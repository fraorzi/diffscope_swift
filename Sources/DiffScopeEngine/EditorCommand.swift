import Foundation

/// DEC-015: opening the editor is configured by a template the *user* sets, never assembled from
/// repository content. Splitting the template from launching it is what makes F13 checkable — the
/// harness can assert what argv a template produces and what a failing command reports, neither of
/// which is observable through an application that only launches.
public struct EditorCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]

    /// DEC-082. This was `/usr/bin/open -a WebStorm {file}` for eight milestones, and the missing
    /// `{line}` was the last open item of the POC audit — `⌘⏎` opened the file at the top whatever
    /// the reader was looking at.
    ///
    /// **The IDE's own launcher rather than `open`**, for a measured reason. `open -a` cannot take
    /// a line at all, and the obvious replacement — a `jetbrains://…?path={file}:{line}` URL —
    /// leaves `#` and `?` raw in the path: `…/note#1/a.ts` becomes a URL fragment and the editor
    /// receives `path=…/note`, which is **the wrong file, opened silently**. This form parses no
    /// URL, so those are ordinary characters, and the split-before-substitute rule below is what
    /// keeps a path with a space one argument.
    ///
    /// The path is an install location: a WebStorm reached only through JetBrains Toolbox is not
    /// here, and the default then fails **visibly** as `notLaunched` (F13, `13-…` §2). A default
    /// that fails loudly is worth more than one that opens the wrong line quietly.
    public static let defaultTemplate =
        "/Applications/WebStorm.app/Contents/MacOS/webstorm --line {line} {file}"

    /// `file` and `line` are substituted; nothing else is. A template with no `{file}` is accepted
    /// as written rather than repaired — a silently corrected command opens the wrong thing.
    ///
    /// **The template is split first and substituted afterwards.** Substituting first and splitting
    /// the result gives the path's spaces the same meaning as the template's, so
    /// `~/My Projects/a.ts` arrives as three arguments and the editor opens the wrong file — or
    /// none. Tokenising the user's configuration and then filling the tokens keeps the two apart:
    /// the template decides what the arguments are, the path only decides their contents.
    public init?(template: String, file: String, line: Int) {
        let parts = template.split(separator: " ").map {
            $0.replacingOccurrences(of: "{file}", with: file)
                .replacingOccurrences(of: "{line}", with: String(line))
        }
        guard let executable = parts.first, !executable.isEmpty else { return nil }
        self.executable = executable
        self.arguments = Array(parts.dropFirst())
    }
}

/// What happened when the editor was asked to open a file. `13-…` §2 names **both** arms of F13 —
/// "non-zero exit / not found" — and the application reported only the second for a milestone,
/// because a command that launches and then fails looks identical to success from the call site.
public enum EditorLaunchOutcome: Sendable, Equatable {
    case opened(String)
    case notLaunched(String)
    case failed(exitCode: Int32)

    public var succeeded: Bool {
        if case .opened = self { return true }
        return false
    }

    public var message: String {
        switch self {
        case let .opened(path): return "opened \(path) in the editor"
        case let .notLaunched(reason): return "open in editor failed — \(reason)"
        case let .failed(code): return "open in editor failed — the command exited with status \(code)"
        }
    }
}

/// Runs the command and waits for it, so a non-zero exit is observed rather than assumed away.
///
/// Waiting is safe for the launchers this is used with: `open -a` returns as soon as it has handed
/// the file to the application, and a template that blocks would block the same way when run by
/// hand. `timeout` bounds the wait so a badly chosen template cannot hang the interface; a command
/// still running at the deadline is reported as opened, since it launched and has not failed.
public func launchEditor(
    _ command: EditorCommand,
    file: String,
    timeout: TimeInterval = 5
) -> EditorLaunchOutcome {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command.executable)
    process.arguments = command.arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return .notLaunched(String(describing: error))
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        usleep(20_000)
    }
    guard !process.isRunning else { return .opened(file) }
    return process.terminationStatus == 0 ? .opened(file) : .failed(exitCode: process.terminationStatus)
}
