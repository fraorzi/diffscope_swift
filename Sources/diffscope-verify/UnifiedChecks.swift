import DiffScopeEngine
import DiffScopeSyntax
import Foundation

/// DEC-096. The unified layout is a projection of a model that is already validated, so what these
/// check is not the invariants but the projection: that peeling a line off a block never loses a
/// stop, and that it refuses the lines it has to refuse.
func runUnifiedChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    func model(_ old: String, _ new: String) -> DiffModel {
        let a = [UInt8](old.utf8), b = [UInt8](new.utf8)
        guard let partitions = fallbackPartitions(oldBytes: a, newBytes: b) else {
            return trivialModel(oldBytes: a, newBytes: b)
        }
        return DiffModel(oldBytes: a, newBytes: b,
                         oldPartition: partitions.old, newPartition: partitions.new)
    }
    func blocks(_ old: String, _ new: String) -> [UnifiedBlock] {
        let m = model(old, new)
        return unifiedBlocks(m, stops: changeStops(m))
    }
    func text(_ source: String, _ from: Int, _ to: Int) -> String {
        String(decoding: [UInt8](source.utf8)[from..<to], as: UTF8.self)
    }

    print("\n=== DEC-096: byte-identical lines are peeled off a unified block ===")
    do {
        // The owner's case. A block inserted between a signature and a `return (`: the insertion
        // begins at the `\n` terminating the signature, so the snap pulls that whole line into the
        // block and it prints on both sides although nothing in it changed.
        let old = "function f({\n  a = 1,\n}: P) {\n  return (\n    <C>\n  );\n}\n"
        let new = "function f({\n  a = 1,\n}: P) {\n  const q = 2;\n\n  return (\n    <C>\n  );\n}\n"
        let result = blocks(old, new)
        report("the insertion is one block", result.count == 1, "\(result.count) blocks")
        guard let block = result.first else { return }
        report("the signature line is not printed as removed",
               !text(old, block.oldStart, block.oldEnd).contains("}: P) {"),
               text(old, block.oldStart, block.oldEnd))
        report("nor is the return that follows it",
               !text(new, block.newStart, block.newEnd).contains("return ("),
               text(new, block.newStart, block.newEnd))
        report("and what is left on the new side is exactly the two inserted lines",
               text(new, block.newStart, block.newEnd) == "  const q = 2;\n\n",
               text(new, block.newStart, block.newEnd))
        report("with nothing at all on the old side", block.oldEnd == block.oldStart,
               "\(block.oldEnd - block.oldStart) bytes")
    }

    print("\n=== and a line that really did change is still printed on both sides ===")
    do {
        // `<Container>` → `<Container className={…}>`. Byte-equality alone would be a rule that
        // gets the two lines above right and this one wrong.
        let old = "  return (\n    <C>\n      <D />\n"
        let new = "  return (\n    <C className='x'>\n      <D />\n"
        let result = blocks(old, new)
        report("a line a stop touches in its content is not peeled",
               result.count == 1 && result[0].oldEnd > result[0].oldStart
                   && text(old, result[0].oldStart, result[0].oldEnd).contains("<C>"),
               result.map { text(old, $0.oldStart, $0.oldEnd) }.joined(separator: " | "))
    }

    print("\n=== the empty-range branch, which is why a changed line is not an added one ===")
    do {
        // `7` → `77`. The insertion is a point inside a line, so that line has to be printed as
        // removed even though no byte of it was deleted, or there is nothing to compare against.
        let result = blocks("const value = 7;\n", "const value = 77;\n")
        report("an insertion inside a line still takes the whole line from the old side",
               result.count == 1 && text("const value = 7;\n", result[0].oldStart, result[0].oldEnd)
                   == "const value = 7;\n",
               result.map { "\($0.oldStart)..<\($0.oldEnd)" }.joined(separator: " "))
    }

    print("\n=== nothing is lost: every stop is still inside a block, on both sides ===")
    do {
        var contained = true
        var ordered = true
        var deterministic = true
        var lost: String?

        func check(_ name: String, _ m: DiffModel) {
            let stops = changeStops(m)
            let result = unifiedBlocks(m, stops: stops)
            if result != unifiedBlocks(m, stops: stops) { deterministic = false }
            for stop in stops {
                let inOld = result.contains { $0.oldStart <= stop.oldStart && $0.oldEnd >= stop.oldEnd }
                let inNew = result.contains { $0.newStart <= stop.newStart && $0.newEnd >= stop.newEnd }
                if !(inOld && inNew) {
                    contained = false
                    if lost == nil { lost = "\(name): \(stop.oldStart)..<\(stop.oldEnd)" }
                }
            }
            var oldCursor = 0, newCursor = 0
            for block in result {
                if block.oldStart < oldCursor || block.newStart < newCursor { ordered = false }
                oldCursor = block.oldEnd
                newCursor = block.newEnd
            }
        }

        let parser = TSXParser()
        for fixture in loadFixtures(root: URL(fileURLWithPath: "fixtures")) {
            let structural = structuralDiff(oldPath: fixture.oldPath, oldBytes: fixture.old,
                                            newPath: fixture.newPath, newBytes: fixture.new,
                                            parser: parser)
            check(fixture.name + " (structural)", structural.model)
            check(fixture.name + " (raw)", trivialModel(oldBytes: fixture.old, newBytes: fixture.new))
        }

        report("every stop lies inside a block on both sides, over all fixtures and both paths",
               contained, lost ?? "")
        report("blocks are in order and do not overlap", ordered)
        report("and the blocks are the same on a second call", deterministic)
    }

    print("\n=== a peeled line is byte-identical, asserted here rather than in the renderer ===")
    do {
        // The renderer's comparison would be over UTF-16 code units; this one is over the bytes the
        // invariant is stated on, which removes the question rather than answering it twice.
        var identical = true
        var offender: String?
        let parser = TSXParser()
        for fixture in loadFixtures(root: URL(fileURLWithPath: "fixtures")) {
            let m = structuralDiff(oldPath: fixture.oldPath, oldBytes: fixture.old,
                                   newPath: fixture.newPath, newBytes: fixture.new,
                                   parser: parser).model
            let stops = changeStops(m)
            let snapped = unifiedBlocks(m, stops: stops)
            // Anything a block dropped from its front must have been equal on both sides: compare
            // the bytes between the previous block's end and this one's start, side for side.
            var oldCursor = 0, newCursor = 0
            for block in snapped {
                let oldContext = Array(fixture.old[oldCursor..<block.oldStart])
                let newContext = Array(fixture.new[newCursor..<block.newStart])
                if oldContext != newContext {
                    identical = false
                    if offender == nil { offender = fixture.name }
                }
                oldCursor = block.oldEnd
                newCursor = block.newEnd
            }
        }
        report("the context between blocks is byte-equal on both sides", identical, offender ?? "")
    }
}
