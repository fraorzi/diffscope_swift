import DiffScopeEngine
import Foundation

/// The offsets a change is allowed to begin or end on, in preference to wherever the byte
/// diff happened to stop. Named nodes only: anonymous tokens (`{`, `)`, `return`) would make
/// almost every offset a boundary and the snap meaningless.
public struct SyntaxBoundaries: Sendable {
    public let offsets: [Int]

    public init(tree: SyntaxTree) {
        var seen = Set<Int>()
        for node in tree.nodes where node.isNamed && !node.isError && node.end > node.start {
            seen.insert(node.start)
            seen.insert(node.end)
        }
        offsets = seen.sorted()
    }

    public init(offsets: [Int]) {
        self.offsets = offsets.sorted()
    }

    public func contains(_ offset: Int) -> Bool {
        var low = 0
        var high = offsets.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if offsets[mid] == offset { return true }
            if offsets[mid] < offset { low = mid + 1 } else { high = mid - 1 }
        }
        return false
    }

    /// Nearest boundary at or before `offset`, no further away than `budget`.
    public func snapDown(_ offset: Int, budget: Int) -> Int {
        var best: Int?
        var low = 0
        var high = offsets.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if offsets[mid] <= offset { best = offsets[mid]; low = mid + 1 } else { high = mid - 1 }
        }
        guard let candidate = best, offset - candidate <= budget else { return offset }
        return candidate
    }

    /// Nearest boundary at or after `offset`, no further away than `budget`.
    public func snapUp(_ offset: Int, budget: Int) -> Int {
        var best: Int?
        var low = 0
        var high = offsets.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if offsets[mid] >= offset { best = offsets[mid]; high = mid - 1 } else { low = mid + 1 }
        }
        guard let candidate = best, candidate - offset <= budget else { return offset }
        return candidate
    }
}

/// Chosen by measurement, not taste — see `22-experiment-log.md` → M6-B.
public let boundarySnapBudget = 16

/// Widens each changed range onto the nearest syntax boundaries within a byte budget, then
/// merges what now overlaps.
///
/// **Outward only.** Sliding a hunk onto a boundary — git's indent heuristic, and the obvious
/// reading of "tie-breaking among equally-minimal alignments" — moves bytes *out* of the
/// presented set, which INV-2 forbids as recorded (DEC-047). Expansion is monotone, so
/// containment survives by construction: the snapped mask is a superset of the canonical one.
public func snapToBoundaries(
    _ mask: [(start: Int, end: Int)],
    boundaries: SyntaxBoundaries,
    budget: Int,
    bytes: [UInt8] = []
) -> [(start: Int, end: Int)] {
    guard budget > 0, !boundaries.offsets.isEmpty, !mask.isEmpty else { return mask }

    // A boundary already on a line boundary is not widened (DEC-086). This pass exists to rescue a
    // change that *begins mid-structure*; once the canonical alignment lands on whole lines, the
    // same widening spends its budget spilling into the neighbouring line — which is how an
    // inserted member came to put its highlight on the *next* line's indentation. Measured: with
    // the shift in place and this guard absent, the corpus reports **more** wrong lines than before
    // the shift, not fewer.
    func atLineStart(_ offset: Int) -> Bool {
        guard !bytes.isEmpty else { return false }
        return offset == 0 || (offset <= bytes.count && bytes[offset - 1] == 0x0A)
    }

    var widened = mask.map { range -> (start: Int, end: Int) in
        (atLineStart(range.start) ? range.start : boundaries.snapDown(range.start, budget: budget),
         atLineStart(range.end) ? range.end : boundaries.snapUp(range.end, budget: budget))
    }
    widened.sort { $0.start < $1.start }

    var merged: [(start: Int, end: Int)] = []
    for range in widened {
        if let last = merged.last, range.start <= last.end {
            merged[merged.count - 1] = (last.start, max(last.end, range.end))
        } else {
            merged.append(range)
        }
    }
    return merged
}

/// Applies the snap to a finished partition, as a presentation pass.
///
/// Deliberately after labelling rather than before it. Widening the mask that `reconcile`
/// consumes would let the extra bytes be read as evidence of a move, and a `moved` label is a
/// claim about content, not about where a mark begins. Here the only effect is that some bytes
/// which are unchanged are nevertheless shown inside the change — the direction that can
/// mislead a reviewer into reading more, never into reading less.
public func snapPresentation(
    _ partition: Partition,
    boundaries: SyntaxBoundaries,
    budget: Int = boundarySnapBudget,
    bytes: [UInt8] = []
) -> Partition {
    let presented = partition.segments.filter(\.isPresented).map { (start: $0.start, end: $0.end) }
    guard !presented.isEmpty else { return partition }
    let snapped = snapToBoundaries(presented, boundaries: boundaries, budget: budget, bytes: bytes)

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
    let inherited = snapped.map { agreed($0, \.classification) }
    let disclosed = snapped.map { agreed($0, \.disclosure) }

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
            append(Segment(start: overlapStart, end: overlapEnd, label: .changed,
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

/// The byte ranges tree-sitter could not parse (F1 of `13-error-and-fallback-model.md` §2).
///
/// F1 is *"parse error in part of a file: structural for clean regions, raw for the rest"*. Until
/// now nothing produced it: `anchors` skips `ERROR` nodes, so their bytes fell into the ordinary
/// gap comparison and the file was presented as a completely understood structural result. The
/// corpus shows why that matters — `invalid-tsx` and `truncated-file` both produce a confident
/// twelve- and twenty-anchor result with no hint that a region was never parsed at all.
///
/// Top-most errors only. A malformed construct produces a nest of `ERROR` nodes, and reporting each
/// one would turn a single broken tag into a dozen claims.
public func parseErrorRegions(tree: SyntaxTree) -> [(start: Int, end: Int)] {
    var regions: [(start: Int, end: Int)] = []
    var stack = [0]
    while let id = stack.popLast() {
        guard id < tree.nodes.count else { continue }
        let node = tree.node(id)
        if node.isError, node.end > node.start {
            regions.append((node.start, node.end))
            continue                       // its children are the same failure, said again
        }
        stack.append(contentsOf: node.children)
    }
    return regions.sorted { $0.start < $1.start }
}

/// Whether a byte offset falls inside any region, for callers walking segments.
func region(containing offset: Int, in regions: [(start: Int, end: Int)]) -> (start: Int, end: Int)? {
    regions.first { offset >= $0.start && offset < $0.end }
}
