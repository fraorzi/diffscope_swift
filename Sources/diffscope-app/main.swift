import AppKit
import DiffScopeEngine
import DiffScopeGit
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

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
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
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle

        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = self

        let leftScroll = scrollWrapping(repoTable)
        let middleScroll = scrollWrapping(fileTable)

        let controls = NSStackView(views: [scopeControl, modeControl])
        controls.orientation = .horizontal
        controls.spacing = 12

        let rightStack = NSStackView(frame: NSRect(x: 0, y: 0, width: 840, height: 800))
        rightStack.setViews([controls, statusLabel, webView], in: .leading)
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 6
        rightStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 0, right: 8)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.widthAnchor.constraint(equalTo: rightStack.widthAnchor, constant: -16).isActive = true

        let split = NSSplitView()
        splitView = split
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(leftScroll)
        split.addArrangedSubview(middleScroll)
        split.addArrangedSubview(rightStack)

        // Auto layout inside the split, rather than frame proportions. NSSplitView distributes by
        // preserving existing proportions, and every pane started at zero — so the tables were
        // populated, correct, and drawn at zero width. Width constraints at a priority below
        // `defaultHigh` keep the dividers draggable.
        for (pane, width) in [(leftScroll, 280.0), (middleScroll, 320.0)] {
            pane.translatesAutoresizingMaskIntoConstraints = false
            let constraint = pane.widthAnchor.constraint(equalToConstant: width)
            constraint.priority = NSLayoutConstraint.Priority(600)
            constraint.isActive = true
            pane.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        }
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

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
        column.width = 260
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 20
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
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 800))
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
                self.snapshot(named: "gutter") { exit(ok ? 0 : 23) }
            }
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
        title.font = .systemFont(ofSize: 20, weight: .medium)

        emptyStateDetail = NSTextField(wrappingLabelWithString:
            "Choose a folder and DiffScope will look inside it for Git repositories. "
            + "You can add as many folders as you like, and add single repositories from anywhere.")
        emptyStateDetail.font = .systemFont(ofSize: 12)
        emptyStateDetail.textColor = .secondaryLabelColor
        emptyStateDetail.alignment = .center
        emptyStateDetail.preferredMaxLayoutWidth = 420

        let chooseFolder = NSButton(title: "Choose a Folder…", target: self,
                                    action: #selector(addRootFolder))
        chooseFolder.keyEquivalent = "\r"
        let chooseRepository = NSButton(title: "Add a Single Repository…", target: self,
                                        action: #selector(addRepository))
        let buttons = NSStackView(views: [chooseFolder, chooseRepository])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [title, emptyStateDetail, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16

        emptyState = NSView()
        emptyState.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyState.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
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
            let outcome = sweep.run(over: found.repositories.map(\.url))
            let labels = disambiguatedNames(for: outcome.snapshots.map(\.url.path))
            DispatchQueue.main.async {
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
    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit DiffScope", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        for (index, mode) in PresentationMode.allCases.enumerated() {
            let item = view.addItem(withTitle: mode.title, action: #selector(selectMode(_:)),
                                    keyEquivalent: String(index + 1))
            item.tag = index
            item.target = self
        }
        view.addItem(.separator())
        for (index, title) in ["All local", "Unstaged", "Staged", "vs base"].enumerated() {
            let item = view.addItem(withTitle: "Scope: \(title)", action: #selector(selectScope(_:)),
                                    keyEquivalent: String(index + 1))
            item.keyEquivalentModifierMask = [.command, .shift]
            item.tag = index
            item.target = self
        }
        viewItem.submenu = view
        main.addItem(viewItem)

        let sourcesItem = NSMenuItem()
        let sources = NSMenu(title: "Sources")
        for (title, action, key) in [
            ("Add Root Folder…", #selector(addRootFolder), "O"),
            ("Add Repository…", #selector(addRepository), "R"),
            ("Remove Source", #selector(removeSource), ""),
        ] as [(String, Selector, String)] {
            let item = sources.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = self
        }
        sourcesItem.submenu = sources
        main.addItem(sourcesItem)

        let navigateItem = NSMenuItem()
        let navigate = NSMenu(title: "Navigate")
        let bindings: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Next Change", #selector(nextChange), "n", [.command]),
            ("Previous Change", #selector(previousChange), "p", [.command]),
            ("Expand All Collapsed Ranges", #selector(expandAll), "e", [.command]),
            ("Next File", #selector(nextFile), "]", [.command]),
            ("Previous File", #selector(previousFile), "[", [.command]),
            ("Next Repository", #selector(nextRepository), "]", [.command, .shift]),
            ("Previous Repository", #selector(previousRepository), "[", [.command, .shift]),
            ("Focus Repositories", #selector(focusRepositories), "1", [.command, .option]),
            ("Focus Files", #selector(focusFiles), "2", [.command, .option]),
            ("Focus Diff", #selector(focusDiff), "3", [.command, .option]),
            ("Open in Editor", #selector(openInEditor), "o", [.command]),
        ]
        for (title, action, key, modifiers) in bindings {
            let item = navigate.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
        }
        navigateItem.submenu = navigate
        main.addItem(navigateItem)

        NSApplication.shared.mainMenu = main
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
        let next = max(0, min(count - 1, (table.selectedRow < 0 ? 0 : table.selectedRow + delta)))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    @objc private func nextFile() { step(fileTable, by: 1) }
    @objc private func previousFile() { step(fileTable, by: -1) }
    @objc private func nextRepository() { step(repoTable, by: 1) }
    @objc private func previousRepository() { step(repoTable, by: -1) }
    @objc private func focusRepositories() { window.makeFirstResponder(repoTable) }
    @objc private func focusFiles() { window.makeFirstResponder(fileTable) }
    @objc private func focusDiff() { window.makeFirstResponder(webView) }

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
        let availability = scopes.availability(of: state.scope, head: repository.head, base: repository.base)
        if case let .unavailable(reason) = availability {
            state.files = []
            fileTable.reloadData()
            statusLabel.stringValue = "\(state.scope.title) unavailable — \(reason)"
            return
        }
        state.files = (try? scopes.changedFiles(scope: state.scope, in: repository.url, baseRef: baseRef)) ?? []
        fileTable.reloadData()
        let ageText = repository.baseRefCommitterDate.map { " · base \(repository.baseRefUsed ?? "?") tip \($0.prefix(10))" } ?? ""
        statusLabel.stringValue = "\(state.files.count) files · \(state.scope.title)\(ageText)"
    }

    private func showDiff(for file: ChangedFile) {
        state.selectedFile = file
        render(file: file, previousAnchor: nil)
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

    private func render(file: ChangedFile, previousAnchor: RefreshAnchor?) {
        guard let repository = state.selectedRepository else { return }
        let mode = state.mode
        DispatchQueue.global(qos: .userInitiated).async {
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
                self.statusLabel.stringValue = "\(file.path) · \(outcome.summary)"
                if self.rendererReady { self.push(json) } else { self.pendingModel = json }
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
            if let selected, state.files.contains(where: { $0.path == selected.path }) {
                if let row = state.files.firstIndex(where: { $0.path == selected.path }) {
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
        tableView === repoTable ? state.repositories.count : state.files.count
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
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if tableView === repoTable {
            let snapshot = state.repositories[row]
            let ahead = snapshot.aheadCount.map { "↑\($0)" } ?? "↑?"
            let label = state.repositoryLabels[snapshot.url.path] ?? snapshot.displayName
            text.stringValue = "\(label)  ·  \(snapshot.uncommittedCount)△ \(ahead)"
            text.toolTip = "\(snapshot.url.path)\n\(snapshot.head.displayText)\n\(snapshot.baseRefUsed ?? "base: prompt")"
        } else {
            let file = state.files[row]
            text.stringValue = "\(file.kind.rawValue.prefix(3))  \(file.path)"
            text.toolTip = file.path
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === repoTable {
            guard table.selectedRow >= 0 else { return }
            let repository = state.repositories[table.selectedRow]
            state.selectedRepository = repository
            startWatching(repository)
            reloadFiles()
        } else {
            guard table.selectedRow >= 0, table.selectedRow < state.files.count else { return }
            showDiff(for: state.files[table.selectedRow])
        }
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
