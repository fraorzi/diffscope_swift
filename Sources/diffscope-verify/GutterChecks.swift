import DiffScopeEngine
import Foundation

/// `12-desktop-ux-specification.md` §5.1: change meaning is carried by *"gutter, underline, and
/// background texture"*. Two of the three were built; this covers the third.
///
/// Which lines carry a difference is computed in the engine and carried on the contract, so it is
/// checkable here rather than only visible in a webview — the M8-D lesson applied before the fact
/// rather than after it.
func runGutterChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    func lines(_ old: String, _ new: String) -> (old: [Int], new: [Int]) {
        let model = trivialModel(oldBytes: [UInt8](old.utf8), newBytes: [UInt8](new.utf8))
        let render = buildRenderModel(model: model, pinOld: "a", pinNew: "b")
        guard case let .text(oldSide, newSide) = render.payload else { return ([], []) }
        return (oldSide.changedLines, newSide.changedLines)
    }

    print("\n=== the gutter marks the lines that changed (12-… §5.1) ===")
    do {
        // This check used to assert `[1, 2, 3]` — every line of the file — and argued for it: Raw
        // claims no structure, so the gutter must not imply one. The argument was sound and the
        // premise was not. Raw claims no *structure*; comparison never depended on parsing
        // (DEC-021), so marking the two untouched lines was the shape of `wholeFilePartition`
        // rather than a consequence of claiming nothing. The old value is kept as the control.
        let whole = lines("a\nb\nc\n", "a\nB\nc\n")
        report("a raw model marks the line that changed and not the file holding it",
               whole.new == [2], String(describing: whole.new))
        report("negative control: it is not marking every line and calling it precision",
               whole.new != [1, 2, 3], String(describing: whole.new))

        let unchanged = lines("a\nb\n", "a\nb\n")
        report("an unchanged file marks nothing",
               unchanged.old.isEmpty && unchanged.new.isEmpty, String(describing: unchanged))

        let empty = lines("", "")
        report("an empty file marks nothing", empty.new.isEmpty)
    }

    print("\n=== line attribution, computed on bytes ===")
    do {
        func marked(_ text: String, _ segments: [(Int, Int)]) -> [Int] {
            let bytes = [UInt8](text.utf8)
            var built: [Segment] = []
            var cursor = 0
            for (start, end) in segments {
                if start > cursor { built.append(Segment(start: cursor, end: start, label: .unchanged)) }
                built.append(Segment(start: start, end: end, label: .changed))
                cursor = end
            }
            if cursor < bytes.count { built.append(Segment(start: cursor, end: bytes.count, label: .unchanged)) }
            return changedLines(bytes: bytes, partition: Partition(totalLength: bytes.count, segments: built))
        }

        let text = "one\ntwo\nthree\n"
        report("a change inside one line marks only that line", marked(text, [(4, 7)]) == [2],
               String(describing: marked(text, [(4, 7)])))
        report("a change spanning a newline marks both lines", marked(text, [(2, 5)]) == [1, 2],
               String(describing: marked(text, [(2, 5)])))
        // The off-by-one that would put every mark one line low: a segment ending *on* a newline
        // stops at the line that newline terminates.
        report("a segment ending exactly at a newline does not claim the line after it",
               marked(text, [(0, 4)]) == [1], String(describing: marked(text, [(0, 4)])))
        report("a change on the last line marks the last line", marked(text, [(8, 13)]) == [3],
               String(describing: marked(text, [(8, 13)])))
        report("an empty segment marks nothing", marked(text, [(4, 4)]).isEmpty)

        // Counting on bytes and splitting on 0x0A only means the `\r` belongs to the line it
        // terminates — so a CRLF change lands on the line whose ending changed, not the next one.
        let crlf = "one\r\ntwo\r\n"
        report("a carriage return belongs to the line it terminates",
               marked(crlf, [(3, 4)]) == [1], String(describing: marked(crlf, [(3, 4)])))
    }

    print("\n=== the gutter agrees with the document it is drawn beside ===")
    do {
        let old = [UInt8]("const a = 1;\nconst b = 2;\nconst c = 3;\n".utf8)
        let new = [UInt8]("const a = 1;\nconst b = 22;\nconst c = 3;\n".utf8)
        let model = trivialModel(oldBytes: old, newBytes: new)
        let render = buildRenderModel(model: model, pinOld: "a", pinNew: "b")
        guard case let .text(_, newSide) = render.payload else {
            report("the contract carries a text payload", false); return
        }
        let documentLines = newSide.text.split(separator: "\n", omittingEmptySubsequences: false).count - 1
        report("every marked line exists in the document",
               newSide.changedLines.allSatisfy { $0 >= 1 && $0 <= documentLines },
               "\(newSide.changedLines) against \(documentLines) lines")
        report("marked lines are sorted and unique",
               newSide.changedLines == newSide.changedLines.sorted()
                   && Set(newSide.changedLines).count == newSide.changedLines.count)

        // INV-5 reaches the gutter too: Structural and Expanded are flags over one model, so they
        // cannot disagree about which lines carry a difference.
        let structural = buildRenderModel(model: model, pinOld: "a", pinNew: "b", mode: "structural")
        let expanded = buildRenderModel(model: model, pinOld: "a", pinNew: "b", mode: "expanded")
        guard case let .text(_, s) = structural.payload, case let .text(_, e) = expanded.payload else { return }
        report("Structural and Expanded mark the same lines", s.changedLines == e.changedLines)
    }
}
