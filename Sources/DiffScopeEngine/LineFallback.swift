import Foundation

/// A localisation of last resort: which **lines** differ, for a file whose byte diff ran out of
/// budget (DEC-105).
///
/// **The case this exists for was never measured until there was a corpus for it.** DEC-095 stopped
/// the fallback path painting whole files, and it did so with a byte diff on a tenth of the normal
/// work budget — which is right for the dense-JSX gate case it was measured against. A 40 KB
/// translation file with a hundred edited strings is a different animal: the byte diff exhausts that
/// budget, `fallbackPartitions` returns `nil`, and the reader is shown 1098 changed lines where git
/// shows 94. Over a corpus of 364 stylesheets, JSON and Markdown files the model reported **190% of
/// git's added lines as changed**, almost all of it from eight translation files.
///
/// Lines are the right unit here for the same reason git chose them: there are three orders of
/// magnitude fewer of them than bytes, so the work fits, and a reader of a file with no grammar
/// reads it by line anyway.
///
/// **Anchoring, not minimising.** Unique lines that appear exactly once on each side are matched by
/// content, the longest increasing run of those pairs is kept, identical lines are trimmed from the
/// head and tail of every region between two anchors, and the search then **recurses** inside what is
/// left — a line that is not unique in the file is very often unique in the twenty lines around it.
/// Whatever survives all of that is reported as changed. That is patience's idea, and it is **not minimal** — which would
/// be a problem on the structural path, where INV-2 is stated against a byte-minimal diff, and is not
/// one here: this runs only where the byte diff has already refused to answer, so there is no
/// minimal alignment to be contained by, and `validate` reports the model unverified either way.
///
/// What it must never do is hide a change, and the shape of the rule is what prevents it: anything
/// not covered by a matched **identical** line pair is presented. A region the anchors cannot explain
/// is marked whole, which is the conservative direction.
public struct LineHunk: Sendable, Equatable {
    public let oldStart: Int
    public let oldEnd: Int
    public let newStart: Int
    public let newEnd: Int
}

/// Above this many lines even the anchoring is refused, and the whole file remains the answer. A
/// file with a million lines is a database dump, and the reader is not reading it.
public let lineFallbackLineLimit = 200_000

public func lineAnchoredHunks(old: [UInt8], new: [UInt8]) -> [LineHunk]? {
    let oldLines = lineSpans(old)
    let newLines = lineSpans(new)
    guard oldLines.count <= lineFallbackLineLimit, newLines.count <= lineFallbackLineLimit else {
        return nil
    }

    func key(_ bytes: [UInt8], _ span: (start: Int, end: Int)) -> UInt64 {
        // FNV-1a over the line's bytes, terminator included. A hash collision would pair two lines
        // that differ, so every pairing is confirmed on the bytes themselves — the hash is an index,
        // not a decision.
        var hash: UInt64 = 0xcbf29ce484222325
        for index in span.start..<span.end {
            hash = (hash ^ UInt64(bytes[index])) &* 0x100000001b3
        }
        return hash
    }

    let oldKeys = oldLines.map { key(old, $0) }
    let newKeys = newLines.map { key(new, $0) }

    func sameLine(_ oldIndex: Int, _ newIndex: Int) -> Bool {
        guard oldKeys[oldIndex] == newKeys[newIndex] else { return false }
        let a = oldLines[oldIndex], b = newLines[newIndex]
        guard a.end - a.start == b.end - b.start else { return false }
        return Array(old[a.start..<a.end]) == Array(new[b.start..<b.end])
    }

    var matched: [(oldIndex: Int, newIndex: Int)] = []

    /// One region, in line indices. Trims identical lines off both ends, anchors on the lines that
    /// are unique **within the region**, and recurses between the anchors. Depth is bounded because
    /// each level either matches a line or gives up, and a region that matches nothing is left for
    /// the caller to mark whole.
    func align(oldFrom: Int, oldTo: Int, newFrom: Int, newTo: Int, depth: Int) {
        var oldFrom = oldFrom, oldTo = oldTo, newFrom = newFrom, newTo = newTo
        while oldFrom < oldTo, newFrom < newTo, sameLine(oldFrom, newFrom) {
            matched.append((oldFrom, newFrom))
            oldFrom += 1
            newFrom += 1
        }
        while oldTo > oldFrom, newTo > newFrom, sameLine(oldTo - 1, newTo - 1) {
            matched.append((oldTo - 1, newTo - 1))
            oldTo -= 1
            newTo -= 1
        }
        guard oldFrom < oldTo, newFrom < newTo, depth > 0 else { return }

        var oldCounts: [UInt64: Int] = [:]
        var newCounts: [UInt64: Int] = [:]
        for index in oldFrom..<oldTo { oldCounts[oldKeys[index], default: 0] += 1 }
        for index in newFrom..<newTo { newCounts[newKeys[index], default: 0] += 1 }
        var newIndexOf: [UInt64: Int] = [:]
        for index in newFrom..<newTo where newCounts[newKeys[index]] == 1 {
            newIndexOf[newKeys[index]] = index
        }

        var pairs: [(oldIndex: Int, newIndex: Int)] = []
        for index in oldFrom..<oldTo where oldCounts[oldKeys[index]] == 1 {
            guard let newIndex = newIndexOf[oldKeys[index]], sameLine(index, newIndex) else { continue }
            pairs.append((index, newIndex))
        }
        let anchors = longestIncreasingByNewIndex(pairs)
        guard !anchors.isEmpty else { return }

        var oldCursor = oldFrom
        var newCursor = newFrom
        for anchor in anchors {
            align(oldFrom: oldCursor, oldTo: anchor.oldIndex,
                  newFrom: newCursor, newTo: anchor.newIndex, depth: depth - 1)
            matched.append((anchor.oldIndex, anchor.newIndex))
            oldCursor = anchor.oldIndex + 1
            newCursor = anchor.newIndex + 1
        }
        align(oldFrom: oldCursor, oldTo: oldTo, newFrom: newCursor, newTo: newTo, depth: depth - 1)
    }

    align(oldFrom: 0, oldTo: oldLines.count, newFrom: 0, newTo: newLines.count, depth: 24)
    matched.sort { $0.oldIndex < $1.oldIndex }

    var hunks: [LineHunk] = []
    var oldCursor = 0
    var newCursor = 0
    func emit(upToOld: Int, upToNew: Int) {
        guard upToOld > oldCursor || upToNew > newCursor else { return }
        let oldStart = oldCursor < oldLines.count ? oldLines[oldCursor].start : old.count
        let oldEnd = upToOld > oldCursor ? oldLines[upToOld - 1].end : oldStart
        let newStart = newCursor < newLines.count ? newLines[newCursor].start : new.count
        let newEnd = upToNew > newCursor ? newLines[upToNew - 1].end : newStart
        hunks.append(LineHunk(oldStart: oldStart, oldEnd: oldEnd, newStart: newStart, newEnd: newEnd))
    }
    for pair in matched {
        emit(upToOld: pair.oldIndex, upToNew: pair.newIndex)
        oldCursor = pair.oldIndex + 1
        newCursor = pair.newIndex + 1
    }
    emit(upToOld: oldLines.count, upToNew: newLines.count)
    return hunks
}

/// Whole lines, terminator included. A file that does not end with one still ends with a line.
func lineSpans(_ bytes: [UInt8]) -> [(start: Int, end: Int)] {
    var spans: [(start: Int, end: Int)] = []
    var start = 0
    var index = 0
    while index < bytes.count {
        if bytes[index] == 0x0A {
            spans.append((start, index + 1))
            start = index + 1
        }
        index += 1
    }
    if start < bytes.count { spans.append((start, bytes.count)) }
    return spans
}

/// Patience's second half: the longest run of pairs that is increasing on **both** sides, so the
/// anchors can be used in order without any of them crossing.
private func longestIncreasingByNewIndex(
    _ pairs: [(oldIndex: Int, newIndex: Int)]
) -> [(oldIndex: Int, newIndex: Int)] {
    guard !pairs.isEmpty else { return [] }
    var tailIndices: [Int] = []
    var previous = [Int](repeating: -1, count: pairs.count)

    for (index, pair) in pairs.enumerated() {
        var low = 0
        var high = tailIndices.count
        while low < high {
            let mid = (low + high) / 2
            if pairs[tailIndices[mid]].newIndex < pair.newIndex { low = mid + 1 } else { high = mid }
        }
        previous[index] = low > 0 ? tailIndices[low - 1] : -1
        if low == tailIndices.count { tailIndices.append(index) } else { tailIndices[low] = index }
    }

    var result: [(oldIndex: Int, newIndex: Int)] = []
    var cursor = tailIndices.last ?? -1
    while cursor >= 0 {
        result.append(pairs[cursor])
        cursor = previous[cursor]
    }
    return result.reversed()
}
