import AppKit
import DiffScopeTerminal
import Foundation
import WebKit

/// The terminal pane: xterm.js in its own `WKWebView` (DEC-054), one `TerminalSession` behind it.
///
/// The two directions are deliberately narrow. Output goes down as **base64 of the raw PTY bytes**,
/// never as a decoded string, because a UTF-8 sequence splits across reads. Input comes back
/// through one message handler and reaches exactly one place — `TerminalSession.send` — which is
/// what keeps DEC-028 true now that a shell exists inside the application: what runs is what the
/// user typed, and nothing is ever derived from repository content.
final class TerminalPane: NSObject, WKNavigationDelegate {
    private(set) var webView: WKWebView!

    /// One shell per tab (DEC-067). The pane was a session and is now a list of them; everything
    /// that used to mean *the session* now means *the active one*, which is what the selftest arms
    /// were always about.
    struct Tab {
        let id: String
        let session: TerminalSession
        /// What the strip calls it. The shell's own name, so two `zsh` tabs are told apart by the
        /// directory each of them reports rather than by a number nobody chose.
        let title: String
    }

    private(set) var tabs: [Tab] = []
    private(set) var activeTabID: String?
    private var nextTabNumber = 1

    var session: TerminalSession? {
        tabs.first { $0.id == activeTabID }?.session
    }
    private var ready = false
    /// Bytes that arrived before the page was ready, **with the tab they belong to**. A flat
    /// buffer replayed into "the current tab" invented a grid: output can arrive before the page
    /// has been told the tab exists.
    private var buffered: [(tab: String?, bytes: [UInt8])] = []
    private let relay = ScriptRelay()

    /// The shell is not started until the pane is first opened: it costs ~340 ms and one
    /// `ssh-agent` on this machine (T0), and neither belongs on the path to a first window.
    private(set) var started = false

    var onSessionExit: (() -> Void)?
    /// A command finished in the terminal. The window uses it to refresh the repository beside it —
    /// `git commit` changes what the lists say without touching a single watched file.
    var onCommandFinished: ((Int?) -> Void)?
    /// The directory the shell reports it is in, and the one the reader has selected. When they
    /// disagree the pane says so rather than implying the terminal is where the diff is.
    private(set) var selectedDirectory: String?

    var shellDirectory: String? { session?.reportedDirectory }

    override init() {
        super.init()
        let configuration = WKWebViewConfiguration()
        relay.onMessage = { [weak self] body in self?.handle(body) }
        configuration.userContentController.add(relay, name: "diffscopeTerminal")
        // A non-zero starting frame, for the reason recorded in M8-D: NSSplitView distributes by
        // preserving the proportions of the frames it already has, and a pane that starts at zero
        // stays at zero while reporting no error of any kind.
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: Theme.terminalPaneHeight),
                            configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
    }

    func load() {
        guard let html = Bundle.module.url(forResource: "terminal", withExtension: "html",
                                           subdirectory: "Renderer") else {
            FileHandle.standardError.write(Data("SELFTEST terminal=MISSING\n".utf8))
            return
        }
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        // Tabs opened before the page finished loading were opened into nothing:
        // `evaluateJavaScript` on an unloaded page is dropped without a word, and the first
        // selection afterwards then created a *third* grid for a tab the page had never heard of.
        // The pane's list is the truth; the page is told it again.
        for tab in tabs {
            webView.evaluateJavaScript("window.diffscopeTerminalOpenTab(\"\(tab.id)\")")
        }
        if let activeTabID {
            webView.evaluateJavaScript("window.diffscopeTerminalSelectTab(\"\(activeTabID)\")")
        }
        publishTabs()
        configureInput()
        publishMode()
        publishPrompt()
        publishDirectory()
        if !buffered.isEmpty {
            let pending = buffered
            buffered.removeAll()
            for chunk in pending { deliver(chunk.bytes, to: chunk.tab) }
        }
    }

    /// The page is told which keys to intercept rather than holding its own list (T2).
    private func configureInput() {
        let keys = InputRouter.interceptedKeys.map { "\"\($0)\"" }.joined(separator: ",")
        webView.evaluateJavaScript("window.diffscopeTerminalConfigure({interceptedKeys:[\(keys)]})")
    }

    private func publishMode() {
        let mode = session?.mode ?? .program
        let name: String
        switch mode {
        case .local: name = "local"
        case .program: name = "program"
        case .forcedRaw: name = "forcedRaw"
        case .handedOver: name = "handedOver"
        }
        let label = mode.label.replacingOccurrences(of: "\"", with: "")
        webView.evaluateJavaScript(
            "window.diffscopeTerminalSetMode && window.diffscopeTerminalSetMode(\"\(name)\", \"\(label)\")")
    }

    /// The prompt's last line, as spans, drawn beside the caret instead of in the grid (DEC-089).
    ///
    /// Read off the session rather than pushed from the callback, so the tab strip and this agree:
    /// selecting a tab publishes **that** tab's prompt, and a tab whose shell drew a prompt while it
    /// was off screen does not come back blank.
    private func publishPrompt() {
        let segments = session?.inlinePrompt
        let payload: [String: Any] = segments.map { list -> [String: Any] in
            ["segments": list.map { segment -> [String: Any] in
                var entry: [String: Any] = ["text": segment.text]
                if let colour = segment.foreground { entry["fg"] = colour }
                if let colour = segment.background { entry["bg"] = colour }
                for (name, on) in [("bold", segment.bold), ("dim", segment.dim),
                                   ("italic", segment.italic), ("underline", segment.underline),
                                   ("inverse", segment.inverse)] where on {
                    entry[name] = true
                }
                return entry
            }]
        } ?? ["segments": []]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.diffscopeTerminalSetPrompt && window.diffscopeTerminalSetPrompt(\(json))")
    }

    func toggleForcedRaw() {
        guard let session else { return }
        session.setForcedRaw(!session.isForcedRaw)
    }

    private func publishDirectory() {
        let shown = session?.reportedDirectory ?? selectedDirectory
        let diverged = shown != nil && selectedDirectory != nil && shown != selectedDirectory
        let name = (shown as NSString?)?.lastPathComponent ?? "unknown"
        let payload: [String: Any] = ["name": name, "path": shown ?? "", "diverged": diverged,
                                      "known": session?.reportedDirectory != nil]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.diffscopeTerminalSetDirectory && window.diffscopeTerminalSetDirectory(\(json))")
    }

    /// The reader selected a different repository. Under guard: see `TerminalSession.follow`.
    @discardableResult
    func follow(directory path: String, force: Bool = false) -> TerminalSession.FollowOutcome? {
        selectedDirectory = path
        guard let session else { publishDirectory(); return nil }
        var typed = ""
        // The typed line lives in the page, so it has to be read before deciding — asking after
        // sending would be deciding on a field that no longer says what it said.
        let semaphore = DispatchSemaphore(value: 0)
        webView.evaluateJavaScript("document.getElementById('line').value") { value, _ in
            typed = (value as? String) ?? ""
            semaphore.signal()
        }
        // The main queue drives the webview, so it cannot be blocked waiting for it.
        if Thread.isMainThread {
            let deadline = Date().addingTimeInterval(0.3)
            while semaphore.wait(timeout: .now()) == .timedOut, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
        } else {
            _ = semaphore.wait(timeout: .now() + 0.3)
        }
        let outcome = session.follow(directory: path, typedLine: typed, force: force)
        publishDirectory()
        return outcome
    }

    var isForcedRaw: Bool { session?.isForcedRaw ?? false }

    /// Puts text in the input line **without submitting it** (DEC-092's custom commands).
    ///
    /// Typed rather than run: the reader reads it, edits it, and presses Return — or does not. A
    /// custom command that executed itself would be a second path into the repository, which is
    /// the thing the closed registry exists to prevent.
    /// **No trailing newline**, which is the whole of it: the bytes reach the shell's own line
    /// editor, zsh echoes them where it echoes everything the reader types, and the command sits
    /// there until somebody presses Return.
    @discardableResult
    func type(_ text: String) -> Bool {
        guard let session else { return false }
        session.send(text)
        return true
    }

    /// `command`/`arguments` exist for the selftest, which must run the same path on a stranger's
    /// machine where `$SHELL` and `~/.zshrc` are somebody else's. The application itself passes
    /// neither and gets the user's own shell.
    @discardableResult
    func start(workingDirectory: String,
               command: String? = nil,
               arguments: [String]? = nil) -> Bool {
        guard tabs.isEmpty else { return true }
        return openTab(workingDirectory: workingDirectory, command: command, arguments: arguments)
    }

    /// A tab starts its shell when it is created, not when the drawer opens: DEC-053 measured
    /// ~340 ms to a prompt and one leaked `ssh-agent` per interactive shell, and a reader who asks
    /// for a second shell has asked for both.
    @discardableResult
    func openTab(workingDirectory: String,
                 command: String? = nil,
                 arguments: [String]? = nil) -> Bool {
        guard let session = TerminalSession(shellPath: command,
                                            workingDirectory: workingDirectory,
                                            arguments: arguments) else { return false }
        let id = "tab-\(nextTabNumber)"
        nextTabNumber += 1
        // Output is addressed to the tab it came from, so a suite running in a tab nobody is
        // looking at still writes into its own scrollback.
        session.onOutput = { [weak self] bytes in self?.deliver(bytes, to: id) }
        session.onExit = { [weak self] in self?.closeTab(id) }
        session.onModeChange = { [weak self] _ in self?.publishMode() }
        session.onPrompt = { [weak self] _ in self?.publishPrompt() }
        session.onDirectoryChange = { [weak self] _ in
            self?.publishDirectory()
            self?.publishTabs()
        }
        session.onCommandFinished = { [weak self] code in self?.onCommandFinished?(code) }
        let title = (command.map { ($0 as NSString).lastPathComponent })
            ?? (ProcessInfo.processInfo.environment["SHELL"] as NSString?)?.lastPathComponent
            ?? "shell"
        tabs.append(Tab(id: id, session: session, title: title))
        selectedDirectory = workingDirectory
        activeTabID = id
        webView.evaluateJavaScript("window.diffscopeTerminalOpenTab(\"\(id)\")")
        publishMode()
        publishTabs()
        started = true
        return true
    }

    func selectTab(_ id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        webView.evaluateJavaScript("window.diffscopeTerminalSelectTab(\"\(id)\")")
        publishMode()
        publishPrompt()
        publishDirectory()
        publishTabs()
    }

    /// The next tab along, wrapping — a strip is a ring, unlike a file list where the end is a fact
    /// worth feeling.
    func stepTab(by delta: Int) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        let next = (index + delta + tabs.count) % tabs.count
        selectTab(tabs[next].id)
    }

    func closeTab(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].session.stop()
        tabs.remove(at: index)
        webView.evaluateJavaScript("window.diffscopeTerminalCloseTab(\"\(id)\")")
        if activeTabID == id { activeTabID = tabs.first?.id }
        if tabs.isEmpty {
            started = false
            onSessionExit?()
        } else if let active = activeTabID {
            selectTab(active)
        }
        publishTabs()
    }

    func closeActiveTab() {
        guard let activeTabID else { return }
        closeTab(activeTabID)
    }

    /// What the strip says. The directory is the one each **shell** reports (OSC 7), not the one
    /// the reader selected — the distinction DEC-056 drew for one pane, made visible per tab.
    private func publishTabs() {
        let payload: [String: Any] = [
            "active": activeTabID ?? "",
            "tabs": tabs.map { tab -> [String: Any] in
                let reported = tab.session.reportedDirectory
                return ["id": tab.id, "title": tab.title,
                        "cwd": (reported as NSString?)?.lastPathComponent ?? "",
                        "diverged": reported != nil && selectedDirectory != nil
                            && reported != selectedDirectory]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.diffscopeTerminalSetTabs && window.diffscopeTerminalSetTabs(\(json))")
    }

    func stop() {
        // The page is told too. Clearing the list here and leaving the grids behind left the page
        // holding tabs no session was attached to, and the next selection landed on one of them —
        // a drawer showing a shell that had been dead for two arms.
        for tab in tabs {
            tab.session.stop()
            webView.evaluateJavaScript("window.diffscopeTerminalCloseTab(\"\(tab.id)\")")
        }
        tabs.removeAll()
        activeTabID = nil
        started = false
        publishTabs()
    }

    func focus() {
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("window.diffscopeTerminalFocus && window.diffscopeTerminalFocus()")
    }

    func probe(_ completion: @escaping (String) -> Void) {
        webView.evaluateJavaScript("JSON.stringify(window.diffscopeTerminalProbe())") { value, _ in
            completion((value as? String) ?? "")
        }
    }

    private func deliver(_ bytes: [UInt8], to tab: String? = nil) {
        guard ready else { buffered.append((tab: tab, bytes: bytes)); return }
        let base64 = Data(bytes).base64EncodedString()
        let target = tab.map { ", \"\($0)\"" } ?? ""
        webView.evaluateJavaScript("window.diffscopeTerminalWrite(\"\(base64)\"\(target))")
    }

    private func handle(_ body: Any) {
        guard let message = body as? [String: Any], let name = message["name"] as? String else { return }
        // A message names the tab it came from. Routing by "whichever Swift thinks is active" is a
        // race with the reader's hand: they can switch tabs between a keystroke and its delivery.
        let addressed = (message["tab"] as? String).flatMap { id in
            tabs.first { $0.id == id }?.session
        } ?? session
        switch name {
        case "selectTab":
            if let id = message["tab"] as? String { selectTab(id) }
        case "input":
            guard let data = message["data"] as? String else { return }
            addressed?.send(data)
        case "binary":
            // xterm hands binary over as a string of code points 0…255, one per byte.
            guard let data = message["data"] as? String else { return }
            addressed?.send(data.unicodeScalars.map { UInt8($0.value & 0xFF) })
        case "resize":
            guard let columns = message["cols"] as? Int, let rows = message["rows"] as? Int,
                  columns > 0, rows > 0 else { return }
            addressed?.resize(columns: UInt16(columns), rows: UInt16(rows))
        case "key":
            guard let session = addressed, let name = message["key"] as? String else { return }
            let key = InputKey(name,
                               control: message["control"] as? Bool ?? false,
                               alt: message["alt"] as? Bool ?? false,
                               meta: message["meta"] as? Bool ?? false,
                               shift: message["shift"] as? Bool ?? false)
            apply(session.handle(key: key, line: message["line"] as? String ?? ""))
        case "releaseForcedRaw":
            session?.setForcedRaw(false)
        case "toggleForcedRaw":
            toggleForcedRaw()
        default:
            break
        }
    }

    /// The field is told what to do about the key; the bytes have already gone to the PTY.
    private func apply(_ action: InputAction) {
        switch action {
        case .submit, .clearLine, .handOver:
            // A handed-over line belongs to the shell now, and it echoes what it received — leaving
            // the text here as well would show it twice.
            webView.evaluateJavaScript("window.diffscopeTerminalApply({clear:true})")
        case let .setLine(text):
            guard let encoded = try? JSONSerialization.data(withJSONObject: [text]),
                  let json = String(data: encoded, encoding: .utf8) else { return }
            let quoted = json.dropFirst().dropLast()
            webView.evaluateJavaScript("window.diffscopeTerminalApply({line:\(quoted)})")
        case .sendRaw(let bytes) where bytes == [0x03]:
            // ⌃C takes the half-typed line with it, the way it does in a terminal.
            webView.evaluateJavaScript("window.diffscopeTerminalApply({clear:true})")
        case .sendRaw, .recall, .releaseForcedRaw, .editLocally:
            break
        }
    }
}

/// A separate receiver so the content controller's strong reference to the message handler does not
/// hold the pane alive through a cycle.
private final class ScriptRelay: NSObject, WKScriptMessageHandler {
    var onMessage: ((Any) -> Void)?

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        onMessage?(message.body)
    }
}
