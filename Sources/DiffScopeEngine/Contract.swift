import Foundation

public struct RenderSegment: Codable, Sendable, Equatable {
    public let start: Int
    public let end: Int
    public let label: String
    public let classification: String?
    public let group: String?
    public let disclosure: String?
    public let uncertain: Bool
    public let confidence: Double?
    /// Pairs the two sides of one move. Both sides carry the same value (DEC-038).
    public let link: Int?
}

/// Below this, a segment's alignment is worth marking as uncertain in the interface. Ordinary
/// changed segments sit at 0.8; anything less came from a guess the layer could not confirm.
public let confidenceFloor = 0.8

public struct RenderSide: Codable, Sendable, Equatable {
    public let text: String
    public let utf16Length: Int
    public let segments: [RenderSegment]
    /// One-based line numbers that carry a difference. The gutter paints these; it does not decide
    /// them (`12-…` §5.1).
    public let changedLines: [Int]
}

public enum RenderPayload: Codable, Sendable, Equatable {
    case text(old: RenderSide, new: RenderSide)
    case unrenderable(reason: String)

    private enum CodingKeys: String, CodingKey { case kind, old, new, reason }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(old, new):
            try container.encode("text", forKey: .kind)
            try container.encode(old, forKey: .old)
            try container.encode(new, forKey: .new)
        case let .unrenderable(reason):
            try container.encode("unrenderable", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "text":
            self = .text(
                old: try container.decode(RenderSide.self, forKey: .old),
                new: try container.decode(RenderSide.self, forKey: .new)
            )
        default:
            self = .unrenderable(reason: try container.decode(String.self, forKey: .reason))
        }
    }
}

public struct RenderModel: Codable, Sendable, Equatable {
    public let pinOld: String
    public let pinNew: String
    public let mode: String
    public let payload: RenderPayload
    public let coverageVerified: Bool
    public let notices: [String]
    /// Jump targets and folds, both sides together, in UTF-16 units like everything the
    /// renderer sees (DEC-044). Computed here rather than in JavaScript so they are checkable.
    public let stops: [ChangeStop]
    public let collapses: [CollapseRange]
    /// DEC-048: formatting-only runs offered as one group each. Empty in Expanded, whose whole
    /// job is to drop the quietening — the segment set is identical either way (INV-5).
    public let formattingCollapses: [FormattingCollapse]
    /// DEC-034: where the reader can be put back after a refresh, and where they go this time.
    public let anchors: [RefreshAnchor]
    public let restore: AnchorRestore?
}

public enum ContractError: Error, CustomStringConvertible {
    case mappingFailed(side: Side, underlying: String)

    public var description: String {
        switch self {
        case let .mappingFailed(side, underlying):
            return "could not map \(side.rawValue) side offsets: \(underlying)"
        }
    }
}

public func buildRenderModel(
    model: DiffModel,
    pinOld: String,
    pinNew: String,
    mode: String = "raw",
    validation: ValidationResult? = nil,
    notices extra: [String] = [],
    previousAnchor: RefreshAnchor? = nil
) -> RenderModel {
    let result = validation ?? validate(model)
    var notices: [String] = extra
    if !result.passed {
        notices.append("invariant violation — falling back to raw: \(result.summary)")
    }
    if !result.coverageChecked {
        notices.append("coverage not verified for this file")
    }

    do {
        let old = try renderSide(bytes: model.oldBytes, partition: model.oldPartition)
        let new = try renderSide(bytes: model.newBytes, partition: model.newPartition)
        let byteStops = changeStops(model)
        let byteCollapses = collapseRanges(model, stops: byteStops)
        // Expanded exists to stop quietening formatting changes, so it offers no formatting group.
        let byteFormatting = mode == "expanded" ? [] : formattingCollapses(model).ranges
        let byteAnchors = refreshAnchors(model)
        let oldMapper = Utf16OffsetMapper(bytes: model.oldBytes)
        let newMapper = Utf16OffsetMapper(bytes: model.newBytes)
        let oldMap = try oldMapper.map(byteOffsets: byteStops.flatMap { [$0.oldStart, $0.oldEnd] }
            + byteCollapses.flatMap { [$0.oldStart, $0.oldEnd] }
            + byteFormatting.flatMap { [$0.oldStart, $0.oldEnd] }
            + byteAnchors.map(\.oldStart))
        let newMap = try newMapper.map(byteOffsets: byteStops.flatMap { [$0.newStart, $0.newEnd] }
            + byteCollapses.flatMap { [$0.newStart, $0.newEnd] }
            + byteFormatting.flatMap { [$0.newStart, $0.newEnd] }
            + byteAnchors.map(\.newStart))
        let stops = byteStops.compactMap { stop -> ChangeStop? in
            guard let a = oldMap[stop.oldStart], let b = oldMap[stop.oldEnd],
                  let c = newMap[stop.newStart], let d = newMap[stop.newEnd] else { return nil }
            return ChangeStop(oldStart: a, oldEnd: b, newStart: c, newEnd: d)
        }
        let collapses = byteCollapses.compactMap { range -> CollapseRange? in
            guard let a = oldMap[range.oldStart], let b = oldMap[range.oldEnd],
                  let c = newMap[range.newStart], let d = newMap[range.newEnd] else { return nil }
            return CollapseRange(oldStart: a, oldEnd: b, newStart: c, newEnd: d, lines: range.lines)
        }
        let formatting = byteFormatting.compactMap { range -> FormattingCollapse? in
            guard let a = oldMap[range.oldStart], let b = oldMap[range.oldEnd],
                  let c = newMap[range.newStart], let d = newMap[range.newEnd] else { return nil }
            return FormattingCollapse(oldStart: a, oldEnd: b, newStart: c, newEnd: d,
                                      lines: range.lines, changes: range.changes)
        }
        let anchors = byteAnchors.compactMap { anchor -> RefreshAnchor? in
            guard let a = oldMap[anchor.oldStart], let b = newMap[anchor.newStart] else { return nil }
            return RefreshAnchor(digest: anchor.digest, occurrence: anchor.occurrence,
                                 oldStart: a, newStart: b)
        }
        return RenderModel(
            pinOld: pinOld, pinNew: pinNew, mode: mode,
            payload: .text(old: old, new: new),
            coverageVerified: result.coverageChecked,
            notices: notices,
            stops: stops, collapses: collapses,
            formattingCollapses: formatting,
            anchors: anchors,
            restore: resolveAnchor(previous: previousAnchor, candidates: anchors)
        )
    } catch {
        notices.append("content is not valid UTF-8; no text rendering is offered")
        return RenderModel(
            pinOld: pinOld, pinNew: pinNew, mode: mode,
            payload: .unrenderable(reason: String(describing: error)),
            coverageVerified: result.coverageChecked,
            notices: notices,
            stops: [], collapses: [],
            formattingCollapses: [], anchors: [], restore: nil
        )
    }
}

func renderSide(bytes: [UInt8], partition: Partition) throws -> RenderSide {
    let mapper = Utf16OffsetMapper(bytes: bytes)
    var boundaries: [Int] = [0, bytes.count]
    for segment in partition.segments {
        boundaries.append(segment.start)
        boundaries.append(segment.end)
    }
    let mapping = try mapper.map(byteOffsets: boundaries)
    guard let text = String(bytes: bytes, encoding: .utf8) else {
        throw Utf16MappingError.invalidUTF8(atByte: 0)
    }

    var segments: [RenderSegment] = []
    segments.reserveCapacity(partition.segments.count)
    for segment in partition.segments {
        guard let start = mapping[segment.start], let end = mapping[segment.end] else { continue }
        segments.append(RenderSegment(
            start: start,
            end: end,
            label: segment.label.rawValue,
            classification: segment.classification,
            group: classificationGroup(of: segment.classification),
            disclosure: segment.disclosure,
            uncertain: (segment.confidence ?? 1) < confidenceFloor,
            confidence: segment.confidence,
            link: segment.link
        ))
    }

    return RenderSide(
        text: text,
        utf16Length: mapping[bytes.count] ?? 0,
        segments: segments,
        changedLines: changedLines(bytes: bytes, partition: partition)
    )
}

/// One-based line numbers carrying a difference, for the gutter.
///
/// `12-desktop-ux-specification.md` §5.1 names three carriers of change meaning — *"gutter,
/// underline, and background texture"* — and the gutter was the missing one.
///
/// Computed here rather than derived in the renderer from the segments, for the same reason
/// navigation stops and folds are (M7-A): a fact about the model belongs to the model, and a fact
/// the renderer derives on its own cannot be checked without a webview. It is a small array of
/// integers next to a document, so carrying it costs nothing worth measuring.
///
/// Lines are counted on **bytes**, splitting on `0x0A` only. A `\r` therefore belongs to the line it
/// terminates, which is what makes a CRLF-only change land on the line it actually changed.
public func changedLines(bytes: [UInt8], partition: Partition) -> [Int] {
    guard !bytes.isEmpty else { return [] }
    var lineStarts: [Int] = [0]
    for (offset, byte) in bytes.enumerated() where byte == 0x0A && offset + 1 < bytes.count {
        lineStarts.append(offset + 1)
    }

    func line(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low + 1
    }

    var lines = Set<Int>()
    for segment in partition.segments where segment.label != .unchanged {
        // An empty segment cannot mark a line, and a segment ending exactly on a newline should
        // not claim the line after it.
        guard segment.end > segment.start else { continue }
        let first = line(containing: segment.start)
        let last = line(containing: segment.end - 1)
        for number in first...last { lines.insert(number) }
    }
    return lines.sorted()
}

public func encodeRenderModel(_ model: RenderModel) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(model), as: UTF8.self)
}
