import DiffScopeEngine
import Foundation

func runContractChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    print("\n=== X-1 probe: the conversion asserts the UNIT, not just round-tripping ===")
    do {
        let source = [
            "const a = 1;",
            "const b = \"\u{00F3}\";",
            "const c = \"Z\u{0307}ABKA\";",
            "const d = \"\u{4E2D}\";",
            "const e = \"\u{1F600}\";",
            "const MARKER = 9;",
        ].joined(separator: "\n")

        let bytes = [UInt8](source.utf8)
        guard let markerRange = source.range(of: "MARKER") else {
            report("probe contains MARKER", false); return
        }
        let prefix = String(source[source.startIndex..<markerRange.lowerBound])
        let byteOffset = prefix.utf8.count
        let utf16Offset = prefix.utf16.count
        let codepointOffset = prefix.unicodeScalars.count

        report("probe integrity: the three units genuinely differ",
               byteOffset != utf16Offset && utf16Offset != codepointOffset,
               "bytes=\(byteOffset) utf16=\(utf16Offset) codepoints=\(codepointOffset)")

        let mapper = Utf16OffsetMapper(bytes: bytes)
        let mapped = (try? mapper.utf16Offset(ofByte: byteOffset)) ?? -1
        report("byte offset maps to the UTF-16 offset, not the byte or codepoint offset",
               mapped == utf16Offset && mapped != byteOffset && mapped != codepointOffset,
               "mapped=\(mapped) expected=\(utf16Offset)")

        let units = Array(source.utf16)
        let recovered = String(decoding: units[mapped..<min(mapped + 6, units.count)], as: UTF16.self)
        report("slicing the JS-side string at the mapped offset yields MARKER",
               recovered == "MARKER", recovered.debugDescription)

        let naive = String(decoding: bytes[utf16Offset..<min(utf16Offset + 6, bytes.count)], as: UTF8.self)
        report("applying the UTF-16 offset to the byte buffer yields plausible WRONG text",
               naive != "MARKER", naive.debugDescription)
        report("and the two offsets genuinely disagree", byteOffset != utf16Offset,
               "bytes=\(byteOffset) utf16=\(utf16Offset)")

        report("NFD sequence survived into the probe", source.contains("Z\u{0307}"))
    }

    print("\n=== conversion edge cases ===")
    do {
        let ascii = Utf16OffsetMapper(bytes: [UInt8]("abc".utf8))
        report("ascii maps identically", (try? ascii.utf16Offset(ofByte: 3)) == 3)

        let astral = Utf16OffsetMapper(bytes: [UInt8]("\u{1F600}".utf8))
        report("a 4-byte character counts as two UTF-16 units",
               (try? astral.utf16Offset(ofByte: 4)) == 2)

        let combining = Utf16OffsetMapper(bytes: [UInt8]("Z\u{0307}".utf8))
        report("a decomposed pair counts as two UTF-16 units",
               (try? combining.utf16Offset(ofByte: 3)) == 2)

        let mixed = Utf16OffsetMapper(bytes: [UInt8]("a\u{00F3}\u{4E2D}\u{1F600}b".utf8))
        report("mixed widths accumulate correctly", (try? mixed.utf16Offset(ofByte: 11)) == 6,
               String(describing: try? mixed.utf16Offset(ofByte: 11)))

        var split = false
        do { _ = try astral.utf16Offset(ofByte: 2) } catch Utf16MappingError.offsetSplitsCharacter { split = true } catch {}
        report("an offset inside a character is refused, not rounded", split)

        var invalid = false
        let broken = Utf16OffsetMapper(bytes: [0x61, 0xFF, 0x62])
        do { _ = try broken.utf16Offset(ofByte: 3) } catch Utf16MappingError.invalidUTF8 { invalid = true } catch {}
        report("invalid UTF-8 is refused rather than guessed", invalid)

        var outOfRange = false
        do { _ = try ascii.utf16Offset(ofByte: 99) } catch Utf16MappingError.offsetOutOfRange { outOfRange = true } catch {}
        report("an out-of-range offset is refused", outOfRange)
    }

    print("\n=== render contract ===")
    do {
        let old = [UInt8]("const t = \"Witaj u\u{017C}ytkowniku\";\n".utf8)
        let new = [UInt8]("const t = \"Witaj, u\u{017C}ytkowniku\";\n".utf8)
        let model = trivialModel(oldBytes: old, newBytes: new)
        let render = buildRenderModel(model: model, pinOld: "aaa", pinNew: "bbb")

        guard case let .text(oldSide, newSide) = render.payload else {
            report("render payload is text", false); return
        }
        report("render payload is text", true)
        report("old text round-trips exactly", Array(oldSide.text.utf8) == old)
        report("new text round-trips exactly", Array(newSide.text.utf8) == new)
        report("segment offsets are in UTF-16, shorter than the byte length",
               oldSide.utf16Length < old.count, "utf16=\(oldSide.utf16Length) bytes=\(old.count)")
        report("last segment ends exactly at the UTF-16 length",
               oldSide.segments.last?.end == oldSide.utf16Length)
        report("pin identity crosses with the model", render.pinOld == "aaa" && render.pinNew == "bbb")
        report("coverage status crosses with the model", render.coverageVerified)

        let json = (try? encodeRenderModel(render)) ?? ""
        report("model encodes to JSON", json.contains("\"pinOld\":\"aaa\""), String(json.prefix(80)))
        let decoded = try? JSONDecoder().decode(RenderModel.self, from: Data(json.utf8))
        report("model survives a JSON round trip", decoded == render)

        let binary = trivialModel(oldBytes: [0x00, 0xFF, 0xFE], newBytes: [0x00, 0xFF, 0xFD])
        let binaryRender = buildRenderModel(model: binary, pinOld: "x", pinNew: "y")
        var unrenderable = false
        if case .unrenderable = binaryRender.payload { unrenderable = true }
        report("non-UTF-8 content is declared unrenderable rather than mangled", unrenderable)
        report("and says so in a notice", binaryRender.notices.contains { $0.contains("not valid UTF-8") })
    }
}
