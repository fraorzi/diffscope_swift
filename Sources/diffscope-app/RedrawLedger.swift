import AppKit

/// What was actually redrawn, and why.
///
/// This project has been wrong about the screen three times in a way no check could see: M6-D (a
/// verified move reached the renderer unpaired), M8-D (both lists rendered completely blank rows
/// and nothing failed), and T1-A (the first terminal selftest passed every arm while the snapshot
/// was blank). The pattern is always the same — **the suite cannot see the screen**, so a defect
/// that is only visible costs a milestone to find.
///
/// Flicker is that defect class again. `DEC-109` and `DEC-112` both attacked it and both were
/// written as *source* checks: `InstallChecks` greps `main.swift` for the literal text of the
/// guard, and `FileOrderChecks` greps for `reloadData(forRowIndexes:`. Both pass today, and both
/// are defeated at run time — `annotateFiles` full-reloads the table a fifth of a second after
/// DEC-112's targeted reload succeeds, and `refreshGitState` full-reloads it one line after. A
/// grep for a guard cannot see a second, unguarded call on the same path.
///
/// So the guard stops being a phrase to grep for and becomes **a road with a counter on it**.
/// Every redraw goes through here with a stated reason; `Sources/diffscope-verify/RedrawChecks.swift`
/// asserts that no other road exists, with a negative control; and the application selftest drives
/// real scenarios and asserts the numbers.
///
/// **What these numbers are, and are not.** They count the *cause* — how many times a table was
/// told to rebuild — not the *effect*, which is photons. A `reloadData` that rebuilds sixty-three
/// identical stacks of views produces an identical picture, so a pixel comparison would call it
/// clean. That is exactly why the count is the assertion: the work is real whether or not the
/// result differs, and it is the work that costs a frame.
final class RedrawLedger {

    /// The two lists. An enum rather than a string because a misspelled surface in a `switch` over
    /// strings falls into `default` and is counted as nothing — a redraw that happened and that no
    /// assertion can see, which is the exact defect this file exists to prevent.
    enum Surface: String, CaseIterable {
        case file
        case repo
    }

    /// How much of a surface was redrawn. `rows` carries the count rather than the set, because
    /// what an assertion wants to say is *one row changed*, not *which*.
    enum Extent: Equatable {
        case everything
        case rows(Int)
    }

    /// One redraw, as it happened. Kept in order: the sequence is the finding. Two entries a
    /// fifth of a second apart, the second saying `everything`, is the shape of the defect this
    /// type exists to make visible.
    struct Entry: Equatable {
        let surface: Surface
        let extent: Extent
        let reason: String
    }

    /// Monotonic since the last `reset()`. Deliberately not a dictionary: a named field is a thing
    /// an assertion can misspell and fail on, where a missing dictionary key reads as zero and
    /// passes.
    struct Counts: Equatable {
        var fileTableFull = 0
        var fileTableRows = 0
        var repoTableFull = 0
        var repoTableRows = 0
        /// Every cell view built. The unit cost behind the other three — there is no view reuse in
        /// either table, so a full reload of a 63-file tree builds 63 stacks of views and roughly
        /// 250 constraints. Counted separately because *how many reloads* and *how much work they
        /// cost* are two questions, and collapsing a 63-row table and a 2-row one into "1 reload"
        /// would hide the answer to the second.
        var cellsBuilt = 0
        /// Calls across the JavaScript bridge on a product path. Each is an async round trip, and
        /// one file save currently makes three of them.
        var bridgeCalls = 0
    }

    private(set) var counts = Counts()
    private(set) var entries: [Entry] = []

    /// Rebuild the whole list. The expensive one, and the one every finding so far is about.
    ///
    /// The table is optional because `GitActions` reaches it as `fileTable?` — an extension on the
    /// same controller, called before the window exists in one path. A nil table still records the
    /// entry: *we decided to redraw and there was nothing to redraw* is worth seeing, and silently
    /// dropping it would make the ledger disagree with the code it is measuring.
    func reloadAll(_ table: NSTableView?, _ surface: Surface, reason: String) {
        entries.append(Entry(surface: surface, extent: .everything, reason: reason))
        switch surface {
        case .file: counts.fileTableFull += 1
        case .repo: counts.repoTableFull += 1
        }
        table?.reloadData()
    }

    /// Rebuild named rows. DEC-112's form: the rows are the same rows, and what changed is one
    /// row's answer to *is this in the commit*.
    func reloadRows(_ table: NSTableView?, _ surface: Surface, _ rows: IndexSet, reason: String) {
        guard !rows.isEmpty else { return }
        entries.append(Entry(surface: surface, extent: .rows(rows.count), reason: reason))
        switch surface {
        case .file: counts.fileTableRows += 1
        case .repo: counts.repoTableRows += 1
        }
        table?.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    func cellBuilt() { counts.cellsBuilt += 1 }
    func bridgeCall() { counts.bridgeCalls += 1 }

    /// Called by a scenario before it begins. The entries go too: a scenario asserting *zero full
    /// reloads* wants to name the ones it found, and a list left over from the previous scenario
    /// would name the wrong ones.
    func reset() {
        counts = Counts()
        entries = []
    }

    /// What the assertion prints when it fails. A bare `expected 0, got 2` sends the reader back
    /// to the debugger; the reasons say which two, in order, which is usually the whole diagnosis.
    var summary: String {
        guard !entries.isEmpty else { return "nothing redrawn" }
        return entries.map { entry in
            let extent: String
            switch entry.extent {
            case .everything: extent = "all"
            case .rows(let n): extent = "\(n) row\(n == 1 ? "" : "s")"
            }
            return "\(entry.surface.rawValue)/\(extent): \(entry.reason)"
        }.joined(separator: " · ")
    }
}
