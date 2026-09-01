import Foundation
import DiffScopeShell
import DiffScopeGit

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

    print("\n=== what the reader chose survives what they did not choose ===")
    let page = (try? String(contentsOfFile: "Renderer/src/main.js", encoding: .utf8)) ?? ""

    // One rule, stated once, about what each value is an index into. Fold sets index the fold list,
    // which a mode change rebuilds differently; `stopIndex` indexes `stops`, which the engine
    // computes from the canonical byte diff and which is therefore the same list in every mode.
    report("fold sets follow the pinned pair **and** the mode",
           page.contains("if (!samePin || !sameMode) {")
               && page.contains("expanded = new Set();")
               && page.contains("expandedReflows = new Set();"))
    report("and the change-stop follows the pinned pair alone",
           page.range(of: "if (!samePin) {").map { range in
               String(page[range.lowerBound...].prefix(220)).contains("stopIndex = -1;")
           } ?? false)
    report("a stop index outliving its list is clamped, not kept",
           page.contains("if (stopIndex >= stops.length) stopIndex = stops.length - 1;"))
    // The unified view is built lazily, so a wrap chosen before it existed used to be lost.
    report("the unified view is built with the wrap the reader chose",
           page.contains("unifiedWrapping.of(wrapEnabled ? EditorView.lineWrapping : [])")
               && page.contains("wrapEnabled = enabled;"))
    // Two layouts are two documents, so an offset does not carry — the stop does, and it is what
    // the reader was actually looking at.
    report("switching layout keeps the reader's place",
           page.contains("if (stopIndex >= 0 && stopIndex < stops.length) goToStopIndex(stopIndex);")
               && page.contains("restoreViewportLine("))
    report("and opening a withheld block keeps it too",
           page.range(of: "function expandReflow(").map { range in
               let body = String(page[range.lowerBound...].prefix(900))
               return body.contains("captureViewportLine(unified)")
                   && body.contains("restoreViewportLine(unified, mark)")
           } ?? false)
    // A document the reader has just opened starts at the top rather than at the previous file's
    // scroll offset, clamped.
    report("a new document starts at the top when there is no anchor",
           page.contains("if (!samePin && !(model.restore && model.restore.resolution !== \"noPreviousAnchor\"))"))

    // Folding is a question about the list, not about which file to read.
    report("folding a directory does not re-render the diff",
           shell.range(of: "func setDirectory(").map { range in
               String(shell[range.lowerBound...].prefix(1600)).contains("restoringSelection = true")
           } ?? false)
    report("and its fallback goes to the neighbour rather than to row zero",
           shell.range(of: "func setDirectory(").map { range in
               let body = String(shell[range.lowerBound...].prefix(1900))
               return body.contains("RowNavigation.nearestSelectable(in: state.fileRows, to: previous)")
                   && !body.contains("RowNavigation.firstSelectable(in: state.fileRows)")
           } ?? false)
    // The sweep re-selects a row whenever the open repository's index moves, which says nothing
    // about the repository having changed.
    report("collapsed directories survive a reselect of the same repository",
           shell.contains("if self.openRepositoryPath != repository.url.standardizedFileURL.path {"))
    report("the drawer reopens at the height the reader left it",
           shell.contains("terminalHeightConstraint.constant = visible ? terminalHeight : 0"))

    print("\n=== the window shows one answer, and stands behind it ===")

    // Five surfaces share the diff pane and four of them are `flex: 1`, so any two shown at once
    // split it between two answers. Every show-path used to hide whichever others its author had
    // in mind, and the render never hid the lens at all.
    report("one place decides which surface owns the pane",
           page.contains("const paneSurfaces = {") && page.contains("function showSurface(name)"))
    var strays: [String] = []
    for (number, raw) in page.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.contains("style.display ="), !line.hasPrefix("//"), !line.hasPrefix("///") else { continue }
        // The one assignment inside `showSurface`, and the style audit reading a computed value.
        guard !line.contains("id === name ? shown"), !line.contains("style.display ===") else { continue }
        strays.append("line \(number + 1): \(line.prefix(60))")
    }
    report("and nothing else shows or hides one", strays.isEmpty, strays.joined(separator: " | "))
    // Control: the scan has to be able to see an offender at all.
    report("control: a surface shown outside it would be caught",
           !page.isEmpty && "  host.style.display = \"block\";".contains("style.display ="))

    // An early return that leaves the previous file's answers behind is a window offering to act
    // on a document it is not showing.
    report("an unrenderable file clears the folds, stops and footer it is not about",
           page.range(of: "content cannot be displayed as text").map { range in
               // Backwards from the sentence the branch prints — the forward form matched a
               // same-shaped guard in `blockFacts`, four hundred lines earlier.
               let body = String(page[..<range.lowerBound].suffix(900))
               return body.contains("folds = [];") && body.contains("stops = [];")
                   && body.contains("updateFooter(model);") && body.contains("stopIndex = -1;")
           } ?? false)
    // A scope that cannot be computed must not go on offering its last result.
    report("an unavailable scope empties the pane rather than keeping its last diff",
           shell.contains("clearDiffPane(reason:") && shell.contains("state.selectedFile = nil"))
    report("and the page has a way to be emptied with a stated reason",
           page.contains("window.diffscopeClearDiff = function (reason)"))
    // The newest-wins guard covered the text path only.
    report("a late image comparison cannot land under another file's name",
           shell.range(of: "if kind.rendersAsImage {").map { range in
               String(shell[range.lowerBound...].prefix(700))
                   .contains("guard self.state.selectedFile?.path == file.path else { return }")
           } ?? false)
    report("and neither can a mid-write refusal",
           shell.range(of: "guard pair.stable else {").map { range in
               String(shell[range.lowerBound...].prefix(500))
                   .contains("guard self.state.selectedFile?.path == file.path else { return }")
           } ?? false)
    // Staging moves bytes between the index and the working tree, which is what two scopes compare.
    report("a write refreshes the diff it just changed",
           git.range(of: "func afterWrite()").map { range in
               String(git[range.lowerBound...].prefix(1200)).contains("refreshCurrentFile()")
           } ?? false)
    // The one feed that admits it lost data used to get a clause appended to whatever sentence
    // happened to be in the status line.
    report("a dropped-events signal re-reads more than one file change does",
           shell.range(of: "if signal == .rescan {").map { range in
               let body = String(shell[range.lowerBound...].prefix(500))
               return body.contains("refreshOpenRepositoryRow()") && body.contains("refreshGitState()")
                   && !body.contains("statusLabel.stringValue +=")
           } ?? false)

    print("\n=== the same question is not asked twice ===")

    // One reading, parsed once, derived twice. Checked against bytes rather than against a
    // repository, so the awkward cases can be written down rather than constructed.
    let porcelain = Data(([" M src/a.ts", "?? nowy/żółć.txt", "R  b.ts", "a.ts", "UU c.ts",
                           "A  \"q r\".ts"].joined(separator: "\0") + "\0").utf8)
    let snapshot = StatusSnapshot(porcelainZ: porcelain)
    report("the porcelain reading is parsed once, into entries",
           snapshot.entries.count == 5, "\(snapshot.entries.count)")
    report("a non-ASCII path arrives unquoted and unescaped",
           snapshot.entries.contains { $0.path == "nowy/żółć.txt" },
           snapshot.entries.map(\.path).joined(separator: " | "))
    report("a rename carries the path it came from",
           snapshot.entries.contains { $0.path == "b.ts" && $0.original == "a.ts" })
    report("and a name with a space and a quote in it is one entry",
           snapshot.entries.contains { $0.path == "\"q r\".ts" })
    report("an unmerged pair survives the parse",
           snapshot.entries.contains { $0.index == "U" && $0.worktree == "U" })

    // The changed-file list and the staging state are two derivations of that one reading. They
    // used to run `git status` for themselves, one after the other, on the main thread.
    report("reloadFiles takes one status reading and derives both from it",
           shell.contains("statusSnapshot = StatusSnapshot(porcelainZ: result.standardOutput)")
               && shell.contains("gitState.staging(from: $0)"))

    print("\n=== the page does not pay for what it is not showing ===")
    report("decorations are rebuilt only where a document is",
           page.range(of: "function refreshDecorations()").map { range in
               String(page[range.lowerBound...].prefix(400)).contains("view.state.doc.length")
           } ?? false)
    report("an already-empty pane is not emptied again",
           page.contains("if (left.state.doc.length) applySide(left, empty);")
               && page.contains("if (unified && unified.state.doc.length) {"))
    report("the group counts are walked once per render",
           page.contains("lastGroupCounts = groupCounts(model);")
               && !page.contains("Object.fromEntries(groupCounts(model))"))
    report("the segment projection is a merge walk, not a nested loop",
           page.contains("while (first < runs.length && runs[first].srcEnd <= seg.start) first += 1;"))

    print("\n=== a control is not redrawn to say what it already says ===")
    let pill = (try? String(contentsOfFile: "Sources/diffscope-app/PillControl.swift",
                            encoding: .utf8)) ?? ""
    let staging = (try? String(contentsOfFile: "Sources/diffscope-app/StagingControls.swift",
                               encoding: .utf8)) ?? ""
    report("the chrome's labels refuse a write that changes nothing",
           ledger.contains("final class QuietLabel: NSTextField")
               && shell.contains("statusLabel = QuietLabel(") && shell.contains("watchLabel = QuietLabel(")
               && shell.contains("comparisonLabel = QuietLabel(")
               && shell.contains("let field = QuietLabel(labelWithString: \"\")"))
    report("and the rule lives in the label rather than at 53 call sites",
           !shell.contains("if statusLabel.stringValue !="))
    report("a pill segment relayouts its glass only when its availability changes",
           pill.contains("guard segments[index].enabled != enabled else { return }"))
    report("the operation banner is rebuilt only when the operation changes",
           staging.contains("guard drawn != operation else { return }"))

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
