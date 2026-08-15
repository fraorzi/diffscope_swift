import DiffScopeEngine
import DiffScopeSyntax
import Foundation

/// One change should be one mark. `coalesceAdjacent` is the pass that makes that true, and these are
/// the properties it must not buy it with: it may not move a claim onto bytes it was not made about,
/// and it may not change what is presented.
func runCoalesceChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    func presented(_ partition: Partition) -> Set<Int> {
        var bytes = Set<Int>()
        for segment in partition.segments where segment.isPresented {
            for offset in segment.start..<segment.end { bytes.insert(offset) }
        }
        return bytes
    }

    print("\n=== coalescing adjacent segments: the mechanics ===")
    do {
        let fragmented = Partition(totalLength: 12, segments: [
            Segment(start: 0, end: 4, label: .changed, confidence: 1),
            Segment(start: 4, end: 8, label: .changed, confidence: 0.8),
            Segment(start: 8, end: 12, label: .unchanged, confidence: 1),
        ])
        let merged = coalesceAdjacent(fragmented)
        report("two adjacent changed segments become one",
               merged.segments.filter { $0.label == .changed }.count == 1,
               "\(merged.segments.count) segments")
        report("the merged run spans both", merged.segments.first?.end == 8)
        report("confidence takes the lower of the two", merged.segments.first?.confidence == 0.8)
        report("the presented byte set is untouched", presented(merged) == presented(fragmented))
        report("the partition still covers the file", merged.totalLength == 12)
        report("coalescing twice changes nothing", coalesceAdjacent(merged).segments == merged.segments)
    }

    print("\n=== what refuses to merge ===")
    do {
        func pair(_ a: Segment, _ b: Segment) -> Int {
            coalesceAdjacent(Partition(totalLength: 8, segments: [a, b])).segments.count
        }
        report("a different label is a different claim",
               pair(Segment(start: 0, end: 4, label: .changed),
                    Segment(start: 4, end: 8, label: .moved)) == 2)
        report("a gap between segments is not adjacency",
               coalesceAdjacent(Partition(totalLength: 12, segments: [
                   Segment(start: 0, end: 4, label: .changed),
                   Segment(start: 4, end: 8, label: .unchanged),
                   Segment(start: 8, end: 12, label: .changed),
               ])).segments.count == 3)
        report("a disclosure keeps the edges of the bytes it discloses",
               pair(Segment(start: 0, end: 4, label: .changed, disclosure: "invisible"),
                    Segment(start: 4, end: 8, label: .changed)) == 2)
        report("a move keeps the edges of the run that moved",
               pair(Segment(start: 0, end: 4, label: .changed, link: 1),
                    Segment(start: 4, end: 8, label: .changed)) == 2)

        // The negative control that keeps `uncertain` discriminating: merging across the floor would
        // spread doubt onto bytes that were attributed cleanly.
        report("a run below the confidence floor is not merged into one above it",
               pair(Segment(start: 0, end: 4, label: .changed, confidence: 0.6),
                    Segment(start: 4, end: 8, label: .changed, confidence: 1)) == 2)
        report("two runs on the same side of the floor do merge",
               pair(Segment(start: 0, end: 4, label: .changed, confidence: 0.8),
                    Segment(start: 4, end: 8, label: .changed, confidence: 1)) == 1)

        let disagreeing = coalesceAdjacent(Partition(totalLength: 8, segments: [
            Segment(start: 0, end: 4, label: .changed, classification: "whitespace"),
            Segment(start: 4, end: 8, label: .changed, classification: "quote-style"),
        ]))
        report("two classifications in one run leave it unclassified",
               disagreeing.segments.count == 1 && disagreeing.segments[0].classification == nil,
               disagreeing.segments[0].classification ?? "nil")
    }

    print("\n=== the pass reaches the shipping result ===")
    do {
        guard let parser = TSXParser() else { report("parser for the coalescing checks", false); return }
        // A reflow: one attribute list wrapped onto several lines. This is the shape that produced
        // seventeen marks on one line before the pass existed.
        let old = [UInt8]("<Image src={a.src} alt={a.alt} width={a.width} height={a.height} />\n".utf8)
        let new = [UInt8]("""
        <Image
          src={a.src}
          alt={a.alt}
          width={b?.width ?? a.width}
          height={b?.height ?? a.height}
        />

        """.utf8)
        let result = structuralDiff(oldPath: "a.tsx", oldBytes: old,
                                    newPath: "a.tsx", newBytes: new, parser: parser)
        report("the reflow fixture is structural", !result.stats.usedFallback)

        for (side, partition) in [("old", result.model.oldPartition), ("new", result.model.newPartition)] {
            var offending: String?
            for (a, b) in zip(partition.segments, partition.segments.dropFirst())
            where a.end == b.start && a.label == b.label && a.disclosure == b.disclosure
                && a.link == b.link
                && ((a.confidence ?? 1) < confidenceFloor) == ((b.confidence ?? 1) < confidenceFloor) {
                offending = "\(a.start)..<\(a.end) then \(b.start)..<\(b.end)"
                break
            }
            report("no two \(side) segments still say the same thing side by side",
                   offending == nil, offending ?? "")
        }

        report("the result still validates", validate(result.model).passed)
    }
}
