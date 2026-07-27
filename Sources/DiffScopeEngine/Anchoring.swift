import Foundation

/// A place the reader's position can be restored to after a refresh (DEC-034).
///
/// It is identified by **content**, not by offset or line number: an insertion above the viewport
/// is the ordinary case while editing, and it moves every offset below it. The candidate set is
/// drawn from segments labelled `unchanged`, which exist on **both** sides by definition — so one
/// anchor positions both panes, which a change-index anchor could not do.
public struct RefreshAnchor: Codable, Sendable, Equatable {
    /// A hash of the anchored bytes, line-aligned. Content is the identity; the bytes themselves
    /// are already on screen, so shipping them a second time would double a large file's payload.
    public let digest: String
    /// Which occurrence of that text this is, counted from the top. Repeated lines are common in
    /// code (`}` alone on a line); without this the anchor would jump between identical stretches.
    public let occurrence: Int
    public let oldStart: Int
    public let newStart: Int

    public init(digest: String, occurrence: Int, oldStart: Int, newStart: Int) {
        self.digest = digest
        self.occurrence = occurrence
        self.oldStart = oldStart
        self.newStart = newStart
    }
}

/// Why the restored position is where it is. Carried rather than inferred, because "we anchored
/// somewhere else" and "there was nothing to anchor to" look identical from a scroll offset.
public enum AnchorResolution: String, Codable, Sendable, Equatable {
    case exact
    case nearestSurvivingAbove
    case topOfFile
    case noPreviousAnchor
}

public struct AnchorRestore: Codable, Sendable, Equatable {
    public let oldStart: Int
    public let newStart: Int
    public let resolution: AnchorResolution
    public let anchor: RefreshAnchor?

    public init(oldStart: Int, newStart: Int, resolution: AnchorResolution, anchor: RefreshAnchor?) {
        self.oldStart = oldStart
        self.newStart = newStart
        self.resolution = resolution
        self.anchor = anchor
    }
}

/// Only whole lines anchor: a fraction of a line is not a place a reader recognises, and the
/// two panes would land at visually different positions inside a wrapped line.
private func lineAlignedRange(_ start: Int, _ end: Int, in bytes: [UInt8]) -> Range<Int>? {
    var lower = start
    while lower < end, lower > 0, bytes[lower - 1] != 0x0A { lower += 1 }
    guard lower == 0 || (lower <= end && lower > 0 && bytes[lower - 1] == 0x0A) else { return nil }
    var upper = end
    while upper > lower, bytes[upper - 1] != 0x0A { upper -= 1 }
    guard upper > lower else { return nil }
    return lower..<upper
}

/// FNV-1a, because the engine imports Foundation and nothing else (DEC-042), and an anchor digest
/// needs collision resistance against ordinary source text, not against an adversary.
private func digestHex(_ bytes: ArraySlice<UInt8>) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return String(hash, radix: 16)
}

/// The anchors a model offers, in document order.
///
/// They come from the **canonical diff's matched blocks**, for the same reason `changeStops` does:
/// that is the alignment INV-2 is stated against, it is byte-equal on both sides by construction,
/// and it exists in every mode. Deriving them from segments labelled `unchanged` instead would
/// give Raw no anchors at all — Raw is one fallback segment over the whole file — so a refresh in
/// Raw would silently throw the reader back to the top.
/// How many lines an anchor's identity is taken over. One line is too weak — `}` alone occurs
/// everywhere — and identity that spans the whole matched block changes whenever anything above
/// the reader is edited, which is precisely the case anchoring exists for.
public let anchorWindowLines = 3
/// Anchors are line-granular, so a very large file is thinned by striding rather than by giving
/// the whole file one anchor. The reader lands within a few lines instead of exactly, which is
/// still far closer than the top of the file.
public let anchorBudget = 2000

public func refreshAnchors(_ model: DiffModel) -> [RefreshAnchor] {
    let matched = canonicalMatches(old: model.oldBytes, new: model.newBytes)
    guard !matched.exceededBudget else { return [] }

    var lines: [(oldStart: Int, newStart: Int, end: Int)] = []
    for block in matched.matches {
        guard let oldRange = lineAlignedRange(block.oldStart, block.oldStart + block.length,
                                              in: model.oldBytes) else { continue }
        // The two sides of a matched block are byte-equal, so one offset converts to the other.
        let delta = block.newStart - block.oldStart
        var cursor = oldRange.lowerBound
        while cursor < oldRange.upperBound {
            lines.append((cursor, cursor + delta, oldRange.upperBound))
            guard let newline = model.oldBytes[cursor..<oldRange.upperBound].firstIndex(of: 0x0A) else { break }
            cursor = newline + 1
        }
    }

    let stride = max(1, (lines.count + anchorBudget - 1) / anchorBudget)
    var seen: [String: Int] = [:]
    var anchors: [RefreshAnchor] = []
    for (index, line) in lines.enumerated() where index % stride == 0 {
        var end = line.oldStart
        for _ in 0..<anchorWindowLines {
            guard end < line.end else { break }
            guard let newline = model.oldBytes[end..<line.end].firstIndex(of: 0x0A) else { end = line.end; break }
            end = newline + 1
        }
        guard end > line.oldStart else { continue }
        let digest = digestHex(model.oldBytes[line.oldStart..<end])
        let occurrence = seen[digest, default: 0]
        seen[digest] = occurrence + 1
        anchors.append(RefreshAnchor(digest: digest, occurrence: occurrence,
                                     oldStart: line.oldStart, newStart: line.newStart))
    }
    return anchors
}

/// DEC-034's fallback chain, stated literally: the same anchor → the nearest **surviving** anchor
/// above it → the top of the file. Nothing here searches downward; scrolling past unread content
/// is worse than scrolling back to content already read.
///
/// The chain has to be exact, not approximate. Re-anchoring to a *different* anchor each refresh
/// is how a long editing session creeps away from where the reader was looking.
public func resolveAnchor(previous: RefreshAnchor?, candidates: [RefreshAnchor]) -> AnchorRestore {
    guard let previous else {
        return AnchorRestore(oldStart: 0, newStart: 0, resolution: .noPreviousAnchor, anchor: nil)
    }
    if let exact = candidates.first(where: { $0.digest == previous.digest && $0.occurrence == previous.occurrence }) {
        return AnchorRestore(oldStart: exact.oldStart, newStart: exact.newStart,
                             resolution: .exact, anchor: exact)
    }
    // "Above" is measured on the side the anchor was taken from, in its own coordinates: the
    // incoming model has not moved yet, and the old position is the last thing known about it.
    if let above = candidates.last(where: { $0.oldStart <= previous.oldStart }) {
        return AnchorRestore(oldStart: above.oldStart, newStart: above.newStart,
                             resolution: .nearestSurvivingAbove, anchor: above)
    }
    return AnchorRestore(oldStart: 0, newStart: 0, resolution: .topOfFile, anchor: nil)
}
