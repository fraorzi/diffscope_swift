import Foundation

/// Two byte strings that differ only in how much whitespace they contain, and where.
///
/// Not `trimmingCharacters` and not a normaliser: whitespace is *dropped* rather than collapsed,
/// because that is the question a reflow asks. `a  b` and `a\n      b` are the same code laid out
/// twice; `ab` is a third thing, and dropping rather than collapsing is what keeps them apart.
public func equalIgnoringWhitespace(_ old: ArraySlice<UInt8>, _ new: ArraySlice<UInt8>) -> Bool {
    var left = old.makeIterator()
    var right = new.makeIterator()
    var a = left.next()
    var b = right.next()
    while true {
        while let byte = a, isLayoutByte(byte) { a = left.next() }
        while let byte = b, isLayoutByte(byte) { b = right.next() }
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?) where x == y:
            a = left.next()
            b = right.next()
        default: return false
        }
    }
}

public func isLayoutByte(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
}

/// Words, numbers and single punctuation bytes, with whitespace dropped.
///
/// Crude on purpose. It has no grammar to be wrong about, it runs on a slice of a hunk rather than
/// on a file, and the only property asked of it is the one a reflow preserves: *the same tokens in
/// the same order*.
public func layoutTokens(_ bytes: ArraySlice<UInt8>) -> [[UInt8]] {
    func isWord(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte == 0x24 || byte >= 0x80
    }
    var out: [[UInt8]] = []
    var index = bytes.startIndex
    while index < bytes.endIndex {
        let byte = bytes[index]
        if isLayoutByte(byte) {
            index += 1
        } else if isWord(byte) {
            var end = index
            while end < bytes.endIndex, isWord(bytes[end]) { end += 1 }
            out.append(Array(bytes[index..<end]))
            index = end
        } else {
            out.append([byte])
            index += 1
        }
    }
    return out
}

/// True when the whole of `needle` appears inside `haystack`, in order.
public func isTokenSubsequence(_ needle: [[UInt8]], of haystack: [[UInt8]]) -> Bool {
    guard needle.count <= haystack.count else { return false }
    var cursor = 0
    for token in haystack where cursor < needle.count {
        if token == needle[cursor] { cursor += 1 }
    }
    return cursor == needle.count
}

/// The largest hunk this pass will tokenise. Beyond it a hunk is a rewritten file rather than a
/// rewrapped element, and the answer is not worth an allocation per token.
public let reflowTokenBudget = 64 * 1024

/// How one canonical hunk relates to the reflow question (DEC-101).
public enum HunkLayout: Sendable, Equatable {
    /// Both sides carry the same bytes in a different layout: the whole hunk is formatting.
    case layoutOnly
    /// One side's tokens are a subsequence of the other's: content was inserted or removed and the
    /// rest was re-laid-out. Nothing was reordered or replaced.
    case reflowed
    /// The same tokens in a different order. Called out rather than folded into `substantive`
    /// because it is the one shape that must never be quietened in any part: DEC-048 lets the
    /// interface collapse a `formatting-only` run, and a reorder with one quiet gap in it is a
    /// reorder a reader can miss.
    case reordered
    /// Anything else — a rename, a rewrite, an edit.
    case substantive
}

/// The regions the layout question is asked about: hunks snapped out to whole lines and merged
/// while they touch.
///
/// **A hunk on its own is too small to answer it, and the suite proved that too.** `prop-reordering`
/// moves four JSX attributes; the byte diff cuts that into hunks of a few tokens each, and inside a
/// hunk of a few tokens one side very often *is* a subsequence of the other — so the reorder passed
/// the test hunk by hunk and its whitespace was classified as layout again. A reorder is only
/// visible at the scale of the thing reordered, which is the region its hunks jointly cover.
public func layoutRegions(hunks: [(oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int)],
                          old: [UInt8], new: [UInt8]) -> [(oldStart: Int, oldEnd: Int,
                                                           newStart: Int, newEnd: Int)] {
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

    var regions: [(oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int)] = []
    for hunk in hunks.sorted(by: { $0.oldStart < $1.oldStart }) {
        let oldRange = (lineStart(old, hunk.oldStart),
                        hunk.oldEnd > hunk.oldStart ? lineEnd(old, hunk.oldEnd - 1)
                                                    : lineEnd(old, hunk.oldStart))
        let newRange = (lineStart(new, hunk.newStart),
                        hunk.newEnd > hunk.newStart ? lineEnd(new, hunk.newEnd - 1)
                                                    : lineEnd(new, hunk.newStart))
        if let last = regions.last, oldRange.0 <= last.oldEnd, newRange.0 <= last.newEnd {
            regions[regions.count - 1] = (last.oldStart, max(last.oldEnd, oldRange.1),
                                          last.newStart, max(last.newEnd, newRange.1))
        } else {
            regions.append((oldRange.0, oldRange.1, newRange.0, newRange.1))
        }
    }
    return regions
}

/// Every token of `needle` appears in `haystack`, counting repeats, in any order.
private func containsAll(_ needle: [[UInt8]], in haystack: [[UInt8]]) -> Bool {
    guard needle.count <= haystack.count else { return false }
    var available: [[UInt8]: Int] = [:]
    for token in haystack { available[token, default: 0] += 1 }
    for token in needle {
        guard let count = available[token], count > 0 else { return false }
        available[token] = count - 1
    }
    return true
}

public func hunkLayout(old: ArraySlice<UInt8>, new: ArraySlice<UInt8>) -> HunkLayout {
    if equalIgnoringWhitespace(old, new) { return .layoutOnly }
    guard old.count <= reflowTokenBudget, new.count <= reflowTokenBudget else { return .substantive }
    let oldTokens = layoutTokens(old)
    let newTokens = layoutTokens(new)
    if isTokenSubsequence(oldTokens, of: newTokens) || isTokenSubsequence(newTokens, of: oldTokens) {
        return .reflowed
    }
    // Content preserved, order not: one side's tokens all appear on the other, but not in order.
    // Equality of multisets is too strict to catch the fixture that this exists for —
    // `prop-reordering` also moves the closing `/>` onto the same line, so the new side carries two
    // tokens the old one does not, and a rule keyed on equal counts let its gap through.
    if containsAll(oldTokens, in: newTokens) || containsAll(newTokens, in: oldTokens) {
        return .reordered
    }
    return .substantive
}

/// One token: its bytes, and where they sit in the file.
public struct LayoutToken: Sendable, Equatable {
    public let text: [UInt8]
    public let start: Int
    public let end: Int
}

public func layoutTokensWithOffsets(_ bytes: [UInt8], from: Int, to: Int) -> [LayoutToken] {
    func isWord(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte == 0x24 || byte >= 0x80
    }
    var out: [LayoutToken] = []
    var index = max(0, from)
    let limit = min(to, bytes.count)
    while index < limit {
        let byte = bytes[index]
        if isLayoutByte(byte) {
            index += 1
        } else if isWord(byte) {
            var end = index
            while end < limit, isWord(bytes[end]) { end += 1 }
            out.append(LayoutToken(text: Array(bytes[index..<end]), start: index, end: end))
            index = end
        } else {
            out.append(LayoutToken(text: [byte], start: index, end: index + 1))
            index += 1
        }
    }
    return out
}

/// The gaps between two tokens that are **neighbours on both sides**: the pair did not change, only
/// the whitespace between them did (DEC-101).
///
/// This is the rule that reaches the change the owner reported. A region rule can only speak when
/// the *whole* region is a rewrap, and a prop added to a rewrapped element usually sits in a region
/// holding other edits as well — so on the corpus the region rules classify 5% of the whitespace
/// marks and leave the rest at full weight. This asks the same question one token pair at a time:
/// `<Image` was followed by `src` before and is followed by `src` now, so whatever happened to the
/// bytes between them is a line break moving.
///
/// **A reorder cannot pass it**, which is the property the whole entry turns on. `prop-reordering`
/// puts `required` between `<Field` and `name`, so the pair `(Field, name)` is not adjacent on the
/// new side and its gap is refused — the same fixture that refused two earlier drafts.
///
/// Repeated pairs are matched by content rather than by position, so a file with two identical
/// adjacent token pairs can have a gap classified from the wrong one of them. That is the one
/// imprecision here, and it is bounded by what the claim costs: `formatting-only` groups a mark, it
/// never removes it, and the mark still covers exactly the bytes that changed.
public func preservedGapRanges(bytes: [UInt8], from: Int, to: Int,
                               otherAdjacentPairs: Set<[[UInt8]]>) -> [(start: Int, end: Int)] {
    let tokens = layoutTokensWithOffsets(bytes, from: from, to: to)
    guard tokens.count > 1 else { return [] }
    var out: [(start: Int, end: Int)] = []
    for index in 0..<(tokens.count - 1) {
        let left = tokens[index]
        let right = tokens[index + 1]
        guard right.start > left.end,
              otherAdjacentPairs.contains([left.text, right.text]) else { continue }
        out.append((left.end, right.start))
    }
    return out
}

public func adjacentTokenPairs(bytes: [UInt8], from: Int, to: Int) -> Set<[[UInt8]]> {
    let tokens = layoutTokensWithOffsets(bytes, from: from, to: to)
    guard tokens.count > 1 else { return [] }
    var pairs = Set<[[UInt8]]>()
    for index in 0..<(tokens.count - 1) {
        pairs.insert([tokens[index].text, tokens[index + 1].text])
    }
    return pairs
}

/// Says `whitespace` on the marks that a reflow accounts for (DEC-101).
///
/// **Where the existing classifier cannot reach.** `changeClassification` runs on the *gap pair*
/// between two anchors, which is the only place the syntax layer knows what corresponds to what.
/// After `reconcile` cuts those gaps against the canonical mask, a segment no longer knows its
/// counterpart — so a rewrapped block arrives here as a dozen unclassified marks over indentation
/// and line breaks, and the interface draws all of them at full weight. The corpus survey counts
/// 13058 marks made **entirely of whitespace** across 4016 real changes, none of them classified.
///
/// The canonical hunk is the pairing this pass uses instead. A hunk is a correspondence by
/// construction — `D` produced it as one edit with an old side and a new side — so what its two
/// sides have in common is a fact about the file rather than a guess about the reader's intent.
/// Two rules follow from it:
///
/// - **`layoutOnly`**: the sides are equal ignoring whitespace, so *every* mark in the hunk is
///   layout, whatever bytes it covers.
/// - **`reflowed`**: one side's tokens are a subsequence of the other's, so the marks made **only of
///   whitespace** are layout — the rewrap — while the marks over the inserted or removed tokens stay
///   loud, which is the whole point.
///
/// **The second rule replaced a wider one, and the suite is what refused it.** The draft said any
/// mark made only of whitespace is formatting, wherever it sits. That is true of the bytes in
/// isolation and wrong about the change: `prop-reordering` moves four JSX attributes onto one line,
/// the bytes between them are spaces, and four marks of a *reorder* came out `formatting-only` —
/// the one group DEC-048 lets the interface quieten. A second draft guarded on the `reordering`
/// classification and changed nothing, because that fixture produces no classified segment at all:
/// the gap is subdivided by anchors before the classifier ever sees it. **Measure the control before
/// believing the check**, twice in one pass. The token test is the question itself rather than a
/// proxy for it — a reflow preserves the token sequence, a reorder permutes it.
///
/// **Nothing is hidden and nothing is dropped.** The segments keep their bytes, their labels and
/// their confidence; they gain a `classification` that puts them in the `formatting-only` group,
/// which DEC-017 requires to be grouping and never filtering. A segment that already carries a
/// classification keeps it: this pass adds a claim where there was none, and never overrules one
/// made with more information than it has.
public func classifyLayoutMarks(
    _ partition: Partition,
    bytes: [UInt8],
    layoutRanges: [(start: Int, end: Int)],
    reflowRanges: [(start: Int, end: Int)],
    preservedGaps: [(start: Int, end: Int)] = []
) -> Partition {
    guard !layoutRanges.isEmpty || !reflowRanges.isEmpty || !preservedGaps.isEmpty else {
        return partition
    }

    func enclosing(_ ranges: [(start: Int, end: Int)], _ segment: Segment) -> (start: Int, end: Int)? {
        var low = 0
        var high = ranges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if ranges[mid].end <= segment.start { low = mid + 1 }
            else if ranges[mid].start >= segment.end { high = mid - 1 }
            else { return ranges[mid] }
        }
        return nil
    }

    func inLayoutHunk(_ segment: Segment) -> Bool {
        guard let range = enclosing(layoutRanges, segment) else { return false }
        return range.start <= segment.start && range.end >= segment.end
    }

    func allWhitespace(_ segment: Segment) -> Bool {
        guard segment.end <= bytes.count, segment.end > segment.start else { return false }
        return bytes[segment.start..<segment.end].allSatisfy(isLayoutByte)
    }

    return Partition(totalLength: partition.totalLength, segments: partition.segments.map { segment in
        func insidePreservedGap(_ segment: Segment) -> Bool {
            guard let gap = enclosing(preservedGaps, segment) else { return false }
            return gap.start <= segment.start && gap.end >= segment.end
        }
        guard segment.isPresented, segment.classification == nil,
              inLayoutHunk(segment)
                  || (allWhitespace(segment)
                      && (enclosing(reflowRanges, segment) != nil || insidePreservedGap(segment)))
        else { return segment }
        return Segment(start: segment.start, end: segment.end, label: segment.label,
                       classification: ChangeClass.whitespace.rawValue,
                       disclosure: segment.disclosure, confidence: segment.confidence,
                       link: segment.link)
    })
}
