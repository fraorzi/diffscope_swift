import DiffScopeEngine
import DiffScopeSyntax
import Foundation

func runMatchingChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    guard let parser = TSXParser() else { report("parser for matching", false); return }

    func diff(_ old: String, _ new: String, path: String = "a.tsx") -> StructuralResult {
        structuralDiff(oldPath: path, oldBytes: [UInt8](old.utf8),
                       newPath: path, newBytes: [UInt8](new.utf8), parser: parser)
    }

    func unchangedText(_ result: StructuralResult, side: Side) -> String {
        let partition = side == .old ? result.model.oldPartition : result.model.newPartition
        let bytes = side == .old ? result.model.oldBytes : result.model.newBytes
        var out = [UInt8]()
        for segment in partition.segments where segment.label == .unchanged {
            out.append(contentsOf: bytes[segment.start..<segment.end])
        }
        return String(decoding: out, as: UTF8.self)
    }

    print("\n=== the founding case: JSX wrapper removal ===")
    do {
        let result = diff("""
        <div>
          <Header />
          <Content />
        </div>
        """, """
        <>
          <Header />
          <Content />
        </>
        """)

        let violations = validate(result.model)
        report("wrapper removal: invariants hold", violations.passed, violations.summary)

        let keptOld = unchangedText(result, side: .old)
        let keptNew = unchangedText(result, side: .new)
        report("children survive as unchanged on the old side",
               keptOld.contains("<Header />") && keptOld.contains("<Content />"),
               keptOld.debugDescription)
        report("children survive as unchanged on the new side",
               keptNew.contains("<Header />") && keptNew.contains("<Content />"),
               keptNew.debugDescription)
        report("the wrapper itself is not reported unchanged",
               !keptOld.contains("div"), keptOld.debugDescription)
        report("most bytes are preserved rather than rewritten",
               Double(result.stats.unchangedBytesOld) / Double(result.model.oldBytes.count) > 0.5,
               "\(result.stats.unchangedBytesOld)/\(result.model.oldBytes.count) bytes, \(result.stats.anchors) anchors")
    }

    print("\n=== prop reordering must never read as 'no change' ===")
    do {
        let result = diff("<Button disabled size=\"lg\" variant=\"primary\" />",
                          "<Button\n  variant=\"primary\"\n  size=\"lg\"\n  disabled\n/>")
        report("prop reordering: invariants hold", validate(result.model).passed)
        report("model does not present 'no changes'", !result.model.presentsNoChanges)
        let movedOrKept = result.stats.movedSegments > 0 || unchangedText(result, side: .new).contains("primary")
        report("reordered content is reported as moved or preserved, never as rewritten",
               movedOrKept, "moved=\(result.stats.movedSegments)")
    }

    print("\n=== a single character edit stays local ===")
    do {
        let result = diff("const t = \"Witaj u\u{017C}ytkowniku\";\n",
                          "const t = \"Witaj, u\u{017C}ytkowniku\";\n")
        report("string edit: invariants hold", validate(result.model).passed)
        let ratio = Double(result.stats.unchangedBytesNew) / Double(result.model.newBytes.count)
        report("most of the line is still unchanged", ratio > 0.4,
               String(format: "%.0f%% unchanged", ratio * 100))
    }

    print("\n=== repeated identical siblings are surfaced, not guessed (DEC-031) ===")
    do {
        let repeated = """
        <ul>
          <Item />
          <Item />
          <Item />
        </ul>
        """
        let edited = """
        <ul>
          <Item />
          <Item x />
          <Item />
        </ul>
        """
        guard let oldTree = parser.parseTree([UInt8](repeated.utf8)),
              let newTree = parser.parseTree([UInt8](edited.utf8)) else {
            report("ambiguity fixture parses", false); return
        }
        report("ambiguity fixture parses", true)
        let mapping = matchTrees(old: oldTree, new: newTree)
        report("identical siblings produce a recorded ambiguity",
               !mapping.ambiguities.isEmpty,
               "\(mapping.ambiguities.count) ambiguity records")
        if let first = mapping.ambiguities.first {
            report("the ambiguity names more than one candidate per side",
                   first.oldCandidates.count > 1 || first.newCandidates.count > 1,
                   "old=\(first.oldCandidates.count) new=\(first.newCandidates.count)")
        }
        let result = diff(repeated, edited)
        report("ambiguity does not break the invariants", validate(result.model).passed)
        report("the ambiguity is carried into the result stats", result.stats.ambiguities > 0)
    }

    print("\n=== determinism ===")
    do {
        let a = diff("<div>\n  <A />\n  <B />\n</div>", "<>\n  <A />\n  <B />\n</>")
        let b = diff("<div>\n  <A />\n  <B />\n</div>", "<>\n  <A />\n  <B />\n</>")
        report("identical input yields identical anchors", a.stats.anchors == b.stats.anchors)
        report("identical input yields identical segments",
               a.model.oldPartition == b.model.oldPartition && a.model.newPartition == b.model.newPartition)
    }

    print("\n=== structural matching never invents equality ===")
    do {
        let result = diff("const a = 1;\n", "const a = 2;\n")
        report("a changed literal is not swallowed", !result.model.presentsNoChanges)
        report("invariants hold", validate(result.model).passed)

        let identical = diff("const a = 1;\n", "const a = 1;\n")
        report("byte-equal input is the only 'no changes' case", identical.model.presentsNoChanges)
    }

    print("\n=== fallback still reachable through the structural path ===")
    do {
        let css = structuralDiff(oldPath: "a.css", oldBytes: [UInt8](".a{}".utf8),
                                 newPath: "a.css", newBytes: [UInt8](".b{}".utf8), parser: parser)
        report("unsupported language falls back with a reason",
               css.stats.usedFallback && css.stats.fallbackReason != nil,
               css.stats.fallbackReason ?? "nil")
        report("and its fallback segments are presented", validate(css.model).passed)

        let conflicted = "const a = 1;\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> other\n"
        let conflict = structuralDiff(oldPath: "a.ts", oldBytes: [UInt8]("const a = 1;\n".utf8),
                                      newPath: "a.ts", newBytes: [UInt8](conflicted.utf8), parser: parser)
        report("merge conflict markers force fallback rather than being parsed",
               conflict.stats.usedFallback, conflict.stats.fallbackReason ?? "nil")
    }

    print("\n=== corpus: structural diff of real files against a perturbed copy ===")
    do {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath).deletingLastPathComponent()
        var checked = 0
        var failed = 0
        var unchangedRatio = 0.0
        var fellBack = 0

        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walker {
                if url.pathComponents.contains("node_modules") || url.pathComponents.contains(".build") {
                    walker.skipDescendants(); continue
                }
                guard url.pathExtension == "tsx" else { continue }
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size > 200, size < 60_000 else { continue }
                guard let data = try? Data(contentsOf: url) else { continue }
                let bytes = [UInt8](data)
                guard let text = String(bytes: bytes, encoding: .utf8) else { continue }

                let perturbed = text.replacingOccurrences(of: "className", with: "class_Name")
                guard perturbed != text else { continue }

                let result = structuralDiff(
                    oldPath: url.lastPathComponent, oldBytes: bytes,
                    newPath: url.lastPathComponent, newBytes: [UInt8](perturbed.utf8),
                    parser: parser
                )
                checked += 1
                if !validate(result.model).passed { failed += 1 }
                if result.stats.usedFallback { fellBack += 1 }
                unchangedRatio += Double(result.stats.unchangedBytesOld) / Double(max(1, bytes.count))
                if checked >= 120 { break }
            }
        }

        report("real files were structurally diffed", checked > 0, "\(checked) files")
        report("every structural diff satisfies the invariants", failed == 0, "\(failed) failed of \(checked)")
        if checked > 0 {
            let mean = unchangedRatio / Double(checked) * 100
            print(String(format: "        mean unchanged: %.1f%% · fallbacks: %d", mean, fellBack))
            report("a rename-like edit preserves most of the file", mean > 60,
                   String(format: "%.1f%%", mean))
        }
    }
}
