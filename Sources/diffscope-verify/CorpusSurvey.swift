import DiffScopeEngine
import DiffScopeSyntax
import Foundation

/// What the presentation does wrong, counted over thousands of real changes rather than argued
/// about on one.
///
/// `measure-alignment.sh` measures the working tree of one repository against `git diff -U0`, which
/// is how M11 was steered — and it can only ever see the change that happens to be uncommitted. The
/// owner's report ("the same `<Image>` line is printed twice because a prop was added and prettier
/// reflowed it") is not about one file: it is a *shape* of change that recurs across every Next.js
/// repository they have. A fix aimed at one file is a fix nobody can tell from a coincidence.
///
/// So this reads a corpus built by `Scripts/devtools/build-corpus.sh` — one directory per
/// (before, after) pair extracted from real history, with the line numbers `git diff -U0` touches —
/// runs the shipped pipeline over all of it, and reports two things:
///
/// - **the metrics M11 already steers on**, summed: false lines, missed lines, marks, presented
///   bytes, lines the unified view prints twice;
/// - **a taxonomy**: named shapes of wrong presentation, each with the number of pairs it occurs in,
///   the number of instances, and the worst offenders by name, so a fix can be aimed at the shape
///   that occurs most rather than the one that was reported most recently.
///
/// The JSON it writes is the point of the whole thing: two runs of this tool are directly
/// comparable, so a change to the engine is answerable with *what moved, across 1400 changes* and
/// not with *it looks better on the file I was staring at*.
func runCorpusSurvey(root: String, jsonOut: String?, limit: Int?, only: String?,
                     settings: MatcherSettings = MatcherSettings()) {
    let fm = FileManager.default
    var pairs: [CorpusPair] = []
    let rootURL = URL(fileURLWithPath: root)
    guard let walker = fm.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
        print("no such corpus: \(root)")
        exit(1)
    }
    for case let url as URL in walker where url.lastPathComponent == "meta.json" {
        guard let pair = CorpusPair(metaURL: url) else { continue }
        if let only, !pair.meta.repo.contains(only), !pair.meta.path.contains(only) { continue }
        pairs.append(pair)
    }
    pairs.sort { ($0.meta.repo, $0.meta.commit, $0.meta.path) < ($1.meta.repo, $1.meta.commit, $1.meta.path) }
    if let limit, pairs.count > limit { pairs = Array(pairs.prefix(limit)) }

    guard !pairs.isEmpty else {
        print("no pairs under \(root) — run Scripts/devtools/build-corpus.sh first")
        exit(1)
    }

    let parser = TSXParser()
    var results: [PairMeasurement] = []
    results.reserveCapacity(pairs.count)
    let started = Date()
    for (index, pair) in pairs.enumerated() {
        if index % 100 == 0 {
            FileHandle.standardError.write(Data("  \(index)/\(pairs.count)\n".utf8))
        }
        results.append(measure(pair: pair, parser: parser, settings: settings))
    }
    let elapsed = Date().timeIntervalSince(started)

    report(results, elapsed: elapsed, settingsLine:
           "snap=\(settings.boundarySnapBudget) word=\(settings.wordSnapBudget)"
           + " merge=\(settings.mergeSplitMarksInWords ? 1 : 0)"
           + " reabsorb=\(settings.absorbAfterWidening ? 1 : 0)"
           + " island=\(settings.absorbIslandBytes)")
    if let jsonOut { writeSurveyJSON(results, to: jsonOut) }
}

// MARK: - the corpus on disk

struct CorpusMeta: Codable {
    let repo: String
    let commit: String
    let path: String
    let ext: String
    let beforeBytes: Int
    let afterBytes: Int
    let gitOldLines: [Int]
    let gitNewLines: [Int]
}

struct CorpusPair {
    let meta: CorpusMeta
    let old: [UInt8]
    let new: [UInt8]

    init?(metaURL: URL) {
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(CorpusMeta.self, from: data)
        else { return nil }
        let directory = metaURL.deletingLastPathComponent()
        guard let before = try? Data(contentsOf: directory.appendingPathComponent("before.\(meta.ext)")),
              let after = try? Data(contentsOf: directory.appendingPathComponent("after.\(meta.ext)"))
        else { return nil }
        self.meta = meta
        self.old = [UInt8](before)
        self.new = [UInt8](after)
    }
}

// MARK: - what one pair measures

/// The named shapes. Each is a claim about the *presentation* that a reader would call wrong, and
/// each is counted rather than described, so the list can be ranked.
enum WrongShape: String, CaseIterable, Codable {
    /// The old pane says nothing about a line git says was removed. The reflow case's signature.
    case silentOldSide = "silent-old-side"
    /// A block whose old tokens are a subsequence of its new tokens: content kept, layout redone,
    /// something inserted. This is the owner's `<Image className=…>` report, stated generally.
    case reflowInsertion = "reflow-insertion"
    /// The same, with the token sequences *equal*: pure reflow, nothing added or removed.
    case reflowOnly = "reflow-only"
    /// A line that is byte-identical on both sides and printed twice by the unified view.
    case duplicatedLine = "duplicated-line"
    /// A mark that starts or ends inside a word whose other half is **not** marked, so the reader is
    /// shown `bg-o⟦pacity-30⟧` over a class name they have to reassemble themselves.
    case shreddedWord = "shredded-word"
    /// Two presented segments that touch and were still drawn as two marks — `⟦t⟧⟦ransition⟧`. The
    /// bytes are all presented, so nothing is missing; what is wrong is the number of edges.
    case splitMark = "split-mark"
    /// A mark whose bytes are entirely whitespace, and which is not labelled formatting.
    case whitespaceOnlyMark = "whitespace-only-mark"
    /// An unchanged island of one or two bytes left standing between two marks — absorption's floor
    /// is 8, so what survives here is a gap the relative rule refused.
    case microIsland = "micro-island"
    /// More than two marks per changed line: confetti, whatever produced it.
    case markConfetti = "mark-confetti"
    /// The structural path was not taken at all.
    case wholeFileFallback = "whole-file-fallback"
    /// A block whose old half is the new half laid out differently, which the unified layout may
    /// withhold (DEC-102). Counted so the two shapes above can be read as *what is still printed
    /// twice* rather than as *what the byte diff produced*.
    case reflowedBlock = "reflowed-block"
}

struct PairMeasurement: Codable {
    let repo: String
    let commit: String
    let path: String
    let structural: Bool
    let gitOldLines: Int
    let gitNewLines: Int
    let modelOldLines: Int
    let modelNewLines: Int
    /// A line the model marks on the new side that git says is untouched.
    let falseLines: Int
    /// A line git removes that the old side does not mark.
    let missedLines: Int
    let marks: Int
    let presentedBytes: Int
    /// Marks the interface draws as uncertain, and the bytes under them. `reconcile` gives a byte the
    /// canonical mask claims but no anchor explains a confidence of 0.6, and the floor is 0.8 — so
    /// this counts how often the window says *this attribution is doubtful*. A flag that fires on a
    /// third of everything is not a flag.
    let uncertainMarks: Int
    let uncertainBytes: Int
    /// Why a junction between two touching marks was not merged, and why a short unchanged island
    /// between two marks was not absorbed. Both are refusals with reasons, and the reasons are what
    /// says which rule to look at next.
    let junctionReasons: [String: Int]
    let islandReasons: [String: Int]
    /// Why a line that is byte-identical on both sides is printed twice anyway. DEC-096's peel takes
    /// the ones it can; this says what the rest are, so the next entry aims at a shape rather than at
    /// a number.
    let duplicateReasons: [String: Int]
    /// Presented bytes drawn at full weight — everything the `formatting-only` group does not hold.
    /// The number DEC-101 exists to move: a rewrapped element should cost the reader one loud mark
    /// on what changed and quiet ones on the rewrap.
    let loudBytes: Int
    let shapes: [String: Int]

    func count(_ shape: WrongShape) -> Int { shapes[shape.rawValue] ?? 0 }
}

private func measure(pair: CorpusPair, parser: TSXParser?,
                     settings: MatcherSettings) -> PairMeasurement {
    let result = structuralDiff(oldPath: pair.meta.path, oldBytes: pair.old,
                                newPath: pair.meta.path, newBytes: pair.new,
                                parser: parser, settings: settings)
    let model = result.model
    let oldLines = Set(changedLines(bytes: pair.old, partition: model.oldPartition))
    let newLines = Set(changedLines(bytes: pair.new, partition: model.newPartition))
    let gitOld = Set(pair.meta.gitOldLines)
    let gitNew = Set(pair.meta.gitNewLines)

    var shapes: [String: Int] = [:]
    func add(_ shape: WrongShape, _ n: Int = 1) {
        guard n > 0 else { return }
        shapes[shape.rawValue, default: 0] += n
    }

    if result.stats.usedFallback { add(.wholeFileFallback) }

    let marks = model.oldPartition.segments.filter(\.isPresented).count
        + model.newPartition.segments.filter(\.isPresented).count
    let presentedBytes = model.oldPartition.segments.filter(\.isPresented).reduce(0) { $0 + $1.length }
        + model.newPartition.segments.filter(\.isPresented).reduce(0) { $0 + $1.length }
    func loud(_ partition: Partition) -> Int {
        partition.segments.filter {
            $0.isPresented
                && classificationGroup(of: $0.classification) != ClassificationGroup.formattingOnly.rawValue
        }.reduce(0) { $0 + $1.length }
    }
    let loudBytes = loud(model.oldPartition) + loud(model.newPartition)

    func uncertain(_ partition: Partition) -> (marks: Int, bytes: Int) {
        let below = partition.segments.filter { $0.isPresented && ($0.confidence ?? 1) < confidenceFloor }
        return (below.count, below.reduce(0) { $0 + $1.length })
    }
    let uncertainOld = uncertain(model.oldPartition)
    let uncertainNew = uncertain(model.newPartition)

    var junctionReasons: [String: Int] = [:]
    var islandReasons: [String: Int] = [:]
    for (partition, bytes) in [(model.oldPartition, pair.old), (model.newPartition, pair.new)] {
        let segments = partition.segments
        for index in 1..<max(1, segments.count) where index < segments.count {
            let left = segments[index - 1]
            let right = segments[index]
            guard left.isPresented, right.isPresented, left.end == right.start else { continue }
            let reason: String
            if left.disclosure != right.disclosure { reason = "disclosure" }
            else if left.link != right.link { reason = "link" }
            else if ((left.confidence ?? 1) < confidenceFloor) != ((right.confidence ?? 1) < confidenceFloor) {
                reason = "crosses-the-floor"
            } else if left.label != right.label { reason = "label" }
            else { reason = "other" }
            junctionReasons[reason, default: 0] += 1
        }
        // Why a one- or two-byte unchanged island survived absorption. Recomputed from the finished
        // partition rather than instrumented inside the pass, so it says what the reader is left
        // with rather than what the pass was thinking.
        for index in 1..<max(1, segments.count - 1) where index + 1 < segments.count {
            let island = segments[index]
            let before = segments[index - 1]
            let after = segments[index + 1]
            guard island.label == .unchanged, island.length <= 2,
                  before.isPresented, after.isPresented else { continue }
            let reason: String
            if before.label != after.label || before.disclosure != after.disclosure
                || before.link != after.link
                || ((before.confidence ?? 1) < confidenceFloor) != ((after.confidence ?? 1) < confidenceFloor) {
                reason = "flanks-disagree"
            } else if island.length > min(before.length, after.length) {
                reason = "longer-than-a-flank"
            } else if touchesAnUnmarkedLine(island: island, before: before, after: after, bytes: bytes) {
                reason = "would-add-a-line"
            } else {
                reason = "unexplained"
            }
            islandReasons[reason, default: 0] += 1
        }
    }

    add(.shreddedWord, shreddedWordCount(bytes: pair.old, partition: model.oldPartition)
        + shreddedWordCount(bytes: pair.new, partition: model.newPartition))
    add(.splitMark, splitMarkCount(model.oldPartition) + splitMarkCount(model.newPartition))
    add(.whitespaceOnlyMark, whitespaceOnlyMarkCount(bytes: pair.old, partition: model.oldPartition)
        + whitespaceOnlyMarkCount(bytes: pair.new, partition: model.newPartition))
    add(.microIsland, microIslandCount(model.oldPartition) + microIslandCount(model.newPartition))

    let stops = changeStops(model)
    let blocks = unifiedBlocks(model, stops: stops)
    var duplicated = 0
    var reflowInsertions = 0
    var reflowOnly = 0
    var silent = 0
    var reflowedBlocks = 0
    var duplicateReasons: [String: Int] = [:]
    for block in blocks {
        let oldSlice = Array(pair.old[safe: block.oldStart..<block.oldEnd])
        let newSlice = Array(pair.new[safe: block.newStart..<block.newEnd])
        // Withheld lines print nothing, so they can duplicate nothing and be silent about nothing.
        // The shapes below count what the reader is actually shown: the old half minus what the
        // layout holds back (DEC-108).
        if block.reflowed {
            reflowedBlocks += 1
            continue
        }
        if !block.withheldOld.isEmpty { reflowedBlocks += 1 }
        let shownOld = block.withheldOld.isEmpty
            ? oldSlice
            : { () -> [UInt8] in
                var kept: [UInt8] = []
                var cursor = block.oldStart
                for range in block.withheldOld {
                    kept += pair.old[safe: cursor..<range.start]
                    cursor = range.end
                }
                kept += pair.old[safe: cursor..<block.oldEnd]
                return kept
            }()
        let (count, reasons) = duplicatedLineBreakdown(
            old: pair.old, new: pair.new, block: block, stops: stops, shownOld: shownOld)
        duplicated += count
        for (key, value) in reasons { duplicateReasons[key, default: 0] += value }

        let oldTokens = tokens(of: oldSlice)
        let newTokens = tokens(of: newSlice)
        if !oldSlice.isEmpty, !newSlice.isEmpty, oldSlice != newSlice {
            if oldTokens == newTokens {
                reflowOnly += 1
            } else if isSubsequence(oldTokens, of: newTokens) {
                reflowInsertions += 1
            }
        }

        // The pane is silent when the block still prints old lines and no mark falls inside them.
        if !shownOld.isEmpty, block.oldEnd > block.oldStart,
           !model.oldPartition.segments.contains(where: {
               $0.isPresented && $0.start < block.oldEnd && $0.end > block.oldStart
           }) {
            silent += 1
        }
    }
    add(.reflowedBlock, reflowedBlocks)
    add(.duplicatedLine, duplicated)
    add(.reflowInsertion, reflowInsertions)
    add(.reflowOnly, reflowOnly)
    add(.silentOldSide, silent)

    let changed = max(1, oldLines.count + newLines.count)
    if marks > 2 * changed { add(.markConfetti) }

    return PairMeasurement(
        repo: pair.meta.repo, commit: String(pair.meta.commit.prefix(12)), path: pair.meta.path,
        structural: !result.stats.usedFallback,
        gitOldLines: gitOld.count, gitNewLines: gitNew.count,
        modelOldLines: oldLines.count, modelNewLines: newLines.count,
        falseLines: newLines.subtracting(gitNew).count,
        missedLines: gitOld.subtracting(oldLines).count,
        marks: marks, presentedBytes: presentedBytes,
        uncertainMarks: uncertainOld.marks + uncertainNew.marks,
        uncertainBytes: uncertainOld.bytes + uncertainNew.bytes,
        junctionReasons: junctionReasons, islandReasons: islandReasons,
        duplicateReasons: duplicateReasons,
        loudBytes: loudBytes, shapes: shapes
    )
}

// MARK: - the detectors

private func isWordByte(_ byte: UInt8) -> Bool {
    (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
        || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte == 0x24 || byte >= 0x80
}

private func isSpaceByte(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
}

/// A word cut in half by an edge, counted only where the **other half is unmarked**.
///
/// The first draft of this detector counted every edge falling inside a word, and it reported 742
/// instances on 250 pairs — most of them `⟦t⟧⟦ransition⟧`, where both halves are presented and the
/// only fault is that two marks say what one could. That is a different defect with a different fix,
/// so it is counted separately as `split-mark`. Measure the control before believing the check.
private func shreddedWordCount(bytes: [UInt8], partition: Partition) -> Int {
    var count = 0
    for (index, segment) in partition.segments.enumerated() where segment.isPresented && segment.length > 0 {
        let start = segment.start
        let end = segment.end
        let previousPresented = index > 0 && partition.segments[index - 1].isPresented
            && partition.segments[index - 1].end == start
        let nextPresented = index + 1 < partition.segments.count && partition.segments[index + 1].isPresented
            && partition.segments[index + 1].start == end
        if start > 0, !previousPresented, isWordByte(bytes[start - 1]), isWordByte(bytes[start]) { count += 1 }
        if end < bytes.count, !nextPresented, isWordByte(bytes[end - 1]), isWordByte(bytes[end]) { count += 1 }
    }
    return count
}

/// Absorption's fourth condition, asked backwards: is there a line the island touches that carries
/// no presented byte from either flank? That is the rule that makes absorption unable to add a line
/// to `changedLines`, and it is the one a reader cannot see the effect of.
private func touchesAnUnmarkedLine(island: Segment, before: Segment, after: Segment,
                                   bytes: [UInt8]) -> Bool {
    func line(_ offset: Int) -> Int {
        var count = 0
        var index = 0
        while index < offset, index < bytes.count {
            if bytes[index] == 0x0A { count += 1 }
            index += 1
        }
        return count
    }
    let first = line(island.start)
    let last = line(max(island.start, island.end - 1))
    guard first != last || true else { return false }
    let markedFirst = line(max(0, before.end - 1))
    let markedLast = line(after.start)
    return first < markedFirst || last > markedLast
}

private func splitMarkCount(_ partition: Partition) -> Int {
    var count = 0
    for index in 1..<max(1, partition.segments.count) where index < partition.segments.count {
        let previous = partition.segments[index - 1]
        let segment = partition.segments[index]
        if previous.isPresented, segment.isPresented, previous.end == segment.start { count += 1 }
    }
    return count
}

private func whitespaceOnlyMarkCount(bytes: [UInt8], partition: Partition) -> Int {
    partition.segments.filter { segment in
        segment.isPresented && segment.length > 0
            && segment.classification == nil
            && bytes[segment.start..<segment.end].allSatisfy(isSpaceByte)
    }.count
}

private func microIslandCount(_ partition: Partition) -> Int {
    var count = 0
    for index in 1..<max(1, partition.segments.count - 1) where index + 1 < partition.segments.count {
        let island = partition.segments[index]
        guard island.label == .unchanged, island.length <= 2,
              partition.segments[index - 1].isPresented,
              partition.segments[index + 1].isPresented
        else { continue }
        count += 1
    }
    return count
}

/// Which byte-identical lines a block prints twice, and why each one survived DEC-096's peel.
///
/// - `stop-covers-it` — a change stop covers bytes of the line, so peeling it would drop a stop out
///   of the block, which is the property DEC-096 asserts over every fixture.
/// - `out-of-order` — the identical line exists on the other side at a different position: the two
///   copies are not a pair the peel could take, because taking them would reorder the block.
/// - `at-the-edge` — neither, which means the peel should have taken it and did not.
private func duplicatedLineBreakdown(old: [UInt8], new: [UInt8], block: UnifiedBlock,
                                     stops: [ChangeStop], shownOld: [UInt8]) -> (Int, [String: Int]) {
    // Only the old lines the layout still prints can be printed twice.
    let withheldBytes = Set(block.withheldOld.flatMap { Array($0.start..<$0.end) })
    let oldLines = lineRanges(old, from: block.oldStart, to: block.oldEnd)
        .filter { !withheldBytes.contains($0.start) }
    let newLines = lineRanges(new, from: block.newStart, to: block.newEnd)
    guard !oldLines.isEmpty, !newLines.isEmpty else { return (0, [:]) }

    func covered(_ range: (start: Int, end: Int), _ from: (ChangeStop) -> Int,
                 _ to: (ChangeStop) -> Int) -> Bool {
        stops.contains { to($0) > from($0) && from($0) < range.end && to($0) > range.start }
    }

    var reasons: [String: Int] = [:]
    var count = 0
    var taken = Set<Int>()
    for (oldIndex, oldRange) in oldLines.enumerated() {
        let text = Array(old[oldRange.start..<oldRange.end])
        guard !text.allSatisfy(isSpaceByte) else { continue }
        guard let newIndex = newLines.indices.first(where: {
            !taken.contains($0) && Array(new[newLines[$0].start..<newLines[$0].end]) == text
        }) else { continue }
        taken.insert(newIndex)
        count += 1
        let newRange = newLines[newIndex]
        if covered(oldRange, { $0.oldStart }, { $0.oldEnd })
            || covered(newRange, { $0.newStart }, { $0.newEnd }) {
            reasons["stop-covers-it", default: 0] += 1
        } else if oldIndex != newIndex {
            reasons["out-of-order", default: 0] += 1
        } else {
            reasons["at-the-edge", default: 0] += 1
        }
    }
    return (count, reasons)
}

/// Whole lines, terminator included, inside a byte range.
private func lineRanges(_ bytes: [UInt8], from: Int, to: Int) -> [(start: Int, end: Int)] {
    var out: [(start: Int, end: Int)] = []
    var start = max(0, from)
    let limit = min(to, bytes.count)
    while start < limit {
        var end = start
        while end < limit, bytes[end] != 0x0A { end += 1 }
        if end < limit { end += 1 }
        out.append((start, end))
        start = end
    }
    return out
}

private func duplicatedLineCount(old: [UInt8], new: [UInt8]) -> Int {
    let oldLines = splitLines(old).lines
    let newLines = splitLines(new).lines
    guard !oldLines.isEmpty, !newLines.isEmpty else { return 0 }
    var remaining = newLines
    var count = 0
    for line in oldLines {
        guard !line.allSatisfy(isSpaceByte) else { continue }
        if let hit = remaining.firstIndex(of: line) {
            remaining.remove(at: hit)
            count += 1
        }
    }
    return count
}

/// Words, numbers, strings and punctuation, with every run of whitespace dropped.
///
/// The point of dropping whitespace is the whole question this survey exists to ask: when prettier
/// rewraps a JSX element, *the tokens do not change* — only where the line breaks fall. A tokenizer
/// this crude is enough to say so, and being crude is what makes it safe to run over 1400 files
/// without a parse.
func tokens(of bytes: [UInt8]) -> [[UInt8]] {
    var out: [[UInt8]] = []
    var index = 0
    while index < bytes.count {
        let byte = bytes[index]
        if isSpaceByte(byte) {
            index += 1
        } else if isWordByte(byte) {
            var end = index
            while end < bytes.count, isWordByte(bytes[end]) { end += 1 }
            out.append(Array(bytes[index..<end]))
            index = end
        } else {
            out.append([byte])
            index += 1
        }
    }
    return out
}

func isSubsequence(_ needle: [[UInt8]], of haystack: [[UInt8]]) -> Bool {
    guard needle.count <= haystack.count else { return false }
    var cursor = 0
    for token in haystack where cursor < needle.count {
        if token == needle[cursor] { cursor += 1 }
    }
    return cursor == needle.count
}

private extension Array where Element == UInt8 {
    subscript(safe range: Range<Int>) -> ArraySlice<UInt8> {
        let lower = Swift.max(0, Swift.min(range.lowerBound, count))
        let upper = Swift.max(lower, Swift.min(range.upperBound, count))
        return self[lower..<upper]
    }
}

// MARK: - reporting

private func report(_ results: [PairMeasurement], elapsed: TimeInterval, settingsLine: String) {
    let structural = results.filter(\.structural).count
    print("")
    print("=== corpus survey: \(results.count) pairs, \(structural) structural, "
        + String(format: "%.1f s", elapsed) + " ===")
    print("  settings: \(settingsLine)")
    print("")

    let falseLines = results.reduce(0) { $0 + $1.falseLines }
    let missed = results.reduce(0) { $0 + $1.missedLines }
    let marks = results.reduce(0) { $0 + $1.marks }
    let bytes = results.reduce(0) { $0 + $1.presentedBytes }
    let gitOld = results.reduce(0) { $0 + $1.gitOldLines }
    let gitNew = results.reduce(0) { $0 + $1.gitNewLines }
    print(String(format: "  git lines            −%d  +%d", gitOld, gitNew))
    print(String(format: "  false lines          %d  (%.1f%% of + lines)", falseLines,
                 gitNew == 0 ? 0 : 100 * Double(falseLines) / Double(gitNew)))
    print(String(format: "  missed lines         %d  (%.1f%% of − lines)", missed,
                 gitOld == 0 ? 0 : 100 * Double(missed) / Double(gitOld)))
    print("  marks                \(marks)")
    print("  presented bytes      \(bytes)")
    let uncertainMarks = results.reduce(0) { $0 + $1.uncertainMarks }
    let uncertainBytes = results.reduce(0) { $0 + $1.uncertainBytes }
    print(String(format: "  uncertain marks      %d  (%.1f%% of marks, %.1f%% of presented bytes)",
                 uncertainMarks,
                 marks == 0 ? 0 : 100 * Double(uncertainMarks) / Double(marks),
                 bytes == 0 ? 0 : 100 * Double(uncertainBytes) / Double(bytes)))
    let loud = results.reduce(0) { $0 + $1.loudBytes }
    print(String(format: "  loud bytes           %d  (%.1f%% of presented)", loud,
                 bytes == 0 ? 0 : 100 * Double(loud) / Double(bytes)))
    print("")
    print("  shape                     pairs   instances   share of pairs")
    for shape in WrongShape.allCases {
        let affected = results.filter { $0.count(shape) > 0 }
        let instances = results.reduce(0) { $0 + $1.count(shape) }
        let name = shape.rawValue.padding(toLength: 24, withPad: " ", startingAt: 0)
        print("  \(name)" + String(format: "%6d %11d %13.1f%%", affected.count, instances,
                                   100 * Double(affected.count) / Double(results.count)))
    }

    print("")
    var junctions: [String: Int] = [:]
    var islands: [String: Int] = [:]
    for row in results {
        for (key, count) in row.junctionReasons { junctions[key, default: 0] += count }
        for (key, count) in row.islandReasons { islands[key, default: 0] += count }
    }
    print("  why two touching marks stayed two:")
    for (key, count) in junctions.sorted(by: { $0.value > $1.value }) {
        print("    \(count)  \(key)")
    }
    var duplicates: [String: Int] = [:]
    for row in results {
        for (key, count) in row.duplicateReasons { duplicates[key, default: 0] += count }
    }
    print("  why a byte-identical line is printed twice:")
    for (key, count) in duplicates.sorted(by: { $0.value > $1.value }) {
        print("    \(count)  \(key)")
    }
    print("  why a short island survived absorption:")
    for (key, count) in islands.sorted(by: { $0.value > $1.value }) {
        print("    \(count)  \(key)")
    }

    print("")
    for shape in [WrongShape.reflowInsertion, .silentOldSide, .duplicatedLine, .shreddedWord] {
        let worst = results.filter { $0.count(shape) > 0 }
            .sorted { $0.count(shape) > $1.count(shape) }
            .prefix(5)
        guard !worst.isEmpty else { continue }
        print("  worst for \(shape.rawValue):")
        for row in worst {
            print(String(format: "    %3d  ", row.count(shape)) + "\(row.repo) \(row.commit) \(row.path)")
        }
    }
}

private func writeSurveyJSON(_ results: [PairMeasurement], to path: String) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(results) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
    print("\n  written \(path)")
}
