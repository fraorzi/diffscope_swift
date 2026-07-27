import Foundation

/// One place a reviewer can jump to, expressed on **both** sides so the panes move together.
public struct ChangeStop: Codable, Sendable, Equatable {
    public let oldStart: Int
    public let oldEnd: Int
    public let newStart: Int
    public let newEnd: Int
}

/// An unchanged stretch long enough to be worth folding. Byte-equal on both sides by
/// construction — folding is the one presentation act that puts content out of sight, so what
/// it hides has to be provably the same text on both sides.
public struct CollapseRange: Codable, Sendable, Equatable {
    public let oldStart: Int
    public let oldEnd: Int
    public let newStart: Int
    public let newEnd: Int
    public let lines: Int
}

/// Unchanged lines kept either side of a fold, so a change never opens without context.
public let collapseContextLines = 3
/// Below this, folding costs a reader more than it saves.
public let collapseMinimumLines = 8

private func lineStarts(_ bytes: [UInt8]) -> [Int] {
    var starts = [0]
    for (index, byte) in bytes.enumerated() where byte == 0x0A { starts.append(index + 1) }
    return starts
}

private func lineIndex(of offset: Int, in starts: [Int]) -> Int {
    var low = 0
    var high = starts.count - 1
    var best = 0
    while low <= high {
        let mid = (low + high) / 2
        if starts[mid] <= offset { best = mid; low = mid + 1 } else { high = mid - 1 }
    }
    return best
}

/// Navigation follows the **canonical diff**, not the presented segments: the same alignment
/// the invariant is stated against, so "next change" cannot drift away from what INV-2 checks.
/// Presented ranges are supersets of these, so every stop lands inside a marked region.
public func changeStops(_ model: DiffModel) -> [ChangeStop] {
    guard case let .exact(hunks) = canonicalDiff(old: model.oldBytes, new: model.newBytes) else {
        return []
    }
    return hunks.map {
        ChangeStop(oldStart: $0.oldStart, oldEnd: $0.oldEnd, newStart: $0.newStart, newEnd: $0.newEnd)
    }
}

/// The unchanged gaps between stops, trimmed by `collapseContextLines` on each end and dropped
/// when what remains is shorter than `collapseMinimumLines`.
public func collapseRanges(_ model: DiffModel, stops: [ChangeStop]) -> [CollapseRange] {
    let oldStarts = lineStarts(model.oldBytes)
    let newStarts = lineStarts(model.newBytes)

    var gaps: [(oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int)] = []
    var oldCursor = 0
    var newCursor = 0
    for stop in stops {
        if stop.oldStart > oldCursor || stop.newStart > newCursor {
            gaps.append((oldCursor, stop.oldStart, newCursor, stop.newStart))
        }
        oldCursor = stop.oldEnd
        newCursor = stop.newEnd
    }
    gaps.append((oldCursor, model.oldBytes.count, newCursor, model.newBytes.count))

    var out: [CollapseRange] = []
    for gap in gaps {
        // Fold whole lines only: half a line behind a fold marker is unreadable on both counts.
        let firstOld = lineIndex(of: gap.oldStart, in: oldStarts) + 1 + collapseContextLines
        let lastOld = lineIndex(of: max(gap.oldStart, gap.oldEnd - 1), in: oldStarts) - collapseContextLines
        let firstNew = lineIndex(of: gap.newStart, in: newStarts) + 1 + collapseContextLines
        let lastNew = lineIndex(of: max(gap.newStart, gap.newEnd - 1), in: newStarts) - collapseContextLines
        guard lastOld - firstOld + 1 >= collapseMinimumLines,
              lastNew - firstNew + 1 >= collapseMinimumLines,
              lastOld - firstOld == lastNew - firstNew,
              firstOld > 0, firstNew > 0,
              lastOld < oldStarts.count, lastNew < newStarts.count
        else { continue }

        let oldRange = oldStarts[firstOld]..<oldStarts[lastOld]
        let newRange = newStarts[firstNew]..<newStarts[lastNew]
        guard oldRange.lowerBound >= gap.oldStart, oldRange.upperBound <= gap.oldEnd,
              newRange.lowerBound >= gap.newStart, newRange.upperBound <= gap.newEnd,
              Array(model.oldBytes[oldRange]) == Array(model.newBytes[newRange])
        else { continue }

        out.append(CollapseRange(
            oldStart: oldRange.lowerBound, oldEnd: oldRange.upperBound,
            newStart: newRange.lowerBound, newEnd: newRange.upperBound,
            lines: lastOld - firstOld
        ))
    }
    return out
}
