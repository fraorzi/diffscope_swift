import DiffScopeEngine
import DiffScopeSyntax
import Foundation

func runClassificationChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    print("\n=== classification: detectors on aligned pairs ===")
    do {
        func classify(_ old: String, _ new: String) -> ChangeClass? {
            changeClassification(old: [UInt8](old.utf8), new: [UInt8](new.utf8))
        }

        report("indentation reads as whitespace", classify("  a", "    a") == .whitespace)
        report("an added blank line reads as whitespace", classify("a\nb", "a\n\nb") == .whitespace)
        report("quote swap reads as quote-style", classify("'x'", "\"x\"") == .quoteStyle)
        report("an added trailing comma reads as trailing-comma",
               classify("[a, b]", "[a, b,]") == .trailingComma)
        report("redundant parentheses read as paren-only", classify("a + b", "(a + b)") == .parenOnly)
        report("swapped arguments read as reordering",
               classify("f(a, b)", "f(b, a)") == .reordering, String(describing: classify("f(a, b)", "f(b, a)")))
        report("reordering is not formatting-only",
               ChangeClass.reordering.group == .potentiallyBehaviorAffecting)

        print("        false-positive guards — a wrong 'formatting-only' is a trust defect")
        report("a changed literal is not classified", classify("const a = 1;", "const a = 2;") == nil)
        report("a loosened comparison is not classified", classify("a === b", "a == b") == nil)
        report("a renamed identifier is not classified", classify("getUser()", "getPerson()") == nil)
        report("a removed argument is not classified", classify("f(a, b)", "f(a)") == nil)
        report("an inserted statement is not classified", classify("a();", "a();\nb();") == nil)
        report("identical input is never classified", classify("a", "a") == nil)
    }

    print("\n=== classification: labels never suppress, and reach the render contract ===")
    do {
        guard let parser = TSXParser() else { report("parser for classification", false); return }
        func diff(_ old: String, _ new: String) -> StructuralResult {
            structuralDiff(oldPath: "a.tsx", oldBytes: [UInt8](old.utf8),
                           newPath: "a.tsx", newBytes: [UInt8](new.utf8), parser: parser)
        }
        func classifications(_ result: StructuralResult) -> Set<String> {
            var found = Set<String>()
            for partition in [result.model.oldPartition, result.model.newPartition] {
                for segment in partition.segments {
                    if let name = segment.classification { found.insert(name) }
                }
            }
            return found
        }

        let quotes = diff("const a = 'x';\n", "const a = \"x\";\n")
        report("a quote-style change still reports a difference", !quotes.model.presentsNoChanges)
        report("a quote-style change still satisfies the invariants", validate(quotes.model).passed)
        report("a quote-style change is labelled, not hidden",
               quotes.stats.formattingOnlySegments > 0,
               "\(quotes.stats.formattingOnlySegments) formatting-only segments")

        let indent = diff("function f() {\n  return 1;\n}\n", "function f() {\n    return 1;\n}\n")
        report("an indentation change is labelled formatting-only",
               indent.stats.formattingOnlySegments > 0, classifications(indent).sorted().joined(separator: ","))
        report("an indentation change still presents every changed byte", validate(indent.model).passed)

        let literal = diff("const a = 1;\n", "const a = 2;\n")
        report("a real edit carries no formatting-only label",
               literal.stats.formattingOnlySegments == 0, classifications(literal).sorted().joined(separator: ","))

        print("        diagnostic labels are gone from the vocabulary")
        let wrapper = diff("<div>\n  <A />\n</div>\n", "<>\n  <A />\n</>\n")
        let diagnostics: Set<String> = ["anchor", "filler", "refined", "moved-content"]
        let leaked = classifications(wrapper).union(classifications(literal)).intersection(diagnostics)
        report("no diagnostic label survives in the model", leaked.isEmpty, leaked.sorted().joined(separator: ","))
        let vocabulary = Set(ChangeClass.allCases.map(\.rawValue))
        let unknown = classifications(wrapper).union(classifications(indent))
            .union(classifications(quotes)).subtracting(vocabulary)
        report("every classification comes from the recorded vocabulary", unknown.isEmpty,
               unknown.sorted().joined(separator: ","))
        report("wrapper removal still preserves its children", validate(wrapper.model).passed)

        let render = buildRenderModel(model: indent.model, pinOld: "a", pinNew: "b", mode: "structural")
        if case let .text(old, new) = render.payload {
            let groups = Set((old.segments + new.segments).compactMap(\.group))
            report("the render contract carries the grouping",
                   groups.contains(ClassificationGroup.formattingOnly.rawValue),
                   groups.sorted().joined(separator: ","))
            let grouped = (old.segments + new.segments).filter { $0.group != nil }
            report("grouped segments are still presented as changes, never as unchanged",
                   grouped.allSatisfy { $0.label != "unchanged" },
                   "\(grouped.count) grouped segments")
        } else {
            report("the render contract carries the grouping", false, "payload was not text")
        }
    }

    print("\n=== INV-5 and INV-4: modes agree, fallbacks are visible ===")
    do {
        guard let parser = TSXParser() else { report("parser for the mode checks", false); return }
        let result = structuralDiff(
            oldPath: "a.tsx", oldBytes: [UInt8]("function f() {\n  return 1;\n}\n".utf8),
            newPath: "a.tsx", newBytes: [UInt8]("function f() {\n    return 2;\n}\n".utf8),
            parser: parser
        )
        let structural = buildRenderModel(model: result.model, pinOld: "a", pinNew: "b", mode: "structural")
        let expanded = buildRenderModel(model: result.model, pinOld: "a", pinNew: "b", mode: "expanded")
        guard case let .text(structuralOld, structuralNew) = structural.payload,
              case let .text(expandedOld, expandedNew) = expanded.payload else {
            report("both modes render text", false); return
        }
        report("INV-5: Structural and Expanded produce identical segment sets",
               structuralOld.segments == expandedOld.segments
                   && structuralNew.segments == expandedNew.segments,
               "\(structuralOld.segments.count) vs \(expandedOld.segments.count) segments")
        report("the modes differ only in the declared mode", structural.mode != expanded.mode)
        report("Raw stays available on the same pinned pair",
               buildRenderModel(model: trivialModel(oldBytes: result.model.oldBytes,
                                                    newBytes: result.model.newBytes),
                                pinOld: "a", pinNew: "b").pinOld == structural.pinOld)

        let css = structuralDiff(oldPath: "a.css", oldBytes: [UInt8](".a{}".utf8),
                                 newPath: "a.css", newBytes: [UInt8](".b{}".utf8), parser: parser)
        let cssRender = buildRenderModel(
            model: css.model, pinOld: "a", pinNew: "b", mode: "structural",
            notices: ["raw for this file — \(css.stats.fallbackReason ?? "")"]
        )
        report("INV-4: a fallback reaches the interface as a notice",
               cssRender.notices.contains { $0.hasPrefix("raw for this file") },
               cssRender.notices.joined(separator: " | "))
        if case let .text(old, _) = cssRender.payload {
            report("and its segments are labelled fallback, not unchanged",
                   old.segments.allSatisfy { $0.label == "fallback" }, "\(old.segments.count) segments")
        }
    }

    print("\n=== M6-A corpus: does the vocabulary fire on real files, and only where it should? ===")
    do {
        guard let parser = TSXParser() else { report("parser for the classification corpus", false); return }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath).deletingLastPathComponent()

        var checked = 0
        var reindentClassified = 0
        var reindentUnclassifiedChanges = 0
        var renameFormattingOnly = 0
        var renameChangedSegments = 0

        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walker {
                if url.pathComponents.contains("node_modules") || url.pathComponents.contains(".build") {
                    walker.skipDescendants(); continue
                }
                guard url.pathExtension == "tsx" else { continue }
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size > 200, size < 60_000,
                      let data = try? Data(contentsOf: url),
                      let text = String(bytes: [UInt8](data), encoding: .utf8) else { continue }

                let reindented = text.replacingOccurrences(of: "\n  ", with: "\n    ")
                let renamed = text.replacingOccurrences(of: "className", with: "class_Name")
                guard reindented != text, renamed != text else { continue }

                let bytes = [UInt8](data)
                let name = url.lastPathComponent
                let whitespaceOnly = structuralDiff(oldPath: name, oldBytes: bytes,
                                                    newPath: name, newBytes: [UInt8](reindented.utf8),
                                                    parser: parser)
                let rename = structuralDiff(oldPath: name, oldBytes: bytes,
                                            newPath: name, newBytes: [UInt8](renamed.utf8),
                                            parser: parser)

                for partition in [whitespaceOnly.model.oldPartition, whitespaceOnly.model.newPartition] {
                    for segment in partition.segments where segment.label == .changed {
                        if segment.classification == nil { reindentUnclassifiedChanges += 1 }
                        else { reindentClassified += 1 }
                    }
                }
                for partition in [rename.model.oldPartition, rename.model.newPartition] {
                    for segment in partition.segments where segment.label == .changed {
                        renameChangedSegments += 1
                        if classificationGroup(of: segment.classification)
                            == ClassificationGroup.formattingOnly.rawValue { renameFormattingOnly += 1 }
                    }
                }

                checked += 1
                if checked >= 120 { break }
            }
        }

        report("real files were classified", checked > 0, "\(checked) files")
        if checked > 0 {
            let reindentTotal = reindentClassified + reindentUnclassifiedChanges
            let hitRate = reindentTotal == 0 ? 0 : Double(reindentClassified) / Double(reindentTotal) * 100
            print(String(format: "        whitespace-only edit: %.1f%% of changed segments classified (%d of %d)",
                         hitRate, reindentClassified, reindentTotal))
            print(String(format: "        rename edit: %d of %d changed segments claimed formatting-only",
                         renameFormattingOnly, renameChangedSegments))
            report("a whitespace-only edit is recognised on real files", hitRate > 50,
                   String(format: "%.1f%%", hitRate))
            report("a rename is never claimed to be formatting-only on real files",
                   renameFormattingOnly == 0, "\(renameFormattingOnly) false claims")
        }
    }
}
