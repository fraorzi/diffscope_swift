import CryptoKit
import DiffScopeGit
import Foundation

private let fm = FileManager.default

/// Shared with `DegradationChecks`: the forced fixtures build repositories the same way.
@discardableResult
func shell(_ args: [String], in dir: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", dir.path] + args
    var env = ProcessInfo.processInfo.environment
    env["GIT_AUTHOR_NAME"] = "t"; env["GIT_AUTHOR_EMAIL"] = "t@t"
    env["GIT_COMMITTER_NAME"] = "t"; env["GIT_COMMITTER_EMAIL"] = "t@t"
    process.environment = env
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func snapshotGitDirectory(_ repository: URL) -> [String: String] {
    var digest: [String: String] = [:]
    let gitDir = repository.appendingPathComponent(".git")
    guard let walker = fm.enumerator(at: gitDir, includingPropertiesForKeys: [.isRegularFileKey]) else { return digest }
    for case let url as URL in walker {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        guard let data = try? Data(contentsOf: url) else { continue }
        let relative = url.path.replacingOccurrences(of: gitDir.path + "/", with: "")
        digest[relative] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    return digest
}

func makeRepository(_ name: String, in parent: URL) -> URL {
    let url = parent.appendingPathComponent(name)
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    shell(["init", "-q", "-b", "main", "."], in: url)
    shell(["config", "user.email", "t@t"], in: url)
    shell(["config", "user.name", "t"], in: url)
    return url
}

func runGitChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("diffscope-m2-\(UUID().uuidString)")
    try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: scratch) }

    let runner = GitRunner()
    let reader = RepositoryReader(runner: runner)
    let scopes = ScopeReader(runner: runner)

    let repo = makeRepository("primary", in: scratch)
    try? "line one\nline two\nżółć\n".write(
        to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    shell(["add", "-A"], in: repo)
    shell(["commit", "-qm", "c1"], in: repo)
    shell(["branch", "feature"], in: repo)
    shell(["checkout", "-q", "feature"], in: repo)
    try? "line one\nCHANGED\nżółć\n".write(
        to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    shell(["commit", "-qam", "c2"], in: repo)
    try? "staged\n".write(to: repo.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
    shell(["add", "s.txt"], in: repo)
    try? "unstaged edit\n".write(
        to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try? "untracked\n".write(to: repo.appendingPathComponent("u.txt"), atomically: true, encoding: .utf8)

    print("\n=== R-8: every Git operation is proven not to write ===")
    do {
        GitRunner.resetExecutedOperationLabels()
        var offenders: [String] = []
        for operation in GitOperation.allProvenReadOnly {
            let before = snapshotGitDirectory(repo)
            _ = try? runner.run(operation, in: repo)
            let after = snapshotGitDirectory(repo)
            if before != after { offenders.append(operation.label) }
        }
        report("all \(GitOperation.allProvenReadOnly.count) registered operations leave .git byte-identical",
               offenders.isEmpty, offenders.joined(separator: ", "))

        let stale = repo.appendingPathComponent("a.txt")
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: stale.path)
        let before = snapshotGitDirectory(repo)
        _ = try? runner.run(.statusPorcelain(), in: repo)
        let after = snapshotGitDirectory(repo)
        report("status leaves .git untouched even with a stale stat cache", before == after,
               before.keys.filter { before[$0] != after[$0] }.joined(separator: ", "))
    }

    print("\n=== R-1..R-3: base branch detection cascade ===")
    do {
        let resolution = try? reader.resolveBaseBranch(in: repo)
        report("unique local default resolves without a remote",
               resolution == .resolved(ref: "main", source: .uniqueLocalDefault),
               String(describing: resolution))

        let both = makeRepository("both-defaults", in: scratch)
        try? "x\n".write(to: both.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        shell(["add", "-A"], in: both); shell(["commit", "-qm", "c"], in: both)
        shell(["branch", "master"], in: both)
        let ambiguous = try? reader.resolveBaseBranch(in: both)
        report("both main and master present asks the user", ambiguous == .needsUserChoice,
               String(describing: ambiguous))

        let overridden = try? reader.resolveBaseBranch(in: both, override: "develop")
        report("explicit override wins", overridden == .resolved(ref: "develop", source: .userOverride))
    }

    print("\n=== R-12: unborn HEAD, and the idiom that lies ===")
    do {
        let unborn = makeRepository("unborn", in: scratch)
        try? "hi\n".write(to: unborn.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let symbolic = try? runner.run(.symbolicRefHead(), in: unborn)
        report("git symbolic-ref reports a branch that does not exist",
               (symbolic?.succeeded ?? false) && symbolic?.trimmedOutput == "main",
               "exit=\(symbolic?.exitCode ?? -1) out=\(symbolic?.trimmedOutput ?? "")")

        let head = try? reader.headState(of: unborn)
        var isUnborn = false
        if case .unborn = head { isUnborn = true }
        report("headState uses rev-parse --verify and reports unborn", isUnborn, String(describing: head))
        report("unborn HEAD supports no HEAD comparison", head?.supportsHeadComparison == false)

        for scope in ComparisonScope.allCases {
            let availability = scopes.availability(of: scope, head: head ?? .unborn(intendedBranch: nil), base: .needsUserChoice)
            report("scope \(scope.rawValue) is unavailable with a reason on unborn HEAD",
                   !availability.isAvailable, String(describing: availability))
        }

        let snapshot = try? reader.snapshot(of: unborn)
        report("ahead count is unknown, never a fabricated zero", snapshot?.aheadCount == nil,
               String(describing: snapshot?.aheadCount))
    }

    print("\n=== R-4: detached HEAD ===")
    do {
        let detached = makeRepository("detached", in: scratch)
        try? "a\n".write(to: detached.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        shell(["add", "-A"], in: detached); shell(["commit", "-qm", "c1"], in: detached)
        let sha = shell(["rev-parse", "HEAD"], in: detached)
        shell(["checkout", "-q", sha], in: detached)
        let head = try? reader.headState(of: detached)
        var isDetached = false
        if case .detached = head { isDetached = true }
        report("detached HEAD is identified as detached", isDetached, String(describing: head))
        let availability = scopes.availability(of: .branchVsMergeBase, head: head ?? .unborn(intendedBranch: nil), base: .needsUserChoice)
        report("merge-base scope unavailable when detached", !availability.isAvailable)
    }

    print("\n=== R-7: the four scopes select the right files ===")
    do {
        let staged = (try? scopes.changedFiles(scope: .stagedVsHead, in: repo)) ?? []
        let unstaged = (try? scopes.changedFiles(scope: .unstagedVsIndex, in: repo)) ?? []
        let all = (try? scopes.changedFiles(scope: .allLocalVsHead, in: repo)) ?? []

        report("staged scope sees only the staged file",
               staged.map(\.path) == ["s.txt"], staged.map(\.path).description)
        report("unstaged scope sees the worktree edit and the untracked file",
               unstaged.map(\.path).sorted() == ["a.txt", "u.txt"], unstaged.map(\.path).description)
        report("all-local scope is the union",
               Set(all.map(\.path)) == Set(["a.txt", "s.txt", "u.txt"]), all.map(\.path).description)
        report("untracked file is labelled untracked",
               unstaged.first { $0.path == "u.txt" }?.kind == .untracked)

        let mergeBaseRev = shell(["merge-base", "main", "HEAD"], in: repo)
        let branchFiles = (try? scopes.changedFiles(scope: .branchVsMergeBase, in: repo, baseRef: "main")) ?? []
        report("merge-base scope sees the committed branch change",
               branchFiles.map(\.path) == ["a.txt"], branchFiles.map(\.path).description)

        if let file = branchFiles.first,
           let pair = try? scopes.pinnedPair(for: file, scope: .branchVsMergeBase, in: repo, mergeBaseRev: mergeBaseRev) {
            report("pinned pair carries distinct content hashes", pair.oldHash != pair.newHash)
            report("pinned old side is the merge-base blob, byte-exact",
                   String(decoding: pair.oldBytes, as: UTF8.self) == "line one\nline two\nżółć\n",
                   String(decoding: pair.oldBytes, as: UTF8.self).debugDescription)
            report("pinned new side is the HEAD blob, byte-exact",
                   String(decoding: pair.newBytes, as: UTF8.self) == "line one\nCHANGED\nżółć\n",
                   String(decoding: pair.newBytes, as: UTF8.self).debugDescription)
        } else {
            report("pinned pair could be built for the merge-base scope", false)
        }

        if let worktreeFile = unstaged.first(where: { $0.path == "a.txt" }),
           let pair = try? scopes.pinnedPair(for: worktreeFile, scope: .unstagedVsIndex, in: repo) {
            report("worktree side is read from disk, byte-exact",
                   String(decoding: pair.newBytes, as: UTF8.self) == "unstaged edit\n")
        }
    }

    print("\n=== R-10, R-11: discovery ===")
    do {
        let rootA = scratch.appendingPathComponent("rootA")
        let nested = rootA.appendingPathComponent("clients")
        try? fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let depth2 = makeRepository("deep", in: nested)
        let tooDeep = nested.appendingPathComponent("more")
        try? fm.createDirectory(at: tooDeep, withIntermediateDirectories: true)
        _ = makeRepository("deeper", in: tooDeep)

        let discovery = RepositoryDiscovery(maximumDepth: 2)
        let result = discovery.discover(sources: [DiscoverySource(url: rootA, kind: .root)])
        report("depth 2 finds the repository two levels down",
               result.repositories.contains { $0.url.standardizedFileURL.path == depth2.standardizedFileURL.path },
               result.repositories.map(\.displayName).description)
        report("depth limit excludes anything deeper",
               !result.repositories.contains { $0.displayName == "deeper" })

        let individual = discovery.discover(sources: [DiscoverySource(url: repo, kind: .individualRepository)])
        report("an individually added repository is found regardless of depth",
               individual.repositories.count == 1)

        let notARepo = discovery.discover(sources: [DiscoverySource(url: scratch, kind: .individualRepository)])
        report("a non-repository added individually is reported, not silently dropped",
               notARepo.diagnostics.contains { if case .notARepository = $0 { return true }; return false })

        let missing = discovery.discover(sources: [
            DiscoverySource(url: scratch.appendingPathComponent("nope"), kind: .root)
        ])
        report("a missing source is reported",
               missing.diagnostics.contains { if case .sourceMissing = $0 { return true }; return false })

        let linkRoot = scratch.appendingPathComponent("linkRoot")
        try? fm.createDirectory(at: linkRoot, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: linkRoot.appendingPathComponent("escape"), withDestinationURL: repo)
        let linked = discovery.discover(sources: [DiscoverySource(url: linkRoot, kind: .root)])
        report("a symlink escaping its root is refused",
               linked.diagnostics.contains { if case .symlinkEscapesRoot = $0 { return true }; return false }
                   || linked.repositories.isEmpty,
               linked.diagnostics.map(\.description).description)

        let merged = discovery.discover(sources: [
            DiscoverySource(url: rootA, kind: .root),
            DiscoverySource(url: repo, kind: .individualRepository),
        ])
        report("multiple sources merge without duplicates",
               Set(merged.repositories.map(\.identity)).count == merged.repositories.count)
    }

    print("\n=== R-8 closing: no operation ran that was not proven ===")
    do {
        let proven = Set(GitOperation.allProvenReadOnly.map(\.label))
        let executed = GitRunner.executedOperationLabels
        let unproven = executed.subtracting(proven)
        report("every operation executed during this run appears in the proven registry",
               unproven.isEmpty, unproven.sorted().joined(separator: ", "))
        report("the runner always passes --no-optional-locks",
               GitRunner.readOnlyGlobalArguments.contains("--no-optional-locks"))
    }
}

/// `12-…` §4's counts. The parser, because the shape git emits is the part that bites: a `-` where
/// a number would be, and a rename written as a path expression rather than a path.
func runNumstatChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    print("\n=== line counts are read, and `binary` is a state rather than a zero (12-… §4) ===")
    let counts = parseNumstat("""
        9\t11\tpackages/web/src/results/ResultsList.tsx
        184\t0\tpackages/ui/src/list/List.tsx
        -\t-\tapps/desktop/assets/icon@2x.png
        3\t3\tpackages/web/src/panel/{Frame.tsx => Panel.tsx}
        """)
    report("added and deleted come back per path",
           counts["packages/web/src/results/ResultsList.tsx"]
               == ChangeCount(added: 9, deleted: 11, isBinary: false))
    report("a new file has no deletions rather than a missing entry",
           counts["packages/ui/src/list/List.tsx"]?.deleted == 0)
    report("binary is a state, not +0 −0",
           counts["apps/desktop/assets/icon@2x.png"]?.isBinary == true)
    report("and it says the word rather than a count",
           counts["apps/desktop/assets/icon@2x.png"]?.text == "binary")
    report("a rename is keyed by the path the list uses — the new one",
           counts["packages/web/src/panel/Panel.tsx"]
               == ChangeCount(added: 3, deleted: 3, isBinary: false),
           counts.keys.sorted().joined(separator: ", "))

    report("the counts are worded once, where they are computed",
           ChangeCount(added: 9, deleted: 11, isBinary: false).text == "+9 −11"
               && ChangeCount(added: 184, deleted: 0, isBinary: false).text == "+184"
               && ChangeCount(added: 0, deleted: 0, isBinary: false).text == "±0")

    report("negative control: a truncated row is skipped rather than read as a path",
           parseNumstat("9\tpackages/only-two-fields.tsx\n").isEmpty)

    report("the operation is in the registry the read-only proof runs over",
           GitOperation.allProvenReadOnly.contains { $0.label == "diff-numstat" })
}
