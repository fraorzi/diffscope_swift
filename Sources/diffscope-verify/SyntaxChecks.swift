import DiffScopeEngine
import DiffScopeSyntax
import Foundation

func runSyntaxChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    guard let parser = TSXParser() else {
        report("tree-sitter TSX parser initialises", false)
        return
    }
    report("tree-sitter TSX parser initialises", true)

    print("\n=== the reason for this architecture: offsets are byte-native ===")
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
        guard let markerRange = source.range(of: "MARKER") else { report("probe has MARKER", false); return }
        let prefix = String(source[source.startIndex..<markerRange.lowerBound])
        let byteOffset = prefix.utf8.count
        let utf16Offset = prefix.utf16.count

        report("probe integrity: byte and UTF-16 offsets differ", byteOffset != utf16Offset,
               "bytes=\(byteOffset) utf16=\(utf16Offset)")

        guard let outcome = parser.parse(bytes) else { report("probe parses", false); return }
        let marker = outcome.leaves.first {
            $0.end <= bytes.count && String(decoding: bytes[$0.start..<$0.end], as: UTF8.self) == "MARKER"
        }
        report("the MARKER identifier is found as a leaf", marker != nil)
        report("its start byte equals the UTF-8 byte offset, NOT the UTF-16 offset",
               marker?.start == byteOffset,
               "leaf=\(marker?.start ?? -1) bytes=\(byteOffset) utf16=\(utf16Offset)")
        report("root end byte equals the byte count, not the UTF-16 length",
               outcome.rootEndByte == bytes.count && bytes.count != source.utf16.count,
               "root=\(outcome.rootEndByte) bytes=\(bytes.count) utf16=\(source.utf16.count)")
    }

    print("\n=== DEC-024 construction on real source ===")
    do {
        let source = """
        export const A = () => (
          <div className="flex">
            <Header title="Cze\u{015B}\u{0107}" />
            <Content />
          </div>
        );

        """
        let bytes = [UInt8](source.utf8)
        guard let outcome = parser.parse(bytes) else { report("real source parses", false); return }
        let result = buildSyntaxPartition(bytes: bytes, leaves: outcome.leaves)

        report("partition is well formed", partitionDefects(result.partition).isEmpty,
               partitionDefects(result.partition).map(\.description).joined(separator: "; "))
        report("partition reconstructs the source byte for byte",
               reconstruct(result.partition, from: bytes) == bytes)
        report("filler segments exist, because leaves exclude whitespace",
               result.stats.fillerSegments > 0, "\(result.stats.fillerSegments) filler segments")
        report("no zero-width segment survives", result.partition.segments.allSatisfy { $0.end > $0.start })
    }

    print("\n=== error recovery keeps the partition valid ===")
    do {
        let broken = "export const A = () => (\n  <div className=\"x\">\n    <Header"
        let bytes = [UInt8](broken.utf8)
        guard let outcome = parser.parse(bytes) else { report("broken source still parses", false); return }
        report("broken source still yields a tree", true)
        report("the tree reports error nodes", outcome.hasErrorNodes)

        let result = buildSyntaxPartition(bytes: bytes, leaves: outcome.leaves)
        report("partition of broken source is still well formed",
               partitionDefects(result.partition).isEmpty,
               partitionDefects(result.partition).map(\.description).joined(separator: "; "))
        report("partition of broken source still reconstructs exactly",
               reconstruct(result.partition, from: bytes) == bytes)
    }

    print("\n=== file classification (DEC-004) ===")
    do {
        report("tsx is structural", classify(path: "a.tsx", bytes: [UInt8]("const a = 1;".utf8)).isStructural)
        report("ts is structural", classify(path: "a.ts", bytes: [UInt8]("const a = 1;".utf8)).isStructural)
        report("css falls back", !classify(path: "a.css", bytes: [UInt8](".a{}".utf8)).isStructural)
        report("markdown falls back", !classify(path: "a.md", bytes: [UInt8]("# hi".utf8)).isStructural)
        report("a NUL byte marks content binary",
               !classify(path: "a.ts", bytes: [0x61, 0x00, 0x62]).isStructural)
        report("invalid UTF-8 falls back",
               !classify(path: "a.ts", bytes: [0x61, 0xFF, 0x62]).isStructural)

        let conflicted = [UInt8]("const a = 1;\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> other\n".utf8)
        report("merge conflict markers force fallback, never parsed as source",
               !classify(path: "a.ts", bytes: conflicted).isStructural,
               String(describing: classify(path: "a.ts", bytes: conflicted)))
    }

    print("\n=== whole-file behaviour through partitionForSource ===")
    do {
        let css = [UInt8](".a { color: red }\n".utf8)
        let cssResult = partitionForSource(path: "a.css", bytes: css, parser: parser, label: .fallback)
        report("unsupported language yields one visible fallback segment",
               cssResult.usedFallback && cssResult.partition.segments.count == 1
                   && cssResult.partition.segments[0].label == .fallback)
        report("and still reconstructs exactly", reconstruct(cssResult.partition, from: css) == css)

        let empty = partitionForSource(path: "a.tsx", bytes: [], parser: parser)
        report("an empty file yields an empty, valid partition",
               partitionDefects(empty.partition).isEmpty && empty.partition.segments.isEmpty)
    }

    print("\n=== corpus sweep: every real .tsx file in the fixtures and repositories ===")
    do {
        let fm = FileManager.default
        var files: [URL] = []
        let root = URL(fileURLWithPath: fm.currentDirectoryPath).deletingLastPathComponent()
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            var scanned = 0
            for case let url as URL in walker {
                if url.pathComponents.contains("node_modules") || url.pathComponents.contains(".build") {
                    walker.skipDescendants()
                    continue
                }
                guard url.pathExtension == "tsx" else { continue }
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 400_000 else { continue }
                files.append(url)
                scanned += 1
                if scanned >= 400 { break }
            }
        }

        var checked = 0
        var malformed = 0
        var mismatched = 0
        var fillerBytes = 0
        var totalBytes = 0
        for url in files {
            guard let data = try? Data(contentsOf: url) else { continue }
            let bytes = [UInt8](data)
            guard classify(path: url.lastPathComponent, bytes: bytes).isStructural else { continue }
            guard let outcome = parser.parse(bytes) else { continue }
            let result = buildSyntaxPartition(bytes: bytes, leaves: outcome.leaves)
            checked += 1
            if !partitionDefects(result.partition).isEmpty { malformed += 1 }
            if reconstruct(result.partition, from: bytes) != bytes { mismatched += 1 }
            fillerBytes += result.stats.fillerBytes
            totalBytes += bytes.count
        }

        report("real .tsx files were found to sweep", checked > 0, "\(checked) files")
        report("every partition is well formed", malformed == 0, "\(malformed) malformed of \(checked)")
        report("every partition reconstructs byte for byte", mismatched == 0, "\(mismatched) mismatched of \(checked)")
        if totalBytes > 0 {
            let pct = Double(fillerBytes) / Double(totalBytes) * 100
            print(String(format: "        filler: %.1f%% of %d bytes across %d files", pct, totalBytes, checked))
        }
    }
}
