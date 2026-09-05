import DiffScopeEngine
import Foundation

public struct StructuralStats: Sendable, Equatable {
    public let anchors: Int
    public let ambiguities: Int
    public let unchangedBytesOld: Int
    public let unchangedBytesNew: Int
    public let usedFallback: Bool
    /// The condition that caused the fallback, ranked (DEC-051). Carried whole rather than as a
    /// sentence so the caller can say which taxonomy row fired, not merely what went wrong.
    public let degradation: Degradation?
    public var fallbackReason: String? { degradation?.reason }
    public let movedSegments: Int
    public let formattingOnlySegments: Int
    public let behaviorAffectingSegments: Int
    public let invisibleSegments: Int
    public let movesFound: Int
    public let movesBelowFloor: Int
    /// F1: byte ranges the parser could not read, and the changed segments inside them that are
    /// therefore shown without any structural claim.
    public let unparsedRegions: Int
    public let unparsedBytes: Int

    public init(anchors: Int, ambiguities: Int, unchangedBytesOld: Int, unchangedBytesNew: Int,
                usedFallback: Bool, degradation: Degradation?, movedSegments: Int = 0,
                formattingOnlySegments: Int = 0, behaviorAffectingSegments: Int = 0,
                invisibleSegments: Int = 0, movesFound: Int = 0, movesBelowFloor: Int = 0,
                unparsedRegions: Int = 0, unparsedBytes: Int = 0) {
        self.anchors = anchors
        self.ambiguities = ambiguities
        self.unchangedBytesOld = unchangedBytesOld
        self.unchangedBytesNew = unchangedBytesNew
        self.usedFallback = usedFallback
        self.degradation = degradation
        self.movedSegments = movedSegments
        self.formattingOnlySegments = formattingOnlySegments
        self.behaviorAffectingSegments = behaviorAffectingSegments
        self.invisibleSegments = invisibleSegments
        self.movesFound = movesFound
        self.movesBelowFloor = movesBelowFloor
        self.unparsedRegions = unparsedRegions
        self.unparsedBytes = unparsedBytes
    }
}

public extension StructuralStats {
    /// `12-…` §5.2's parser-state indicator, derived from what this run actually did.
    ///
    /// It lives beside the statistics rather than in the shell so that the check suite exercises
    /// the same derivation the window does. The one case it cannot see is a structural result
    /// discarded by validation *after* parsing: the parse succeeded, so the shell says so itself.
    var parserState: ParserStateReport {
        ParserStateReport.of(structuralRequested: true, structuralUsed: !usedFallback,
                             degradation: degradation,
                             unparsedRegions: unparsedRegions, unparsedBytes: unparsedBytes)
    }
}

public struct StructuralResult: Sendable {
    public let model: DiffModel
    public let stats: StructuralStats
}

struct Anchor {
    let oldStart: Int
    let oldEnd: Int
    let newStart: Int
    let newEnd: Int
}

func anchors(old: SyntaxTree, new: SyntaxTree, mapping: NodeMapping) -> [Anchor] {
    let ambiguousOld = mapping.ambiguousOldNodes
    let ambiguousNew = mapping.ambiguousNewNodes

    var candidates: [Anchor] = []
    for (oldID, newID) in mapping.oldToNew {
        let oldNode = old.node(oldID)
        let newNode = new.node(newID)
        guard oldNode.isLeaf, newNode.isLeaf else { continue }
        guard !oldNode.isError, !newNode.isError else { continue }
        guard !ambiguousOld.contains(oldID), !ambiguousNew.contains(newID) else { continue }
        guard oldNode.end > oldNode.start, newNode.end > newNode.start else { continue }
        guard old.text(of: oldID) == new.text(of: newID) else { continue }
        candidates.append(Anchor(
            oldStart: oldNode.start, oldEnd: oldNode.end,
            newStart: newNode.start, newEnd: newNode.end
        ))
    }

    candidates.sort {
        $0.oldStart != $1.oldStart ? $0.oldStart < $1.oldStart : $0.newStart < $1.newStart
    }

    var kept: [Anchor] = []
    var oldCursor = 0
    var newCursor = 0
    for anchor in candidates where anchor.oldStart >= oldCursor && anchor.newStart >= newCursor {
        kept.append(anchor)
        oldCursor = anchor.oldEnd
        newCursor = anchor.newEnd
    }
    return kept
}

/// - Parameter external: conditions this module cannot detect for itself — F8 (a Git filter is
///   active) and F10 (the pin would not settle) both belong to the Git layer, which the syntax
///   layer must not import. They join the ranking rather than pre-empting it, so a filtered `.png`
///   still reports as binary: F9 outranks F8.
public func structuralDiff(
    oldPath: String, oldBytes: [UInt8],
    newPath: String, newBytes: [UInt8],
    parser: TSXParser?,
    settings: MatcherSettings = MatcherSettings(),
    external: [Degradation] = []
) -> StructuralResult {
    func fallbackResult(_ degradation: Degradation) -> StructuralResult {
        // One route for every whole-file fallback, so the F-rows cannot drift apart from Raw mode
        // (DEC-095). `trivialModel` localises the change wherever the byte diff can be computed and
        // paints the whole file only where it cannot.
        return StructuralResult(
            model: trivialModel(oldBytes: oldBytes, newBytes: newBytes,
                                absorption: AbsorptionSettings(islandBytes: settings.absorbIslandBytes,
                                       refuseBetweenLayoutFlanks: settings.absorbRefusesLayoutFlanks)),
            stats: StructuralStats(anchors: 0, ambiguities: 0,
                                   unchangedBytesOld: 0, unchangedBytesNew: 0,
                                   usedFallback: true, degradation: degradation)
        )
    }

    if oldBytes == newBytes {
        // INV-3 holds: the sides are byte-equal, so nothing is labelled changed. An external
        // condition still travels with the answer, because F8 is precisely the case where "no
        // changes" needs its caveat — the file list says the file changed (DEC-041, following
        // `git status`), this view compares bytes the filter did not touch, and both are right.
        return StructuralResult(
            model: DiffModel(
                oldBytes: oldBytes, newBytes: newBytes,
                oldPartition: wholeFilePartition(length: oldBytes.count, label: .unchanged),
                newPartition: wholeFilePartition(length: newBytes.count, label: .unchanged)
            ),
            stats: StructuralStats(anchors: 0, ambiguities: 0,
                                   unchangedBytesOld: oldBytes.count, unchangedBytesNew: newBytes.count,
                                   usedFallback: false,
                                   degradation: Degradation.mostConservative(external))
        )
    }

    // Everything knowable before parsing, gathered rather than short-circuited, so the reason shown
    // is the most conservative one that is true (DEC-051). Gate one lives here: parsing a 31 MB
    // bundle costs about a second before anything can be decided about it (DEC-050, M8-A).
    var upfront = external
    upfront += sourceDegradations(path: oldPath, bytes: oldBytes)
    upfront += sourceDegradations(path: newPath, bytes: newBytes)
    let largest = max(oldBytes.count, newBytes.count)
    if largest > structuralSizeLimit {
        upfront.append(.budgetExceeded(
            reason: "file is \(largest / 1024) KB, above the \(structuralSizeLimit / 1024) KB structural limit"))
    }
    if let worst = Degradation.mostConservative(upfront) { return fallbackResult(worst) }

    guard let parser,
          let oldTree = parser.parseTree(oldBytes),
          let newTree = parser.parseTree(newBytes)
    else { return fallbackResult(Degradation.parseFailure(reason: "parser unavailable")) }

    // Gate two, after parsing and before matching: parsing is linear, matching is not.
    let nodes = max(oldTree.nodes.count, newTree.nodes.count)
    if nodes > structuralNodeBudget {
        return fallbackResult(Degradation.budgetExceeded(
            reason: "file has \(nodes) syntax nodes, above the \(structuralNodeBudget) budget"))
    }

    let mapping = matchTrees(old: oldTree, new: newTree, settings: settings)
    // Gate three: matching gave up part-way. A partial mapping would present fewer anchors and
    // therefore *more* apparent change than the file contains — a worse answer that looks like a
    // normal one, which is exactly what INV-4 exists to prevent.
    if mapping.exceededBudget {
        return fallbackResult(Degradation.budgetExceeded(
            reason: "structural matching exceeded its work budget after \(mapping.workUsed) units"))
    }
    let found = anchors(old: oldTree, new: newTree, mapping: mapping)

    var oldSegments: [Segment] = []
    var newSegments: [Segment] = []
    var oldCursor = 0
    var newCursor = 0
    var unchangedOld = 0
    var unchangedNew = 0

    func emitGap(oldTo: Int, newTo: Int) {
        let oldSpan = oldCursor..<oldTo
        let newSpan = newCursor..<newTo
        let oldSlice = oldSpan.isEmpty ? [] : Array(oldBytes[oldSpan])
        let newSlice = newSpan.isEmpty ? [] : Array(newBytes[newSpan])
        let equal = oldSlice == newSlice
        // The gap pair is the only place both sides of a change are known to correspond,
        // so classification happens here, before reconciliation subdivides it.
        let classification = equal ? nil : changeClassification(old: oldSlice, new: newSlice)?.rawValue
        let disclosure = equal ? nil : invisibleDifference(old: oldSlice, new: newSlice)?.rawValue
        if !oldSpan.isEmpty {
            oldSegments.append(Segment(start: oldSpan.lowerBound, end: oldSpan.upperBound,
                                       label: equal ? .unchanged : .changed,
                                       classification: classification, disclosure: disclosure,
                                       confidence: equal ? 1 : 0.8))
            if equal { unchangedOld += oldSlice.count }
        }
        if !newSpan.isEmpty {
            newSegments.append(Segment(start: newSpan.lowerBound, end: newSpan.upperBound,
                                       label: equal ? .unchanged : .changed,
                                       classification: classification, disclosure: disclosure,
                                       confidence: equal ? 1 : 0.8))
            if equal { unchangedNew += newSlice.count }
        }
    }

    for anchor in found {
        emitGap(oldTo: anchor.oldStart, newTo: anchor.newStart)
        oldSegments.append(Segment(start: anchor.oldStart, end: anchor.oldEnd,
                                   label: .unchanged, confidence: 1))
        newSegments.append(Segment(start: anchor.newStart, end: anchor.newEnd,
                                   label: .unchanged, confidence: 1))
        unchangedOld += anchor.oldEnd - anchor.oldStart
        unchangedNew += anchor.newEnd - anchor.newStart
        oldCursor = anchor.oldEnd
        newCursor = anchor.newEnd
    }
    emitGap(oldTo: oldBytes.count, newTo: newBytes.count)

    var oldChangedMask: [(start: Int, end: Int)] = []
    var newChangedMask: [(start: Int, end: Int)] = []
    // How each hunk relates to the reflow question (DEC-101). The canonical hunk is a correspondence
    // by construction, which is what lets this say `whitespace` about a mark that `reconcile` has
    // already cut away from its counterpart. `layout` is the whole hunk; `reflow` is its whitespace.
    var oldLayout: [(start: Int, end: Int)] = []
    var newLayout: [(start: Int, end: Int)] = []
    var oldReflowed: [(start: Int, end: Int)] = []
    var newReflowed: [(start: Int, end: Int)] = []
    var allHunks: [(oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int)] = []
    var coverageKnown = false
    // **When the byte diff gives up, the mask is lines rather than nothing** (DEC-122, the third of
    // the silences E-F named and the last one open).
    //
    // `reconcile` opens with `guard applied else { return segments }`, so on a pair the canonical
    // diff cannot finish it was the identity — and the anchor/gap marks shipped **unclipped**. Those
    // marks are the whole gap between two anchors, which is why a file that exhausts the budget drew
    // lines 13–24 as changed where only line 12 was touched. The file is disclosed as unverified
    // (`Contract.swift:141`) and nothing said the marks on it were the anchors' rather than the byte
    // diff's.
    //
    // DEC-105's line anchoring answers exactly this condition and its guarantee is the one needed
    // here: *what it leaves unmarked is byte-identical line pairs*, so its hunks **cover every byte
    // that differs**. Clipping against a superset of the truth is safe in both directions — a byte
    // outside every line hunk is byte-identical and may be demoted, and a byte inside one may be
    // promoted, which is the direction that over-marks.
    //
    // INV-2 is unaffected either way: it is stated against `D`, and where `D` cannot be computed the
    // file is `unverified` and says so. This does not make it verified. It makes the marks on it
    // narrower than the anchors alone, which is what the reader is looking at.
    switch canonicalDiff(old: oldBytes, new: newBytes) {
    case let .exact(hunks):
        coverageKnown = true
        for hunk in hunks {
            if hunk.oldEnd > hunk.oldStart { oldChangedMask.append((hunk.oldStart, hunk.oldEnd)) }
            if hunk.newEnd > hunk.newStart { newChangedMask.append((hunk.newStart, hunk.newEnd)) }
            allHunks.append((hunk.oldStart, hunk.oldEnd, hunk.newStart, hunk.newEnd))
        }
    case .budgetExceeded:
        if settings.lineMaskWhenBudgetExceeded,
           let hunks = lineAnchoredHunks(old: oldBytes, new: newBytes) {
            coverageKnown = true
            for hunk in hunks {
                if hunk.oldEnd > hunk.oldStart { oldChangedMask.append((hunk.oldStart, hunk.oldEnd)) }
                if hunk.newEnd > hunk.newStart { newChangedMask.append((hunk.newStart, hunk.newEnd)) }
                allHunks.append((hunk.oldStart, hunk.oldEnd, hunk.newStart, hunk.newEnd))
            }
        }
    }

    // Classified here, before every widening pass, so a flank the snap adds can inherit the claim
    // through `widenPresented`'s agreement rule rather than arriving unclassified beside it.
    // Asked of the region the hunks jointly cover rather than of each hunk, because a reorder is
    // only visible at the scale of the thing reordered (DEC-101).
    var oldPreservedGaps: [(start: Int, end: Int)] = []
    var newPreservedGaps: [(start: Int, end: Int)] = []
    if settings.classifyWhitespaceHunks {
        for region in layoutRegions(hunks: allHunks, old: oldBytes, new: newBytes) {
            // The finest of the three rules, and the one that reaches a prop added to an element
            // that was rewrapped around it: a gap between two tokens that are still neighbours on
            // the other side is a line break moving and nothing else.
            let layout = hunkLayout(old: oldBytes[region.oldStart..<region.oldEnd],
                                    new: newBytes[region.newStart..<region.newEnd])
            if layout != .reordered {
                let oldPairs = adjacentTokenPairs(bytes: oldBytes, from: region.oldStart,
                                                  to: region.oldEnd)
                let newPairs = adjacentTokenPairs(bytes: newBytes, from: region.newStart,
                                                  to: region.newEnd)
                oldPreservedGaps += preservedGapRanges(bytes: oldBytes, from: region.oldStart,
                                                       to: region.oldEnd, otherAdjacentPairs: newPairs)
                newPreservedGaps += preservedGapRanges(bytes: newBytes, from: region.newStart,
                                                       to: region.newEnd, otherAdjacentPairs: oldPairs)
            }
            switch layout {
            case .layoutOnly:
                if region.oldEnd > region.oldStart { oldLayout.append((region.oldStart, region.oldEnd)) }
                if region.newEnd > region.newStart { newLayout.append((region.newStart, region.newEnd)) }
            case .reflowed:
                if region.oldEnd > region.oldStart { oldReflowed.append((region.oldStart, region.oldEnd)) }
                if region.newEnd > region.newStart { newReflowed.append((region.newStart, region.newEnd)) }
            case .reordered, .substantive:
                continue
            }
        }
    }

    func layoutClassified(_ segments: [Segment], bytes: [UInt8],
                          layout: [(start: Int, end: Int)],
                          reflowed: [(start: Int, end: Int)],
                          gaps: [(start: Int, end: Int)]) -> [Segment] {
        guard settings.classifyWhitespaceHunks else { return segments }
        return classifyLayoutMarks(
            Partition(totalLength: bytes.count, segments: segments),
            bytes: bytes, layoutRanges: layout, reflowRanges: reflowed,
            preservedGaps: gaps).segments
    }
    let reconciledOld = layoutClassified(
        reconcile(oldSegments, against: oldChangedMask, applied: coverageKnown),
        bytes: oldBytes, layout: oldLayout, reflowed: oldReflowed, gaps: oldPreservedGaps)
    let reconciledNew = layoutClassified(
        reconcile(newSegments, against: newChangedMask, applied: coverageKnown),
        bytes: newBytes, layout: newLayout, reflowed: newReflowed, gaps: newPreservedGaps)

    unchangedOld = reconciledOld.filter { $0.label == .unchanged }.reduce(0) { $0 + $1.length }
    unchangedNew = reconciledNew.filter { $0.label == .unchanged }.reduce(0) { $0 + $1.length }

    // A move regroups what is presented; it never removes it. Searched on the reconciled
    // labels, so the candidates are exactly the content the byte diff already calls changed.
    let search = findMoves(oldBytes: oldBytes, oldSegments: reconciledOld,
                           newBytes: newBytes, newSegments: reconciledNew,
                           floor: settings.moveContentFloor)
    let movedOld = applyMoves(
        Partition(totalLength: oldBytes.count, segments: reconciledOld),
        ranges: search.moves.enumerated().flatMap { index, move in
            move.oldRanges.map { (start: $0.lowerBound, end: $0.upperBound, link: index) }
        }
    )
    let movedNew = applyMoves(
        Partition(totalLength: newBytes.count, segments: reconciledNew),
        ranges: search.moves.enumerated().flatMap { index, move in
            move.newRanges.map { (start: $0.lowerBound, end: $0.upperBound, link: index) }
        }
    )

    // Syntax snapping first, then grapheme snapping (`14-…` §4). Both only ever widen what is
    // presented, so the order costs nothing — but grapheme snapping must come last, because a
    // syntax boundary is not obliged to fall on a cluster boundary and the emoji-ZWJ case proves
    // it does not.
    // F1 (`13-…` §2): the regions the parser could not read. The structural result stands for the
    // rest of the file — that is what F1 asks for — but a change shown inside an unparsed region is
    // shown *without* a structural claim behind it, so it is labelled as the fallback it is.
    //
    // Only **changed** segments are relabelled. Repainting byte-equal content as fallback would
    // suggest something happened there; the byte comparison is still perfectly valid inside a
    // region tree-sitter failed on, because comparison never depended on parsing (DEC-021).
    let oldErrors = parseErrorRegions(tree: oldTree)
    let newErrors = parseErrorRegions(tree: newTree)
    let unparsedBytes = (oldErrors + newErrors).reduce(0) { $0 + ($1.end - $1.start) }

    // Absorption first (DEC-094). An absorbed island removes two boundaries from the presented set,
    // so the 16-byte snap has strictly less to rescue — DEC-087 established that the order of these
    // passes is load-bearing, and this is the same fact from the other side. It also keeps the
    // budget-0 control honest: were absorption to run after the snap, its input would be a function
    // of `boundarySnapBudget`, and turning the snap off would exercise a different absorption from
    // the shipped one.
    // The word snap sits between the two (DEC-100). After the syntax snap, because a mark that has
    // already reached a node boundary has no word left to finish and the pass costs nothing; before
    // the grapheme snap, which must stay last for the reason above. All three only widen, so the
    // order changes what is spent and never what is claimed.
    let absorption = AbsorptionSettings(islandBytes: settings.absorbIslandBytes,
                                       refuseBetweenLayoutFlanks: settings.absorbRefusesLayoutFlanks)
    let oldStrings = stringRegions(tree: oldTree)
    let newStrings = stringRegions(tree: newTree)
    let oldPartition = snapToGraphemeBoundaries(snapToWordBoundaries(snapPresentation(
        absorbIslands(movedOld, bytes: oldBytes, settings: absorption),
        boundaries: SyntaxBoundaries(tree: oldTree),
        budget: settings.boundarySnapBudget, bytes: oldBytes,
        crossesLineBreaks: settings.snapCrossesLineBreaks
    ), bytes: oldBytes, stringRegions: oldStrings,
       budget: settings.wordSnapBudget), bytes: oldBytes)
    let newPartition = snapToGraphemeBoundaries(snapToWordBoundaries(snapPresentation(
        absorbIslands(movedNew, bytes: newBytes, settings: absorption),
        boundaries: SyntaxBoundaries(tree: newTree),
        budget: settings.boundarySnapBudget, bytes: newBytes,
        crossesLineBreaks: settings.snapCrossesLineBreaks
    ), bytes: newBytes, stringRegions: newStrings,
       budget: settings.wordSnapBudget), bytes: newBytes)

    // Last, so it catches fragmentation from every pass above it rather than only from its
    // neighbour: `reconcile` cut by the other side's structure, the snap added flanks of its own,
    // and `markUnparsed` may have split a run again.
    // The word merge runs first and `coalesceAdjacent` after it, because the two answer different
    // questions: one says a junction inside a word reports no fact of its own, the other says two
    // neighbours making the same claim are one mark. Both are off when the budget is 0, so the
    // negative control turns off the whole of DEC-100 rather than half of it.
    // **A second absorption, after the wideners rather than before them (DEC-103).** DEC-094 put the
    // pass first on purpose and that ordering is kept — it is what makes the budget-0 control honest
    // and what stops the snap rescuing boundaries absorption would have removed. What it cannot do
    // from there is see the gaps the wideners *create*: a mark widened onto a word boundary leaves a
    // one- or two-byte island behind it that absorption was never offered. The corpus counts 1757 of
    // them over 1200 changes, 1507 refused by no rule at all — which is the signature of a pass that
    // ran too early rather than of a rule that is too strict.
    //
    // Running it twice is safe for the reason the pass was safe once: absorption only relabels
    // `unchanged` as presented, so it is monotone, and its fourth condition — every line the island
    // touches already carries a presented byte from a flank — is a theorem about `changedLines`
    // whichever partition it is asked about.
    func absorbedAgain(_ partition: Partition, bytes: [UInt8]) -> Partition {
        guard settings.absorbAfterWidening else { return partition }
        return absorbIslands(partition, bytes: bytes, settings: absorption)
    }

    func merged(_ partition: Partition, bytes: [UInt8], strings: [(start: Int, end: Int)]) -> Partition {
        guard settings.mergeSplitMarksInWords else { return coalesceAdjacent(partition) }
        return coalesceAdjacent(coalesceAcrossWords(partition, bytes: bytes, stringRegions: strings))
    }
    let oldMarked = merged(markUnparsed(absorbedAgain(oldPartition, bytes: oldBytes),
                                        regions: oldErrors),
                           bytes: oldBytes, strings: oldStrings)
    let newMarked = merged(markUnparsed(absorbedAgain(newPartition, bytes: newBytes),
                                        regions: newErrors),
                           bytes: newBytes, strings: newStrings)

    unchangedOld = oldMarked.segments.filter { $0.label == .unchanged }.reduce(0) { $0 + $1.length }
    unchangedNew = newMarked.segments.filter { $0.label == .unchanged }.reduce(0) { $0 + $1.length }

    return StructuralResult(
        model: DiffModel(
            oldBytes: oldBytes, newBytes: newBytes,
            oldPartition: oldMarked, newPartition: newMarked
        ),
        stats: StructuralStats(
            anchors: found.count, ambiguities: mapping.ambiguities.count,
            unchangedBytesOld: unchangedOld, unchangedBytesNew: unchangedNew,
            usedFallback: false,
            // The structural result stands and still carries its condition: F1 degrades part of a
            // file, not the file. `usedFallback` stays false because the analysis was not withheld.
            degradation: (oldErrors.isEmpty && newErrors.isEmpty) ? nil : .partialParseError(
                reason: "\(oldErrors.count + newErrors.count) region(s) of this file did not parse"
                    + " (\(unparsedBytes) bytes); changes inside them are shown without a structural claim"),
            movedSegments: search.moves.count,
            formattingOnlySegments: segmentCount(in: oldMarked, group: .formattingOnly)
                + segmentCount(in: newMarked, group: .formattingOnly),
            behaviorAffectingSegments: segmentCount(in: oldMarked, group: .potentiallyBehaviorAffecting)
                + segmentCount(in: newMarked, group: .potentiallyBehaviorAffecting),
            invisibleSegments: [oldMarked, newMarked].reduce(0) { total, partition in
                total + partition.segments.filter { $0.disclosure != nil }.count
            },
            movesFound: search.moves.count,
            movesBelowFloor: search.belowFloor,
            unparsedRegions: oldErrors.count + newErrors.count,
            unparsedBytes: unparsedBytes
        )
    )
}

/// Splits labelled segments against the canonical diff's changed mask.
///
/// The return type used to carry a `moved` count that nothing incremented and nothing read — the
/// residue of the reconciliation-derived `moved` label removed in M6-D. A counter stuck at zero is
/// worse than no counter, because it reads as a measurement.
func reconcile(
    _ segments: [Segment],
    against mask: [(start: Int, end: Int)],
    applied: Bool
) -> [Segment] {
    guard applied else { return segments }
    let sorted = mask.sorted { $0.start < $1.start }
    var out: [Segment] = []

    for segment in segments {
        if segment.label == .changed {
            var cursor = segment.start
            for range in sorted {
                if range.end <= cursor { continue }
                if range.start >= segment.end { break }
                let overlapStart = max(range.start, cursor)
                let overlapEnd = min(range.end, segment.end)
                guard overlapEnd > overlapStart else { continue }
                if overlapStart > cursor {
                    out.append(Segment(start: cursor, end: overlapStart, label: .unchanged,
                                       confidence: 1))
                }
                out.append(Segment(start: overlapStart, end: overlapEnd, label: .changed,
                                   classification: segment.classification,
                                   disclosure: segment.disclosure, confidence: segment.confidence))
                cursor = overlapEnd
            }
            if cursor < segment.end {
                out.append(Segment(start: cursor, end: segment.end, label: .unchanged,
                                   confidence: 1))
            }
            continue
        }

        guard segment.label == .unchanged else { out.append(segment); continue }

        var cursor = segment.start
        for range in sorted {
            if range.end <= cursor { continue }
            if range.start >= segment.end { break }
            let overlapStart = max(range.start, cursor)
            let overlapEnd = min(range.end, segment.end)
            guard overlapEnd > overlapStart else { continue }
            if overlapStart > cursor {
                out.append(Segment(start: cursor, end: overlapStart, label: .unchanged,
                                   classification: segment.classification, confidence: segment.confidence))
            }
            // An anchor the byte diff contradicts used to be relabelled `moved` here. That was
            // a claim this function cannot check: it sees one side only, so it could not compare
            // the two ranges DEC-038 requires to be byte-equal. Moves are now searched for
            // deliberately, against both sides, after reconciliation.
            out.append(Segment(
                start: overlapStart, end: overlapEnd,
                label: .changed,
                classification: segment.classification,
                disclosure: segment.disclosure,
                confidence: 0.6
            ))
            cursor = overlapEnd
        }
        if cursor < segment.end {
            out.append(Segment(start: cursor, end: segment.end, label: .unchanged,
                               classification: segment.classification, confidence: segment.confidence))
        }
    }
    return out
}


/// Relabels **changed** segments that fall inside a region the parser could not read, so a change
/// shown there is marked as raw rather than presented as understood (F1, INV-4).
///
/// Splits a segment that straddles a region boundary rather than relabelling the whole of it: the
/// clean half is still a structural claim the layer can make.
func markUnparsed(_ partition: Partition, regions: [(start: Int, end: Int)]) -> Partition {
    guard !regions.isEmpty else { return partition }
    var out: [Segment] = []
    for segment in partition.segments {
        guard segment.label == .changed else { out.append(segment); continue }
        var cursor = segment.start
        for region in regions where region.end > segment.start && region.start < segment.end {
            let start = max(region.start, cursor)
            let end = min(region.end, segment.end)
            guard end > start else { continue }
            if start > cursor {
                out.append(Segment(start: cursor, end: start, label: .changed,
                                   classification: segment.classification,
                                   disclosure: segment.disclosure,
                                   confidence: segment.confidence, link: segment.link))
            }
            out.append(Segment(start: start, end: end, label: .fallback,
                               classification: "parse-error",
                               disclosure: segment.disclosure,
                               confidence: 0, link: segment.link))
            cursor = end
        }
        if cursor < segment.end {
            out.append(Segment(start: cursor, end: segment.end, label: segment.label,
                               classification: segment.classification,
                               disclosure: segment.disclosure,
                               confidence: segment.confidence, link: segment.link))
        }
    }
    return Partition(totalLength: partition.totalLength, segments: out)
}
