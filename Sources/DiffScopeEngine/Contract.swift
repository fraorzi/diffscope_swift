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
    notices extra: [String] = []
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
        let oldMapper = Utf16OffsetMapper(bytes: model.oldBytes)
        let newMapper = Utf16OffsetMapper(bytes: model.newBytes)
        let oldMap = try oldMapper.map(byteOffsets: byteStops.flatMap { [$0.oldStart, $0.oldEnd] }
            + byteCollapses.flatMap { [$0.oldStart, $0.oldEnd] })
        let newMap = try newMapper.map(byteOffsets: byteStops.flatMap { [$0.newStart, $0.newEnd] }
            + byteCollapses.flatMap { [$0.newStart, $0.newEnd] })
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
        return RenderModel(
            pinOld: pinOld, pinNew: pinNew, mode: mode,
            payload: .text(old: old, new: new),
            coverageVerified: result.coverageChecked,
            notices: notices,
            stops: stops, collapses: collapses
        )
    } catch {
        notices.append("content is not valid UTF-8; no text rendering is offered")
        return RenderModel(
            pinOld: pinOld, pinNew: pinNew, mode: mode,
            payload: .unrenderable(reason: String(describing: error)),
            coverageVerified: result.coverageChecked,
            notices: notices,
            stops: [], collapses: []
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
        segments: segments
    )
}

public func encodeRenderModel(_ model: RenderModel) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(model), as: UTF8.self)
}
