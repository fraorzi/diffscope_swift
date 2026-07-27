import AppKit
import DiffScopeEngine
import DiffScopeGit
import WebKit

final class AppState {
    var repositories: [RepositorySnapshot] = []
    var selectedRepository: RepositorySnapshot?
    var scope: ComparisonScope = .allLocalVsHead
    var files: [ChangedFile] = []
    var mergeBaseRev: String?
}

final class Controller: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, WKNavigationDelegate {
    let state = AppState()
    let discovery = RepositoryDiscovery(maximumDepth: 2)
    let reader = RepositoryReader()
    let scopes = ScopeReader()

    var window: NSWindow!
    var repoTable: NSTableView!
    var fileTable: NSTableView!
    var webView: WKWebView!
    var scopeControl: NSSegmentedControl!
    var statusLabel: NSTextField!
    var rendererReady = false
    var pendingModel: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        window.title = "DiffScope — raw"
        window.center()

        repoTable = makeTable(identifier: "repo")
        fileTable = makeTable(identifier: "file")

        scopeControl = NSSegmentedControl(
            labels: ["All local", "Unstaged", "Staged", "vs base"],
            trackingMode: .selectOne, target: self, action: #selector(scopeChanged)
        )
        scopeControl.selectedSegment = 0

        statusLabel = NSTextField(labelWithString: "scanning…")
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle

        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = self

        let leftScroll = scrollWrapping(repoTable)
        let middleScroll = scrollWrapping(fileTable)

        let rightStack = NSStackView(views: [scopeControl, statusLabel, webView])
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
            exit(ok ? 0 : 4)
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
        DispatchQueue.global(qos: .userInitiated).async {
            guard let pair = try? self.scopes.pinnedPair(
                for: file, scope: self.state.scope, in: repository.url, mergeBaseRev: self.state.mergeBaseRev
            ) else { return }
            let model = trivialModel(oldBytes: pair.oldBytes, newBytes: pair.newBytes)
            let validation = validate(model)
            let render = buildRenderModel(
                model: model, pinOld: pair.oldHash, pinNew: pair.newHash,
                mode: "raw", validation: validation
            )
            guard let json = try? encodeRenderModel(render) else { return }
            DispatchQueue.main.async {
                if self.rendererReady { self.push(json) } else { self.pendingModel = json }
            }
        }
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
