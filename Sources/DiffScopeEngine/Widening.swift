import Foundation

/// Rewrites a partition so that every byte of `snapped` is presented, keeping what the segments
/// underneath already claimed.
///
/// Shared by the two widening passes rather than written twice: `snapPresentation` widens onto
/// syntax boundaries and `snapToWordBoundaries` onto the ends of a word, and both then face the
/// identical question of what the widened bytes should say. The answer below is the load-bearing
/// part — an inherited classification, and only where the run agrees on one.
public func widenPresented(_ partition: Partition, to snapped: [(start: Int, end: Int)]) -> Partition {
    // A widened flank is unchanged content, so it cannot make a run behave differently. It may
    // therefore carry the run's classification — but only where every change inside that run
    // agrees on one. A run holding an unclassified change stays unclassified.
    func agreed(_ range: (start: Int, end: Int), _ field: (Segment) -> String?) -> String? {
        var found: String??
        for segment in partition.segments
        where segment.isPresented && segment.start < range.end && segment.end > range.start {
            if found == nil { found = field(segment) }
            else if found! != field(segment) { return nil }
        }
        return found ?? nil
    }
    /// Classification folds rather than agrees (DEC-120). Two changes inside one run that disagree
    /// about *which* formatting they are still agree that they are formatting, and the widened
    /// flank may say so. `disclosure` keeps the strict rule above: it is a claim about the exact
    /// bytes that render alike, and a run holding two different ones holds neither.
    func folded(_ range: (start: Int, end: Int)) -> String? {
        var found: String??
        for segment in partition.segments
        where segment.isPresented && segment.start < range.end && segment.end > range.start {
            found = found == nil ? segment.classification
                                 : mergedClassification(found!, segment.classification)
        }
        return found ?? nil
    }
    let inherited = snapped.map { folded($0) }
    let disclosed = snapped.map { agreed($0, \.disclosure) }
    // **The widened bytes keep the run's label, and `.changed` is not a safe default.** On the
    // fallback path the run is `.fallback` — INV-4's promise that every presented range in a file
    // nothing was parsed of is marked as produced without structural analysis — and a widened flank
    // labelled `.changed` breaks that promise *and* stops `coalesceAcrossWords` merging the two
    // halves of the word it just finished, because the two halves no longer agree on what they are.
    let labels: [SegmentLabel] = snapped.map { range in
        var found: SegmentLabel?
        for segment in partition.segments
        where segment.isPresented && segment.start < range.end && segment.end > range.start {
            if found == nil { found = segment.label }
            else if found != segment.label { return .changed }
        }
        // **A move's flank is not part of the move.** DEC-038 requires the two sides of a move to be
        // byte-identical, and the bytes this pass adds were not part of that comparison — so a
        // widened `.moved` run becomes `.changed`, which claims less. `.fallback` is the case this
        // was written for and it inherits, because it claims less than `.changed` already does.
        return found == .moved ? .changed : (found ?? .changed)
    }

    var out: [Segment] = []
    func append(_ segment: Segment) {
        if let last = out.last, last.end == segment.start, last.label == segment.label,
           last.classification == segment.classification, last.disclosure == segment.disclosure,
           last.confidence == segment.confidence, last.link == segment.link {
            out[out.count - 1] = Segment(start: last.start, end: segment.end, label: last.label,
                                         classification: last.classification,
                                         disclosure: last.disclosure,
                                         confidence: last.confidence,
                                         link: last.link)
        } else {
            out.append(segment)
        }
    }

    for segment in partition.segments {
        guard segment.label == .unchanged else { append(segment); continue }
        var cursor = segment.start
        for (index, range) in snapped.enumerated() {
            if range.end <= cursor { continue }
            if range.start >= segment.end { break }
            let overlapStart = max(range.start, cursor)
            let overlapEnd = min(range.end, segment.end)
            guard overlapEnd > overlapStart else { continue }
            if overlapStart > cursor {
                append(Segment(start: cursor, end: overlapStart, label: .unchanged,
                               classification: segment.classification,
                               confidence: segment.confidence))
            }
            append(Segment(start: overlapStart, end: overlapEnd, label: labels[index],
                           classification: inherited[index], disclosure: disclosed[index],
                           confidence: segment.confidence))
            cursor = overlapEnd
        }
        if cursor < segment.end {
            append(Segment(start: cursor, end: segment.end, label: .unchanged,
                           classification: segment.classification,
                           confidence: segment.confidence))
        }
    }
    return Partition(totalLength: partition.totalLength, segments: out)
}
