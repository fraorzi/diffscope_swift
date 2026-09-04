import Foundation

/// One block of the unified layout: the old bytes printed with `−` and the new bytes printed with
/// `+`, both snapped to whole lines.
public struct ByteRange: Codable, Sendable, Equatable {
    public let start: Int
    public let end: Int
    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct UnifiedBlock: Codable, Sendable, Equatable {
    public let oldStart: Int
    public let oldEnd: Int
    public let newStart: Int
    public let newEnd: Int
    /// The old lines this block need not print, because every token on them is on the new side, in
    /// order (DEC-102, made line-by-line by DEC-108).
    ///
    /// A *fact about the block*, not an instruction: what the layout does with it is the layout's,
    /// and what makes it checkable is that it is decided here.
    public let withheldOld: [ByteRange]

    public init(oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int,
                withheldOld: [ByteRange] = []) {
        self.oldStart = oldStart
        self.oldEnd = oldEnd
        self.newStart = newStart
        self.newEnd = newEnd
        self.withheldOld = withheldOld
    }

    /// True when the whole old half is withheld — the case DEC-102 shipped with, and still the
    /// common one: a rewrap that removed nothing.
    public var reflowed: Bool {
        guard let first = withheldOld.first, withheldOld.count == 1 else { return false }
        return first.start <= oldStart && first.end >= oldEnd && oldEnd > oldStart
    }

    private enum CodingKeys: String, CodingKey { case oldStart, oldEnd, newStart, newEnd, withheldOld }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        oldStart = try container.decode(Int.self, forKey: .oldStart)
        oldEnd = try container.decode(Int.self, forKey: .oldEnd)
        newStart = try container.decode(Int.self, forKey: .newStart)
        newEnd = try container.decode(Int.self, forKey: .newEnd)
        withheldOld = try container.decodeIfPresent([ByteRange].self, forKey: .withheldOld) ?? []
    }
}

/// The old lines a block need not print, **one line at a time** (DEC-108).
///
/// DEC-102 asked the question of the whole half: if every token of the old side is on the new side,
/// in order, then the old side says nothing the new side does not and the layout may withhold it. It
/// is the right question and it was asked at the wrong scale. The owner's file has a `<Heading>` that
/// was rewrapped, given two new class rules, wrapped in a fragment — and lost `as string` from one
/// attribute. One removed token on one line, and the whole eight-line element is printed twice.
///
/// So the question is asked per line, against the new side read in order:
///
/// - walk the new side's tokens with a cursor;
/// - for each old line in turn, try to match its tokens from the cursor onwards;
/// - if they all match, the line is withheld and the cursor stays where the match left it;
/// - if any token is missing, the line is **kept** and the cursor is put back — because that line is
///   the one carrying the removal, and the reader is reading this pane to find it.
///
/// The order is what keeps it honest. A line is only withheld when its tokens appear **after**
/// everything the previous withheld line consumed, so a block that shuffles its lines withholds
/// nothing: the tokens are all present, and not in that order.
///
/// **Only whole lines**, so what remains on screen is still a diff of lines, and the withheld ranges
/// are merged where they touch so the header can count them.
/// How far past a block's new half the withholding walk may look, in whole lines of context
/// (DEC-119). Zero reproduces the behaviour DEC-108 shipped, which is the negative control.
public let reflowLookaheadLines = 1

/// The new-side span the withholding walk is allowed to read: the block's new half, plus at most
/// `lookaheadLines` whole lines of **context** after it (DEC-119).
///
/// Exposed rather than inlined so the property checks ask this function instead of restating the
/// window. A check that restates a rule stops being a check the moment the rule moves; what keeps
/// this one honest is that the bound is asserted separately — the walk may not cross a line any stop
/// touches, and it may not travel further than the constant allows.
public func withheldWindowEnd(new: [UInt8], block: UnifiedBlock, stops: [ChangeStop],
                              lookaheadLines: Int = reflowLookaheadLines) -> Int {
    var windowEnd = block.newEnd
    var remaining = max(0, lookaheadLines)
    while remaining > 0, windowEnd < new.count {
        var lineEnd = windowEnd
        while lineEnd < new.count, new[lineEnd] != 0x0A { lineEnd += 1 }
        if lineEnd < new.count { lineEnd += 1 }
        guard lineEnd > windowEnd else { break }
        let touched = stops.contains {
            $0.newEnd > $0.newStart && $0.newStart < lineEnd && $0.newEnd > windowEnd
        }
        if touched { break }
        windowEnd = lineEnd
        remaining -= 1
    }
    return windowEnd
}

public func withheldOldRanges(old: [UInt8], new: [UInt8], block: UnifiedBlock,
                              stops: [ChangeStop] = [],
                              lookaheadLines: Int = reflowLookaheadLines) -> [ByteRange] {
    guard block.oldEnd > block.oldStart, block.newEnd > block.newStart else { return [] }

    // **The window the question is asked over, which is not the block** (DEC-119).
    //
    // A block's new half ends at the last line a hunk touched. Prettier ends an exploded element
    // with its closing token on a line of its own, and that line is **unchanged** — so it is outside
    // every hunk, outside the block, and invisible to the walk below. The old line still contains
    // `/` and `>`, the walk runs out of tape on them, the line is kept, and the element is printed
    // twice. On the old side the very same bytes are *inside* the block, because the block was
    // snapped to whole lines independently on each side; the asymmetry is the whole defect.
    //
    // So the walk may look past `block.newEnd`, by whole lines, and **only into context**. A line a
    // stop touches belongs to the next block's change, and withholding an old line on the strength
    // of new content would hide a removal — which is the one thing this pass may never do.
    let windowEnd = withheldWindowEnd(new: new, block: block, stops: stops,
                                      lookaheadLines: lookaheadLines)

    guard block.oldEnd - block.oldStart <= reflowTokenBudget,
          windowEnd - block.newStart <= reflowTokenBudget else { return [] }

    let newTokens = layoutTokens(new[block.newStart..<windowEnd])
    guard !newTokens.isEmpty else { return [] }

    var ranges: [ByteRange] = []
    var cursor = 0
    var lineStart = block.oldStart
    while lineStart < block.oldEnd {
        var lineEnd = lineStart
        while lineEnd < block.oldEnd, old[lineEnd] != 0x0A { lineEnd += 1 }
        if lineEnd < block.oldEnd { lineEnd += 1 }

        let lineTokens = layoutTokens(old[lineStart..<lineEnd])
        var walker = cursor
        var matched = true
        for token in lineTokens {
            var found = false
            while walker < newTokens.count {
                let candidate = newTokens[walker]
                walker += 1
                if candidate == token { found = true; break }
            }
            if !found { matched = false; break }
        }
        // A line with no tokens at all — blank, or whitespace — is withheld with its neighbours
        // rather than breaking a run in half, and consumes nothing.
        if matched {
            cursor = lineTokens.isEmpty ? cursor : walker
            if let last = ranges.last, last.end == lineStart {
                ranges[ranges.count - 1] = ByteRange(start: last.start, end: lineEnd)
            } else {
                ranges.append(ByteRange(start: lineStart, end: lineEnd))
            }
        }
        lineStart = lineEnd
    }
    return ranges
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
        let block = UnifiedBlock(oldStart: oldStart, oldEnd: oldEnd,
                                 newStart: newStart, newEnd: newEnd)
        return UnifiedBlock(oldStart: oldStart, oldEnd: oldEnd, newStart: newStart, newEnd: newEnd,
                            withheldOld: withheldOldRanges(old: old, new: new, block: block,
                                                          stops: stops))
    }
}
