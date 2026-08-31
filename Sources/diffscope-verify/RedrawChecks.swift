import Foundation
import DiffScopeShell

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

    print("\n=== a refresh of an unchanged document does no work ===")
    let shell = (try? String(contentsOfFile: "Sources/diffscope-app/main.swift", encoding: .utf8)) ?? ""
    let git = (try? String(contentsOfFile: "Sources/diffscope-app/GitActions.swift",
                           encoding: .utf8)) ?? ""

    // The decision itself, asked every question it has. It is a pure function for exactly this
    // reason — the rule it encodes cannot otherwise be exercised without driving a window, and a
    // rule checked once by hand is a rule that drifts.
    let showing = RenderPin(path: "a.tsx", mode: "structural", oldHash: "h1", newHash: "h2")
    report("the same document in the same mode is not drawn again",
           renderIsRedundant(displayed: showing, wanted: showing, restoringStop: nil))
    for (name, wanted) in [
        ("a different file", RenderPin(path: "b.tsx", mode: "structural", oldHash: "h1", newHash: "h2")),
        ("a different mode", RenderPin(path: "a.tsx", mode: "raw", oldHash: "h1", newHash: "h2")),
        ("changed old bytes", RenderPin(path: "a.tsx", mode: "structural", oldHash: "x", newHash: "h2")),
        ("changed new bytes", RenderPin(path: "a.tsx", mode: "structural", oldHash: "h1", newHash: "x")),
    ] {
        report("\(name) is drawn",
               !renderIsRedundant(displayed: showing, wanted: wanted, restoringStop: nil))
    }
    // Both halves. The second is the one that matters: a guard against redrawing is one line from
    // being a way never to draw at all.
    report("nothing on screen means draw",
           !renderIsRedundant(displayed: nil, wanted: showing, restoringStop: nil))
    report("and ⌥⌘V re-renders the same pair on purpose",
           !renderIsRedundant(displayed: showing, wanted: showing, restoringStop: 3))
    report("the render asks it rather than deciding for itself",
           shell.contains("renderIsRedundant(displayed: displayed, wanted: wanted,"))
    // Inside `render`, and before the build — the whole value of the pin is that it is asked
    // before the parse rather than after it.
    report("and it is asked before the model is built",
           shell.range(of: "private func render(file: ChangedFile").map { start in
               let body = String(shell[start.lowerBound...].prefix(9000))
               guard let pin = body.range(of: "renderIsRedundant(displayed:"),
                     let build = body.range(of: "buildModel(path: file.path") else { return false }
               return pin.lowerBound < build.lowerBound
           } ?? false)
    // Both halves, deliberately: a guard against redrawing is one line from being a way never to
    // draw at all. Four surfaces can take the pane away from the diff or empty it.
    report("a pin is forgotten wherever the document stops being the diff",
           shell.components(separatedBy: "displayedPin = nil").count - 1 >= 4,
           "\(shell.components(separatedBy: "displayedPin = nil").count - 1) sites")
    report("and the pin it records is the one it compared",
           shell.contains("self.displayedPin = wanted"))

    // The sweep runs on a concurrent queue, so *is this the newest answer* is a different question
    // from *is this still the repository*, and the scope it counted for is a third.
    report("the annotation sweep checks generation, repository and scope",
           shell.contains("generation == self.annotationGeneration")
               && shell.contains("self.state.selectedRepository?.url == repository.url")
               && shell.contains("self.state.scope == scope"))
    report("and it redraws only the rows whose annotation or count changed",
           shell.contains("previousAnnotations[path] != found[path]")
               && shell.contains("previousCounts[path] != counts[path]"))
    report("refreshGitState redraws only the boxes that changed",
           git.contains("previousStaging[path] != state.staging[path]"))
    // A write changes the counts of one repository. `rescan()` sweeps every configured one.
    report("a write refreshes the repository it was made in, not all of them",
           git.range(of: "func afterWrite()").map { range in
               let body = String(git[range.lowerBound...].prefix(600))
               return body.contains("refreshOpenRepositoryRow()") && !body.contains("rescan()\n")
           } ?? false)
    report("and a command finishing in the drawer does the same",
           shell.range(of: "func refreshAfterCommand()").map { range in
               String(shell[range.lowerBound...].prefix(1200)).contains("refreshOpenRepositoryRow()")
           } ?? false)
    // A row passed through under the arrow keys is not a row chosen.
    report("walking the repository list coalesces its work",
           shell.contains("generation == self.openRepositoryGeneration"))
    // A restoration that lands on the same file is not a selection: rendering it discarded the
    // reader's position a moment before the anchored render tried to restore it.
    report("a restored selection on the same file does not render again",
           shell.contains("if restoringSelection, file.path == state.selectedFile?.path { return }"))

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
