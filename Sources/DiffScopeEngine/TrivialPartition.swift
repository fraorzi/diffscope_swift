import Foundation

public func wholeFilePartition(length: Int, label: SegmentLabel) -> Partition {
    guard length > 0 else {
        return Partition(totalLength: 0, segments: [])
    }
    return Partition(
        totalLength: length,
        segments: [Segment(start: 0, end: length, label: label, confidence: 0)]
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

public func fallbackPartitions(
    oldBytes: [UInt8],
    newBytes: [UInt8],
    workBudget: Int = fallbackDiffWorkBudget,
    absorption: AbsorptionSettings = AbsorptionSettings()
) -> (old: Partition, new: Partition)? {
    guard case let .exact(hunks) = canonicalDiff(old: oldBytes, new: newBytes,
                                                 workBudget: workBudget)
    else { return nil }

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
                                    confidence: 0))
            cursor = range.end
        }
        if cursor < bytes.count {
            segments.append(Segment(start: cursor, end: bytes.count, label: .unchanged, confidence: 1))
        }
        let partition = Partition(totalLength: bytes.count, segments: segments)
        return coalesceAdjacent(snapToGraphemeBoundaries(
            absorbIslands(partition, bytes: bytes, settings: absorption), bytes: bytes))
    }

    return (side(oldBytes, hunks.map { (start: $0.oldStart, end: $0.oldEnd) }),
            side(newBytes, hunks.map { (start: $0.newStart, end: $0.newEnd) }))
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
