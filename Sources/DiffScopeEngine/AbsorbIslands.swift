import Foundation

/// The absolute ceiling on an island, in bytes. Chosen by measurement, not taste — see
/// `22-experiment-log.md` → M11-D.
public let absorbIslandBytes = 8

/// The shortest island of real content that the layout-flank rule will refuse (DEC-117).
///
/// Below it the pass keeps absorbing, and that is not a concession — a one- or two-byte gap between
/// two marks is the confetti DEC-094 exists to remove, and refusing it trades one complaint for
/// another. Three is where a token starts: `t('` is three bytes and `locale` is six, and those are
/// the shapes the owner reported.
public let layoutFlankIslandFloor = 3

public struct AbsorptionSettings: Sendable, Equatable {
    public var islandBytes: Int
    public var relativeToFlanks: Bool
    /// Whether an island of real content between two flanks made only of layout bytes is refused
    /// (DEC-117). Off reproduces the pass as DEC-094 shipped it, which is the negative control.
    public var refuseBetweenLayoutFlanks: Bool

    public init(islandBytes: Int = absorbIslandBytes, relativeToFlanks: Bool = true,
                refuseBetweenLayoutFlanks: Bool = true) {
        self.islandBytes = islandBytes
        self.relativeToFlanks = relativeToFlanks
        self.refuseBetweenLayoutFlanks = refuseBetweenLayoutFlanks
    }
}

/// Absorbs short unchanged islands that sit **inside** a run of change, so one edit is drawn as one
/// mark instead of as confetti (DEC-094).
///
/// Myers minimises the edit script over bytes, and byte-minimality reuses whatever it finds. Inside
/// a nine-line insertion it will hold the `r` of `number`, the `im` of `img`, and a lone space as
/// *matched*, because matching them is shorter. The reader is then shown a block of new code with
/// six unchanged islands punched through it, and has to work out that none of them means anything.
///
/// **This cannot be fixed in `D`.** Those islands are matched bytes; dropping them lowers the total
/// matched length below the LCS, and the brute-force check over 600 random pairs fails on the first
/// run. Byte-minimality is the wrong objective for presentation and the right one for a validator,
/// which is why the two are separated here rather than reconciled.
///
/// **INV-2 survives by construction.** Relabelling `.unchanged` as presented only ever *grows* the
/// presented set, and growth is monotone: a byte of `D`'s hunks that was contained stays contained.
/// This is DEC-021's argument for grapheme snapping and DEC-047's for boundary snapping, applied a
/// third time. No invariant is reopened.
///
/// Four conditions, and the conjunction is what fails in the safe direction. Each has a case it is
/// there to stop:
///
/// - **Flanked on both sides by presented segments.** A trailing gap after the last change is not an
///   island; it is where the change ended.
/// - **No longer than `islandBytes`.** A 200-byte island between two 800-byte insertions is a whole
///   function hidden inside a mark.
/// - **No longer than the shorter of its two flanks.** Scale-free, and it is what saves a 6-byte gap
///   between two 3-byte edits: there the gap is real context between two real edits.
/// - **Every line the island touches already carries a presented byte from one of its flanks.** This
///   is the load-bearing rule, and it is a theorem rather than a heuristic: *absorption never changes
///   `changedLines`.* The metric M11-B measures — a line reported changed that was not — cannot move
///   in the wrong direction, whatever the floor is set to.
///
/// **There is no per-run allowance, and there was going to be one.** The obvious fear is a long
/// alternation of small edits swallowing its context whole, and the obvious answer is a cap on
/// absorbed bytes per run. The relative rule already implies it: with flanks `f₁ … fₙ` and islands
/// `i₁ … iₙ₋₁` where `iₖ ≤ min(fₖ, fₖ₊₁)`, the absorbed total is at most `f₁ + … + fₙ₋₁`, which is
/// strictly less than the run's own changed bytes. A cap at or above that is a knob that can never
/// turn, and this repository has recorded three separate defects that were exactly that.
///
/// And the run must agree with itself: two flanks are only absorbed between when they share a
/// `label`, a `disclosure`, a `link`, and a side of `confidenceFloor`. Absorbing between two
/// different moves would fabricate a third; absorbing across the floor would either lend confidence
/// to bytes that had none or spread doubt onto bytes that were attributed cleanly — `coalesceAdjacent`
/// refuses to merge for the same reason, and this pass must not smuggle past it what that one turns
/// away.
///
/// The absorbed island inherits its flanks' fields by `coalesceAdjacent`'s rules: the classification
/// when they agree and `nil` when they do not, and the lower confidence. Inheriting an agreed
/// classification is not a nicety — it is what stops M6-B's trap recurring, where splitting a
/// classified change into a classified core and unclassified flanks dropped M6-A's recall from 97.8%
/// to 40.9%.
public func absorbIslands(
    _ partition: Partition,
    bytes: [UInt8],
    settings: AbsorptionSettings = AbsorptionSettings()
) -> Partition {
    guard settings.islandBytes > 0, partition.segments.count >= 3 else { return partition }
    let segments = partition.segments
    let lines = LineIndex(bytes: bytes)

    // A line carries a presented byte when any presented segment overlaps it. Computed once over the
    // input, so the no-new-line rule is judged against the partition as it arrived rather than
    // against one this pass has already been changing.
    var presentedLines = Set<Int>()
    for segment in segments where segment.isPresented && segment.end > segment.start {
        for line in lines.touched(from: segment.start, to: segment.end) {
            presentedLines.insert(line)
        }
    }

    var absorb = [Bool](repeating: false, count: segments.count)
    for index in 1..<max(segments.count - 1, 1) where !segments[index].isPresented {
        guard segments[index - 1].isPresented, segments[index + 1].isPresented,
              qualifies(segments[index], between: segments[index - 1], and: segments[index + 1],
                        bytes: bytes, lines: lines, presentedLines: presentedLines,
                        settings: settings)
        else { continue }
        absorb[index] = true
    }

    var out: [Segment] = []
    out.reserveCapacity(segments.count)
    for (position, segment) in segments.enumerated() {
        guard absorb[position] else { out.append(segment); continue }
        let left = segments[position - 1]
        let right = segments[position + 1]
        out.append(Segment(
            start: segment.start,
            end: segment.end,
            label: left.label,
            classification: left.classification == right.classification ? left.classification : nil,
            disclosure: left.disclosure,
            confidence: min(left.confidence ?? 1, right.confidence ?? 1),
            link: left.link
        ))
    }
    return Partition(totalLength: partition.totalLength, segments: out)
}

/// Whether one unchanged segment may be absorbed between the two presented segments flanking it.
private func qualifies(
    _ island: Segment,
    between left: Segment,
    and right: Segment,
    bytes: [UInt8],
    lines: LineIndex,
    presentedLines: Set<Int>,
    settings: AbsorptionSettings
) -> Bool {
    guard island.length > 0, island.length <= settings.islandBytes else { return false }
    // **A fifth condition, and it is about what the flanks *are* rather than how long they are**
    // (DEC-117). The four rules above are all geometry: length, length against the flanks, and the
    // lines touched. None of them asks what the pass is absorbing across.
    //
    // Two flanks made of nothing but layout bytes are not a run of change with confetti in it. They
    // are a line break moving — which is exactly what a prettier rewrap produces — and the thing
    // between them is code the reader can see is untouched. The owner reported it as
    // *an attribute that did not change is drawn as if it had been added*, and the corpus case is
    // `formatSierotki(locale, t('…'))` rewrapped, where `locale` and `t('` sit between two runs of
    // indentation and are drawn inside one loud mark.
    //
    // The confetti this pass exists for is unaffected: inside a nine-line insertion the flanks are
    // runs of inserted **code**, not indentation, so the condition does not fire. And an island that
    // is itself only whitespace is still absorbed, because joining two line breaks across a space
    // says nothing a reader can disagree with.
    if settings.refuseBetweenLayoutFlanks,
       island.length >= layoutFlankIslandFloor,
       onlyLayoutBytes(bytes, left) || onlyLayoutBytes(bytes, right),
       !onlyLayoutBytes(bytes, island) {
        return false
    }
    // A move is the one label that is a claim about *both* sides: DEC-038 requires the two ranges to
    // be byte-identical, and the two sides are absorbed independently, so widening one is not
    // guaranteed to widen the other. Refused outright rather than guarded — T-11 caught this, and a
    // rule that holds only when the two sides happen to agree is not a rule.
    guard left.label != .moved, right.label != .moved else { return false }
    guard left.label == right.label, left.disclosure == right.disclosure, left.link == right.link,
          ((left.confidence ?? 1) < confidenceFloor) == ((right.confidence ?? 1) < confidenceFloor)
    else { return false }
    if settings.relativeToFlanks, island.length > min(left.length, right.length) { return false }
    // The no-new-line rule. An island may span a newline — the confetti this pass exists for does —
    // but only into lines its own flanks already mark.
    return lines.touched(from: island.start, to: island.end)
        .allSatisfy { presentedLines.contains($0) }
}

/// Whether every byte of a segment is a space, tab, carriage return or newline.
private func onlyLayoutBytes(_ bytes: [UInt8], _ segment: Segment) -> Bool {
    guard segment.start >= 0, segment.end <= bytes.count, segment.end > segment.start else {
        return false
    }
    return bytes[segment.start..<segment.end].allSatisfy(isLayoutByte)
}

/// Line starts on `0x0A` only, built once so the pass stays linear in the file rather than
/// quadratic in it. Same convention as `changedLines`: a range ending exactly on a newline does not
/// claim the line after it, and `\r` belongs to the line it terminates.
private struct LineIndex {
    private let starts: [Int]

    init(bytes: [UInt8]) {
        var starts = [0]
        for (offset, byte) in bytes.enumerated() where byte == 0x0A && offset + 1 < bytes.count {
            starts.append(offset + 1)
        }
        self.starts = starts
    }

    private func line(containing offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }

    func touched(from: Int, to: Int) -> Range<Int> {
        guard to > from else { return 0..<0 }
        return line(containing: from)..<(line(containing: to - 1) + 1)
    }
}
