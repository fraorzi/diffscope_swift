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
    private(set) var session: TerminalSession?
    private var ready = false
    private var buffered: [UInt8] = []
    private let relay = ScriptRelay()

    /// The shell is not started until the pane is first opened: it costs ~340 ms and one
    /// `ssh-agent` on this machine (T0), and neither belongs on the path to a first window.
    private(set) var started = false

    var onSessionExit: (() -> Void)?

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
        configureInput()
        publishMode()
        if !buffered.isEmpty {
            let pending = buffered
            buffered.removeAll()
            deliver(pending)
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

    func toggleForcedRaw() {
        guard let session else { return }
        session.setForcedRaw(!session.isForcedRaw)
    }

    var isForcedRaw: Bool { session?.isForcedRaw ?? false }

    /// `command`/`arguments` exist for the selftest, which must run the same path on a stranger's
    /// machine where `$SHELL` and `~/.zshrc` are somebody else's. The application itself passes
    /// neither and gets the user's own shell.
    @discardableResult
    func start(workingDirectory: String,
               command: String? = nil,
               arguments: [String]? = nil) -> Bool {
        guard session == nil else { return true }
        guard let session = TerminalSession(shellPath: command,
                                            workingDirectory: workingDirectory,
                                            arguments: arguments) else { return false }
        session.onOutput = { [weak self] bytes in self?.deliver(bytes) }
        session.onExit = { [weak self] in self?.onSessionExit?() }
        session.onModeChange = { [weak self] _ in self?.publishMode() }
        self.session = session
        webView.evaluateJavaScript("window.diffscopeTerminalReset && window.diffscopeTerminalReset()")
        publishMode()
        started = true
        return true
    }

    func stop() {
        session?.stop()
        session = nil
        started = false
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

    private func deliver(_ bytes: [UInt8]) {
        guard ready else { buffered.append(contentsOf: bytes); return }
        let base64 = Data(bytes).base64EncodedString()
        webView.evaluateJavaScript("window.diffscopeTerminalWrite(\"\(base64)\")")
    }

    private func handle(_ body: Any) {
        guard let message = body as? [String: Any], let name = message["name"] as? String else { return }
        switch name {
        case "input":
            guard let data = message["data"] as? String else { return }
            session?.send(data)
        case "binary":
            // xterm hands binary over as a string of code points 0…255, one per byte.
            guard let data = message["data"] as? String else { return }
            session?.send(data.unicodeScalars.map { UInt8($0.value & 0xFF) })
        case "resize":
            guard let columns = message["cols"] as? Int, let rows = message["rows"] as? Int,
                  columns > 0, rows > 0 else { return }
            session?.resize(columns: UInt16(columns), rows: UInt16(rows))
        case "key":
            guard let session, let name = message["key"] as? String else { return }
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
