import Foundation

public enum SegmentLabel: String, Sendable, Equatable {
    case unchanged
    case changed
    case moved
    case fallback
}

public struct Segment: Sendable, Equatable {
    public let start: Int
    public let end: Int
    public let label: SegmentLabel
    public let classification: String?
    public let confidence: Double?
    public let link: Int?

    public init(
        start: Int,
        end: Int,
        label: SegmentLabel,
        classification: String? = nil,
        confidence: Double? = nil,
        link: Int? = nil
    ) {
        self.start = start
        self.end = end
        self.label = label
        self.classification = classification
        self.confidence = confidence
        self.link = link
    }

    public var length: Int { end - start }
    public var isPresented: Bool { label != .unchanged }
}

public struct Partition: Sendable, Equatable {
    public let totalLength: Int
    public let segments: [Segment]

    public init(totalLength: Int, segments: [Segment]) {
        self.totalLength = totalLength
        self.segments = segments
    }

    public var presentedRanges: [(start: Int, end: Int)] {
        segments.filter(\.isPresented).map { ($0.start, $0.end) }
    }
}

public enum PartitionDefect: Sendable, Equatable, CustomStringConvertible {
    case emptyWithNonZeroLength(totalLength: Int)
    case negativeOrZeroWidth(index: Int, start: Int, end: Int)
    case doesNotStartAtZero(firstStart: Int)
    case gap(afterIndex: Int, from: Int, to: Int)
    case overlap(atIndex: Int, previousEnd: Int, start: Int)
    case doesNotEndAtTotalLength(lastEnd: Int, totalLength: Int)
    case sumMismatch(sum: Int, totalLength: Int)

    public var description: String {
        switch self {
        case let .emptyWithNonZeroLength(n):
            return "no segments but totalLength is \(n)"
        case let .negativeOrZeroWidth(i, s, e):
            return "segment \(i) has zero or negative width: \(s)..<\(e)"
        case let .doesNotStartAtZero(s):
            return "first segment starts at \(s), expected 0"
        case let .gap(i, from, to):
            return "gap after segment \(i): bytes \(from)..<\(to) belong to no segment"
        case let .overlap(i, prev, s):
            return "segment \(i) starts at \(s) but previous ended at \(prev)"
        case let .doesNotEndAtTotalLength(last, total):
            return "last segment ends at \(last), expected \(total)"
        case let .sumMismatch(sum, total):
            return "segment lengths sum to \(sum), expected \(total)"
        }
    }
}

public func partitionDefects(_ partition: Partition) -> [PartitionDefect] {
    var defects: [PartitionDefect] = []

    guard !partition.segments.isEmpty else {
        if partition.totalLength != 0 {
            defects.append(.emptyWithNonZeroLength(totalLength: partition.totalLength))
        }
        return defects
    }

    var sum = 0
    var cursor = 0

    for (index, segment) in partition.segments.enumerated() {
        if segment.end <= segment.start {
            defects.append(.negativeOrZeroWidth(index: index, start: segment.start, end: segment.end))
            continue
        }
        if index == 0, segment.start != 0 {
            defects.append(.doesNotStartAtZero(firstStart: segment.start))
        } else if index > 0 {
            if segment.start > cursor {
                defects.append(.gap(afterIndex: index - 1, from: cursor, to: segment.start))
            } else if segment.start < cursor {
                defects.append(.overlap(atIndex: index, previousEnd: cursor, start: segment.start))
            }
        }
        sum += segment.length
        cursor = max(cursor, segment.end)
    }

    if cursor != partition.totalLength {
        defects.append(.doesNotEndAtTotalLength(lastEnd: cursor, totalLength: partition.totalLength))
    }
    if sum != partition.totalLength {
        defects.append(.sumMismatch(sum: sum, totalLength: partition.totalLength))
    }

    return defects
}
