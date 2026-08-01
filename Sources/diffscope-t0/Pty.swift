import Darwin
import Foundation

/// One interactive shell on a real PTY, driven the way the application would drive it.
///
/// `zsh -i -c` is deliberately not used anywhere here: it never enters the prompt loop, so the
/// hooks never fire, and it produced the false negative recorded in `22-experiment-log.md`.
final class Shell {
    let master: Int32
    let pid: pid_t
    let startedAt = Date()

    private let condition = NSCondition()
    private var raw: [UInt8] = []
    private var timed: [TimedEvent] = []
    private var reachedEndOfFile = false
    private let scanner = VTScanner()

    init?(command: String,
          arguments: [String],
          environment: [String: String],
          workingDirectory: String,
          columns: UInt16 = 80,
          rows: UInt16 = 24) {
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        var descriptor: Int32 = -1

        // Everything the child touches between fork and exec is prepared here: after a fork only
        // async-signal-safe work is legal, and allocating in the Swift runtime is not.
        let argv: [UnsafeMutablePointer<CChar>?] = ([command] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let path = strdup(command)
        let directory = strdup(workingDirectory)

        let child = forkpty(&descriptor, nil, nil, &size)
        if child == 0 {
            if chdir(directory) != 0 { _exit(126) }
            execve(path, argv, envp)
            _exit(127)
        }

        for pointer in argv where pointer != nil { free(pointer) }
        for pointer in envp where pointer != nil { free(pointer) }
        free(path)
        free(directory)

        guard child > 0 else { return nil }
        master = descriptor
        pid = child

        scanner.onEvent = { [weak self] event in self?.append(event) }
        scanner.onReply = { [weak self] reply in self?.send(reply) }

        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "diffscope-t0.pty"
        thread.start()
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, 8192) }
            guard count > 0 else {
                condition.lock()
                reachedEndOfFile = true
                condition.broadcast()
                condition.unlock()
                return
            }
            condition.lock()
            raw.append(contentsOf: buffer[0..<count])
            condition.broadcast()
            condition.unlock()
            scanner.feed(buffer[0..<count])
        }
    }

    private func append(_ event: TerminalEvent) {
        condition.lock()
        timed.append(TimedEvent(event: event, at: Date()))
        condition.broadcast()
        condition.unlock()
    }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { write(master, $0.baseAddress! + offset, bytes.count - offset) }
            if written <= 0 { return }
            offset += written
        }
    }

    func resize(columns: UInt16, rows: UInt16) {
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    var transcript: String {
        condition.lock()
        defer { condition.unlock() }
        return String(decoding: raw, as: UTF8.self)
    }

    var events: [TimedEvent] {
        condition.lock()
        defer { condition.unlock() }
        return timed
    }

    /// Waits until the predicate holds over everything seen so far. Returns false on timeout, and
    /// the caller reports what *did* arrive — a timeout is a measurement, not only a failure.
    func wait(timeout: TimeInterval = 8, until predicate: ([TimedEvent], String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if predicate(timed, String(decoding: raw, as: UTF8.self)) { return true }
            if Date() >= deadline || reachedEndOfFile {
                return predicate(timed, String(decoding: raw, as: UTF8.self))
            }
            condition.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
    }

    func waitForEvent(_ match: @escaping (TerminalEvent) -> Bool, timeout: TimeInterval = 8) -> Bool {
        wait(timeout: timeout) { events, _ in events.contains(match) }
    }

    /// The count of matching events has to be read before an action and waited on after it —
    /// "another prompt" is not the same claim as "a prompt".
    func count(_ match: (TerminalEvent) -> Bool) -> Int {
        events.filter { match($0.event) }.count
    }

    func waitForCount(_ match: @escaping (TerminalEvent) -> Bool,
                      atLeast target: Int,
                      timeout: TimeInterval = 8) -> Bool {
        wait(timeout: timeout) { events, _ in events.filter { match($0.event) }.count >= target }
    }

    func waitForText(_ needle: String, timeout: TimeInterval = 8) -> Bool {
        wait(timeout: timeout) { _, text in text.contains(needle) }
    }

    /// The shell is asked to leave, then made to. Nothing of this probe may outlive it.
    func close() {
        kill(pid, SIGHUP)
        let deadline = Date().addingTimeInterval(2)
        var status: Int32 = 0
        while Date() < deadline {
            if waitpid(pid, &status, WNOHANG) == pid {
                Darwin.close(master)
                return
            }
            usleep(20_000)
        }
        kill(pid, SIGKILL)
        _ = waitpid(pid, &status, 0)
        Darwin.close(master)
    }

    /// The probe's own side channel, emitted by the generated rc file: the agent this shell's
    /// startup files spawned, so the probe can clean up exactly what it caused and nothing else.
    var reportedAgentPids: [pid_t] {
        events.compactMap {
            guard case let .note(text) = $0.event, text.hasPrefix("agent=") else { return nil }
            return pid_t(text.dropFirst("agent=".count))
        }
    }

    var millisecondsToFirstPrompt: Double? {
        guard let first = events.first(where: { isPromptStart($0.event) }) else { return nil }
        return first.at.timeIntervalSince(startedAt) * 1000
    }
}
