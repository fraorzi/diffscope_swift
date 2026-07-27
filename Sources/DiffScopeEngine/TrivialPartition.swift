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

public func trivialModel(oldBytes: [UInt8], newBytes: [UInt8]) -> DiffModel {
    let label: SegmentLabel = oldBytes == newBytes ? .unchanged : .fallback
    return DiffModel(
        oldBytes: oldBytes,
        newBytes: newBytes,
        oldPartition: wholeFilePartition(length: oldBytes.count, label: label),
        newPartition: wholeFilePartition(length: newBytes.count, label: label)
    )
}
