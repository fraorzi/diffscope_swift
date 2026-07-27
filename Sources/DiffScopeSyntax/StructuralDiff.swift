import DiffScopeEngine
import Foundation

public struct StructuralStats: Sendable, Equatable {
    public let anchors: Int
    public let ambiguities: Int
    public let unchangedBytesOld: Int
    public let unchangedBytesNew: Int
    public let usedFallback: Bool
    public let fallbackReason: String?
    public let movedSegments: Int

    public init(anchors: Int, ambiguities: Int, unchangedBytesOld: Int, unchangedBytesNew: Int,
                usedFallback: Bool, fallbackReason: String?, movedSegments: Int = 0) {
        self.anchors = anchors
        self.ambiguities = ambiguities
        self.unchangedBytesOld = unchangedBytesOld
        self.unchangedBytesNew = unchangedBytesNew
        self.usedFallback = usedFallback
        self.fallbackReason = fallbackReason
        self.movedSegments = movedSegments
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

public func structuralDiff(
    oldPath: String, oldBytes: [UInt8],
    newPath: String, newBytes: [UInt8],
    parser: TSXParser?,
    settings: MatcherSettings = MatcherSettings()
) -> StructuralResult {
    func fallbackResult(_ reason: String) -> StructuralResult {
        let label: SegmentLabel = oldBytes == newBytes ? .unchanged : .fallback
        return StructuralResult(
            model: DiffModel(
                oldBytes: oldBytes, newBytes: newBytes,
                oldPartition: wholeFilePartition(length: oldBytes.count, label: label),
                newPartition: wholeFilePartition(length: newBytes.count, label: label)
            ),
            stats: StructuralStats(anchors: 0, ambiguities: 0,
                                   unchangedBytesOld: 0, unchangedBytesNew: 0,
                                   usedFallback: true, fallbackReason: reason)
        )
    }

    if oldBytes == newBytes {
        return StructuralResult(
            model: DiffModel(
                oldBytes: oldBytes, newBytes: newBytes,
                oldPartition: wholeFilePartition(length: oldBytes.count, label: .unchanged),
                newPartition: wholeFilePartition(length: newBytes.count, label: .unchanged)
            ),
            stats: StructuralStats(anchors: 0, ambiguities: 0,
                                   unchangedBytesOld: oldBytes.count, unchangedBytesNew: newBytes.count,
                                   usedFallback: false, fallbackReason: nil)
        )
    }

    let oldClass = classify(path: oldPath, bytes: oldBytes)
    let newClass = classify(path: newPath, bytes: newBytes)
    if case let .fallback(reason) = oldClass { return fallbackResult(reason) }
    if case let .fallback(reason) = newClass { return fallbackResult(reason) }
    guard let parser,
          let oldTree = parser.parseTree(oldBytes),
          let newTree = parser.parseTree(newBytes)
    else { return fallbackResult("parser unavailable") }

    let mapping = matchTrees(old: oldTree, new: newTree, settings: settings)
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
        if !oldSpan.isEmpty {
            oldSegments.append(Segment(start: oldSpan.lowerBound, end: oldSpan.upperBound,
                                       label: equal ? .unchanged : .changed,
                                       confidence: equal ? 1 : 0.8))
            if equal { unchangedOld += oldSlice.count }
        }
        if !newSpan.isEmpty {
            newSegments.append(Segment(start: newSpan.lowerBound, end: newSpan.upperBound,
                                       label: equal ? .unchanged : .changed,
                                       confidence: equal ? 1 : 0.8))
            if equal { unchangedNew += newSlice.count }
        }
    }

    for anchor in found {
        emitGap(oldTo: anchor.oldStart, newTo: anchor.newStart)
        oldSegments.append(Segment(start: anchor.oldStart, end: anchor.oldEnd,
                                   label: .unchanged, classification: "anchor", confidence: 1))
        newSegments.append(Segment(start: anchor.newStart, end: anchor.newEnd,
                                   label: .unchanged, classification: "anchor", confidence: 1))
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

    return StructuralResult(
        model: DiffModel(
            oldBytes: oldBytes, newBytes: newBytes,
            oldPartition: Partition(totalLength: oldBytes.count, segments: reconciledOld.segments),
            newPartition: Partition(totalLength: newBytes.count, segments: reconciledNew.segments)
        ),
        stats: StructuralStats(
            anchors: found.count, ambiguities: mapping.ambiguities.count,
            unchangedBytesOld: unchangedOld, unchangedBytesNew: unchangedNew,
            usedFallback: false, fallbackReason: nil,
            movedSegments: reconciledOld.moved + reconciledNew.moved
        )
    )
}

func reconcile(
    _ segments: [Segment],
    against mask: [(start: Int, end: Int)],
    applied: Bool
) -> (segments: [Segment], moved: Int) {
    guard applied, !mask.isEmpty else { return (segments, 0) }
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
                                       classification: "refined", confidence: 1))
                }
                out.append(Segment(start: overlapStart, end: overlapEnd, label: .changed,
                                   classification: segment.classification, confidence: segment.confidence))
                cursor = overlapEnd
            }
            if cursor < segment.end {
                out.append(Segment(start: cursor, end: segment.end, label: .unchanged,
                                   classification: "refined", confidence: 1))
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
            let wasAnchor = segment.classification == "anchor"
            out.append(Segment(
                start: overlapStart, end: overlapEnd,
                label: wasAnchor ? .moved : .changed,
                classification: wasAnchor ? "moved-content" : segment.classification,
                confidence: 0.6
            ))
            if wasAnchor { moved += 1 }
            cursor = overlapEnd
        }
        if cursor < segment.end {
            out.append(Segment(start: cursor, end: segment.end, label: .unchanged,
                               classification: segment.classification, confidence: segment.confidence))
        }
    }
    return (out, moved)
}
