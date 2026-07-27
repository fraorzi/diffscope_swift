import DiffScopeEngine
import DiffScopeSyntax
import Foundation

func runDisclosureChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    print("\n=== DEC-023: differences that are real in the bytes and absent on screen ===")
    do {
        func detect(_ old: String, _ new: String) -> InvisibleDifference? {
            invisibleDifference(old: [UInt8](old.utf8), new: [UInt8](new.utf8))
        }

        report("the corpus's own ŻABKA case is a normalization-form difference",
               detect("Z\u{0307}ABKA", "\u{017B}ABKA") == .normalizationForm)
        report("a zero-width space is disclosed",
               detect("const a = 1;", "const\u{200B} a = 1;") == .invisibleControl)
        report("a bidi override is disclosed — the Trojan Source mechanism",
               detect("if (x) {", "if (\u{202E}x) {") == .invisibleControl)
        report("a non-breaking space is disclosed",
               detect("a b", "a\u{00A0}b") == .whitespaceLookalike)
        report("a tab against spaces is disclosed", detect("  x", "\tx") == .whitespaceLookalike)

        print("        negative controls — a visible change must never be called invisible")
        report("a changed literal is visible", detect("const a = 1;", "const a = 2;") == nil)
        report("added indentation is visible", detect("  x", "    x") == nil)
        report("a renamed identifier is visible", detect("getUser()", "getPerson()") == nil)
        report("identical text discloses nothing", detect("a", "a") == nil)

        report("codepoints are named for revelation",
               revealedCodepoints(in: [UInt8]("Z\u{0307}".utf8)) == ["U+0307"],
               revealedCodepoints(in: [UInt8]("Z\u{0307}".utf8)).joined(separator: " "))
        report("ordinary text reveals nothing", revealedCodepoints(in: [UInt8]("abc".utf8)).isEmpty)
    }

    print("\n=== disclosure survives the pipeline and reaches the contract ===")
    do {
        guard let parser = TSXParser() else { report("parser for the disclosure checks", false); return }
        let result = structuralDiff(
            oldPath: "a.tsx", oldBytes: [UInt8]("const label = \"Z\u{0307}ABKA\";\n".utf8),
            newPath: "a.tsx", newBytes: [UInt8]("const label = \"\u{017B}ABKA\";\n".utf8),
            parser: parser
        )
        report("the invisible case satisfies the invariants", validate(result.model).passed)
        report("and is never reported as 'no changes'", !result.model.presentsNoChanges)
        report("reconciliation and snapping do not drop the disclosure",
               result.stats.invisibleSegments > 0, "\(result.stats.invisibleSegments) segments")

        let render = buildRenderModel(model: result.model, pinOld: "a", pinNew: "b", mode: "structural")
        guard case let .text(old, new) = render.payload else {
            report("the disclosure reaches the render contract", false, "payload was not text"); return
        }
        let disclosed = (old.segments + new.segments).compactMap(\.disclosure)
        report("the disclosure reaches the render contract",
               disclosed.contains(InvisibleDifference.normalizationForm.rawValue),
               disclosed.joined(separator: ","))
        report("a disclosed segment is still presented as a change",
               (old.segments + new.segments).filter { $0.disclosure != nil }
                   .allSatisfy { $0.label != "unchanged" })

        let visible = structuralDiff(oldPath: "a.tsx", oldBytes: [UInt8]("const a = 1;\n".utf8),
                                     newPath: "a.tsx", newBytes: [UInt8]("const a = 2;\n".utf8),
                                     parser: parser)
        report("an ordinary edit discloses nothing", visible.stats.invisibleSegments == 0)
    }

    print("\n=== DEC-017: confidence is indicated, not merely computed ===")
    do {
        guard let parser = TSXParser() else { return }
        let reordered = structuralDiff(
            oldPath: "a.tsx", oldBytes: [UInt8]("<Button disabled size=\"lg\" variant=\"primary\" />".utf8),
            newPath: "a.tsx", newBytes: [UInt8]("<Button variant=\"primary\" size=\"lg\" disabled />".utf8),
            parser: parser
        )
        let render = buildRenderModel(model: reordered.model, pinOld: "a", pinNew: "b", mode: "structural")
        guard case let .text(old, new) = render.payload else { report("reordering renders", false); return }
        let segments = old.segments + new.segments
        report("a segment below the confidence floor is marked uncertain",
               segments.contains { $0.uncertain },
               segments.compactMap(\.confidence).map { String(format: "%.1f", $0) }.joined(separator: " "))
        report("an ordinary changed segment is not marked uncertain",
               segments.contains { $0.label == "changed" && !$0.uncertain })
        report("uncertainty follows the recorded floor, not a renderer opinion",
               segments.allSatisfy { $0.uncertain == (($0.confidence ?? 1) < confidenceFloor) })
    }

    print("\n=== M6-C corpus: how often is this real? ===")
    do {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath).deletingLastPathComponent()
        var scanned = 0
        var withDecomposed = 0
        var withControls = 0
        var withLookalikes = 0

        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walker {
                if url.pathComponents.contains("node_modules") || url.pathComponents.contains(".build") {
                    walker.skipDescendants(); continue
                }
                guard ["tsx", "ts", "jsx", "js"].contains(url.pathExtension) else { continue }
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 200_000,
                      let data = try? Data(contentsOf: url),
                      let text = String(bytes: [UInt8](data), encoding: .utf8) else { continue }

                scanned += 1
                if isDecomposed(text) { withDecomposed += 1 }
                if text.unicodeScalars.contains(where: { invisibleControlScalars.contains($0) }) { withControls += 1 }
                if text.unicodeScalars.contains(where: { whitespaceLookalikeScalars.contains($0) }) { withLookalikes += 1 }
                if scanned >= 8000 { break }
            }
        }

        report("real sources were scanned for invisible content", scanned > 0, "\(scanned) files")
        print(String(format: "        %d of %d files carry a decomposed sequence, %d a zero-width or bidi control, %d a whitespace lookalike",
                     withDecomposed, scanned, withControls, withLookalikes))
        report("the ŻABKA finding is not a one-off fixture", withDecomposed > 0,
               "\(withDecomposed) files")
    }
}
