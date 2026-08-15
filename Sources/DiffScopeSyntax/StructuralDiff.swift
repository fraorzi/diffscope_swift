import DiffScopeEngine
import Foundation

public struct StructuralStats: Sendable, Equatable {
    public let anchors: Int
    public let ambiguities: Int
    public let unchangedBytesOld: Int
    public let unchangedBytesNew: Int
    public let usedFallback: Bool
    /// The condition that caused the fallback, ranked (DEC-051). Carried whole rather than as a
    /// sentence so the caller can say which taxonomy row fired, not merely what went wrong.
    public let degradation: Degradation?
    public var fallbackReason: String? { degradation?.reason }
    public let movedSegments: Int
    public let formattingOnlySegments: Int
    public let behaviorAffectingSegments: Int
    public let invisibleSegments: Int
    public let movesFound: Int
    public let movesBelowFloor: Int
    /// F1: byte ranges the parser could not read, and the changed segments inside them that are
    /// therefore shown without any structural claim.
    public let unparsedRegions: Int
    public let unparsedBytes: Int

    public init(anchors: Int, ambiguities: Int, unchangedBytesOld: Int, unchangedBytesNew: Int,
                usedFallback: Bool, degradation: Degradation?, movedSegments: Int = 0,
                formattingOnlySegments: Int = 0, behaviorAffectingSegments: Int = 0,
                invisibleSegments: Int = 0, movesFound: Int = 0, movesBelowFloor: Int = 0,
                unparsedRegions: Int = 0, unparsedBytes: Int = 0) {
        self.anchors = anchors
        self.ambiguities = ambiguities
        self.unchangedBytesOld = unchangedBytesOld
        self.unchangedBytesNew = unchangedBytesNew
        self.usedFallback = usedFallback
        self.degradation = degradation
        self.movedSegments = movedSegments
        self.formattingOnlySegments = formattingOnlySegments
        self.behaviorAffectingSegments = behaviorAffectingSegments
        self.invisibleSegments = invisibleSegments
        self.movesFound = movesFound
        self.movesBelowFloor = movesBelowFloor
        self.unparsedRegions = unparsedRegions
        self.unparsedBytes = unparsedBytes
    }
}

public extension StructuralStats {
    /// `12-…` §5.2's parser-state indicator, derived from what this run actually did.
    ///
    /// It lives beside the statistics rather than in the shell so that the check suite exercises
    /// the same derivation the window does. The one case it cannot see is a structural result
    /// discarded by validation *after* parsing: the parse succeeded, so the shell says so itself.
    var parserState: ParserStateReport {
        ParserStateReport.of(structuralRequested: true, structuralUsed: !usedFallback,
                             degradation: degradation,
                             unparsedRegions: unparsedRegions, unparsedBytes: unparsedBytes)
    }
}

public struct StructuralResult: Sendable {
    public let model: DiffModel
    public let stats: StructuralStats
}

struct Anchor {
    let oldStart: Int
    let oldEnd: Int
    let newStart: Int
    let newEnd: Int
}

func anchors(old: SyntaxTree, new: SyntaxTree, mapping: NodeMapping) -> [Anchor] {
    let ambiguousOld = mapping.ambiguousOldNodes
    let ambiguousNew = mapping.ambiguousNewNodes

    var candidates: [Anchor] = []
    for (oldID, newID) in mapping.oldToNew {
        let oldNode = old.node(oldID)
        let newNode = new.node(newID)
        guard oldNode.isLeaf, newNode.isLeaf else { continue }
        guard !oldNode.isError, !newNode.isError else { continue }
        guard !ambiguousOld.contains(oldID), !ambiguousNew.contains(newID) else { continue }
        guard oldNode.end > oldNode.start, newNode.end > newNode.start else { continue }
        guard old.text(of: oldID) == new.text(of: newID) else { continue }
        candidates.append(Anchor(
            oldStart: oldNode.start, oldEnd: oldNode.end,
            newStart: newNode.start, newEnd: newNode.end
        ))
    }

    candidates.sort {
        $0.oldStart != $1.oldStart ? $0.oldStart < $1.oldStart : $0.newStart < $1.newStart
    }

    var kept: [Anchor] = []
    var oldCursor = 0
    var newCursor = 0
    for anchor in candidates where anchor.oldStart >= oldCursor && anchor.newStart >= newCursor {
        kept.append(anchor)
        oldCursor = anchor.oldEnd
        newCursor = anchor.newEnd
    }
    return kept
}

/// - Parameter external: conditions this module cannot detect for itself — F8 (a Git filter is
///   active) and F10 (the pin would not settle) both belong to the Git layer, which the syntax
///   layer must not import. They join the ranking rather than pre-empting it, so a filtered `.png`
///   still reports as binary: F9 outranks F8.
public func structuralDiff(
    oldPath: String, oldBytes: [UInt8],
    newPath: String, newBytes: [UInt8],
    parser: TSXParser?,
    settings: MatcherSettings = MatcherSettings(),
    external: [Degradation] = []
) -> StructuralResult {
    func fallbackResult(_ degradation: Degradation) -> StructuralResult {
        let label: SegmentLabel = oldBytes == newBytes ? .unchanged : .fallback
        return StructuralResult(
            model: DiffModel(
                oldBytes: oldBytes, newBytes: newBytes,
                oldPartition: wholeFilePartition(length: oldBytes.count, label: label),
                newPartition: wholeFilePartition(length: newBytes.count, label: label)
            ),
            stats: StructuralStats(anchors: 0, ambiguities: 0,
                                   unchangedBytesOld: 0, unchangedBytesNew: 0,
                                   usedFallback: true, degradation: degradation)
        )
    }

    if oldBytes == newBytes {
        // INV-3 holds: the sides are byte-equal, so nothing is labelled changed. An external
        // condition still travels with the answer, because F8 is precisely the case where "no
        // changes" needs its caveat — the file list says the file changed (DEC-041, following
        // `git status`), this view compares bytes the filter did not touch, and both are right.
        return StructuralResult(
            model: DiffModel(
                oldBytes: oldBytes, newBytes: newBytes,
                oldPartition: wholeFilePartition(length: oldBytes.count, label: .unchanged),
                newPartition: wholeFilePartition(length: newBytes.count, label: .unchanged)
            ),
            stats: StructuralStats(anchors: 0, ambiguities: 0,
                                   unchangedBytesOld: oldBytes.count, unchangedBytesNew: newBytes.count,
                                   usedFallback: false,
                                   degradation: Degradation.mostConservative(external))
        )
    }

    // Everything knowable before parsing, gathered rather than short-circuited, so the reason shown
    // is the most conservative one that is true (DEC-051). Gate one lives here: parsing a 31 MB
    // bundle costs about a second before anything can be decided about it (DEC-050, M8-A).
    var upfront = external
    upfront += sourceDegradations(path: oldPath, bytes: oldBytes)
    upfront += sourceDegradations(path: newPath, bytes: newBytes)
    let largest = max(oldBytes.count, newBytes.count)
    if largest > structuralSizeLimit {
        upfront.append(.budgetExceeded(
            reason: "file is \(largest / 1024) KB, above the \(structuralSizeLimit / 1024) KB structural limit"))
    }
    if let worst = Degradation.mostConservative(upfront) { return fallbackResult(worst) }

    guard let parser,
          let oldTree = parser.parseTree(oldBytes),
          let newTree = parser.parseTree(newBytes)
    else { return fallbackResult(Degradation.parseFailure(reason: "parser unavailable")) }

    // Gate two, after parsing and before matching: parsing is linear, matching is not.
    let nodes = max(oldTree.nodes.count, newTree.nodes.count)
    if nodes > structuralNodeBudget {
        return fallbackResult(Degradation.budgetExceeded(
            reason: "file has \(nodes) syntax nodes, above the \(structuralNodeBudget) budget"))
    }

    let mapping = matchTrees(old: oldTree, new: newTree, settings: settings)
    // Gate three: matching gave up part-way. A partial mapping would present fewer anchors and
    // therefore *more* apparent change than the file contains — a worse answer that looks like a
    // normal one, which is exactly what INV-4 exists to prevent.
    if mapping.exceededBudget {
        return fallbackResult(Degradation.budgetExceeded(
            reason: "structural matching exceeded its work budget after \(mapping.workUsed) units"))
    }
    let found = anchors(old: oldTree, new: newTree, mapping: mapping)

    var oldSegments: [Segment] = []
    var newSegments: [Segment] = []
    var oldCursor = 0
    var newCursor = 0
    var unchangedOld = 0
    var unchangedNew = 0

    func emitGap(oldTo: Int, newTo: Int) {
        let oldSpan = oldCursor..<oldTo
        let newSpan = newCursor..<newTo
        let oldSlice = oldSpan.isEmpty ? [] : Array(oldBytes[oldSpan])
        let newSlice = newSpan.isEmpty ? [] : Array(newBytes[newSpan])
        let equal = oldSlice == newSlice
        // The gap pair is the only place both sides of a change are known to correspond,
        // so classification happens here, before reconciliation subdivides it.
        let classification = equal ? nil : changeClassification(old: oldSlice, new: newSlice)?.rawValue
        let disclosure = equal ? nil : invisibleDifference(old: oldSlice, new: newSlice)?.rawValue
        if !oldSpan.isEmpty {
            oldSegments.append(Segment(start: oldSpan.lowerBound, end: oldSpan.upperBound,
                                       label: equal ? .unchanged : .changed,
                                       classification: classification, disclosure: disclosure,
                                       confidence: equal ? 1 : 0.8))
            if equal { unchangedOld += oldSlice.count }
        }
        if !newSpan.isEmpty {
            newSegments.append(Segment(start: newSpan.lowerBound, end: newSpan.upperBound,
                                       label: equal ? .unchanged : .changed,
                                       classification: classification, disclosure: disclosure,
                                       confidence: equal ? 1 : 0.8))
            if equal { unchangedNew += newSlice.count }
        }
    }

    for anchor in found {
        emitGap(oldTo: anchor.oldStart, newTo: anchor.newStart)
        oldSegments.append(Segment(start: anchor.oldStart, end: anchor.oldEnd,
                                   label: .unchanged, confidence: 1))
        newSegments.append(Segment(start: anchor.newStart, end: anchor.newEnd,
                                   label: .unchanged, confidence: 1))
        unchangedOld += anchor.oldEnd - anchor.oldStart
        unchangedNew += anchor.newEnd - anchor.newStart
        oldCursor = anchor.oldEnd
        newCursor = anchor.newEnd
    }
    emitGap(oldTo: oldBytes.count, newTo: newBytes.count)

    var oldChangedMask: [(start: Int, end: Int)] = []
    var newChangedMask: [(start: Int, end: Int)] = []
    var coverageKnown = false
    if case let .exact(hunks) = canonicalDiff(old: oldBytes, new: newBytes) {
        coverageKnown = true
        for hunk in hunks {
            if hunk.oldEnd > hunk.oldStart { oldChangedMask.append((hunk.oldStart, hunk.oldEnd)) }
            if hunk.newEnd > hunk.newStart { newChangedMask.append((hunk.newStart, hunk.newEnd)) }
        }
    }

    let reconciledOld = reconcile(oldSegments, against: oldChangedMask, applied: coverageKnown)
    let reconciledNew = reconcile(newSegments, against: newChangedMask, applied: coverageKnown)

    unchangedOld = reconciledOld.filter { $0.label == .unchanged }.reduce(0) { $0 + $1.length }
    unchangedNew = reconciledNew.filter { $0.label == .unchanged }.reduce(0) { $0 + $1.length }

    // A move regroups what is presented; it never removes it. Searched on the reconciled
    // labels, so the candidates are exactly the content the byte diff already calls changed.
    let search = findMoves(oldBytes: oldBytes, oldSegments: reconciledOld,
                           newBytes: newBytes, newSegments: reconciledNew,
                           floor: settings.moveContentFloor)
    let movedOld = applyMoves(
        Partition(totalLength: oldBytes.count, segments: reconciledOld),
        ranges: search.moves.enumerated().flatMap { index, move in
            move.oldRanges.map { (start: $0.lowerBound, end: $0.upperBound, link: index) }
        }
    )
    let movedNew = applyMoves(
        Partition(totalLength: newBytes.count, segments: reconciledNew),
        ranges: search.moves.enumerated().flatMap { index, move in
            move.newRanges.map { (start: $0.lowerBound, end: $0.upperBound, link: index) }
        }
    )

    // Syntax snapping first, then grapheme snapping (`14-…` §4). Both only ever widen what is
    // presented, so the order costs nothing — but grapheme snapping must come last, because a
    // syntax boundary is not obliged to fall on a cluster boundary and the emoji-ZWJ case proves
    // it does not.
    // F1 (`13-…` §2): the regions the parser could not read. The structural result stands for the
    // rest of the file — that is what F1 asks for — but a change shown inside an unparsed region is
    // shown *without* a structural claim behind it, so it is labelled as the fallback it is.
    //
    // Only **changed** segments are relabelled. Repainting byte-equal content as fallback would
    // suggest something happened there; the byte comparison is still perfectly valid inside a
    // region tree-sitter failed on, because comparison never depended on parsing (DEC-021).
    let oldErrors = parseErrorRegions(tree: oldTree)
    let newErrors = parseErrorRegions(tree: newTree)
    let unparsedBytes = (oldErrors + newErrors).reduce(0) { $0 + ($1.end - $1.start) }

    let oldPartition = snapToGraphemeBoundaries(snapPresentation(
        movedOld, boundaries: SyntaxBoundaries(tree: oldTree), budget: settings.boundarySnapBudget
    ), bytes: oldBytes)
    let newPartition = snapToGraphemeBoundaries(snapPresentation(
        movedNew, boundaries: SyntaxBoundaries(tree: newTree), budget: settings.boundarySnapBudget
    ), bytes: newBytes)

    // Last, so it catches fragmentation from every pass above it rather than only from its
    // neighbour: `reconcile` cut by the other side's structure, the snap added flanks of its own,
    // and `markUnparsed` may have split a run again.
    let oldMarked = coalesceAdjacent(markUnparsed(oldPartition, regions: oldErrors))
    let newMarked = coalesceAdjacent(markUnparsed(newPartition, regions: newErrors))

    unchangedOld = oldMarked.segments.filter { $0.label == .unchanged }.reduce(0) { $0 + $1.length }
    unchangedNew = newMarked.segments.filter { $0.label == .unchanged }.reduce(0) { $0 + $1.length }

    return StructuralResult(
        model: DiffModel(
            oldBytes: oldBytes, newBytes: newBytes,
            oldPartition: oldMarked, newPartition: newMarked
        ),
        stats: StructuralStats(
            anchors: found.count, ambiguities: mapping.ambiguities.count,
            unchangedBytesOld: unchangedOld, unchangedBytesNew: unchangedNew,
            usedFallback: false,
            // The structural result stands and still carries its condition: F1 degrades part of a
            // file, not the file. `usedFallback` stays false because the analysis was not withheld.
            degradation: (oldErrors.isEmpty && newErrors.isEmpty) ? nil : .partialParseError(
                reason: "\(oldErrors.count + newErrors.count) region(s) of this file did not parse"
                    + " (\(unparsedBytes) bytes); changes inside them are shown without a structural claim"),
            movedSegments: search.moves.count,
            formattingOnlySegments: segmentCount(in: oldMarked, group: .formattingOnly)
                + segmentCount(in: newMarked, group: .formattingOnly),
            behaviorAffectingSegments: segmentCount(in: oldMarked, group: .potentiallyBehaviorAffecting)
                + segmentCount(in: newMarked, group: .potentiallyBehaviorAffecting),
            invisibleSegments: [oldMarked, newMarked].reduce(0) { total, partition in
                total + partition.segments.filter { $0.disclosure != nil }.count
            },
            movesFound: search.moves.count,
            movesBelowFloor: search.belowFloor,
            unparsedRegions: oldErrors.count + newErrors.count,
            unparsedBytes: unparsedBytes
        )
    )
}

/// Splits labelled segments against the canonical diff's changed mask.
///
/// The return type used to carry a `moved` count that nothing incremented and nothing read — the
/// residue of the reconciliation-derived `moved` label removed in M6-D. A counter stuck at zero is
/// worse than no counter, because it reads as a measurement.
func reconcile(
    _ segments: [Segment],
    against mask: [(start: Int, end: Int)],
    applied: Bool
) -> [Segment] {
    guard applied else { return segments }
    let sorted = mask.sorted { $0.start < $1.start }
    var out: [Segment] = []

    for segment in segments {
        if segment.label == .changed {
            var cursor = segment.start
            for range in sorted {
                if range.end <= cursor { continue }
                if range.start >= segment.end { break }
                let overlapStart = max(range.start, cursor)
                let overlapEnd = min(range.end, segment.end)
                guard overlapEnd > overlapStart else { continue }
                if overlapStart > cursor {
                    out.append(Segment(start: cursor, end: overlapStart, label: .unchanged,
                                       confidence: 1))
                }
                out.append(Segment(start: overlapStart, end: overlapEnd, label: .changed,
                                   classification: segment.classification,
                                   disclosure: segment.disclosure, confidence: segment.confidence))
                cursor = overlapEnd
            }
            if cursor < segment.end {
                out.append(Segment(start: cursor, end: segment.end, label: .unchanged,
                                   confidence: 1))
            }
            continue
        }

        guard segment.label == .unchanged else { out.append(segment); continue }

        var cursor = segment.start
        for range in sorted {
            if range.end <= cursor { continue }
            if range.start >= segment.end { break }
            let overlapStart = max(range.start, cursor)
            let overlapEnd = min(range.end, segment.end)
            guard overlapEnd > overlapStart else { continue }
            if overlapStart > cursor {
                out.append(Segment(start: cursor, end: overlapStart, label: .unchanged,
                                   classification: segment.classification, confidence: segment.confidence))
            }
            // An anchor the byte diff contradicts used to be relabelled `moved` here. That was
            // a claim this function cannot check: it sees one side only, so it could not compare
            // the two ranges DEC-038 requires to be byte-equal. Moves are now searched for
            // deliberately, against both sides, after reconciliation.
            out.append(Segment(
                start: overlapStart, end: overlapEnd,
                label: .changed,
                classification: segment.classification,
                disclosure: segment.disclosure,
                confidence: 0.6
            ))
            cursor = overlapEnd
        }
        if cursor < segment.end {
            out.append(Segment(start: cursor, end: segment.end, label: .unchanged,
                               classification: segment.classification, confidence: segment.confidence))
        }
    }
    return out
}


/// Relabels **changed** segments that fall inside a region the parser could not read, so a change
/// shown there is marked as raw rather than presented as understood (F1, INV-4).
///
/// Splits a segment that straddles a region boundary rather than relabelling the whole of it: the
/// clean half is still a structural claim the layer can make.
func markUnparsed(_ partition: Partition, regions: [(start: Int, end: Int)]) -> Partition {
    guard !regions.isEmpty else { return partition }
    var out: [Segment] = []
    for segment in partition.segments {
        guard segment.label == .changed else { out.append(segment); continue }
        var cursor = segment.start
        for region in regions where region.end > segment.start && region.start < segment.end {
            let start = max(region.start, cursor)
            let end = min(region.end, segment.end)
            guard end > start else { continue }
            if start > cursor {
                out.append(Segment(start: cursor, end: start, label: .changed,
                                   classification: segment.classification,
                                   disclosure: segment.disclosure,
                                   confidence: segment.confidence, link: segment.link))
            }
            out.append(Segment(start: start, end: end, label: .fallback,
                               classification: "parse-error",
                               disclosure: segment.disclosure,
                               confidence: 0, link: segment.link))
            cursor = end
        }
        if cursor < segment.end {
            out.append(Segment(start: cursor, end: segment.end, label: segment.label,
                               classification: segment.classification,
                               disclosure: segment.disclosure,
                               confidence: segment.confidence, link: segment.link))
        }
    }
    return Partition(totalLength: partition.totalLength, segments: out)
}
