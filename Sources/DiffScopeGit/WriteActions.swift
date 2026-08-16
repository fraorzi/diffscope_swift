import Foundation

/// Where the interface's verbs meet the write registry (DEC-092).
///
/// Two things are true of every function here and are the reason this type exists rather than the
/// window calling `GitWriter` itself:
///
/// 1. **A class-B or class-C operation records a restore point before it runs.** Not after, not
///    "when it looks risky" — before, in the same function, so there is no path that forgets.
/// 2. **Nothing here decides whether the user meant it.** `Confirmation.required(for:)` answers
///    that from the operation's declared risk, and the window asks. A default argument that skips
///    the question is exactly the door this separation closes.
public struct RestorePoint: Sendable, Equatable {
    public let label: String
    public let date: Date
    /// The commit HEAD pointed at. `nil` on an unborn HEAD, where there is nothing to go back to
    /// and the index is the only thing worth remembering.
    public let head: String?
    /// The index, written out as a tree object so it survives anything that follows.
    public let indexTree: String?
    /// The stash this point parked the working tree in, when the operation could destroy it.
    public let stashRef: String?

    public var describesSomething: Bool { head != nil || indexTree != nil || stashRef != nil }
}

public struct WriteActions: Sendable {
    public let writer: GitWriter
    public let runner: GitRunner
    public let state: RepositoryStateReader

    public init(writer: GitWriter = GitWriter(), runner: GitRunner = GitRunner()) {
        self.writer = writer
        self.runner = runner
        self.state = RepositoryStateReader(runner: runner)
    }

    // ---- restore points ----------------------------------------------------------------------

    /// Remembers where the repository was. `write-tree` creates an object and moves no ref, so the
    /// index can be put back byte for byte later — `reflog` only remembers refs, and half of what
    /// this application changes is the index.
    public func capture(_ label: String, in repository: URL, stashWorktree: Bool = false) -> RestorePoint {
        let head = state.headSha(in: repository)
        let tree = try? writer.run(.writeTree(), in: repository).trimmedOutput
        var stashRef: String?
        if stashWorktree {
            let before = state.stashes(in: repository).first?.ref
            _ = writer.attempt(.stashPush(message: "diffscope restore point: \(label)",
                                          keepIndex: false, includeUntracked: true), in: repository)
            let after = state.stashes(in: repository).first
            if let after, after.ref != before || before == nil { stashRef = after.ref }
        }
        return RestorePoint(label: label, date: Date(), head: head,
                            indexTree: tree?.isEmpty == false ? tree : nil, stashRef: stashRef)
    }

    /// Puts back what `capture` remembered: HEAD first, then the index, then the working tree.
    /// The order matters — `reset --soft` moves HEAD and leaves the index alone, so reading the
    /// tree back afterwards is what makes the index the one that was captured rather than the one
    /// the operation left behind.
    public func restore(_ point: RestorePoint, in repository: URL) throws {
        if let head = point.head {
            try writer.run(.resetSoft(head), in: repository)
        }
        if let tree = point.indexTree {
            try writer.run(.readTree(tree), in: repository)
        }
        if let stash = point.stashRef {
            try writer.run(.stashApply(stash, pop: true), in: repository)
        }
    }

    // ---- staging -----------------------------------------------------------------------------

    public func stage(paths: [String], in repository: URL) throws {
        guard !paths.isEmpty else { return }
        try writer.run(.addPaths(paths), in: repository)
    }

    /// Unstaging is the operation OQ-056 asked for first, because it destroys nothing: the bytes
    /// are still in the working tree afterwards, whatever happens.
    public func unstage(paths: [String], in repository: URL, hasCommits: Bool) throws {
        guard !paths.isEmpty else { return }
        try writer.run(hasCommits ? .restoreStaged(paths) : .resetPaths(paths), in: repository)
    }

    /// An untracked file has nothing to restore *from*, so discarding it means deleting it — and
    /// deleting it means the Trash, never `rm`. This is the one place in the product where a file
    /// leaves the working tree, and macOS has a well-understood undo for exactly this.
    public func discard(tracked: [String], untracked: [String], in repository: URL) throws {
        if !tracked.isEmpty {
            try writer.run(.restoreWorktree(tracked), in: repository)
        }
        for path in untracked {
            let url = repository.appendingPathComponent(path)
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// Applies a patch this application generated. `intentToAdd` is passed for an untracked file:
    /// without it there is nothing in the index for the patch to apply against.
    public func apply(patch: Data, to destination: PatchDestination, reverse: Bool,
                      intentToAdd path: String? = nil, in repository: URL) throws {
        if let path { _ = writer.attempt(.addIntentToAdd([path]), in: repository) }
        let operation: GitWriteOperation = destination == .index
            ? .applyToIndex(reverse: reverse)
            : .applyToWorktree(reverse: reverse)
        try writer.run(operation, in: repository, standardInput: patch)
    }

    public enum PatchDestination: Sendable, Equatable { case index, worktree }

    // ---- commit ------------------------------------------------------------------------------

    /// The message as git will store it: summary, blank line, description, then the co-author
    /// trailers. Composed here so the check can assert the shape rather than reading it off a text
    /// field.
    public static func composeMessage(summary: String, description: String,
                                      coAuthors: [String] = []) -> String {
        var message = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { message += "\n\n" + body }
        let trailers = coAuthors.map { "Co-authored-by: \($0)" }.joined(separator: "\n")
        if !trailers.isEmpty { message += "\n\n" + trailers }
        return message + "\n"
    }

    @discardableResult
    public func commit(summary: String, description: String, coAuthors: [String] = [],
                       amend: Bool = false, allowEmpty: Bool = false,
                       in repository: URL) throws -> RestorePoint {
        let point = capture(amend ? "amend" : "commit", in: repository)
        let message = WriteActions.composeMessage(summary: summary, description: description,
                                                  coAuthors: coAuthors)
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diffscope-commit-\(UUID().uuidString).txt")
        try Data(message.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try writer.run(.commit(messageFile: file.path, amend: amend, allowEmpty: allowEmpty),
                       in: repository)
        return point
    }

    /// GitHub Desktop's *Undo*: the commit goes away, everything it contained is staged again, and
    /// nothing is lost. `reset --soft` and nothing else.
    public func undoLastCommit(in repository: URL) throws {
        try writer.run(.resetSoft("HEAD~1"), in: repository)
    }

    // ---- branches, stashes, conflicts ---------------------------------------------------------

    public func checkout(branch: String, in repository: URL) throws {
        try writer.run(.checkoutBranch(branch), in: repository)
    }

    public func createBranch(_ name: String, at rev: String?, checkout: Bool, in repository: URL) throws {
        try writer.run(checkout ? .createAndCheckoutBranch(name, at: rev) : .createBranch(name, at: rev),
                       in: repository)
    }

    public func renameBranch(from: String, to: String, in repository: URL) throws {
        try writer.run(.renameBranch(from: from, to: to), in: repository)
    }

    public func deleteBranch(_ name: String, force: Bool, in repository: URL) throws {
        try writer.run(.deleteBranch(name, force: force), in: repository)
    }

    public func stashAll(message: String?, keepIndex: Bool, includeUntracked: Bool,
                         in repository: URL) throws {
        try writer.run(.stashPush(message: message, keepIndex: keepIndex,
                                  includeUntracked: includeUntracked), in: repository)
    }

    public func stash(_ ref: String, verb: StashVerb, in repository: URL) throws {
        switch verb {
        case .apply: try writer.run(.stashApply(ref, pop: false), in: repository)
        case .pop: try writer.run(.stashApply(ref, pop: true), in: repository)
        case .drop: try writer.run(.stashDrop(ref), in: repository)
        }
    }

    public enum StashVerb: Sendable, Equatable { case apply, pop, drop }

    /// Taking one side of a conflict, then marking the path resolved. `git add` after
    /// `checkout --ours` is what removes it from the unmerged list, and doing them separately is
    /// how a path ends up resolved in the index while the interface still calls it conflicted.
    public func resolve(paths: [String], taking side: ConflictSide, in repository: URL) throws {
        if side != .asIs {
            try writer.run(.checkoutSide(side == .ours ? "ours" : "theirs", paths: paths), in: repository)
        }
        try writer.run(.addPaths(paths), in: repository)
    }

    public enum ConflictSide: Sendable, Equatable { case ours, theirs, asIs }

    // ---- history ------------------------------------------------------------------------------

    public func revert(_ rev: String, in repository: URL) throws {
        try writer.run(.revert(rev), in: repository)
    }

    public func cherryPick(_ revs: [String], in repository: URL) throws {
        try writer.run(.cherryPick(revs), in: repository)
    }

    public func reset(to rev: String, kind: ResetKind, in repository: URL) throws {
        switch kind {
        case .soft: try writer.run(.resetSoft(rev), in: repository)
        case .mixed: try writer.run(.resetMixed(rev), in: repository)
        case .hard: try writer.run(.resetHard(rev), in: repository)
        }
    }

    public enum ResetKind: String, Sendable, Equatable, CaseIterable {
        case soft, mixed, hard

        /// What the confirmation sheet says is lost. `hard` is the only one that can lose work, and
        /// saying so in the sheet is the difference between a warning and a habit.
        public var consequence: String {
            switch self {
            case .soft: return "The commits are undone. Everything they contained stays staged."
            case .mixed: return "The commits are undone. Everything they contained stays in your files, unstaged."
            case .hard: return "The commits are undone and every change they contained is discarded."
            }
        }
    }

    public func checkoutDetached(_ rev: String, in repository: URL) throws {
        try writer.run(.checkoutDetached(rev), in: repository)
    }

    public func tag(_ name: String, message: String?, at rev: String?, in repository: URL) throws {
        try writer.run(.tag(name, message: message, rev: rev), in: repository)
    }

    public func deleteTag(_ name: String, in repository: URL) throws {
        try writer.run(.deleteTag(name), in: repository)
    }

    public func merge(_ ref: String, squash: Bool, in repository: URL) -> Result<GitInvocationResult, GitWriteFailure> {
        writer.attempt(.merge(ref, squash: squash), in: repository)
    }

    public func continueOperation(_ operation: RepositoryOperation, verb: String,
                                  in repository: URL) -> Result<GitInvocationResult, GitWriteFailure> {
        switch operation {
        case .merging:
            return verb == "Abort" ? writer.attempt(.mergeAbort(), in: repository)
                                   : writer.attempt(.commit(messageFile: mergeMessageFile(in: repository),
                                                            amend: false, allowEmpty: false), in: repository)
        case .rebasing, .cherryPicking, .reverting:
            return writer.attempt(.rebaseContinue(verb.lowercased()), in: repository)
        default:
            return .failure(.failed(exitCode: 1, message: "nothing is in progress"))
        }
    }

    /// git wrote the merge message itself; continuing a merge means committing it unchanged.
    private func mergeMessageFile(in repository: URL) -> String {
        state.gitDirectory(of: repository).appendingPathComponent("MERGE_MSG").path
    }

    // ---- bisect, worktrees --------------------------------------------------------------------

    public func bisect(_ verb: String, rev: String? = nil, in repository: URL) -> Result<GitInvocationResult, GitWriteFailure> {
        writer.attempt(.bisect(verb, rev: rev), in: repository)
    }

    public func addWorktree(path: String, branch: String?, checkout rev: String?, in repository: URL) throws {
        try writer.run(.worktreeAdd(path: path, branch: branch, checkout: rev), in: repository)
    }

    public func removeWorktree(path: String, force: Bool, in repository: URL) throws {
        try writer.run(.worktreeRemove(path: path, force: force), in: repository)
    }

    // ---- remote -------------------------------------------------------------------------------

    public func fetch(remote: String, in repository: URL) -> Result<GitInvocationResult, GitWriteFailure> {
        writer.attempt(.fetch(remote: remote, prune: true), in: repository)
    }

    public func pull(remote: String, branch: String, rebase: Bool,
                     in repository: URL) -> Result<GitInvocationResult, GitWriteFailure> {
        writer.attempt(.pull(remote: remote, branch: branch, rebase: rebase), in: repository)
    }

    public func push(remote: String, branch: String, setUpstream: Bool, forceWithLease: Bool,
                     in repository: URL) -> Result<GitInvocationResult, GitWriteFailure> {
        writer.attempt(.push(remote: remote, branch: branch, setUpstream: setUpstream,
                             forceWithLease: forceWithLease), in: repository)
    }
}
