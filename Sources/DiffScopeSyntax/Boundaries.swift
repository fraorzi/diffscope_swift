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
    bytes: [UInt8] = [],
    crossesLineBreaks: Bool = false
) -> [(start: Int, end: Int)] {
    guard budget > 0, !boundaries.offsets.isEmpty, !mask.isEmpty else { return mask }

    // A boundary already on a line boundary is not widened (DEC-087). This pass exists to rescue a
    // change that *begins mid-structure*; once the canonical alignment lands on whole lines, the
    // same widening spends its budget spilling into the neighbouring line — which is how an
    // inserted member came to put its highlight on the *next* line's indentation. Measured: with
    // the shift in place and this guard absent, the corpus reports **more** wrong lines than before
    // the shift, not fewer.
    func atLineStart(_ offset: Int) -> Bool {
        guard !bytes.isEmpty else { return false }
        return offset == 0 || (offset <= bytes.count && bytes[offset - 1] == 0x0A)
    }

    // **The budget is bounded by the line as well as by its own number** (DEC-123).
    //
    // DEC-087 already found the shape from one side: an edge that has *arrived* at a line start must
    // not be widened, because the same budget then spends itself spilling into the neighbouring
    // line, and the corpus reported more wrong lines with the snap than without it. That guard fixes
    // the case where the edge starts on a boundary. It says nothing about an edge two bytes into a
    // line whose nearest node boundary is on the line above.
    //
    // A boundary on another line is a claim about that line. This pass exists to finish a construct
    // the change already touched, not to reach into one it did not — and reaching is the whole of
    // the pass's line cost: measured, the snap costs 327 false lines and every one of them is a
    // crossing. Bounded this way it costs **none**, and still keeps 73% of the marks it merges.
    func roomBackwards(_ offset: Int) -> Int {
        var at = min(offset, bytes.count)
        var room = 0
        while at > 0, bytes[at - 1] != 0x0A { at -= 1; room += 1 }
        return room
    }
    func roomForwards(_ offset: Int) -> Int {
        var at = max(0, offset)
        var room = 0
        while at < bytes.count, bytes[at] != 0x0A { at += 1; room += 1 }
        return room
    }
    let bounded = !crossesLineBreaks && !bytes.isEmpty
    var widened = mask.map { range -> (start: Int, end: Int) in
        let back = bounded ? min(budget, roomBackwards(range.start)) : budget
        let forward = bounded ? min(budget, roomForwards(range.end)) : budget
        return (atLineStart(range.start) ? range.start
                    : boundaries.snapDown(range.start, budget: back),
                atLineStart(range.end) ? range.end
                    : boundaries.snapUp(range.end, budget: forward))
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
    bytes: [UInt8] = [],
    crossesLineBreaks: Bool = false
) -> Partition {
    let presented = partition.segments.filter(\.isPresented).map { (start: $0.start, end: $0.end) }
    guard !presented.isEmpty else { return partition }
    return widenPresented(partition,
                          to: snapToBoundaries(presented, boundaries: boundaries,
                                               budget: budget, bytes: bytes,
                                               crossesLineBreaks: crossesLineBreaks))
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

/// The byte ranges of string and template literals, where a "word" is delimited by spaces rather
/// than by the language's identifier rule.
///
/// A Tailwind class attribute is one string node holding thirty words. `SyntaxBoundaries` offers
/// only that node's two ends, so the 16-byte budget can never reach them and the mark stays where
/// the byte diff put it — `bg-o⟦pacity-30⟧`, over a class name the reader has to reassemble. Inside
/// these ranges the word rule is *whitespace to whitespace*, which is what a class name, a URL
/// segment and a sentence in a JSX string all are.
public func stringRegions(tree: SyntaxTree) -> [(start: Int, end: Int)] {
    var regions: [(start: Int, end: Int)] = []
    for node in tree.nodes where node.end > node.start {
        switch node.type {
        case "string", "template_string", "string_fragment":
            regions.append((node.start, node.end))
        default:
            continue
        }
    }
    return regions.sorted { $0.start < $1.start }
}

