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

    print("\n=== DEC-102: a rewrapped old half is withheld rather than printed twice ===")
    do {
        let parser = TSXParser()
        func blocks(_ old: String, _ new: String) -> ([UnifiedBlock], DiffModel) {
            let model = structuralDiff(oldPath: "a.tsx", oldBytes: [UInt8](old.utf8),
                                       newPath: "a.tsx", newBytes: [UInt8](new.utf8),
                                       parser: parser).model
            return (unifiedBlocks(model, stops: changeStops(model)), model)
        }

        // The owner's report: a prop added, the element rewrapped around it.
        let rewrapped = blocks(
            "      <Image src={hero} alt=\"Hero\" width={1200} priority />\n",
            "      <Image\n        src={hero}\n        alt=\"Hero\"\n        width={1200}\n"
                + "        priority\n        className=\"rounded\"\n      />\n").0
        report("a rewrap with a prop added is a reflowed block",
               rewrapped.contains { $0.reflowed },
               rewrapped.map { "\($0.oldStart)..<\($0.oldEnd) reflowed=\($0.reflowed)" }
                   .joined(separator: " "))

        // The negative control that matters most: a block that *removes* something is never
        // reflowed, however tidy the rest of it is. Withholding it would hide the removal, which is
        // the one thing a reviewer must see.
        let removal = blocks(
            "      <Image src={hero} alt=\"Hero\" priority />\n",
            "      <Image\n        src={hero}\n        alt=\"Hero\"\n      />\n").0
        report("negative control: a block that removes a token is never reflowed",
               removal.allSatisfy { !$0.reflowed },
               removal.map { "reflowed=\($0.reflowed)" }.joined(separator: " "))

        // A pure insertion has no old half to withhold, so an expander over it would open onto
        // nothing.
        let inserted = blocks("const a = 1;\n", "const a = 1;\nconst b = 2;\n").0
        report("a pure insertion is not a reflowed block",
               inserted.allSatisfy { !$0.reflowed })

        // A reorder is not a rewrap: the tokens are there, in another order, and the order is the
        // change. Subsequence in one direction is what refuses it.
        let reordered = blocks("<Field name=\"a\" required />\n",
                               "<Field required name=\"a\" />\n").0
        report("a reorder is not a reflowed block",
               reordered.allSatisfy { !$0.reflowed })

        // Every fixture: a reflowed block's old tokens really are on the new side, in order. The
        // property the withholding rests on, asserted rather than assumed.
        var offenders: [String] = []
        var found = 0
        for fixture in loadFixtures(root: URL(fileURLWithPath: "fixtures")) {
            let model = structuralDiff(oldPath: fixture.oldPath, oldBytes: fixture.old,
                                       newPath: fixture.newPath, newBytes: fixture.new,
                                       parser: parser).model
            let fixtureStops = changeStops(model)
            for block in unifiedBlocks(model, stops: fixtureStops) where block.reflowed {
                found += 1
                // Against the window the rule reads, not against the block: DEC-119 lets the walk
                // see one line of context past the block, and that line is printed directly below
                // it. "On screen" is the claim; the block was only ever a proxy for it.
                let windowEnd = withheldWindowEnd(new: fixture.new, block: block,
                                                  stops: fixtureStops)
                let oldTokens = layoutTokens(fixture.old[block.oldStart..<block.oldEnd])
                let newTokens = layoutTokens(fixture.new[block.newStart..<windowEnd])
                if !isTokenSubsequence(oldTokens, of: newTokens) { offenders.append(fixture.name) }
            }
        }
        report("over every fixture, a withheld half is on screen in the half that stays",
               offenders.isEmpty, offenders.isEmpty ? "\(found) reflowed blocks" : offenders.joined(separator: ", "))
    }

    print("\n=== DEC-108: withheld line by line, not half by half ===")
    do {
        let parser = TSXParser()
        // The owner's `<Heading>`: rewrapped, wrapped in a fragment, two class rules added — and one
        // line lost `as string`. DEC-102 refused the whole block for that one line, so the element
        // was printed twice.
        let old = "  <Heading\n    level={3}\n"
            + "    dangerouslySetInnerHTML={{ __html: title as string }}\n  />\n"
        let new = "  <>\n    <Heading\n      level={3}\n      className={clsx(styles.title)}\n"
            + "      dangerouslySetInnerHTML={{ __html: title }}\n    />\n  </>\n"
        let oldBytes = [UInt8](old.utf8), newBytes = [UInt8](new.utf8)
        let model = structuralDiff(oldPath: "a.tsx", oldBytes: oldBytes,
                                   newPath: "a.tsx", newBytes: newBytes, parser: parser).model
        let blocks = unifiedBlocks(model, stops: changeStops(model))
        let withheldText = blocks.flatMap { block in
            block.withheldOld.map { String(decoding: oldBytes[$0.start..<$0.end], as: UTF8.self) }
        }.joined()
        report("the rewrapped lines are withheld",
               withheldText.contains("<Heading") && withheldText.contains("/>"),
               withheldText.debugDescription)
        report("and the line that lost a token is kept",
               !withheldText.contains("as string"),
               withheldText.debugDescription)
        // The block that holds the removal withholds *part* of its old half and keeps the rest —
        // which is the whole of DEC-108. Its neighbour, a clean rewrap, is withheld entirely, and
        // that is DEC-102 still working.
        report("the block holding the removal keeps the line and withholds the others",
               blocks.contains { !$0.reflowed && !$0.withheldOld.isEmpty },
               blocks.map { "old \($0.oldStart)..<\($0.oldEnd) withheld \($0.withheldOld.count)" }
                   .joined(separator: " · "))

        // Order is what keeps it honest: the tokens of a shuffled block are all present on the other
        // side, and not in that order.
        let shuffledOld = "<Field\n  name=\"a\"\n  label=\"b\"\n/>\n"
        let shuffledNew = "<Field\n  label=\"b\"\n  name=\"a\"\n/>\n"
        let shuffled = structuralDiff(oldPath: "a.tsx", oldBytes: [UInt8](shuffledOld.utf8),
                                      newPath: "a.tsx", newBytes: [UInt8](shuffledNew.utf8),
                                      parser: parser).model
        let shuffledBlocks = unifiedBlocks(shuffled, stops: changeStops(shuffled))
        let shuffledWithheld = shuffledBlocks.flatMap { block in
            block.withheldOld.map { String(decoding: [UInt8](shuffledOld.utf8)[$0.start..<$0.end],
                                           as: UTF8.self) }
        }.joined()
        report("a line moved past another is not withheld",
               !shuffledWithheld.contains("name") || !shuffledWithheld.contains("label"),
               shuffledWithheld.debugDescription)

        // The property, over every fixture: what is withheld really is on the new side, in order.
        var offenders: [String] = []
        var withheldLines = 0
        for fixture in loadFixtures(root: URL(fileURLWithPath: "fixtures")) {
            let model = structuralDiff(oldPath: fixture.oldPath, oldBytes: fixture.old,
                                       newPath: fixture.newPath, newBytes: fixture.new,
                                       parser: parser).model
            let fixtureStops = changeStops(model)
            for block in unifiedBlocks(model, stops: fixtureStops) {
                guard !block.withheldOld.isEmpty else { continue }
                let hidden = block.withheldOld.flatMap { Array(fixture.old[$0.start..<$0.end]) }
                withheldLines += block.withheldOld.count
                let windowEnd = withheldWindowEnd(new: fixture.new, block: block,
                                                  stops: fixtureStops)
                if !isTokenSubsequence(layoutTokens(hidden[...]),
                                       of: layoutTokens(fixture.new[block.newStart..<windowEnd])) {
                    offenders.append(fixture.name)
                }
            }
        }
        report("over every fixture, what is withheld is on the new side in order",
               offenders.isEmpty,
               offenders.isEmpty ? "\(withheldLines) withheld runs" : offenders.joined(separator: ", "))
    }

    print("\n=== DEC-102: the flag reaches the renderer ===")
    do {
        let parser = TSXParser()
        // The engine's blocks were checked from the day the flag existed. The contract's were not,
        // and the projection into UTF-16 rebuilds every block by naming its fields — so the flag was
        // computed, asserted, and dropped one function before the window.
        let old = "      <NextImage src={img.src} alt={img.alt} priority />\n"
        let new = "      <NextImage\n        src={img.src}\n        alt={img.alt}\n"
            + "        priority\n        className=\"rounded\"\n      />\n"
        let result = structuralDiff(oldPath: "a.tsx", oldBytes: [UInt8](old.utf8),
                                    newPath: "a.tsx", newBytes: [UInt8](new.utf8), parser: parser)
        let engineBlocks = unifiedBlocks(result.model, stops: changeStops(result.model))
        let contract = buildRenderModel(model: result.model, pinOld: "a", pinNew: "b")
        report("the engine says this block is a rewrap",
               engineBlocks.contains { $0.reflowed })
        report("and the model the renderer receives says so too",
               contract.unifiedBlocks.contains { $0.reflowed },
               contract.unifiedBlocks.map { "\($0.oldStart)..<\($0.oldEnd) reflowed=\($0.reflowed)" }
                   .joined(separator: " "))
        report("the two agree block for block",
               engineBlocks.map { $0.reflowed } == contract.unifiedBlocks.map { $0.reflowed })
    }

    print("\n=== DEC-102: the layout withholds it and offers it back ===")
    do {
        // Two facts, not one `contains`: DEC-064's named failure mode is a check that keeps passing
        // because it only ever asked about the first of the things it cares about. A withheld half
        // with no way back is the failure this pair exists to catch.
        let source = (try? String(contentsOfFile: "Renderer/src/main.js", encoding: .utf8)) ?? ""
        report("the unified layout reads the withheld ranges",
               source.contains("block.withheldOld"))
        report("and the reader can bring the withheld half back",
               source.contains("function expandReflow") && source.contains("expandReflow(this.reflowIndex)"))
        report("and the header says how much is behind it",
               source.contains("lines not printed"))
    }

    print("\n=== DEC-119: a closing token on its own line does not print the element twice ===")
    do {
        // The owner's second report, reduced to one element. Prettier explodes the attributes and
        // puts `/>` on a line of its own; that line is unchanged, so it is outside every hunk and
        // outside the block, and the old line's `/` and `>` used to fall off the end of the walk.
        let old = [UInt8]("<Img src={a.src} alt=\"\" />\n".utf8)
        let new = [UInt8]("<Img\n  src={a.src}\n  loading=\"lazy\"\n  alt=\"\"\n/>\n".utf8)
        let model = trivialModel(oldBytes: old, newBytes: new)
        let stops = changeStops(model)
        let blocks = unifiedBlocks(model, stops: stops)

        report("the rewrapped element is one block", blocks.count == 1, "\(blocks.count) blocks")
        report("and its old half is withheld rather than printed beside its own rewrap",
               blocks.first?.reflowed == true)

        // The negative control: with no lookahead this is DEC-108's behaviour, and the element is
        // printed twice. Asserted rather than assumed, because the whole entry is the one line.
        if let block = blocks.first {
            report("control: with no lookahead the old half is kept",
                   withheldOldRanges(old: old, new: new, block: block,
                                     stops: stops, lookaheadLines: 0).isEmpty)
        } else {
            report("control: with no lookahead the old half is kept", false, "no block")
        }
    }

    print("\n=== DEC-119: the lookahead stops at the next change, and a removal stays visible ===")
    do {
        // The barrier, at the smallest scale that can express it. The old line's second token lives
        // only on the new side's second line; whether the walk may reach it is the whole rule.
        let old = [UInt8]("x y\n".utf8)
        let new = [UInt8]("x\ny\n".utf8)
        let block = UnifiedBlock(oldStart: 0, oldEnd: old.count, newStart: 0, newEnd: 2)

        report("context one line past the block is reachable",
               !withheldOldRanges(old: old, new: new, block: block, stops: []).isEmpty)
        report("but a line the next change touches is not",
               withheldOldRanges(old: old, new: new, block: block,
                                 stops: [ChangeStop(oldStart: 0, oldEnd: 0,
                                                    newStart: 2, newEnd: 4)]).isEmpty)

        // And the property that matters more than either: a line that was genuinely removed beside
        // a rewrap is still kept, so the reader still sees the removal.
        let oldPair = [UInt8]("const x = foo(a);\nafter();\nafter();\n".utf8)
        let newPair = [UInt8]("const x = foo(\n  a,\n);\nafter();\n".utf8)
        let model = trivialModel(oldBytes: oldPair, newBytes: newPair)
        let pairStops = changeStops(model)
        let withheld = unifiedBlocks(model, stops: pairStops).flatMap(\.withheldOld)
        let removedLineStart = 18   // the second `after();`, which is the one that went
        // And the bound, over every fixture, so the window cannot quietly grow: whatever the walk
        // reads past a block is at most `reflowLookaheadLines` line terminators further on.
        var overshoot: [String] = []
        let parser = TSXParser()
        for fixture in loadFixtures(root: URL(fileURLWithPath: "fixtures")) {
            let fixtureModel = structuralDiff(oldPath: fixture.oldPath, oldBytes: fixture.old,
                                              newPath: fixture.newPath, newBytes: fixture.new,
                                              parser: parser).model
            let fixtureStops = changeStops(fixtureModel)
            for block in unifiedBlocks(fixtureModel, stops: fixtureStops) {
                let windowEnd = withheldWindowEnd(new: fixture.new, block: block,
                                                  stops: fixtureStops)
                let crossed = fixture.new[block.newEnd..<windowEnd].filter { $0 == 0x0A }.count
                if crossed > reflowLookaheadLines { overshoot.append(fixture.name) }
            }
        }
        report("the window never reaches further than the bound allows", overshoot.isEmpty,
               overshoot.joined(separator: ", "))

        report("a removed line beside a rewrap is not withheld",
               !withheld.contains { $0.start <= removedLineStart && $0.end > removedLineStart },
               withheld.map { "\($0.start)..<\($0.end)" }.joined(separator: ","))
    }
}
