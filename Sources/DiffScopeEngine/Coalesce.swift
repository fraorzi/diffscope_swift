import Foundation

/// Merges adjacent segments that make the same claim, so one change is drawn as one mark.
///
/// The renderer draws one decoration per segment, so a run split into four is four marks with four
/// edges — and the reader reads four edits. Nothing upstream had a reason to keep them apart:
/// `reconcile` emits one segment per overlap of the canonical mask with an *input* segment, so the
/// **other** side's structure decides where this side is cut, and `snapPresentation`'s widened
/// flanks arrive with a different confidence again. Measured over the owner's eleven files: 443
/// presented segments where 108 carry the same information.
///
/// **This changes nothing about what is presented.** Merged segments are adjacent and share a label,
/// so the presented byte set, the partition's coverage and its total length are all identical —
/// INV-1 through INV-5 are untouched by construction. What changes is how many marks say it.
///
/// Three things refuse to merge, because merging them would move a claim off the bytes it was made
/// about: `disclosure` (this exact run differs invisibly), `link` (this exact run is one side of a
/// move), and **crossing `confidenceFloor`** — the floor is the line the interface actually reads, so
/// merging across it would either lend confidence to bytes that had none or spread doubt onto bytes
/// that were attributed cleanly. A below-floor run keeps its own edges for the same reason a
/// disclosed one does.
///
/// The two that do merge resolve in the direction that shows the reader more:
///
/// - **`classification` disagrees → the run is unclassified.** Classification is what lets a run be
///   quietened as formatting; a run holding two different claims has not earned that, and
///   unclassified is drawn at full weight.
/// - **`confidence` differs on the same side of the floor → the lower one wins.** No part of a run is
///   better attributed than its worst-attributed part.
public func coalesceAdjacent(_ partition: Partition) -> Partition {
    var out: [Segment] = []
    out.reserveCapacity(partition.segments.count)
    for segment in partition.segments {
        guard let last = out.last, last.end == segment.start, last.label == segment.label,
              last.disclosure == segment.disclosure, last.link == segment.link,
              ((last.confidence ?? 1) < confidenceFloor) == ((segment.confidence ?? 1) < confidenceFloor)
        else {
            out.append(segment)
            continue
        }
        let confidence: Double?
        if last.confidence == nil, segment.confidence == nil {
            confidence = nil
        } else {
            confidence = min(last.confidence ?? 1, segment.confidence ?? 1)
        }
        out[out.count - 1] = Segment(
            start: last.start,
            end: segment.end,
            label: last.label,
            classification: last.classification == segment.classification ? last.classification : nil,
            disclosure: last.disclosure,
            confidence: confidence,
            link: last.link
        )
    }
    return Partition(totalLength: partition.totalLength, segments: out)
}
