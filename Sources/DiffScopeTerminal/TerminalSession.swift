import Foundation

/// A shell, its PTY, its prompt marks and the grid's view of it.
///
/// **This is the only place in the product that starts a process the user can type into.** DEC-028
/// is unchanged by the terminal existing: nothing here is derived from repository content — not the
/// command, not an argument, not a prefilled line. The shell comes from `$SHELL`, the directory
/// comes from the reader's selection, and everything else the user types themselves.
public final class TerminalSession {
    public enum State: Equatable {
        case starting
        case atPrompt
        case programRunning
    }

    public let shellPath: String
    public let kind: ShellKind
    public private(set) var state: State = .starting

    /// Coalesced output, delivered on the main queue. Raw bytes: see `PtyProcess` for why nothing
    /// is decoded on the way.
    public var onOutput: (([UInt8]) -> Void)?
    public var onStateChange: ((State) -> Void)?
    public var onExit: (() -> Void)?

    private let integration: ShellIntegration
    private let process: PtyProcess
    private let scanner = TerminalScanner()
    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var flushScheduled = false

    /// A `read` per `evaluateJavaScript` makes `cat` of a large file thousands of round trips into
    /// the webview. One frame's worth of bytes at a time instead; measured in T1-A.
    public static let flushInterval: TimeInterval = 0.016

    public init?(shellPath: String? = nil,
                 workingDirectory: String,
                 columns: UInt16 = 80,
                 rows: UInt16 = 24,
                 arguments: [String]? = nil,
                 environment: [String: String] = ProcessInfo.processInfo.environment) {
        let resolved = shellPath ?? environment["SHELL"] ?? "/bin/zsh"
        let kind = ShellKind.of(path: resolved)
        guard let integration = try? ShellIntegration.generate(for: kind) else { return nil }

        let home = environment["HOME"] ?? NSHomeDirectory()
        guard let process = PtyProcess(
            command: resolved,
            arguments: arguments ?? integration.arguments,
            environment: integration.environment(base: environment,
                                                 userZdotdir: environment["ZDOTDIR"] ?? home),
            workingDirectory: workingDirectory,
            columns: columns,
            rows: rows
        ) else {
            integration.remove()
            return nil
        }

        self.shellPath = resolved
        self.kind = kind
        self.integration = integration
        self.process = process

        // `onReply` stays nil: xterm.js answers device queries itself, and a second answer from
        // here would reach the program as stray input.
        scanner.onEvent = { [weak self] event in self?.apply(event) }
        process.onOutput = { [weak self] bytes in self?.receive(bytes) }
        process.onExit = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.onExit?() }
        }
    }

    private func receive(_ bytes: [UInt8]) {
        scanner.feed(bytes[...])
        lock.lock()
        pending.append(contentsOf: bytes)
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        lock.lock()
        let bytes = pending
        pending.removeAll(keepingCapacity: true)
        flushScheduled = false
        lock.unlock()
        guard !bytes.isEmpty else { return }
        onOutput?(bytes)
    }

    private func apply(_ event: TerminalEvent) {
        let next: State?
        switch event {
        case .promptStart, .promptEnd: next = .atPrompt
        case .commandStart: next = .programRunning
        case .commandEnd: next = .atPrompt
        default: next = nil
        }
        guard let next, next != state else { return }
        DispatchQueue.main.async {
            self.state = next
            self.onStateChange?(next)
        }
    }

    /// The user's keystrokes, and nothing else. T2 splits this into a local input line and raw
    /// passthrough; until then every key goes straight through.
    public func send(_ bytes: [UInt8]) { process.write(bytes) }
    public func send(_ text: String) { process.write(text) }

    public func resize(columns: UInt16, rows: UInt16) { process.resize(columns: columns, rows: rows) }

    public var windowSize: (columns: UInt16, rows: UInt16)? { process.windowSize }
    public var isRunning: Bool { process.isRunning }
    public var processIdentifier: pid_t { process.pid }

    public func stop() {
        process.terminate()
        integration.remove()
    }
}
