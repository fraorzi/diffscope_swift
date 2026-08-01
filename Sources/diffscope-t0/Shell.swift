import DiffScopeTerminal
import Foundation

/// The gate drives the **shipping** module through this shim — `PtyProcess` for the PTY,
/// `PtyRecorder` for the assertions. Nothing about terminal behaviour lives here any more, which is
/// the point: a gate that measures its own copy of the code measures the wrong thing.
final class Shell {
    private let process: PtyProcess
    private let recorder: PtyRecorder

    init?(command: String,
          arguments: [String],
          environment: [String: String],
          workingDirectory: String,
          columns: UInt16 = 80,
          rows: UInt16 = 24) {
        guard let process = PtyProcess(command: command,
                                       arguments: arguments,
                                       environment: environment,
                                       workingDirectory: workingDirectory,
                                       columns: columns,
                                       rows: rows) else { return nil }
        self.process = process
        recorder = PtyRecorder(answeringQueries: true)
        recorder.attach(to: process)
    }

    func send(_ text: String) { process.write(text) }
    func resize(columns: UInt16, rows: UInt16) { process.resize(columns: columns, rows: rows) }
    func close() { process.terminate() }

    var transcript: String { recorder.transcript }
    var events: [TimedEvent] { recorder.events }
    var reportedAgentPids: [pid_t] { recorder.reportedAgentPids }
    var millisecondsToFirstPrompt: Double? { recorder.millisecondsToFirstPrompt }

    func count(_ match: (TerminalEvent) -> Bool) -> Int { recorder.count(match) }

    func wait(timeout: TimeInterval = 8, until predicate: ([TimedEvent], String) -> Bool) -> Bool {
        recorder.wait(timeout: timeout, until: predicate)
    }

    func waitForEvent(_ match: @escaping (TerminalEvent) -> Bool, timeout: TimeInterval = 8) -> Bool {
        recorder.waitForEvent(match, timeout: timeout)
    }

    func waitForText(_ needle: String, timeout: TimeInterval = 8) -> Bool {
        recorder.waitForText(needle, timeout: timeout)
    }

    func waitForCount(_ match: @escaping (TerminalEvent) -> Bool,
                      atLeast target: Int,
                      timeout: TimeInterval = 8) -> Bool {
        recorder.waitForCount(match, atLeast: target, timeout: timeout)
    }
}
