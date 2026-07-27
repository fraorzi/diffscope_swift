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
        }
    }
    return (matches, budget.exceeded, budget.used)
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
