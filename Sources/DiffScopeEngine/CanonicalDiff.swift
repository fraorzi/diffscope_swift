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

public func canonicalMatches(
    old: [UInt8],
    new: [UInt8],
    workBudget: Int = defaultCanonicalDiffWorkBudget
) -> (matches: [MatchBlock], exceededBudget: Bool, workUsed: Int) {
    var matches: [MatchBlock] = []
    let half = (old.count + new.count + 1) / 2 + 1
    var forward = [Int](repeating: 0, count: 2 * half + 2)
    var backward = [Int](repeating: 0, count: 2 * half + 2)
    let budget = WorkBudget(limit: workBudget)
    old.withUnsafeBufferPointer { a in
        new.withUnsafeBufferPointer { b in
            divide(a, 0, a.count, b, 0, b.count, &forward, &backward, half, &matches, budget)
            if !budget.exceeded {
                matches = shiftToLineBoundaries(matches, old: a, new: b)
            }
        }
    }
    return (matches, budget.exceeded, budget.used)
}

/// Moves each hunk along the file, while the alignment stays equally minimal, to the position where
/// it covers a whole number of lines (DEC-087).
///
/// Myers does not select a unique alignment. Where several are equally short it picks arbitrarily,
/// and the arbitrary one is usually the one that begins mid-line: an insertion before
/// `import ButtonLink …` anchors after the shared word `import `, so an untouched line reads as
/// removed-and-re-added, and an insertion before `  text: string;` anchors after the shared indent,
/// so the highlight lands on the *next* line's whitespace.
///
/// **This is not the sliding DEC-047 refused.** That objection was against moving the presentation
/// while `D` stood still, which fails a validator recomputing `D`. Here `D` itself moves, inside the
/// one function both the model and `Validation` call, so containment holds byte for byte.
///
/// A shift moves the boundary between a hunk and each of its neighbouring matches by the same
/// amount, so **the total matched length is invariant** and the result is still minimal — the
/// property `diffscope-verify` already asserts against a brute-force LCS on random pairs.
///
/// **The boundary set is `0x0A` and nothing else.** Snapping to tokens or tree nodes would fix more
/// and would make `D` depend on a parse that can fail, at which point the independent check is no
/// longer independent of the thing it checks.
func shiftToLineBoundaries(
    _ matches: [MatchBlock],
    old: UnsafeBufferPointer<UInt8>,
    new: UnsafeBufferPointer<UInt8>
) -> [MatchBlock] {
    guard matches.count > 1 else { return matches }
    var blocks = matches

    // A range is whole-line when it begins at a line start and ends at one. An empty range is a
    // point, and a point is aligned when it sits at a line start.
    @inline(__always)
    func aligned(_ buffer: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Bool {
        guard start == 0 || buffer[start - 1] == 0x0A else { return false }
        return end == start || end == 0 || buffer[end - 1] == 0x0A
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

        // Neither neighbouring match may be consumed: a match shrinking to nothing merges two hunks
        // into one, which is a different edit script rather than the same one written down better.
        var best: Int?
        var shift = 0
        while shift + 1 < current.length,
              stepHolds(old, oldStart + shift, oldEnd + shift, down: true),
              stepHolds(new, newStart + shift, newEnd + shift, down: true) {
            shift += 1
            if aligned(old, oldStart + shift, oldEnd + shift),
               aligned(new, newStart + shift, newEnd + shift) {
                best = shift
            }
        }
        // The furthest position down the file wins, so the upward search only runs when the
        // downward one found nothing, and stops at the first candidate it reaches.
        if best == nil {
            shift = 0
            while -shift + 1 < previous.length,
                  stepHolds(old, oldStart + shift, oldEnd + shift, down: false),
                  stepHolds(new, newStart + shift, newEnd + shift, down: false) {
                shift -= 1
                if aligned(old, oldStart + shift, oldEnd + shift),
                   aligned(new, newStart + shift, newEnd + shift) {
                    best = shift
                    break
                }
            }
        }
        // No reachable position covers whole lines: the alignment stays exactly where Myers put it,
        // and no boundary is invented.
        guard let chosen = best, chosen != 0 else { continue }

        blocks[index - 1] = MatchBlock(oldStart: previous.oldStart, newStart: previous.newStart,
                                       length: previous.length + chosen)
        blocks[index] = MatchBlock(oldStart: current.oldStart + chosen,
                                   newStart: current.newStart + chosen,
                                   length: current.length - chosen)
    }
    return blocks
}

public func canonicalDiff(
    old: [UInt8],
    new: [UInt8],
    workBudget: Int = defaultCanonicalDiffWorkBudget
) -> CanonicalDiffOutcome {
    let result = canonicalMatches(old: old, new: new, workBudget: workBudget)
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
