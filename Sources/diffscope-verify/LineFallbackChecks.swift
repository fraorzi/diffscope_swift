import DiffScopeEngine
import Foundation

/// DEC-105 — the fallback path localises by line when the byte diff cannot answer at all.
func runLineFallbackChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    print("\n=== DEC-105: a file the byte diff gives up on is still localised ===")

    // A translation file: many similar lines, a handful edited. The shape the corpus found, at a size
    // that exhausts a small budget without taking a minute to build.
    func messages(_ edits: Set<Int>) -> [UInt8] {
        var text = "{\n"
        for index in 0..<900 {
            // The edited strings are long and unlike the originals, which is what actually exhausts
            // the byte budget: Myers' work grows with the *edit distance*, so a hundred rewritten
            // sentences cost far more than a hundred rewritten words.
            let value = edits.contains(index)
                ? "Zupełnie inne zdanie, przetłumaczone od nowa dla klucza numer \(index)"
                : "Krótka wartość \(index)"
            text += "  \"key\(index)\": \"\(value)\",\n"
        }
        text += "}\n"
        return [UInt8](text.utf8)
    }
    // Scattered edits rather than three: what exhausts the byte budget is the *number of separate
    // differences*, not the size of the file, which is why a 40 KB translation file reaches this path
    // and a 400 KB one with a single edit does not.
    let edits = Set(stride(from: 3, to: 900, by: 6))
    let old = messages([])
    let new = messages(edits)

    // The budget is set to what the shipped fallback path allows, so this is the shipped behaviour
    // rather than a construction that only fails in a test.
    guard case .budgetExceeded = canonicalDiff(old: old, new: new,
                                               workBudget: fallbackDiffWorkBudget) else {
        report("the byte diff gives up on this pair, as the corpus says it does", false,
               "it finished — the fixture no longer reproduces the case")
        return
    }
    report("the byte diff gives up on this pair, as the corpus says it does", true)

    guard let partitions = fallbackPartitions(oldBytes: old, newBytes: new) else {
        report("the line fallback answers where the byte diff did not", false, "returned nil")
        return
    }
    report("the line fallback answers where the byte diff did not", true)

    let marked = Set(changedLines(bytes: new, partition: partitions.new))
    // Line 1 is `{`, so key *n* sits on line *n + 2*.
    let expected = Set(edits.map { $0 + 2 })
    report("it marks every line that changed", expected.isSubset(of: marked),
           "\(expected.subtracting(marked).count) of \(expected.count) left unmarked")
    report("and few that did not", marked.count <= expected.count + 8,
           "\(marked.count) of 902 lines marked, against \(expected.count) edited")

    // The negative control, and it is the behaviour this entry replaces: without the line pass the
    // answer is the whole file.
    let control = fallbackPartitions(oldBytes: old, newBytes: new, lineFallback: false)
    report("negative control: without it the whole file is the answer", control == nil)

    // The property that makes the pass safe to run where nothing can be verified: the parts it calls
    // unchanged are byte-equal on the two sides, in order. A pairing that hid a change would fail it.
    func unchangedText(_ bytes: [UInt8], _ partition: Partition) -> [UInt8] {
        partition.segments.filter { $0.label == .unchanged }
            .flatMap { Array(bytes[$0.start..<$0.end]) }
    }
    report("what it calls unchanged is byte-equal on both sides",
           unchangedText(old, partitions.old) == unchangedText(new, partitions.new))

    // And the same property over pairs it has never seen, including insertions, deletions and
    // reorderings of similar lines — the case where a line-level pairing is most likely to cross.
    var generator = SystemRandomNumberGenerator()
    var failures = 0
    for _ in 0..<60 {
        var lines = (0..<80).map { "line \($0 % 20)\n" }
        var edited = lines
        for _ in 0..<Int.random(in: 1...10, using: &generator) {
            let at = Int.random(in: 0..<edited.count, using: &generator)
            switch Int.random(in: 0...2, using: &generator) {
            case 0: edited[at] = "edited \(Int.random(in: 0...999, using: &generator))\n"
            case 1: edited.insert("inserted\n", at: at)
            default: edited.remove(at: at)
            }
        }
        lines.append("tail\n")
        edited.append("tail\n")
        let a = [UInt8](lines.joined().utf8)
        let b = [UInt8](edited.joined().utf8)
        guard let hunks = lineAnchoredHunks(old: a, new: b) else { continue }
        var oldKept: [UInt8] = []
        var newKept: [UInt8] = []
        var oldCursor = 0, newCursor = 0
        for hunk in hunks {
            oldKept += a[oldCursor..<hunk.oldStart]
            newKept += b[newCursor..<hunk.newStart]
            oldCursor = hunk.oldEnd
            newCursor = hunk.newEnd
        }
        oldKept += a[oldCursor...]
        newKept += b[newCursor...]
        if oldKept != newKept { failures += 1 }
    }
    report("over 60 random line edits, what it leaves unmarked is identical on both sides",
           failures == 0, failures == 0 ? "" : "\(failures) pairs disagreed")
}
