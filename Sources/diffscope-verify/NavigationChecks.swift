import DiffScopeEngine
import DiffScopeSyntax
import Foundation

func runNavigationChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    print("\n=== navigation stops follow the canonical diff ===")
    do {
        let old = [UInt8]((1...40).map { "line \($0)\n" }.joined().utf8)
        var newText = (1...40).map { "line \($0)\n" }.joined()
        newText = newText.replacingOccurrences(of: "line 5\n", with: "line five\n")
        newText = newText.replacingOccurrences(of: "line 35\n", with: "line thirty-five\n")
        let new = [UInt8](newText.utf8)
        let model = trivialModel(oldBytes: old, newBytes: new)
        let stops = changeStops(model)

        report("two separated edits give two stops", stops.count == 2, "\(stops.count) stops")
        report("stops are ordered on both sides",
               zip(stops, stops.dropFirst()).allSatisfy { $0.oldEnd <= $1.oldStart && $0.newEnd <= $1.newStart })
        report("every stop names a position on both sides",
               stops.allSatisfy { $0.oldStart <= $0.oldEnd && $0.newStart <= $0.newEnd })

        if case let .exact(hunks) = canonicalDiff(old: old, new: new) {
            report("a stop exists for every canonical hunk", stops.count == hunks.count,
                   "\(stops.count) vs \(hunks.count)")
        }

        print("        folds hide only content that is byte-equal on both sides")
        let folds = collapseRanges(model, stops: stops)
        report("a long unchanged stretch is offered as a fold", !folds.isEmpty, "\(folds.count) folds")
        report("every folded range is byte-identical across sides",
               folds.allSatisfy { Array(old[$0.oldStart..<$0.oldEnd]) == Array(new[$0.newStart..<$0.newEnd]) })
        report("no fold overlaps a change",
               folds.allSatisfy { fold in
                   stops.allSatisfy { fold.oldEnd <= $0.oldStart || fold.oldStart >= $0.oldEnd }
               })
        report("folds keep context around each change",
               folds.allSatisfy { $0.lines >= collapseMinimumLines }, folds.map { "\($0.lines)" }.joined(separator: ","))
        report("folds start and end on line boundaries",
               folds.allSatisfy { fold in
                   (fold.oldStart == 0 || old[fold.oldStart - 1] == 0x0A)
                       && (fold.oldEnd == old.count || old[fold.oldEnd - 1] == 0x0A)
               })
    }

    print("\n=== nothing is folded when there is nothing to hide ===")
    do {
        let short = [UInt8]("const a = 1;\nconst b = 2;\n".utf8)
        let edited = [UInt8]("const a = 9;\nconst b = 2;\n".utf8)
        let model = trivialModel(oldBytes: short, newBytes: edited)
        let stops = changeStops(model)
        report("a small file offers no folds", collapseRanges(model, stops: stops).isEmpty)
        report("but it still offers a stop", !stops.isEmpty)

        let identical = trivialModel(oldBytes: short, newBytes: short)
        report("byte-equal sides offer no stops", changeStops(identical).isEmpty)
        report("and no folds", collapseRanges(identical, stops: []).isEmpty)
    }

    print("\n=== the render contract carries navigation in UTF-16, like everything else ===")
    do {
        guard let parser = TSXParser() else { report("parser for the navigation checks", false); return }
        let oldText = "const shop = \"\u{017B}ABKA\";\n" + (1...30).map { "const v\($0) = \($0);\n" }.joined()
        let newText = "const shop = \"\u{017B}ABKA\";\n" + (1...30).map { "const v\($0) = \($0 == 30 ? 99 : $0);\n" }.joined()
        let result = structuralDiff(oldPath: "a.tsx", oldBytes: [UInt8](oldText.utf8),
                                    newPath: "a.tsx", newBytes: [UInt8](newText.utf8), parser: parser)
        let render = buildRenderModel(model: result.model, pinOld: "a", pinNew: "b", mode: "structural")
        guard case let .text(old, new) = render.payload else { report("navigation renders", false); return }

        report("stops reach the renderer", !render.stops.isEmpty, "\(render.stops.count) stops")
        report("folds reach the renderer", !render.collapses.isEmpty, "\(render.collapses.count) folds")
        report("every stop lies inside the document, in UTF-16 units",
               render.stops.allSatisfy { $0.oldEnd <= old.utf16Length && $0.newEnd <= new.utf16Length })
        report("offsets are UTF-16, not bytes — the ŻABKA line proves the difference",
               old.utf16Length < [UInt8](oldText.utf8).count,
               "utf16 \(old.utf16Length) vs bytes \([UInt8](oldText.utf8).count)")

        // A stop the reader jumps to must land inside something the interface has marked,
        // or "next change" would scroll to text that looks unchanged.
        let presented = old.segments.filter { $0.label != "unchanged" }
        report("every stop lands inside a presented range",
               render.stops.allSatisfy { stop in
                   presented.contains { $0.start <= stop.oldStart && $0.end >= stop.oldEnd }
                       || stop.oldStart == stop.oldEnd
               })
        report("no fold overlaps a presented range",
               render.collapses.allSatisfy { fold in
                   presented.allSatisfy { fold.oldEnd <= $0.start || fold.oldStart >= $0.end }
               })

        let raw = buildRenderModel(model: trivialModel(oldBytes: result.model.oldBytes,
                                                       newBytes: result.model.newBytes),
                                   pinOld: "a", pinNew: "b", mode: "raw")
        report("Raw navigates to the same places as Structural", raw.stops == render.stops)
    }
}
