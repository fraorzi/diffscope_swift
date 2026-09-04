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

/// A run of formatting-only changes offered as one collapsed group (DEC-048).
///
/// Unlike `CollapseRange` this hides bytes that **differ** between the sides, so it is grouping
/// under DEC-017's terms and nothing else: the segments stay in the model, `changes` states how
/// many were grouped, and one keystroke opens it. It is never a filter — a collapsed group that
/// could not be opened, or that did not say how much it held, would be one.
public struct FormattingCollapse: Codable, Sendable, Equatable {
    public let oldStart: Int
    public let oldEnd: Int
    public let newStart: Int
    public let newEnd: Int
    public let lines: Int
    public let changes: Int
}

public struct FormattingCollapseResult: Sendable, Equatable {
    public let ranges: [FormattingCollapse]
    /// Runs that were found but could not be offered because the two sides did not span the same
    /// number of lines. Counted rather than dropped in silence: DEC-038 records git's unannounced
    /// rejection floor as the thing to avoid, and this is the same shape of floor.
    public let unpaired: Int
}

/// Below this a group costs a reader the fold marker and saves them nothing.
public let formattingCollapseMinimumLines = 3
/// Unchanged code inside a run, in lines, before the run is cut. A long unchanged stretch between
/// two reindents is not part of either — and it already has the byte-equal fold path.
public let formattingCollapseGapLines = 2

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
///
/// **When the byte diff runs out of budget the answer is lines, not silence** (DEC-118) — DEC-105
/// carried onto the navigation path. `fallbackPartitions` has taken that route since DEC-105 on the reasoning that
/// *the byte diff refusing to answer is not the same thing as there being no answer*. This function
/// did not: it returned an empty list, and an empty stop list is not a quiet degradation. It is the
/// whole of the unified layout, because `unifiedBlocks` opens with `guard !stops.isEmpty`, and it is
/// the whole of `⌘↓`.
///
/// Measured on the corpus: the 40 M budget is exhausted on real `.tsx` pages — a small file replaced
/// by a large one is enough — and on those pairs the default layout drew no block at all while the
/// notice bar said only *coverage not verified*. That sentence is true and is not the one the reader
/// needs; the line-anchored hunks are, and they already exist.
///
/// The stops this route returns are wider than minimal, which is the same trade DEC-105 accepted:
/// what it leaves unstopped is byte-identical line pairs, so no change loses its stop. Navigation
/// asks for somewhere to go, not for the smallest possible somewhere.
///
/// - Parameter lineFallback: off reproduces the empty-list behaviour exactly, so the negative control
///   exercises this rule rather than a different code path.
public func changeStops(_ model: DiffModel, lineFallback: Bool = true) -> [ChangeStop] {
    switch canonicalDiff(old: model.oldBytes, new: model.newBytes) {
    case let .exact(hunks):
        return hunks.map {
            ChangeStop(oldStart: $0.oldStart, oldEnd: $0.oldEnd,
                       newStart: $0.newStart, newEnd: $0.newEnd)
        }
    case .budgetExceeded:
        guard lineFallback,
              let hunks = lineAnchoredHunks(old: model.oldBytes, new: model.newBytes)
        else { return [] }
        return hunks.map {
            ChangeStop(oldStart: $0.oldStart, oldEnd: $0.oldEnd,
                       newStart: $0.newStart, newEnd: $0.newEnd)
        }
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

/// Whether every presented segment touching a range is formatting-only — and that at least one
/// is. A presented segment of any other kind disqualifies the range outright: a group that
/// quietened a real edit alongside a reindent would hide the one thing the reader is looking for.
private func isFormattingOnly(_ partition: Partition, from: Int, to: Int) -> (formatting: Bool, any: Bool) {
    var sawFormatting = false
    for segment in partition.segments where segment.isPresented {
        // A pure insertion is zero-width on the other side, so a touching segment counts.
        guard segment.end > from || (segment.end == from && segment.start == from),
              segment.start < to || (segment.start == to && from == to)
        else { continue }
        guard classificationGroup(of: segment.classification) == ClassificationGroup.formattingOnly.rawValue
        else { return (false, true) }
        sawFormatting = true
    }
    return (sawFormatting, sawFormatting)
}

/// DEC-048. Formatting-only changes offered as collapsed groups.
///
/// Grouping is driven by the **canonical hunks**, not by one side's segments, because a reindent
/// is usually an insertion: the old side has no changed bytes at all, so a per-side run would find
/// nothing to pair on the left and offer nothing. Hunks are stated on both sides by construction —
/// the same reason `changeStops` uses them.
///
/// A group is offered only where both sides span the **same number of lines**. The panes scroll
/// together, so a group hiding four lines on the left and five on the right slides everything
/// below it out of correspondence. That is the argument byte-equality makes for `collapseRanges`,
/// applied to content that is allowed to differ.
public func formattingCollapses(_ model: DiffModel) -> FormattingCollapseResult {
    let stops = changeStops(model)
    guard !stops.isEmpty else { return FormattingCollapseResult(ranges: [], unpaired: 0) }

    let oldStarts = lineStarts(model.oldBytes)
    let newStarts = lineStarts(model.newBytes)

    // Merging happens in **lines**, not bytes. A reindent is an insertion, so its old-side hunk is
    // zero-width; merging byte offsets and then converting would place the last old line one line
    // short of the last new line, and the pairing condition below would reject every real case.
    struct Run {
        var oldLines: ClosedRange<Int>
        var newLines: ClosedRange<Int>
        var changes: Int
    }
    var runs: [Run] = []
    var canExtend = false
    for stop in stops {
        let old = isFormattingOnly(model.oldPartition, from: stop.oldStart, to: stop.oldEnd)
        let new = isFormattingOnly(model.newPartition, from: stop.newStart, to: stop.newEnd)
        let oldLines = lineIndex(of: stop.oldStart, in: oldStarts)...lineIndex(of: max(stop.oldStart, stop.oldEnd - 1), in: oldStarts)
        let newLines = lineIndex(of: stop.newStart, in: newStarts)...lineIndex(of: max(stop.newStart, stop.newEnd - 1), in: newStarts)
        guard !((old.any && !old.formatting) || (new.any && !new.formatting)),
              old.formatting || new.formatting
        else { canExtend = false; continue }

        // Consecutive formatting hunks separated by a line or two of untouched code are one
        // reformatting, not several. A longer gap is ordinary unchanged code, which already has
        // the byte-equal fold path and does not belong inside a formatting group.
        if var last = runs.last, canExtend,
           oldLines.lowerBound - last.oldLines.upperBound <= formattingCollapseGapLines,
           newLines.lowerBound - last.newLines.upperBound <= formattingCollapseGapLines {
            last.oldLines = last.oldLines.lowerBound...max(last.oldLines.upperBound, oldLines.upperBound)
            last.newLines = last.newLines.lowerBound...max(last.newLines.upperBound, newLines.upperBound)
            last.changes += 1
            runs[runs.count - 1] = last
        } else {
            runs.append(Run(oldLines: oldLines, newLines: newLines, changes: 1))
        }
        canExtend = true
    }

    func byteRange(_ lines: ClosedRange<Int>, _ starts: [Int], _ count: Int) -> Range<Int>? {
        guard lines.lowerBound < starts.count else { return nil }
        let lower = starts[lines.lowerBound]
        let upper = lines.upperBound + 1 < starts.count ? starts[lines.upperBound + 1] : count
        guard upper > lower else { return nil }
        return lower..<upper
    }

    var ranges: [FormattingCollapse] = []
    var unpaired = 0
    for run in runs {
        guard let oldRange = byteRange(run.oldLines, oldStarts, model.oldBytes.count),
              let newRange = byteRange(run.newLines, newStarts, model.newBytes.count)
        else { unpaired += 1; continue }
        let oldLines = run.oldLines.count
        let newLines = run.newLines.count
        guard oldLines >= formattingCollapseMinimumLines || newLines >= formattingCollapseMinimumLines
        else { continue }
        guard oldLines == newLines else { unpaired += 1; continue }

        // Whole lines are hidden, so a real edit anywhere on those lines disqualifies the group —
        // a reindent and a renamed variable on the same line is not a formatting change.
        let oldClean = isFormattingOnly(model.oldPartition, from: oldRange.lowerBound, to: oldRange.upperBound)
        let newClean = isFormattingOnly(model.newPartition, from: newRange.lowerBound, to: newRange.upperBound)
        guard !(oldClean.any && !oldClean.formatting), !(newClean.any && !newClean.formatting) else { continue }

        ranges.append(FormattingCollapse(
            oldStart: oldRange.lowerBound, oldEnd: oldRange.upperBound,
            newStart: newRange.lowerBound, newEnd: newRange.upperBound,
            lines: oldLines, changes: run.changes
        ))
    }
    return FormattingCollapseResult(ranges: ranges, unpaired: unpaired)
}
