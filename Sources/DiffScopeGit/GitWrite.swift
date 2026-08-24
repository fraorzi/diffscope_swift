import Foundation

/// What an operation can cost the user if it is wrong (DEC-092 §5).
///
/// The class is declared on the operation rather than decided at the call site, because the call
/// site is where a confirmation gets skipped "just this once". `Confirmation.required(for:)` is the
/// only function that maps a class onto a question, so there is one place to read and one place to
/// change.
public enum WriteRisk: String, Sendable, Equatable, CaseIterable {
    /// Nothing existing is lost. Staging, committing, creating a branch.
    case additive
    /// Undoable from a restore point this application takes before it runs.
    case recoverable
    /// Data can leave the repository and not be in the object database anywhere.
    case destructive
    /// Leaves the machine. Always explicit, never automatic (DEC-011 as amended).
    case network
}

/// A Git operation that **writes**, and is proven to be the one that ran.
///
/// The read registry (`GitOperation.allProvenReadOnly`) proves a negative: nothing it contains
/// changes `.git`. This registry cannot prove that and does not pretend to. What it holds instead
/// is the *closure* property that has been true of this product since M2 — a Git invocation that is
/// not in a registry cannot happen — plus a declared risk class per operation, and, for the staging
/// operations, INV-6.
public struct GitWriteOperation: Sendable, Equatable {
    public let label: String
    public let arguments: [String]
    public let risk: WriteRisk

    private init(_ label: String, _ arguments: [String], _ risk: WriteRisk) {
        self.label = label
        self.arguments = arguments
        self.risk = risk
    }

    // ---- index and working tree -------------------------------------------------------------

    public static func addPaths(_ paths: [String]) -> GitWriteOperation {
        GitWriteOperation("add", ["add", "--"] + paths, .additive)
    }

    /// `-N` makes an untracked file addressable by a patch without putting its content in the
    /// index. Without it the first hunk a reader selects out of a new file has nothing to apply to.
    public static func addIntentToAdd(_ paths: [String]) -> GitWriteOperation {
        GitWriteOperation("add-intent", ["add", "-N", "--"] + paths, .additive)
    }

    public static func restoreStaged(_ paths: [String]) -> GitWriteOperation {
        GitWriteOperation("restore-staged", ["restore", "--staged", "--"] + paths, .additive)
    }

    /// The unborn-HEAD form of unstaging. `restore --staged` needs a HEAD to restore from; before
    /// the first commit there is none, and `reset` is the operation that works there.
    public static func resetPaths(_ paths: [String]) -> GitWriteOperation {
        GitWriteOperation("reset-paths", ["reset", "-q", "--"] + paths, .additive)
    }

    public static func restoreWorktree(_ paths: [String]) -> GitWriteOperation {
        GitWriteOperation("restore-worktree", ["restore", "--worktree", "--"] + paths, .destructive)
    }

    /// Patches arrive on standard input, never as a file the repository could point at.
    /// `--whitespace=nowarn` because the patch was generated from bytes this application read; a
    /// whitespace opinion here would rewrite them. `--unidiff-zero` is deliberately **not** passed:
    /// the patches carry three lines of context and git checking that context is one more thing
    /// standing between a stale selection and someone's index.
    public static func applyToIndex(reverse: Bool) -> GitWriteOperation {
        GitWriteOperation(reverse ? "apply-cached-reverse" : "apply-cached",
                          ["apply", "--cached", "--whitespace=nowarn"]
                              + (reverse ? ["-R"] : []) + ["-"],
                          .additive)
    }

    public static func applyToWorktree(reverse: Bool) -> GitWriteOperation {
        GitWriteOperation(reverse ? "apply-worktree-reverse" : "apply-worktree",
                          ["apply", "--whitespace=nowarn"]
                              + (reverse ? ["-R"] : []) + ["-"],
                          .destructive)
    }

    // ---- commit -----------------------------------------------------------------------------

    /// The message travels in a file, never in argv: a commit message may contain anything at all,
    /// including things a process list should not carry.
    public static func commit(messageFile: String, amend: Bool, allowEmpty: Bool) -> GitWriteOperation {
        var arguments = ["commit", "-F", messageFile, "--cleanup=strip"]
        if amend { arguments.append("--amend") }
        if allowEmpty { arguments.append("--allow-empty") }
        return GitWriteOperation(amend ? "commit-amend" : "commit", arguments, amend ? .recoverable : .additive)
    }

    /// The commit lazygit's *amend an old commit* is built on: git composes the `fixup!` subject
    /// that `rebase --autosquash` recognises, which a hand-written message does not.
    public static func commitFixup(_ sha: String) -> GitWriteOperation {
        GitWriteOperation("commit-fixup", ["commit", "--fixup", sha], .additive)
    }

    public static func resetSoft(_ rev: String) -> GitWriteOperation {
        GitWriteOperation("reset-soft", ["reset", "--soft", rev], .recoverable)
    }

    public static func resetMixed(_ rev: String) -> GitWriteOperation {
        GitWriteOperation("reset-mixed", ["reset", "--mixed", rev], .recoverable)
    }

    public static func resetHard(_ rev: String) -> GitWriteOperation {
        GitWriteOperation("reset-hard", ["reset", "--hard", rev], .destructive)
    }

    public static func readTree(_ tree: String) -> GitWriteOperation {
        GitWriteOperation("read-tree", ["read-tree", tree], .recoverable)
    }

    /// Writes the index out as a tree object. Additive in the strict sense — it creates an object
    /// and changes no ref — and it is how a restore point remembers what was staged.
    public static func writeTree() -> GitWriteOperation {
        GitWriteOperation("write-tree", ["write-tree"], .additive)
    }

    public static func revert(_ rev: String, noEdit: Bool = true) -> GitWriteOperation {
        GitWriteOperation("revert", ["revert"] + (noEdit ? ["--no-edit"] : []) + [rev], .additive)
    }

    public static func cherryPick(_ revs: [String]) -> GitWriteOperation {
        GitWriteOperation("cherry-pick", ["cherry-pick"] + revs, .recoverable)
    }

    public static func checkoutDetached(_ rev: String) -> GitWriteOperation {
        GitWriteOperation("checkout-detach", ["checkout", "--detach", rev], .recoverable)
    }

    public static func tag(_ name: String, message: String?, rev: String?) -> GitWriteOperation {
        var arguments = ["tag"]
        if let message { arguments += ["-a", "-m", message] }
        arguments.append(name)
        if let rev { arguments.append(rev) }
        return GitWriteOperation("tag", arguments, .additive)
    }

    public static func deleteTag(_ name: String) -> GitWriteOperation {
        GitWriteOperation("tag-delete", ["tag", "-d", name], .destructive)
    }

    // ---- branches ---------------------------------------------------------------------------

    public static func checkoutBranch(_ name: String) -> GitWriteOperation {
        GitWriteOperation("checkout-branch", ["checkout", name], .recoverable)
    }

    public static func createBranch(_ name: String, at rev: String?) -> GitWriteOperation {
        GitWriteOperation("branch-create", ["branch", name] + (rev.map { [$0] } ?? []), .additive)
    }

    public static func createAndCheckoutBranch(_ name: String, at rev: String?) -> GitWriteOperation {
        GitWriteOperation("checkout-new-branch", ["checkout", "-b", name] + (rev.map { [$0] } ?? []), .additive)
    }

    public static func renameBranch(from: String, to: String) -> GitWriteOperation {
        GitWriteOperation("branch-rename", ["branch", "-m", from, to], .recoverable)
    }

    public static func deleteBranch(_ name: String, force: Bool) -> GitWriteOperation {
        GitWriteOperation("branch-delete", ["branch", force ? "-D" : "-d", name], .destructive)
    }

    public static func merge(_ ref: String, squash: Bool) -> GitWriteOperation {
        GitWriteOperation(squash ? "merge-squash" : "merge",
                          ["merge", "--no-edit"] + (squash ? ["--squash"] : []) + [ref], .recoverable)
    }

    public static func mergeAbort() -> GitWriteOperation {
        GitWriteOperation("merge-abort", ["merge", "--abort"], .recoverable)
    }

    public static func rebase(onto ref: String, interactive: Bool, autosquash: Bool) -> GitWriteOperation {
        var arguments = ["rebase"]
        if interactive { arguments.append("-i") }
        if autosquash { arguments.append("--autosquash") }
        arguments.append(ref)
        return GitWriteOperation(interactive ? "rebase-interactive" : "rebase", arguments, .destructive)
    }

    /// The form for a range that reaches the **first commit of the repository**, which has no
    /// parent to rebase onto. `--root` is the only way to rewrite it, and without this the oldest
    /// commit is the one commit in a repository that cannot be amended.
    public static func rebaseRoot(interactive: Bool, autosquash: Bool) -> GitWriteOperation {
        var arguments = ["rebase"]
        if interactive { arguments.append("-i") }
        if autosquash { arguments.append("--autosquash") }
        arguments.append("--root")
        return GitWriteOperation("rebase-root", arguments, .destructive)
    }

    public static func rebaseContinue(_ verb: String) -> GitWriteOperation {
        GitWriteOperation("rebase-\(verb)", ["rebase", "--\(verb)"], .recoverable)
    }

    public static func checkoutSide(_ side: String, paths: [String]) -> GitWriteOperation {
        GitWriteOperation("checkout-\(side)", ["checkout", "--\(side)", "--"] + paths, .destructive)
    }

    // ---- stash ------------------------------------------------------------------------------

    public static func stashPush(message: String?, keepIndex: Bool, includeUntracked: Bool) -> GitWriteOperation {
        var arguments = ["stash", "push"]
        if keepIndex { arguments.append("--keep-index") }
        if includeUntracked { arguments.append("--include-untracked") }
        if let message { arguments += ["-m", message] }
        return GitWriteOperation("stash-push", arguments, .recoverable)
    }

    public static func stashApply(_ ref: String, pop: Bool) -> GitWriteOperation {
        GitWriteOperation(pop ? "stash-pop" : "stash-apply", ["stash", pop ? "pop" : "apply", ref], .recoverable)
    }

    public static func stashDrop(_ ref: String) -> GitWriteOperation {
        GitWriteOperation("stash-drop", ["stash", "drop", ref], .destructive)
    }

    // ---- bisect -----------------------------------------------------------------------------

    public static func bisect(_ verb: String, rev: String? = nil) -> GitWriteOperation {
        GitWriteOperation("bisect-\(verb)", ["bisect", verb] + (rev.map { [$0] } ?? []), .recoverable)
    }

    // ---- worktrees --------------------------------------------------------------------------

    public static func worktreeAdd(path: String, branch: String?, checkout rev: String?) -> GitWriteOperation {
        var arguments = ["worktree", "add"]
        if let branch { arguments += ["-b", branch] }
        arguments.append(path)
        if let rev { arguments.append(rev) }
        return GitWriteOperation("worktree-add", arguments, .additive)
    }

    public static func worktreeRemove(path: String, force: Bool) -> GitWriteOperation {
        GitWriteOperation("worktree-remove", ["worktree", "remove"] + (force ? ["--force"] : []) + [path], .destructive)
    }

    // ---- remote -----------------------------------------------------------------------------

    public static func fetch(remote: String, prune: Bool) -> GitWriteOperation {
        GitWriteOperation("fetch", ["fetch"] + (prune ? ["--prune"] : []) + [remote], .network)
    }

    public static func pull(remote: String, branch: String, rebase: Bool) -> GitWriteOperation {
        GitWriteOperation(rebase ? "pull-rebase" : "pull",
                          ["pull", rebase ? "--rebase" : "--no-rebase", remote, branch], .network)
    }

    public static func push(remote: String, branch: String, setUpstream: Bool, forceWithLease: Bool) -> GitWriteOperation {
        var arguments = ["push"]
        if setUpstream { arguments.append("-u") }
        // `--force-with-lease` and never `--force` (DEC-092). The lease is what makes a force push
        // refuse when somebody else has pushed since this application last looked.
        if forceWithLease { arguments.append("--force-with-lease") }
        arguments += [remote, branch]
        // The lease gets a label of its own: the command record is what the user reads afterwards
        // to see what happened, and *a push* and *a force push* must not appear there as the
        // same line.
        return GitWriteOperation(forceWithLease ? "push-force-with-lease" : "push", arguments, .network)
    }

    public static func pushDelete(remote: String, branch: String) -> GitWriteOperation {
        GitWriteOperation("push-delete", ["push", remote, "--delete", branch], .network)
    }

    public static func pushTags(remote: String) -> GitWriteOperation {
        GitWriteOperation("push-tags", ["push", remote, "--tags"], .network)
    }

    /// Every write this application can perform, with a representative argument list. The closing
    /// check asserts that nothing ran whose label is not here — the same proof shape as R-8's, and
    /// the reason a new Git call cannot arrive as an implementation detail.
    public static let allProvenWriting: [GitWriteOperation] = [
        .addPaths(["a.txt"]),
        .addIntentToAdd(["a.txt"]),
        .restoreStaged(["a.txt"]),
        .resetPaths(["a.txt"]),
        .restoreWorktree(["a.txt"]),
        .applyToIndex(reverse: false),
        .applyToIndex(reverse: true),
        .applyToWorktree(reverse: false),
        .applyToWorktree(reverse: true),
        .commit(messageFile: "/tmp/m", amend: false, allowEmpty: false),
        .commit(messageFile: "/tmp/m", amend: true, allowEmpty: false),
        .commitFixup("HEAD"),
        .resetSoft("HEAD"),
        .resetMixed("HEAD"),
        .resetHard("HEAD"),
        .readTree("HEAD"),
        .writeTree(),
        .revert("HEAD"),
        .cherryPick(["HEAD"]),
        .checkoutDetached("HEAD"),
        .tag("v1", message: nil, rev: nil),
        .deleteTag("v1"),
        .checkoutBranch("main"),
        .createBranch("feature", at: nil),
        .createAndCheckoutBranch("feature", at: nil),
        .renameBranch(from: "a", to: "b"),
        .deleteBranch("feature", force: false),
        .merge("main", squash: false),
        .merge("main", squash: true),
        .mergeAbort(),
        .rebase(onto: "main", interactive: false, autosquash: false),
        .rebase(onto: "main", interactive: true, autosquash: true),
        .rebaseRoot(interactive: true, autosquash: true),
        .rebaseContinue("continue"),
        .rebaseContinue("skip"),
        .rebaseContinue("abort"),
        .checkoutSide("ours", paths: ["a.txt"]),
        .checkoutSide("theirs", paths: ["a.txt"]),
        .stashPush(message: nil, keepIndex: false, includeUntracked: false),
        .stashApply("stash@{0}", pop: false),
        .stashApply("stash@{0}", pop: true),
        .stashDrop("stash@{0}"),
        .bisect("start"),
        .bisect("good", rev: "HEAD"),
        .bisect("bad", rev: "HEAD"),
        .bisect("skip"),
        .bisect("reset"),
        .worktreeAdd(path: "/tmp/w", branch: nil, checkout: nil),
        .worktreeRemove(path: "/tmp/w", force: false),
        .fetch(remote: "origin", prune: true),
        .pull(remote: "origin", branch: "main", rebase: false),
        .pull(remote: "origin", branch: "main", rebase: true),
        .push(remote: "origin", branch: "main", setUpstream: false, forceWithLease: false),
        .push(remote: "origin", branch: "main", setUpstream: false, forceWithLease: true),
        .pushDelete(remote: "origin", branch: "feature"),
        .pushTags(remote: "origin"),
    ]

    /// `--force` without a lease, and the argument that would let the repository decide what runs.
    /// The read registry forbids the second already (DEC-051); a write registry has to forbid the
    /// first as well, because a force push is the one operation here that can destroy work that was
    /// never on this machine.
    public static let forbiddenArguments = ["--force", "--textconv", "--filters", "--ext-diff", "-c",
                                            "--exec", "--upload-pack", "--receive-pack"]

    /// `--force-with-lease` contains `--force` as a prefix and is the sanctioned form, so the
    /// comparison is over whole arguments. `worktree remove --force` is the one place a plain
    /// `--force` is allowed: it is bounded by the path beside it and destroys nothing that is not
    /// already in that directory.
    public static var forbiddenOperations: [GitWriteOperation] {
        allProvenWriting.filter { operation in
            guard operation.label != "worktree-remove" else { return false }
            return operation.arguments.contains { forbiddenArguments.contains($0) }
        }
    }
}

/// What the user is asked before an operation runs (DEC-092 §5, point 5).
public enum Confirmation: Sendable, Equatable {
    case none
    /// Runs, and the status line says how to undo it.
    case undoable
    /// A sheet naming what is lost.
    case explicit(String)
    /// A sheet that also requires the branch name to be typed.
    case typedBranchName(String)

    public static func required(for operation: GitWriteOperation) -> Confirmation {
        switch operation.risk {
        case .additive: return .none
        case .recoverable: return .undoable
        case .destructive: return .explicit(operation.label)
        case .network:
            return operation.arguments.contains("--force-with-lease")
                ? .typedBranchName(operation.label)
                : .explicit(operation.label)
        }
    }
}

/// One line of the record the interface shows: the exact argv, and how it ended.
///
/// This is the second half of the sentence that replaces "it never writes" — *it shows you the
/// command it ran*. It is kept in memory only; a log on disk would be a second thing to trust.
public struct CommandRecordEntry: Sendable, Equatable {
    public let date: Date
    public let repository: String
    public let arguments: [String]
    public let exitCode: Int32
    public let standardError: String

    public var commandLine: String { (["git"] + arguments).joined(separator: " ") }
    public var succeeded: Bool { exitCode == 0 }
}

public enum GitWriteFailure: Error, CustomStringConvertible, Equatable {
    case launchFailed(String)
    /// Another process holds `index.lock`. Reported as itself rather than as a generic failure,
    /// because the user's next move — wait, or look at WebStorm — depends on knowing which it is.
    case indexLocked
    case failed(exitCode: Int32, message: String)

    public var description: String {
        switch self {
        case let .launchFailed(message): return "failed to launch git: \(message)"
        case .indexLocked: return "another program is using this repository's index"
        case let .failed(code, message): return message.isEmpty ? "git exited \(code)" : message
        }
    }
}

/// The runner for operations that write.
///
/// Deliberately **not** `GitRunner`: that type's whole point is `--no-optional-locks` and a proof
/// that nothing it runs writes. Sharing it would make the read path's guarantee depend on a flag
/// somebody remembered to pass.
public final class GitWriter: @unchecked Sendable {
    private static let lock = NSLock()
    private static var executed: Set<String> = []
    private static var record: [CommandRecordEntry] = []

    /// How many commands the record keeps. A window, not a log.
    public static let recordLimit = 200

    public static var executedOperationLabels: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return executed
    }

    public static func resetExecutedOperationLabels() {
        lock.lock(); executed = []; lock.unlock()
    }

    public static var commandRecord: [CommandRecordEntry] {
        lock.lock(); defer { lock.unlock() }
        return record
    }

    public static func clearCommandRecord() {
        lock.lock(); record = []; lock.unlock()
    }

    public let executableURL: URL

    public init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.executableURL = executableURL
    }

    /// How long a held `index.lock` is waited out before it is reported. One retry: a lock held
    /// longer than this is another program's, not a race with ourselves.
    public static let lockRetryDelay: TimeInterval = 0.15

    /// An interactive rebase needs its todo list, and git asks for it by **running an editor**.
    /// `GIT_SEQUENCE_EDITOR` is set to `cp <our file>` for exactly one invocation — git appends the
    /// todo's path, so the command becomes `cp <ours> <git's>` and the list is replaced without a
    /// script, a terminal or an editor anywhere in it.
    ///
    /// Scoped to the call rather than to the runner: a leaked sequence editor would silently
    /// rewrite the todo of every later rebase.
    @discardableResult
    public func run(_ operation: GitWriteOperation, in repository: URL,
                    standardInput: Data? = nil,
                    sequenceTodo: URL) throws -> GitInvocationResult {
        try run(operation, in: repository, standardInput: standardInput,
                environment: ["GIT_SEQUENCE_EDITOR": "/bin/cp \(shellQuoted(sequenceTodo.path))"])
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    public func run(_ operation: GitWriteOperation, in repository: URL,
                    standardInput: Data? = nil,
                    environment overrides: [String: String] = [:]) throws -> GitInvocationResult {
        GitWriter.lock.lock()
        GitWriter.executed.insert(operation.label)
        GitWriter.lock.unlock()

        var result = try invoke(operation, in: repository, standardInput: standardInput,
                                overrides: overrides)
        if !result.succeeded, isIndexLock(result.standardError) {
            Thread.sleep(forTimeInterval: GitWriter.lockRetryDelay)
            result = try invoke(operation, in: repository, standardInput: standardInput,
                                overrides: overrides)
        }

        let entry = CommandRecordEntry(date: Date(), repository: repository.path,
                                       arguments: operation.arguments, exitCode: result.exitCode,
                                       standardError: result.standardError)
        GitWriter.lock.lock()
        GitWriter.record.append(entry)
        if GitWriter.record.count > GitWriter.recordLimit { GitWriter.record.removeFirst() }
        GitWriter.lock.unlock()

        guard result.succeeded else {
            if isIndexLock(result.standardError) { throw GitWriteFailure.indexLocked }
            // **A hook's refusal is usually on stdout** (DEC-113). `git commit` in a repository with
            // husky exits 1 and says nothing on stderr; commitlint has already printed
            // `✖ subject may not be empty` to stdout, and lint-staged prints its whole report there.
            // Reading stderr alone left `message` empty, so the window said *git exited 1* — which is
            // how a rejected commit came to look like a commit that did nothing at all.
            let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = String(decoding: result.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitWriteFailure.failed(exitCode: result.exitCode,
                                         message: stderr.isEmpty ? stdout : stderr)
        }
        return result
    }

    /// Runs without throwing on a non-zero exit, for the operations whose failure is an answer
    /// rather than a fault — `branch -d` on an unmerged branch, `merge` finding a conflict.
    public func attempt(_ operation: GitWriteOperation, in repository: URL,
                        standardInput: Data? = nil) -> Result<GitInvocationResult, GitWriteFailure> {
        do { return .success(try run(operation, in: repository, standardInput: standardInput)) }
        catch let failure as GitWriteFailure { return .failure(failure) }
        catch { return .failure(.launchFailed(String(describing: error))) }
    }

    private func isIndexLock(_ message: String) -> Bool {
        message.contains("index.lock") || message.contains("Unable to create") && message.contains(".lock")
    }

    private func invoke(_ operation: GitWriteOperation, in repository: URL,
                        standardInput: Data?, overrides: [String: String]) throws -> GitInvocationResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-C", repository.path] + operation.arguments

        var environment = ProcessInfo.processInfo.environment
        // A write path needs the index lock, so `GIT_OPTIONAL_LOCKS` is deliberately absent here.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        // Nothing this application runs may open an editor: there is no terminal attached to it,
        // and a git subprocess waiting on one would hang with no way to say so.
        environment["GIT_EDITOR"] = "true"
        environment["GIT_SEQUENCE_EDITOR"] = "true"
        environment["GIT_PAGER"] = "cat"
        for (key, value) in overrides { environment[key] = value }
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = Pipe()
        process.standardInput = standardInput == nil ? FileHandle.nullDevice : inPipe

        do { try process.run() } catch {
            throw GitWriteFailure.launchFailed(String(describing: error))
        }
        if let standardInput {
            inPipe.fileHandleForWriting.write(standardInput)
            try? inPipe.fileHandleForWriting.close()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GitInvocationResult(exitCode: process.terminationStatus, standardOutput: outData,
                                   standardError: String(decoding: errData, as: UTF8.self))
    }
}
