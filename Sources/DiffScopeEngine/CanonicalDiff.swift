import Foundation

public struct Hunk: Sendable, Equatable, CustomStringConvertible {
    public let oldStart: Int
    public let oldEnd: Int
    public let newStart: Int
    public let newEnd: Int

    public init(oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int) {
        self.oldStart = oldStart
        self.oldEnd = oldEnd
        self.newStart = newStart
        self.newEnd = newEnd
    }

    public var description: String {
        "old[\(oldStart)..<\(oldEnd)] new[\(newStart)..<\(newEnd)]"
    }
}

public struct MatchBlock: Sendable, Equatable {
    public let oldStart: Int
    public let newStart: Int
    public let length: Int
}

public let defaultCanonicalDiffWorkBudget = 40_000_000

public enum CanonicalDiffOutcome: Sendable, Equatable {
    case exact([Hunk])
    case budgetExceeded(workUsed: Int)
}

final class WorkBudget {
    let limit: Int
    private(set) var used = 0
    private(set) var exceeded = false

    init(limit: Int) { self.limit = limit }

    @inline(__always)
    func spend(_ amount: Int) {
        used += amount
        if used > limit { exceeded = true }
    }
}

/// - Parameter applyShift: the boundary shift, on by default because production always wants it.
///   The suite turns it off to hold the unshifted alignment next to the shifted one — without that
///   control a check asserting where a hunk lands cannot tell a shift that fired from one that was
///   never needed. Same precedent as `boundarySnapBudget: 0` (DEC-047).
public func canonicalMatches(
    old: [UInt8],
    new: [UInt8],
    workBudget: Int = defaultCanonicalDiffWorkBudget,
    applyShift: Bool = true
) -> (matches: [MatchBlock], exceededBudget: Bool, workUsed: Int) {
    var matches: [MatchBlock] = []
    let half = (old.count + new.count + 1) / 2 + 1
    var forward = [Int](repeating: 0, count: 2 * half + 2)
    var backward = [Int](repeating: 0, count: 2 * half + 2)
    let budget = WorkBudget(limit: workBudget)
    old.withUnsafeBufferPointer { a in
        new.withUnsafeBufferPointer { b in
            divide(a, 0, a.count, b, 0, b.count, &forward, &backward, half, &matches, budget)
            if applyShift, !budget.exceeded {
                matches = shiftToReadableBoundaries(matches, old: a, new: b)
            }
        }
    }
    return (matches, budget.exceeded, budget.used)
}

/// The three classes a byte can belong to for boundary purposes. Bytes at or above `0x80` count as
/// word bytes so that a boundary is never placed inside a multi-byte UTF-8 sequence; grapheme
/// snapping is a later and separate pass, and this one should not hand it work to undo.
@inline(__always)
func lexicalClass(_ byte: UInt8) -> UInt8 {
    switch byte {
    case 0x20, 0x09, 0x0A, 0x0D: return 0
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x24: return 1
    default: return byte >= 0x80 ? 1 : 2
    }
}

/// The longest match a shift may consume entirely, in bytes (DEC-097, measured in M11-G).
///
/// Consuming a match merges the two hunks either side of it, which is how an insertion whose
/// neighbours are a short match apart becomes reachable at all: the walk is bounded by
/// `current.length` and `previous.length`, and a four-byte match between two insertions bounds it to
/// nothing. Bounded in turn, because with no bound a file of small scattered edits could collapse
/// into one hunk covering it.
///
/// **Eight, because that is where the curve saturates and not because larger is safer.** M11-G finds
/// 8, 16, 24, 48 and 96 identical on the corpus, and consuming is the one direction in this pass
/// that relocates presented bytes rather than merely renaming a boundary — so the smallest value
/// that buys the whole effect is the one to take.
public let matchConsumeFloor = 8

/// How well one position reads as a place for a change to begin or end. Lower is better, and the
/// numbers are the ranks of DEC-088's total order; `nil` means the position is not a boundary at all.
private let rankLine = 1
private let rankSpaced = 2
private let rankLexical = 3

/// The worst rank a landing may have and still be allowed to **consume** the match it walked
/// through (DEC-104, widening DEC-097's `rankLine`-only rule).
///
/// DEC-097 let a shift swallow a match shorter than `matchConsumeFloor`, and allowed it only when the
/// shift landed on a whole line, on the reasoning that merging two hunks is the one thing this pass
/// does that a reader can see as a *different* answer rather than a better-placed one.
///
/// The corpus says the rule is one rank too strict. `<NextImage src={img.src} …>` rewrapped with a
/// prop added aligns as `"s"` matched inside `className` and `"rc={img.src}"` matched at the real
/// `src` — so `src`, a word the reader can see is untouched, is drawn as changed. Consuming that
/// one-byte match lands on a **whitespace-adjacent** boundary, rank 2, and the alignment that
/// results pairs `src` with `src`.
///
/// Rank 3 is still refused: a bare class transition — `)}` against `src` — is a boundary the language
/// sees and a reader does not, and consuming a match to reach one would be the unmeasured licence
/// DEC-097 was right to withhold.
private let matchConsumeRankLimit = rankSpaced

/// Moves each hunk along the file, while the alignment stays equally minimal, to the position where
/// it reads best: whole lines first, then whole tokens (DEC-087, extended by DEC-088).
///
/// Myers does not select a unique alignment. Where several are equally short it picks arbitrarily,
/// and the arbitrary one is usually the one that begins mid-line: an insertion before
/// `import ButtonLink …` anchors after the shared word `import `, so an untouched line reads as
/// removed-and-re-added, and an insertion before `  text: string;` anchors after the shared indent,
/// so the highlight lands on the *next* line's whitespace. Below the line it is the same fault:
/// inserting `'compact' | ` into `'base' | 'wide'` anchors after the shared `'`, so the mark reads
/// `compact' | ` and the apostrophe of `'wide'` — a byte nobody touched — is drawn as changed.
///
/// **This is not the sliding DEC-047 refused.** That objection was against moving the presentation
/// while `D` stood still, which fails a validator recomputing `D`. Here `D` itself moves, inside the
/// one function both the model and `Validation` call, so containment holds byte for byte.
///
/// A shift moves the boundary between a hunk and each of its neighbouring matches by the same
/// amount, so **the total matched length is invariant** and the result is still minimal — the
/// property `diffscope-verify` already asserts against a brute-force LCS on random pairs.
///
/// **The boundary set is a pure function of the bytes.** DEC-087 admitted only `0x0A`, on the
/// ground that snapping to *lexer tokens or tree-sitter nodes* would make `D` depend on a parse
/// that can fail. A byte-class transition needs no parser and cannot fail, so it is inside that
/// argument rather than against it; the door DEC-087 shut stays shut. `D` remains minimal,
/// deterministic, over bytes, and free of structural input.
///
/// Rank 2 sits above rank 3 because a class transition alone does not separate the two candidates
/// in the case that motivated this: `…| '⟦compact' | ⟧'wide'` and `…| ⟦'compact' | ⟧'wide'` are both
/// class transitions at both ends, and only whitespace adjacency prefers the second.
func shiftToReadableBoundaries(
    _ matches: [MatchBlock],
    old: UnsafeBufferPointer<UInt8>,
    new: UnsafeBufferPointer<UInt8>
) -> [MatchBlock] {
    guard matches.count > 1 else { return matches }
    var blocks = matches

    // How well a single position reads. A file edge is the strongest boundary there is.
    @inline(__always)
    func rank(_ buffer: UnsafeBufferPointer<UInt8>, _ offset: Int) -> Int? {
        guard offset > 0, offset < buffer.count else { return rankLine }
        let before = buffer[offset - 1]
        let after = buffer[offset]
        if before == 0x0A { return rankLine }
        let beforeClass = lexicalClass(before)
        guard beforeClass != lexicalClass(after) else { return nil }
        return beforeClass == 0 || lexicalClass(after) == 0 ? rankSpaced : rankLexical
    }

    /// A match that **cuts a word in half on one side** — the diff borrowing letters from the middle
    /// of an unrelated identifier (DEC-104).
    ///
    /// `img.height}` rewrapped beside an inserted `compactImageDimensions?.height ?? ` aligns as the
    /// `i` of `Dimensions` matched to the `i` of `img`, and `mg.height}` matched at the real one. The
    /// `i` is a match by the letter and noise by the eye: it begins and ends inside a word that
    /// neither side changed. Consuming it pairs `img.height}` with `img.height}`.
    ///
    /// It is a separate permission from the landing rank because it is a fact about the match being
    /// removed rather than about the position gained. The rank rule asks *is the place I am going to
    /// readable*; this asks *was the thing I am giving up ever visible*. `{` to `i` is a class
    /// transition and rank 3, so no rank rule would ever have allowed this one.
    @inline(__always)
    func buriedInWord(_ buffer: UnsafeBufferPointer<UInt8>, _ start: Int, _ length: Int) -> Bool {
        guard length > 0 else { return false }
        func isWord(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte == 0x24 || byte >= 0x80
        }
        let end = start + length
        if start > 0, isWord(buffer[start - 1]), isWord(buffer[start]) { return true }
        if end < buffer.count, isWord(buffer[end - 1]), isWord(buffer[end]) { return true }
        return false
    }

    @inline(__always)
    func isNoise(_ block: MatchBlock) -> Bool {
        block.length <= matchConsumeFloor
            && (buriedInWord(old, block.oldStart, block.length)
                || buriedInWord(new, block.newStart, block.length))
    }

    // A hunk is as good as its worst end, and as good as its worse side. An empty range is a point,
    // and a point is judged once.
    @inline(__always)
    func rank(_ buffer: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Int? {
        guard let atStart = rank(buffer, start) else { return nil }
        guard end > start else { return atStart }
        guard let atEnd = rank(buffer, end) else { return nil }
        return max(atStart, atEnd)
    }

    // One step is legal when the byte leaving the front of the hunk equals the byte entering the
    // back of it — for every side that has content. A side with an empty hunk imposes no condition;
    // its boundary simply travels with the other side's.
    @inline(__always)
    func stepHolds(_ buffer: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int, down: Bool) -> Bool {
        guard end > start else { return true }
        if down {
            guard end < buffer.count else { return false }
            return buffer[start] == buffer[end]
        }
        guard start > 0 else { return false }
        return buffer[start - 1] == buffer[end - 1]
    }

    for index in 1..<blocks.count {
        let previous = blocks[index - 1]
        let current = blocks[index]
        let oldStart = previous.oldStart + previous.length
        let newStart = previous.newStart + previous.length
        let oldEnd = current.oldStart
        let newEnd = current.newStart
        guard oldEnd > oldStart || newEnd > newStart else { continue }

        // The best shift found at each rank. Ranks are compared first and the shift only breaks
        // ties, so a whole-line position anywhere in reach beats a token boundary next door.
        var bestAtRank = [Int?](repeating: nil, count: rankLexical + 1)

        // **The boundary a consuming shift is scored on is the one it would leave behind, not the one
        // it walks past** (DEC-104). When the shift swallows a neighbouring match, that match stops
        // existing, and the hunk's edge moves to where *it* began — so scoring the walked-to position
        // asks about a boundary the move removes.
        //
        // This is what kept `<NextImage src={img.src} …>` wrong through DEC-097. The alignment matches
        // the `s` of the old `src` inside the inserted `className` and the rest at the real `src`;
        // consuming that one-byte match pairs `src` with `src`, and the position it lands on reads as
        // a word boundary. Scored at the walked-to offset it reads as the middle of `class` instead —
        // rank `nil`, refused, every time.
        @inline(__always)
        func score(_ shift: Int) -> Int? {
            var oldFrom = oldStart + shift, newFrom = newStart + shift
            var oldTo = oldEnd + shift, newTo = newEnd + shift
            if shift < 0, -shift == previous.length {
                // The consumed match joins the hunk, and so does whatever hunk lay in front of it:
                // the edge that survives is the end of the match *before* the one being swallowed.
                let before = index >= 2 ? blocks[index - 2] : nil
                oldFrom = before.map { $0.oldStart + $0.length } ?? 0
                newFrom = before.map { $0.newStart + $0.length } ?? 0
            }
            if shift > 0, shift == current.length {
                let after = index + 1 < blocks.count ? blocks[index + 1] : nil
                oldTo = after?.oldStart ?? old.count
                newTo = after?.newStart ?? new.count
            }
            guard let oldRank = rank(old, oldFrom, oldTo),
                  let newRank = rank(new, newFrom, newTo)
            else { return nil }
            return max(oldRank, newRank)
        }

        // Shift 0 is a candidate like any other, and scoring it is what keeps the ranks honest:
        // Myers often lands on a line boundary already, and a rank-2 position one byte away must
        // not be allowed to pull it off one. DEC-087 could leave this out because it accepted only
        // whole-line positions, so moving from one to another cost nothing.
        if let found = score(0) { bestAtRank[found] = 0 }

        // A short neighbouring match **may** be consumed, and a long one may not (DEC-097). The
        // total matched length is invariant either way — the boundary between the hunk and each of
        // its neighbours moves by the same amount — so what changes is the number of hunks, not the
        // size of the edit script. Consuming is therefore allowed only where it lands on a whole
        // line and only for a match under `matchConsumeFloor`; the walk itself may reach further,
        // because a candidate that is refused still has to be looked at to be refused.
        let consumable = current.length <= matchConsumeFloor
        let downLimit = consumable ? current.length : current.length - 1
        var shift = 0
        while shift < downLimit,
              stepHolds(old, oldStart + shift, oldEnd + shift, down: true),
              stepHolds(new, newStart + shift, newEnd + shift, down: true) {
            shift += 1
            // Overwriting keeps the largest shift at each rank: the position furthest down the file.
            // Consuming noise is a candidate even where the edge it leaves reads as nothing at all:
            // the gain is the match that stops existing, not the position gained, so it enters at the
            // worst rank and wins only when nothing better is in reach.
            let scored = score(shift)
                ?? (shift == current.length && isNoise(current) ? rankLexical : nil)
            guard let found = scored else { continue }
            if shift == current.length, found > matchConsumeRankLimit, !isNoise(current) { continue }
            bestAtRank[found] = shift
        }
        // The furthest position down the file wins, so the upward search keeps only what the
        // downward one did not reach, and stops as soon as it finds the best rank there is.
        if bestAtRank[rankLine] == nil {
            shift = 0
            let upLimit = previous.length <= matchConsumeFloor ? previous.length : previous.length - 1
            while -shift < upLimit,
                  stepHolds(old, oldStart + shift, oldEnd + shift, down: false),
                  stepHolds(new, newStart + shift, newEnd + shift, down: false) {
                shift -= 1
                let scored = score(shift)
                    ?? (-shift == previous.length && isNoise(previous) ? rankLexical : nil)
                if let found = scored, bestAtRank[found] == nil,
                   -shift != previous.length || found <= matchConsumeRankLimit || isNoise(previous) {
                    bestAtRank[found] = shift
                }
                if bestAtRank[rankLine] != nil { break }
            }
        }
        // No reachable position reads as a boundary: the alignment stays exactly where Myers put
        // it, and no boundary is invented.
        let best = (rankLine...rankLexical).lazy.compactMap { bestAtRank[$0] }.first
        guard let chosen = best, chosen != 0 else { continue }

        blocks[index - 1] = MatchBlock(oldStart: previous.oldStart, newStart: previous.newStart,
                                       length: previous.length + chosen)
        blocks[index] = MatchBlock(oldStart: current.oldStart + chosen,
                                   newStart: current.newStart + chosen,
                                   length: current.length - chosen)
    }
    // A consumed match is gone, not present-and-empty. Leaving it in the list would make the tiling
    // property — every match is a real match, in order — read a zero-width block as a defect, and it
    // would be right to.
    return blocks.filter { $0.length > 0 }
}

public func canonicalDiff(
    old: [UInt8],
    new: [UInt8],
    workBudget: Int = defaultCanonicalDiffWorkBudget,
    applyShift: Bool = true
) -> CanonicalDiffOutcome {
    let result = canonicalMatches(old: old, new: new, workBudget: workBudget, applyShift: applyShift)
    if result.exceededBudget {
        return .budgetExceeded(workUsed: result.workUsed)
    }
    let matches = result.matches
    var hunks: [Hunk] = []
    var oldCursor = 0
    var newCursor = 0
    for match in matches {
        if match.oldStart > oldCursor || match.newStart > newCursor {
            hunks.append(Hunk(
                oldStart: oldCursor, oldEnd: match.oldStart,
                newStart: newCursor, newEnd: match.newStart
            ))
        }
        oldCursor = match.oldStart + match.length
        newCursor = match.newStart + match.length
    }
    if oldCursor < old.count || newCursor < new.count {
        hunks.append(Hunk(
            oldStart: oldCursor, oldEnd: old.count,
            newStart: newCursor, newEnd: new.count
        ))
    }
    return .exact(hunks)
}

private func divide(
    _ a: UnsafeBufferPointer<UInt8>, _ aLoIn: Int, _ aHiIn: Int,
    _ b: UnsafeBufferPointer<UInt8>, _ bLoIn: Int, _ bHiIn: Int,
    _ forward: inout [Int], _ backward: inout [Int], _ half: Int,
    _ matches: inout [MatchBlock], _ budget: WorkBudget
) {
    if budget.exceeded { return }
    var aLo = aLoIn, aHi = aHiIn, bLo = bLoIn, bHi = bHiIn

    var prefix = 0
    while aLo + prefix < aHi, bLo + prefix < bHi, a[aLo + prefix] == b[bLo + prefix] {
        prefix += 1
    }
    if prefix > 0 {
        appendMatch(&matches, MatchBlock(oldStart: aLo, newStart: bLo, length: prefix))
        aLo += prefix
        bLo += prefix
    }

    var suffix = 0
    while aHi - suffix > aLo, bHi - suffix > bLo, a[aHi - suffix - 1] == b[bHi - suffix - 1] {
        suffix += 1
    }
    let suffixOldStart = aHi - suffix
    let suffixNewStart = bHi - suffix
    aHi -= suffix
    bHi -= suffix

    if aLo < aHi, bLo < bHi {
        let snake = middleSnake(a, aLo, aHi, b, bLo, bHi, &forward, &backward, half, budget)
        if budget.exceeded { return }
        divide(a, aLo, aLo + snake.xStart, b, bLo, bLo + snake.yStart, &forward, &backward, half, &matches, budget)
        if snake.xEnd > snake.xStart {
            appendMatch(&matches, MatchBlock(
                oldStart: aLo + snake.xStart,
                newStart: bLo + snake.yStart,
                length: snake.xEnd - snake.xStart
            ))
        }
        divide(a, aLo + snake.xEnd, aHi, b, bLo + snake.yEnd, bHi, &forward, &backward, half, &matches, budget)
    }

    if suffix > 0 {
        appendMatch(&matches, MatchBlock(oldStart: suffixOldStart, newStart: suffixNewStart, length: suffix))
    }
}

private func appendMatch(_ matches: inout [MatchBlock], _ block: MatchBlock) {
    if let last = matches.last,
       last.oldStart + last.length == block.oldStart,
       last.newStart + last.length == block.newStart {
        matches[matches.count - 1] = MatchBlock(
            oldStart: last.oldStart, newStart: last.newStart, length: last.length + block.length
        )
    } else {
        matches.append(block)
    }
}

private struct Snake {
    let xStart: Int
    let yStart: Int
    let xEnd: Int
    let yEnd: Int
}

private func middleSnake(
    _ a: UnsafeBufferPointer<UInt8>, _ aLo: Int, _ aHi: Int,
    _ b: UnsafeBufferPointer<UInt8>, _ bLo: Int, _ bHi: Int,
    _ forward: inout [Int], _ backward: inout [Int], _ half: Int, _ budget: WorkBudget
) -> Snake {
    let n = aHi - aLo
    let m = bHi - bLo
    let delta = n - m
    let deltaIsOdd = (delta & 1) != 0
    let maxD = (n + m + 1) / 2

    forward[half + 1] = 0
    backward[half + 1] = 0

    var d = 0
    while d <= maxD {
        budget.spend(4 * d + 2)
        if budget.exceeded { return Snake(xStart: 0, yStart: 0, xEnd: 0, yEnd: 0) }
        var k = -d
        while k <= d {
            var x: Int
            if k == -d || (k != d && forward[half + k - 1] < forward[half + k + 1]) {
                x = forward[half + k + 1]
            } else {
                x = forward[half + k - 1] + 1
            }
            var y = x - k
            let xStart = x, yStart = y
            while x < n, y < m, a[aLo + x] == b[bLo + y] {
                x += 1
                y += 1
            }
            forward[half + k] = x
            if deltaIsOdd, abs(delta - k) <= d - 1,
               x + backward[half + (delta - k)] >= n {
                return Snake(xStart: xStart, yStart: yStart, xEnd: x, yEnd: y)
            }
            k += 2
        }

        k = -d
        while k <= d {
            var x: Int
            if k == -d || (k != d && backward[half + k - 1] < backward[half + k + 1]) {
                x = backward[half + k + 1]
            } else {
                x = backward[half + k - 1] + 1
            }
            var y = x - k
            let xStart = x, yStart = y
            while x < n, y < m, a[aLo + n - x - 1] == b[bLo + m - y - 1] {
                x += 1
                y += 1
            }
            backward[half + k] = x
            if !deltaIsOdd, abs(delta - k) <= d,
               x + forward[half + (delta - k)] >= n {
                return Snake(xStart: n - x, yStart: m - y, xEnd: n - xStart, yEnd: m - yStart)
            }
            k += 2
        }

        d += 1
    }

    return Snake(xStart: n, yStart: m, xEnd: n, yEnd: m)
}
