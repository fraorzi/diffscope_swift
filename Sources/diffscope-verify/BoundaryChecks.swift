import DiffScopeEngine
import DiffScopeSyntax
import Foundation

/// M6-B. Measures the slider problem M5-B recorded — 38.0% of hunk boundaries landing on a
/// syntax boundary — and what outward snapping costs to improve it.
func runBoundaryChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    guard let parser = TSXParser() else { report("parser for the boundary checks", false); return }

    print("\n=== boundary snapping: the mechanics ===")
    do {
        let source = [UInt8]("const alpha = 1;\nconst beta = 2;\n".utf8)
        guard let tree = parser.parseTree(source) else { report("boundary fixture parses", false); return }
        let boundaries = SyntaxBoundaries(tree: tree)
        report("boundary fixture parses", true)
        report("a named node start is a boundary", boundaries.contains(0))
        report("mid-identifier is not a boundary", !boundaries.contains(8))

        let snapped = snapToBoundaries([(8, 11)], boundaries: boundaries, budget: 16)
        report("a mid-token range is widened onto boundaries",
               snapped.count == 1 && snapped[0].start <= 8 && snapped[0].end >= 11,
               "\(snapped)")
        report("snapping only ever widens, so containment survives",
               snapped.allSatisfy { $0.start <= 8 && $0.end >= 11 })

        let unbudgeted = snapToBoundaries([(8, 11)], boundaries: boundaries, budget: 0)
        report("a zero budget is exactly the identity", unbudgeted.map(\.start) == [8])

        let far = SyntaxBoundaries(offsets: [0, 1000])
        report("a boundary beyond the budget is not reached",
               snapToBoundaries([(500, 501)], boundaries: far, budget: 4).map(\.start) == [500])

        let overlapping = snapToBoundaries([(8, 11), (12, 14)], boundaries: boundaries, budget: 32)
        report("ranges that meet after widening are merged", overlapping.count == 1, "\(overlapping)")
    }

    print("\n=== M6-B: what does snapping buy, and what does it cost? ===")
    do {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath).deletingLastPathComponent()
        let budgets = [0, 4, 8, 16, 32, 64]
        var onBoundary = [Int](repeating: 0, count: budgets.count)
        var boundaryTotal = [Int](repeating: 0, count: budgets.count)
        var presentedBytes = [Int](repeating: 0, count: budgets.count)
        var changedBytes = 0
        var checked = 0

        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walker {
                if url.pathComponents.contains("node_modules") || url.pathComponents.contains(".build") {
                    walker.skipDescendants(); continue
                }
                guard url.pathExtension == "tsx" else { continue }
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size > 400, size < 40_000,
                      let data = try? Data(contentsOf: url),
                      let text = String(bytes: [UInt8](data), encoding: .utf8) else { continue }

                // The slider case by construction: duplicating a block makes the alignment
                // ambiguous by exactly the length of the repeated content.
                let lines = text.components(separatedBy: "\n")
                guard lines.count > 20 else { continue }
                let from = lines.count / 2
                let block = lines[from..<min(from + 4, lines.count)]
                var perturbedLines = lines
                perturbedLines.insert(contentsOf: block, at: from)
                let perturbed = perturbedLines.joined(separator: "\n")
                guard perturbed != text else { continue }

                let newBytes = [UInt8](perturbed.utf8)
                guard let tree = parser.parseTree(newBytes) else { continue }
                let boundaries = SyntaxBoundaries(tree: tree)
                guard case let .exact(hunks) = canonicalDiff(old: [UInt8](data), new: newBytes) else { continue }
                let mask = hunks.filter { $0.newEnd > $0.newStart }.map { (start: $0.newStart, end: $0.newEnd) }
                guard !mask.isEmpty else { continue }

                changedBytes += mask.reduce(0) { $0 + ($1.end - $1.start) }
                for (index, budget) in budgets.enumerated() {
                    let snapped = snapToBoundaries(mask, boundaries: boundaries, budget: budget)
                    for range in snapped {
                        boundaryTotal[index] += 2
                        if boundaries.contains(range.start) { onBoundary[index] += 1 }
                        if boundaries.contains(range.end) { onBoundary[index] += 1 }
                        presentedBytes[index] += range.end - range.start
                    }
                }

                checked += 1
                if checked >= 150 { break }
            }
        }

        report("files were probed for the slider case", checked > 0, "\(checked) files")
        guard checked > 0 else { return }

        print("        budget   on a syntax boundary   bytes presented vs minimal")
        for (index, budget) in budgets.enumerated() {
            let aligned = Double(onBoundary[index]) / Double(max(1, boundaryTotal[index])) * 100
            let overhead = Double(presentedBytes[index]) / Double(max(1, changedBytes)) * 100 - 100
            print(String(format: "        %4d B   %18.1f%%   %+23.1f%%", budget, aligned, overhead))
        }

        let baseline = Double(onBoundary[0]) / Double(max(1, boundaryTotal[0])) * 100
        let chosen = budgets.firstIndex(of: boundarySnapBudget) ?? 0
        let improved = Double(onBoundary[chosen]) / Double(max(1, boundaryTotal[chosen])) * 100
        report("the unsnapped baseline reproduces the M5-B figure", baseline < 60,
               String(format: "%.1f%%", baseline))
        report("the shipped budget puts most boundaries on syntax boundaries", improved > 90,
               String(format: "%.1f%% at %d bytes", improved, boundarySnapBudget))
        let overhead = Double(presentedBytes[chosen]) / Double(max(1, changedBytes)) * 100 - 100
        report("and presents little more than the minimal change", overhead < 25,
               String(format: "+%.1f%%", overhead))
    }

    print("\n=== snapping never costs coverage ===")
    do {
        func diff(_ old: String, _ new: String, budget: Int = boundarySnapBudget) -> StructuralResult {
            structuralDiff(oldPath: "a.tsx", oldBytes: [UInt8](old.utf8),
                           newPath: "a.tsx", newBytes: [UInt8](new.utf8), parser: parser,
                           // The word snap turns off with the syntax snap here (DEC-100). Both are
                           // wideners and both finish an identifier, so a control that turned off
                           // only one would be asserting the *other* pass's absence.
                           settings: MatcherSettings(boundarySnapBudget: budget,
                                                     wordSnapBudget: budget == 0 ? 0 : DiffScopeEngine.wordSnapBudget))
        }

        /// Runs of adjacent presented segments — one visible change is one run, whatever the
        /// segmentation underneath.
        func presentedRuns(_ partition: Partition) -> [(start: Int, end: Int)] {
            var runs: [(start: Int, end: Int)] = []
            for segment in partition.segments where segment.isPresented {
                if let last = runs.last, last.end == segment.start {
                    runs[runs.count - 1] = (last.start, segment.end)
                } else {
                    runs.append((segment.start, segment.end))
                }
            }
            return runs
        }

        print("        negative control: the same edit without a budget")
        let renamed = "const value = getUserName();\n"
        let unsnapped = diff("const value = getUser();\n", renamed, budget: 0)
        let snappedResult = diff("const value = getUser();\n", renamed)
        guard let renamedTree = parser.parseTree([UInt8](renamed.utf8)) else {
            report("the renamed fixture parses", false); return
        }
        let renamedBoundaries = SyntaxBoundaries(tree: renamedTree)
        func allOnBoundary(_ result: StructuralResult) -> Bool {
            presentedRuns(result.model.newPartition).allSatisfy {
                renamedBoundaries.contains($0.start) && renamedBoundaries.contains($0.end)
            }
        }
        report("without a budget the change starts mid-identifier", !allOnBoundary(unsnapped),
               presentedRuns(unsnapped.model.newPartition).map { "\($0.start)..<\($0.end)" }.joined(separator: " "))
        report("with the shipped budget it starts on the identifier", allOnBoundary(snappedResult),
               presentedRuns(snappedResult.model.newPartition).map { "\($0.start)..<\($0.end)" }.joined(separator: " "))
        report("and snapping did not lose the invariants", validate(snappedResult.model).passed)
        report("nor turn the edit into 'no changes'", !snappedResult.model.presentsNoChanges)
        let duplicated = diff("""
        function a() {
          return 1;
        }

        function b() {
          return 2;
        }

        """, """
        function a() {
          return 1;
        }

        function a() {
          return 1;
        }

        function b() {
          return 2;
        }

        """)
        report("the slider case satisfies the invariants", validate(duplicated.model).passed,
               validate(duplicated.model).summary)
        report("and still reports a difference", !duplicated.model.presentsNoChanges)

        guard let tree = parser.parseTree(duplicated.model.newBytes) else {
            report("the new side parses", false); return
        }
        let boundaries = SyntaxBoundaries(tree: tree)
        // Adjacent presented segments are one visible change, so the run is what a reader sees.
        var runs: [(start: Int, end: Int)] = []
        for segment in duplicated.model.newPartition.segments where segment.isPresented {
            if let last = runs.last, last.end == segment.start {
                runs[runs.count - 1] = (last.start, segment.end)
            } else {
                runs.append((segment.start, segment.end))
            }
        }
        let aligned = runs.allSatisfy {
            ($0.start == 0 || boundaries.contains($0.start))
                && ($0.end == duplicated.model.newBytes.count || boundaries.contains($0.end))
        }
        report("every presented change begins and ends on a syntax boundary", aligned,
               runs.map { "\($0.start)..<\($0.end)" }.joined(separator: " "))

        let unchangedText = duplicated.model.newPartition.segments
            .filter { $0.label == .unchanged }
            .reduce(into: [UInt8]()) { $0 += duplicated.model.newBytes[$1.start..<$1.end] }
        report("the duplicated body is not swallowed",
               String(decoding: unchangedText, as: UTF8.self).contains("function b"))
    }

    print("\n=== DEC-123: the snap finishes a construct, it does not reach into the line above ===")
    do {
        // Two lines, a one-byte mark on the second, and the only boundary within budget on the
        // first. Written against `SyntaxBoundaries(offsets:)` rather than a parse, so the case is
        // about the rule and not about which nodes tree-sitter happens to name.
        let bytes = [UInt8]("abc\ndef\n".utf8)
        let boundaries = SyntaxBoundaries(offsets: [2, 7])
        let mask = [(start: 5, end: 6)]          // the "e", two bytes into line 2

        let bounded = snapToBoundaries(mask, boundaries: boundaries, budget: 16, bytes: bytes)
        report("an edge is not widened onto a boundary on the line above",
               bounded.count == 1 && bounded[0].start == 5 && bounded[0].end == 7,
               bounded.map { "\($0.start)..<\($0.end)" }.joined(separator: ","))

        // The negative control: with the rule off this is the pass as DEC-047 shipped it, and the
        // mark reaches back across the newline onto offset 2.
        let crossing = snapToBoundaries(mask, boundaries: boundaries, budget: 16, bytes: bytes,
                                        crossesLineBreaks: true)
        report("control: with the rule off it reaches back across the newline",
               crossing.count == 1 && crossing[0].start == 2 && crossing[0].end == 7,
               crossing.map { "\($0.start)..<\($0.end)" }.joined(separator: ","))

        // And the property, over every fixture, stated so it survives the merge the pass does at
        // the end: **no line terminator enters the presented set because of this pass.** Zipping the
        // inputs against the outputs would be wrong — `snapToBoundaries` sorts and merges what now
        // overlaps, so the two lists are not parallel.
        guard let parser = TSXParser() else { report("parser for the boundary checks", false); return }
        var crossed: [String] = []
        for fixture in loadFixtures(root: URL(fileURLWithPath: "fixtures")) {
            let model = structuralDiff(oldPath: fixture.oldPath, oldBytes: fixture.old,
                                       newPath: fixture.newPath, newBytes: fixture.new,
                                       parser: parser).model
            for (bytes, partition) in [(fixture.old, model.oldPartition),
                                       (fixture.new, model.newPartition)] {
                guard let tree = parser.parseTree(bytes) else { continue }
                let presented = partition.segments.filter(\.isPresented)
                    .map { (start: $0.start, end: $0.end) }
                guard !presented.isEmpty else { continue }
                var before = Set<Int>()
                for range in presented { for offset in range.start..<range.end { before.insert(offset) } }
                let widened = snapToBoundaries(presented, boundaries: SyntaxBoundaries(tree: tree),
                                               budget: boundarySnapBudget, bytes: bytes)
                for range in widened {
                    for offset in range.start..<range.end
                    where bytes[offset] == 0x0A && !before.contains(offset) {
                        crossed.append(fixture.name)
                    }
                }
            }
        }
        report("over every fixture, the snap adds no line terminator to the presented set",
               crossed.isEmpty, Set(crossed).sorted().joined(separator: ", "))
    }
}
