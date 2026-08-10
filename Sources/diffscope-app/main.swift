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

enum Lens: String { case diff, blame, history }

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
    /// The last search and its hits (DEC-062). Kept on the state rather than in the view, so a
    /// refresh can decide what to do with them — today it replaces them with the file list, which
    /// is the honest answer: the hits were computed against bytes that have just changed.
    /// Which question the pane is answering (DEC-061). Not a mode and not a scope: the file and
    /// the pinned pair are the same in all three.
    var lens: Lens = .diff
    var searchQuery = ""
    var searchMatchCase = false
    var searchHits: [SearchHit] = []
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
    /// The sentence stating which convention the uncommitted counts use (`12-…` §2).
    var conventionLabel: NSTextField!
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
    /// What the last ⌘⏎ did, shown in Preferences. F13's failure is visible on the status line the
    /// moment it happens and gone by the time the reader opens the settings to fix it.
    var lastEditorAttempt: String?
    var lensMenuItems: [String: NSMenuItem] = [:]
    var sideBySideMenuItem: NSMenuItem?
    /// DEC-059: the window opens unified, so this starts false.
    var sideBySide = false
    /// DEC-060: each region collapses on its own. Collapsed is **reduced, not hidden** — the rail
    /// still says which repositories there are and which have work in them, the spine still says
    /// how many files changed and how big each change is.
    var reposCollapsed = false
    var filesCollapsed = false
    var reposCollapseMenuItem: NSMenuItem?
    var filesCollapseMenuItem: NSMenuItem?
    var repoPaneWidth: NSLayoutConstraint?
    var filePaneWidth: NSLayoutConstraint?
    var repoPaneMinimum: NSLayoutConstraint?
    var filePaneMinimum: NSLayoutConstraint?
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
        // A selftest that reads the developer's own configuration is not a selftest of anything
        // repeatable. It also loses: the startup sweep of whatever repositories happen to be on
        // this machine finished *after* the keyboard arm's own scan and replaced the fixture tree
        // with them, so the arm reported a 63-file tree as empty. The arms bring their own sources.
        if ProcessInfo.processInfo.environment["DIFFSCOPE_SELFTEST"] != nil {
            state.configuration = Configuration(sources: [])
            if let tree = ProcessInfo.processInfo.environment["DIFFSCOPE_KEYBOARD_TREE"] {
                state.configuration = Configuration(sources: [ConfiguredSource(kind: .repository, path: tree)])
            }
            scan(sources: state.configuration.sources)
            return
        }
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

        let middleScroll = scrollWrapping(fileTable)

        // `12-…` §2: the uncommitted count *"must state which convention it uses"*. On screen,
        // under the counts it describes, rather than in a tooltip or a document the reader does
        // not have. The sentence comes from the Git layer, beside the operation it is about.
        conventionLabel = NSTextField(labelWithString: RepositoryReader.uncommittedCountConvention)
        // A sentence, so the proportional face rather than the monospace the paths use — it fits
        // the pane in two lines instead of three, and the third was being clipped.
        conventionLabel.font = Theme.prose(Theme.textSizeTiny)
        conventionLabel.textColor = Theme.inkQuiet
        conventionLabel.maximumNumberOfLines = 2
        conventionLabel.lineBreakMode = .byWordWrapping
        conventionLabel.preferredMaxLayoutWidth = Theme.repositoryPaneWidth - 2 * Theme.space3
        // Both priorities, or the sentence vanishes: a stack view will happily give a label zero
        // height next to a scroll view that grows without limit, and it did — the first version of
        // this pane rendered the caption at three lines with the third clipped, and squeezed it out
        // of existence entirely when the text got shorter. M8-D's defect class, one pane over.
        conventionLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        conventionLabel.setContentHuggingPriority(.required, for: .vertical)
        let repoScroll = scrollWrapping(repoTable)
        let leftStack = NSStackView(views: [repoScroll, conventionLabel])
        // The caption under the repository list sits on the list's own surface, not on the
        // window's: it belongs to that pane and the seam would say otherwise (`--ds-panel-repos`).
        leftStack.wantsLayer = true
        leftStack.layer?.backgroundColor = Theme.panelRepositories.cgColor
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = Theme.space2
        leftStack.edgeInsets = NSEdgeInsets(top: 0, left: Theme.space3, bottom: Theme.space3, right: Theme.space3)
        // Without this the scroll view's own content width becomes the pane's floor, and a 44 px
        // rail comes out at 87: the constraint said 44, the constant read 44, and the window drew
        // twice that. A check on the constant would have agreed with the wrong number.
        repoScroll.translatesAutoresizingMaskIntoConstraints = false
        repoScroll.widthAnchor.constraint(equalTo: leftStack.widthAnchor,
                                          constant: -2 * Theme.space3).isActive = true
        let leftScroll = leftStack

        let controls = NSStackView(views: [scopeControl, modeControl])
        controls.orientation = .horizontal
        controls.spacing = Theme.space6 - Theme.space2

        let rightStack = NSStackView(frame: NSRect(x: 0, y: 0, width: Theme.windowWidth - Theme.repositoryPaneWidth - Theme.filePaneWidth, height: Theme.windowHeight))
        rightStack.setViews([controls, statusLabel, webView], in: .leading)
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = Theme.space3
        rightStack.edgeInsets = NSEdgeInsets(top: Theme.space4, left: Theme.space4, bottom: 0, right: Theme.space4)
        // `--ds-chrome`: the band holding the scope bar, the mode control and the status line is
        // one surface, distinct from both lists and from the diff.
        rightStack.wantsLayer = true
        rightStack.layer?.backgroundColor = Theme.chrome.cgColor
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
        //
        // The minimum is *required* while a pane is full and dropped while it is collapsed
        // (DEC-060): a rail is 44 px wide and a floor of 140 would quietly refuse to draw it.
        var widthConstraints: [NSLayoutConstraint] = []
        var minimumConstraints: [NSLayoutConstraint] = []
        for (pane, width) in [(leftScroll, Theme.repositoryPaneWidth), (middleScroll, Theme.filePaneWidth)] {
            pane.translatesAutoresizingMaskIntoConstraints = false
            let constraint = pane.widthAnchor.constraint(equalToConstant: width)
            // 999, not 600: the divider stays draggable (that needs a priority below required),
            // and a collapse wins against whatever the pane's own content would rather be. At 600
            // the repository rail collapsed and the file spine did not, which is worse than
            // neither — half a layout is a layout nobody designed.
            constraint.priority = NSLayoutConstraint.Priority(999)
            constraint.isActive = true
            widthConstraints.append(constraint)
            let minimum = pane.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.paneMinimumWidth)
            minimum.isActive = true
            minimumConstraints.append(minimum)
        }
        repoPaneWidth = widthConstraints[0]
        filePaneWidth = widthConstraints[1]
        repoPaneMinimum = minimumConstraints[0]
        filePaneMinimum = minimumConstraints[1]
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
        // Alternating rows were the only surface distinction the two lists had. The design gives
        // each list its own background (`--ds-panel-repos`, `--ds-panel-files`) and one selection
        // treatment, so the stripes go: two systems saying "this row is different from that one"
        // is one system too many.
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = identifier == "repo" ? Theme.panelRepositories : Theme.panelFiles
        table.selectionHighlightStyle = .regular
        // One column, so "last" is "the one": it grows and shrinks with the pane, which is what a
        // collapse needs (DEC-060).
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // `.plain`, because the automatic style is `.inset` on modern macOS: it adds a 16 pt
        // margin on each side and a 17 pt intercell spacing, and with one column that is 16 pt of
        // padding before the only cell. In a 44 px rail it consumed half the row — `kbt•` was set
        // on the row and `kb` was drawn. Measured rather than guessed: the cell reported its frame
        // 16 pt inside a 32 pt clip view.
        table.style = .plain
        table.intercellSpacing = NSSize(width: Theme.space2, height: 0)
        // The document view keeps whatever width it was last given; the clip view then shows a
        // window onto the middle of it. Tying the width to the clip is what makes a collapsed
        // pane show the *start* of each row rather than the middle.
        table.autoresizingMask = [.width]
        return table
    }

    private func scrollWrapping(_ view: NSView) -> NSScrollView {
        // A non-zero starting frame matters: NSSplitView distributes space by *preserving the
        // proportions of the frames it already has*, so panes that begin at zero width stay at
        // zero width no matter how wide the split becomes.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Theme.repositoryPaneWidth, height: Theme.windowHeight))
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        return scroll
    }

    /// Selftest lines go to stderr for the arms to read, and a normal launch is not an arm — a
    /// person starting the application should not be told `SELFTEST renderer=index.html` before
    /// their window appears.
    private func selftestLog(_ line: String) {
        guard ProcessInfo.processInfo.environment["DIFFSCOPE_SELFTEST"] != nil else { return }
        FileHandle.standardError.write(Data(line.utf8))
    }

    private func loadRenderer() {
        guard let html = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Renderer") else {
            // Not gated: a missing renderer bundle is a real failure of a real launch, and the
            // window can only say so in a status line nobody may be looking at.
            statusLabel.stringValue = "renderer bundle missing"
            FileHandle.standardError.write(Data("SELFTEST renderer=MISSING\n".utf8))
            if ProcessInfo.processInfo.environment["DIFFSCOPE_SELFTEST"] != nil { exit(2) }
            return
        }
        selftestLog("SELFTEST renderer=\(html.lastPathComponent)\n")
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
                                      mode: "structural", pathTaken: outcome.pathTaken,
                                      parser: outcome.parser, validation: outcome.validation,
                                      notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(5) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            // The parser-state indicator (`12-…` §5.2) has to reach the *document*: it is the
            // seventh of seven and the last to be built, and its whole purpose is that a reader
            // no longer infers the parse state from the presence of some other notice.
            let ok = text.contains("pinC:pinD")
                && text.contains("formatting-only")
                && text.contains("parser: parsed")
                && text.contains("mode: structural")
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
                                      mode: "structural", pathTaken: outcome.pathTaken,
                                      parser: outcome.parser, validation: outcome.validation,
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
                                      mode: "structural", pathTaken: outcome.pathTaken,
                                      parser: outcome.parser, validation: outcome.validation,
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
                                          mode: "structural", pathTaken: outcome.pathTaken,
                                      parser: outcome.parser, validation: outcome.validation,
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
                                      mode: "structural", pathTaken: outcome.pathTaken,
                                      parser: outcome.parser, validation: outcome.validation,
                                      notices: outcome.notices)
        guard let json = try? encodeRenderModel(render) else { exit(20) }
        push(json)
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
            let text = (value as? String) ?? "nil"
            // The pill and the parser chip both have to disagree with the reader's selection here,
            // which is the case `23b-…` §2 recorded and nothing enforced: the reader asked for
            // structural, the file was never parsed, and the interface used to say `mode:
            // structural` with no qualification whatsoever.
            let ok = text.contains("Structural analysis unavailable")
                && text.contains("git status")
                && text.contains("All textual differences are shown")
                && text.contains("mode: structural — showing raw")
                && text.contains("parser: not parsed")
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
                                      mode: "structural", pathTaken: outcome.pathTaken,
                                      parser: outcome.parser, validation: outcome.validation,
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
                    if ok { self.runUnifiedSelftest() } else { exit(23) }
                }
            }
        }
    }

    /// DEC-059: the default layout, asked of the live document. The model is the gutter arm's —
    /// one line changed out of twelve — so the unified projection must show that line twice, once
    /// removed and once added, and the rest exactly once.
    ///
    /// What this arm is really for is the greyscale rule. Side-by-side separates direction by
    /// pane; unified has no panes, so if the sign column is ever empty the two directions differ
    /// by hue alone and the product is lying in a screenshot.
    private func runUnifiedSelftest() {
        webView.evaluateJavaScript("window.diffscopeSetLayout(\"unified\")") { _, _ in
            self.webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
                let text = (value as? String) ?? "nil"
                let data = Data(text.utf8)
                let probe = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let signs = probe["signs"] as? Int ?? 0
                let added = probe["addedLines"] as? Int ?? 0
                let removed = probe["removedLines"] as? Int ?? 0
                let doc = probe["unifiedText"] as? String ?? ""
                // Thirteen lines for twelve, because the changed one appears on both sides; the
                // sign column has one more marker than that, for the empty line a trailing
                // newline leaves behind.
                let lines = probe["unifiedLines"] as? Int ?? -1
                let ok = probe["layout"] as? String == "unified"
                    && lines == 13 && signs == lines + 1 && added == 1 && removed == 1
                    && doc.contains("value7 = 7;") && doc.contains("value7 = 77;")
                FileHandle.standardError.write(Data(
                    ("SELFTEST unified=\(ok ? "OK" : "MISMATCH") signs=\(signs) added=\(added) "
                        + "removed=\(removed) lines=\(lines) "
                        + "glyphs=\(probe["signGlyphs"] as? String ?? "?")\n").utf8))
                self.snapshot(named: "unified") {
                    guard ok else { exit(24) }
                    // Back to two panes: every arm after this one probes two documents, and the
                    // audit that follows must see the marks the reader sees.
                    self.webView.evaluateJavaScript("window.diffscopeSetLayout(\"split\")") { _, _ in
                        self.runStyleAuditSelftest()
                    }
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
        // The **configuration** is pointed at the tree, not just this one sweep. DEC-006 refreshes
        // the list when the window becomes active, and that refresh reads the configuration — so a
        // scan of the tree alone was being replaced by the reader's real repositories a second
        // later, and the arm then reported a tree with no changes in it. The race was invisible
        // until two arms were added ahead of this one and it started losing.
        state.configuration = Configuration(sources: [ConfiguredSource(kind: .repository, path: tree)])
        scan(sources: state.configuration.sources)
        // A sweep already in flight when this one starts still finishes, and finishing later means
        // winning: the startup sweep of the reader's own configuration replaced the fixture tree a
        // second after it was scanned, and the arm reported a tree with no changes in it. So the
        // arm waits for the list to *be* the tree rather than assuming its own scan was the last
        // word. Invisible until two arms were added ahead of this one and the timing shifted.
        waitForTree(tree, attemptsLeft: 40) {
        // The sweep is off the main thread; the walk needs the list it produces.
        self.waitForFiles(attemptsLeft: 40) { files in
            guard files == 63 else {
                FileHandle.standardError.write(Data(
                    ("SELFTEST keyboard=MISMATCH the tree has \(files) changed files, not 63 "
                        + "repos=\(self.state.repositories.count) selected=\(self.state.selectedRepository?.url.lastPathComponent ?? "none") "
                        + "rows=\(self.state.fileRows.count) scope=\(self.state.scope)\n").utf8))
                exit(40)
            }
            self.walkTheFileList()
        }
        }
    }

    private func waitForTree(_ tree: String, attemptsLeft: Int, then next: @escaping () -> Void) {
        if state.repositories.count == 1, state.repositories[0].url.path == tree {
            next(); return
        }
        guard attemptsLeft > 0 else {
            FileHandle.standardError.write(Data(
                ("SELFTEST keyboard=MISMATCH the list never became the fixture tree — "
                    + "\(state.repositories.map { $0.url.lastPathComponent })\n").utf8))
            exit(40)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.scan(sources: self.state.configuration.sources)
            self.waitForTree(tree, attemptsLeft: attemptsLeft - 1, then: next)
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
            // ⌥↓ since DEC-065 re-cut the map: the file tier of the three movement tiers. This
            // was ⌘] and the walk kept passing with the old key bound to nothing, which is why the
            // press is asserted rather than merely sent.
            guard press(key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                        modifiers: [.option, .function, .numericPad], keyCode: 125) else { break }
            // The end of the list is where the selection stops moving; ⌥↓ does not wrap, which is
            // itself the behaviour under test. That last press is a probe for the end rather than a
            // step, so it is not counted.
            guard fileTable.selectedRow != before else { break }
            keystrokes += 1
            record()
        }
        let distinct = Set(visited).count
        let menuOK = distinct == 63 && headerStops == 0 && keystrokes == 62
        FileHandle.standardError.write(Data(
            ("SELFTEST keyboard=\(menuOK ? "OK" : "MISMATCH") ⌥↓ visited \(distinct) of 63 files in "
                + "\(keystrokes) keystrokes past \(headers) headers, \(headerStops) blind stops\n").utf8))
        guard menuOK else { exit(41) }

        // The bare arrow keys, through the table's own key handling rather than through the menu.
        // `shouldSelectRow` is what makes them agree with the menu route; before it, ↓ selected headers and the diff pane kept showing the last file.
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

    /// ⌘R since DEC-065 (⌥⌘V when M8-J built it): the row of `12-…` §9 that had no implementation
    /// at all before that milestone. The same region, shown raw, and the mode it left restored on
    /// the second press.
    private func rawForCurrentRegionSelftest() {
        guard let modified = state.fileRows.compactMap({ $0.file }).first(where: { $0.kind == .modified }),
              let row = state.fileRows.firstIndex(where: { $0.file?.path == modified.path }) else {
            FileHandle.standardError.write(Data("SELFTEST keyboard-raw-region=MISMATCH no modified file\n".utf8))
            exit(43)
        }
        fileTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        fileTable.scrollRowToVisible(row)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard self.press(key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                             modifiers: [.command, .function, .numericPad], keyCode: 125) else { exit(43) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.webView.evaluateJavaScript("window.diffscopeCommand(\"currentStop\")") { value, _ in
                    let before = (value as? Int) ?? (value as? NSNumber)?.intValue ?? -1
                    guard self.press(key: "r", modifiers: [.command]) else { exit(44) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        self.webView.evaluateJavaScript("window.diffscopeCommand(\"currentStop\")") { raw, _ in
                            let inRaw = (raw as? Int) ?? (raw as? NSNumber)?.intValue ?? -1
                            let ok = self.state.mode == .raw && inRaw == before && before >= 0
                            FileHandle.standardError.write(Data(
                                ("SELFTEST keyboard-raw-region=\(ok ? "OK" : "MISMATCH") mode="
                                    + "\(self.state.mode.rawValue) stop \(before) → \(inRaw)\n").utf8))
                            guard ok else { exit(45) }
                            guard self.press(key: "r", modifiers: [.command]) else { exit(46) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                let returned = self.state.mode == .structural
                                FileHandle.standardError.write(Data(
                                    ("SELFTEST keyboard-return=\(returned ? "OK" : "MISMATCH") the second "
                                        + "press returns to \(self.state.mode.rawValue)\n").utf8))
                                guard returned else { exit(47) }
                                self.windowSnapshot(named: "keyboard") { self.collapseSelftest() }
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
    private func press(key: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = 0) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode
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
                                      mode: "structural", pathTaken: outcome.pathTaken,
                                      parser: outcome.parser, validation: outcome.validation,
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
                                      mode: "expanded", pathTaken: outcome.pathTaken,
                                      parser: outcome.parser, validation: outcome.validation,
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
    /// DEC-060, photographed rather than asserted. Both lists collapsed with 63 files in the tree
    /// is the worst case for width, and the question a check cannot answer is whether the rail and
    /// the spine still say anything — three letters and a kind glyph are the smallest claims in
    /// the window.
    private func collapseSelftest() {
        guard press(key: "0", modifiers: [.control, .command]) else { exit(48) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // The **drawn** widths. A constraint's constant is what was asked for: at priority 600
            // the file pane ignored it and stayed at 320 while the rail obeyed, and an assertion on
            // the constants would have called that a pass.
            let railDrawn = self.repoTable.enclosingScrollView?.superview?.frame.width ?? -1
            let spineDrawn = self.fileTable.enclosingScrollView?.frame.width ?? -1
            let ok = self.reposCollapsed && self.filesCollapsed
                && abs(railDrawn - Theme.railWidth) < 1 && abs(spineDrawn - Theme.spineWidth) < 1
            // The **drawn** widths, not the constants. A constraint's constant is what was asked
            // for; the pane is what the window did with it, and the two disagreed by a factor of
            // two until the scroll view stopped setting the floor. Asserting the constant would
            // have been a check that agreed with the wrong number.
            let repoCell = self.repoTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView
            let fileCell = self.fileTable.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView
            // The row has to start where the pane does. `.inset` — the automatic table style —
            // put the cell 16 pt in, and the rail then drew two letters of the three that separate
            // one repository from another. Asserted rather than eyeballed, because the picture is
            // the only other thing that can see it.
            let field = repoCell?.textField
            let fieldInWindow = field.map { $0.convert($0.bounds, to: nil) } ?? .zero
            let paneOrigin = self.repoTable.enclosingScrollView?.convert(NSPoint.zero, to: nil).x ?? 0
            let indent = fieldInWindow.minX - paneOrigin
            let indented = indent >= 0 && indent <= Theme.space4
            FileHandle.standardError.write(Data(
                ("SELFTEST collapse=\(ok && indented ? "OK" : "MISMATCH") rail=\(railDrawn) "
                    + "spine=\(spineDrawn) indent=\(indent) "
                    + "repoRow=\(repoCell?.textField?.stringValue ?? "nil")"
                    + "@\(fieldInWindow.width) "
                    + "fileRow=\(fileCell?.textField?.stringValue ?? "nil")\n").utf8))
            guard ok, indented else { exit(48) }
            self.windowSnapshot(named: "collapsed") { self.lensSelftest() }
        }
    }

    /// DEC-061, end to end against the fixture tree: a real repository with one commit and 63
    /// modified files, so blame has both committed lines and lines that are not committed yet —
    /// the state the parser's all-zero sha exists for, and the one a repository will not produce
    /// on demand when you want it.
    private func lensSelftest() {
        guard press(key: "b", modifiers: [.control, .command]) else { exit(49) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
                let probe = ((try? JSONSerialization.jsonObject(
                    with: Data(((value as? String) ?? "{}").utf8))) as? [String: Any]) ?? [:]
                let rows = probe["lensRows"] as? Int ?? 0
                let uncommitted = probe["lensUncommitted"] as? Int ?? 0
                let ok = rows > 0 && uncommitted > 0
                FileHandle.standardError.write(Data(
                    ("SELFTEST lens-blame=\(ok ? "OK" : "MISMATCH") rows=\(rows) "
                        + "uncommitted=\(uncommitted)\n").utf8))
                self.snapshot(named: "blame") {
                    guard ok else { exit(49) }
                    guard self.press(key: "h", modifiers: [.control, .command]) else { exit(50) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
                            let probe = ((try? JSONSerialization.jsonObject(
                                with: Data(((value as? String) ?? "{}").utf8))) as? [String: Any]) ?? [:]
                            let commits = probe["lensRows"] as? Int ?? 0
                            let historyOK = commits > 0
                            FileHandle.standardError.write(Data(
                                ("SELFTEST lens-history=\(historyOK ? "OK" : "MISMATCH") "
                                    + "commits=\(commits)\n").utf8))
                            self.snapshot(named: "history") {
                                guard historyOK else { exit(50) }
                                self.renderedSelftest()
                            }
                        }
                    }
                }
            }
        }
    }

    /// DEC-063, end to end: two PNGs built here that differ in a known number of pixels, so the
    /// count in the sentence can be wrong in a way a picture would never show.
    private func renderedSelftest() {
        func png(dot: Bool) -> [UInt8] {
            let size = 16
            var pixels = [UInt8](repeating: 0, count: size * size * 4)
            for index in stride(from: 0, to: pixels.count, by: 4) {
                pixels[index] = 40; pixels[index + 1] = 40; pixels[index + 2] = 200
                pixels[index + 3] = 255
            }
            if dot {
                // Four pixels, in a square, so the expected count is a number rather than "some".
                for (x, y) in [(4, 4), (5, 4), (4, 5), (5, 5)] {
                    let index = (y * size + x) * 4
                    pixels[index] = 255; pixels[index + 1] = 255; pixels[index + 2] = 255
                }
            }
            var buffer = pixels
            let data: Data? = buffer.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress, width: size, height: size,
                                              bitsPerComponent: 8, bytesPerRow: size * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                      let image = context.makeImage() else { return nil }
                return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }
            return [UInt8](data ?? Data())
        }

        let old = png(dot: false)
        let new = png(dot: true)
        let kind = renderableKind(path: "assets/mark.png", bytes: new)
        guard kind == .raster(format: "PNG") else {
            FileHandle.standardError.write(Data("SELFTEST rendered=MISMATCH not classified as PNG\n".utf8))
            exit(51)
        }
        showRendered(file: ChangedFile(path: "assets/mark.png", originalPath: nil, kind: .modified),
                     oldBytes: old, newBytes: new, kind: kind)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.webView.evaluateJavaScript("JSON.stringify(window.diffscopeProbe())") { value, _ in
                let probe = ((try? JSONSerialization.jsonObject(
                    with: Data(((value as? String) ?? "{}").utf8))) as? [String: Any]) ?? [:]
                let modes = probe["renderedModes"] as? Int ?? 0
                let images = probe["renderedImages"] as? Int ?? 0
                let ok = modes == 4 && images == 2
                FileHandle.standardError.write(Data(
                    ("SELFTEST rendered=\(ok ? "OK" : "MISMATCH") modes=\(modes) images=\(images) "
                        + "off=\(probe["renderedModesOff"] as? Int ?? -1)\n").utf8))
                self.snapshot(named: "rendered") {
                    guard ok else { exit(51) }
                    self.renderedFixtureSelftest()
                }
            }
        }
    }

    /// The §4.7a fixtures, through the real path (DEC-063). Two of them make claims a picture
    /// cannot check — *0 pixels differ* and *the boundary held* — and both are the kind of claim
    /// that stays true by accident until it does not.
    private func renderedFixtureSelftest() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("fixtures")
        func bytes(_ case_: String, _ file: String) -> [UInt8] {
            [UInt8]((try? Data(contentsOf: root.appendingPathComponent("\(case_)/\(file)"))) ?? Data())
        }
        func differing(_ case_: String, _ ext: String) -> Int? {
            guard let old = ImageComparison.image(from: bytes(case_, "before.\(ext)")),
                  let new = ImageComparison.image(from: bytes(case_, "after.\(ext)")) else { return nil }
            return ImageComparison.compare(old: old, new: new).differing
        }

        // The pair whose bytes moved and whose picture did not. If this is ever non-zero the
        // sentence F18 requires would be replaced by a count, which is the failure in reverse.
        let identical = differing("raster-identical-bytes-differ", "png")
        // The same file with a square moved two units: the pass must find it.
        let moved = differing("raster-resize", "png")
        let fixturesOK = identical == 0 && (moved ?? 0) > 0
        FileHandle.standardError.write(Data(
            ("SELFTEST rendered-fixtures=\(fixturesOK ? "OK" : "MISMATCH") "
                + "identical-render=\(identical.map(String.init) ?? "undecodable") "
                + "resize=\(moved.map(String.init) ?? "undecodable")\n").utf8))
        guard fixturesOK else { exit(52) }

        // The boundary control. The SVG carries a script, an onload handler and two remote
        // references; it is drawn through an `<img>` from a `data:` URL, where none of them can
        // run. A marker the file would set is asked for afterwards.
        let hostile = bytes("svg-hostile", "after.svg")
        showRendered(file: ChangedFile(path: "public/hostile.svg", originalPath: nil, kind: .modified),
                     oldBytes: bytes("svg-hostile", "before.svg"), newBytes: hostile,
                     kind: .textThatRenders(format: "SVG"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.webView.evaluateJavaScript("String(globalThis.__diffscopeHostile)") { value, _ in
                let marker = (value as? String) ?? "undefined"
                let images = "document.querySelectorAll(\"#rendered img\").length"
                self.webView.evaluateJavaScript(images) { count, _ in
                    let drawn = (count as? Int) ?? (count as? NSNumber)?.intValue ?? 0
                    // Drawn **and** inert: either half alone would pass while the product failed.
                    let held = marker == "undefined" && drawn == 2
                    FileHandle.standardError.write(Data(
                        ("SELFTEST svg-boundary=\(held ? "OK" : "MISMATCH") marker=\(marker) "
                            + "images=\(drawn)\n").utf8))
                    self.snapshot(named: "rendered-svg") {
                        exit(held ? 0 : 53)
                    }
                }
            }
        }
    }

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
        // `--ds-empty-bg`. The one screen AppKit draws before any pane exists, so it is the one
        // place the window's own surface is visible on its own.
        emptyState.wantsLayer = true
        emptyState.layer?.backgroundColor = Theme.emptyStateSurface.cgColor
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

    /// DEC-059. Unified is what the window opens on; this is the mode a reader opts into for a
    /// large restructure, where the question is whether two versions correspond rather than what
    /// changed. The renderer re-projects the model it already has, so the pinned pair and the
    /// current change stop both survive the switch.
    @objc private func toggleSideBySide() {
        sideBySide.toggle()
        sideBySideMenuItem?.state = sideBySide ? .on : .off
        webView.evaluateJavaScript("window.diffscopeSetLayout(\"\(sideBySide ? "split" : "unified")\")") { _, _ in }
        statusLabel.stringValue = sideBySide ? "side by side" : "unified"
    }

    /// DEC-060. Three toggles rather than one focus mode, because the two lists stop being useful
    /// at different moments: the repository list goes quiet once you are inside a repository, and
    /// the file list stays in use for the whole review.
    @objc private func toggleRepositoriesPane() {
        reposCollapsed.toggle()
        reposCollapseMenuItem?.state = reposCollapsed ? .on : .off
        applyCollapses()
    }

    @objc private func toggleFilesPane() {
        filesCollapsed.toggle()
        filesCollapseMenuItem?.state = filesCollapsed ? .on : .off
        applyCollapses()
    }

    @objc private func toggleBothPanes() {
        let collapsing = !(reposCollapsed && filesCollapsed)
        reposCollapsed = collapsing
        filesCollapsed = collapsing
        reposCollapseMenuItem?.state = collapsing ? .on : .off
        filesCollapseMenuItem?.state = collapsing ? .on : .off
        applyCollapses()
    }

    private func applyCollapses() {
        // DEC-064: the pane moves, unless the reader has asked the system for less motion — in
        // which case it is simply the other width, with nothing in between. The system setting is
        // the authority; there is no preference of our own to disagree with it.
        // The constant is set outright and the *layout pass* is what animates. Animating the
        // constant itself left it at its old value whenever the animation did not run to
        // completion — the selftest caught a collapse that had been asked for and not made, which
        // is the failure mode worth having a check for at all.
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        repoPaneWidth?.constant = reposCollapsed ? Theme.railWidth : Theme.repositoryPaneWidth
        filePaneWidth?.constant = filesCollapsed ? Theme.spineWidth : Theme.filePaneWidth
        repoPaneMinimum?.constant = reposCollapsed ? Theme.railWidth : Theme.paneMinimumWidth
        filePaneMinimum?.constant = filesCollapsed ? Theme.spineWidth : Theme.paneMinimumWidth
        // The caption under the repository list is a sentence, and a 44 px rail has no room for
        // one. It is the pane's own explanation, so it goes with the pane rather than being
        // squeezed into an unreadable column.
        conventionLabel.isHidden = reposCollapsed
        repoTable.reloadData()
        fileTable.reloadData()
        // The dividers are moved through the split view's own API as well as by constraint.
        // Constraints alone were satisfied for the rail and quietly ignored for the spine — twice,
        // at two different priorities — because `NSSplitView` keeps the divider position it last
        // computed and a width constraint is only one of the things it weighs. `setPosition` is
        // the instruction it cannot reinterpret.
        let first = reposCollapsed ? Theme.railWidth : Theme.repositoryPaneWidth
        let second = first + splitView.dividerThickness
            + (filesCollapsed ? Theme.spineWidth : Theme.filePaneWidth)
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.motionQuick
                context.allowsImplicitAnimation = true
                splitView.animator().setPosition(first, ofDividerAt: 0)
                splitView.animator().setPosition(second, ofDividerAt: 1)
                splitView.animator().layoutSubtreeIfNeeded()
            }
        } else {
            splitView.setPosition(first, ofDividerAt: 0)
            splitView.setPosition(second, ofDividerAt: 1)
            splitView.layoutSubtreeIfNeeded()
        }
        // The split view is not the constraint owner; the window's content view is. Laying out the
        // subtree from the split alone left the second divider exactly where it had been.
        window.contentView?.layoutSubtreeIfNeeded()
        splitView.adjustSubviews()
        splitView.setPosition(first, ofDividerAt: 0)
        splitView.setPosition(second, ofDividerAt: 1)
        // The column does not follow the pane on its own, and a column narrower than its pane
        // draws a row that is mostly empty — M8-D's defect exactly: two lists full of correct
        // rows, rendered blank, in a window that passed every check. Setting the width by hand
        // was worse: the table resized it back to 10 pt behind the change.
        for (table, collapsed) in [(repoTable!, reposCollapsed), (fileTable!, filesCollapsed)] {
            // A legacy scroller reserves its own width whether or not it is shown, and that
            // reservation becomes the pane's floor.
            table.enclosingScrollView?.scrollerStyle = .overlay
            table.enclosingScrollView?.hasVerticalScroller = !collapsed
            // A pane that shrinks keeps its horizontal scroll offset, and the rail then drew its
            // three letters starting 27 pt into a 44 pt column — present, correct, and mostly off
            // the left edge. Nothing about the row was wrong; the clip view was where it had been.
            if let clip = table.enclosingScrollView?.contentView {
                clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y))
                table.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            guard let column = table.tableColumns.first,
                  let clip = table.enclosingScrollView?.contentView else { continue }
            // The table keeps whatever width it had and the clip view then centres the difference,
            // which put a 32 pt cell 16 pt into a 32 pt window — three letters set, two drawn.
            // Sizing the table to the clip is what makes the row start where the pane does.
            column.minWidth = Theme.spineWidth - 2 * Theme.space2
            column.maxWidth = Theme.windowWidth
            column.width = max(column.minWidth, clip.bounds.width)
            table.setFrameSize(NSSize(width: clip.bounds.width, height: table.frame.height))
            table.tile()
            // …and again after the split view's own layout pass, which re-tiles the scroll view
            // and puts the width back. The first assignment is what the table is asked for; this
            // is what it keeps.
            DispatchQueue.main.async {
                table.setFrameSize(NSSize(width: clip.bounds.width, height: table.frame.height))
                table.tile()
                clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y))
                table.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
        statusLabel.stringValue = "repositories: \(reposCollapsed ? "rail" : "list")"
            + " · files: \(filesCollapsed ? "spine" : "list")"
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
                                           keyEquivalent: keyEquivalent(binding.key))
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
        sideBySideMenuItem = menuItems["layout.sideBySide"]
        for id in ["lens.diff", "lens.blame", "lens.history"] { lensMenuItems[id] = menuItems[id] }
        lensMenuItems["lens.diff"]?.state = .on
        reposCollapseMenuItem = menuItems["collapse.repositories"]
        filesCollapseMenuItem = menuItems["collapse.files"]
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
        case "preferences": return #selector(showPreferences)
        case "mode.raw", "mode.structural", "mode.expanded": return #selector(selectMode(_:))
        case "rawRegion": return #selector(toggleRawForCurrentRegion)
        case "terminal": return #selector(toggleTerminal)
        case "terminal.raw": return #selector(toggleTerminalRawMode)
        case "terminal.follow": return #selector(followTerminalToSelection)
        case "wrap": return #selector(toggleWrap)
        case "layout.sideBySide": return #selector(toggleSideBySide)
        case "lens.diff": return #selector(showDiffLens)
        case "lens.blame": return #selector(showBlameLens)
        case "lens.history": return #selector(showHistoryLens)
        case "collapse.repositories": return #selector(toggleRepositoriesPane)
        case "collapse.files": return #selector(toggleFilesPane)
        case "collapse.both": return #selector(toggleBothPanes)
        case "scope.allLocal", "scope.unstaged", "scope.staged", "scope.base":
            return #selector(selectScope(_:))
        case "sources.addRoot": return #selector(addRootFolder)
        case "sources.addRepository": return #selector(addRepository)
        case "sources.remove": return #selector(removeSource)
        case "sources.baseBranch": return #selector(setBaseBranch)
        case "search": return #selector(searchChangedFiles)
        case "search.worktree": return #selector(searchWorktree)
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

    /// The map writes keys as a reader sees them — `↓`, `⏎` — and this is the one place that
    /// becomes AppKit's notation. Keeping the translation here rather than in the map is what lets
    /// `diffscope-verify` link the map without linking AppKit (DEC-057), and what lets the
    /// documents quote `⌘↓` and mean the thing the menu prints.
    private func keyEquivalent(_ key: String) -> String {
        switch key {
        case "↑": return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "↓": return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case "←": return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "→": return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case "⏎": return "\r"
        default: return key
        }
    }

    private func modifierFlags(_ modifiers: KeyboardModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
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
        let template = editorTemplate()
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
                DispatchQueue.main.async {
                    self.statusLabel.stringValue = outcome.message
                    self.lastEditorAttempt = outcome.message
                }
            }
        }
    }

    /// DEC-015: the command is **user configuration**. The environment variable stays as a testing
    /// override — F13's broken-editor arm needs a way in that does not write to the reader's file —
    /// and the configuration is what a person edits, in Preferences or in the JSON itself.
    private func editorTemplate() -> String {
        ProcessInfo.processInfo.environment["DIFFSCOPE_EDITOR"]
            ?? state.configuration.editorTemplate
            ?? EditorCommand.defaultTemplate
    }

    /// The preferences window (DEC-015, `12-…` §10). One setting today, and it is the one with a
    /// failure the reader has to be able to see: the last attempt and its exit status are shown
    /// here, because "nothing happened" is the least useful thing an editor integration can say.
    @objc private func showPreferences() {
        let panel = NSAlert()
        panel.messageText = "Editor command"
        panel.informativeText = """
            {file} is the absolute path, {line} the 1-based line. The template is split into \
            arguments first and substituted afterwards, so a path with spaces stays one argument.

            Last attempt: \(lastEditorAttempt ?? "none this session")
            """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: Theme.emptyStateMaximumWidth,
                                              height: Theme.space6 + Theme.space4))
        field.stringValue = editorTemplate()
        field.font = Theme.font(Theme.textSize)
        field.placeholderString = EditorCommand.defaultTemplate
        panel.accessoryView = field
        panel.addButton(withTitle: "Save")
        panel.addButton(withTitle: "Cancel")
        panel.addButton(withTitle: "Reset to default")
        let choice = panel.runModal()
        switch choice {
        case .alertFirstButtonReturn:
            let entered = field.stringValue.trimmingCharacters(in: .whitespaces)
            state.configuration.editorTemplate = entered.isEmpty ? nil : entered
        case .alertThirdButtonReturn:
            state.configuration.editorTemplate = nil
        default:
            return
        }
        configStore.save(state.configuration)
        statusLabel.stringValue = "editor command: \(editorTemplate())"
    }

    /// Draws a comparison the diff engine has nothing to say about (DEC-063).
    ///
    /// Every number in the sentence is computed here and checked in the engine's own words before
    /// it reaches the view: dimensions from the decoded images, differing pixels from a real pass
    /// over both, and the modes that cannot work here disabled **with their reason**.
    /// Bytes rather than the pinned pair: the pair is a Git-layer type with no public initialiser,
    /// and widening it so a selftest can build one would be the tail wagging the dog. What this
    /// needs is two sides.
    private func showRendered(file: ChangedFile, oldBytes: [UInt8], newBytes: [UInt8],
                              kind: RenderableKind) {
        let oldImage = oldBytes.isEmpty ? nil : ImageComparison.image(from: oldBytes)
        let newImage = newBytes.isEmpty ? nil : ImageComparison.image(from: newBytes)
        var differing: Int?
        var maskSource: String?
        if let oldImage, let newImage {
            let outcome = ImageComparison.compare(old: oldImage, new: newImage)
            differing = outcome.differing
            maskSource = outcome.mask.map { "data:image/png;base64," + $0.base64EncodedString() }
        }

        let comparison = RenderedComparison(
            kind: kind,
            oldBytes: oldBytes.count, newBytes: newBytes.count,
            oldSize: oldImage.map(ImageComparison.size), newSize: newImage.map(ImageComparison.size),
            differingPixels: differing)
        let summary = renderedComparisonSummary(comparison)

        // A mode is offered or refused **with a reason**; there is no third state. An SVG's pixel
        // pass is refused for a reason worth stating rather than hidden: the bytes are handed to an
        // `<img>` so nothing inside them can run, and an `<img>` is exactly what cannot be read
        // back pixel by pixel.
        let missingSide = oldImage == nil || newImage == nil
        let svg = kind == .textThatRenders(format: "SVG")
        func mode(_ id: String, _ label: String, _ reason: String?) -> [String: Any] {
            reason.map { ["id": id, "label": label, "reason": $0] } ?? ["id": id, "label": label]
        }
        let modes: [[String: Any]] = [
            mode("sidebyside", "Side by side", nil),
            mode("blend", "Blend", missingSide ? "no counterpart" : nil),
            mode("split", "Split", missingSide ? "no counterpart" : nil),
            mode("pixel", "Pixel diff",
                 missingSide ? "no counterpart"
                     : svg ? "drawn through an <img>, which cannot be read back"
                     : !comparison.withinPixelBudget
                         ? "over \(RenderedComparison.megapixelBudget) megapixels"
                         : differing == 0 ? "0 pixels differ" : nil),
        ]

        let mime = ImageComparison.mimeType(for: kind)
        var payload: [String: Any] = ["summary": "\(file.path) · \(summary)", "modes": modes]
        if !oldBytes.isEmpty {
            payload["oldSrc"] = ImageComparison.dataURL(bytes: oldBytes, mimeType: mime)
        }
        if !newBytes.isEmpty {
            payload["newSrc"] = ImageComparison.dataURL(bytes: newBytes, mimeType: mime)
        }
        if let maskSource { payload["maskSrc"] = maskSource }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8),
              let wrapped = try? JSONSerialization.data(withJSONObject: [json]),
              let escaped = String(data: wrapped, encoding: .utf8) else { return }
        let argument = String(escaped.dropFirst().dropLast())
        webView.evaluateJavaScript("window.diffscopeShowRendered(\(argument))") { _, _ in }
        statusLabel.stringValue = summary
    }

    // ---- The lenses (DEC-061) ----------------------------------------------------------------
    //
    // Same file, same window, same gutter geometry: what changes is the question. Both run through
    // the closed operation registry, so R-8's proof covers them the moment they exist — an
    // operation that is not in the registry cannot be issued at all.
    @objc private func showDiffLens() {
        state.lens = .diff
        updateLensMenu()
        webView.evaluateJavaScript("window.diffscopeHideLens()") { _, _ in }
        statusLabel.stringValue = "lens: diff"
    }

    @objc private func showBlameLens() {
        guard let repository = state.selectedRepository, let file = state.selectedFile else {
            statusLabel.stringValue = "blame needs a file — choose one first"
            return
        }
        let result = try? GitRunner().run(.blame(path: file.path), in: repository.url)
        guard let result, result.succeeded else {
            statusLabel.stringValue = "blame unavailable for \(file.path) — the file has no history yet"
            return
        }
        // Not `trimmedOutput`: blame's content lines carry their own leading whitespace and the
        // last line of a file may be blank, and trimming would quietly edit the file's text.
        let lines = parseBlamePorcelain(String(decoding: result.standardOutput, as: UTF8.self))
        state.lens = .blame
        updateLensMenu()
        let rows = lines.map { line in
            ["sha": line.sha, "who": line.author, "when": line.committed,
             "line": String(line.line), "text": line.text,
             "uncommitted": line.isUncommitted ? "1" : ""] as [String: String]
        }
        let uncommitted = lines.filter(\.isUncommitted).count
        pushLens(kind: "blame", rows: rows,
                 summary: "\(file.path) · \(lines.count) lines · \(uncommitted) not committed yet")
    }

    @objc private func showHistoryLens() {
        guard let repository = state.selectedRepository else {
            statusLabel.stringValue = "history needs a repository — choose one first"
            return
        }
        let result = try? GitRunner().run(.log(limit: 200), in: repository.url)
        guard let result, result.succeeded else {
            statusLabel.stringValue = "history unavailable — this repository has no commits yet"
            return
        }
        let commits = parseLog(String(decoding: result.standardOutput, as: UTF8.self))
        state.lens = .history
        updateLensMenu()
        let rows = commits.map { commit in
            ["sha": commit.sha, "who": commit.author, "when": commit.committed,
             "subject": commit.subject, "refs": commit.refs] as [String: String]
        }
        pushLens(kind: "history", rows: rows,
                 summary: historySummary(commits: commits,
                                         branch: repository.head.displayText,
                                         ahead: repository.aheadCount))
    }

    private func updateLensMenu() {
        lensMenuItems["lens.diff"]?.state = state.lens == .diff ? .on : .off
        lensMenuItems["lens.blame"]?.state = state.lens == .blame ? .on : .off
        lensMenuItems["lens.history"]?.state = state.lens == .history ? .on : .off
    }

    private func pushLens(kind: String, rows: [[String: String]], summary: String) {
        let payload: [String: Any] = ["kind": kind, "summary": summary,
                                      "rows": rows.map { row -> [String: Any] in
                                          var out: [String: Any] = row
                                          out["uncommitted"] = (row["uncommitted"] ?? "") == "1"
                                          out["line"] = Int(row["line"] ?? "") ?? 0
                                          return out
                                      }]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8),
              let escaped = String(data: try! JSONSerialization.data(withJSONObject: [json]),
                                   encoding: .utf8) else { return }
        // The payload is passed as a JSON string inside a JSON array, so quoting it is the
        // serialiser's problem rather than a piece of string arithmetic here.
        let argument = String(escaped.dropFirst().dropLast())
        webView.evaluateJavaScript("window.diffscopeShowLens(\(argument))") { _, _ in }
        statusLabel.stringValue = summary
    }

    // ---- Search (DEC-062) -------------------------------------------------------------------
    //
    // The default scope is the changed set, because that is the material under review; the whole
    // worktree is a different question and is asked with a different key rather than a hidden
    // default. Both are read-only: the reader's query is matched as a literal, and nothing
    // compiled from a repository is ever run (DEC-028).
    @objc private func searchChangedFiles() { runSearch(scope: .changedFiles) }
    @objc private func searchWorktree() { runSearch(scope: .wholeWorktree) }

    private func runSearch(scope: SearchScope) {
        guard let repository = state.selectedRepository else {
            statusLabel.stringValue = "search needs a repository — choose one first"
            return
        }
        let prompt = NSAlert()
        prompt.messageText = "Find in \(scope.title)"
        prompt.informativeText = "Matched as literal text, not as a pattern. "
            + "An empty search clears the results and brings the file list back."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: Theme.emptyStateMaximumWidth,
                                              height: Theme.space6 + Theme.space4))
        field.stringValue = state.searchQuery
        field.font = Theme.font(Theme.textSize)
        let matchCase = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
        matchCase.state = state.searchMatchCase ? .on : .off
        let stack = NSStackView(views: [field, matchCase])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: Theme.emptyStateMaximumWidth,
                             height: 2 * (Theme.space6 + Theme.space4))
        prompt.accessoryView = stack
        prompt.addButton(withTitle: "Find")
        prompt.addButton(withTitle: "Cancel")
        guard prompt.runModal() == .alertFirstButtonReturn else { return }

        state.searchQuery = field.stringValue
        state.searchMatchCase = matchCase.state == .on
        guard !state.searchQuery.isEmpty else {
            state.searchHits = []
            reloadFiles()
            return
        }

        let contents = searchableContents(of: repository, scope: scope)
        let result = search(query: state.searchQuery, in: contents,
                            options: SearchOptions(matchCase: state.searchMatchCase))
        state.searchHits = result.hits
        showSearchResults(result, scope: scope)
    }

    /// The text to search. Changed files come from the scope the reader is already looking at;
    /// the worktree walk skips `.git` and `node_modules` for the reason DEC-027 skips them in the
    /// watcher, and stops at a file count rather than reading a repository of unknown size.
    private func searchableContents(of repository: RepositorySnapshot,
                                    scope: SearchScope) -> [(path: String, text: String)] {
        func read(_ relative: String) -> (path: String, text: String)? {
            let url = repository.url.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: url), data.count < 4_000_000,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return (path: relative, text: text)
        }
        switch scope {
        case .changedFiles:
            return state.files.compactMap { read($0.path) }
        case .wholeWorktree:
            let skipped = Set([".git", "node_modules", ".next", "dist", "build"])
            var out: [(path: String, text: String)] = []
            let base = repository.url.standardizedFileURL.path
            guard let walker = FileManager.default.enumerator(at: repository.url,
                                                              includingPropertiesForKeys: [.isDirectoryKey]) else {
                return out
            }
            for case let url as URL in walker {
                if skipped.contains(url.lastPathComponent) {
                    walker.skipDescendants()
                    continue
                }
                guard out.count < 4_000 else { break }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(base + "/") else { continue }
                if let entry = read(String(path.dropFirst(base.count + 1))) { out.append(entry) }
            }
            return out
        }
    }

    private func showSearchResults(_ result: SearchResult, scope: SearchScope) {
        // Results take the file list's place: one window, no second place to be (DEC-005). ⌘F with
        // an empty query brings the files back, and so does any refresh.
        state.fileRows = result.hits.map { hit in
            let file = state.files.first { $0.path == hit.path }
                ?? ChangedFile(path: hit.path, originalPath: nil, kind: .modified)
            let snippet = (hit.before + hit.match + hit.after).trimmingCharacters(in: .whitespaces)
            return .file(file, display: "\(hit.line)  \(snippet.prefix(80))")
        }
        fileTable.reloadData()
        statusLabel.stringValue = searchSummary(query: state.searchQuery, result: result, scope: scope)
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
        var unavailable: [String] = []
        for (index, scope) in ComparisonScope.allCases.enumerated() {
            let state = scopes.availability(of: scope, head: repository.head, base: repository.base)
            scopeControl.setEnabled(state == .available, forSegment: index)
            if case let .unavailable(reason) = state {
                scopeControl.setToolTip("\(scope.title) — \(reason)", forSegment: index)
                unavailable.append("\(scope.title) — \(reason)")
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
        // A greyed-out segment with its reason in a tooltip is the defect DEC-058 named: a tooltip
        // is invisible until pointed at, and a reader walking the window from the keyboard never
        // sees it. `12-…` §3 asks for the reason to be *stated*, so it goes on the line.
        let reasons = unavailable.isEmpty ? "" : " · unavailable: " + unavailable.joined(separator: ", ")
        statusLabel.stringValue = "\(state.files.count) files · \(state.scope.title)\(ageText)\(reasons)"
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
            // DEC-063: a file that renders is compared by being drawn. Decided from the bytes as
            // well as the name, because a `.png` that is not a PNG is a placeholder, an LFS
            // pointer or a rename that outran its content — and drawing it would show an empty
            // frame with no explanation.
            let kind = renderableKind(path: file.path,
                                      bytes: pair.newBytes.isEmpty ? pair.oldBytes : pair.newBytes)
            if kind.rendersAsImage {
                DispatchQueue.main.async {
                    self.showRendered(file: file, oldBytes: pair.oldBytes, newBytes: pair.newBytes,
                                      kind: kind)
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
                mode: mode.rawValue, pathTaken: outcome.pathTaken, parser: outcome.parser,
                validation: outcome.validation, notices: outcome.notices,
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
        /// Which path produced this model, as opposed to which mode asked for it. The two disagree
        /// exactly when a structural run was withheld or discarded, and `23b-…` §2 records what
        /// happened while only the mode was carried: the pill said `structural` beside a notice
        /// saying structural analysis was unavailable.
        let pathTaken: String
        /// `12-…` §5.2's parser-state indicator, decided where the parse outcome is known.
        let parser: ParserStateReport
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

        func rawOutcome(notices: [String], summary: String,
                        parser: ParserStateReport) -> ModelOutcome {
            let model = trivialModel(oldBytes: old, newBytes: new)
            return ModelOutcome(model: model, validation: validate(model),
                                notices: notices, summary: summary,
                                pathTaken: "raw", parser: parser)
        }

        guard mode.usesStructure else {
            return rawOutcome(notices: outside.map { [$0.notice] } ?? [],
                              summary: outside.map { "raw — \($0.reason)" } ?? "raw",
                              parser: ParserStateReport.of(structuralRequested: false,
                                                           structuralUsed: false,
                                                           degradation: outside))
        }

        let result = structuralDiff(oldPath: path, oldBytes: old, newPath: path, newBytes: new,
                                    parser: parser, external: external)
        if result.stats.usedFallback {
            let degradation = result.stats.degradation
                ?? .parseFailure(reason: "structural analysis unavailable")
            return ModelOutcome(model: result.model, validation: validate(result.model),
                                notices: [degradation.notice],
                                summary: "raw — \(degradation.reason)",
                                pathTaken: "raw", parser: result.stats.parserState)
        }

        let validation = validate(result.model)
        guard validation.passed else {
            let discarded = Degradation.invariantViolation(reason: validation.summary)
            return rawOutcome(
                notices: [discarded.notice],
                summary: "raw — structural result discarded",
                // The file parsed. What failed was the check afterwards, and saying "not parsed"
                // here would make the indicator report the wrong stage of the pipeline — the whole
                // reason §5.2 lists parser state separately from fallback marking.
                parser: ParserStateReport(state: "parsed",
                                          detail: "structural result discarded after parsing")
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
                            summary: carried.map { "\(summary) · \($0.reason)" } ?? summary,
                            pathTaken: "structural", parser: stats.parserState)
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
            if reposCollapsed {
                // Three letters, because two do not separate `web` from `des` in the product
                // owner's own tree, and a dot for "there is work in here". The full row is one
                // hover — and one ⌃⌘1 — away.
                // No space before the dot: at 11 px the rail has room for four characters and the
                // three letters are the part that has to be readable.
                text.stringValue = String(label.prefix(3))
                    + (snapshot.uncommittedCount > 0 ? "•" : "")
                // Tiny, because three letters at 11 px do not fit a 44 px rail once the insets
                // and the dot are counted — and two letters do not separate `web` from `wea`.
                text.font = Theme.font(Theme.textSizeTiny)
                text.toolTip = "\(label) — \(snapshot.head.displayText), "
                    + "\(snapshot.uncommittedCount) uncommitted, \(ahead)"
                text.lineBreakMode = .byClipping
                return cell
            }
            // `12-…` §2 lists the branch as **displayed**, and it was in the tooltip only
            // (`23b-…` §2). A tooltip is not a display: it is invisible until pointed at, so a
            // reader walking the list from the keyboard never sees it. The unusual head states
            // matter most of the three — `no commits yet` explains why all four scopes are greyed.
            text.stringValue = "\(label)  ·  \(snapshot.head.displayText)  ·  "
                + "\(snapshot.uncommittedCount)△ \(ahead)"
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
                if filesCollapsed {
                    // One bar per file, carrying the kind glyph: the design drew these bars
                    // distinguished by hue alone, which DEC-035 forbids.
                    //
                    // The design also sizes each bar by how much the file changed. That number is
                    // not in `ChangedFile` — the scope layer lists paths and kinds, not counts —
                    // and a bar length invented here would be a measurement the product did not
                    // make. The bar is uniform until the count is real.
                    text.stringValue = "\(file.kind.glyph) ▍"
                    text.toolTip = "\(file.path) — \(file.kind.rawValue)\(badge)"
                    text.lineBreakMode = .byClipping
                    return cell
                }
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
