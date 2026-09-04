import DiffScopeEngine
import DiffScopeSyntax
import Foundation

/// DEC-094. Absorption is the one pass in the pipeline whose whole purpose is to present *more* than
/// the diff found, so the properties that matter are the ones bounding how much more: it may never
/// remove a byte from the presented set, it may never add a line to `changedLines`, and it must stop
/// where the rules say rather than where the picture looks tidiest.
func runAbsorptionChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    func presented(_ partition: Partition) -> Set<Int> {
        var bytes = Set<Int>()
        for segment in partition.segments where segment.isPresented {
            for offset in segment.start..<segment.end { bytes.insert(offset) }
        }
        return bytes
    }
    func cuts(_ partition: Partition) -> Set<Int> {
        Set(partition.segments.map(\.start)).union(partition.segments.map(\.end))
    }
    // One line, so no island can ever be refused by the no-new-line rule and the other rules are
    // what is being read.
    func line(_ count: Int) -> [UInt8] { [UInt8](repeating: 0x61, count: count) }

    print("\n=== DEC-094: absorbing a short unchanged island ===")
    do {
        let shredded = Partition(totalLength: 41, segments: [
            Segment(start: 0, end: 20, label: .changed, confidence: 1),
            Segment(start: 20, end: 21, label: .unchanged, confidence: 1),
            Segment(start: 21, end: 41, label: .changed, confidence: 1),
        ])
        let absorbed = absorbIslands(shredded, bytes: line(41))
        report("a one-byte island between two long changes is absorbed",
               absorbed.segments.allSatisfy { $0.label == .changed },
               absorbed.segments.map { "\($0.start)..<\($0.end) \($0.label.rawValue)" }.joined(separator: " "))
        report("and coalescing then draws the run as one mark",
               coalesceAdjacent(absorbed).segments.count == 1)
        report("the presented set grew rather than moved",
               presented(absorbed).isSuperset(of: presented(shredded))
                   && presented(absorbed).count == presented(shredded).count + 1)
        report("the cut points are a subset of the input's — the pass only ever merges",
               cuts(absorbed).isSubset(of: cuts(shredded)))
        report("reconstruction is untouched",
               reconstruct(absorbed, from: line(41)) == reconstruct(shredded, from: line(41)))
        report("the partition is still well formed", partitionDefects(absorbed).isEmpty,
               partitionDefects(absorbed).map(\.description).joined(separator: "; "))
        report("absorbing twice changes nothing",
               absorbIslands(absorbed, bytes: line(41)).segments == absorbed.segments)
    }

    print("\n=== and the four conditions that refuse it ===")
    do {
        func island(_ length: Int, flank: Int = 20, mutate: (Segment) -> Segment = { $0 })
            -> (before: Partition, after: Partition) {
            let total = flank * 2 + length
            let before = Partition(totalLength: total, segments: [
                mutate(Segment(start: 0, end: flank, label: .changed, confidence: 1)),
                Segment(start: flank, end: flank + length, label: .unchanged, confidence: 1),
                Segment(start: flank + length, end: total, label: .changed, confidence: 1),
            ])
            return (before, absorbIslands(before, bytes: line(total)))
        }
        func absorbed(_ pair: (before: Partition, after: Partition)) -> Bool {
            pair.after.segments.allSatisfy { $0.label == .changed }
        }

        report("an island at the floor is absorbed", absorbed(island(absorbIslandBytes)))
        report("negative control: one byte over the floor is not",
               !absorbed(island(absorbIslandBytes + 1)))
        report("a 6-byte island between two 3-byte edits is real context, and survives",
               !absorbed(island(6, flank: 3)))
        report("a trailing gap after the last change is not an island",
               absorbIslands(Partition(totalLength: 24, segments: [
                   Segment(start: 0, end: 20, label: .changed, confidence: 1),
                   Segment(start: 20, end: 24, label: .unchanged, confidence: 1),
               ]), bytes: line(24)).segments.count == 2)
        // DEC-038: a move's two ranges must stay byte-identical, and the two sides are absorbed
        // independently. T-11 found this by failing on 192 disagreements; the rule is a refusal
        // rather than a guard, because one that holds only when the sides happen to agree is not one.
        let moved = Partition(totalLength: 42, segments: [
            Segment(start: 0, end: 20, label: .moved, confidence: 1, link: 0),
            Segment(start: 20, end: 22, label: .unchanged, confidence: 1),
            Segment(start: 22, end: 42, label: .moved, confidence: 1, link: 0),
        ])
        report("a move is never widened, even between two halves of the same one",
               absorbIslands(moved, bytes: line(42)).segments == moved.segments)
        report("flanks on opposite sides of the confidence floor refuse too",
               !absorbed(island(2, mutate: { Segment(start: $0.start, end: $0.end, label: .changed,
                                                     confidence: 0.6) })))
        report("negative control: with the floor at zero the pass is the identity",
               absorbIslands(island(2).before, bytes: line(44),
                             settings: AbsorptionSettings(islandBytes: 0)).segments
                   == island(2).before.segments)
    }

    print("\n=== the no-new-line rule, which is a theorem and not a preference ===")
    do {
        // `aaa\nbbb\nccc` — a change on line 1, an island covering the whole of line 2, a change on
        // line 3. Absorbing would put a mark on a line that carried none.
        let bytes = [UInt8]("aaa\nbbb\nccc".utf8)
        let straddling = Partition(totalLength: bytes.count, segments: [
            Segment(start: 0, end: 3, label: .changed, confidence: 1),
            Segment(start: 3, end: 8, label: .unchanged, confidence: 1),
            Segment(start: 8, end: 11, label: .changed, confidence: 1),
        ])
        report("an island holding a line of its own is refused",
               absorbIslands(straddling, bytes: bytes).segments == straddling.segments)

        // The same shape, but both flanks already reach into the middle line, so absorbing adds no
        // line. This is the confetti case: an island may span a newline, into lines already marked.
        let reaching = Partition(totalLength: bytes.count, segments: [
            Segment(start: 0, end: 5, label: .changed, confidence: 1),
            Segment(start: 5, end: 6, label: .unchanged, confidence: 1),
            Segment(start: 6, end: 11, label: .changed, confidence: 1),
        ])
        report("but one inside lines its flanks already mark is absorbed",
               absorbIslands(reaching, bytes: bytes).segments.allSatisfy { $0.label == .changed })
    }

    print("\n=== a long alternation cannot swallow its context whole ===")
    do {
        // The reason there is no per-run allowance: the relative rule already bounds the total. A
        // cap would be a knob that can never turn, and this repository has three of those on record.
        // Twenty one-byte changes separated by two-byte islands: the islands are wider than their
        // flanks, so every one of them is refused.
        var wide: [Segment] = []
        var offset = 0
        for index in 0..<20 {
            wide.append(Segment(start: offset, end: offset + 1, label: .changed, confidence: 1))
            offset += 1
            if index < 19 {
                wide.append(Segment(start: offset, end: offset + 2, label: .unchanged, confidence: 1))
                offset += 2
            }
        }
        let alternating = Partition(totalLength: offset, segments: wide)
        report("islands wider than their flanks are all refused",
               absorbIslands(alternating, bytes: line(offset)).segments == alternating.segments)

        // And where they are not wider, the bound is what makes a cap unnecessary: absorbed bytes
        // are strictly fewer than the run's own changed bytes, whatever the floor.
        var generator = SystemRandomNumberGenerator()
        var bounded = true
        for _ in 0..<200 {
            var segments: [Segment] = []
            var at = 0
            var changed = true
            while at < 200 {
                let length = Int.random(in: 1...10, using: &generator)
                segments.append(Segment(start: at, end: at + length,
                                        label: changed ? .changed : .unchanged, confidence: 1))
                at += length
                changed.toggle()
            }
            if segments.last?.label == .changed {
                segments.append(Segment(start: at, end: at + 3, label: .unchanged, confidence: 1))
                at += 3
            }
            let before = Partition(totalLength: at, segments: segments)
            let after = absorbIslands(before, bytes: line(at),
                                      settings: AbsorptionSettings(islandBytes: 1_000))
            let changedBytes = segments.filter(\.isPresented).reduce(0) { $0 + $1.length }
            if presented(after).count - presented(before).count >= changedBytes { bounded = false }
        }
        report("absorbed bytes stay strictly below the run's own changed bytes, at any floor", bounded)
    }

    print("\n=== the properties, over every fixture and over random partitions ===")
    do {
        var monotone = true
        var linesHeld = true
        var wellFormed = true
        var reconstructed = true
        var idempotent = true

        func check(_ partition: Partition, _ bytes: [UInt8]) {
            let after = absorbIslands(partition, bytes: bytes)
            if !presented(after).isSuperset(of: presented(partition)) { monotone = false }
            if changedLines(bytes: bytes, partition: after)
                != changedLines(bytes: bytes, partition: partition) { linesHeld = false }
            if !partitionDefects(after).isEmpty { wellFormed = false }
            if reconstruct(after, from: bytes) != bytes { reconstructed = false }
            if absorbIslands(after, bytes: bytes).segments != after.segments { idempotent = false }
        }

        let parser = TSXParser()
        for fixture in loadFixtures(root: URL(fileURLWithPath: "fixtures")) {
            let result = structuralDiff(oldPath: fixture.oldPath, oldBytes: fixture.old,
                                        newPath: fixture.newPath, newBytes: fixture.new,
                                        parser: parser)
            check(result.model.oldPartition, fixture.old)
            check(result.model.newPartition, fixture.new)
        }

        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let bytes = [UInt8](String((0..<Int.random(in: 4...120, using: &generator)).map { _ in
                Array("ab\n;x").randomElement(using: &generator)!
            }).utf8)
            var segments: [Segment] = []
            var offset = 0
            var changed = Bool.random(using: &generator)
            while offset < bytes.count {
                let length = min(Int.random(in: 1...12, using: &generator), bytes.count - offset)
                segments.append(Segment(start: offset, end: offset + length,
                                        label: changed ? .changed : .unchanged, confidence: 1))
                offset += length
                changed.toggle()
            }
            check(Partition(totalLength: bytes.count, segments: segments), bytes)
        }

        report("absorption never removes a byte from the presented set", monotone)
        report("and never adds a line to the ones reported changed", linesHeld)
        report("the partition stays well formed", wellFormed)
        report("both sides still reconstruct byte for byte", reconstructed)
        report("and the pass is idempotent", idempotent)
    }

    print("\n=== DEC-117: a line break moving does not swallow the code it moved around ===")
    do {
        // The shape the owner reported, reduced to one line. A rewrap puts indentation either side
        // of an identifier nobody touched; the two marks are pure layout and the island is a word.
        let bytes = [UInt8]("foo(\n                  locale,\n                  bar)".utf8)
        let indentOne = 4..<23      // a newline and eighteen spaces — a real rewrap's indent
        let word = 23..<29             // "locale"
        let indentTwo = 29..<49      // a comma, a newline and eighteen spaces
        let partition = Partition(totalLength: bytes.count, segments: [
            Segment(start: 0, end: 4, label: .unchanged, confidence: 1),
            Segment(start: indentOne.lowerBound, end: indentOne.upperBound, label: .changed,
                    classification: ChangeClass.whitespace.rawValue, confidence: 0.8),
            Segment(start: word.lowerBound, end: word.upperBound, label: .unchanged, confidence: 1),
            Segment(start: indentTwo.lowerBound, end: indentTwo.upperBound, label: .changed,
                    classification: ChangeClass.whitespace.rawValue, confidence: 0.8),
            Segment(start: 49, end: bytes.count, label: .unchanged, confidence: 1),
        ])

        func wordIsPresented(_ settings: AbsorptionSettings) -> Bool {
            absorbIslands(partition, bytes: bytes, settings: settings).segments
                .contains { $0.isPresented && $0.start <= word.lowerBound && $0.end >= word.upperBound }
        }

        report("an untouched word between two indent marks is left unmarked",
               !wordIsPresented(AbsorptionSettings()))

        // The negative control. With the rule off this is the pass as DEC-094 shipped it, and the
        // word is swallowed — which is the defect, reproduced rather than asserted away.
        report("control: with the rule off the word is swallowed",
               wordIsPresented(AbsorptionSettings(refuseBetweenLayoutFlanks: false)))

        // The floor is the other half of the rule and it has to be seen to hold: a one- or two-byte
        // gap is still absorbed, because that gap is the confetti DEC-094 exists to remove.
        let tight = [UInt8]("a\n  ,\n  b".utf8)
        let tightPartition = Partition(totalLength: tight.count, segments: [
            Segment(start: 0, end: 1, label: .unchanged, confidence: 1),
            Segment(start: 1, end: 4, label: .changed,
                    classification: ChangeClass.whitespace.rawValue, confidence: 0.8),
            Segment(start: 4, end: 5, label: .unchanged, confidence: 1),
            Segment(start: 5, end: 8, label: .changed,
                    classification: ChangeClass.whitespace.rawValue, confidence: 0.8),
            Segment(start: 8, end: tight.count, label: .unchanged, confidence: 1),
        ])
        report("a one-byte island between the same two marks is still absorbed",
               absorbIslands(tightPartition, bytes: tight, settings: AbsorptionSettings())
                   .segments.contains { $0.isPresented && $0.start <= 4 && $0.end >= 5 })
    }
}
