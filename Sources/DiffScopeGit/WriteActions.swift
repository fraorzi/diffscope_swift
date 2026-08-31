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
    ///
    /// **A patch bound for the index is refused when a content filter is in force for its path**
    /// (INV-4, DEC-025). `git add` hands the bytes to git and git runs its clean filter on them;
    /// `git apply --cached` is handed bytes and stores them, so a patch this application built from
    /// the raw file on disk puts unfiltered bytes into an index that is supposed to hold filtered
    /// ones. Measured: with `core.autocrlf=input` and a CRLF file, `git add` stores `61 0a 42 0a
    /// 63 0a` and this path stored `61 0d 0a 42 0d 0a 63 0d 0a`, with `git status` reporting the
    /// file cleanly staged either way. Running the filter here instead is a larger change and is
    /// not what this guard is: the doctrine is that a degradation is **visible**, so the write is
    /// refused and the reason is handed back in words rather than bytes being guessed at.
    ///
    /// The paths come out of the patch's own headers rather than from an argument, for the reason
    /// the restore points above are taken inside the function that needs them: a guard a call site
    /// has to remember to ask for is a guard that is one day not asked for.
    public func apply(patch: Data, to destination: PatchDestination, reverse: Bool,
                      intentToAdd path: String? = nil, in repository: URL) throws {
        if destination == .index {
            let check = ContentFilterCheck(runner: runner)
            let refusals = ContentFilterCheck.paths(inPatch: patch)
                .map { check.verdict(for: $0, in: repository) }
                .filter(\.transforms)
            if !refusals.isEmpty { throw ContentFilterRefusal(verdicts: refusals) }
        }
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

    // ---- rewriting history -----------------------------------------------------------------------

    /// What a commit is to become in a rewritten history. lazygit's verbs, and GitHub Desktop's two
    /// gestures, are the same five words underneath.
    public enum RewriteVerb: String, Sendable, Equatable, CaseIterable {
        case reword, squash, fixup, drop, moveUp, moveDown

        public var consequence: String {
            switch self {
            case .reword: return "The commit keeps its changes and gets a new message."
            case .squash: return "The commit is folded into the one before it, and you write one message for both."
            case .fixup: return "The commit is folded into the one before it, and its message is dropped."
            case .drop: return "The commit and everything in it are removed from the branch."
            case .moveUp: return "The commit changes places with the one before it."
            case .moveDown: return "The commit changes places with the one after it."
            }
        }
    }

    /// Rewrites the branch so that `sha` is treated the given way.
    ///
    /// The todo list is **generated here** and handed to git through `GIT_SEQUENCE_EDITOR`, so
    /// nothing opens an editor and nothing is typed into a terminal. A restore point is taken
    /// first, because every verb here is class C: the commits that come out have different
    /// identities from the ones that went in, and the only way back is the reflog or this point.
    @discardableResult
    public func rewrite(_ sha: String, as verb: RewriteVerb, newMessage: String? = nil,
                        in repository: URL) throws -> RestorePoint {
        let point = capture("rewrite", in: repository)
        let listing = try runner.run(.logGraph(limit: 400, all: false), in: repository)
        let commits = String(decoding: listing.standardOutput, as: UTF8.self)
            .split(separator: "\n").compactMap { line -> (sha: String, subject: String)? in
                let parts = line.components(separatedBy: "\u{1f}")
                guard parts.count >= 5 else { return nil }
                return (parts[0], parts[4])
            }
        guard let position = commits.firstIndex(where: { $0.sha.hasPrefix(sha) }) else {
            throw GitWriteFailure.failed(exitCode: 1, message: "that commit is not on this branch")
        }
        // How deep the todo has to reach, and it is not the same for every verb — this was wrong
        // in the first version and three checks said so in three different ways.
        //
        // `squash`, `fixup` and *move earlier* all act on the commit **and the one before it**, so
        // the older one has to be in the list: a todo whose first line is `squash` is one git
        // refuses, because there is nothing above it to squash into. `reword`, `drop` and *move
        // later* need only the commit itself — everything newer is already in the range.
        let deepest: Int
        switch verb {
        case .squash, .fixup, .moveUp: deepest = position + 1
        case .reword, .drop, .moveDown: deepest = position
        }
        guard deepest + 1 < commits.count else {
            throw GitWriteFailure.failed(exitCode: 1,
                                         message: "the first commit of a branch cannot be rewritten this way")
        }
        let onto = commits[deepest + 1].sha

        // git's todo is oldest first; the log is newest first.
        var todo: [(verb: String, sha: String, subject: String)] = commits[0...deepest]
            .reversed().map { ("pick", $0.sha, $0.subject) }
        guard let index = todo.firstIndex(where: { $0.sha.hasPrefix(sha) }) else {
            throw GitWriteFailure.failed(exitCode: 1, message: "that commit is not in the range")
        }
        switch verb {
        case .reword: todo[index].verb = "reword"
        case .squash:
            guard index > 0 else {
                throw GitWriteFailure.failed(exitCode: 1, message: "there is nothing before it to squash into")
            }
            todo[index].verb = "squash"
        case .fixup:
            guard index > 0 else {
                throw GitWriteFailure.failed(exitCode: 1, message: "there is nothing before it to fold into")
            }
            todo[index].verb = "fixup"
        case .drop: todo[index].verb = "drop"
        case .moveUp:
            guard index > 0 else {
                throw GitWriteFailure.failed(exitCode: 1, message: "it is already the oldest in this range")
            }
            todo.swapAt(index, index - 1)
        case .moveDown:
            guard index + 1 < todo.count else {
                throw GitWriteFailure.failed(exitCode: 1, message: "it is already the newest commit")
            }
            todo.swapAt(index, index + 1)
        }

        let text = todo.map { "\($0.verb) \($0.sha) \($0.subject)" }.joined(separator: "\n") + "\n"
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diffscope-todo-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        // `reword` would open an editor for the message; the message is supplied instead, through
        // the same mechanism a commit message travels by.
        var overrides: [String: String] = [:]
        if verb == .reword, let newMessage {
            let messageFile = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("diffscope-reword-\(UUID().uuidString).txt")
            try Data((newMessage + "\n").utf8).write(to: messageFile)
            overrides["GIT_EDITOR"] = "/bin/cp '\(messageFile.path)'"
        }
        if verb == .squash {
            // A squash asks for the combined message. Keeping git's own default — both messages,
            // one after the other — is the honest starting point, and the reader can amend it.
            overrides["GIT_EDITOR"] = "true"
        }
        overrides["GIT_SEQUENCE_EDITOR"] = "/bin/cp '\(file.path)'"
        try writer.run(.rebase(onto: onto, interactive: true, autosquash: false),
                       in: repository, environment: overrides)
        return point
    }

    /// lazygit's *amend an old commit*: the staged changes become a `fixup` on the named commit and
    /// the branch is rebased with `--autosquash`, which is the mechanism that feature is built on
    /// everywhere it exists.
    @discardableResult
    public func amendOldCommit(_ sha: String, in repository: URL) throws -> RestorePoint {
        let point = capture("amend-old", in: repository)
        // `commit --fixup=<sha>` rather than a message file saying `fixup! <sha>`: git composes the
        // subject autosquash matches, which is `fixup! <the target's own subject>`. Writing the sha
        // into the message by hand produced a commit autosquash walked straight past, and left it
        // sitting on the branch as `fixup! a75edbc…` — measured, in the check below.
        try writer.run(.commitFixup(sha), in: repository)
        // The oldest commit has no parent, and `<sha>~1` is not a revision there. `--root` is the
        // form that reaches it — without this, the one commit in a repository that could not be
        // amended was the first one.
        let quiet = ["GIT_SEQUENCE_EDITOR": "true", "GIT_EDITOR": "true"]
        let parent = try? runner.run(.revParse("\(sha)~1"), in: repository)
        if parent?.succeeded == true {
            try writer.run(.rebase(onto: "\(sha)~1", interactive: true, autosquash: true),
                           in: repository, environment: quiet)
        } else {
            try writer.run(.rebaseRoot(interactive: true, autosquash: true),
                           in: repository, environment: quiet)
        }
        return point
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

// ---- content filters, and the line-level write that must not run through one ------------------
//
// **The defect this exists for, measured.** Whole-file staging is `git add`, and `git add` hands the
// working-tree bytes to git, which runs the clean filter configured for the path before storing
// them. Line-level staging is `git apply --cached` fed a patch this application builds from the
// index blob and the **raw** file on disk, and `--cached` stores the bytes it is given. In a
// repository with `core.autocrlf=input` and a CRLF file, one line edited:
//
//     git add f.txt          index becomes  61 0a 42 0a 63 0a          (LF, what git means to store)
//     line staging           index becomes  61 0d 0a 42 0d 0a 63 0d 0a (CRLF, what was on disk)
//
// `git status` says `M ` either way, so the reader commits CRLF into a repository that normalises
// to LF and nothing on screen looks wrong. That is a silent degradation, which is the one thing
// `14-…` forbids outright.
//
// Running the clean filter here would be the other repair, and it is an architectural change: it
// moves filter execution into the write path, and DEC-028 refused to let repository configuration
// decide what this application executes. So this type does the thing INV-4 asks for instead — it
// establishes that a filter *could* change the bytes, and the write is refused in words the reader
// can act on rather than performed with bytes nobody chose.

/// What git would do to one path's bytes on the way into the index, as far as it can be established
/// without running anything the repository configures.
public struct ContentFilterVerdict: Sendable, Equatable {
    public let path: String
    /// `check-attr` attributes that are set to something — `filter`, `text`, `eol`.
    /// `unspecified` and `unset` are already dropped by `FilterCheck`, so `-text` (explicitly no
    /// conversion) correctly does not appear here.
    public let attributes: [String: String]
    /// `core.autocrlf` / `core.eol`, and only where the value is one that transforms.
    public let configuration: [String: String]
    /// Sources that mention the question and could not be answered. Unknown is never read as clean
    /// — that is the same rule `FilterState.unknown` follows on the read path.
    public let undetermined: [String]

    public var transforms: Bool {
        !attributes.isEmpty || !configuration.isEmpty || !undetermined.isEmpty
    }

    /// What made this path suspect, in the shortest form that still names the setting the reader
    /// would have to change.
    public var evidence: String {
        var parts = (attributes.map { "\($0.key)=\($0.value)" }
            + configuration.map { "\($0.key)=\($0.value)" }).sorted()
        parts += undetermined.map { "could not be determined: \($0)" }
        return parts.joined(separator: ", ")
    }
}

/// The refusal itself, thrown before anything is written.
///
/// Its own type rather than `GitWriteFailure.failed`: nothing failed and git never ran, and
/// reporting a refusal as an exit code would be the second lie in a file about not telling the
/// first one. It still reaches the window's status line, which prints `\(error)` for anything that
/// is not a `GitWriteFailure`.
public struct ContentFilterRefusal: Error, CustomStringConvertible, Equatable, Sendable {
    public let verdicts: [ContentFilterVerdict]

    public init(verdicts: [ContentFilterVerdict]) {
        self.verdicts = verdicts
    }

    public var paths: [String] { verdicts.map(\.path) }

    public var description: String {
        let named = verdicts.map { "“\($0.path)” (\($0.evidence))" }.joined(separator: ", ")
        return """
            refused to stage lines of \(named): Git is configured to change this file's bytes on \
            the way into the index, and a line-level patch carries the bytes as they are on disk — \
            staging it would put content in the index that Git itself would not have written. \
            Stage the whole file, which runs Git's own conversion, or turn the setting off for this \
            repository
            """
    }
}

/// Establishes whether a content filter is in force for a path, from `git check-attr` and from the
/// `core.autocrlf` / `core.eol` configuration.
///
/// Headless on purpose: the window calls it through `WriteActions.apply`, and the check suite calls
/// it directly, so what ships and what is proven are the same function.
public struct ContentFilterCheck: Sendable {
    private let attributes: FilterCheck
    private let state: RepositoryStateReader

    public init(runner: GitRunner = GitRunner()) {
        self.attributes = FilterCheck(runner: runner)
        self.state = RepositoryStateReader(runner: runner)
    }

    public func verdict(for path: String, in repository: URL) -> ContentFilterVerdict {
        let attributeState = attributes.state(for: path, in: repository)
        var undetermined: [String] = []
        if attributeState.unknown { undetermined.append("git check-attr did not answer for this path") }

        let scan = ContentFilterCheck.configuration(
            of: repository, gitDirectory: state.gitDirectory(of: repository))
        undetermined += scan.undetermined

        var configuration: [String: String] = [:]
        // `autocrlf` transforms for anything but an explicit off. The values git accepts are the
        // boolean set plus `input`, and `input` is the one that bit — it converts on the way *in*,
        // which is exactly the direction a line-level write travels.
        if let value = scan.values["core.autocrlf"],
           !["false", "0", "off", "no", ""].contains(value.lowercased()) {
            configuration["core.autocrlf"] = value
        }
        // `core.eol` only decides which ending a *converted* file gets, so on its own it changes
        // nothing; `crlf` is recorded anyway because the combination that matters — a `text`
        // attribute plus `core.eol=crlf` — is one where the attribute alone understates what
        // happens, and over-reporting here costs a refusal while under-reporting costs bytes.
        if let value = scan.values["core.eol"], value.lowercased() == "crlf" {
            configuration["core.eol"] = value
        }

        return ContentFilterVerdict(path: path, attributes: attributeState.active,
                                    configuration: configuration, undetermined: undetermined)
    }

    // ---- the configuration files, read rather than asked for ---------------------------------
    //
    // `git config --get` would be the direct question and there is no way to ask it: `GitOperation`
    // is a closed registry whose whole purpose is that an invocation outside it cannot happen, and
    // widening it is not this change's to make. So the files git would read are read in the order
    // git reads them, last assignment winning, which is git's own precedence.
    //
    // Every uncertainty resolves toward refusal. A file that exists and cannot be read is recorded
    // as undetermined rather than skipped; a **conditional** include is followed but its condition
    // is not evaluated, so an assignment found inside one is recorded as undetermined rather than
    // taken as either present or absent.

    static let interestingKeys: Set<String> = ["core.autocrlf", "core.eol"]

    static func configuration(of repository: URL,
                              gitDirectory: URL) -> (values: [String: String], undetermined: [String]) {
        var values: [String: String] = [:]
        var undetermined: [String] = []
        var seen: Set<String> = []
        for source in sources(of: repository, gitDirectory: gitDirectory) {
            scan(source, conditional: false, depth: 0, seen: &seen,
                 values: &values, undetermined: &undetermined)
        }
        return (values, undetermined)
    }

    /// System, then global, then the repository's own, then the worktree's — git's precedence, and
    /// the environment variables that redirect each of them.
    private static func sources(of repository: URL, gitDirectory: URL) -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        var files: [URL] = []

        let noSystem = (environment["GIT_CONFIG_NOSYSTEM"] ?? "").lowercased()
        if !["1", "true", "yes", "on"].contains(noSystem) {
            if let path = environment["GIT_CONFIG_SYSTEM"] {
                files.append(URL(fileURLWithPath: path))
            } else {
                // git's system path is compiled in and differs per install; all three that a macOS
                // machine can have are read, because reading one that is not git's costs a refusal
                // and missing the one that is costs bytes.
                files += ["/etc/gitconfig", "/usr/local/etc/gitconfig", "/opt/homebrew/etc/gitconfig"]
                    .map { URL(fileURLWithPath: $0) }
            }
        }

        if let path = environment["GIT_CONFIG_GLOBAL"] {
            files.append(URL(fileURLWithPath: path))
        } else {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let xdg = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".config")
            files.append(xdg.appendingPathComponent("git/config"))
            files.append(home.appendingPathComponent(".gitconfig"))
        }

        files.append(gitDirectory.appendingPathComponent("config"))
        files.append(gitDirectory.appendingPathComponent("config.worktree"))
        return files
    }

    private static func scan(_ url: URL, conditional: Bool, depth: Int, seen: inout Set<String>,
                             values: inout [String: String], undetermined: inout [String]) {
        let resolved = url.standardizedFileURL
        guard !seen.contains(resolved.path) else { return }
        seen.insert(resolved.path)
        guard FileManager.default.fileExists(atPath: resolved.path) else { return }
        guard depth < 10 else {
            undetermined.append("\(resolved.path) includes files more deeply than this reads")
            return
        }
        guard let data = try? Data(contentsOf: resolved),
              let text = String(data: data, encoding: .utf8) else {
            undetermined.append("\(resolved.path) could not be read")
            return
        }

        var section = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                guard let close = line.firstIndex(of: "]") else { continue }
                let header = line[line.index(after: line.startIndex)..<close]
                section = String(header.prefix { !$0.isWhitespace }).lowercased()
                line = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            guard let (key, value) = entry(line) else { continue }
            let full = "\(section).\(key)"
            if interestingKeys.contains(full) {
                if conditional {
                    undetermined.append("\(resolved.path) sets \(full) inside a conditional include")
                } else {
                    values[full] = value
                }
            }
            guard key == "path", section == "include" || section == "includeif" else { continue }
            scan(expand(value, relativeTo: resolved), conditional: conditional || section == "includeif",
                 depth: depth + 1, seen: &seen, values: &values, undetermined: &undetermined)
        }
    }

    /// `key = value`, with the comment git would strip and the quoting git would remove. A bare key
    /// with no `=` is `true`, which is how `[core]\n\tautocrlf` reads.
    private static func entry(_ line: String) -> (key: String, value: String)? {
        var text = ""
        var quoted = false
        var escaped = false
        for character in line {
            if escaped {
                text.append(character)
                escaped = false
                continue
            }
            if character == "\\" { escaped = true; text.append(character); continue }
            if character == "\"" { quoted.toggle(); text.append(character); continue }
            if (character == "#" || character == ";") && !quoted { break }
            text.append(character)
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        guard let separator = text.firstIndex(of: "=") else {
            let key = text.lowercased()
            guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
            return (key, "true")
        }
        let key = String(text[text.startIndex..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
        var value = String(text[text.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        guard !key.isEmpty else { return nil }
        return (key, value.replacingOccurrences(of: "\\\"", with: "\""))
    }

    private static func expand(_ path: String, relativeTo file: URL) -> URL {
        if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return file.deletingLastPathComponent().appendingPathComponent(path)
    }

    // ---- the paths a patch touches -------------------------------------------------------------

    /// The paths named in a patch's headers.
    ///
    /// Read from the `diff --git` / `---` / `+++` block only, never from the body: a removed line
    /// whose content begins `-- ` is written `--- ` once the `-` marker is on it, and a parser that
    /// scanned every line would take that for a header. `diff --git ` at the start of a line cannot
    /// be a body line, because every body line begins with a space, `-`, `+` or `\`.
    public static func paths(inPatch patch: Data) -> [String] {
        var paths: [String] = []
        var inHeader = true
        for line in String(decoding: patch, as: UTF8.self).split(separator: "\n",
                                                                 omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { inHeader = true; continue }
            if line.hasPrefix("@@") { inHeader = false; continue }
            guard inHeader, line.hasPrefix("--- ") || line.hasPrefix("+++ ") else { continue }
            var text = String(line.dropFirst(4))
            if let tab = text.firstIndex(of: "\t") { text = String(text[text.startIndex..<tab]) }
            guard let path = header(text), path != "/dev/null", !paths.contains(path) else { continue }
            paths.append(path)
        }
        return paths
    }

    /// `a/src/List.tsx`, `b/"pa\"th"` or `"a/pa\"th"` reduced to the path itself.
    private static func header(_ text: String) -> String? {
        var text = text
        if text.hasPrefix("\"") { text = unquote(text) }
        if text.hasPrefix("a/") || text.hasPrefix("b/") { text = String(text.dropFirst(2)) }
        if text.hasPrefix("\"") { text = unquote(text) }
        return text.isEmpty ? nil : text
    }

    /// The inverse of the C-quoting the patch writer applies: `\"`, `\\` and three-digit octal.
    private static func unquote(_ text: String) -> String {
        var out = ""
        var scalars = Array(text.unicodeScalars.dropFirst())
        if scalars.last == "\"" { scalars.removeLast() }
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "\\", index + 1 < scalars.count else {
                out.unicodeScalars.append(scalars[index]); index += 1; continue
            }
            let next = scalars[index + 1]
            if next.properties.numericType != nil, index + 3 < scalars.count,
               let value = UInt8(String(String.UnicodeScalarView(scalars[(index + 1)...(index + 3)])),
                                 radix: 8) {
                out.unicodeScalars.append(UnicodeScalar(value))
                index += 4
            } else {
                out.unicodeScalars.append(next)
                index += 2
            }
        }
        return out
    }
}
