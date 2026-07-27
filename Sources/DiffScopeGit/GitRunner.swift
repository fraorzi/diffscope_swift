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

    public static func catFile(rev: String, path: String) -> GitOperation {
        GitOperation("cat-file", ["cat-file", "--textconv", "\(rev):\(path)"])
    }

    public static func catFileBlob(rev: String, path: String) -> GitOperation {
        GitOperation("cat-file-blob", ["cat-file", "blob", "\(rev):\(path)"])
    }

    public static func diffNameStatus(_ arguments: [String]) -> GitOperation {
        GitOperation("diff-name-status", ["diff", "--name-status", "--no-color"] + arguments)
    }

    public static func diffRaw(_ arguments: [String]) -> GitOperation {
        GitOperation("diff-raw", ["diff", "--no-color"] + arguments)
    }

    public static func checkAttr(_ attribute: String, path: String) -> GitOperation {
        GitOperation("check-attr", ["check-attr", attribute, "--", path])
    }

    public static func lsFiles() -> GitOperation {
        GitOperation("ls-files", ["ls-files", "-z"])
    }

    public static func remotes() -> GitOperation {
        GitOperation("remote", ["remote"])
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
        .catFile(rev: "HEAD", path: "a.txt"),
        .catFileBlob(rev: "HEAD", path: "a.txt"),
        .diffNameStatus([]),
        .diffRaw([]),
        .checkAttr("text", path: "a.txt"),
        .lsFiles(),
        .remotes(),
    ]
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
