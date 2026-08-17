import Foundation

/// One block of the unified layout: the old bytes printed with `−` and the new bytes printed with
/// `+`, both snapped to whole lines.
public struct UnifiedBlock: Codable, Sendable, Equatable {
    public let oldStart: Int
    public let oldEnd: Int
    public let newStart: Int
    public let newEnd: Int

    public init(oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int) {
        self.oldStart = oldStart
        self.oldEnd = oldEnd
        self.newStart = newStart
        self.newEnd = newEnd
    }
}

/// The blocks the unified layout prints, **with byte-identical lines peeled off them** (DEC-096).
///
/// A unified diff is a line-based form and a change stop is not: a stop can start mid-line, and
/// emitting half a line as a removal would print text the file does not contain. So each stop is
/// snapped out to whole lines and overlapping blocks are merged — that much the renderer already
/// did, and it is ported here unchanged, including the empty-range branch that makes `7` → `77`
/// render as a changed line rather than an added one with nothing to compare against.
///
/// What is new is the peel. Snapping outward pulls in whole lines that a stop only grazed, and a
/// grazed line is printed **twice** — once with `−` and once with `+` — although both copies are the
/// same bytes. That is what the owner reported: `}: ImageTextProps) {` and `  return (` appearing on
/// both sides of a block whose actual change was the twelve lines between them.
///
/// A leading or trailing line pair comes off the block when **both** hold:
///
/// - the old line's bytes equal the new line's bytes, and
/// - no stop **covers any byte of** either line, terminator included. A stop that is empty on a side
///   is a point there, takes no bytes, and so blocks nothing — which is the case that matters, since
///   a pure insertion is exactly that.
///
/// **The second condition is what keeps this honest.** `<Container>` becoming
/// `<Container className={…}>` is a line that must appear on both sides, because it genuinely
/// differs; a rule that peeled on byte-equality alone would be right about the first two lines and
/// wrong about that one. Byte-equality alone is not enough, and neither is the mark alone.
///
/// The first draft asked whether a stop touched the line's *content*, excluding the terminator —
/// `changedLines`' convention, and the wrong question here. What a peel must preserve is not which
/// line a stop claims but which bytes it covers; the property below found it on `moved-function`,
/// where a stop covering only a newline fell out of every block.
///
/// This lives in the engine rather than in `main.js` for the reason M7-A gave about stops, folds and
/// changed lines: a fact about the model belongs to the model, and one the renderer works out for
/// itself cannot be checked without a webview. `unifiedBlocks` was the one part of that layout
/// deciding *what is shown* that had never been checkable.
public func unifiedBlocks(_ model: DiffModel, stops: [ChangeStop]) -> [UnifiedBlock] {
    let old = model.oldBytes
    let new = model.newBytes
    guard !stops.isEmpty else { return [] }

    func lineStart(_ bytes: [UInt8], _ index: Int) -> Int {
        var at = min(index, bytes.count)
        while at > 0, bytes[at - 1] != 0x0A { at -= 1 }
        return at
    }
    func lineEnd(_ bytes: [UInt8], _ index: Int) -> Int {
        var at = min(index, bytes.count)
        while at < bytes.count, bytes[at] != 0x0A { at += 1 }
        return at < bytes.count ? at + 1 : bytes.count
    }
    // An empty range on one side is an insertion seen from that side. At a line boundary it takes
    // nothing from this side and the line count simply grows; **inside** a line it changes that
    // line, and the line has to appear as removed even though no byte of it was deleted.
    func snap(_ bytes: [UInt8], _ start: Int, _ end: Int) -> (start: Int, end: Int) {
        if end > start { return (lineStart(bytes, start), lineEnd(bytes, end - 1)) }
        let at = lineStart(bytes, start)
        return at == start ? (start, start) : (at, lineEnd(bytes, start))
    }

    var blocks: [UnifiedBlock] = []
    for stop in stops.sorted(by: { $0.oldStart == $1.oldStart ? $0.newStart < $1.newStart
                                                              : $0.oldStart < $1.oldStart }) {
        let oldRange = snap(old, stop.oldStart, stop.oldEnd)
        let newRange = snap(new, stop.newStart, stop.newEnd)
        if let last = blocks.last, oldRange.start <= last.oldEnd, newRange.start <= last.newEnd {
            blocks[blocks.count - 1] = UnifiedBlock(
                oldStart: last.oldStart, oldEnd: max(last.oldEnd, oldRange.end),
                newStart: last.newStart, newEnd: max(last.newEnd, newRange.end))
        } else {
            blocks.append(UnifiedBlock(oldStart: oldRange.start, oldEnd: oldRange.end,
                                       newStart: newRange.start, newEnd: newRange.end))
        }
    }

    // A stop touches a line when its range overlaps any byte of it, **terminator included**. A stop
    // with an empty range on a side is a point there, and a point takes no bytes, so it touches
    // nothing.
    //
    // The terminator has to count. The first draft excluded it, on the reasoning that a segment
    // ending exactly on a newline does not claim the line after it — `changedLines`' own convention,
    // and true there. Here it is the wrong question: what a peel must preserve is not which line a
    // stop *claims* but which bytes it *covers*, and a stop covering a newline and nothing else is
    // still a stop. The property check found it on `moved-function`, where peeling dropped a stop
    // out of every block.
    func touched(_ stops: [ChangeStop], _ from: (ChangeStop) -> Int, _ to: (ChangeStop) -> Int,
                 _ start: Int, _ end: Int) -> Bool {
        stops.contains { to($0) > from($0) && from($0) < end && to($0) > start }
    }

    return blocks.compactMap { block in
        var oldStart = block.oldStart, oldEnd = block.oldEnd
        var newStart = block.newStart, newEnd = block.newEnd

        func peelable(oldFrom: Int, oldTo: Int, newFrom: Int, newTo: Int) -> Bool {
            guard oldTo > oldFrom, newTo > newFrom, oldTo - oldFrom == newTo - newFrom,
                  Array(old[oldFrom..<oldTo]) == Array(new[newFrom..<newTo])
            else { return false }
            return !touched(stops, { $0.oldStart }, { $0.oldEnd }, oldFrom, oldTo)
                && !touched(stops, { $0.newStart }, { $0.newEnd }, newFrom, newTo)
        }

        while oldStart < oldEnd, newStart < newEnd {
            let oldTo = lineEnd(old, oldStart)
            let newTo = lineEnd(new, newStart)
            guard oldTo <= oldEnd, newTo <= newEnd,
                  peelable(oldFrom: oldStart, oldTo: oldTo, newFrom: newStart, newTo: newTo)
            else { break }
            oldStart = oldTo
            newStart = newTo
        }
        while oldEnd > oldStart, newEnd > newStart {
            let oldFrom = lineStart(old, oldEnd - 1)
            let newFrom = lineStart(new, newEnd - 1)
            guard oldFrom >= oldStart, newFrom >= newStart,
                  peelable(oldFrom: oldFrom, oldTo: oldEnd, newFrom: newFrom, newTo: newEnd)
            else { break }
            oldEnd = oldFrom
            newEnd = newFrom
        }
        // A block that peels to nothing was context all along. It should be unreachable — every
        // stop touches something — and dropping it is the answer rather than printing an empty hunk.
        guard oldEnd > oldStart || newEnd > newStart else { return nil }
        return UnifiedBlock(oldStart: oldStart, oldEnd: oldEnd, newStart: newStart, newEnd: newEnd)
    }
}
