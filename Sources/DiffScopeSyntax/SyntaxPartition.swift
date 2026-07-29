import DiffScopeEngine
import Foundation

public enum SourceClassification: Sendable, Equatable {
    case structural
    case fallback(Degradation)

    public var isStructural: Bool { self == .structural }

    public var degradation: Degradation? {
        if case let .fallback(degradation) = self { return degradation }
        return nil
    }

    public var reason: String? { degradation?.reason }
}

public struct PartitionBuildStats: Sendable, Equatable {
    public let leafCount: Int
    public let zeroWidthDropped: Int
    public let overlapsClamped: Int
    public let fillerSegments: Int
    public let fillerBytes: Int
    public let errorBytes: Int
}

public struct SyntaxPartitionResult: Sendable {
    public let partition: Partition
    public let stats: PartitionBuildStats
    public let usedFallback: Bool
}

/// Every condition that holds for this source, unranked and in no particular order.
///
/// All four are linear scans of a buffer already in memory, so asking all four costs what asking
/// the first one used to. That is what makes precedence affordable here: the reason shown can be
/// chosen from the conditions that are true rather than from the order they happened to be tested.
public func sourceDegradations(path: String, bytes: [UInt8]) -> [Degradation] {
    var found: [Degradation] = []
    let lower = path.lowercased()
    let structuralExtensions = [".tsx", ".ts", ".jsx", ".js", ".mts", ".cts", ".mjs", ".cjs"]
    if !structuralExtensions.contains(where: { lower.hasSuffix($0) }) {
        found.append(.unsupportedLanguage(reason: "unsupported language"))
    }
    if bytes.contains(0) {
        found.append(.binary(reason: "binary content"))
    } else if !Utf16OffsetMapper(bytes: bytes).isValidUTF8 {
        // Mapped to F9 by DEC-051: §2 has no row for undecodable text, and "content this tool
        // cannot treat as text" is what F9 names. Reported only when there is no NUL to report,
        // because a NUL is the more direct statement about the same file.
        found.append(.binary(reason: "not valid UTF-8"))
    }
    if let marker = firstConflictMarker(in: bytes) {
        // F2 by DEC-051: a file mid-merge is not source, which is the condition a whole-file parse
        // failure reports. Ranked there rather than invented as a row of its own.
        found.append(.parseFailure(reason: "merge conflict marker at byte \(marker)"))
    }
    return found
}

public func classify(path: String, bytes: [UInt8]) -> SourceClassification {
    guard let worst = Degradation.mostConservative(sourceDegradations(path: path, bytes: bytes))
    else { return .structural }
    return .fallback(worst)
}

func firstConflictMarker(in bytes: [UInt8]) -> Int? {
    let markers: [[UInt8]] = [
        Array("<<<<<<< ".utf8),
        Array("=======\n".utf8),
        Array(">>>>>>> ".utf8),
    ]
    var lineStart = 0
    var index = 0
    while index <= bytes.count {
        if index == bytes.count || bytes[index] == 0x0A {
            for marker in markers where lineStart + marker.count <= bytes.count {
                if Array(bytes[lineStart..<(lineStart + marker.count)]) == marker { return lineStart }
            }
            lineStart = index + 1
        }
        index += 1
    }
    return nil
}

public func buildSyntaxPartition(
    bytes: [UInt8],
    leaves: [SyntaxLeaf],
    changedLabel: SegmentLabel = .unchanged
) -> SyntaxPartitionResult {
    guard !bytes.isEmpty else {
        return SyntaxPartitionResult(
            partition: Partition(totalLength: 0, segments: []),
            stats: PartitionBuildStats(leafCount: leaves.count, zeroWidthDropped: 0,
                                       overlapsClamped: 0, fillerSegments: 0,
                                       fillerBytes: 0, errorBytes: 0),
            usedFallback: false
        )
    }

    var segments: [Segment] = []
    var cursor = 0
    var zeroWidth = 0
    var clamped = 0
    var fillerSegments = 0
    var fillerBytes = 0
    var errorBytes = 0

    for leaf in leaves {
        if leaf.end <= leaf.start || leaf.isMissing {
            zeroWidth += 1
            continue
        }
        var start = leaf.start
        if start < cursor {
            clamped += 1
            start = cursor
        }
        if start >= leaf.end { continue }
        if start > cursor {
            segments.append(Segment(start: cursor, end: start, label: changedLabel, classification: "filler"))
            fillerSegments += 1
            fillerBytes += start - cursor
        }
        let label: SegmentLabel = leaf.isError ? .fallback : changedLabel
        if leaf.isError { errorBytes += leaf.end - start }
        segments.append(Segment(
            start: start, end: leaf.end,
            label: label,
            classification: leaf.isError ? "parse-error" : leaf.type,
            confidence: leaf.isError ? 0 : 1
        ))
        cursor = leaf.end
    }

    if cursor < bytes.count {
        segments.append(Segment(start: cursor, end: bytes.count, label: changedLabel, classification: "filler"))
        fillerSegments += 1
        fillerBytes += bytes.count - cursor
    }

    return SyntaxPartitionResult(
        partition: Partition(totalLength: bytes.count, segments: segments),
        stats: PartitionBuildStats(
            leafCount: leaves.count, zeroWidthDropped: zeroWidth, overlapsClamped: clamped,
            fillerSegments: fillerSegments, fillerBytes: fillerBytes, errorBytes: errorBytes
        ),
        usedFallback: false
    )
}

public func partitionForSource(
    path: String,
    bytes: [UInt8],
    parser: TSXParser?,
    label: SegmentLabel = .unchanged
) -> SyntaxPartitionResult {
    let classification = classify(path: path, bytes: bytes)
    guard classification.isStructural, let parser, let outcome = parser.parse(bytes) else {
        return SyntaxPartitionResult(
            partition: wholeFilePartition(length: bytes.count, label: label == .unchanged ? .unchanged : .fallback),
            stats: PartitionBuildStats(leafCount: 0, zeroWidthDropped: 0, overlapsClamped: 0,
                                       fillerSegments: bytes.isEmpty ? 0 : 1,
                                       fillerBytes: bytes.count, errorBytes: 0),
            usedFallback: true
        )
    }
    return buildSyntaxPartition(bytes: bytes, leaves: outcome.leaves, changedLabel: label)
}
