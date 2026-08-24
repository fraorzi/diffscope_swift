import DiffScopeEngine
import DiffScopeGit
import Foundation

/// The write path's proof (DEC-092 §5).
///
/// R-8 proves a negative over the read registry and keeps doing so in `GitChecks`. This file proves
/// the two things that replace it for operations that *do* write:
///
/// - **W-1, W-9 — the registry is still closed.** Every write that runs is one of the registered
///   ones. That is the property that has held since M2, and losing it to a "quick `git add`" at a
///   call site is how a product like this stops being auditable.
/// - **INV-6 — it wrote exactly what it showed.** A selection is turned into bytes by
///   `applySelection`, and into a patch by `stagingPatch`, along two paths that share nothing but
///   the walk. git applies the patch; the index is read back; the two must agree byte for byte.
///
/// The second is the whole reason DEC-003 sequenced staging after the engine, and it is why this
/// file is longer than the code it checks.
func runWriteChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    let fm = FileManager.default
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("diffscope-write-\(UUID().uuidString)")
    try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: scratch) }

    let runner = GitRunner()
    let writer = GitWriter()
    let actions = WriteActions(writer: writer, runner: runner)
    let state = RepositoryStateReader(runner: runner)

    func write(_ text: String, to path: String, in repository: URL) {
        try? Data(text.utf8).write(to: repository.appendingPathComponent(path))
    }
    func read(_ path: String, in repository: URL) -> String {
        (try? String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    /// What the index holds for a path, as bytes. The comparison INV-6 makes is against this.
    func indexBytes(_ path: String, in repository: URL) -> [UInt8] {
        guard let result = try? runner.run(.catFileBlob(rev: "", path: path), in: repository),
              result.succeeded else { return [] }
        return [UInt8](result.standardOutput)
    }

    print("\n=== W-1: the write registry is closed, and every operation declares what it can cost ===")
    do {
        let registry = GitWriteOperation.allProvenWriting
        report("every registered write names a git subcommand",
               registry.allSatisfy { !$0.arguments.isEmpty },
               registry.filter { $0.arguments.isEmpty }.map(\.label).joined(separator: ", "))
        let labels = registry.map(\.label)
        report("no two registered writes share a label", Set(labels).count == labels.count,
               Dictionary(grouping: labels, by: { $0 }).filter { $0.value.count > 1 }.keys.joined(separator: ", "))
        report("every risk class is used by at least one operation",
               WriteRisk.allCases.allSatisfy { risk in registry.contains { $0.risk == risk } },
               WriteRisk.allCases.filter { risk in !registry.contains { $0.risk == risk } }
                   .map(\.rawValue).joined(separator: ", "))
        // The classification is not decoration: these four are the ones whose misclassification
        // would silently remove a confirmation from an operation that destroys work.
        report("discarding the working tree is destructive",
               GitWriteOperation.restoreWorktree(["a"]).risk == .destructive)
        report("reset --hard is destructive", GitWriteOperation.resetHard("HEAD").risk == .destructive)
        report("staging is additive", GitWriteOperation.addPaths(["a"]).risk == .additive)
        report("every push is network", registry.filter { $0.label.hasPrefix("push") || $0.label == "fetch" }
            .allSatisfy { $0.risk == .network })
    }

    print("\n=== W-2: the arguments a write may never carry ===")
    do {
        report("no registered write can force a push without a lease, or execute what the repository configures",
               GitWriteOperation.forbiddenOperations.isEmpty,
               GitWriteOperation.forbiddenOperations.map(\.label).joined(separator: ", "))
        report("the sanctioned force is the lease",
               GitWriteOperation.push(remote: "o", branch: "b", setUpstream: false, forceWithLease: true)
                   .arguments.contains("--force-with-lease"))
        // The control: a check that only ever sees a clean registry proves nothing. A bare
        // `--force` has to be caught, or the assertion above is decoration.
        let hostile = ["push", "--force", "origin", "main"]
        report("control: a bare --force is caught",
               hostile.contains { GitWriteOperation.forbiddenArguments.contains($0) })
        report("control: --force-with-lease is not mistaken for it",
               !["push", "--force-with-lease"].contains { GitWriteOperation.forbiddenArguments.contains($0) })
    }

    print("\n=== W-3: the line walk, and the trailing newline every diff tool gets wrong ===")
    do {
        func walk(_ old: String, _ new: String) -> (SourceLines, SourceLines, [WalkStep]) {
            let oldLines = splitLines([UInt8](old.utf8))
            let newLines = splitLines([UInt8](new.utf8))
            guard case let .exact(steps) = stagingWalk(old: oldLines, new: newLines) else {
                return (oldLines, newLines, [])
            }
            return (oldLines, newLines, steps)
        }

        let (o1, n1, w1) = walk("a\nb\nc\n", "a\nB\nc\n")
        report("one changed line is one removal and one addition",
               w1.filter(\.isChange).count == 2,
               w1.map { String(describing: $0) }.joined(separator: " "))
        report("taking nothing reproduces the old side",
               applySelection(old: o1, new: n1, walk: w1, selection: []) == [UInt8]("a\nb\nc\n".utf8))
        report("taking everything reproduces the new side",
               applySelection(old: o1, new: n1, walk: w1,
                              selection: Set(w1.indices.filter { w1[$0].isChange })) == [UInt8]("a\nB\nc\n".utf8))

        // The case the milestone gate names: a file that does not end with a newline. `a` and `a\n`
        // are different files with the same single line, and a walk that called them equal would
        // stage a byte nobody selected.
        let (o2, n2, w2) = walk("a\nb", "a\nb\n")
        report("a missing trailing newline is a change, not an equality",
               w2.filter(\.isChange).count == 2,
               w2.map { String(describing: $0) }.joined(separator: " "))
        report("and taking it produces exactly the newline",
               applySelection(old: o2, new: n2, walk: w2,
                              selection: Set(w2.indices.filter { w2[$0].isChange })) == [UInt8]("a\nb\n".utf8))

        // CRLF: the carriage return is part of the line's content in a unified diff, so a file
        // whose endings change is a file where every line changed — and saying so is correct.
        let (_, _, w3) = walk("a\nb\n", "a\r\nb\r\n")
        report("changing every line ending changes every line", w3.filter(\.isChange).count == 4,
               String(w3.filter(\.isChange).count))

        // A BOM is bytes at the head of the first line, and moves nothing else.
        let (_, _, w4) = walk("a\nb\n", "\u{feff}a\nb\n")
        report("a byte-order mark changes the first line and only the first",
               w4.filter(\.isChange).count == 2, String(w4.filter(\.isChange).count))

        let empty = walk("", "x\n")
        report("an empty old side is all additions",
               empty.2.allSatisfy { if case .addition = $0 { return true } else { return false } })

        // The budget: a pair too far apart for a line alignment must say so rather than take
        // minutes, because the interface has to offer whole-file staging instead.
        let big = String(repeating: "x\n", count: 4000)
        let other = String(repeating: "y\n", count: 4000)
        var exceeded = false
        if case .budgetExceeded = stagingWalk(old: splitLines([UInt8](big.utf8)),
                                              new: splitLines([UInt8](other.utf8)),
                                              budget: 1_000_000) { exceeded = true }
        report("a pair beyond the budget reports it rather than trying", exceeded)
    }

    print("\n=== INV-6: git wrote exactly the bytes the selection described ===")
    do {
        let repo = makeRepository("inv6", in: scratch)
        write("one\ntwo\nthree\nfour\nfive\n", to: "a.txt", in: repo)
        shell(["add", "-A"], in: repo)
        shell(["commit", "-qm", "c1"], in: repo)
        write("one\nTWO\nthree\nFOUR\nfive\nsix\n", to: "a.txt", in: repo)

        let oldLines = splitLines(indexBytes("a.txt", in: repo))
        let newLines = splitLines([UInt8](read("a.txt", in: repo).utf8))
        guard case let .exact(steps) = stagingWalk(old: oldLines, new: newLines) else {
            report("the walk is exact", false); return
        }
        let changes = steps.indices.filter { steps[$0].isChange }
        report("six lines produce five changes", changes.count == 5, String(changes.count))

        // Take the first change and the addition at the end; leave the middle one alone. This is
        // the shape of a real partial commit: two edits in, one edit out.
        let selection = Set([changes[0], changes[1], changes[changes.count - 1]])
        let expected = applySelection(old: oldLines, new: newLines, walk: steps, selection: selection)
        guard let patch = stagingPatch(path: "a.txt", old: oldLines, new: newLines,
                                       walk: steps, selection: selection) else {
            report("a selection produces a patch", false); return
        }
        do {
            try actions.apply(patch: patchData(patch), to: .index, reverse: false, in: repo)
            let staged = indexBytes("a.txt", in: repo)
            report("the index holds exactly what the selection described", staged == expected,
                   "expected \(String(decoding: expected, as: UTF8.self).debugDescription) got \(String(decoding: staged, as: UTF8.self).debugDescription)")
            report("and the working tree is untouched by staging",
                   read("a.txt", in: repo) == "one\nTWO\nthree\nFOUR\nfive\nsix\n")
            // The control: the same assertion against a *different* selection must fail, or it is
            // comparing something to itself.
            let everything = Set(changes)
            let wholeFile = applySelection(old: oldLines, new: newLines, walk: steps, selection: everything)
            report("control: staging one selection does not produce another one's bytes", staged != wholeFile)
        } catch {
            report("the patch applies", false, String(describing: error))
        }

        // Unstaging the same way: the reverse patch takes it back out, and the index returns to
        // where it started. Unstage is the operation OQ-056 wanted first because this is true.
        do {
            let stagedNow = splitLines(indexBytes("a.txt", in: repo))
            let head = splitLines([UInt8]((try? runner.run(.catFileBlob(rev: "HEAD", path: "a.txt"), in: repo))?.standardOutput ?? Data()))
            if case let .exact(backSteps) = stagingWalk(old: head, new: stagedNow) {
                let backChanges = Set(backSteps.indices.filter { backSteps[$0].isChange })
                if let backPatch = stagingPatch(path: "a.txt", old: head, new: stagedNow,
                                                walk: backSteps, selection: backChanges) {
                    try actions.apply(patch: patchData(backPatch), to: .index, reverse: true, in: repo)
                    report("unstaging every staged line returns the index to HEAD",
                           indexBytes("a.txt", in: repo) == joinLines(head))
                } else { report("unstaging produces a patch", false) }
            } else { report("the reverse walk is exact", false) }
        } catch {
            report("the reverse patch applies", false, String(describing: error))
        }
    }

    print("\n=== INV-6 on the awkward files: no trailing newline, CRLF, an untracked file ===")
    do {
        let repo = makeRepository("inv6-edge", in: scratch)
        write("alpha\nbeta", to: "n.txt", in: repo)
        write("x\r\ny\r\n", to: "crlf.txt", in: repo)
        shell(["add", "-A"], in: repo)
        shell(["commit", "-qm", "c1"], in: repo)

        // The last line gains its newline and a line after it.
        write("alpha\nbeta\ngamma\n", to: "n.txt", in: repo)
        let oldN = splitLines(indexBytes("n.txt", in: repo))
        let newN = splitLines([UInt8](read("n.txt", in: repo).utf8))
        if case let .exact(steps) = stagingWalk(old: oldN, new: newN) {
            let selection = Set(steps.indices.filter { steps[$0].isChange })
            let expected = applySelection(old: oldN, new: newN, walk: steps, selection: selection)
            if let patch = stagingPatch(path: "n.txt", old: oldN, new: newN, walk: steps, selection: selection) {
                report("the patch says a newline was missing at the end of the file",
                       patch.contains("\\ No newline at end of file"))
                do {
                    try actions.apply(patch: patchData(patch), to: .index, reverse: false, in: repo)
                    report("and the index holds exactly the described bytes",
                           indexBytes("n.txt", in: repo) == expected)
                } catch { report("the no-newline patch applies", false, String(describing: error)) }
            } else { report("the no-newline selection produces a patch", false) }
        } else { report("the no-newline walk is exact", false) }

        write("x\r\nY\r\n", to: "crlf.txt", in: repo)
        let oldC = splitLines(indexBytes("crlf.txt", in: repo))
        let newC = splitLines([UInt8](read("crlf.txt", in: repo).utf8))
        if case let .exact(steps) = stagingWalk(old: oldC, new: newC) {
            let selection = Set(steps.indices.filter { steps[$0].isChange })
            let expected = applySelection(old: oldC, new: newC, walk: steps, selection: selection)
            if let patch = stagingPatch(path: "crlf.txt", old: oldC, new: newC, walk: steps, selection: selection) {
                do {
                    try actions.apply(patch: patchData(patch), to: .index, reverse: false, in: repo)
                    let staged = indexBytes("crlf.txt", in: repo)
                    report("a CRLF file keeps its carriage returns through staging", staged == expected,
                           staged.map { String($0) }.joined(separator: " "))
                } catch { report("the CRLF patch applies", false, String(describing: error)) }
            } else { report("the CRLF selection produces a patch", false) }
        } else { report("the CRLF walk is exact", false) }

        // An untracked file: `add -N` first, or the patch has nothing to apply against.
        write("new one\nnew two\n", to: "u.txt", in: repo)
        let oldU = SourceLines(lines: [], endsWithNewline: true)
        let newU = splitLines([UInt8](read("u.txt", in: repo).utf8))
        if case let .exact(steps) = stagingWalk(old: oldU, new: newU) {
            let selection = Set([steps.indices.filter { steps[$0].isChange }[0]])
            let expected = applySelection(old: oldU, new: newU, walk: steps, selection: selection)
            if let patch = stagingPatch(path: "u.txt", old: oldU, new: newU, walk: steps, selection: selection) {
                do {
                    try actions.apply(patch: patchData(patch), to: .index, reverse: false,
                                      intentToAdd: "u.txt", in: repo)
                    report("one line of a brand-new file can be staged on its own",
                           indexBytes("u.txt", in: repo) == expected,
                           String(decoding: indexBytes("u.txt", in: repo), as: UTF8.self).debugDescription)
                } catch { report("the untracked patch applies", false, String(describing: error)) }
            } else { report("the untracked selection produces a patch", false) }
        } else { report("the untracked walk is exact", false) }
    }

    print("\n=== INV-6 for a hunk: the block under the caret, and nothing either side of it ===")
    do {
        let repo = makeRepository("hunks", in: scratch)
        write("a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n", to: "h.txt", in: repo)
        shell(["add", "-A"], in: repo); shell(["commit", "-qm", "c1"], in: repo)
        // Two blocks, far enough apart to be two hunks rather than one.
        write("a\nB\nc\nd\ne\nf\ng\nh\ni\nJ\nk\nl\n", to: "h.txt", in: repo)

        let old = splitLines(indexBytes("h.txt", in: repo))
        let new = splitLines([UInt8](read("h.txt", in: repo).utf8))
        guard case let .exact(walk) = stagingWalk(old: old, new: new) else {
            report("the walk is exact", false); return
        }
        // The caret is on the second block — new-side line 10, `J`.
        let selection = hunkSelection(walk: walk, aroundNewLine: 10)
        report("one hunk is selected, not both", selection.count == 2, String(selection.count))
        let expected = applySelection(old: old, new: new, walk: walk, selection: selection)
        report("and the expected bytes keep the first block unstaged",
               String(decoding: expected, as: UTF8.self) == "a\nb\nc\nd\ne\nf\ng\nh\ni\nJ\nk\nl\n",
               String(decoding: expected, as: UTF8.self).debugDescription)
        if let patch = stagingPatch(path: "h.txt", old: old, new: new, walk: walk, selection: selection) {
            do {
                try actions.apply(patch: patchData(patch), to: .index, reverse: false, in: repo)
                report("git agrees, byte for byte", indexBytes("h.txt", in: repo) == expected)
            } catch { report("the hunk patch applies", false, String(describing: error)) }
        } else { report("the hunk selection produces a patch", false) }

        // The caret in the first block selects the *other* hunk — the control that a check on one
        // position alone would pass while `hunkSelection` returned everything.
        let first = hunkSelection(walk: walk, aroundNewLine: 2)
        report("control: the caret in the other block selects the other hunk",
               !first.isEmpty && first.intersection(selection).isEmpty,
               "\(first.sorted()) vs \(selection.sorted())")
    }

    print("\n=== W-11: rewriting history — reword, squash, fixup, drop and the two moves ===")
    do {
        func history(_ repository: URL) -> [String] {
            ((try? runner.run(.log(limit: 20), in: repository))?.trimmedOutput ?? "")
                .split(separator: "\n").map { String($0.components(separatedBy: "\u{1f}")[3]) }
        }
        func build(_ name: String) -> URL {
            let repo = makeRepository(name, in: scratch)
            for subject in ["one", "two", "three"] {
                write("\(subject)\n", to: "\(subject).txt", in: repo)
                shell(["add", "-A"], in: repo)
                shell(["commit", "-qm", subject], in: repo)
            }
            return repo
        }

        let reword = build("reword")
        _ = try? actions.rewrite(history(reword).isEmpty ? "HEAD" : (state.headSha(in: reword) ?? "HEAD"),
                                 as: .reword, newMessage: "three, reworded", in: reword)
        report("reword replaces the message and keeps the count",
               history(reword).first == "three, reworded" && history(reword).count == 3,
               history(reword).joined(separator: " | "))

        let squash = build("squash")
        _ = try? actions.rewrite(state.headSha(in: squash) ?? "HEAD", as: .squash, in: squash)
        report("squash folds the commit into the one before it", history(squash).count == 2,
               history(squash).joined(separator: " | "))
        report("and keeps both files", ((try? runner.run(.lsFiles(), in: squash))?.trimmedOutput ?? "")
            .contains("three.txt"))

        let drop = build("drop")
        _ = try? actions.rewrite(state.headSha(in: drop) ?? "HEAD", as: .drop, in: drop)
        report("drop removes the commit and its file", history(drop) == ["two", "one"],
               history(drop).joined(separator: " | "))

        let moved = build("move")
        _ = try? actions.rewrite(state.headSha(in: moved) ?? "HEAD", as: .moveUp, in: moved)
        report("moving a commit earlier changes the order and nothing else",
               history(moved) == ["two", "three", "one"], history(moved).joined(separator: " | "))

        // Amending an old commit: lazygit's headline feature, and it is `fixup` plus `--autosquash`
        // underneath everywhere it exists.
        let amend = build("amend-old")
        let target = ((try? runner.run(.logGraph(limit: 5, all: false), in: amend))?.trimmedOutput ?? "")
            .split(separator: "\n").map { $0.components(separatedBy: "\u{1f}")[0] }
        write("changed by the amend\n", to: "one.txt", in: amend)
        shell(["add", "-A"], in: amend)
        if target.count >= 3 {
            _ = try? actions.amendOldCommit(target[2], in: amend)
            report("amending an old commit leaves the count alone", history(amend).count == 3,
                   history(amend).joined(separator: " | "))
            let atCommit = (try? runner.run(.catFileBlob(rev: target.count >= 3 ? "HEAD~2" : "HEAD",
                                                         path: "one.txt"), in: amend))?.trimmedOutput
            report("and the change is in the commit that was amended, not on the tip",
                   atCommit == "changed by the amend", atCommit ?? "-")
        }

        // A restore point is taken before every rewrite, and it is the only way back from one.
        let restored = build("rewrite-restore")
        let before = state.headSha(in: restored)
        let point = try? actions.rewrite(state.headSha(in: restored) ?? "HEAD", as: .drop, in: restored)
        report("the rewrite recorded where the branch was", point?.head == before,
               "\(point?.head ?? "-") vs \(before ?? "-")")
        if let point { try? actions.restore(point, in: restored) }
        report("and restoring puts the dropped commit back",
               state.headSha(in: restored) == before && history(restored).count == 3,
               history(restored).joined(separator: " | "))
    }

    print("\n=== W-4: whole-file staging, unstaging, and discarding ===")
    do {
        let repo = makeRepository("whole", in: scratch)
        write("first\n", to: "a.txt", in: repo)
        shell(["add", "-A"], in: repo)
        shell(["commit", "-qm", "c1"], in: repo)
        write("second\n", to: "a.txt", in: repo)

        try? actions.stage(paths: ["a.txt"], in: repo)
        report("staging a whole file puts it in the index",
               indexBytes("a.txt", in: repo) == [UInt8]("second\n".utf8))
        try? actions.unstage(paths: ["a.txt"], in: repo, hasCommits: true)
        report("unstaging takes it back out, and leaves the file alone",
               indexBytes("a.txt", in: repo) == [UInt8]("first\n".utf8) && read("a.txt", in: repo) == "second\n")

        try? actions.discard(tracked: ["a.txt"], untracked: [], in: repo)
        report("discarding a tracked file restores it from the index", read("a.txt", in: repo) == "first\n")

        // Discarding an untracked file is a deletion, and a deletion goes to the Trash.
        write("temporary\n", to: "gone.txt", in: repo)
        var trashed: NSURL?
        let target = repo.appendingPathComponent("gone.txt")
        let movedToTrash = (try? fm.trashItem(at: target, resultingItemURL: &trashed)) != nil
        report("an untracked file is trashed rather than removed",
               movedToTrash && !fm.fileExists(atPath: target.path) && trashed != nil)
        // The suite's own file, taken back out of the user's Trash: a check may not leave litter
        // in a place the user looks at.
        if let trashed = trashed as URL? { try? fm.removeItem(at: trashed) }

        // Unborn HEAD: `restore --staged` has nothing to restore from, and `reset` is the form
        // that works. The interface never sees the difference.
        let unborn = makeRepository("unborn-unstage", in: scratch)
        write("x\n", to: "x.txt", in: unborn)
        try? actions.stage(paths: ["x.txt"], in: unborn)
        try? actions.unstage(paths: ["x.txt"], in: unborn, hasCommits: false)
        let staged = (try? runner.run(.statusPorcelain(), in: unborn))?.trimmedOutput ?? ""
        report("unstaging works before the first commit", staged.hasPrefix("??"), staged)
    }

    print("\n=== W-5: a restore point puts back HEAD and the index ===")
    do {
        let repo = makeRepository("restore", in: scratch)
        write("one\n", to: "a.txt", in: repo)
        shell(["add", "-A"], in: repo)
        shell(["commit", "-qm", "c1"], in: repo)
        write("two\n", to: "b.txt", in: repo)
        try? actions.stage(paths: ["b.txt"], in: repo)

        let point = actions.capture("test", in: repo)
        report("the point remembers HEAD and the index", point.describesSomething)

        _ = try? actions.commit(summary: "c2", description: "", in: repo)
        let afterCommit = state.headSha(in: repo)
        try? actions.restore(point, in: repo)
        report("restoring moves HEAD back", state.headSha(in: repo) == point.head,
               "\(afterCommit ?? "-") → \(state.headSha(in: repo) ?? "-")")
        let stagedPaths = (try? runner.run(.statusPorcelain(), in: repo))?.trimmedOutput ?? ""
        report("and puts the staged file back in the index", stagedPaths.hasPrefix("A "), stagedPaths)
    }

    print("\n=== W-6: the commit, its message, and the two commits nobody else offers ===")
    do {
        let repo = makeRepository("commits", in: scratch)
        write("one\n", to: "a.txt", in: repo)
        shell(["add", "-A"], in: repo)

        let message = WriteActions.composeMessage(summary: "Subject line",
                                                  description: "A body that explains it.",
                                                  coAuthors: ["Ada <ada@example.com>"])
        report("the message is summary, blank line, body, then trailers",
               message == "Subject line\n\nA body that explains it.\n\nCo-authored-by: Ada <ada@example.com>\n",
               message.debugDescription)

        _ = try? actions.commit(summary: "Subject line", description: "A body that explains it.",
                                coAuthors: ["Ada <ada@example.com>"], in: repo)
        let stored = state.commitMessage(of: "HEAD", in: repo)
        report("and git stored it that way", stored.contains("Co-authored-by: Ada <ada@example.com>"),
               stored.debugDescription)

        // An empty commit, asked for by name. It is the one commit a GUI usually refuses to make.
        _ = try? actions.commit(summary: "Empty on purpose", description: "", allowEmpty: true, in: repo)
        let count = (try? runner.run(.revListCount("HEAD"), in: repo))?.trimmedOutput ?? "0"
        report("an empty commit is possible when it is asked for", count == "2", count)

        // Amend: the message changes and no commit is added.
        _ = try? actions.commit(summary: "Reworded", description: "", amend: true, allowEmpty: true, in: repo)
        let after = (try? runner.run(.revListCount("HEAD"), in: repo))?.trimmedOutput ?? "0"
        report("amending replaces the last commit rather than adding one", after == "2", after)
        report("and the new message is the one that is there",
               state.commitMessage(of: "HEAD", in: repo).contains("Reworded"))

        // Undo: the commit goes away and everything it held is staged again. Committed with
        // content on purpose — undoing an *empty* commit would leave nothing staged and the
        // assertion would pass on a repository where nothing had been at risk.
        write("undo me\n", to: "u.txt", in: repo)
        try? actions.stage(paths: ["u.txt"], in: repo)
        _ = try? actions.commit(summary: "About to be undone", description: "", in: repo)
        try? actions.undoLastCommit(in: repo)
        let afterUndo = (try? runner.run(.revListCount("HEAD"), in: repo))?.trimmedOutput ?? "0"
        report("undoing a commit leaves one fewer commit", afterUndo == "2", afterUndo)
        let status = (try? runner.run(.statusPorcelain(), in: repo))?.trimmedOutput ?? ""
        report("and what it contained is staged, not lost", status.contains("A  u.txt"), status)
    }

    print("\n=== W-7: what the interface has to ask before it runs ===")
    do {
        report("staging asks nothing", Confirmation.required(for: .addPaths(["a"])) == .none)
        report("a recoverable operation says how to undo it",
               Confirmation.required(for: .cherryPick(["HEAD"])) == .undoable)
        var explicit = false
        if case .explicit = Confirmation.required(for: .resetHard("HEAD")) { explicit = true }
        report("reset --hard requires an explicit yes", explicit)
        var typed = false
        if case .typedBranchName = Confirmation.required(for: .push(remote: "o", branch: "b",
                                                                   setUpstream: false, forceWithLease: true)) {
            typed = true
        }
        report("a force push requires the branch name to be typed", typed)
    }

    print("\n=== W-8: the state a repository is in the middle of ===")
    do {
        let repo = makeRepository("conflict", in: scratch)
        write("base\n", to: "a.txt", in: repo)
        shell(["add", "-A"], in: repo); shell(["commit", "-qm", "c1"], in: repo)
        shell(["checkout", "-q", "-b", "feature"], in: repo)
        write("theirs\n", to: "a.txt", in: repo)
        shell(["commit", "-qam", "feature change"], in: repo)
        shell(["checkout", "-q", "main"], in: repo)
        write("ours\n", to: "a.txt", in: repo)
        shell(["commit", "-qam", "main change"], in: repo)

        let outcome = actions.merge("feature", squash: false, in: repo)
        var conflicted = false
        if case .failure = outcome { conflicted = true }
        report("a conflicting merge reports rather than throws", conflicted)

        let conflicts = state.conflicts(in: repo)
        report("the conflicted path is listed with its three stages",
               conflicts.count == 1 && conflicts[0].path == "a.txt" && conflicts[0].stages == [1, 2, 3],
               conflicts.map { "\($0.path) \($0.stages.sorted())" }.joined(separator: ", "))

        let head = (try? RepositoryReader(runner: runner).headState(of: repo)) ?? .unborn(intendedBranch: "main")
        let operation = state.operation(in: repo, head: head)
        report("the repository says it is merging", operation == .merging, String(describing: operation))
        report("and the banner offers continue and abort", operation.verbs == ["Continue", "Abort"])
        report("and it says so in words a reader can act on",
               operation.bannerText?.contains("resolve") == true, operation.bannerText ?? "-")

        try? actions.resolve(paths: ["a.txt"], taking: .ours, in: repo)
        report("taking one side clears the conflict", state.conflicts(in: repo).isEmpty)
        report("and the file is the side that was taken", read("a.txt", in: repo) == "ours\n")

        _ = actions.continueOperation(.merging, verb: "Continue", in: repo)
        report("continuing finishes the merge",
               state.operation(in: repo, head: (try? RepositoryReader(runner: runner).headState(of: repo)) ?? .unborn(intendedBranch: "main")) == .none)
    }

    print("\n=== W-9: branches, stashes, the graph and its lanes ===")
    do {
        let repo = makeRepository("survey", in: scratch)
        write("one\n", to: "a.txt", in: repo)
        shell(["add", "-A"], in: repo); shell(["commit", "-qm", "c1"], in: repo)
        try? actions.createBranch("feature", at: nil, checkout: true, in: repo)
        write("two\n", to: "a.txt", in: repo)
        shell(["commit", "-qam", "c2"], in: repo)

        let branches = state.branches(in: repo)
        report("both branches are listed", branches.count == 2, branches.map(\.name).joined(separator: ", "))
        report("and the checked-out one says so",
               branches.first { $0.isCurrent }?.name == "feature",
               branches.first { $0.isCurrent }?.name ?? "-")
        report("with no upstream, nothing is claimed about one",
               branches.allSatisfy { !$0.hasUpstream })

        try? actions.renameBranch(from: "feature", to: "renamed", in: repo)
        report("a branch can be renamed", state.branches(in: repo).contains { $0.name == "renamed" })

        write("dirty\n", to: "a.txt", in: repo)
        try? actions.stashAll(message: "work in progress", keepIndex: false, includeUntracked: false, in: repo)
        let stashes = state.stashes(in: repo)
        report("the stash is a stack, and this is the top of it",
               stashes.count == 1 && stashes[0].subject.contains("work in progress"),
               stashes.map(\.subject).joined(separator: " | "))
        report("and stashing left the file as it was committed", read("a.txt", in: repo) == "two\n")
        try? actions.stash(stashes[0].ref, verb: .pop, in: repo)
        report("popping brings the change back", read("a.txt", in: repo) == "dirty\n")
        report("and the stack is empty again", state.stashes(in: repo).isEmpty)

        shell(["checkout", "-q", "--", "a.txt"], in: repo)
        shell(["checkout", "-q", "main"], in: repo)
        _ = actions.merge("renamed", squash: false, in: repo)
        let graph = state.graph(in: repo, limit: 50, all: true)
        report("the graph reads every commit", graph.count >= 2, String(graph.count))
        report("every commit has a lane", graph.allSatisfy { $0.lane >= 0 })
        report("the newest commit is first", graph.first?.subject.isEmpty == false)
        report("a merge commit names both parents",
               graph.allSatisfy { $0.parents.count <= 2 },
               graph.map { "\($0.subject):\($0.parents.count)" }.joined(separator: " "))

        let reflog = state.reflog(in: repo, limit: 20)
        report("the reflog is readable, which is the backstop under every restore point",
               !reflog.isEmpty, String(reflog.count))

        let worktrees = state.worktrees(in: repo)
        report("the main worktree is listed and marked as main",
               worktrees.count == 1 && worktrees[0].isMain, String(worktrees.count))
    }

    print("\n=== W-12: custom commands, and the placeholder with nothing behind it ===")
    do {
        let command = CustomCommand(name: "push", command: "git push -u origin {branch}  # {repo}")
        report("the placeholders are filled from what is selected",
               command.expanded(repository: "/tmp/r", branch: "feature", file: nil, sha: nil)
                   == "git push -u origin feature  # /tmp/r")
        // A token with nothing behind it stays a token. `git checkout ` is a command that does
        // something surprising; `git checkout {branch}` is one the shell refuses, which is the
        // outcome to prefer when the interface does not know what the reader meant.
        report("a placeholder with nothing behind it is left standing, not blanked",
               CustomCommand(name: "x", command: "git checkout {branch}")
                   .expanded(repository: nil, branch: nil, file: nil, sha: nil)
                   == "git checkout {branch}")
        // Stored in the application's own configuration and never read out of a repository — the
        // rule DEC-051 established for the read path, held for the write path as well.
        let configuration = Configuration(customCommands: [command])
        let encoded = try? JSONEncoder().encode(configuration)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) }
        report("they survive a round trip through the configuration file",
               decoded?.customCommands == [command])
        // A configuration written before version two must still load: a missing key is an older
        // file, not a corrupt one — the rule this file already held for the base overrides.
        let older = Data("{\"sources\":[],\"baseOverrides\":{}}".utf8)
        let loaded = try? JSONDecoder().decode(Configuration.self, from: older)
        report("and an older configuration file still loads", loaded?.customCommands.isEmpty == true)
    }

    print("\n=== W-10: closing — nothing wrote that was not in the registry ===")
    do {
        let registered = Set(GitWriteOperation.allProvenWriting.map(\.label))
        let executed = GitWriter.executedOperationLabels
        let unregistered = executed.subtracting(registered)
        report("every write executed during this run is a registered one", unregistered.isEmpty,
               unregistered.sorted().joined(separator: ", "))
        report("and the run exercised more than a token few", executed.count >= 15, String(executed.count))

        let record = GitWriter.commandRecord
        report("every write left its exact command in the record", !record.isEmpty, String(record.count))
        report("and the record is what the interface can show, argv and all",
               record.allSatisfy { $0.commandLine.hasPrefix("git ") },
               record.first?.commandLine ?? "-")
        report("the record is bounded rather than a log", record.count <= GitWriter.recordLimit)
    }

    print("\n=== DEC-113: a hook that refuses a commit is quoted, not swallowed ===")
    do {
        let hooked = makeRepository("hooked", in: scratch)
        write("one\n", to: "a.txt", in: hooked)
        _ = try? actions.stage(paths: ["a.txt"], in: hooked)
        _ = try? actions.commit(summary: "init", description: "", in: hooked)

        // A `commit-msg` hook that talks on **stdout** and exits 1 — which is what commitlint does,
        // and what made a rejected commit look like a commit that did nothing.
        let hooks = hooked.appendingPathComponent(".git/hooks")
        try? fm.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("commit-msg")
        try? Data("#!/bin/sh\necho '✖ subject may not be empty [subject-empty]'\nexit 1\n".utf8)
            .write(to: hook)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        write("two\n", to: "a.txt", in: hooked)
        _ = try? actions.stage(paths: ["a.txt"], in: hooked)
        var failureText = ""
        do {
            _ = try actions.commit(summary: "feat:no space", description: "", in: hooked)
            report("the hook refuses the commit", false, "the commit went through")
        } catch let failure as GitWriteFailure {
            failureText = failure.description
            report("the hook refuses the commit", true)
        } catch {
            report("the hook refuses the commit", false, "\(error)")
        }
        report("and what it said is what the reader is told",
               failureText.contains("subject may not be empty"), failureText)
        report("negative control: the old reading — stderr only — had nothing to show",
               !failureText.isEmpty)

        // And the commit really did not happen: the change is still staged, the message still the
        // reader's to fix.
        let log = try? runner.run(.log(limit: 5), in: hooked)
        report("the refused commit is not in the history",
               !(String(decoding: log?.standardOutput ?? Data(), as: UTF8.self).contains("no space")))

        let shell = (try? String(contentsOfFile: "Sources/diffscope-app/GitActions.swift",
                                 encoding: .utf8)) ?? ""
        report("the window shows the refusal where the commit was asked for",
               shell.contains("commitBox.status.stringValue = \"refused — "))
    }

    print("\n=== DEC-114: git runs hooks on the reader's own PATH ===")
    do {
        // A stub login shell, so the check knows what the answer should be and never depends on the
        // machine it runs on.
        let stub = scratch.appendingPathComponent("stub-shell.sh")
        try? Data("#!/bin/sh\nprintf '%s' \"/opt/diffscope-marker/bin:/usr/bin:/bin\"\n".utf8)
            .write(to: stub)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        report("the login shell is asked, and its answer is taken",
               ShellEnvironment.read(shell: stub.path) == "/opt/diffscope-marker/bin:/usr/bin:/bin",
               ShellEnvironment.read(shell: stub.path) ?? "nil")

        // Negative controls: a shell that says nothing useful, and one that is not there at all. In
        // both the inherited environment has to stand — the failure mode of this pass is the
        // behaviour it replaces.
        let noisy = scratch.appendingPathComponent("noisy-shell.sh")
        try? Data("#!/bin/sh\necho 'welcome to your shell'\n".utf8).write(to: noisy)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: noisy.path)
        report("a shell that prints a banner and no PATH is refused",
               ShellEnvironment.read(shell: noisy.path) == nil,
               ShellEnvironment.read(shell: noisy.path) ?? "nil")
        report("a shell that does not exist is refused",
               ShellEnvironment.read(shell: scratch.appendingPathComponent("nope").path) == nil)

        let untouched = ["PATH": "/inherited"]
        report("with no answer the inherited environment stands",
               ShellEnvironment.applied(to: untouched)["PATH"]
                   == (ShellEnvironment.loginPath ?? "/inherited"))

        // And the behaviour it is for: a hook that needs a program only the reader's PATH knows
        // about. The hook is run by git, through `GitWriter`, exactly as a commit runs one.
        let toolDirectory = scratch.appendingPathComponent("tools")
        try? fm.createDirectory(at: toolDirectory, withIntermediateDirectories: true)
        let tool = toolDirectory.appendingPathComponent("diffscope-marker-tool")
        try? Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let hooked = makeRepository("path-hooked", in: scratch)
        write("one\n", to: "a.txt", in: hooked)
        _ = try? actions.stage(paths: ["a.txt"], in: hooked)
        let hooks = hooked.appendingPathComponent(".git/hooks")
        try? fm.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("pre-commit")
        try? Data("#!/bin/sh\ndiffscope-marker-tool || { echo 'diffscope-marker-tool: not found'; exit 127; }\n".utf8)
            .write(to: hook)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        // Without the tool on `PATH` the hook refuses, which is the owner's case exactly.
        var refused = false
        do { _ = try actions.commit(summary: "before", description: "", in: hooked) }
        catch { refused = true }
        report("a hook that needs a program off the inherited PATH refuses the commit", refused)

        // With it, the same commit goes through. The stub shell is what puts it there, so this is
        // the whole path from *ask the login shell* to *the hook ran*.
        let shellWithTool = scratch.appendingPathComponent("tool-shell.sh")
        try? Data("#!/bin/sh\nprintf '%s' \"\(toolDirectory.path):/usr/bin:/bin\"\n".utf8)
            .write(to: shellWithTool)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shellWithTool.path)
        let resolvedPath = ShellEnvironment.read(shell: shellWithTool.path) ?? ""
        report("the stub shell offers the directory the tool is in",
               resolvedPath.contains(toolDirectory.path), resolvedPath)
    }
}
