import Foundation

/// Files that are compared by being drawn (DEC-063).
///
/// Three classes, not two. The classification error this replaced had been in the documents since
/// DEC-004: **SVG is not binary.** It is text that also renders, so both readings exist and the
/// reader picks; treating it as binary hides a real textual diff, and treating it as text alone
/// hides that the drawn mark moved.
public enum RenderableKind: Sendable, Equatable {
    /// Text that also renders. Both readings are complete.
    case textThatRenders(format: String)
    /// Pixels only.
    case raster(format: String)
    /// Neither: an archive, a generated blob, a font.
    case undisplayable
    /// Ordinary text, and the diff engine's business rather than this file's.
    case text

    public var rendersAsImage: Bool {
        switch self {
        case .textThatRenders, .raster: return true
        case .undisplayable, .text: return false
        }
    }
}

/// Classification by extension **and** by content, because a `.png` that is not a PNG is a thing
/// that happens (a placeholder, a Git LFS pointer, a rename that outran its content) and drawing
/// it would show the reader an empty frame with no explanation.
public func renderableKind(path: String, bytes: [UInt8]) -> RenderableKind {
    let name = path.lowercased()
    func hasPrefix(_ signature: [UInt8]) -> Bool {
        bytes.count >= signature.count && Array(bytes.prefix(signature.count)) == signature
    }

    if name.hasSuffix(".svg") {
        // An SVG is text, and its text is what makes it one. A file whose bytes are not valid
        // UTF-8 is not an SVG whatever it is called.
        guard String(bytes: bytes, encoding: .utf8)?.contains("<svg") == true else {
            return .undisplayable
        }
        return .textThatRenders(format: "SVG")
    }
    if hasPrefix([0x89, 0x50, 0x4e, 0x47]) { return .raster(format: "PNG") }
    if hasPrefix([0xff, 0xd8, 0xff]) { return .raster(format: "JPEG") }
    if hasPrefix([0x47, 0x49, 0x46, 0x38]) { return .raster(format: "GIF") }
    if bytes.count > 12, Array(bytes.prefix(4)) == Array("RIFF".utf8),
       Array(bytes[8..<12]) == Array("WEBP".utf8) { return .raster(format: "WebP") }

    // Names that promise an image and do not deliver one. Said rather than drawn blank.
    for suffix in [".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".ico"] where name.hasSuffix(suffix) {
        return .undisplayable
    }
    for suffix in [".zip", ".pdf", ".woff", ".woff2", ".ttf", ".otf", ".mp4", ".mov", ".wasm"]
    where name.hasSuffix(suffix) {
        return .undisplayable
    }
    return .text
}

/// Everything the rendered comparison has to say in words (DEC-063, `12-…` §5.5). Composed here
/// rather than in the view for the reason `baseSummary` is: a sentence the interface assembles
/// cannot be checked, and two of these are trust statements rather than labels.
public struct RenderedComparison: Sendable, Equatable {
    public let kind: RenderableKind
    public let oldBytes: Int
    public let newBytes: Int
    /// `nil` where the side does not exist — an image added or deleted in this comparison.
    public let oldSize: (width: Int, height: Int)?
    public let newSize: (width: Int, height: Int)?
    /// Pixels that differ, where a pixel comparison was made.
    public let differingPixels: Int?

    public init(kind: RenderableKind, oldBytes: Int, newBytes: Int,
                oldSize: (width: Int, height: Int)?, newSize: (width: Int, height: Int)?,
                differingPixels: Int?) {
        self.kind = kind
        self.oldBytes = oldBytes
        self.newBytes = newBytes
        self.oldSize = oldSize
        self.newSize = newSize
        self.differingPixels = differingPixels
    }

    public static func == (a: RenderedComparison, b: RenderedComparison) -> Bool {
        a.kind == b.kind && a.oldBytes == b.oldBytes && a.newBytes == b.newBytes
            && a.oldSize?.width == b.oldSize?.width && a.oldSize?.height == b.oldSize?.height
            && a.newSize?.width == b.newSize?.width && a.newSize?.height == b.newSize?.height
            && a.differingPixels == b.differingPixels
    }

    /// The budget above which no pixel comparison is attempted. Stated, and the mode is disabled
    /// with the reason rather than hidden — the same rule an unavailable scope follows.
    public static let megapixelBudget = 16

    public var withinPixelBudget: Bool {
        guard let newSize else { return false }
        return newSize.width * newSize.height <= Self.megapixelBudget * 1_000_000
    }

    public var dimensionsChanged: Bool {
        guard let oldSize, let newSize else { return true }
        return oldSize != newSize
    }
}

public func renderedComparisonSummary(_ comparison: RenderedComparison) -> String {
    func size(_ value: (width: Int, height: Int)?) -> String {
        value.map { "\($0.width) × \($0.height)" } ?? "—"
    }
    let bytes = "\(comparison.oldBytes) → \(comparison.newBytes) bytes"

    guard comparison.oldSize != nil else {
        return "New in this comparison — \(size(comparison.newSize)), \(comparison.newBytes) bytes. "
            + "There is no left side, so Blend, Split and Pixel diff have nothing to compare against."
    }
    guard comparison.newSize != nil else {
        return "Removed in this comparison — \(size(comparison.oldSize)), \(comparison.oldBytes) bytes. "
            + "There is no right side to compare against."
    }
    if !comparison.withinPixelBudget {
        return "\(size(comparison.oldSize)) → \(size(comparison.newSize)) · \(bytes). "
            + "Too large to compare pixel by pixel — over \(RenderedComparison.megapixelBudget) megapixels. "
            + "Both renderings are shown; Pixel diff is unavailable and says so rather than being hidden."
    }
    // The trust statement. Without it a reader sees an empty comparison and concludes the tool
    // found nothing, when what it found is a difference that does not reach the screen — DEC-023's
    // invisible difference, at the scale of a whole file.
    if comparison.differingPixels == 0 {
        return "The two files render identically — 0 pixels differ. The bytes differ: \(bytes). "
            + (comparison.kind == .textThatRenders(format: "SVG")
                ? "The source reading shows what changed."
                : "Nothing about the rendered result has moved.")
    }
    let pixels = comparison.differingPixels.map { "\($0) pixels differ" } ?? "not compared pixel by pixel"
    let dimensions = comparison.dimensionsChanged
        ? "\(size(comparison.oldSize)) → \(size(comparison.newSize))"
        : "\(size(comparison.newSize)) · unchanged"
    return "\(dimensions) · \(bytes) · \(pixels)"
}
