import DiffScopeEngine
import DiffScopeSyntax
import Foundation

/// A readable dump of what the structural layer actually produced for one pair of files.
///
/// `--emit-model` prints the render contract as JSON over `trivialModel`; neither half of that is
/// usable when the question is *why does this look wrong on screen*. This prints the structural
/// model the application builds, marked up inline, so a segment can be read against the line it
/// falls on.
func runEmitStructural(oldPath: String, newPath: String, displayPath: String, snapBudget: Int?,
                       islandFloor: Int? = nil) {
    let old = [UInt8]((try? Data(contentsOf: URL(fileURLWithPath: oldPath))) ?? Data())
    let new = [UInt8]((try? Data(contentsOf: URL(fileURLWithPath: newPath))) ?? Data())
    let parser = TSXParser()
    // Both passes are settable here because each is most likely to be *mistaken* for the other and
    // for the alignment: a widened flank, an absorbed island and a badly placed boundary all look
    // the same on screen, and turning one off at a time is how they are told apart.
    var settings = MatcherSettings()
    if let snapBudget { settings.boundarySnapBudget = snapBudget }
    if let islandFloor { settings.absorbIslandBytes = islandFloor }
    let result = structuralDiff(oldPath: displayPath, oldBytes: old, newPath: displayPath,
                                newBytes: new, parser: parser, settings: settings)
    let stats = result.stats
    let validation = validate(result.model)

    print("file: \(displayPath)")
    print("path: \(stats.usedFallback ? "raw (fallback)" : "structural")"
        + "  anchors=\(stats.anchors)  ambiguities=\(stats.ambiguities)"
        + "  moved=\(stats.movedSegments)  formatting-only=\(stats.formattingOnlySegments)")
    // `passed` reads only `violations`, so a run whose coverage check never happened printed
    // "passed" — the one word that hides the thing the reader of this tool is looking for. The
    // summary already distinguishes "verified" from "unverified (coverage budget exceeded)".
    print("validation: \(validation.passed ? validation.summary : "FAILED — \(validation.summary)")")
    if let degradation = stats.degradation { print("degradation: \(degradation.reason)") }
    print("")
    print("legend: ⟦label/classification⟧ … ⟧ marks one segment. `~` after the label means uncertain.")
    print("")
    emitSide("OLD", bytes: old, partition: result.model.oldPartition)
    print("")
    emitSide("NEW", bytes: new, partition: result.model.newPartition)

    // The unified layout's own view of the same model (DEC-096, DEC-102). Printed here because
    // "why is this element shown twice" is a question about blocks, and until now the only way to
    // ask it was to read the window.
    // DEC-048's groups, and the runs it found and could not offer. Until now the only way to ask
    // *why is this reflow not collapsed* was to read the window.
    let collapses = formattingCollapses(result.model)
    print("")
    print("=== FORMATTING GROUPS === offered=\(collapses.ranges.count) unpaired=\(collapses.unpaired)")
    for group in collapses.ranges {
        print("  old \(group.oldStart)..<\(group.oldEnd)  new \(group.newStart)..<\(group.newEnd)"
            + "  \(group.lines) lines, \(group.changes) changes")
    }

    print("")
    print("=== UNIFIED BLOCKS ===")
    let stops = changeStops(result.model)
    func lineOf(_ bytes: [UInt8], _ offset: Int) -> Int {
        var line = 1
        var index = 0
        while index < min(offset, bytes.count) {
            if bytes[index] == 0x0A { line += 1 }
            index += 1
        }
        return line
    }
    for (index, block) in unifiedBlocks(result.model, stops: stops).enumerated() {
        let oldLines = block.oldEnd > block.oldStart
            ? "\(lineOf(old, block.oldStart))–\(lineOf(old, block.oldEnd - 1))" : "—"
        let newLines = block.newEnd > block.newStart
            ? "\(lineOf(new, block.newStart))–\(lineOf(new, block.newEnd - 1))" : "—"
        let withheld = block.withheldOld.map { range in
            "\(lineOf(old, range.start))–\(lineOf(old, max(range.start, range.end - 1)))"
        }.joined(separator: ",")
        let note = block.reflowed
            ? "reflowed — the whole old half is withheld"
            : (withheld.isEmpty ? "" : "withheld old lines \(withheld)")
        print(String(format: "  %2d  old %-10@ new %-10@ ", index,
                     oldLines as NSString, newLines as NSString) + note)
    }
}

private func emitSide(_ title: String, bytes: [UInt8], partition: Partition) {
    var marked: [UInt8] = []
    marked.reserveCapacity(bytes.count + 64)
    var cursor = 0
    for segment in partition.segments {
        guard segment.label != .unchanged, segment.end > segment.start else { continue }
        if segment.start > cursor { marked.append(contentsOf: bytes[cursor..<segment.start]) }
        var tag = segment.label.rawValue
        if let classification = segment.classification { tag += "/" + classification }
        if let disclosure = segment.disclosure { tag += "!" + disclosure }
        if let link = segment.link { tag += "#\(link)" }
        if (segment.confidence ?? 1) < confidenceFloor { tag += "~" }
        marked.append(contentsOf: Array("⟦\(tag)|".utf8))
        marked.append(contentsOf: bytes[segment.start..<segment.end])
        marked.append(contentsOf: Array("⟧".utf8))
        cursor = segment.end
    }
    if cursor < bytes.count { marked.append(contentsOf: bytes[cursor...]) }

    print("=== \(title) ===")
    let text = String(decoding: marked, as: UTF8.self)
    let changed = Set(changedLines(bytes: bytes, partition: partition))
    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let number = index + 1
        print(String(format: "%@%5d | %@", changed.contains(number) ? "*" : " ", number,
                     String(line)))
    }
}
