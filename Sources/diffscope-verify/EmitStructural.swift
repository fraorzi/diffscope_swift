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
    print("validation: \(validation.passed ? "passed" : "FAILED — \(validation.summary)")")
    if let degradation = stats.degradation { print("degradation: \(degradation.reason)") }
    print("")
    print("legend: ⟦label/classification⟧ … ⟧ marks one segment. `~` after the label means uncertain.")
    print("")
    emitSide("OLD", bytes: old, partition: result.model.oldPartition)
    print("")
    emitSide("NEW", bytes: new, partition: result.model.newPartition)
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
