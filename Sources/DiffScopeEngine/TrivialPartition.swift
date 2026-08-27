import Foundation

public func wholeFilePartition(length: Int, label: SegmentLabel) -> Partition {
    guard length > 0 else {
        return Partition(totalLength: 0, segments: [])
    }
    // An unchanged whole file is the one thing here that *is* confirmed — the two byte arrays were
    // compared and found equal — and until DEC-116 it was reported at confidence 0 with everything
    // else this function makes. Nothing drew it, because an unchanged segment carries no mark; it
    // was still a segment saying *this alignment could not be confirmed* about the strongest
    // confirmation the product has.
    return Partition(
        totalLength: length,
        segments: [Segment(start: 0, end: length, label: label,
                           confidence: label == .unchanged ? 1 : 0)]
    )
}

/// The two partitions for a file nothing could be parsed of, built from the canonical diff rather
/// than from the file's length (DEC-095).
///
/// Returns `nil` when the diff cannot be computed at all — a work budget exceeded on a minified
/// bundle, and nothing else. There the whole file genuinely is the answer, because nothing smaller
/// is known.
///
/// **F7 is a statement about structure, and comparison never depended on parsing (DEC-021).**
/// Painting every line of a `.css` file because there is no CSS grammar was never required by any
/// decision; it was the shape of `wholeFilePartition`, inherited from a time when the fallback path
/// had nothing else to offer. It has the byte diff, which is the same byte diff the structural path
/// validates against.
///
/// The segments are labelled `.fallback`, so INV-4 still holds — every presented range is marked as
/// produced without structural analysis, and `fallbackNotice` still says the file is shown as plain
/// text. What changes is that the unchanged bytes are labelled `.unchanged` instead of being painted
/// with the rest.
///
/// `snapPresentation` is skipped, because it needs a tree. DEC-093's shift does not, so the
/// alignment arrives already sitting on line and token boundaries; absorption, grapheme snapping and
/// coalescing all run, because none of them needs a parse either.
/// The work the fallback path may spend on a byte diff before giving the whole file as the answer.
///
/// A tenth of `defaultCanonicalDiffWorkBudget`, and the reason is the path it is on: a file arrives
/// here *because* something about it was too expensive or too unknown to analyse, so spending the
/// full budget re-deriving that is the wrong trade. Measured in M11-E: the dense-JSX gate case goes
/// from 0.98 s back to the parse baseline, and every file small enough to be read on screen still
/// gets its localised diff.
public let fallbackDiffWorkBudget = defaultCanonicalDiffWorkBudget / 10

/// A change whose range came from the canonical byte diff, on the path with no grammar. The same
/// number an ordinary structural change gets, because it is the same claim: *these bytes differ, and
/// here is where* — reached by the alignment the structural path is checked against.
public let exactFallbackConfidence = 0.8
/// A change whose range came from DEC-105's line anchors. Below the floor on purpose: the marked
/// boundaries are wider than minimal and were never compared byte for byte.
public let lineAnchoredFallbackConfidence = 0.6

public func fallbackPartitions(
    oldBytes: [UInt8],
    newBytes: [UInt8],
    workBudget: Int = fallbackDiffWorkBudget,
    absorption: AbsorptionSettings = AbsorptionSettings(),
    lineFallback: Bool = true
) -> (old: Partition, new: Partition)? {
    var oldRanges: [(start: Int, end: Int)]
    var newRanges: [(start: Int, end: Int)]
    // **How the ranges were obtained, in the vocabulary the rest of the engine already uses**
    // (DEC-116). `confidence` says how far an *alignment* can be trusted, and it was reading 0 —
    // the value that means no analysis at all — for every mark this function makes, on both of the
    // two very different routes below. On a corpus of stylesheets, JSON and Markdown that is 99.3%
    // of marks and 100% of presented bytes drawn uncertain, in a whole family of files, which is
    // a texture that says nothing.
    //
    // The two routes do not deserve the same number:
    //
    // - `.exact` is the canonical byte diff — the same alignment INV-2 states the structural path
    //   *against*. A change taken from it is exactly as well aligned as a change taken from a
    //   structural gap pair, and that is `0.8`: at the floor, trusted, and still a change rather
    //   than a confirmed identity.
    // - the line-anchored fallback (DEC-105) is a heuristic. Its guarantee is that what it leaves
    //   unmarked is byte-identical; the boundaries of what it *does* mark are wider than minimal
    //   and were never compared byte for byte. `0.6` is the value already meaning *the byte diff
    //   and the alignment disagree*, which is the same doubt.
    //
    // What says *this file was not parsed* is the `.fallback` label and the notice bar, and it has
    // said so all along. Confidence restating it was a second copy of one axis, drowning out the
    // other — two indicators saying the same thing are one indicator and a decoration.
    let rangeConfidence: Double
    switch canonicalDiff(old: oldBytes, new: newBytes, workBudget: workBudget) {
    case let .exact(hunks):
        oldRanges = hunks.map { (start: $0.oldStart, end: $0.oldEnd) }
        newRanges = hunks.map { (start: $0.newStart, end: $0.newEnd) }
        rangeConfidence = exactFallbackConfidence
    case .budgetExceeded:
        // **Lines, before the whole file** (DEC-105). The byte diff refusing to answer is not the
        // same thing as there being no answer: a 40 KB translation file with a hundred edited
        // strings exhausts this path's budget and used to be painted from the first line to the
        // last, which is 1098 changed lines where git reports 94.
        guard lineFallback, let hunks = lineAnchoredHunks(old: oldBytes, new: newBytes)
        else { return nil }
        oldRanges = hunks.map { (start: $0.oldStart, end: $0.oldEnd) }
        newRanges = hunks.map { (start: $0.newStart, end: $0.newEnd) }
        rangeConfidence = lineAnchoredFallbackConfidence
    }

    func side(_ bytes: [UInt8], _ ranges: [(start: Int, end: Int)]) -> Partition {
        guard !bytes.isEmpty else { return Partition(totalLength: 0, segments: []) }
        var segments: [Segment] = []
        var cursor = 0
        for range in ranges where range.end > range.start {
            if range.start > cursor {
                segments.append(Segment(start: cursor, end: range.start, label: .unchanged,
                                        confidence: 1))
            }
            segments.append(Segment(start: range.start, end: range.end, label: .fallback,
                                    confidence: rangeConfidence))
            cursor = range.end
        }
        if cursor < bytes.count {
            segments.append(Segment(start: cursor, end: bytes.count, label: .unchanged, confidence: 1))
        }
        let partition = Partition(totalLength: bytes.count, segments: segments)
        // **The word snap runs here too** (DEC-100 was structural-path only). A file with no grammar
        // is where a reader most needs a whole word: the corpus of stylesheets and JSON reports 1452
        // marks cutting one, `2⟦00⟧ms` and `--animated-background-active-⟦hover⟧` among them.
        //
        // The identifier rule, widened to take a hyphen (DEC-107). Treating the whole file as a
        // string literal was tried first and is too much: with no whitespace to stop it, `.a{}`
        // becomes one word and a one-character change paints the line. A hyphen is the only
        // punctuation that belongs inside a name here — `--custom-property`, `200ms`, `bg-red-500` —
        // and it is a subtraction only in a language this path has already failed to parse.
        // And the word merge with it, for the reason it exists: widening gives the finished half of
        // a word the *unchanged* side's confidence, so the word ends up as two marks that differ
        // only in how sure they are. Without this the snap trades 1452 cut words for 6809 split
        // ones, which is not a trade.
        let widened = snapToGraphemeBoundaries(
            absorbIslands(snapToWordBoundaries(partition, bytes: bytes, stringRegions: [],
                                               hyphenIsWord: true),
                          bytes: bytes, settings: absorption),
            bytes: bytes)
        return coalesceAdjacent(coalesceAcrossWords(widened, bytes: bytes, stringRegions: [],
                                                    hyphenIsWord: true))
    }

    return (side(oldBytes, oldRanges), side(newBytes, newRanges))
}

public func trivialModel(
    oldBytes: [UInt8],
    newBytes: [UInt8],
    absorption: AbsorptionSettings = AbsorptionSettings()
) -> DiffModel {
    if oldBytes == newBytes {
        return DiffModel(
            oldBytes: oldBytes, newBytes: newBytes,
            oldPartition: wholeFilePartition(length: oldBytes.count, label: .unchanged),
            newPartition: wholeFilePartition(length: newBytes.count, label: .unchanged)
        )
    }
    // Raw mode takes the same route as the F7 path, deliberately and in one function. DEC-013 makes
    // Raw a *path* rather than a worse answer, and two implementations of "what a file looks like
    // when nothing parsed" would drift.
    if let partitions = fallbackPartitions(oldBytes: oldBytes, newBytes: newBytes,
                                           absorption: absorption) {
        return DiffModel(oldBytes: oldBytes, newBytes: newBytes,
                         oldPartition: partitions.old, newPartition: partitions.new)
    }
    return DiffModel(
        oldBytes: oldBytes, newBytes: newBytes,
        oldPartition: wholeFilePartition(length: oldBytes.count, label: .fallback),
        newPartition: wholeFilePartition(length: newBytes.count, label: .fallback)
    )
}
