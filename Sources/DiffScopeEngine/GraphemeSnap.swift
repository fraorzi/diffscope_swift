import Foundation

/// `14-losslessness-and-trust-model.md` §4: *"Presented regions are snapped **outward** to
/// grapheme-cluster boundaries. This is safe because outward expansion is **monotone**: growing a
/// region can never push a changed byte outside it, so display snapping cannot break INV-2."*
///
/// That paragraph had no implementation until T-10 was written as a named check and failed on
/// `unicode-graphemes`. The canonical diff of `'😀'` → `'😀‍💻'` is an insertion that begins
/// *between* the emoji and the zero-width joiner, which is correct on bytes and unrenderable on
/// screen: the boundary falls inside one grapheme cluster, so the two panes would cut a single
/// glyph in half and mark one piece.
///
/// Comparison stays on bytes (DEC-021). This is a display pass and nothing else.
public func snapToGraphemeBoundaries(_ partition: Partition, bytes: [UInt8]) -> Partition {
    guard !partition.segments.isEmpty else { return partition }
    guard let boundaries = graphemeBoundarySet(bytes) else { return partition }

    /// Which label wins when a boundary between two segments has to move. Growing a changed region
    /// is the safe direction — INV-2 is containment, so a presented range may always be larger.
    func rank(_ label: SegmentLabel) -> Int {
        switch label {
        case .changed, .fallback, .moved: return 2
        case .unchanged: return 0
        }
    }

    var cuts: [Int] = [partition.segments[0].start]
    for index in 1..<partition.segments.count {
        let left = partition.segments[index - 1]
        let right = partition.segments[index]
        let cut = right.start
        if boundaries.contains(cut) {
            cuts.append(cut)
            continue
        }
        // The boundary sits inside a cluster. Move it so that the *more presented* side grows: to
        // the start of the cluster when the right-hand segment is the changed one, to its end when
        // the left-hand one is. Equal ranks fall to the cluster start, which is still monotone
        // because neither side is claiming less than it did.
        let start = clusterStart(containing: cut, in: boundaries)
        let end = clusterEnd(containing: cut, in: boundaries, limit: bytes.count)
        cuts.append(rank(left.label) > rank(right.label) ? end : start)
    }
    cuts.append(partition.segments[partition.segments.count - 1].end)

    var snapped: [Segment] = []
    for (index, segment) in partition.segments.enumerated() {
        let start = cuts[index]
        let end = cuts[index + 1]
        // A segment swallowed whole by its neighbour's expansion disappears rather than surviving
        // as a zero-width one, which T-0 forbids outright.
        guard end > start, start >= (snapped.last?.end ?? 0) else { continue }
        snapped.append(Segment(
            start: max(start, snapped.last?.end ?? 0), end: end,
            label: segment.label,
            classification: segment.classification,
            disclosure: segment.disclosure,
            confidence: segment.confidence,
            link: segment.link
        ))
    }
    guard let first = snapped.first, let last = snapped.last,
          first.start == 0, last.end == partition.totalLength
    else { return partition }
    return Partition(totalLength: partition.totalLength, segments: snapped)
}

/// Byte offsets at which a grapheme cluster begins, plus the end of the buffer. `nil` when the
/// bytes are not valid UTF-8 — content the product refuses to interpret has no cluster structure,
/// and inventing one would be the guessing DEC-044 forbids.
func graphemeBoundarySet(_ bytes: [UInt8]) -> Set<Int>? {
    guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
    var offsets: Set<Int> = [0, bytes.count]
    var offset = 0
    for character in text {
        offset += String(character).utf8.count
        offsets.insert(offset)
    }
    return offsets
}

private func clusterStart(containing offset: Int, in boundaries: Set<Int>) -> Int {
    var candidate = offset
    while candidate > 0 && !boundaries.contains(candidate) { candidate -= 1 }
    return candidate
}

private func clusterEnd(containing offset: Int, in boundaries: Set<Int>, limit: Int) -> Int {
    var candidate = offset
    while candidate < limit && !boundaries.contains(candidate) { candidate += 1 }
    return candidate
}
