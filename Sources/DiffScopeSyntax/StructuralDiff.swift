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

    public init(anchors: Int, ambiguities: Int, unchangedBytesOld: Int, unchangedBytesNew: Int,
                usedFallback: Bool, degradation: Degradation?, movedSegments: Int = 0,
                formattingOnlySegments: Int = 0, behaviorAffectingSegments: Int = 0,
                invisibleSegments: Int = 0, movesFound: Int = 0, movesBelowFloor: Int = 0) {
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

    unchangedOld = reconciledOld.segments.filter { $0.label == .unchanged }.reduce(0) { $0 + $1.length }
    unchangedNew = reconciledNew.segments.filter { $0.label == .unchanged }.reduce(0) { $0 + $1.length }

    // A move regroups what is presented; it never removes it. Searched on the reconciled
    // labels, so the candidates are exactly the content the byte diff already calls changed.
    let search = findMoves(oldBytes: oldBytes, oldSegments: reconciledOld.segments,
                           newBytes: newBytes, newSegments: reconciledNew.segments,
                           floor: settings.moveContentFloor)
    let movedOld = applyMoves(
        Partition(totalLength: oldBytes.count, segments: reconciledOld.segments),
        ranges: search.moves.enumerated().flatMap { index, move in
            move.oldRanges.map { (start: $0.lowerBound, end: $0.upperBound, link: index) }
        }
    )
    let movedNew = applyMoves(
        Partition(totalLength: newBytes.count, segments: reconciledNew.segments),
        ranges: search.moves.enumerated().flatMap { index, move in
            move.newRanges.map { (start: $0.lowerBound, end: $0.upperBound, link: index) }
        }
    )

    let oldPartition = snapPresentation(
        movedOld, boundaries: SyntaxBoundaries(tree: oldTree), budget: settings.boundarySnapBudget
    )
    let newPartition = snapPresentation(
        movedNew, boundaries: SyntaxBoundaries(tree: newTree), budget: settings.boundarySnapBudget
    )

    unchangedOld = oldPartition.segments.filter { $0.label == .unchanged }.reduce(0) { $0 + $1.length }
    unchangedNew = newPartition.segments.filter { $0.label == .unchanged }.reduce(0) { $0 + $1.length }

    return StructuralResult(
        model: DiffModel(
            oldBytes: oldBytes, newBytes: newBytes,
            oldPartition: oldPartition, newPartition: newPartition
        ),
        stats: StructuralStats(
            anchors: found.count, ambiguities: mapping.ambiguities.count,
            unchangedBytesOld: unchangedOld, unchangedBytesNew: unchangedNew,
            usedFallback: false, degradation: nil,
            movedSegments: search.moves.count,
            formattingOnlySegments: segmentCount(in: oldPartition, group: .formattingOnly)
                + segmentCount(in: newPartition, group: .formattingOnly),
            behaviorAffectingSegments: segmentCount(in: oldPartition, group: .potentiallyBehaviorAffecting)
                + segmentCount(in: newPartition, group: .potentiallyBehaviorAffecting),
            invisibleSegments: [oldPartition, newPartition].reduce(0) { total, partition in
                total + partition.segments.filter { $0.disclosure != nil }.count
            },
            movesFound: search.moves.count,
            movesBelowFloor: search.belowFloor
        )
    )
}

func reconcile(
    _ segments: [Segment],
    against mask: [(start: Int, end: Int)],
    applied: Bool
) -> (segments: [Segment], moved: Int) {
    guard applied else { return (segments, 0) }
    let sorted = mask.sorted { $0.start < $1.start }
    var out: [Segment] = []
    var moved = 0

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
    return (out, moved)
}
