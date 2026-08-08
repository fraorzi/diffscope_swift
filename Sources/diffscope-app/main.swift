import AppKit
import DiffScopeEngine
import DiffScopeGit
import DiffScopeShell
import DiffScopeSyntax
import WebKit

/// DEC-013: the three modes are presentation flags over one renderer, not three code paths.
/// Structural and Expanded share a model and therefore a segment set (INV-5); only Raw
/// builds a different one, and it stays available on the same pinned pair.
enum PresentationMode: String, CaseIterable {
    case raw, structural, expanded

    var usesStructure: Bool { self != .raw }
    var title: String { rawValue.capitalized }
}

final class AppState {
    var repositories: [RepositorySnapshot] = []
    var selectedRepository: RepositorySnapshot?
    var scope: ComparisonScope = .allLocalVsHead
    var files: [ChangedFile] = []
    var mergeBaseRev: String?
    var mode: PresentationMode = .structural
    var selectedFile: ChangedFile?
    var configuration = Configuration()
    /// Sources that are configured and unusable. Kept rather than filtered, so the interface can
    /// say which ones and offer to remove them (DEC-036).
    var sourceProblems: [InspectedSource] = []
    /// Path → label, qualified only where two repositories share a folder name (DEC-037).
    var repositoryLabels: [String: String] = [:]
    /// The file list as drawn: headers and files interleaved (DEC-033 as amended).
    var fileRows: [FileListRow] = []
    /// Path → what the list can say about the file cheaply. Filled in by a background pass, so a
    /// large working tree lists immediately and gains its badges a moment later.
    var annotations: [String: FileAnnotation] = [:]
}

final class Controller: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, WKNavigationDelegate {
    let state = AppState()
    let discovery = RepositoryDiscovery(maximumDepth: 2)
    let reader = RepositoryReader()
    let scopes = ScopeReader()
    /// Asked once per file the reader opens, not once per file listed: the disclosure belongs to
    /// the diff view, and a sweep over 63 files would pay 63 `git check-attr` invocations for an
    /// answer nobody is looking at yet (DEC-051).
    let filters = FilterCheck(runner: GitRunner())
    let configStore = ConfigurationStore()

    let parser = TSXParser()
    /// Renders run here, one at a time. See `render(file:previousAnchor:restoringStop:)`.
    let renderQueue = DispatchQueue(label: "local.diffscope.render", qos: .userInitiated)

    var window: NSWindow!
    var repoTable: NSTableView!
    var fileTable: NSTableView!
    var webView: WKWebView!
    var scopeControl: NSSegmentedControl!
    var modeControl: NSSegmentedControl!
    var statusLabel: NSTextField!
    var rendererReady = false
    var pendingModel: String?
    var watcher: RepositoryWatcher?
    var emptyState: NSView!
    var emptyStateDetail: NSTextField!
    /// Held so the empty state can *replace* the three panes rather than float over them: an
    /// overlay leaves the tables visible behind it and still reachable by keyboard.
    var splitView: NSSplitView!
    var wrapMenuItem: NSMenuItem?
    var wrapEnabled = true
    /// Every menu item by the identifier of the binding that drew it (DEC-057), so the few items
    /// that carry state can be reached without searching the menu bar by title.
    var menuItems: [String: NSMenuItem] = [:]
    var rawRegionMenuItem: NSMenuItem?
    /// The mode ⌥⌘V left, and the change stop it left it at. Both are needed: the point of the
    /// control view is that it returns the reader to *where they were*, not merely to the mode.
    var rawRegionReturn: (mode: PresentationMode, stop: Int)?
    /// The terminal (DEC-054). Built with the window, loaded with the window, and **not started
    /// until it is first shown** — a shell costs ~340 ms and one `ssh-agent` here (T0).
    let terminal = TerminalPane()
    var terminalSplit: NSSplitView!
    var terminalMenuItem: NSMenuItem?
    var terminalRawMenuItem: NSMenuItem?
    var terminalVisible = false
    var lastCommandRefresh = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        loadRenderer()
        loadConfiguredSources()
    }

    /// DEC-036 as amended: **no suggested path and no auto-detection**. The hardcoded
    /// `~/WebstormProjects` that used to live here was the very string the amendment removed —
    /// a WebStorm-specific name in a product that depends on WebStorm for nothing.
    ///
    /// `DIFFSCOPE_ROOT` survives as a testing hook that *adds* a root for this launch only. It is
    /// never written to the configuration, so it cannot quietly become a default again.
    private func loadConfiguredSources() {
        let load = configStore.load()
        state.configuration = load.configuration
        if let problem = load.problem {
            // The file is left on disk exactly as it was. Reporting and continuing beats
            // overwriting a configuration the user may be able to repair by hand.
            statusLabel.stringValue = "\(problem) — starting with no sources, the file was left untouched"
        }

        var sources = state.configuration.sources
        if let hook = ProcessInfo.processInfo.environment["DIFFSCOPE_ROOT"],
           !sources.contains(where: { $0.path == hook }) {
            sources.append(ConfiguredSource(kind: .root, path: hook))
        }
        scan(sources: sources)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// DEC-006: the repository list is refreshed on window focus. The FSEvents watcher covers the
    /// repository being *looked at*; everything else goes stale while the reader is in their editor,
    /// and coming back to counts that are minutes old is the case this closes.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !state.repositories.isEmpty else { return }
        rescan()
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Theme.windowWidth, height: Theme.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "DiffScope"
        window.center()

        repoTable = makeTable(identifier: "repo")
        fileTable = makeTable(identifier: "file")

        scopeControl = NSSegmentedControl(
            labels: ["All local", "Unstaged", "Staged", "vs base"],
            trackingMode: .selectOne, target: self, action: #selector(scopeChanged)
        )
        scopeControl.selectedSegment = 0

        modeControl = NSSegmentedControl(
            labels: PresentationMode.allCases.map(\.title),
            trackingMode: .selectOne, target: self, action: #selector(modeChanged)
        )
        modeControl.selectedSegment = PresentationMode.allCases.firstIndex(of: state.mode) ?? 0

        statusLabel = NSTextField(labelWithString: "scanning…")
        statusLabel.font = Theme.font(Theme.textSizeSmall)
        statusLabel.textColor = Theme.inkQuiet
        statusLabel.lineBreakMode = .byTruncatingMiddle

        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = self

        let leftScroll = scrollWrapping(repoTable)
        let middleScroll = scrollWrapping(fileTable)

        let controls = NSStackView(views: [scopeControl, modeControl])
        controls.orientation = .horizontal
        controls.spacing = Theme.space6 - Theme.space2

        let rightStack = NSStackView(frame: NSRect(x: 0, y: 0, width: Theme.windowWidth - Theme.repositoryPaneWidth - Theme.filePaneWidth, height: Theme.windowHeight))
        rightStack.setViews([controls, statusLabel, webView], in: .leading)
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = Theme.space3
        rightStack.edgeInsets = NSEdgeInsets(top: Theme.space4, left: Theme.space4, bottom: 0, right: Theme.space4)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.widthAnchor.constraint(equalTo: rightStack.widthAnchor, constant: -2 * Theme.space4).isActive = true

        // The terminal sits under the diff rather than under the whole window: the lists stay
        // visible while a command runs, which is the arrangement T3 depends on — a command changes
        // the working tree and the diff beside it refreshes.
        let terminalHost = terminal.webView!
        terminalHost.isHidden = true
        let vertical = NSSplitView(frame: rightStack.frame)
        terminalSplit = vertical
        vertical.isVertical = false
        vertical.dividerStyle = .thin
        vertical.addArrangedSubview(rightStack)
        vertical.addArrangedSubview(terminalHost)
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        let terminalHeight = terminalHost.heightAnchor.constraint(equalToConstant: Theme.terminalPaneHeight)
        terminalHeight.priority = NSLayoutConstraint.Priority(600)
        terminalHeight.isActive = true
        terminalHost.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.terminalPaneMinimumHeight).isActive = true

        let split = NSSplitView()
        splitView = split
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(leftScroll)
        split.addArrangedSubview(middleScroll)
        split.addArrangedSubview(vertical)

        // Auto layout inside the split, rather than frame proportions. NSSplitView distributes by
        // preserving existing proportions, and every pane started at zero — so the tables were
        // populated, correct, and drawn at zero width. Width constraints at a priority below
        // `defaultHigh` keep the dividers draggable.
        for (pane, width) in [(leftScroll, Theme.repositoryPaneWidth), (middleScroll, Theme.filePaneWidth)] {
            pane.translatesAutoresizingMaskIntoConstraints = false
            let constraint = pane.widthAnchor.constraint(equalToConstant: width)
            constraint.priority = NSLayoutConstraint.Priority(600)
            constraint.isActive = true
            pane.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.paneMinimumWidth).isActive = true
        }
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        vertical.translatesAutoresizingMaskIntoConstraints = false
        vertical.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.diffPaneMinimumWidth).isActive = true

        buildEmptyState()
        let container = NSView()
        container.addSubview(split)
        container.addSubview(emptyState)
        split.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: container.topAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: container.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        // The divider positions have to be set *after* the split has a width of its own. Setting
        // them on the next run-loop pass looks like it does that and does not: the split is inside
        // a constrained container, so its frame is still zero until layout runs, and every pane
        // collapsed to zero width. The tables were built, populated and invisible.
        container.layoutSubtreeIfNeeded()
    }

    private func makeTable(identifier: String) -> NSTableView {
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.width = Theme.repositoryPaneWidth - 2 * Theme.space6 + Theme.space4
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Theme.rowHeight
        table.dataSource = self
        table.delegate = self
        table.identifier = NSUserInterfaceItemIdentifier(identifier)
        table.usesAlternatingRowBackgroundColors = true
        return table
    }

    private func scrollWrapping(_ view: NSView) -> NSScrollView {
        // A non-zero starting frame matters: NSSplitView distributes space by *preserving the
        // proportions of the frames it already has*, so panes that begin at zero width stay at
        // zero width no matter how wide the split becomes.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Theme.repositoryPaneWidth, height: Theme.windowHeight))
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    private func loadRenderer() {
        guard let html = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Renderer") else {
            statusLabel.stringValue = "renderer bundle missing"
            FileHandle.standardError.write(Data("SELFTEST renderer=MISSING\n".utf8))
            if ProcessInfo.processInfo.environment["DIFFSCOPE_SELFTEST"] != nil { exit(2) }
            return
        }
        FileHandle.standardError.write(Data("SELFTEST renderer=\(html.lastPathComponent)\n".utf8))
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        terminal.load()
    }

    /// ⌥⌘T. The pane is built with the window and hidden; the *shell* starts here, the first time
    /// the reader asks for it.
    @objc func toggleTerminal() {
        setTerminalVisible(!terminalVisible, startingShell: true)
    }

    /// Showing the pane and starting a shell are separate acts. They were one, and the selftest —
    /// which has its own deterministic command to run — silently got the user's `$SHELL` instead,
    /// then reported on a buffer holding somebody's prompt.
    func setTerminalVisible(_ visible: Bool, startingShell: Bool) {
        terminalVisible = visible
        terminal.webView.isHidden = !visible
        terminalMenuItem?.state = visible ? .on : .off
        terminalSplit.adjustSubviews()
        guard visible else { return }
        terminalSplit.setPosition(terminalSplit.bounds.height - Theme.terminalPaneHeight,
                                  ofDividerAt: 0)
        terminal.webView.needsDisplay = true
        window.displayIfNeeded()
        if startingShell { startTerminalIfNeeded() }
        terminal.focus()
    }

    /// ⌥⌘R. Opens the pane first if it is closed, because forcing raw mode on a terminal nobody can
    /// see would be a setting with no visible effect.
    @objc func toggleTerminalRawMode() {
        if !terminalVisible { setTerminalVisible(true, startingShell: true) }
        startTerminalIfNeeded()
        terminal.toggleForcedRaw()
        terminalRawMenuItem?.state = terminal.isForcedRaw ? .on : .off
    }

    @discardableResult
    func startTerminalIfNeeded() -> Bool {
        guard !terminal.started else { return true }
        // The reader's selection decides where the shell opens. *Following* the selection as it
        // changes belongs to T3; this is the one line that makes the pane useful before then.
        let directory = state.selectedRepository?.url.path ?? NSHomeDirectory()
        let started = terminal.start(workingDirectory: directory)
        if !started { statusLabel.stringValue = "the terminal could not start a shell" }
        terminal.onSessionExit = { [weak self] in
            guard let self else { return }
            self.terminal.stop()
            if self.terminalVisible { self.setTerminalVisible(false, startingShell: false) }
        }
        terminal.onCommandFinished = { [weak self] _ in self?.refreshAfterCommand() }
        return started
    }

    /// What a finished command adds to what the watcher already does.
    ///
    /// **Measured before it was written** (T3-A), and the measurement contradicted the reasoning:
    /// FSEvents *does* see `git commit`, because `.git` lives inside the watched root — one signal
    /// at ~440 ms, same as a plain edit. So the file list needs nothing from here.
    ///
    /// What no file-system event triggers is the **repository-level** sweep: the uncommitted count
    /// and commits-ahead-of-base beside every repository in the list. Those change the moment a
    /// commit lands and otherwise stay stale until the window is focused (DEC-006). That, and only
    /// that, is what a command's end mark is used for.
    private func refreshAfterCommand() {
        guard state.selectedRepository != nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCommandRefresh) > RefreshDebounce.quietPeriod else { return }
        lastCommandRefresh = now
        rescan()
    }

    /// ⌥⌘K. The explicit half of DEC-056: when the guard refused, the reader decides.
    @objc func followTerminalToSelection() {
        guard let repository = state.selectedRepository else { return }
        startTerminalIfNeeded()
        if !terminalVisible { setTerminalVisible(true, startingShell: true) }
        let outcome = terminal.follow(directory: repository.url.path, force: true)
        if case .sent = outcome {
            statusLabel.stringValue = "terminal followed to \(repository.displayName)"
        }
    }

    /// Called when the reader picks a different repository. The refusals are silent by design: the
    /// pane already shows that the directories disagree, and a status line that shouted every time
    /// somebody had half a command typed would be noise.
    private func followTerminalIfPossible(_ repository: RepositorySnapshot) {
        guard terminal.started else { return }
        terminal.follow(directory: repository.url.path)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        rendererReady = true
        if let pending = pendingModel { push(pending); pendingModel = nil }
        guard ProcessInfo.processInfo.environment["DIFFSCOPE_SELFTEST"] != nil else { return }
        let old = [UInt8]("const a = \"Z\u{0307}ABKA\";\n".utf8)
        let new = [UInt8]("const a = \"\u{017B}ABKA\";\n".utf8)
        let render = buildRenderModel(model: trivialModel(oldBytes: old, newBytes: new),
                                      pinOld: "pinA", pinNew: "pinB")
        guard let json = try? encodeRenderModel(render) else { exit(3) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            let ok = text.contains("pinA:pinB") && text.contains("\u{0307}")
            FileHandle.standardError.write(Data("SELFTEST probe=\(ok ? "OK" : "MISMATCH") \(text.prefix(160))\n".utf8))
            if !ok { exit(4) }
            self.runStructuralSelftest()
        }
    }

    /// Proves the structural path crosses into the renderer natively, not only in the harness:
    /// a formatting-only edit must arrive labelled and be marked as such in the document.
    private func runStructuralSelftest() {
        let old = [UInt8]("""
        export function Card({ title, items }) {
          return (
            <div className='card'>
              <h2>{title}</h2>
              <List items={items} />
            </div>
          );
        }

        """.utf8)
        let new = [UInt8]("""
        export function Card({ title, items }) {
          return (
            <>
                <h2>{title}</h2>
                <List items={items} />
            </>
          );
        }

        """.utf8)
        let outcome = buildModel(path: "selftest.tsx", old: old, new: new, mode: .structural)
        let render = buildRenderModel(model: outcome.model, pinOld: "pinC", pinNew: "pinD",
                                      mode: "structural", validation: outcome.validation,
                                      notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(5) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            let ok = text.contains("pinC:pinD")
                && text.contains("formatting-only")
                && !text.contains("\"formattingMarks\":0")
            FileHandle.standardError.write(
                Data("SELFTEST structural=\(ok ? "OK" : "MISMATCH") \(outcome.summary) \(text.suffix(200))\n".utf8))
            if !ok { exit(6) }
            self.snapshot(named: "structural") {
                self.runModeAgreementSelftest(model: outcome.model, validation: outcome.validation,
                                              structuralProbe: text)
            }
        }
    }

    /// M7: two edits far apart, so the middle is foldable and "next change" has somewhere to go.
    private func runNavigationSelftest() {
        let lines = (1...40).map { "const value\($0) = \($0);\n" }.joined()
        let old = [UInt8]("const first = 1;\n\(lines)const last = 2;\n".utf8)
        let new = [UInt8]("const first = 111;\n\(lines)const last = 222;\n".utf8)
        let outcome = buildModel(path: "selftest.tsx", old: old, new: new, mode: .structural)
        let render = buildRenderModel(model: outcome.model, pinOld: "pinI", pinNew: "pinJ",
                                      mode: "structural", validation: outcome.validation,
                                      notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(13) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeCommand(\"nextChange\"))") { value, _ in
            let jump = (value as? String) ?? "nil"
            self.webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { probe, _ in
                let text = (probe as? String) ?? "nil"
                let ok = jump.contains("\"index\":0") && !text.contains("\"foldMarks\":0")
                FileHandle.standardError.write(
                    Data("SELFTEST navigation=\(ok ? "OK" : "MISMATCH") jump=\(jump) stops=\(render.stops.count) folds=\(render.collapses.count)\n".utf8))
                if !ok { exit(14) }
                self.snapshot(named: "navigation") { self.runRefreshSelftest() }
            }
        }
    }

    /// M7 part two: a reindented block must arrive as one group that says how much it holds
    /// (DEC-048), and the reader's position must survive a refresh that inserts text above it
    /// (DEC-034). Both are decided in the engine, so what this proves is that the decision
    /// survives the crossing and is actually drawn.
    private func runRefreshSelftest() {
        let filler = (1...20).map { "const filler\($0) = \($0);\n" }.joined()
        let old = [UInt8]("""
        export function Card({ title }) {
          const a = 1;
          const b = 2;
          const c = 3;
          const d = 4;
          return <div>{title}</div>;
        }

        \(filler)
        """.utf8)
        let new = [UInt8]("""
        export function Card({ title }) {
            const a = 1;
            const b = 2;
            const c = 3;
            const d = 4;
          return <div>{title}</div>;
        }

        \(filler)
        """.utf8)
        let outcome = buildModel(path: "selftest.tsx", old: old, new: new, mode: .structural)
        let render = buildRenderModel(model: outcome.model, pinOld: "pinK", pinNew: "pinL",
                                      mode: "structural", validation: outcome.validation,
                                      notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(15) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            let grouped = !text.contains("\"formattingFoldMarks\":0") && text.contains("formatting-only changes")
            FileHandle.standardError.write(
                Data("SELFTEST formatting-collapse=\(grouped ? "OK" : "MISMATCH") groups=\(render.formattingCollapses.count) \(text.suffix(200))\n".utf8))
            if !grouped { exit(16) }
            self.snapshot(named: "refresh") { self.runAnchorSelftest(old: old, new: new) }
        }
    }

    private func runAnchorSelftest(old: [UInt8], new: [UInt8]) {
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeAnchorState())") { value, _ in
            guard let text = value as? String, let data = text.data(using: .utf8),
                  let anchor = try? JSONDecoder().decode(RefreshAnchor.self, from: data) else {
                FileHandle.standardError.write(Data("SELFTEST anchor=MISMATCH no anchor reported\n".utf8))
                exit(17)
            }
            let prefix = [UInt8]("const inserted = 0;\nconst alsoInserted = 1;\n".utf8)
            let outcome = self.buildModel(path: "selftest.tsx", old: prefix + old, new: prefix + new,
                                          mode: .structural)
            let render = buildRenderModel(model: outcome.model, pinOld: "pinM", pinNew: "pinN",
                                          mode: "structural", validation: outcome.validation,
                                          notices: outcome.notices, previousAnchor: anchor)
            guard let json = try? encodeRenderModel(render) else { exit(18) }
            self.push(json)
            self.webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { probe, _ in
                let observed = (probe as? String) ?? "nil"
                let moved = (render.restore?.oldStart ?? 0) > anchor.oldStart
                let ok = render.restore?.resolution == .exact && moved && observed.contains("pinM:pinN")
                FileHandle.standardError.write(
                    Data("SELFTEST anchor=\(ok ? "OK" : "MISMATCH") \(String(describing: render.restore?.resolution)) \(anchor.oldStart) → \(render.restore?.oldStart ?? -1)\n".utf8))
                self.snapshot(named: "anchored") {
                    if ok { self.runDegradationSelftest() } else { exit(19) }
                }
            }
        }
    }

    /// DEC-051/INV-4: the most conservative condition must reach the *screen*, not merely the model.
    /// The harness can prove the ranking; only the webview can prove the sentence arrived, and the
    /// snapshot is the only way to see whether a sentence this long is still readable as a chip.
    private func runDegradationSelftest() {
        let old = [UInt8]("const a = 1;\n".utf8)
        let new = [UInt8]("const a = 2;\n".utf8)
        let disclosure = "a Git filter is active for this file (eol=crlf text=set), so the bytes on "
            + "disk and the bytes recorded in the object database are not the same text. This view "
            + "compares them as they are actually stored, which is why the file can be listed as "
            + "changed by `git status` while `git diff` reports nothing"
        let outcome = buildModel(path: "selftest.tsx", old: old, new: new, mode: .structural,
                                 external: [.filterActive(reason: disclosure)])
        let render = buildRenderModel(model: outcome.model, pinOld: "pinO", pinNew: "pinP",
                                      mode: "structural", validation: outcome.validation,
                                      notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(20) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            let ok = text.contains("Structural analysis unavailable")
                && text.contains("git status")
                && text.contains("All textual differences are shown")
            FileHandle.standardError.write(
                Data("SELFTEST degradation=\(ok ? "OK" : "MISMATCH") \(outcome.summary.prefix(80))\n".utf8))
            self.snapshot(named: "degraded") {
                if ok { self.runGutterSelftest() } else { exit(21) }
            }
        }
    }

    /// `12-…` §5.1: the gutter is the third carrier of change meaning. The harness proves which
    /// lines the engine marks; only the webview proves the numbers and the marks were drawn, and
    /// only the snapshot shows whether they are legible beside the code.
    private func runGutterSelftest() {
        let lines = (1...12).map { "const value\($0) = \($0);\n" }.joined()
        let old = [UInt8](lines.utf8)
        let new = [UInt8](lines.replacingOccurrences(of: "value7 = 7", with: "value7 = 77").utf8)
        let outcome = buildModel(path: "selftest.tsx", old: old, new: new, mode: .structural)
        let render = buildRenderModel(model: outcome.model, pinOld: "pinQ", pinNew: "pinR",
                                      mode: "structural", validation: outcome.validation,
                                      notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(22) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            let numbered = !text.contains("\"lineNumbers\":0")
            let marked = !text.contains("\"gutterChanged\":0")
            self.webView.evaluateJavaScript("window.diffscopeCurrentLine()") { line, _ in
                let reported = (line as? Int) ?? (line as? NSNumber)?.intValue ?? -1
                // ⌘O used to hand the editor a literal 1 whatever the reader was looking at.
                let ok = numbered && marked && reported >= 1
                FileHandle.standardError.write(
                    Data("SELFTEST gutter=\(ok ? "OK" : "MISMATCH") line=\(reported) \(text.suffix(120))\n".utf8))
                self.snapshot(named: "gutter") {
                    if ok { self.runStyleAuditSelftest() } else { exit(23) }
                }
            }
        }
    }

    /// G2 (`23-release-gates.md`): a design may restyle any mark and may never hide one. Asked of
    /// the live document, because a stylesheet can be read and still be wrong about what the reader
    /// gets — a later rule, a cascade, an inherited opacity.
    private func runStyleAuditSelftest() {
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeStyleAudit())") { value, _ in
            let text = (value as? String) ?? "nil"
            let data = Data(text.utf8)
            let audit = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] ?? [:]
            var hidden: [String] = []
            var colourOnly: [String] = []
            for (name, entry) in audit {
                if entry["hidden"] as? Bool == true { hidden.append(name) }
                if (entry["distinguishing"] as? [String])?.isEmpty ?? true { colourOnly.append(name) }
            }
            let ok = !audit.isEmpty && hidden.isEmpty && colourOnly.isEmpty
            let line = "SELFTEST style=\(ok ? "OK" : "MISMATCH") audited=\(audit.count)"
                + " hidden=\(hidden.sorted()) colour-only=\(colourOnly.sorted())\n"
            FileHandle.standardError.write(Data(line.utf8))
            guard ok else { exit(24) }

            // Negative control: hide a mark deliberately and require the audit to catch it. An
            // audit that passes on a hidden mark would pass on a design that hid one.
            self.webView.evaluateJavaScript("window.diffscopeInjectHostileStyle(true)") { _, _ in
                self.webView.evaluateJavaScript("JSON.stringify(window.diffscopeStyleAudit())") { hostile, _ in
                    let text = (hostile as? String) ?? ""
                    let caught = text.contains("\"ds-changed\":{\"hidden\":true")
                        || text.contains("\"hidden\":true,\"distinguishing\"")
                    FileHandle.standardError.write(Data(
                        "SELFTEST style-control=\(caught ? "OK" : "MISMATCH") the audit catches a hidden mark\n".utf8))
                    self.webView.evaluateJavaScript("window.diffscopeInjectHostileStyle(false)") { _, _ in
                        guard caught else { exit(25) }
                        self.runTerminalSelftest()
                    }
                }
            }
        }
    }

    /// T1 (DEC-054): a command run through a real PTY, its output reaching the grid, and the
    /// alternate screen entered and reported.
    ///
    /// The command is `/bin/sh -c`, not the user's shell: G3 runs this selftest from `/` on a
    /// stranger's machine, where `$SHELL` and `~/.zshrc` are somebody else's. Prompt marks are
    /// covered headlessly in `TerminalChecks` and against a real interactive zsh by gate T0.
    private func runTerminalSelftest() {
        setTerminalVisible(true, startingShell: false)
        // The grid is the first surface in this product that paints on `requestAnimationFrame`, and
        // WebKit suspends those while the window is **occluded** — which a window launched behind a
        // terminal always is. The buffer then fills while the screen stays empty, and every other
        // signal looks healthy: this is M8-D's defect class arriving through a different door.
        //
        // So the selftest brings its own window to the front and requires that painting resumes.
        // Without this the arm below could only ever assert what the buffer holds.
        window.level = .floating
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        let script = "printf 'DIFFSCOPE-TERMINAL-OK\\n'; sleep 1;"
            + " printf '\\033[?1049hALTERNATE-OK'; sleep 3"
        guard terminal.start(workingDirectory: NSHomeDirectory(),
                             command: "/bin/sh",
                             arguments: ["-c", script]) else {
            FileHandle.standardError.write(Data("SELFTEST terminal=MISMATCH no shell\n".utf8))
            exit(26)
        }

        // A pane drawn at zero size reports a size and no error anywhere else — M8-D, where two
        // lists rendered completely blank and nothing failed. The grid's own pixel size is part of
        // what is asserted, not just the text in its buffer.
        pollTerminal(until: { probe in
            probe.contains("DIFFSCOPE-TERMINAL-OK") && !probe.contains("\"pixelWidth\":0")
        }, timeout: 6) { reached, probe in
            let sized = !probe.contains("\"pixelWidth\":0") && !probe.contains("\"pixelHeight\":0")
            let tokensPresent = probe.contains("\"missingTokens\":[]")
            let ok = reached && sized && tokensPresent
            let line = "SELFTEST terminal=\(ok ? "OK" : "MISMATCH") output reached the grid; "
                + "\(probe.prefix(700))\n"
            FileHandle.standardError.write(Data(line.utf8))
            guard ok else { exit(27) }

            self.pollTerminal(until: {
                $0.contains("\"alternateScreen\":true") && $0.contains("ALTERNATE-OK")
            }, timeout: 8) { entered, alternate in
                let line = "SELFTEST terminal-alternate=\(entered ? "OK" : "MISMATCH") "
                    + "\(alternate.prefix(700))\n"
                FileHandle.standardError.write(Data(line.utf8))
                guard entered else { exit(28) }
                self.assertTerminalPainted {
                    self.snapshotTerminal(named: "terminal") { self.runInputLineSelftest() }
                }
            }
        }
    }

    /// What the buffer holds and what the screen shows are different claims, and only the second is
    /// what the reader gets — M8-D was a surface that drew nothing while every check passed.
    ///
    /// The grid paints on `requestAnimationFrame`, and WebKit suspends those while the window is
    /// occluded: `document.visibilityState` goes to `hidden` and the DOM rows are never written. A
    /// selftest launched from a terminal is usually behind that terminal, so this arm **waits for a
    /// genuinely visible window** and says plainly when it never got one, rather than asserting on
    /// pixels that were never asked for.
    private func assertTerminalPainted(then next: @escaping () -> Void) {
        var attempts = 0
        func check() {
            terminal.webView.evaluateJavaScript("document.visibilityState") { value, _ in
                attempts += 1
                if (value as? String) != "visible", attempts < 30 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
                    return
                }
                guard (value as? String) == "visible" else {
                    FileHandle.standardError.write(Data(
                        ("SELFTEST terminal-paint=SKIPPED the window stayed occluded for 3 s, so "
                            + "WebKit suspended animation frames and the grid was never asked to "
                            + "paint. Run with DiffScope in front to assert drawn glyphs.\n").utf8))
                    next()
                    return
                }
                self.pollTerminal(until: { $0.contains("\"renderedText\":\"ALTERNATE-OK") },
                                  timeout: 4) { painted, probe in
                    let frames = probe.contains("\"framesSinceLastProbe\":0") ? "none" : "arriving"
                    let line = "SELFTEST terminal-paint=\(painted ? "OK" : "MISMATCH") "
                        + "glyphs on screen, frames \(frames)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                    guard painted else { exit(29) }
                    next()
                }
            }
        }
        check()
    }

    /// Polling rather than a fixed delay: the grid is driven by a real process, and a selftest that
    /// waits a chosen number of milliseconds passes or fails by machine load.
    private func pollTerminal(until condition: @escaping (String) -> Bool,
                              timeout: TimeInterval,
                              deadline: Date? = nil,
                              then completion: @escaping (Bool, String) -> Void) {
        let limit = deadline ?? Date().addingTimeInterval(timeout)
        terminal.probe { probe in
            if condition(probe) { completion(true, probe); return }
            if Date() >= limit { completion(false, probe); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.pollTerminal(until: condition, timeout: timeout, deadline: limit, then: completion)
            }
        }
    }

    /// T2: the input line, driven the way a reader drives it — a prompt mark, then a typed command,
    /// then a handover.
    ///
    /// The fixture is `printf` of a prompt mark followed by `cat`: real marks over a real PTY, an
    /// echo to prove the bytes arrived, and no dependence on whose `~/.zshrc` is installed.
    private func runInputLineSelftest() {
        terminal.stop()
        guard terminal.start(workingDirectory: NSHomeDirectory(),
                            command: "/bin/sh",
                            arguments: ["-c", "printf '\\033]133;A\\007'; cat"]) else {
            FileHandle.standardError.write(Data("SELFTEST terminal-input=MISMATCH no shell\n".utf8))
            exit(30)
        }

        pollTerminal(until: { $0.contains("\"mode\":\"local\"") }, timeout: 6) { local, probe in
            let visible = probe.contains("\"inputVisible\":true")
            let labelled = probe.contains("\"modeLabel\":\"prompt\"")
            let configured = probe.contains("\"Enter\"") && probe.contains("\"ctrl-r\"")
            let ok = local && visible && labelled && configured
            let line = "SELFTEST terminal-input=\(ok ? "OK" : "MISMATCH") a prompt mark opened the "
                + "input line; \(probe.suffix(220))\n"
            FileHandle.standardError.write(Data(line.utf8))
            guard ok else { exit(31) }

            // A real keydown through the page's own handler, not a call into its internals: the
            // interception, the routing round trip and the write to the PTY are all on the path.
            let type = """
            (() => { const f = document.getElementById('line'); f.focus(); f.value = 'typed-into-the-line';
              f.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true, cancelable: true}));
              return f.value; })()
            """
            self.terminal.webView.evaluateJavaScript(type) { cleared, _ in
                self.pollTerminal(until: { $0.contains("typed-into-the-line") }, timeout: 6) { echoed, after in
                    let emptied = (cleared as? String) == "" || after.contains("\"line\":\"\"")
                    let ok = echoed && emptied
                    let line = "SELFTEST terminal-submit=\(ok ? "OK" : "MISMATCH") the line reached the "
                        + "shell and the field cleared\n"
                    FileHandle.standardError.write(Data(line.utf8))
                    guard ok else { exit(32) }
                    self.runHandoverSelftest()
                }
            }
        }
    }

    /// Tab is the shell's, not ours: the typed text and the key go over, and the mode says who has
    /// the line. Without this the input line would silently break completion.
    private func runHandoverSelftest() {
        let tab = """
        (() => { const f = document.getElementById('line'); f.focus(); f.value = 'handed-over-text';
          f.dispatchEvent(new KeyboardEvent('keydown', {key: 'Tab', bubbles: true, cancelable: true}));
          return true; })()
        """
        terminal.webView.evaluateJavaScript(tab) { _, _ in
            self.pollTerminal(until: {
                $0.contains("\"mode\":\"handedOver\"") && $0.contains("handed-over-text")
            }, timeout: 6) { handed, probe in
                let hidden = probe.contains("\"inputVisible\":false")
                let admits = probe.contains("shell has the line")
                let ok = handed && hidden && admits
                let line = "SELFTEST terminal-handover=\(ok ? "OK" : "MISMATCH") the shell has the "
                    + "line and the chip says so; \(probe.suffix(200))\n"
                FileHandle.standardError.write(Data(line.utf8))
                guard ok else { exit(33) }

                self.terminal.toggleForcedRaw()
                self.pollTerminal(until: { $0.contains("\"mode\":\"forcedRaw\"") }, timeout: 4) { forced, forcedProbe in
                    let admitsForced = forcedProbe.contains("forced")
                    let line = "SELFTEST terminal-escape-hatch=\(forced && admitsForced ? "OK" : "MISMATCH") "
                        + "⌥⌘R forces raw and the chip admits it\n"
                    FileHandle.standardError.write(Data(line.utf8))
                    guard forced, admitsForced else { exit(34) }
                    self.terminal.toggleForcedRaw()
                    self.snapshotTerminal(named: "terminal-input") { self.runFollowSelftest() }
                }
            }
        }
    }

    /// T3: the terminal belongs to the product — it reports where it is, and follows the reader's
    /// selection when there is provably nothing to disturb.
    ///
    /// The fixture reports a directory over OSC 7 and then echoes, so the chip, the guard and the
    /// composed `cd` are all exercised without depending on anybody's shell.
    private func runFollowSelftest() {
        terminal.stop()
        let target = NSTemporaryDirectory() + "diffscope selftest 'dir"
        try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        let script = "printf '\\033]7;file:///tmp/reported-by-the-shell\\007'; "
            + "printf '\\033]133;A\\007'; cat"
        guard terminal.start(workingDirectory: NSHomeDirectory(),
                             command: "/bin/sh", arguments: ["-c", script]) else {
            FileHandle.standardError.write(Data("SELFTEST terminal-follow=MISMATCH no shell\n".utf8))
            exit(35)
        }

        pollTerminal(until: { $0.contains("reported-by-the-shell") }, timeout: 6) { reported, probe in
            let ok = reported && probe.contains("\"cwdDiverged\":true")
            let line = "SELFTEST terminal-cwd=\(ok ? "OK" : "MISMATCH") the shell reports where it "
                + "is, and the pane says it is not the selected directory; \(probe.suffix(160))\n"
            FileHandle.standardError.write(Data(line.utf8))
            guard ok else { exit(36) }

            // A path with a space and a quote in it, because that is the case that would go wrong.
            let outcome = self.terminal.follow(directory: target)
            let sent = outcome?.wasSent ?? false
            self.pollTerminal(until: { _ in false }, timeout: 0.4) { _, _ in
                self.terminal.probe { after in
                    // `cat` echoes, so the composed command is visible in the grid's own buffer.
                    let arrived = after.contains("cd -- '") && after.contains("selftest ")
                    let ok = sent && arrived
                    let line = "SELFTEST terminal-follow=\(ok ? "OK" : "MISMATCH") the quoted cd "
                        + "reached the shell; \(String(describing: outcome))\n"
                    FileHandle.standardError.write(Data(line.utf8))
                    guard ok else { exit(37) }
                    try? FileManager.default.removeItem(atPath: target)
                    self.snapshotTerminal(named: "terminal-follow") {
                        self.terminal.stop()
                        self.runKeyboardSelftest()
                    }
                }
            }
        }
    }

    /// Definition of done §6: *a 63-file working tree is reviewable entirely from the keyboard*.
    ///
    /// The claim is about a person with their hands on the keys, so this arm presses keys — real
    /// `NSEvent`s through the real menu bar and the real table, not `@objc` methods called directly.
    /// Calling the methods would prove the methods work and say nothing about whether anything is
    /// **bound** to them, which is the half DEC-016 is actually about.
    ///
    /// The tree comes from `Scripts/keyboard-tree.sh` by way of `DIFFSCOPE_KEYBOARD_TREE`. Without
    /// it the arm says SKIPPED **with the reason** — the T1-A pattern, after a blank grid passed
    /// every arm it had.
    private func runKeyboardSelftest() {
        guard let tree = ProcessInfo.processInfo.environment["DIFFSCOPE_KEYBOARD_TREE"],
              FileManager.default.fileExists(atPath: tree + "/.git") else {
            FileHandle.standardError.write(Data(
                ("SELFTEST keyboard=SKIPPED no DIFFSCOPE_KEYBOARD_TREE — build one with "
                    + "Scripts/keyboard-tree.sh and the walk over 63 files is measured\n").utf8))
            exit(0)
        }
        scan(sources: [ConfiguredSource(kind: .repository, path: tree)])
        // The sweep is off the main thread; the walk needs the list it produces.
        waitForFiles(attemptsLeft: 40) { files in
            guard files == 63 else {
                FileHandle.standardError.write(Data(
                    "SELFTEST keyboard=MISMATCH the tree has \(files) changed files, not 63\n".utf8))
                exit(40)
            }
            self.walkTheFileList()
        }
    }

    private func waitForFiles(attemptsLeft: Int, then next: @escaping (Int) -> Void) {
        let files = state.fileRows.compactMap { $0.file }.count
        guard files == 0, attemptsLeft > 0 else { next(files); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.waitForFiles(attemptsLeft: attemptsLeft - 1, then: next)
        }
    }

    /// Two walks over the same list: ⌘] through the menu bar, and ↓ through the table itself. They
    /// disagreed until M8-J — ⌘] stepped past headers and ↓ landed on them — which is why both are
    /// pressed here rather than one being taken as evidence for the other.
    private func walkTheFileList() {
        let headers = state.fileRows.filter { $0.file == nil }.count
        focusFiles()
        fileTable.selectRowIndexes(IndexSet(integer: RowNavigation.firstSelectable(in: state.fileRows) ?? 0),
                                   byExtendingSelection: false)

        var visited: [String] = []
        var headerStops = 0
        var keystrokes = 0
        func record() {
            let row = fileTable.selectedRow
            if row >= 0, row < state.fileRows.count {
                if let file = state.fileRows[row].file { visited.append(file.path) } else { headerStops += 1 }
            }
        }
        record()
        while keystrokes < 200 {
            let before = fileTable.selectedRow
            guard press(key: "]", modifiers: [.command]) else { break }
            // The end of the list is where the selection stops moving; ⌘] does not wrap, which is
            // itself the behaviour under test. That last press is a probe for the end rather than a
            // step, so it is not counted.
            guard fileTable.selectedRow != before else { break }
            keystrokes += 1
            record()
        }
        let distinct = Set(visited).count
        let menuOK = distinct == 63 && headerStops == 0 && keystrokes == 62
        FileHandle.standardError.write(Data(
            ("SELFTEST keyboard=\(menuOK ? "OK" : "MISMATCH") ⌘] visited \(distinct) of 63 files in "
                + "\(keystrokes) keystrokes past \(headers) headers, \(headerStops) blind stops\n").utf8))
        guard menuOK else { exit(41) }

        // The arrow keys, through the table's own key handling. `shouldSelectRow` is what makes them
        // agree with ⌘]; before it, ↓ selected headers and the diff pane kept showing the last file.
        fileTable.selectRowIndexes(IndexSet(integer: RowNavigation.firstSelectable(in: state.fileRows) ?? 0),
                                   byExtendingSelection: false)
        var arrowVisited: [String] = []
        var arrowHeaderStops = 0
        for _ in 0..<80 {
            let row = fileTable.selectedRow
            guard row >= 0, row < state.fileRows.count else { break }
            if let file = state.fileRows[row].file { arrowVisited.append(file.path) } else { arrowHeaderStops += 1 }
            sendArrowDown()
            if fileTable.selectedRow == row { break }
        }
        let arrowOK = Set(arrowVisited).count == 63 && arrowHeaderStops == 0
        FileHandle.standardError.write(Data(
            ("SELFTEST keyboard-arrows=\(arrowOK ? "OK" : "MISMATCH") ↓ visited "
                + "\(Set(arrowVisited).count) of 63 files, \(arrowHeaderStops) blind stops\n").utf8))
        guard arrowOK else { exit(42) }

        rawForCurrentRegionSelftest()
    }

    /// ⌥⌘V, the row of `12-…` §9 that had no implementation at all before M8-J: the same region,
    /// shown raw, and the mode it left restored on the second press.
    private func rawForCurrentRegionSelftest() {
        guard let modified = state.fileRows.compactMap({ $0.file }).first(where: { $0.kind == .modified }),
              let row = state.fileRows.firstIndex(where: { $0.file?.path == modified.path }) else {
            FileHandle.standardError.write(Data("SELFTEST keyboard-raw-region=MISMATCH no modified file\n".utf8))
            exit(43)
        }
        fileTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        fileTable.scrollRowToVisible(row)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard self.press(key: "n", modifiers: [.command]) else { exit(43) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.webView.evaluateJavaScript("window.diffscopeCommand(\"currentStop\")") { value, _ in
                    let before = (value as? Int) ?? (value as? NSNumber)?.intValue ?? -1
                    guard self.press(key: "v", modifiers: [.command, .option]) else { exit(44) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.webView.evaluateJavaScript("window.diffscopeCommand(\"currentStop\")") { raw, _ in
                            let inRaw = (raw as? Int) ?? (raw as? NSNumber)?.intValue ?? -1
                            let ok = self.state.mode == .raw && inRaw == before && before >= 0
                            FileHandle.standardError.write(Data(
                                ("SELFTEST keyboard-raw-region=\(ok ? "OK" : "MISMATCH") mode="
                                    + "\(self.state.mode.rawValue) stop \(before) → \(inRaw)\n").utf8))
                            guard ok else { exit(45) }
                            guard self.press(key: "v", modifiers: [.command, .option]) else { exit(46) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                let returned = self.state.mode == .structural
                                FileHandle.standardError.write(Data(
                                    ("SELFTEST keyboard-return=\(returned ? "OK" : "MISMATCH") the second "
                                        + "press returns to \(self.state.mode.rawValue)\n").utf8))
                                guard returned else { exit(47) }
                                self.windowSnapshot(named: "keyboard") { exit(0) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// A key equivalent, routed the way macOS routes one. `performKeyEquivalent` returning false
    /// means **nothing is bound** to that keystroke, which is the defect DEC-016 names.
    @discardableResult
    private func press(key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
        ) else { return false }
        return NSApplication.shared.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    private func sendArrowDown() {
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: down,
            charactersIgnoringModifiers: down, isARepeat: false, keyCode: 125
        ) else { return }
        window.sendEvent(event)
    }

    private func snapshotTerminal(named name: String, then next: @escaping () -> Void) {
        guard let dir = ProcessInfo.processInfo.environment["DIFFSCOPE_SNAPSHOT_DIR"] else {
            next(); return
        }
        terminal.webView.takeSnapshot(with: nil) { image, _ in
            if let image, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
                do {
                    try png.write(to: url)
                    FileHandle.standardError.write(Data("SELFTEST snapshot=\(url.path)\n".utf8))
                } catch {
                    FileHandle.standardError.write(
                        Data("SELFTEST snapshot=FAILED \(url.path) — \(error)\n".utf8))
                }
            }
            next()
        }
    }

    /// DEC-038: a block relocated without modification must read as one move, on both sides.
    private func runMoveSelftest() {
        let old = [UInt8]("""
        const formatPrice = (value: number) => value.toFixed(2) + " zl";

        export function Cart({ items }) {
          return <ul>{items.map(i => <li>{formatPrice(i.price)}</li>)}</ul>;
        }

        """.utf8)
        let new = [UInt8]("""
        export function Cart({ items }) {
          return <ul>{items.map(i => <li>{formatPrice(i.price)}</li>)}</ul>;
        }

        const formatPrice = (value: number) => value.toFixed(2) + " zl";

        """.utf8)
        let outcome = buildModel(path: "selftest.tsx", old: old, new: new, mode: .structural)
        let render = buildRenderModel(model: outcome.model, pinOld: "pinG", pinNew: "pinH",
                                      mode: "structural", validation: outcome.validation,
                                      notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(11) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            let ok = text.contains("\"moved\":") && text.contains("pinG:pinH")
            FileHandle.standardError.write(
                Data("SELFTEST moves=\(ok ? "OK" : "MISMATCH") \(outcome.summary)\n".utf8))
            if !ok { exit(12) }
            self.snapshot(named: "moved") { self.runNavigationSelftest() }
        }
    }

    /// DEC-023: the corpus's own case — one side decomposed, both rendering identically. The
    /// interface has to say why the marked region looks the same on both sides.
    private func runDisclosureSelftest() {
        let old = [UInt8]("const shop = \"Z\u{0307}ABKA\";\n".utf8)
        let new = [UInt8]("const shop = \"\u{017B}ABKA\";\n".utf8)
        let outcome = buildModel(path: "selftest.tsx", old: old, new: new, mode: .expanded)
        let render = buildRenderModel(model: outcome.model, pinOld: "pinE", pinNew: "pinF",
                                      mode: "expanded", validation: outcome.validation,
                                      notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(9) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            let ok = text.contains("normalization-form") && text.contains("U+0307")
            FileHandle.standardError.write(
                Data("SELFTEST disclosure=\(ok ? "OK" : "MISMATCH") \(outcome.summary) \(text.suffix(220))\n".utf8))
            if !ok { exit(10) }
            self.snapshot(named: "disclosure") { self.runMoveSelftest() }
        }
    }

    /// The rendered result is otherwise only checkable through the probe, which cannot see
    /// whether a mark is legible. `DIFFSCOPE_SNAPSHOT_DIR` writes what the webview drew.
    /// Photographs the **window**, not the webview.
    ///
    /// Every other snapshot in this selftest shows the document only, which is why M8-D's blank
    /// rows survived: the one surface nothing photographed was the shell. The keyboard walk happens
    /// in the file list, so this is the arm that has to show it.
    ///
    /// The diff pane comes out black here, and that is the method rather than the application:
    /// `cacheDisplay` copies AppKit's own drawing, and a `WKWebView` renders out of process. The
    /// document has its own snapshots — this one is of the lists.
    private func windowSnapshot(named name: String, then next: @escaping () -> Void) {
        guard let dir = ProcessInfo.processInfo.environment["DIFFSCOPE_SNAPSHOT_DIR"],
              let view = window.contentView else { next(); return }
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        if let rep {
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            do {
                try rep.representation(using: .png, properties: [:])?.write(to: url)
                FileHandle.standardError.write(Data("SELFTEST snapshot=\(url.path)\n".utf8))
            } catch {
                FileHandle.standardError.write(
                    Data("SELFTEST snapshot=FAILED \(url.path) — \(error)\n".utf8))
            }
        }
        next()
    }

    private func snapshot(named name: String, then next: @escaping () -> Void) {
        guard let dir = ProcessInfo.processInfo.environment["DIFFSCOPE_SNAPSHOT_DIR"] else {
            next(); return
        }
        webView.takeSnapshot(with: nil) { image, _ in
            if let image, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
                // Reported rather than swallowed: this line claimed to have written a snapshot
                // whether or not the directory existed, so a run with a mistyped path looked
                // identical to a successful one.
                do {
                    try png.write(to: url)
                    FileHandle.standardError.write(Data("SELFTEST snapshot=\(url.path)\n".utf8))
                } catch {
                    FileHandle.standardError.write(
                        Data("SELFTEST snapshot=FAILED \(url.path) — \(error)\n".utf8))
                }
            }
            next()
        }
    }

    /// INV-5: Structural and Expanded must produce identical segment sets. They are flags over
    /// one model, so agreement is structural — this proves it survives the crossing anyway.
    private func runModeAgreementSelftest(model: DiffModel, validation: ValidationResult,
                                          structuralProbe: String) {
        let render = buildRenderModel(model: model, pinOld: "pinC", pinNew: "pinD",
                                      mode: "expanded", validation: validation)
        guard let json = try? encodeRenderModel(render) else { exit(7) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            func field(_ probe: String, _ key: String) -> String? {
                guard let range = probe.range(of: "\"\(key)\":") else { return nil }
                return String(probe[range.upperBound...].prefix(while: { $0.isNumber }))
            }
            let sameSegments = field(text, "oldSegments") == field(structuralProbe, "oldSegments")
                && field(text, "newSegments") == field(structuralProbe, "newSegments")
            let quietened = field(text, "formattingMarks") == "0"
            let ok = sameSegments && quietened && text.contains("\"mode\":\"expanded\"")
            FileHandle.standardError.write(
                Data("SELFTEST modes=\(ok ? "OK" : "MISMATCH") segments agree=\(sameSegments) expanded marks=\(field(text, "formattingMarks") ?? "?")\n".utf8))
            if !ok { exit(8) }
            self.snapshot(named: "expanded") { self.runDisclosureSelftest() }
        }
    }

    /// DEC-036: one screen serves both first run and a root that has been moved, so there is no
    /// state in which the window is empty with nothing to act on. No suggested path appears here —
    /// the amendment rejected both that and auto-detection, in favour of predictability.
    private func buildEmptyState() {
        let title = NSTextField(labelWithString: "No folders chosen yet")
        title.font = Theme.prose(Theme.emptyStateTitleSize, weight: .medium)

        emptyStateDetail = NSTextField(wrappingLabelWithString:
            "Choose a folder and DiffScope will look inside it for Git repositories. "
            + "You can add as many folders as you like, and add single repositories from anywhere.")
        emptyStateDetail.font = Theme.prose(Theme.textSize)
        emptyStateDetail.textColor = Theme.inkQuiet
        emptyStateDetail.alignment = .center
        emptyStateDetail.preferredMaxLayoutWidth = Theme.emptyStateMaximumWidth - 2 * Theme.space6 - Theme.space4

        let chooseFolder = NSButton(title: "Choose a Folder…", target: self,
                                    action: #selector(addRootFolder))
        chooseFolder.keyEquivalent = "\r"
        let chooseRepository = NSButton(title: "Add a Single Repository…", target: self,
                                        action: #selector(addRepository))
        let buttons = NSStackView(views: [chooseFolder, chooseRepository])
        buttons.orientation = .horizontal
        buttons.spacing = Theme.space6 - Theme.space2

        let stack = NSStackView(views: [title, emptyStateDetail, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Theme.space6

        emptyState = NSView()
        emptyState.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyState.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: Theme.emptyStateMaximumWidth),
        ])
        emptyState.isHidden = true
    }

    private func showEmptyState(problems: [InspectedSource]) {
        if problems.isEmpty {
            emptyStateDetail.stringValue =
                "Choose a folder and DiffScope will look inside it for Git repositories. "
                + "You can add as many folders as you like, and add single repositories from anywhere."
        } else {
            // Named rather than quietly forgotten: the user is the only one who can tell a moved
            // folder from one they no longer want.
            let list = problems.map { "\($0.source.path) — \($0.state.rawValue)" }.joined(separator: "\n")
            emptyStateDetail.stringValue =
                "Everything you have added is currently unreachable, so there is nothing to show:\n\n"
                + list + "\n\nThey are still configured. Choose them again if they moved, "
                + "or use Sources ▸ Remove Source."
        }
        emptyState.isHidden = false
        splitView.isHidden = true
        statusLabel.stringValue = problems.isEmpty ? "no folders chosen" : "no reachable sources"
    }

    private func hideEmptyState() {
        emptyState.isHidden = true
        splitView.isHidden = false
    }

    /// DEC-037: every configured source, merged into one list. Depth 2 applies per root (DEC-018);
    /// individually added repositories bypass scanning, which is also the answer for a repository
    /// nested deeper than the limit would ever reach.
    private func scan(sources: [ConfiguredSource]) {
        let inspected = configStore.inspect(Configuration(sources: sources))
        let unusable = inspected.filter { $0.state != .present }
        state.sourceProblems = unusable

        // A folder the reader chose that holds no repositories has to say so. Showing three empty
        // panes leaves them wondering whether the application is broken or their folder is empty —
        // the first thing a stranger meets if they pick the wrong directory (G3).
        func explainEmptyResult(_ count: Int) -> Bool {
            guard count == 0, !sources.isEmpty, unusable.count < sources.count else { return false }
            self.state.repositories = []
            self.repoTable.reloadData()
            self.emptyStateDetail.stringValue =
                noRepositoriesFoundMessage(paths: sources.map(\.path),
                                           depth: self.discovery.maximumDepth)
            self.emptyState.isHidden = false
            self.splitView.isHidden = true
            self.statusLabel.stringValue = "no repositories found"
            return true
        }

        guard !sources.isEmpty, unusable.count < sources.count else {
            // Nothing configured, or nothing that still exists. Either way the reader needs the
            // picker rather than an empty table with no explanation (DEC-036, `12-…` §7.5).
            DispatchQueue.main.async {
                self.state.repositories = []
                self.repoTable.reloadData()
                self.showEmptyState(problems: unusable)
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let found = self.discovery.discover(sources: sources.map(\.discoverySource))
            let sweep = RepositorySweep(reader: self.reader)
            let outcome = sweep.run(over: found.repositories.map(\.url),
                                    baseOverrides: self.state.configuration.baseOverrides)
            let labels = disambiguatedNames(for: outcome.snapshots.map(\.url.path))
            DispatchQueue.main.async {
                guard !explainEmptyResult(outcome.snapshots.count) else { return }
                self.state.repositories = outcome.snapshots
                self.state.repositoryLabels = labels
                self.hideEmptyState()
                self.repoTable.reloadData()
                var summary = String(format: "%d repositories from %d sources · swept in %.0f ms",
                                     outcome.snapshots.count, sources.count - unusable.count,
                                     outcome.elapsedSeconds * 1000)
                // A missing root is named, not dropped: a source that vanishes from the list looks
                // exactly like one that was never added.
                if !unusable.isEmpty {
                    summary += " · " + unusable.map { "\($0.source.path) \($0.state.rawValue)" }
                        .joined(separator: ", ")
                }
                self.statusLabel.stringValue = summary
                // Opening onto three empty panes makes the reader click before the application has
                // said anything. Selecting after the summary, not before, so that whatever the
                // selection has to say — an unavailable scope, for instance — is what stays on
                // screen rather than being overwritten by the sweep's own line.
                if self.state.selectedRepository == nil, !outcome.snapshots.isEmpty {
                    self.repoTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
            }
        }
    }

    private func rescan() {
        var sources = state.configuration.sources
        if let hook = ProcessInfo.processInfo.environment["DIFFSCOPE_ROOT"],
           !sources.contains(where: { $0.path == hook }) {
            sources.append(ConfiguredSource(kind: .root, path: hook))
        }
        scan(sources: sources)
    }

    private func add(kind: ConfiguredSource.Kind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = kind == .root
        panel.prompt = kind == .root ? "Add Root Folder" : "Add Repository"
        panel.message = kind == .root
            ? "Choose a folder to scan for Git repositories."
            : "Choose a Git repository."
        // No default directory is offered. DEC-036's amendment rejected both a suggested path and
        // auto-detection, in favour of predictability over convenience.
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let source = ConfiguredSource(kind: kind, path: url.standardizedFileURL.path)
            guard !state.configuration.sources.contains(source) else { continue }
            state.configuration.sources.append(source)
        }
        if let problem = configStore.save(state.configuration) {
            statusLabel.stringValue = problem
        }
        rescan()
    }

    /// DEC-009: the detected base is overridable per repository, and the override is stored in
    /// application configuration — never written into the repository.
    @objc private func setBaseBranch() {
        guard let repository = state.selectedRepository else {
            statusLabel.stringValue = "select a repository first"
            return
        }
        let key = repository.url.standardizedFileURL.path
        let alert = NSAlert()
        alert.messageText = "Base branch for \(repository.displayName)"
        alert.informativeText = "Detected: \(repository.baseRefUsed ?? "none — detection did not resolve"). "
            + "Leave empty to go back to detection."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: Theme.filePaneWidth - 2 * Theme.space6 - 2 * Theme.space4, height: Theme.space6 + Theme.space4))
        field.stringValue = state.configuration.baseOverrides[key] ?? ""
        field.placeholderString = "origin/main"
        alert.accessoryView = field
        alert.addButton(withTitle: "Use This")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let entered = field.stringValue.trimmingCharacters(in: .whitespaces)
        if entered.isEmpty {
            state.configuration.baseOverrides.removeValue(forKey: key)
        } else {
            state.configuration.baseOverrides[key] = entered
        }
        if let problem = configStore.save(state.configuration) { statusLabel.stringValue = problem }
        // Re-swept rather than patched: the merge-base and the ahead count both depend on the ref,
        // and recomputing them is the only way to keep the row honest.
        rescan()
    }

    /// `12-…` §5.4: wrapping is *available*, not compulsory. Forced wrapping pushes the two panes
    /// out of vertical alignment on exactly the minified files that section was written about.
    @objc private func toggleWrap() {
        wrapEnabled.toggle()
        wrapMenuItem?.state = wrapEnabled ? .on : .off
        webView.evaluateJavaScript("window.diffscopeSetWrap(\(wrapEnabled))") { _, _ in }
        statusLabel.stringValue = wrapEnabled ? "long lines wrap" : "long lines scroll horizontally"
    }

    @objc private func addRootFolder() { add(kind: .root) }
    @objc private func addRepository() { add(kind: .repository) }

    /// Removes whichever source the selected repository came from, or the selected missing source
    /// when the empty state is showing.
    @objc private func removeSource() {
        let selectedPath = state.selectedRepository?.url.path
        let match = state.configuration.sources.first { source in
            guard let selectedPath else { return false }
            return selectedPath == source.path || selectedPath.hasPrefix(source.path + "/")
        } ?? state.sourceProblems.first?.source

        guard let match else {
            statusLabel.stringValue = "select a repository to remove the source it came from"
            return
        }
        state.configuration.sources.removeAll { $0 == match }
        if let problem = configStore.save(state.configuration) {
            statusLabel.stringValue = problem
        }
        state.selectedRepository = nil
        state.selectedFile = nil
        watcher?.stop()
        rescan()
        statusLabel.stringValue = "removed \(match.path)"
    }

    @objc private func scopeChanged() {
        state.scope = [.allLocalVsHead, .unstagedVsIndex, .stagedVsHead, .branchVsMergeBase][scopeControl.selectedSegment]
        reloadFiles()
    }

    /// DEC-016 commits to full keyboard operation of *every* function, so this is a map rather
    /// than a shortcut list: anything reachable only by pointer is a defect. The bindings live
    /// in the menu bar so they are discoverable and so macOS routes them regardless of focus.
    ///
    /// **The map is `KeyboardMap.bindings`, and this only draws it** (DEC-057). It used to be a
    /// hand-written list here, with the specification's coverage table in Markdown and nothing
    /// comparing the two — which is how *show raw for the current region* stayed specified,
    /// unimplemented and unreported from M6 to M8. A binding that is not in the map is now not in
    /// the menu, and a specified function with no binding fails the check suite.
    func buildMenu() {
        let main = NSMenu()

        for menu in KeyboardMenu.allCases {
            let hosting = NSMenuItem()
            let submenu = NSMenu(title: menu.title)
            for binding in KeyboardMap.bindings(in: menu) {
                // A separator before the scope block keeps the View menu readable; it is drawn from
                // the map's own ordering rather than being a row in it, since a separator is not a
                // function and DEC-016's rule is about functions.
                if binding.id == "scope.allLocal" { submenu.addItem(.separator()) }
                let item = submenu.addItem(withTitle: binding.title,
                                           action: selector(for: binding.id),
                                           keyEquivalent: binding.key)
                item.keyEquivalentModifierMask = modifierFlags(binding.modifiers)
                if binding.id != "quit" { item.target = self }
                if let tag = binding.tag { item.tag = tag }
                if binding.isToggle { item.state = initialToggleState(of: binding.id) }
                menuItems[binding.id] = item
            }
            hosting.submenu = submenu
            main.addItem(hosting)
        }

        wrapMenuItem = menuItems["wrap"]
        terminalMenuItem = menuItems["terminal"]
        terminalRawMenuItem = menuItems["terminal.raw"]
        rawRegionMenuItem = menuItems["rawRegion"]

        NSApplication.shared.mainMenu = main
    }

    /// The one place an identifier in the map becomes a method here. A binding whose identifier is
    /// unknown is a programming error rather than a missing feature, and it is loud: the menu item
    /// is drawn disabled, so it cannot look like a working function that quietly does nothing.
    private func selector(for id: String) -> Selector? {
        switch id {
        case "quit": return #selector(NSApplication.terminate(_:))
        case "mode.raw", "mode.structural", "mode.expanded": return #selector(selectMode(_:))
        case "rawRegion": return #selector(toggleRawForCurrentRegion)
        case "terminal": return #selector(toggleTerminal)
        case "terminal.raw": return #selector(toggleTerminalRawMode)
        case "terminal.follow": return #selector(followTerminalToSelection)
        case "wrap": return #selector(toggleWrap)
        case "scope.allLocal", "scope.unstaged", "scope.staged", "scope.base":
            return #selector(selectScope(_:))
        case "sources.addRoot": return #selector(addRootFolder)
        case "sources.addRepository": return #selector(addRepository)
        case "sources.remove": return #selector(removeSource)
        case "sources.baseBranch": return #selector(setBaseBranch)
        case "change.next": return #selector(nextChange)
        case "change.previous": return #selector(previousChange)
        case "expandAll": return #selector(expandAll)
        case "file.next": return #selector(nextFile)
        case "file.previous": return #selector(previousFile)
        case "repository.next": return #selector(nextRepository)
        case "repository.previous": return #selector(previousRepository)
        case "focus.repositories": return #selector(focusRepositories)
        case "focus.files": return #selector(focusFiles)
        case "focus.diff": return #selector(focusDiff)
        case "openInEditor": return #selector(openInEditor)
        default: return nil
        }
    }

    private func modifierFlags(_ modifiers: KeyboardModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        return flags
    }

    private func initialToggleState(of id: String) -> NSControl.StateValue {
        id == "wrap" ? .on : .off
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        modeControl.selectedSegment = sender.tag
        modeChanged()
    }

    @objc private func selectScope(_ sender: NSMenuItem) {
        scopeControl.selectedSegment = sender.tag
        scopeChanged()
    }

    @objc private func nextChange() { runCommand("nextChange") }
    @objc private func previousChange() { runCommand("previousChange") }
    @objc private func expandAll() { runCommand("expandAll") }

    private func runCommand(_ name: String) {
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeCommand(\"\(name)\"))") { value, _ in
            guard let text = value as? String, text != "null" else { return }
            self.statusLabel.stringValue = "\(name): \(text)"
        }
    }

    private func step(_ table: NSTableView, by delta: Int) {
        let count = numberOfRows(in: table)
        guard count > 0 else { return }
        guard let next = nextSelectableRow(in: table, from: table.selectedRow, delta: delta) else { return }
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    /// Where the reader is in the list, in the list's own terms.
    ///
    /// A 63-file working tree walked by keyboard gives no sense of progress otherwise: the rows
    /// scroll, and nothing says whether there are two files left or forty. Headers are excluded from
    /// both numbers, because they are not stops (DEC-033) and counting them would make the total
    /// disagree with the number of keystrokes it takes to reach the end.
    func filePositionText() -> String? {
        let files = state.fileRows.compactMap { $0.file }
        guard !files.isEmpty else { return nil }
        let row = fileTable.selectedRow
        guard row >= 0, row < state.fileRows.count, let selected = state.fileRows[row].file,
              let index = files.firstIndex(where: { $0.path == selected.path }) else {
            return "\(files.count) files"
        }
        return "file \(index + 1)/\(files.count)"
    }

    /// Off the main thread, because it stats and reads a few kilobytes per file and the list is
    /// already on screen by then. Only the repository still selected gets its badges applied.
    private func annotateFiles(of repository: RepositorySnapshot) {
        let files = state.files
        DispatchQueue.global(qos: .utility).async {
            var found: [String: FileAnnotation] = [:]
            for file in files {
                if let annotation = annotate(path: file.path, in: repository.url,
                                             sizeLimit: structuralSizeLimit) {
                    found[file.path] = annotation
                }
            }
            DispatchQueue.main.async {
                guard self.state.selectedRepository?.url == repository.url else { return }
                self.state.annotations = found
                self.fileTable.reloadData()
            }
        }
    }

    @objc private func nextFile() { step(fileTable, by: 1) }
    @objc private func previousFile() { step(fileTable, by: -1) }

    /// DEC-033: group headers are labels, not focus stops. Stepping past them keeps next/previous
    /// file one keystroke per *file* — otherwise grouping would silently make navigation longer.
    ///
    /// The walk itself is `RowNavigation.step`, in `DiffScopeGit` beside the row type, so a 63-file
    /// list can be walked without a window (M8-J).
    private func nextSelectableRow(in table: NSTableView, from row: Int, delta: Int) -> Int? {
        guard table === fileTable else {
            let count = numberOfRows(in: table)
            let candidate = row < 0 ? (delta > 0 ? 0 : count - 1) : row + delta
            guard candidate >= 0, candidate < count else { return nil }
            return candidate
        }
        return RowNavigation.step(rows: state.fileRows, from: row < 0 ? nil : row, delta: delta)
    }
    @objc private func nextRepository() { step(repoTable, by: 1) }
    @objc private func previousRepository() { step(repoTable, by: -1) }
    @objc private func focusRepositories() { moveFocus(to: repoTable, named: "repositories") }
    @objc private func focusFiles() { moveFocus(to: fileTable, named: "files") }
    @objc private func focusDiff() { moveFocus(to: webView, named: "diff") }

    /// Focus movement says where the keyboard went. Without it the three ⌥⌘ keys are indistinguishable
    /// from doing nothing, since a table with no selection draws no focus ring worth the name.
    private func moveFocus(to responder: NSResponder, named name: String) {
        window.makeFirstResponder(responder)
        let position = responder === fileTable ? filePositionText().map { " · \($0)" } ?? "" : ""
        statusLabel.stringValue = "keyboard: \(name)\(position)"
    }

    /// `12-…` §9: *show raw for the current region* — the last row of the coverage table, and the
    /// one that had no implementation at all until M8-J.
    ///
    /// Not a fourth mode. Change stops come from the **canonical diff** and are therefore the same
    /// set in every mode, so this switches to Raw on the same pinned pair and jumps back to the stop
    /// the reader was standing on; pressing it again returns to the mode it left. That is what makes
    /// it *the control view for this region* rather than a global toggle the reader has to re-navigate
    /// after using.
    @objc private func toggleRawForCurrentRegion() {
        guard state.selectedFile != nil else {
            statusLabel.stringValue = "raw for current region: no file selected"
            return
        }
        if let previous = rawRegionReturn {
            rawRegionReturn = nil
            rawRegionMenuItem?.state = .off
            apply(mode: previous.mode, restoringStop: previous.stop)
            return
        }
        guard state.mode != .raw else {
            statusLabel.stringValue = "raw for current region: already raw"
            return
        }
        let leaving = state.mode
        webView.evaluateJavaScript("window.diffscopeCommand(\"currentStop\")") { value, _ in
            let stop = (value as? Int) ?? (value as? NSNumber)?.intValue ?? -1
            self.rawRegionReturn = (mode: leaving, stop: stop)
            self.rawRegionMenuItem?.state = .on
            self.apply(mode: .raw, restoringStop: stop)
        }
    }

    /// Switches mode and puts the reader back on the same change stop once the new model has been
    /// rendered. The delay is a render, not a guess: `showDiff` reads the pair off the main thread.
    private func apply(mode: PresentationMode, restoringStop stop: Int) {
        state.mode = mode
        modeControl.selectedSegment = PresentationMode.allCases.firstIndex(of: mode) ?? 0
        guard let file = state.selectedFile else { return }
        showDiff(for: file, restoringStop: stop >= 0 ? stop : nil)
    }

    /// DEC-015: a configurable template, never populated from repository content — the template
    /// is user configuration and a repository is untrusted input. Failure is shown, not swallowed.
    @objc private func openInEditor() {
        guard let repository = state.selectedRepository, let file = state.selectedFile else {
            statusLabel.stringValue = "open in editor: no file selected"
            return
        }
        let template = ProcessInfo.processInfo.environment["DIFFSCOPE_EDITOR"]
            ?? EditorCommand.defaultTemplate
        let path = repository.url.appendingPathComponent(file.path).path

        // The line comes from the renderer, which is the only side that knows where the reader is
        // looking. It used to be a literal 1 — correct in the sense that it opened the file, and
        // useless on the 900-line file where the change is at the bottom.
        webView.evaluateJavaScript("window.diffscopeCurrentLine()") { value, _ in
            let line = (value as? Int) ?? (value as? NSNumber)?.intValue ?? 1
            guard let command = EditorCommand(template: template, file: path, line: max(1, line)) else {
                self.statusLabel.stringValue = "open in editor failed — the editor template is empty"
                return
            }
            // Waiting for the exit status is the point (F13), so it happens off the main thread: a
            // template that takes a second to return must not take the interface with it.
            self.statusLabel.stringValue = "opening \(file.path):\(line)…"
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = launchEditor(command, file: "\(file.path):\(line)")
                DispatchQueue.main.async { self.statusLabel.stringValue = outcome.message }
            }
        }
    }

    @objc private func modeChanged() {
        state.mode = PresentationMode.allCases[modeControl.selectedSegment]
        // Choosing a mode by hand ends the ⌥⌘V excursion: the reader has said where they want to
        // be, and a return key that took them somewhere else would be worse than none.
        rawRegionReturn = nil
        rawRegionMenuItem?.state = .off
        if let file = state.selectedFile { showDiff(for: file) }
    }

    private func reloadFiles() {
        guard let repository = state.selectedRepository else { return }
        var baseRef: String?
        state.mergeBaseRev = nil
        if state.scope == .branchVsMergeBase, let resolved = repository.base.ref {
            baseRef = repository.baseRefUsed ?? resolved
            if let ref = baseRef,
               let result = try? GitRunner().run(.mergeBase(ref, "HEAD"), in: repository.url),
               result.succeeded {
                state.mergeBaseRev = result.trimmedOutput
            }
        }
        // `12-…` §3: scopes that cannot work are **disabled with a stated reason, never hidden**.
        // Leaving them enabled lets the reader click into a dead end and makes the control lie
        // about what is available.
        for (index, scope) in ComparisonScope.allCases.enumerated() {
            let state = scopes.availability(of: scope, head: repository.head, base: repository.base)
            scopeControl.setEnabled(state == .available, forSegment: index)
            if case let .unavailable(reason) = state {
                scopeControl.setToolTip("\(scope.title) — \(reason)", forSegment: index)
            } else {
                scopeControl.setToolTip(scope.title, forSegment: index)
            }
        }

        let availability = scopes.availability(of: state.scope, head: repository.head, base: repository.base)
        if case let .unavailable(reason) = availability {
            state.files = []
            state.fileRows = []
            fileTable.reloadData()
            statusLabel.stringValue = "\(state.scope.title) unavailable — \(reason)"
            return
        }
        state.files = (try? scopes.changedFiles(scope: state.scope, in: repository.url, baseRef: baseRef)) ?? []
        state.fileRows = fileListRows(state.files,
                                      workspacePackages: declaredWorkspacePackages(in: repository.url))
        state.annotations = [:]
        fileTable.reloadData()
        annotateFiles(of: repository)
        // DEC-010/DEC-011: the age is the signal, not the date. The application never fetches, so
        // this line is the only thing telling the reader how old the comparison actually is.
        var ageText = ""
        if state.scope == .branchVsMergeBase {
            ageText = " · " + baseSummary(
                ref: repository.baseRefUsed,
                chosenByUser: state.configuration.baseOverrides[repository.url.standardizedFileURL.path] != nil,
                committerDate: repository.baseRefCommitterDate)
        }
        statusLabel.stringValue = "\(state.files.count) files · \(state.scope.title)\(ageText)"
    }

    private func showDiff(for file: ChangedFile, restoringStop stop: Int? = nil) {
        state.selectedFile = file
        render(file: file, previousAnchor: nil, restoringStop: stop)
    }

    /// A refresh asks the renderer where the reader is *before* rebuilding, because the answer is
    /// about the document currently on screen (DEC-034). The engine then decides where that anchor
    /// lands in the new model; the renderer only executes the decision.
    private func refreshCurrentFile() {
        guard let file = state.selectedFile else { return }
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeAnchorState())") { value, _ in
            var anchor: RefreshAnchor?
            if let text = value as? String, let data = text.data(using: .utf8) {
                anchor = try? JSONDecoder().decode(RefreshAnchor.self, from: data)
            }
            self.render(file: file, previousAnchor: anchor)
        }
    }

    private func render(file: ChangedFile, previousAnchor: RefreshAnchor?, restoringStop: Int? = nil) {
        guard let repository = state.selectedRepository else { return }
        let mode = state.mode
        // One at a time, and the newest wins. Walking a 63-file list at keyboard speed used to start
        // a render per keystroke on the concurrent queue: they raced inside the shared tree-sitter
        // parser (fixed in `TSXParser`), and the ones that survived pushed diffs for files the
        // reader had already walked past. Serialising is also the honest model of the work — only
        // the file now selected is worth rendering.
        renderQueue.async {
            guard let pair = try? self.scopes.pinnedPair(
                for: file, scope: self.state.scope, in: repository.url, mergeBaseRev: self.state.mergeBaseRev
            ) else { return }
            // DEC-049: the file was still being written, so these bytes may be half of one
            // version and half of another. Showing them with a warning would still be showing a
            // blend — the watcher fires again when the writing stops.
            guard pair.stable else {
                DispatchQueue.main.async {
                    self.statusLabel.stringValue =
                        "\(file.path) is being written — showing it once the file settles"
                }
                return
            }
            // DEC-028/DEC-041: asked here, on the file actually being shown, so an active filter is
            // disclosed where the discrepancy it causes is visible.
            let filterState = self.filters.state(for: file.path, in: repository.url)
            let external = filterState.disclosure.map { [Degradation.filterActive(reason: $0)] } ?? []
            let outcome = self.buildModel(path: file.path, old: pair.oldBytes, new: pair.newBytes,
                                          mode: mode, external: external)
            let render = buildRenderModel(
                model: outcome.model, pinOld: pair.oldHash, pinNew: pair.newHash,
                mode: mode.rawValue, validation: outcome.validation, notices: outcome.notices,
                previousAnchor: previousAnchor
            )
            guard let json = try? encodeRenderModel(render) else { return }
            DispatchQueue.main.async {
                // The reader may have moved on while this was being built. Pushing it anyway would
                // put one file's diff under another file's name.
                guard self.state.selectedFile?.path == file.path else { return }
                let position = self.filePositionText().map { "\($0) · " } ?? ""
                self.statusLabel.stringValue = "\(position)\(file.path) · \(outcome.summary)"
                if self.rendererReady { self.push(json) } else { self.pendingModel = json }
                // ⌥⌘V (DEC-057): the stop is restored *after* the new model is in the document,
                // because the stop list belongs to the model that is on screen.
                if let stop = restoringStop {
                    self.webView.evaluateJavaScript(
                        "JSON.stringify(window.diffscopeCommand(\"goToStopIndex:\(stop)\"))"
                    ) { value, _ in
                        guard let text = value as? String, text != "null" else { return }
                        let where_ = self.rawRegionReturn == nil ? "back to \(mode.rawValue)" : "raw"
                        self.statusLabel.stringValue =
                            "\(position)\(file.path) · \(where_) at this region · \(text)"
                    }
                }
            }
        }
    }

    /// DEC-007/DEC-027: one stream, on the repository being looked at, `node_modules` excluded.
    private func startWatching(_ repository: RepositorySnapshot) {
        watcher?.stop()
        let watcher = RepositoryWatcher(root: repository.url) { [weak self] signal in
            self?.handle(signal, in: repository)
        }
        self.watcher = watcher
        if !watcher.start() {
            statusLabel.stringValue = "auto-refresh unavailable for \(repository.displayName)"
        }
        for diagnostic in watcher.diagnostics {
            statusLabel.stringValue = diagnostic.message
        }
    }

    private func handle(_ signal: WatchSignal, in repository: RepositorySnapshot) {
        guard state.selectedRepository?.url == repository.url else { return }
        switch signal {
        case .changed, .rescan:
            let selected = state.selectedFile
            reloadFiles()
            // Selection survives where the file is still in scope, and says so where it is not.
            // Against the drawn rows, not the flat file array: with headers interleaved the two
            // indices differ, and restoring the flat index would land the reader on a neighbour.
            if let selected, state.files.contains(where: { $0.path == selected.path }) {
                if let row = state.fileRows.firstIndex(where: { $0.file?.path == selected.path }) {
                    fileTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                refreshCurrentFile()
            } else if selected != nil {
                statusLabel.stringValue = "\(selected!.path) is no longer in \(state.scope.title)"
            }
            if signal == .rescan {
                statusLabel.stringValue += " · rescanned after dropped file-system events"
            }
        case .rootChanged:
            statusLabel.stringValue = "\(repository.displayName) was moved or renamed — auto-refresh stopped"
            watcher?.stop()
        }
    }

    struct ModelOutcome {
        let model: DiffModel
        let validation: ValidationResult
        let notices: [String]
        let summary: String
    }

    /// Raw is never a degraded structural run: it is its own path on the same pinned pair.
    /// A structural result that fails validation is discarded whole and replaced by raw,
    /// carrying a notice — a fallback that is not visible is an INV-4 violation.
    ///
    /// - Parameter external: conditions detected outside the syntax layer, F8 above all (DEC-051).
    ///   They are disclosed in **every** mode, because a filter changes what the compared bytes
    ///   mean — Raw is not exempt from an explanation it is the reason for.
    func buildModel(path: String, old: [UInt8], new: [UInt8], mode: PresentationMode,
                    external: [Degradation] = []) -> ModelOutcome {
        let outside = Degradation.mostConservative(external)

        func rawOutcome(notices: [String], summary: String) -> ModelOutcome {
            let model = trivialModel(oldBytes: old, newBytes: new)
            return ModelOutcome(model: model, validation: validate(model),
                                notices: notices, summary: summary)
        }

        guard mode.usesStructure else {
            return rawOutcome(notices: outside.map { [$0.notice] } ?? [],
                              summary: outside.map { "raw — \($0.reason)" } ?? "raw")
        }

        let result = structuralDiff(oldPath: path, oldBytes: old, newPath: path, newBytes: new,
                                    parser: parser, external: external)
        if result.stats.usedFallback {
            let degradation = result.stats.degradation
                ?? .parseFailure(reason: "structural analysis unavailable")
            return ModelOutcome(model: result.model, validation: validate(result.model),
                                notices: [degradation.notice],
                                summary: "raw — \(degradation.reason)")
        }

        let validation = validate(result.model)
        guard validation.passed else {
            return rawOutcome(
                notices: [Degradation.invariantViolation(reason: validation.summary).notice],
                summary: "raw — structural result discarded"
            )
        }

        let stats = result.stats
        var summary = "structural · \(stats.anchors) anchors"
        if stats.movedSegments > 0 { summary += " · \(stats.movedSegments) moved" }
        if stats.formattingOnlySegments > 0 { summary += " · \(stats.formattingOnlySegments) formatting-only" }
        if stats.behaviorAffectingSegments > 0 { summary += " · \(stats.behaviorAffectingSegments) reordered" }
        if stats.invisibleSegments > 0 { summary += " · \(stats.invisibleSegments) invisible" }
        if stats.ambiguities > 0 { summary += " · \(stats.ambiguities) ambiguous" }
        // A structural run that succeeded can still carry a condition worth disclosing: byte-equal
        // sides under an active filter are shown as unchanged while the file list says changed.
        let carried = stats.degradation ?? outside
        return ModelOutcome(model: result.model, validation: validation,
                            notices: carried.map { [$0.notice] } ?? [],
                            summary: carried.map { "\(summary) · \($0.reason)" } ?? summary)
    }

    private func push(_ json: String) {
        let escaped = String(decoding: (try? JSONEncoder().encode(json)) ?? Data("\"\"".utf8), as: UTF8.self)
        webView.evaluateJavaScript("window.diffscopeRender(\(escaped))") { _, error in
            if let error { self.statusLabel.stringValue = "render error: \(error)" }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === repoTable ? state.repositories.count : state.fileRows.count
    }

    /// Returns a cell view with the label constrained inside it.
    ///
    /// A bare `NSTextField` was returned here before, and **every row rendered blank** — the label
    /// was left at zero width, so a middle-truncating label truncated the whole string away. The
    /// window looked like a working application with an empty repository list, which is why it
    /// survived: nothing crashed, the counts in the status line were right, and the check suite
    /// cannot see the screen.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        text.font = Theme.font(Theme.textSizeSmall)
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.space2),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Theme.space2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if tableView === repoTable {
            let snapshot = state.repositories[row]
            let ahead = snapshot.aheadCount.map { "↑\($0)" } ?? "↑?"
            let label = state.repositoryLabels[snapshot.url.path] ?? snapshot.displayName
            text.stringValue = "\(label)  ·  \(snapshot.uncommittedCount)△ \(ahead)"
            text.toolTip = "\(snapshot.url.path)\n\(snapshot.head.displayText)\n\(snapshot.baseRefUsed ?? "base: prompt")"
        } else {
            switch state.fileRows[row] {
            case let .header(title):
                text.stringValue = title
                text.textColor = Theme.inkQuiet
                text.font = Theme.font(Theme.textSizeTiny, weight: .semibold)
                text.lineBreakMode = .byTruncatingHead
                text.toolTip = title
            case let .file(file, display):
                // The badge says what the list could work out cheaply; the diff view says the rest
                // (`12-…` §4 asks the list to carry degradation state).
                let badge = state.annotations[file.path].map { " · \($0.badge)" } ?? ""
                text.stringValue = "\(file.kind.rawValue.prefix(3))  \(display)\(badge)"
                // The full path stays one hover away, since the row no longer shows all of it.
                text.toolTip = file.path
            }
        }
        return cell
    }

    /// DEC-033 says headers are labels rather than focus stops, and until M8-J only ⌘] / ⌘[ obeyed
    /// it. An arrow key — the ordinary way anyone walks a 63-file list — landed on a header, where
    /// the selection handler returned without a word and the diff pane went on showing the previous
    /// file. Refusing the selection at the source makes every route agree: arrows, clicks, ⌘].
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView === fileTable else { return true }
        return RowNavigation.isSelectable(rows: state.fileRows, row: row)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === repoTable {
            guard table.selectedRow >= 0 else { return }
            let repository = state.repositories[table.selectedRow]
            state.selectedRepository = repository
            startWatching(repository)
            followTerminalIfPossible(repository)
            reloadFiles()
        } else {
            guard table.selectedRow >= 0, table.selectedRow < state.fileRows.count,
                  let file = state.fileRows[table.selectedRow].file else { return }
            showDiff(for: file)
        }
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
