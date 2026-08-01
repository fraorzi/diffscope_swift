import Foundation

/// Turns a PTY's stream into something a check can assert against: the bytes so far, the marks so
/// far, and a wait with a deadline.
///
/// It exists in the module rather than in the check suite because gate T0 and `diffscope-verify`
/// both need it, and because a gate that measures a copy of the code measures the wrong thing.
public final class PtyRecorder {
    private let condition = NSCondition()
    private var raw: [UInt8] = []
    private var timed: [TimedEvent] = []
    private var closed = false
    private let scanner = TerminalScanner()
    public let startedAt = Date()

    private let answersQueries: Bool

    /// `answeringQueries` belongs only where there is no emulator behind the recorder: a
    /// full-screen program asks who it is talking to and waits for an answer. In the application
    /// xterm.js answers, and a second answer would reach the program as stray input.
    public init(answeringQueries: Bool) {
        answersQueries = answeringQueries
        scanner.onEvent = { [weak self] event in self?.append(event) }
    }

    public func attach(to process: PtyProcess) {
        process.onOutput = { [weak self] bytes in self?.receive(bytes) }
        process.onExit = { [weak self] in self?.finish() }
        if answersQueries {
            scanner.onReply = { [weak process] reply in process?.write(reply) }
        }
    }

    public func receive(_ bytes: [UInt8]) {
        condition.lock()
        raw.append(contentsOf: bytes)
        condition.broadcast()
        condition.unlock()
        scanner.feed(bytes[...])
    }

    private func append(_ event: TerminalEvent) {
        condition.lock()
        timed.append(TimedEvent(event: event, at: Date()))
        condition.broadcast()
        condition.unlock()
    }

    private func finish() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    public var transcript: String {
        condition.lock()
        defer { condition.unlock() }
        return String(decoding: raw, as: UTF8.self)
    }

    public var bytes: [UInt8] {
        condition.lock()
        defer { condition.unlock() }
        return raw
    }

    public var events: [TimedEvent] {
        condition.lock()
        defer { condition.unlock() }
        return timed
    }

    /// Waits until the predicate holds over everything seen so far. A timeout returns the predicate's
    /// last answer rather than throwing, because what *did* arrive is the measurement.
    public func wait(timeout: TimeInterval = 8,
                     until predicate: ([TimedEvent], String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if predicate(timed, String(decoding: raw, as: UTF8.self)) { return true }
            if Date() >= deadline || closed {
                return predicate(timed, String(decoding: raw, as: UTF8.self))
            }
            condition.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
    }

    public func waitForEvent(_ match: @escaping (TerminalEvent) -> Bool,
                             timeout: TimeInterval = 8) -> Bool {
        wait(timeout: timeout) { events, _ in events.contains(match) }
    }

    public func waitForText(_ needle: String, timeout: TimeInterval = 8) -> Bool {
        wait(timeout: timeout) { _, text in text.contains(needle) }
    }

    public func count(_ match: (TerminalEvent) -> Bool) -> Int {
        events.filter { match($0.event) }.count
    }

    /// "Another prompt" is a different claim from "a prompt", so the count is read before the
    /// action and waited on after it.
    public func waitForCount(_ match: @escaping (TerminalEvent) -> Bool,
                             atLeast target: Int,
                             timeout: TimeInterval = 8) -> Bool {
        wait(timeout: timeout) { events, _ in events.filter { match($0.event) }.count >= target }
    }

    public var millisecondsToFirstPrompt: Double? {
        guard let first = events.first(where: { isPromptStart($0.event) }) else { return nil }
        return first.at.timeIntervalSince(startedAt) * 1000
    }

    /// The side channel the generated rc file uses to name the agent it started.
    public var reportedAgentPids: [pid_t] {
        events.compactMap {
            guard case let .note(text) = $0.event, text.hasPrefix("agent=") else { return nil }
            return pid_t(text.dropFirst("agent=".count))
        }
    }
}
