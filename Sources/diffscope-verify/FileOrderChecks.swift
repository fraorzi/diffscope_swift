import DiffScopeGit
import Foundation

/// Ticking a file's box must not move the file (DEC-106).
///
/// The owner reported it as *why does it suddenly change position?* — and the answer turned out not
/// to be the sort, which is by path on both sides of the write. It is the **list membership**: three
/// of the four scopes answer a different question about the same repository, and in two of them a
/// staged file is no longer part of the answer.
///
/// This measures the rows the way the window builds them — `fileTreeRows` over `changedFiles` — and
/// asks, for every scope, what ticking a box does to the row order.
func runFileOrderChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("diffscope-order-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    func git(_ arguments: [String], in url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = url
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
    func write(_ text: String, to path: String, in url: URL) {
        let file = url.appendingPathComponent(path)
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    let repository = root.appendingPathComponent("repo")
    try? fm.createDirectory(at: repository, withIntermediateDirectories: true)
    git(["init", "-q", "-b", "main", "."], in: repository)
    git(["config", "user.email", "t@t"], in: repository)
    git(["config", "user.name", "t"], in: repository)
    for path in ["root.ts", "src/a/one.ts", "src/a/two.ts", "src/b/three.ts", "src/b/four.ts"] {
        write("original\n", to: path, in: repository)
    }
    git(["add", "-A"], in: repository)
    git(["commit", "-qm", "init"], in: repository)
    for path in ["root.ts", "src/a/one.ts", "src/a/two.ts", "src/b/three.ts", "src/b/four.ts"] {
        write("edited\n", to: path, in: repository)
    }
    write("brand new\n", to: "src/a/five.ts", in: repository)

    let scopes = ScopeReader()
    func rows(_ scope: ComparisonScope) -> [String] {
        let files = (try? scopes.changedFiles(scope: scope, in: repository)) ?? []
        return fileTreeRows(files).map { row in
            switch row {
            case let .file(file, _, _): return "f:" + file.path
            case let .directory(key, _, _, _): return "d:" + key
            }
        }
    }

    print("\n=== DEC-106: ticking a box does not move the file ===")

    for scope in [ComparisonScope.allLocalVsHead, .unstagedVsIndex, .stagedVsHead] {
        let before = rows(scope)
        git(["add", "src/a/two.ts"], in: repository)
        let after = rows(scope)
        git(["reset", "-q", "HEAD", "src/a/two.ts"], in: repository)

        let stayed = before == after
        let name = "\(scope.title): staging a file leaves every row where it was"
        // `unstaged` and `staged` answer questions a staged file changes the answer to, and moving
        // it there is the scope working. `all local vs HEAD` is the scope the box belongs to, and it
        // must not move anything at all.
        if scope == .allLocalVsHead {
            report(name, stayed, stayed ? "" : "before \(before) after \(after)")
        } else {
            report("\(scope.title): a staged file leaves this scope, which is the scope working",
                   !stayed,
                   "before \(before.count) rows, after \(after.count)")
        }
    }

    // The untracked case, which is the one that can reorder without changing membership: git prints
    // `??` entries last, so a file that becomes tracked moves within git's own output.
    let before = rows(.allLocalVsHead)
    git(["add", "src/a/five.ts"], in: repository)
    let after = rows(.allLocalVsHead)
    git(["rm", "-q", "--cached", "src/a/five.ts"], in: repository)
    report("all local vs HEAD: staging an untracked file leaves every row where it was",
           before == after, before == after ? "" : "before \(before)\n           after \(after)")

    // Where the selection lands when the row it was on has left the list.
    let sample = fileTreeRows([
        ChangedFile(path: "src/a/one.ts", originalPath: nil, kind: .modified),
        ChangedFile(path: "src/a/two.ts", originalPath: nil, kind: .modified),
        ChangedFile(path: "src/b/three.ts", originalPath: nil, kind: .modified),
    ])
    let shorter = fileTreeRows([
        ChangedFile(path: "src/a/one.ts", originalPath: nil, kind: .modified),
        ChangedFile(path: "src/b/three.ts", originalPath: nil, kind: .modified),
    ])
    // Stay-or-after: the landing is never *earlier* than where the reader was, unless there is
    // nothing at or after it. The exact row depends on how the tree groups, which is not what this
    // is about.
    let landings = shorter.indices.compactMap { index -> (Int, Int)? in
        RowNavigation.nearestSelectable(in: shorter, to: index).map { (index, $0) }
    }
    report("the selection lands at or after where the reader was",
           landings.allSatisfy { $0.1 >= $0.0 },
           landings.map { "\($0.0)→\($0.1)" }.joined(separator: " "))
    report("and falls back upwards when the last row was the one that went",
           RowNavigation.nearestSelectable(in: shorter, to: 99)
               .map { shorter[$0].file?.path } == "src/b/three.ts")
    report("negative control: the first selectable row is not where it lands",
           RowNavigation.firstSelectable(in: shorter) != RowNavigation.nearestSelectable(in: shorter, to: 3),
           "first \(RowNavigation.firstSelectable(in: shorter) ?? -1)")
    report("a header is never the answer",
           sample.indices.allSatisfy { index in
               guard let landing = RowNavigation.nearestSelectable(in: sample, to: index) else { return true }
               return sample[landing].file != nil
           })
}
