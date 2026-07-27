import Foundation

public struct DiffModel: Sendable {
    public let oldBytes: [UInt8]
    public let newBytes: [UInt8]
    public let oldPartition: Partition
    public let newPartition: Partition

    public init(oldBytes: [UInt8], newBytes: [UInt8], oldPartition: Partition, newPartition: Partition) {
        self.oldBytes = oldBytes
        self.newBytes = newBytes
        self.oldPartition = oldPartition
        self.newPartition = newPartition
    }

    public var presentsNoChanges: Bool {
        oldPartition.segments.allSatisfy { !$0.isPresented }
            && newPartition.segments.allSatisfy { !$0.isPresented }
    }
}

public enum Side: String, Sendable, Equatable {
    case old
    case new
}

public enum InvariantViolation: Sendable, Equatable, CustomStringConvertible {
    case partitionMalformed(side: Side, defect: PartitionDefect)
    case reconstructionMismatch(side: Side, expectedLength: Int, actualLength: Int, firstDifferingByte: Int?)
    case uncoveredByte(side: Side, offset: Int, hunk: String)
    case claimedUnchangedButBytesDiffer(firstDifferingByte: Int)
    case claimedChangedButBytesEqual
    case unpresentedFallback(side: Side, segmentIndex: Int)

    public var description: String {
        switch self {
        case let .partitionMalformed(side, defect):
            return "INV-0 \(side.rawValue): \(defect)"
        case let .reconstructionMismatch(side, expected, actual, offset):
            let where_ = offset.map { " first differing byte at \($0)" } ?? ""
            return "INV-1 \(side.rawValue): reconstructed \(actual) bytes, expected \(expected);\(where_)"
        case let .uncoveredByte(side, offset, hunk):
            return "INV-2 \(side.rawValue): byte \(offset) differs but lies in no presented segment (hunk \(hunk))"
        case let .claimedUnchangedButBytesDiffer(offset):
            return "INV-3: model presents no changes but bytes differ at offset \(offset)"
        case .claimedChangedButBytesEqual:
            return "INV-3: model presents changes but both sides are byte-equal"
        case let .unpresentedFallback(side, index):
            return "INV-4 \(side.rawValue): segment \(index) is a fallback but is not presented"
        }
    }
}

public func reconstruct(_ partition: Partition, from bytes: [UInt8]) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(partition.totalLength)
    for segment in partition.segments {
        guard segment.start >= 0, segment.end <= bytes.count, segment.start < segment.end else { continue }
        out.append(contentsOf: bytes[segment.start..<segment.end])
    }
    return out
}

public struct ValidationResult: Sendable {
    public let violations: [InvariantViolation]
    public let coverageChecked: Bool
    public let coverageWorkUsed: Int

    public var passed: Bool { violations.isEmpty }

    public var summary: String {
        if !violations.isEmpty { return violations.map(\.description).joined(separator: "; ") }
        return coverageChecked ? "verified" : "unverified (coverage budget exceeded)"
    }
}

public func validate(
    _ model: DiffModel,
    workBudget: Int = defaultCanonicalDiffWorkBudget
) -> ValidationResult {
    var violations: [InvariantViolation] = []

    for (side, partition) in [(Side.old, model.oldPartition), (Side.new, model.newPartition)] {
        for defect in partitionDefects(partition) {
            violations.append(.partitionMalformed(side: side, defect: defect))
        }
    }

    for (side, partition, bytes) in [
        (Side.old, model.oldPartition, model.oldBytes),
        (Side.new, model.newPartition, model.newBytes),
    ] {
        let rebuilt = reconstruct(partition, from: bytes)
        if rebuilt != bytes {
            var firstDiff: Int? = nil
            for index in 0..<min(rebuilt.count, bytes.count) where rebuilt[index] != bytes[index] {
                firstDiff = index
                break
            }
            if firstDiff == nil, rebuilt.count != bytes.count {
                firstDiff = min(rebuilt.count, bytes.count)
            }
            violations.append(.reconstructionMismatch(
                side: side, expectedLength: bytes.count, actualLength: rebuilt.count, firstDifferingByte: firstDiff
            ))
        }
    }

    for (side, partition) in [(Side.old, model.oldPartition), (Side.new, model.newPartition)] {
        for (index, segment) in partition.segments.enumerated()
        where segment.label == .fallback && !segment.isPresented {
            violations.append(.unpresentedFallback(side: side, segmentIndex: index))
        }
    }

    let bytesEqual = model.oldBytes == model.newBytes
    if model.presentsNoChanges, !bytesEqual {
        var offset = 0
        let limit = min(model.oldBytes.count, model.newBytes.count)
        while offset < limit, model.oldBytes[offset] == model.newBytes[offset] { offset += 1 }
        violations.append(.claimedUnchangedButBytesDiffer(firstDifferingByte: offset))
    }
    if !model.presentsNoChanges, bytesEqual {
        violations.append(.claimedChangedButBytesEqual)
    }

    var coverageChecked = true
    var workUsed = 0

    if !bytesEqual {
        let result = canonicalMatches(old: model.oldBytes, new: model.newBytes, workBudget: workBudget)
        workUsed = result.workUsed
        if result.exceededBudget {
            coverageChecked = false
        } else {
            switch canonicalDiff(old: model.oldBytes, new: model.newBytes, workBudget: workBudget) {
            case let .exact(hunks):
                let oldCover = mergedRanges(model.oldPartition.presentedRanges)
                let newCover = mergedRanges(model.newPartition.presentedRanges)
                for hunk in hunks {
                    if let offset = firstUncovered(from: hunk.oldStart, to: hunk.oldEnd, in: oldCover) {
                        violations.append(.uncoveredByte(side: .old, offset: offset, hunk: hunk.description))
                    }
                    if let offset = firstUncovered(from: hunk.newStart, to: hunk.newEnd, in: newCover) {
                        violations.append(.uncoveredByte(side: .new, offset: offset, hunk: hunk.description))
                    }
                }
            case .budgetExceeded:
                coverageChecked = false
            }
        }
    }

    return ValidationResult(
        violations: violations,
        coverageChecked: coverageChecked,
        coverageWorkUsed: workUsed
    )
}

func mergedRanges(_ ranges: [(start: Int, end: Int)]) -> [(start: Int, end: Int)] {
    guard !ranges.isEmpty else { return [] }
    let sorted = ranges.sorted { $0.start < $1.start || ($0.start == $1.start && $0.end < $1.end) }
    var merged: [(start: Int, end: Int)] = [sorted[0]]
    for range in sorted.dropFirst() {
        let last = merged[merged.count - 1]
        if range.start <= last.end {
            merged[merged.count - 1] = (last.start, max(last.end, range.end))
        } else {
            merged.append(range)
        }
    }
    return merged
}

func firstUncovered(from start: Int, to end: Int, in cover: [(start: Int, end: Int)]) -> Int? {
    guard start < end else { return nil }
    var offset = start
    for range in cover {
        if range.end <= offset { continue }
        if range.start > offset { return offset }
        offset = max(offset, range.end)
        if offset >= end { return nil }
    }
    return offset < end ? offset : nil
}
