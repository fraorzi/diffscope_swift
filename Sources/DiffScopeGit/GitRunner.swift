import Foundation

public struct GitOperation: Sendable, Equatable {
    public let label: String
    public let arguments: [String]

    private init(_ label: String, _ arguments: [String]) {
        self.label = label
        self.arguments = arguments
    }

    public static func statusPorcelain() -> GitOperation {
        GitOperation("status", ["status", "--porcelain"])
    }

    public static func statusPorcelainUall() -> GitOperation {
        GitOperation("status-uall", ["status", "--porcelain", "-uall"])
    }

    public static func revParseVerifyHead() -> GitOperation {
        GitOperation("rev-parse-verify-head", ["rev-parse", "--verify", "--quiet", "HEAD"])
    }

    public static func symbolicRefHead() -> GitOperation {
        GitOperation("symbolic-ref-head", ["symbolic-ref", "--quiet", "--short", "HEAD"])
    }

    public static func originHead() -> GitOperation {
        GitOperation("origin-head", ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])
    }

    public static func showRefVerify(_ ref: String) -> GitOperation {
        GitOperation("show-ref-verify", ["show-ref", "--verify", "--quiet", ref])
    }

    public static func mergeBase(_ a: String, _ b: String) -> GitOperation {
        GitOperation("merge-base", ["merge-base", a, b])
    }

    public static func revListCount(_ range: String) -> GitOperation {
        GitOperation("rev-list-count", ["rev-list", "--count", range])
    }

    public static func refCommitterDate(_ ref: String) -> GitOperation {
        GitOperation("log-committer-date", ["log", "-1", "--format=%cI", ref])
    }

    // `cat-file --textconv` was registered here and never called. It is read-only in the sense R-8
    // proves — it leaves `.git` byte-identical — and that is exactly why it was dangerous to leave
    // lying in a registry whose purpose is to make DEC-028 structural: `--textconv` runs a command
    // the *repository* configures. Removed by DEC-051, with `noExecutingArguments` below standing
    // guard so it cannot come back as a convenience.

    public static func catFileBlob(rev: String, path: String) -> GitOperation {
        GitOperation("cat-file-blob", ["cat-file", "blob", "\(rev):\(path)"])
    }

    public static func diffNameStatus(_ arguments: [String]) -> GitOperation {
        GitOperation("diff-name-status", ["diff", "--name-status", "--no-color"] + arguments)
    }

    public static func diffRaw(_ arguments: [String]) -> GitOperation {
        GitOperation("diff-raw", ["diff", "--no-color"] + arguments)
    }

    /// Line counts per file, for the list (`12-…` §4). `--numstat` because the porcelain formats
    /// are presentations and this one is documented output: two counts and a path, with `-` in
    /// both count columns where a line count would be meaningless — which is git saying *binary*
    /// rather than *zero*, and the difference is the whole reason this is not computed from a
    /// diff we parse ourselves.
    public static func diffNumstat(_ arguments: [String]) -> GitOperation {
        GitOperation("diff-numstat", ["diff", "--numstat", "--no-color"] + arguments)
    }

    /// One invocation for every attribute that can make the compared bytes differ from `git diff`'s
    /// (DEC-028). `-z` because a path may contain anything, including the separator git would
    /// otherwise use.
    public static func checkAttr(_ attributes: [String], path: String) -> GitOperation {
        GitOperation("check-attr", ["check-attr", "-z"] + attributes + ["--", path])
    }

    public static func lsFiles() -> GitOperation {
        GitOperation("ls-files", ["ls-files", "-z"])
    }

    public static func remotes() -> GitOperation {
        GitOperation("remote", ["remote"])
    }

    /// The two lenses (DEC-061). Both read, and both enter the registry rather than being issued
    /// beside it: R-8's proof is over this list, so an operation that is not here cannot be run at
    /// all — which is the whole point of a closed registry.
    ///
    /// `--porcelain` on blame for the reason `--porcelain` is used on status: the human format is
    /// a presentation and changes; this one is documented output. `-w` is deliberately **not**
    /// passed — ignoring whitespace would hand authorship of a line to whoever last changed it
    /// meaningfully, which is a judgement the product owner declined (they asked for the option to
    /// be dropped, not defaulted).
    public static func blame(path: String) -> GitOperation {
        GitOperation("blame", ["blame", "--porcelain", "--", path])
    }

    /// One record per commit, field-separated by a unit separator so a subject containing anything
    /// at all still parses. `-n` bounds the read: a repository's whole history is not a screen.
    public static func log(limit: Int) -> GitOperation {
        GitOperation("log", ["log", "-n", String(limit),
                             "--format=%H\u{1f}%an\u{1f}%cI\u{1f}%s\u{1f}%D"])
    }

    public static let allProvenReadOnly: [GitOperation] = [
        .statusPorcelain(),
        .statusPorcelainUall(),
        .revParseVerifyHead(),
        .symbolicRefHead(),
        .originHead(),
        .showRefVerify("refs/heads/main"),
        .mergeBase("HEAD", "HEAD"),
        .revListCount("HEAD..HEAD"),
        .refCommitterDate("HEAD"),
        .catFileBlob(rev: "HEAD", path: "a.txt"),
        .diffNameStatus([]),
        .diffNumstat([]),
        .diffRaw([]),
        .checkAttr(FilterCheck.attributes, path: "a.txt"),
        .lsFiles(),
        .remotes(),
        .blame(path: "a.txt"),
        .log(limit: 1),
    ]

    /// Arguments that would let repository content decide what runs, or let a caller inject
    /// configuration into an operation the registry claims to describe (DEC-028, DEC-003).
    ///
    /// R-8 proves an operation does not *write*. That is a different property from not *executing*,
    /// and `cat-file --textconv` satisfied the first while breaking the second for two milestones.
    public static let forbiddenArguments = ["--textconv", "--filters", "--ext-diff", "-c"]

    /// Registered operations that would execute repository-configured commands. Empty is the only
    /// acceptable value; the check reports the offenders rather than a boolean.
    public static var executingOperations: [GitOperation] {
        allProvenReadOnly.filter { operation in
            operation.arguments.contains { forbiddenArguments.contains($0) }
        }
    }
}

public struct GitInvocationResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: String

    public var succeeded: Bool { exitCode == 0 }
    public var trimmedOutput: String {
        String(decoding: standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum GitRunnerError: Error, CustomStringConvertible {
    case executableMissing
    case launchFailed(String)

    public var description: String {
        switch self {
        case .executableMissing: return "git executable not found"
        case let .launchFailed(message): return "failed to launch git: \(message)"
        }
    }
}

public final class GitRunner: @unchecked Sendable {
    public static let readOnlyGlobalArguments = ["--no-optional-locks"]

    private static let lock = NSLock()
    private static var executed: Set<String> = []

    public static var executedOperationLabels: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return executed
    }

    public static func resetExecutedOperationLabels() {
        lock.lock()
        executed = []
        lock.unlock()
    }

    public let executableURL: URL

    public init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.executableURL = executableURL
    }

    public func run(_ operation: GitOperation, in repository: URL) throws -> GitInvocationResult {
        GitRunner.lock.lock()
        GitRunner.executed.insert(operation.label)
        GitRunner.lock.unlock()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = GitRunner.readOnlyGlobalArguments
            + ["-C", repository.path]
            + operation.arguments

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw GitRunnerError.launchFailed(String(describing: error))
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return GitInvocationResult(
            exitCode: process.terminationStatus,
            standardOutput: outData,
            standardError: String(decoding: errData, as: UTF8.self)
        )
    }
}
