import Foundation

/// There is one road to a redraw, and it has a counter on it.
///
/// DEC-109 and DEC-112 are both checked today by grepping `main.swift` for the text of their
/// guards, and both guards are defeated at run time by a *second*, unguarded call on the same
/// path: `annotateFiles` full-reloads the file table a fifth of a second after DEC-112's targeted
/// reload succeeds, and `refreshGitState` full-reloads it one line later. A grep for the presence
/// of a guard cannot see that.
///
/// So the shape changes. `RedrawLedger` is the only thing in the application that may call
/// `reloadData`, every call states a reason, and the counts are what the application selftest
/// asserts against real scenarios. This file's job is the structural half: **proving no second
/// road exists.** Without it the ledger is a convention, and a convention is what the two
/// defeated guards already were.
///
/// The same pattern as `KeyboardMap.bindings` — one place where a keystroke becomes a method, and
/// a check that nothing else does it — and for the same reason: the first thing that check found
/// was a specification row with no implementation that had gone unnoticed for three milestones.
func runRedrawChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    print("\n=== every redraw goes through RedrawLedger, and nothing else may draw ===")

    let appSources = ["Sources/diffscope-app/main.swift",
                      "Sources/diffscope-app/GitActions.swift",
                      "Sources/diffscope-app/StagingControls.swift",
                      "Sources/diffscope-app/PillControl.swift",
                      "Sources/diffscope-app/TerminalPane.swift"]

    /// A `reloadData` that is not inside the ledger. Comments and doc comments mention it by name
    /// all over this codebase — DEC-109's own explanation does — so a line that is a comment does
    /// not count. Matching the call rather than the word: `reloadData(`.
    func directCalls(in text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"), !line.hasPrefix("///"), !line.hasPrefix("*") else { return nil }
            guard line.contains("reloadData(") else { return nil }
            return "line \(index + 1): \(line.prefix(70))"
        }
    }

    var offences: [String] = []
    for path in appSources {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        guard !text.isEmpty else { offences.append("\(path): unreadable"); continue }
        for call in directCalls(in: text) { offences.append("\(path) \(call)") }
    }
    report("no surface calls reloadData for itself", offences.isEmpty,
           offences.joined(separator: " | "))

    let ledger = (try? String(contentsOfFile: "Sources/diffscope-app/RedrawLedger.swift",
                              encoding: .utf8)) ?? ""
    report("RedrawLedger is where reloadData lives", ledger.contains("table?.reloadData()")
               && ledger.contains("reloadData(forRowIndexes:"))

    // Every redraw states why. A ledger of anonymous entries counts correctly and diagnoses
    // nothing, and the reason is the half a reader of a failed assertion actually needs.
    report("and every call through it states a reason",
           ledger.contains("reason: String"),
           "reloadAll and reloadRows both take one")

    // The negative control. Without it this check would read identically while matching nothing —
    // the failure mode this project has found in its own checks more than once.
    let hostile = """
        func drawSomething() {
            fileTable.reloadData()
        }
        """
    report("control: a surface that draws for itself is caught",
           !directCalls(in: hostile).isEmpty)
    // And its twin: the comment exemption must not be a hole big enough to hide a call in.
    let commented = "        // `reloadData` keeps the selected index and this pass does not change"
    report("control: a comment naming reloadData is not an offence",
           directCalls(in: commented).isEmpty)

    print("\n=== the renderer counts what it redrew ===")
    let renderer = (try? String(contentsOfFile: "Renderer/src/main.js", encoding: .utf8)) ?? ""
    for counter in ["renders", "documentReplacements", "decorationRebuilds",
                    "layoutSwitches", "noticeRebuilds", "foldStateResets"] {
        report("the page counts \(counter)", renderer.contains("\(counter):"))
    }
    report("and a scenario can zero them", renderer.contains("window.diffscopeResetCounters"))
    // Counted inside `applySide`, not at its call sites: a unified render calls it three times —
    // the composed document and two empty panes — and a count taken outside would say one.
    if let body = renderer.range(of: "function applySide(view, side) {") {
        let head = String(renderer[body.upperBound...].prefix(120))
        report("documentReplacements is counted inside applySide",
               head.contains("counters.documentReplacements"))
    } else {
        report("applySide exists to count in", false)
    }
}
