import Foundation

/// Line-level machinery for partial staging (DEC-092, M12).
///
/// The engine's own diff is over **bytes** (DEC-024, DEC-039) and stays that way. Staging is a
/// different question: `git apply` speaks unified diffs, whose unit is a line, and the reader
/// selects lines. So this file computes a *line* walk of the same two sides and emits a patch from
/// it — and, crucially, it also computes **what the result should be** without going through the
/// patch at all (`applySelection`). Those two paths are independent, which is what makes INV-6
/// checkable: apply the patch, read the bytes back, and compare against a result the patch had no
/// hand in producing.
///
/// Nothing here decides *what* to stage. It turns a selection into bytes, and a selection into a
/// patch, and lets the check assert that git agreed with both.

/// A file split the way a unified diff splits it: content lines without their terminator, plus
/// whether the file ended with one.
///
/// The final-newline flag is not decoration. `a\n` and `a` have the same single line and are
/// different files, and a diff that called those lines equal would emit a patch that silently adds
/// or removes a byte nobody selected. `lineKeys` therefore gives the unterminated last line a key
/// no terminated line can have.
public struct SourceLines: Sendable, Equatable {
    public let lines: [[UInt8]]
    public let endsWithNewline: Bool

    public var count: Int { lines.count }

    public init(lines: [[UInt8]], endsWithNewline: Bool) {
        self.lines = lines
        self.endsWithNewline = endsWithNewline
    }

    /// True when `index` is the last line and the file does not end with a newline — the condition
    /// `\ No newline at end of file` reports.
    public func isUnterminated(_ index: Int) -> Bool {
        !endsWithNewline && index == lines.count - 1
    }
}

public func splitLines(_ bytes: [UInt8]) -> SourceLines {
    if bytes.isEmpty { return SourceLines(lines: [], endsWithNewline: true) }
    var lines: [[UInt8]] = []
    var current: [UInt8] = []
    for byte in bytes {
        if byte == 0x0A {
            lines.append(current)
            current = []
        } else {
            current.append(byte)
        }
    }
    let endsWithNewline = current.isEmpty
    if !endsWithNewline { lines.append(current) }
    return SourceLines(lines: lines, endsWithNewline: endsWithNewline)
}

public func joinLines(_ source: SourceLines) -> [UInt8] {
    var bytes: [UInt8] = []
    for (index, line) in source.lines.enumerated() {
        bytes.append(contentsOf: line)
        if index < source.lines.count - 1 || source.endsWithNewline { bytes.append(0x0A) }
    }
    return bytes
}

/// One position in the merged walk of the two files. `index` addresses the side the step belongs
/// to; a context step carries both, because a patch has to number both margins.
public enum WalkStep: Sendable, Equatable {
    case context(old: Int, new: Int)
    case removal(old: Int)
    case addition(new: Int)

    public var isChange: Bool {
        if case .context = self { return false }
        return true
    }
}

public enum StagingWalkOutcome: Sendable, Equatable {
    case exact([WalkStep])
    /// The two sides are too far apart for a line alignment inside the budget. Whole-file staging
    /// still works; line and hunk selection do not, and the interface has to say so rather than
    /// offer a selection it cannot honour.
    case budgetExceeded(cells: Int)
}

/// Cells of the alignment table this is willing to fill. Sized so the table itself stays inside a
/// few megabytes; a pair that needs more is a pair no reader is picking lines out of anyway.
public let defaultStagingWalkBudget = 8_000_000

/// The line walk of two sides.
///
/// Common leading and trailing lines are stripped first — the part that is actually aligned is the
/// churn between them, which is small in every realistic case — and the middle is aligned by a
/// plain longest-common-subsequence table. A table is used rather than the engine's Myers because
/// this path writes to someone's index: the simplest algorithm that is obviously right is worth
/// more here than the fastest one, and the budget keeps the cost bounded.
public func stagingWalk(old: SourceLines, new: SourceLines,
                        budget: Int = defaultStagingWalkBudget) -> StagingWalkOutcome {
    let oldKeys = lineKeys(old)
    let newKeys = lineKeys(new)

    var prefix = 0
    while prefix < oldKeys.count, prefix < newKeys.count, oldKeys[prefix] == newKeys[prefix] {
        prefix += 1
    }
    var suffix = 0
    while suffix < oldKeys.count - prefix, suffix < newKeys.count - prefix,
          oldKeys[oldKeys.count - 1 - suffix] == newKeys[newKeys.count - 1 - suffix] {
        suffix += 1
    }

    let oldMiddle = Array(oldKeys[prefix..<(oldKeys.count - suffix)])
    let newMiddle = Array(newKeys[prefix..<(newKeys.count - suffix)])
    let cells = (oldMiddle.count + 1) * (newMiddle.count + 1)
    if cells > budget { return .budgetExceeded(cells: cells) }

    var steps: [WalkStep] = []
    for offset in 0..<prefix { steps.append(.context(old: offset, new: offset)) }
    steps.append(contentsOf: alignMiddle(oldMiddle, newMiddle, oldOffset: prefix, newOffset: prefix))
    for offset in 0..<suffix {
        steps.append(.context(old: oldKeys.count - suffix + offset,
                              new: newKeys.count - suffix + offset))
    }
    return .exact(steps)
}

/// A key per line that distinguishes an unterminated last line from an identical terminated one.
private func lineKeys(_ source: SourceLines) -> [LineKey] {
    source.lines.enumerated().map { LineKey(bytes: $0.element, unterminated: source.isUnterminated($0.offset)) }
}

private struct LineKey: Hashable {
    let bytes: [UInt8]
    let unterminated: Bool
}

private func alignMiddle(_ old: [LineKey], _ new: [LineKey],
                         oldOffset: Int, newOffset: Int) -> [WalkStep] {
    if old.isEmpty && new.isEmpty { return [] }
    if old.isEmpty { return (0..<new.count).map { .addition(new: newOffset + $0) } }
    if new.isEmpty { return (0..<old.count).map { .removal(old: oldOffset + $0) } }

    let rows = old.count + 1
    let columns = new.count + 1
    var table = [Int32](repeating: 0, count: rows * columns)
    for i in stride(from: old.count - 1, through: 0, by: -1) {
        for j in stride(from: new.count - 1, through: 0, by: -1) {
            let here = i * columns + j
            if old[i] == new[j] {
                table[here] = table[here + columns + 1] + 1
            } else {
                table[here] = max(table[here + columns], table[here + 1])
            }
        }
    }

    var steps: [WalkStep] = []
    var i = 0, j = 0
    while i < old.count, j < new.count {
        if old[i] == new[j] {
            steps.append(.context(old: oldOffset + i, new: newOffset + j))
            i += 1; j += 1
        } else if table[(i + 1) * columns + j] >= table[i * columns + (j + 1)] {
            // A removal is emitted before an addition at the same position, so a replaced line
            // reads `-old` then `+new` the way every diff in the world writes it.
            steps.append(.removal(old: oldOffset + i))
            i += 1
        } else {
            steps.append(.addition(new: newOffset + j))
            j += 1
        }
    }
    while i < old.count { steps.append(.removal(old: oldOffset + i)); i += 1 }
    while j < new.count { steps.append(.addition(new: newOffset + j)); j += 1 }
    return steps
}

/// The changes of one hunk: the run of changed steps the given **new-side line** falls in or
/// nearest to, with the context between them.
///
/// This is what *stage this hunk* means, and it is computed from the walk rather than from a patch
/// so that the same selection can be turned into bytes by `applySelection` — which is what makes a
/// hunk staged from the keyboard as checkable as a line staged by clicking.
public func hunkSelection(walk: [WalkStep], aroundNewLine line: Int) -> Set<Int> {
    let changes = walk.indices.filter { walk[$0].isChange }
    guard !changes.isEmpty else { return [] }

    // Runs of changes separated by at least one context step. A hunk is what a reader sees as one
    // block, which is exactly that.
    var runs: [[Int]] = []
    for position in changes {
        if let last = runs.last?.last, walk[(last + 1)..<position].allSatisfy({ !$0.isChange }),
           position - last <= 1 {
            runs[runs.count - 1].append(position)
        } else if let last = runs.last?.last, position - last == 1 {
            runs[runs.count - 1].append(position)
        } else {
            runs.append([position])
        }
    }

    /// The new-side line each step sits at, so *the cursor is here* can be answered.
    func newLine(of position: Int) -> Int {
        switch walk[position] {
        case let .context(_, new): return new
        case let .addition(new): return new
        case let .removal:
            // A removal has no new-side line of its own; it belongs to the line it was removed
            // before, which is the next new-side line in the walk.
            for later in (position + 1)..<walk.count {
                if case let .context(_, new) = walk[later] { return new }
                if case let .addition(new) = walk[later] { return new }
            }
            return Int.max
        }
    }

    let target = line - 1
    var best = runs[0]
    var bestDistance = Int.max
    for run in runs {
        let first = newLine(of: run[0])
        let last = newLine(of: run[run.count - 1])
        let distance = target < first ? first - target : (target > last ? target - last : 0)
        if distance < bestDistance { bestDistance = distance; best = run }
        if distance == 0 { break }
    }
    return Set(best)
}

/// The bytes that result from taking **only** the selected steps.
///
/// Computed from the walk and the two files directly, with no patch anywhere in it. This is the
/// independent side of INV-6: the check applies the patch through git and compares what git
/// produced against what this returned.
public func applySelection(old: SourceLines, new: SourceLines,
                           walk: [WalkStep], selection: Set<Int>) -> [UInt8] {
    var lines: [[UInt8]] = []
    var endsWithNewline = true
    var lastWasUnterminated = false
    for (position, step) in walk.enumerated() {
        switch step {
        case let .context(oldIndex, _):
            lines.append(old.lines[oldIndex])
            lastWasUnterminated = old.isUnterminated(oldIndex)
        case let .removal(oldIndex):
            if selection.contains(position) { continue }
            lines.append(old.lines[oldIndex])
            lastWasUnterminated = old.isUnterminated(oldIndex)
        case let .addition(newIndex):
            guard selection.contains(position) else { continue }
            lines.append(new.lines[newIndex])
            lastWasUnterminated = new.isUnterminated(newIndex)
        }
    }
    endsWithNewline = !lastWasUnterminated
    return joinLines(SourceLines(lines: lines, endsWithNewline: endsWithNewline))
}

/// How many unchanged lines surround a change in an emitted patch. Three is what every tool emits
/// and what `git apply` is most forgiving about.
public let stagingPatchContext = 3

/// A unified diff carrying exactly the selected steps.
///
/// - a selected removal is `-`; an **unselected** removal is context, because it stays on both sides
///   — unless taking it as context would move `\ No newline at end of file`, which is the rule
///   spelled out in the body
/// - a selected addition is `+`; an unselected addition is omitted entirely, because it exists only
///   on the new side and is not being taken
///
/// Returns `nil` when nothing is selected: a patch with no changes in it is not an empty patch,
/// it is a patch `git apply` rejects.
public func stagingPatch(path: String, originalPath: String? = nil,
                         old: SourceLines, new: SourceLines,
                         walk: [WalkStep], selection: Set<Int>,
                         context: Int = stagingPatchContext) -> String? {
    // Every step, reduced to the line it contributes to the patch.
    enum Emitted {
        case context([UInt8], unterminated: Bool)
        case removed([UInt8], unterminated: Bool)
        case added([UInt8], unterminated: Bool)
        case dropped
    }

    var emitted: [Emitted] = []
    for (position, step) in walk.enumerated() {
        switch step {
        case let .context(oldIndex, _):
            emitted.append(.context(old.lines[oldIndex], unterminated: old.isUnterminated(oldIndex)))
        case let .removal(oldIndex):
            emitted.append(selection.contains(position)
                ? .removed(old.lines[oldIndex], unterminated: old.isUnterminated(oldIndex))
                : .context(old.lines[oldIndex], unterminated: old.isUnterminated(oldIndex)))
        case let .addition(newIndex):
            emitted.append(selection.contains(position)
                ? .added(new.lines[newIndex], unterminated: new.isUnterminated(newIndex))
                : .dropped)
        }
    }

    // **`\ No newline at end of file` describes the end of a *side*, not the end of a line.**
    //
    // An unterminated last line is only ever the last line of the side it belongs to, so the marker
    // is well formed after a `-` (the old side ends here, unterminated) or after a `+` (the new side
    // does). After a ` ` it is a claim about **both** sides at once — and that is the case this
    // function used to get wrong.
    //
    // `unterminated` on a context line is read from the *old* side alone. When the new side carries
    // on past that line, the line is not the same on both sides at all: the old file has `beta`, the
    // new file has `beta\n`. Emitting it as context with the marker produced
    //
    //     @@ -1,2 +1,3 @@
    //      alpha
    //      beta
    //     \ No newline at end of file
    //     +gamma
    //
    // which `git apply` **accepts**, and which merges two lines: the index became `alpha\nbetagamma\n`.
    // A byte nobody selected was destroyed, and `applySelection` — the independent side of INV-6 —
    // disagreed. The existing edge arm never saw it because it selects every change, which is the
    // one selection that happens to be well formed.
    //
    // So the terminator change is stated the way git states it: the line is removed unterminated and
    // re-added terminated. That is not optional and is not part of the reader's selection — taking
    // any later addition forces it, which is why it is synthesised here rather than offered.
    var lastNewSideIndex = -1
    for index in emitted.indices {
        switch emitted[index] {
        case .context, .added: lastNewSideIndex = index
        case .removed, .dropped: break
        }
    }
    if emitted.indices.contains(where: {
        if case let .context(_, unterminated) = emitted[$0] { return unterminated && $0 < lastNewSideIndex }
        return false
    }) {
        var repaired: [Emitted] = []
        repaired.reserveCapacity(emitted.count + 1)
        for index in emitted.indices {
            if case let .context(line, unterminated) = emitted[index],
               unterminated, index < lastNewSideIndex {
                repaired.append(.removed(line, unterminated: true))
                repaired.append(.added(line, unterminated: false))
            } else {
                repaired.append(emitted[index])
            }
        }
        emitted = repaired
    }

    let changed = emitted.indices.filter {
        if case .context = emitted[$0] { return false }
        if case .dropped = emitted[$0] { return false }
        return true
    }
    guard !changed.isEmpty else { return nil }

    // Runs of changes, each grown by `context` lines of unchanged text and merged where they touch.
    var groups: [(start: Int, end: Int)] = []
    for index in changed {
        var start = index, end = index
        var seen = 0
        while start > 0, seen < context {
            start -= 1
            if case .context = emitted[start] { seen += 1 } else if case .dropped = emitted[start] {} else { seen = 0 }
        }
        seen = 0
        while end + 1 < emitted.count, seen < context {
            end += 1
            if case .context = emitted[end] { seen += 1 } else if case .dropped = emitted[end] {} else { seen = 0 }
        }
        if let last = groups.last, start <= last.end + 1 {
            groups[groups.count - 1] = (last.start, max(last.end, end))
        } else {
            groups.append((start, end))
        }
    }

    // Line numbers are 1-based and count only the lines each side actually has.
    var oldLineAt = [Int](repeating: 0, count: emitted.count + 1)
    var newLineAt = [Int](repeating: 0, count: emitted.count + 1)
    var oldCursor = 1, newCursor = 1
    for index in emitted.indices {
        oldLineAt[index] = oldCursor
        newLineAt[index] = newCursor
        switch emitted[index] {
        case .context: oldCursor += 1; newCursor += 1
        case .removed: oldCursor += 1
        case .added: newCursor += 1
        case .dropped: break
        }
    }
    oldLineAt[emitted.count] = oldCursor
    newLineAt[emitted.count] = newCursor

    let oldName = originalPath ?? path
    var text = "diff --git a/\(quotePath(oldName)) b/\(quotePath(path))\n"
    text += "--- a/\(quotePath(oldName))\n"
    text += "+++ b/\(quotePath(path))\n"

    for group in groups {
        var body = ""
        var oldCount = 0, newCount = 0
        for index in group.start...group.end {
            switch emitted[index] {
            case let .context(line, unterminated):
                body += " " + string(line) + "\n"
                if unterminated { body += "\\ No newline at end of file\n" }
                oldCount += 1; newCount += 1
            case let .removed(line, unterminated):
                body += "-" + string(line) + "\n"
                if unterminated { body += "\\ No newline at end of file\n" }
                oldCount += 1
            case let .added(line, unterminated):
                body += "+" + string(line) + "\n"
                if unterminated { body += "\\ No newline at end of file\n" }
                newCount += 1
            case .dropped:
                break
            }
        }
        guard oldCount > 0 || newCount > 0 else { continue }
        let oldStart = oldCount == 0 ? oldLineAt[group.start] - 1 : oldLineAt[group.start]
        let newStart = newCount == 0 ? newLineAt[group.start] - 1 : newLineAt[group.start]
        text += "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n"
        text += body
    }
    return text
}

/// Bytes back to the string a patch is made of. The content is not required to be UTF-8 — a diff is
/// a byte stream — so anything unconvertible is preserved through the Latin-1 round trip that
/// `patchData` reverses exactly.
private func string(_ line: [UInt8]) -> String {
    String(line.map { Character(UnicodeScalar($0)) })
}

/// The patch as the bytes to hand git, undoing the round trip `string(_:)` makes.
public func patchData(_ patch: String) -> Data {
    var bytes: [UInt8] = []
    for scalar in patch.unicodeScalars {
        if scalar.value < 256 { bytes.append(UInt8(scalar.value)) } else {
            bytes.append(contentsOf: Array(String(scalar).utf8))
        }
    }
    return Data(bytes)
}

/// git quotes a path in a diff header only when it has to; a path with a space in it is written
/// plainly, and one with a quote or a backslash is C-quoted. Emitting the plain form for the
/// characters that need no quoting keeps the header identical to git's own.
private func quotePath(_ path: String) -> String {
    let needsQuoting = path.unicodeScalars.contains { $0 == "\"" || $0 == "\\" || $0.value < 0x20 }
    guard needsQuoting else { return path }
    var out = "\""
    for scalar in path.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        default:
            if scalar.value < 0x20 { out += String(format: "\\%03o", scalar.value) } else { out.unicodeScalars.append(scalar) }
        }
    }
    return out + "\""
}
