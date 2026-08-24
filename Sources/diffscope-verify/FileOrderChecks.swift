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

    print("\n=== DEC-111: a new file in a new folder is a file in a folder before it is staged ===")
    do {
        let fresh = root.appendingPathComponent("fresh")
        try? fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main", "."], in: fresh)
        git(["config", "user.email", "t@t"], in: fresh)
        git(["config", "user.name", "t"], in: fresh)
        write("kept\n", to: "README.md", in: fresh)
        git(["add", "-A"], in: fresh)
        git(["commit", "-qm", "init"], in: fresh)
        // The owner's case: a folder that does not exist in HEAD, with two files in it.
        write("a\n", to: "src/call-to-action-banner/CallToActionBanner.tsx", in: fresh)
        write("b\n", to: "src/call-to-action-banner/styles.module.css", in: fresh)
        // And a path git would quote in the line-based form.
        write("c\n", to: "src/new folder/Weird Name.tsx", in: fresh)

        let reader = ScopeReader()
        func paths() -> [String] {
            ((try? reader.changedFiles(scope: .allLocalVsHead, in: fresh)) ?? []).map(\.path)
        }
        let before = paths()
        report("the untracked folder is listed as its files, not as itself",
               before.contains("src/call-to-action-banner/CallToActionBanner.tsx")
                   && !before.contains { $0.hasSuffix("/") },
               before.joined(separator: " "))
        report("a path with a space arrives unquoted",
               before.contains("src/new folder/Weird Name.tsx"), before.joined(separator: " "))

        let rowsBefore = fileTreeRows(((try? reader.changedFiles(scope: .allLocalVsHead, in: fresh)) ?? []))
        git(["add", "src/call-to-action-banner/CallToActionBanner.tsx"], in: fresh)
        let rowsAfter = fileTreeRows(((try? reader.changedFiles(scope: .allLocalVsHead, in: fresh)) ?? []))
        report("and staging one of them rebuilds the same tree",
               rowsBefore.map { $0.file?.path ?? "d" } == rowsAfter.map { $0.file?.path ?? "d" },
               "\(rowsBefore.count) rows before, \(rowsAfter.count) after")

        // The number on the repository row and the list it sits above must agree — the whole reason
        // the count's convention is written under it.
        let counted = (try? RepositoryReader().uncommittedCount(in: fresh)) ?? -1
        report("the repository count agrees with the list",
               counted == paths().count, "count \(counted), list \(paths().count)")
    }

    print("\n=== DEC-112: the row is a name and a number, and the bar is one chip ===")
    do {
        let shell = (try? String(contentsOfFile: "Sources/diffscope-app/main.swift",
                                 encoding: .utf8)) ?? ""
        let renderer = (try? String(contentsOfFile: "Renderer/src/main.js", encoding: .utf8)) ?? ""

        // The three-letter badge is gone from the row and the fact is not: `annotate` still runs and
        // the tooltip still says it, which is what the check has to pin — a badge removed by deleting
        // the computation would take the fact with it.
        report("the file row draws no annotation badge",
               !shell.contains("ChipView(text: $0.badge)"))
        report("and the row's tooltip still carries what the badge said",
               shell.contains("(annotation.map { \" · \\($0.rawValue)\" } ?? \"\")"))

        // Ticking a box redraws the boxes that changed, not the tree.
        report("staging redraws only the rows whose box changed",
               shell.contains("fileTable.reloadData(forRowIndexes:"))

        // One chip at rest, every sentence behind it, and the sentences still built the same way.
        report("the notice bar draws a summary chip",
               renderer.contains("ds-chip-summary") && renderer.contains("noticesExpanded"))
        report("and every notice is one click away",
               renderer.contains("summary.title = items.join"))
        report("a file with nothing to report still shows nothing",
               renderer.contains("if (!items.length) return;"))
    }
}
