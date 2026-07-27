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
}

final class Controller: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, WKNavigationDelegate {
    let state = AppState()
    let discovery = RepositoryDiscovery(maximumDepth: 2)
    let reader = RepositoryReader()
    let scopes = ScopeReader()

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        loadRenderer()
        let root = ProcessInfo.processInfo.environment["DIFFSCOPE_ROOT"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("WebstormProjects").path
        scanRoot(URL(fileURLWithPath: root))
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

        let rightStack = NSStackView(views: [controls, statusLabel, webView])
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 6
        rightStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 0, right: 8)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.widthAnchor.constraint(equalTo: rightStack.widthAnchor, constant: -16).isActive = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(leftScroll)
        split.addArrangedSubview(middleScroll)
        split.addArrangedSubview(rightStack)

        window.contentView = split
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            split.setPosition(280, ofDividerAt: 0)
            split.setPosition(620, ofDividerAt: 1)
        }
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
        let scroll = NSScrollView()
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
                self.snapshot(named: "navigation") { exit(ok ? 0 : 14) }
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
                try? png.write(to: url)
                FileHandle.standardError.write(Data("SELFTEST snapshot=\(url.path)\n".utf8))
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

    private func scanRoot(_ root: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = self.discovery.discover(sources: [DiscoverySource(url: root, kind: .root)])
            let sweep = RepositorySweep(reader: self.reader)
            let outcome = sweep.run(over: found.repositories.map(\.url))
            DispatchQueue.main.async {
                self.state.repositories = outcome.snapshots
                self.repoTable.reloadData()
                self.statusLabel.stringValue = String(
                    format: "%d repositories · swept in %.0f ms",
                    outcome.snapshots.count, outcome.elapsedSeconds * 1000
                )
            }
        }
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
            ?? "/usr/bin/open -a WebStorm {file}"
        let path = repository.url.appendingPathComponent(file.path).path
        let parts = template.replacingOccurrences(of: "{file}", with: path)
            .replacingOccurrences(of: "{line}", with: "1")
            .split(separator: " ").map(String.init)
        guard let executable = parts.first else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(parts.dropFirst())
        do {
            try process.run()
            statusLabel.stringValue = "opened \(file.path) in the editor"
        } catch {
            statusLabel.stringValue = "open in editor failed: \(error.localizedDescription)"
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
        guard let repository = state.selectedRepository else { return }
        state.selectedFile = file
        let mode = state.mode
        DispatchQueue.global(qos: .userInitiated).async {
            guard let pair = try? self.scopes.pinnedPair(
                for: file, scope: self.state.scope, in: repository.url, mergeBaseRev: self.state.mergeBaseRev
            ) else { return }
            let outcome = self.buildModel(path: file.path, old: pair.oldBytes, new: pair.newBytes, mode: mode)
            let render = buildRenderModel(
                model: outcome.model, pinOld: pair.oldHash, pinNew: pair.newHash,
                mode: mode.rawValue, validation: outcome.validation, notices: outcome.notices
            )
            guard let json = try? encodeRenderModel(render) else { return }
            DispatchQueue.main.async {
                self.statusLabel.stringValue = "\(file.path) · \(outcome.summary)"
                if self.rendererReady { self.push(json) } else { self.pendingModel = json }
            }
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
    func buildModel(path: String, old: [UInt8], new: [UInt8], mode: PresentationMode) -> ModelOutcome {
        func rawOutcome(notices: [String], summary: String) -> ModelOutcome {
            let model = trivialModel(oldBytes: old, newBytes: new)
            return ModelOutcome(model: model, validation: validate(model),
                                notices: notices, summary: summary)
        }

        guard mode.usesStructure else { return rawOutcome(notices: [], summary: "raw") }

        let result = structuralDiff(oldPath: path, oldBytes: old, newPath: path, newBytes: new,
                                    parser: parser)
        if result.stats.usedFallback {
            let reason = result.stats.fallbackReason ?? "structural analysis unavailable"
            return ModelOutcome(model: result.model, validation: validate(result.model),
                                notices: ["raw for this file — \(reason)"],
                                summary: "raw — \(reason)")
        }

        let validation = validate(result.model)
        guard validation.passed else {
            return rawOutcome(
                notices: ["structural result discarded — \(validation.summary)"],
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
        return ModelOutcome(model: result.model, validation: validation, notices: [], summary: summary)
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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text = NSTextField(labelWithString: "")
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.lineBreakMode = .byTruncatingMiddle
        if tableView === repoTable {
            let snapshot = state.repositories[row]
            let ahead = snapshot.aheadCount.map { "↑\($0)" } ?? "↑?"
            text.stringValue = "\(snapshot.displayName)  ·  \(snapshot.uncommittedCount)△ \(ahead)"
            text.toolTip = "\(snapshot.head.displayText)\n\(snapshot.baseRefUsed ?? "base: prompt")"
        } else {
            let file = state.files[row]
            text.stringValue = "\(file.kind.rawValue.prefix(3))  \(file.path)"
            text.toolTip = file.path
        }
        return text
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === repoTable {
            guard table.selectedRow >= 0 else { return }
            state.selectedRepository = state.repositories[table.selectedRow]
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
