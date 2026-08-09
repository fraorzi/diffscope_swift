import AppKit
import DiffScopeEngine

/// The pixel half of the rendered comparison (DEC-063).
///
/// **Done here, in Swift, rather than in the webview.** Two reasons, and the second is the one
/// that decided it: a canvas that has drawn an SVG cannot be read back — the image taints it — so
/// a renderer-side pixel pass would work for PNGs and fail for exactly the format the product
/// owner asked about first. And the words the comparison says are composed in the engine, where
/// they can be checked; a count computed in the view would arrive after the sentence that quotes
/// it.
///
/// Nothing here executes repository content. `CGImageSource` decodes bytes; an SVG is *not* decoded
/// here at all — it is handed to the webview as an `<img>` source, where script inside it cannot
/// run (DEC-063, extending DEC-028).
enum ImageComparison {
    static func image(from bytes: [UInt8]) -> CGImage? {
        let data = Data(bytes) as CFData
        guard let source = CGImageSourceCreateWithData(data, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func size(of image: CGImage) -> (width: Int, height: Int) {
        (width: image.width, height: image.height)
    }

    /// Differing pixels, and a mask marking where. The mask is drawn rather than described because
    /// the alternative is a list of rectangles the view would have to believe.
    ///
    /// Alpha counts: a pixel that changed from transparent to white is a change a reader can see,
    /// and comparing only the colour channels would call it identical.
    static func compare(old: CGImage, new: CGImage) -> (differing: Int, mask: Data?) {
        let width = max(old.width, new.width)
        let height = max(old.height, new.height)
        guard width > 0, height > 0,
              width * height <= RenderedComparison.megapixelBudget * 1_000_000,
              let oldPixels = pixels(of: old, width: width, height: height),
              let newPixels = pixels(of: new, width: width, height: height) else {
            return (0, nil)
        }

        var differing = 0
        var mask = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: oldPixels.count, by: 4) {
            let same = oldPixels[index] == newPixels[index]
                && oldPixels[index + 1] == newPixels[index + 1]
                && oldPixels[index + 2] == newPixels[index + 2]
                && oldPixels[index + 3] == newPixels[index + 3]
            if same { continue }
            differing += 1
            // The mask is drawn in the mark colour at full alpha; the pane hatches it and outlines
            // it, so the marking survives greyscale (DEC-035) rather than relying on the fill.
            mask[index] = 255
            mask[index + 1] = 255
            mask[index + 2] = 255
            mask[index + 3] = 255
        }
        return (differing, differing == 0 ? nil : png(from: mask, width: width, height: height))
    }

    /// Both sides are drawn into a canvas of the same size, so an image that changed dimensions is
    /// still comparable — the region one side does not cover reads as transparent, which is a
    /// difference and is counted as one.
    private static func pixels(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        return buffer.withUnsafeMutableBytes { raw -> [UInt8]? in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: info) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return nil
        } ?? buffer
    }

    private static func png(from pixels: [UInt8], width: Int, height: Int) -> Data? {
        var buffer = pixels
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        return buffer.withUnsafeMutableBytes { raw -> Data? in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: info),
                  let image = context.makeImage() else { return nil }
            let representation = NSBitmapImageRep(cgImage: image)
            return representation.representation(using: .png, properties: [:])
        }
    }

    /// A `data:` URL, which is how the bytes reach an `<img>` without a file server and without
    /// leaving the sandbox. SVG goes the same way and is never inlined into the document.
    static func dataURL(bytes: [UInt8], mimeType: String) -> String {
        "data:\(mimeType);base64," + Data(bytes).base64EncodedString()
    }

    static func mimeType(for kind: RenderableKind) -> String {
        switch kind {
        case .textThatRenders: return "image/svg+xml"
        case let .raster(format):
            switch format {
            case "PNG": return "image/png"
            case "JPEG": return "image/jpeg"
            case "GIF": return "image/gif"
            case "WebP": return "image/webp"
            default: return "application/octet-stream"
            }
        case .undisplayable, .text: return "application/octet-stream"
        }
    }
}
