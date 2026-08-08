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
    public var onModeChange: ((InputMode) -> Void)?
    public var onExit: (() -> Void)?
    /// Where the shell says it is (OSC 7). `nil` until it says — a shell with no integration never
    /// reports, and the pane says it does not know rather than showing where the shell *started*.
    public private(set) var reportedDirectory: String?
    public var onDirectoryChange: ((String) -> Void)?
    /// A command finished (OSC 133;D). This is the one thing the file-system watcher cannot know:
    /// `git commit` leaves the working tree untouched while the repository's status changes.
    public var onCommandFinished: ((Int?) -> Void)?

    /// Which surface owns the keyboard right now (T2). Raw until a prompt mark says otherwise: a
    /// shell that marks nothing — an unrecognised `$SHELL`, or one whose rc file the integration
    /// could not reach — then behaves like every other terminal instead of pretending.
    public private(set) var mode: InputMode = .program
    private let router = InputRouter()
    private var history = SessionHistory()
    private var forcedRaw = false
    private var handedOver = false
    /// Whether this shell has ever marked a prompt. The guard in `follow` asks this rather than
    /// asking what the shell is called.
    public private(set) var hasSeenPromptMark = false

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
        if case let .workingDirectory(path) = event {
            DispatchQueue.main.async {
                guard self.reportedDirectory != path else { return }
                self.reportedDirectory = path
                self.onDirectoryChange?(path)
            }
            return
        }
        if case let .commandEnd(code) = event {
            DispatchQueue.main.async { self.onCommandFinished?(code) }
        }

        // A prompt mark is what ends a handover: the shell has finished with the line it was given.
        let endsHandover = isPromptStart(event) || isPromptEnd(event)
        if endsHandover { DispatchQueue.main.async { self.hasSeenPromptMark = true } }
        guard next != nil || endsHandover else { return }
        DispatchQueue.main.async {
            if endsHandover { self.handedOver = false }
            if let next, next != self.state {
                self.state = next
                self.onStateChange?(next)
            }
            self.refreshMode()
        }
    }

    /// One place decides the mode, from three inputs: where the shell is, whether the reader forced
    /// raw, and whether the shell was handed the line.
    private func refreshMode() {
        let next: InputMode
        if forcedRaw {
            next = .forcedRaw
        } else if handedOver {
            next = .handedOver
        } else {
            switch state {
            case .atPrompt: next = .local
            case .programRunning, .starting: next = .program
            }
        }
        guard next != mode else { return }
        mode = next
        onModeChange?(next)
    }

    /// The escape hatch (`26-terminal-plan.md` §4). Detection will be wrong sometimes, and being
    /// unable to type into an `ssh` password prompt would be worse than never having the feature.
    public func setForcedRaw(_ on: Bool) {
        guard forcedRaw != on else { return }
        forcedRaw = on
        refreshMode()
    }

    public var isForcedRaw: Bool { forcedRaw }

    /// Routes one keystroke and performs whatever it means on the PTY, returning what the input
    /// field should do about it. `recall` is resolved here, against the history this session holds.
    @discardableResult
    public func handle(key: InputKey, line: String) -> InputAction {
        let action = router.route(key: key, line: line, mode: mode)
        switch action {
        case let .submit(text):
            history.remember(text)
            send(text + "\r")
        case let .handOver(text, keyBytes):
            if !text.isEmpty { send(text) }
            send(keyBytes)
            handedOver = true
            refreshMode()
        case let .sendRaw(bytes):
            send(bytes)
        case let .recall(offset):
            guard let recalled = history.recall(offset: offset) else { return .editLocally }
            return .setLine(recalled)
        case .releaseForcedRaw:
            setForcedRaw(false)
        case .setLine, .clearLine, .editLocally:
            break
        }
        return action
    }

    public var historyCount: Int { history.count }

    /// Why a `cd` was or was not sent. The refusals are the interesting half: this is the
    /// application typing into the reader's shell, so it does so only when there is provably
    /// nothing to disturb (DEC-056).
    public enum FollowOutcome: Equatable {
        case sent(String)
        case alreadyThere
        /// A program is running, the reader forced raw, or the shell was handed the line — all
        /// three mean somebody other than the input field owns the keyboard.
        case refusedNotAtPrompt
        case refusedLineNotEmpty
        case refusedNoPromptMarks

        public var wasSent: Bool { if case .sent = self { return true }; return false }
    }

    /// Follows the reader's selection into the shell — under guard.
    ///
    /// `line` is what is currently typed in the input field. The conjunction matters: at a prompt,
    /// **and** nothing typed, **and** the shell has not been handed the line. If prompt detection is
    /// ever wrong, this is what stops a `cd` landing in the middle of something.
    @discardableResult
    public func follow(directory path: String, typedLine: String, force: Bool = false) -> FollowOutcome {
        // On marks *seen*, not on what the shell binary is called. A shell this product does not
        // recognise may still be marking its prompts — the reader's own integration, or a fish
        // config — and refusing it for its name would be answering a different question. The check
        // that found this was driving `/bin/sh` emitting marks by hand.
        guard force || hasSeenPromptMark else { return .refusedNoPromptMarks }
        if let reportedDirectory, reportedDirectory == path, !force { return .alreadyThere }
        if !force {
            guard mode == .local else { return .refusedNotAtPrompt }
            guard typedLine.isEmpty else { return .refusedLineNotEmpty }
        }
        let command = changeDirectoryCommand(to: path)
        send(command + "\r")
        return .sent(command)
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
