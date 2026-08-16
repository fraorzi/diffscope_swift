import DiffScopeEngine
import Foundation

/// DEC-038: a move is byte-identical or it is not a move. The pass condition is trivially
/// checkable, and this type is the whole claim — two ranges whose bytes are equal.
public struct MoveRecord: Sendable, Equatable {
    /// One entry per moved line, because the *ranges* have to be byte-equal and the whitespace
    /// between two lines need not be. A block that moved together is one record holding several
    /// ranges, not several moves.
    public let oldRanges: [Range<Int>]
    public let newRanges: [Range<Int>]
}

public struct MoveSearchResult: Sendable {
    public let moves: [MoveRecord]
    /// Candidates that matched byte-for-byte but carried less content than the floor. Counted
    /// rather than dropped: DEC-038 records `git --color-moved` **silently** discarding small
    /// moves as the thing to avoid, and a floor nobody can see is the same defect.
    public let belowFloor: Int
}

/// Moved content must carry at least this many non-whitespace bytes. Chosen by measurement —
/// see `22-experiment-log.md` → M6-D.
public let moveContentFloor = 12

private let asciiWhitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C]

private func changedRuns(_ segments: [Segment]) -> [(start: Int, end: Int)] {
    var runs: [(start: Int, end: Int)] = []
    for segment in segments where segment.label == .changed {
        if let last = runs.last, last.end == segment.start {
            runs[runs.count - 1] = (last.start, segment.end)
        } else {
            runs.append((segment.start, segment.end))
        }
    }
    return runs
}

/// Lines lying entirely inside changed content, with their trimmed extents.
///
/// Whole runs were tried first and matched almost nothing: structural anchors survive *inside*
/// a relocated block, so one moved block arrives as several changed runs split by unchanged
/// tokens, and the two sides split differently. Lines are the unit that survives that — the
/// same unit `git --color-moved` settled on, for what is probably the same reason.
private func changedLines(_ bytes: [UInt8], _ segments: [Segment]) -> [(start: Int, end: Int)] {
    let runs = changedRuns(segments)
    guard !runs.isEmpty else { return [] }

    var lines: [(start: Int, end: Int)] = []
    var lineStart = 0
    var index = 0
    var runIndex = 0

    func covered(_ start: Int, _ end: Int) -> Bool {
        while runIndex < runs.count, runs[runIndex].end <= start { runIndex += 1 }
        guard runIndex < runs.count else { return false }
        return runs[runIndex].start <= start && runs[runIndex].end >= end
    }

    while index <= bytes.count {
        let atEnd = index == bytes.count
        if atEnd || bytes[index] == 0x0A {
            let lineEnd = index
            if lineEnd > lineStart {
                let content = trimmed((lineStart, lineEnd), in: bytes)
                if content.end > content.start, covered(content.start, content.end) {
                    lines.append(content)
                }
            }
            lineStart = index + 1
        }
        index += 1
    }
    return lines
}

/// Whether two changed lines are neighbours in the file, with nothing but whitespace between them.
///
/// `changedLines` holds only the lines a change covers, so two entries are adjacent in the *array*
/// whenever the lines between them are unchanged — and extending a move across that gap claims one
/// relocation where there are two, which is exactly the pairing `link` exists to carry. A blank line
/// is not such a gap: a block that moved with a blank line inside it moved as one block.
private func adjacent(
    _ first: (start: Int, end: Int),
    _ second: (start: Int, end: Int),
    in bytes: [UInt8]
) -> Bool {
    guard second.start >= first.end else { return false }
    return !bytes[first.end..<second.start].contains { !asciiWhitespace.contains($0) }
}

private func trimmed(_ range: (start: Int, end: Int), in bytes: [UInt8]) -> (start: Int, end: Int) {
    var start = range.start
    var end = range.end
    while start < end, asciiWhitespace.contains(bytes[start]) { start += 1 }
    while end > start, asciiWhitespace.contains(bytes[end - 1]) { end -= 1 }
    return (start, end)
}

/// Pairs deleted content on the old side with identical inserted content on the new side.
///
/// Only content the canonical diff already calls changed is considered, so a move **regroups**
/// what is presented and never removes it (`10-…` §3.7). Pairing is greedy in old-side order,
/// which makes it deterministic under T-7; where several identical candidates exist the first
/// unused one wins rather than an arbitrary hash order.
public func findMoves(
    oldBytes: [UInt8], oldSegments: [Segment],
    newBytes: [UInt8], newSegments: [Segment],
    floor: Int = moveContentFloor
) -> MoveSearchResult {
    let oldLines = changedLines(oldBytes, oldSegments)
    let newLines = changedLines(newBytes, newSegments)
    guard !oldLines.isEmpty, !newLines.isEmpty else { return MoveSearchResult(moves: [], belowFloor: 0) }

    let oldContent = oldLines.map { Array(oldBytes[$0.start..<$0.end]) }
    let newContent = newLines.map { Array(newBytes[$0.start..<$0.end]) }

    var byContent: [[UInt8]: [Int]] = [:]
    for (index, content) in newContent.enumerated() {
        byContent[content, default: []].append(index)
    }

    var used = Set<Int>()
    var moves: [MoveRecord] = []
    var belowFloor = 0
    var oldIndex = 0

    while oldIndex < oldLines.count {
        guard let candidates = byContent[oldContent[oldIndex]],
              let start = candidates.first(where: { !used.contains($0) })
        else { oldIndex += 1; continue }

        // Extend while both sides continue line for line — a block that moved together should
        // be reported as one move, not as one move per line.
        var length = 1
        while oldIndex + length < oldLines.count, start + length < newLines.count,
              !used.contains(start + length),
              oldContent[oldIndex + length] == newContent[start + length],
              adjacent(oldLines[oldIndex + length - 1], oldLines[oldIndex + length], in: oldBytes),
              adjacent(newLines[start + length - 1], newLines[start + length], in: newBytes) {
            length += 1
        }

        let substance = (0..<length)
            .reduce(0) { $0 + oldContent[oldIndex + $1].filter { !asciiWhitespace.contains($0) }.count }
        guard substance >= floor else { belowFloor += 1; oldIndex += length; continue }

        for offset in 0..<length { used.insert(start + offset) }
        moves.append(MoveRecord(
            oldRanges: (0..<length).map { oldLines[oldIndex + $0].start..<oldLines[oldIndex + $0].end },
            newRanges: (0..<length).map { newLines[start + $0].start..<newLines[start + $0].end }
        ))
        oldIndex += length
    }

    return MoveSearchResult(moves: moves, belowFloor: belowFloor)
}

/// Relabels the given ranges as `moved`, splitting segments where a range covers part of one.
/// `link` carries the pairing so the two sides can be reported as one move.
public func applyMoves(
    _ partition: Partition,
    ranges: [(start: Int, end: Int, link: Int)]
) -> Partition {
    guard !ranges.isEmpty else { return partition }
    let sorted = ranges.sorted { $0.start < $1.start }
    var out: [Segment] = []

    for segment in partition.segments {
        guard segment.label == .changed else { out.append(segment); continue }
        var cursor = segment.start
        for range in sorted {
            if range.end <= cursor { continue }
            if range.start >= segment.end { break }
            let overlapStart = max(range.start, cursor)
            let overlapEnd = min(range.end, segment.end)
            guard overlapEnd > overlapStart else { continue }
            if overlapStart > cursor {
                out.append(Segment(start: cursor, end: overlapStart, label: .changed,
                                   classification: segment.classification,
                                   disclosure: segment.disclosure, confidence: segment.confidence))
            }
            out.append(Segment(start: overlapStart, end: overlapEnd, label: .moved,
                               classification: segment.classification,
                               disclosure: segment.disclosure,
                               confidence: 1, link: range.link))
            cursor = overlapEnd
        }
        if cursor < segment.end {
            out.append(Segment(start: cursor, end: segment.end, label: .changed,
                               classification: segment.classification,
                               disclosure: segment.disclosure, confidence: segment.confidence))
        }
    }
    return Partition(totalLength: partition.totalLength, segments: out)
}
