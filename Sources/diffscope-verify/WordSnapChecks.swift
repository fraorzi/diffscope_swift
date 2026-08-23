import DiffScopeEngine
import DiffScopeSyntax
import Foundation

/// DEC-100 and DEC-101 — the two shapes the corpus survey ranked first, and the properties that
/// bound what their fixes are allowed to do.
///
/// Both passes only ever *widen* or *label*, never move or hide, so the properties below are the
/// same three every presentation pass in this project has had to satisfy since DEC-021: the
/// presented set may grow and never shrink, the reported lines may not move, and the pass must be
/// off when its switch is off — which is the negative control that makes the measurement mean
/// anything.
func runWordSnapChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }
    let parser = TSXParser()

    func diff(_ old: String, _ new: String, settings: MatcherSettings = MatcherSettings())
        -> StructuralResult {
        structuralDiff(oldPath: "a.tsx", oldBytes: [UInt8](old.utf8),
                       newPath: "a.tsx", newBytes: [UInt8](new.utf8),
                       parser: parser, settings: settings)
    }
    func marks(_ partition: Partition, _ bytes: [UInt8]) -> [String] {
        partition.segments.filter(\.isPresented)
            .map { String(decoding: bytes[$0.start..<$0.end], as: UTF8.self) }
    }
    func presentedBytes(_ partition: Partition) -> Set<Int> {
        var out = Set<Int>()
        for segment in partition.segments where segment.isPresented {
            for offset in segment.start..<segment.end { out.insert(offset) }
        }
        return out
    }
    let off = MatcherSettings(wordSnapBudget: 0, mergeSplitMarksInWords: false,
                              classifyWhitespaceHunks: false)

    print("\n=== DEC-100: a mark finishes the word it cut ===")
    do {
        // A Tailwind class attribute: one string node, so the only syntax boundaries inside it are
        // the quotes, and the 16-byte snap cannot reach them.
        let old = "const cls = 'flex h-10 w-10 bg-opacity-30 p-4';\n"
        let new = "const cls = 'flex h-10 w-10 bg-black/50 p-4';\n"
        let snapped = diff(old, new)
        let control = diff(old, new, settings: off)
        let newBytes = [UInt8](new.utf8)

        report("the whole class name is one mark, not its tail",
               marks(snapped.model.newPartition, newBytes).contains { $0.contains("bg-black/50") },
               marks(snapped.model.newPartition, newBytes).joined(separator: " | "))
        report("negative control: with the budget at 0 the mark starts inside the class name",
               !marks(control.model.newPartition, newBytes).contains { $0.hasPrefix("bg-black") },
               marks(control.model.newPartition, newBytes).joined(separator: " | "))
        report("the presented set grew rather than moved",
               presentedBytes(snapped.model.newPartition)
                   .isSuperset(of: presentedBytes(control.model.newPartition)))
    }

    do {
        // Outside a string a hyphen is a minus sign, so the identifier rule applies and `a - b` is
        // not one word. The control for the rule above, and the reason there are two rules.
        let old = "const total = count - 1;\n"
        let new = "const total = count - 2;\n"
        let newBytes = [UInt8](new.utf8)
        let result = diff(old, new)
        report("outside a string a hyphen is not part of a word",
               !marks(result.model.newPartition, newBytes).contains { $0.contains("count") },
               marks(result.model.newPartition, newBytes).joined(separator: " | "))
    }

    do {
        // The property the widening rests on: a word cannot straddle a line terminator, because a
        // terminator is not a word byte under either rule — so no line can be added to the report.
        var moved = 0
        var checked = 0
        for fixture in loadFixtures(root: URL(fileURLWithPath: "fixtures")) {
            let on = structuralDiff(oldPath: fixture.oldPath, oldBytes: fixture.old,
                                    newPath: fixture.newPath, newBytes: fixture.new, parser: parser)
            let control = structuralDiff(oldPath: fixture.oldPath, oldBytes: fixture.old,
                                         newPath: fixture.newPath, newBytes: fixture.new,
                                         parser: parser,
                                         settings: MatcherSettings(wordSnapBudget: 0))
            checked += 1
            if changedLines(bytes: fixture.new, partition: on.model.newPartition)
                != changedLines(bytes: fixture.new, partition: control.model.newPartition) { moved += 1 }
            if changedLines(bytes: fixture.old, partition: on.model.oldPartition)
                != changedLines(bytes: fixture.old, partition: control.model.oldPartition) { moved += 1 }
        }
        report("over \(checked) fixtures the word snap reports the same lines as its absence",
               moved == 0, moved == 0 ? "" : "\(moved) sides moved")
    }

    print("\n=== DEC-100: two marks inside one word are one mark ===")
    do {
        // A unit rather than an end-to-end case, and deliberately so: the split this pass repairs is
        // produced by `reconcile` giving a mask-only byte a confidence of 0.6 while the rest of the
        // word keeps 1, and constructing that directly is the only way to be sure the control is
        // exercising the merge rather than some upstream pass that happened to prevent the split.
        let bytes = [UInt8]("transition".utf8)
        let shredded = Partition(totalLength: bytes.count, segments: [
            Segment(start: 0, end: 1, label: .changed, confidence: 0.6),
            Segment(start: 1, end: bytes.count, label: .changed, confidence: 1),
        ])
        let merged = coalesceAcrossWords(shredded, bytes: bytes, stringRegions: [])
        report("a junction inside a word merges, across the confidence floor",
               merged.segments.count == 1,
               merged.segments.map { "\($0.start)..<\($0.end)" }.joined(separator: " "))
        report("and the merged mark keeps the lower confidence",
               merged.segments.first?.confidence == 0.6)
        report("negative control: `coalesceAdjacent` alone leaves the word in two",
               coalesceAdjacent(shredded).segments.count == 2)

        // The junction between two words is left where it is: `a` `b` are two tokens, and two marks
        // over them report two facts.
        let spaced = [UInt8]("a b".utf8)
        let apart = Partition(totalLength: 3, segments: [
            Segment(start: 0, end: 2, label: .changed, confidence: 0.6),
            Segment(start: 2, end: 3, label: .changed, confidence: 1),
        ])
        report("a junction between two words is not merged",
               coalesceAcrossWords(apart, bytes: spaced, stringRegions: []).segments.count == 2)
    }

    print("\n=== DEC-101: a rewrap says it is a rewrap ===")
    do {
        // The owner's own report, reduced: one prop added to a JSX element, prettier rewrapping the
        // element around it — **and a value edited in the same element**, which is what puts this
        // out of `changeClassification`'s reach. With the rewrap alone the gap pair is whitespace on
        // both sides and the existing classifier already says so; add one changed value and the pair
        // is no longer whitespace, so every mark in it arrives unclassified. That is the case this
        // pass exists for, and measuring it any other way measures the classifier that was already
        // there.
        let old = "export function Hero() {\n  return (\n    <section>\n"
            + "      <Image src={hero} alt=\"Hero\" width={1200} height={600} priority />\n"
            + "    </section>\n  );\n}\n"
        let new = "export function Hero() {\n  return (\n    <section>\n      <Image\n"
            + "        src={hero}\n        alt=\"Hero\"\n        width={800}\n        height={600}\n"
            + "        priority\n        className=\"rounded-xl object-cover\"\n      />\n"
            + "    </section>\n  );\n}\n"
        let newBytes = [UInt8](new.utf8)
        let result = diff(old, new)
        let control = diff(old, new, settings: MatcherSettings(classifyWhitespaceHunks: false))

        let quiet = result.model.newPartition.segments.filter {
            $0.isPresented && classificationGroup(of: $0.classification)
                == ClassificationGroup.formattingOnly.rawValue
        }
        let loud = result.model.newPartition.segments.filter {
            $0.isPresented && classificationGroup(of: $0.classification)
                != ClassificationGroup.formattingOnly.rawValue
        }
        report("the rewrap is marked as formatting", !quiet.isEmpty,
               "\(quiet.count) quiet, \(loud.count) loud")
        report("the prop that was added is not",
               loud.contains { String(decoding: newBytes[$0.start..<$0.end], as: UTF8.self)
                   .contains("className") },
               marks(result.model.newPartition, newBytes).joined(separator: " | "))
        // Not "nothing is classified" — `changeClassification` runs on the gap pair and reaches
        // some of these marks on its own. What the control has to show is that this pass is what
        // classifies the rewrap.
        let controlQuiet = control.model.newPartition.segments.filter {
            $0.isPresented && classificationGroup(of: $0.classification)
                == ClassificationGroup.formattingOnly.rawValue
        }
        // The control is a unit rather than the same pair with the switch off, and the reason is
        // worth recording: with every other pass shipped, `changeClassification` already classifies
        // this rewrap from the gap pair, so an end-to-end control measures **that** classifier and
        // reports the same number either way. What has to be shown here is that this pass classifies
        // a mark nothing else reaches — a whitespace run between two tokens that are still
        // neighbours, inside a region holding a real edit.
        let gapBytes = [UInt8]("<Image\n  src={a}\n".utf8)
        let unclassified = Partition(totalLength: gapBytes.count, segments: [
            Segment(start: 0, end: 6, label: .unchanged, confidence: 1),
            Segment(start: 6, end: 9, label: .changed, confidence: 0.8),
            Segment(start: 9, end: gapBytes.count, label: .unchanged, confidence: 1),
        ])
        let pairs = adjacentTokenPairs(bytes: [UInt8]("<Image src={a}\n".utf8), from: 0, to: 15)
        let gaps = preservedGapRanges(bytes: gapBytes, from: 0, to: gapBytes.count,
                                      otherAdjacentPairs: pairs)
        let classified = classifyLayoutMarks(unclassified, bytes: gapBytes,
                                             layoutRanges: [], reflowRanges: [], preservedGaps: gaps)
        report("a gap between two tokens that are still neighbours is classified",
               classified.segments.contains {
                   $0.isPresented && $0.classification == ChangeClass.whitespace.rawValue
               },
               classified.segments.map { "\($0.start)..<\($0.end) \($0.classification ?? "—")" }
                   .joined(separator: " "))
        report("negative control: with no preserved gap the same mark stays unclassified",
               classifyLayoutMarks(unclassified, bytes: gapBytes, layoutRanges: [],
                                   reflowRanges: [], preservedGaps: []).segments
                   .allSatisfy { $0.classification == nil })

        report("no byte moved in or out of the presented set",
               presentedBytes(result.model.newPartition) == presentedBytes(control.model.newPartition))
    }

    do {
        // The rule the suite refused twice before it was right: a reorder is not a rewrap, and the
        // difference is only visible over the region the change covers rather than hunk by hunk.
        let old = "<Field\n  name=\"email\"\n  label=\"Adres\"\n  required\n/>\n"
        let new = "<Field required label=\"Adres\" name=\"email\" />\n"
        let result = diff(old, new)
        let formatting = [result.model.oldPartition, result.model.newPartition].reduce(0) {
            $0 + $1.segments.filter {
                $0.isPresented && classificationGroup(of: $0.classification)
                    == ClassificationGroup.formattingOnly.rawValue
            }.count
        }
        report("a reorder is never presented as formatting, whatever its whitespace looks like",
               formatting == 0, "\(formatting) formatting-only segments")
    }

    do {
        // `layoutOnly`: a pure re-indent, where every mark in the region is layout whatever bytes it
        // covers — the wider of the two rules, and the one that needs no token test.
        let old = "function a() {\n    return 1;\n}\n"
        let new = "function a() {\n  return 1;\n}\n"
        let result = diff(old, new)
        // Both sides: removing two spaces of indentation is a deletion, so the new side carries no
        // mark at all and a check reading only that side would pass on an empty set.
        let presented = result.model.oldPartition.segments.filter(\.isPresented)
            + result.model.newPartition.segments.filter(\.isPresented)
        report("a re-indent is entirely formatting",
               !presented.isEmpty && presented.allSatisfy {
                   classificationGroup(of: $0.classification)
                       == ClassificationGroup.formattingOnly.rawValue
               },
               "\(presented.count) marks")
    }

    print("\n=== DEC-103: absorption runs again after the wideners ===")
    do {
        // Two class names change with one space between them. The word snap finishes both names,
        // and the space left standing between them is an island absorption never saw — because
        // absorption ran before the snap, which is where DEC-094 deliberately put it.
        // The string is long enough that the 16-byte syntax snap cannot reach its quotes; otherwise
        // that pass widens the mark to the whole literal and this measures nothing.
        let old = "const cls = 'flex items-center justify-center px-6 py-16 clip-lg gap-4 text-sm';\n"
        let new = "const cls = 'flex items-center justify-center px-8 py-20 clip-lg gap-4 text-sm';\n"
        let newBytes = [UInt8](new.utf8)
        let again = diff(old, new)
        let once = diff(old, new, settings: MatcherSettings(absorbAfterWidening: false))

        report("the island the widener created is absorbed",
               marks(again.model.newPartition, newBytes).contains { $0.contains("px-8 py-20") },
               marks(again.model.newPartition, newBytes).joined(separator: " | "))
        report("negative control: without the second pass it is two marks",
               !marks(once.model.newPartition, newBytes).contains { $0.contains("px-8 py-20") },
               marks(once.model.newPartition, newBytes).joined(separator: " | "))
        report("the presented set grew rather than moved",
               presentedBytes(again.model.newPartition)
                   .isSuperset(of: presentedBytes(once.model.newPartition)))

        // DEC-094's theorem, asked of the second pass over every fixture: absorption cannot add a
        // line to the report, whichever partition it is handed.
        var moved = 0
        for fixture in loadFixtures(root: URL(fileURLWithPath: "fixtures")) {
            let on = structuralDiff(oldPath: fixture.oldPath, oldBytes: fixture.old,
                                    newPath: fixture.newPath, newBytes: fixture.new, parser: parser)
            let off = structuralDiff(oldPath: fixture.oldPath, oldBytes: fixture.old,
                                     newPath: fixture.newPath, newBytes: fixture.new, parser: parser,
                                     settings: MatcherSettings(absorbAfterWidening: false))
            if changedLines(bytes: fixture.old, partition: on.model.oldPartition)
                != changedLines(bytes: fixture.old, partition: off.model.oldPartition) { moved += 1 }
            if changedLines(bytes: fixture.new, partition: on.model.newPartition)
                != changedLines(bytes: fixture.new, partition: off.model.newPartition) { moved += 1 }
        }
        report("and it reports the same lines as its absence, over every fixture", moved == 0,
               moved == 0 ? "" : "\(moved) sides moved")
    }

    print("\n=== DEC-110: a match landed inside an unrelated word is relocated ===")
    do {
        // The owner's second report, reduced: one attribute rewritten beside another that was not.
        // The alignment lands the `im` of `img.height}` inside `compactImageDimensions` and matches
        // the `g.height}` at the real one, so `img` — a word neither side touched — is drawn as part
        // of the insertion.
        let old = "  height={img.height}\n"
        let new = "  height={compactImageDimensions?.height ?? img.height}\n"
        let oldBytes = [UInt8](old.utf8), newBytes = [UInt8](new.utf8)

        let matches = canonicalMatches(old: oldBytes, new: newBytes).matches
        report("every match is byte-equal after relocation",
               matches.allSatisfy { match in
                   Array(oldBytes[match.oldStart..<(match.oldStart + match.length)])
                       == Array(newBytes[match.newStart..<(match.newStart + match.length)])
               })
        report("the matched total is what it was — a different tiling of the same length",
               matches.reduce(0) { $0 + $1.length }
                   == canonicalMatches(old: oldBytes, new: newBytes, applyShift: false)
                       .matches.reduce(0) { $0 + $1.length },
               matches.map { "\($0.oldStart)→\($0.newStart)×\($0.length)" }.joined(separator: " "))

        let result = diff(old, new)
        report("the untouched word is not part of the insertion",
               !marks(result.model.newPartition, newBytes).contains { $0.hasSuffix("img") },
               marks(result.model.newPartition, newBytes).joined(separator: " | "))
        report("and what is marked is the expression that was inserted",
               marks(result.model.newPartition, newBytes)
                   .contains { $0.contains("compactImageDimensions") })
    }

    do {
        // The property, over 300 random pairs: relocation never changes how much is matched, which
        // is what keeps it inside the minimality the 600-pair reference asserts.
        var generator = SystemRandomNumberGenerator()
        var disagreements = 0
        for _ in 0..<300 {
            let alphabet = Array("abcimg.{}? \n")
            let a = [UInt8](String((0..<Int.random(in: 4...90, using: &generator)).map { _ in
                alphabet.randomElement(using: &generator)!
            }).utf8)
            let b = [UInt8](String((0..<Int.random(in: 4...90, using: &generator)).map { _ in
                alphabet.randomElement(using: &generator)!
            }).utf8)
            let shifted = canonicalMatches(old: a, new: b).matches.reduce(0) { $0 + $1.length }
            let plain = canonicalMatches(old: a, new: b, applyShift: false)
                .matches.reduce(0) { $0 + $1.length }
            if shifted != plain { disagreements += 1 }
        }
        report("over 300 random pairs the matched total is unchanged", disagreements == 0,
               disagreements == 0 ? "" : "\(disagreements) pairs disagreed")
    }
}
