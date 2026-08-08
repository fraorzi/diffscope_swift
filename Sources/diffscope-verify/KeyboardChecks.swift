import DiffScopeGit
import DiffScopeShell
import DiffScopeSyntax
import Foundation

/// The keyboard map and the walk it has to survive (DEC-016, DEC-057, definition of done §6).
///
/// Two different claims are checked here, and they fail for different reasons:
///
/// - **Coverage.** `12-desktop-ux-specification.md` §9 lists nine functions and says any of them
///   reachable only by pointer is a defect. That table is transcribed into `KeyboardFunction`, and
///   every row must have a binding. This is the check that would have caught *show raw for the
///   current region* being specified and never built — it stayed missing for three milestones.
/// - **The walk.** Definition of done §6 is about a **63-file** working tree. Headers are labels
///   under DEC-033, so 63 files under twelve headers must still cost 62 steps; a header that takes
///   the selection is a stop that shows nothing, which is the shape the arrow keys had until M8-J.
///
/// Each has a negative control, because a check that has only ever seen a passing input proves
/// nothing — the lesson G2 was built on.
func runKeyboardChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    print("\n=== the keyboard map (DEC-016, DEC-057) ===")

    let unbound = KeyboardMap.unboundFunctions()
    report("every function `12-…` §9 requires has a binding", unbound.isEmpty,
           unbound.map(\.requirement).joined(separator: "; "))

    let collisions = KeyboardMap.collisions()
    report("no two bindings claim the same keystroke", collisions.isEmpty,
           collisions.map { "\($0.0): \($0.1.map(\.id).joined(separator: ", "))" }.joined(separator: " | "))

    // A binding that is in no menu is reachable by nothing at all: macOS routes key equivalents
    // through the menu bar, so a row the shell never draws is a row that does not exist.
    let placed = KeyboardMenu.allCases.flatMap { KeyboardMap.bindings(in: $0) }
    report("every binding is drawn in a menu", placed.count == KeyboardMap.bindings.count,
           "\(placed.count) of \(KeyboardMap.bindings.count)")

    // The one binding without a keystroke is deliberate — Remove Source destroys configuration and
    // is not something to hand a single key — so it is asserted rather than left looking like an
    // oversight for the next reader to "fix".
    let unbounded = KeyboardMap.bindings.filter { $0.key.isEmpty }.map(\.id)
    report("only Remove Source is deliberately without a keystroke", unbounded == ["sources.remove"],
           unbounded.joined(separator: ", "))

    report("the control view for a region is bound",
           KeyboardMap.bindings.contains { $0.satisfies == .rawForCurrentRegion && $0.shortcut == "⌥⌘V" },
           KeyboardMap.bindings.first { $0.satisfies == .rawForCurrentRegion }?.shortcut ?? "unbound")

    // Negative controls, run through the same functions the real map goes through. Both defects are
    // constructed rather than argued about: a map missing a function must report it, and two
    // bindings on one keystroke must be found.
    let withoutEditor = KeyboardMap.bindings.filter { $0.satisfies != .openInEditor }
    report("negative control: a map with `open in editor` removed reports it unbound",
           KeyboardMap.unboundFunctions(in: withoutEditor) == [.openInEditor],
           KeyboardMap.unboundFunctions(in: withoutEditor).map(\.rawValue).joined(separator: ", "))

    let collided = KeyboardMap.bindings + [
        KeyboardBinding(id: "intruder", title: "Intruder", key: "n", modifiers: [.command],
                        menu: .navigate),
    ]
    report("negative control: a second binding on ⌘N is caught",
           KeyboardMap.collisions(in: collided).contains { $0.0 == "⌘N" },
           KeyboardMap.collisions(in: collided).map(\.0).joined(separator: ", "))

    print("\n=== a 63-file working tree, walked (definition of done §6) ===")

    // The shape the claim is about: `mailingi-2025` had 63 changed files when DEC-033 was written.
    // Reproduced here as rows rather than as a repository, because what is under test is the walk.
    let files = (0..<63).map { index in
        ChangedFile(path: "packages/app-\(index / 6)/src/components/nested/File\(index).tsx",
                    originalPath: nil, kind: .modified)
    }
    let rows = fileListRows(files)
    let headers = rows.filter { $0.file == nil }.count
    report("the 63-file list groups, so the walk has headers to survive", headers > 1,
           "\(headers) headers over \(rows.count) rows")

    var visited: [String] = []
    var cursor = RowNavigation.firstSelectable(in: rows)
    var headerStops = 0
    var steps = 0
    while let current = cursor {
        if let file = rows[current].file { visited.append(file.path) } else { headerStops += 1 }
        guard let next = RowNavigation.step(rows: rows, from: current, delta: 1) else { break }
        cursor = next
        steps += 1
    }
    report("every one of the 63 files is reached going down", visited.count == 63, "\(visited.count)")
    report("no keystroke lands on a header", headerStops == 0, "\(headerStops) header stops")
    report("62 keystrokes, one per file after the first — grouping does not lengthen the walk",
           steps == 62, "\(steps) steps")
    report("each file is visited exactly once", Set(visited).count == visited.count,
           "\(Set(visited).count) distinct of \(visited.count)")
    report("the walk stops at the end rather than wrapping",
           RowNavigation.step(rows: rows, from: rows.count - 1, delta: 1) == nil)

    var back: [String] = []
    var reverse: Int? = rows.lastIndex { $0.file != nil }
    while let current = reverse {
        if let file = rows[current].file { back.append(file.path) }
        guard let previous = RowNavigation.step(rows: rows, from: current, delta: -1) else { break }
        reverse = previous
    }
    report("and the same 63 going back up", back.count == 63 && Set(back) == Set(visited),
           "\(back.count)")
    report("the walk stops at the top rather than wrapping",
           RowNavigation.step(rows: rows, from: RowNavigation.firstSelectable(in: rows), delta: -1) == nil)

    // A header can be *asked for* by a click or by a restored selection, and the answer must be no.
    let headerIndex = rows.firstIndex { $0.file == nil } ?? 0
    report("a header cannot be selected by any route",
           !RowNavigation.isSelectable(rows: rows, row: headerIndex))
    report("a file can", RowNavigation.isSelectable(rows: rows, row: headerIndex + 1))

    // Negative control for the walk: the behaviour the arrow keys actually had until M8-J — step to
    // the next row whatever it is. It must reach the end more slowly *and* stop on rows that show
    // nothing, which is the defect, stated as a measurement rather than as a complaint.
    var naiveSteps = 0
    var naiveHeaderStops = 0
    for (index, row) in rows.enumerated() {
        if row.file == nil { naiveHeaderStops += 1 }
        if index > 0 { naiveSteps += 1 }
    }
    report("negative control: stepping row by row stops on \(naiveHeaderStops) rows that show nothing",
           naiveHeaderStops == headers && naiveSteps > steps, "\(naiveSteps) steps, \(naiveHeaderStops) blind")

    // Walking the list fast is what found this, so walking it fast is what checks it. The parser is
    // one shared `TSParser`, and two renders overlapping inside it aborted the process on a
    // tree-sitter assertion; every other check in the suite parses on one thread, so nothing here
    // could have seen it. A check that only ever ran serially was not a check about the application.
    //
    // Its negative control was run once, by hand, by taking the lock back out of `TSXParser`: the
    // suite does not report a failure, it **aborts** — `ts_stack_state, file stack.c, line 464`.
    // That is what the defect does, so that is what the control has to show.
    print("\n=== the parser under a keyboard-speed walk (M8-J) ===")
    if let parser = TSXParser() {
        let sources = (0..<24).map { index in
            [UInt8]("""
            export function File\(index)({ label }: { label: string }) {
              return (
                <section className="file-\(index)">
                  <header>{label}</header>
                </section>
              );
            }

            """.utf8)
        }
        let outcomes = UnsafeMutablePointer<Int>.allocate(capacity: sources.count)
        outcomes.initialize(repeating: 0, count: sources.count)
        DispatchQueue.concurrentPerform(iterations: sources.count) { index in
            outcomes[index] = parser.parse(sources[index])?.leaves.count ?? 0
        }
        let parsed = (0..<sources.count).filter { outcomes[$0] > 0 }.count
        outcomes.deallocate()
        report("24 concurrent parses on one shared parser all return a tree",
               parsed == sources.count, "\(parsed) of \(sources.count)")
    } else {
        report("24 concurrent parses on one shared parser all return a tree", false, "no parser")
    }

    // An ungrouped list — one file, or a shape the grouping threshold rejects — must still walk.
    let flat = fileListRows([ChangedFile(path: "only.tsx", originalPath: nil, kind: .modified)])
    report("a one-file list has a first stop and nowhere further to go",
           RowNavigation.firstSelectable(in: flat) == 0
               && RowNavigation.step(rows: flat, from: 0, delta: 1) == nil)
    report("an empty list has no stop at all", RowNavigation.firstSelectable(in: []) == nil)
}
