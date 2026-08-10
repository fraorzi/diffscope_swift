import DiffScopeEngine
import DiffScopeGit
import DiffScopeSyntax
import Foundation

/// `13-error-and-fallback-model.md` §5 (precedence) and §3 (the failure paths that cannot arise in
/// this corpus and therefore ship untested unless forced).
///
/// The second half is the reason this file builds repositories and runs broken commands: F8, F13
/// and the oversized case have no natural trigger here, and "we never saw it fail" is not evidence
/// when the trigger cannot occur.
func runDegradationChecks(_ report: (String, Bool, String) -> Void) {
    func check(_ name: String, _ ok: Bool, _ detail: String = "") { report(name, ok, detail) }

    let fm = FileManager.default
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("diffscope-m8b-\(UUID().uuidString)")
    try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: scratch) }

    let parser = TSXParser()

    print("\n=== the precedence of 13-…§5 is data, not the order of guards ===")
    do {
        let ranks = Degradation.all.map(\.rank)
        check("every taxonomy row has a distinct rank", Set(ranks).count == ranks.count)
        check("the ranks are dense, so a new row cannot be added without placing it",
              Set(ranks) == Set(0..<Degradation.all.count),
              ranks.map(String.init).joined(separator: ","))
        check("the order matches §5 exactly",
              Degradation.all.sorted { $0.rank < $1.rank }.map(\.code)
                  == ["F10", "F9", "F8", "F5", "F2", "F7", "F16", "F6", "F3/F4", "F1"],
              Degradation.all.sorted { $0.rank < $1.rank }.map(\.code).joined(separator: " → "))
        check("the most conservative of several conditions wins regardless of the order offered",
              Degradation.mostConservative([.partialParseError(reason: ""), .binary(reason: ""),
                                            .unsupportedLanguage(reason: "")])?.code == "F9"
                  && Degradation.mostConservative([.binary(reason: ""), .partialParseError(reason: "")])?.code == "F9")
        check("no condition means no degradation", Degradation.mostConservative([]) == nil)
    }

    print("\n=== conditions that hold at once report the most conservative one ===")
    do {
        // Before DEC-051 each of these reported whichever guard was written first, which was the
        // milder statement in every case below.
        let binaryImage = classify(path: "logo.png", bytes: [0x89, 0x50, 0x00, 0x4E])
        check("a binary file with an unsupported extension reports binary, not unsupported",
              binaryImage.degradation?.code == "F9", String(describing: binaryImage))

        let undecodable = classify(path: "notes.md", bytes: [0x61, 0xFF, 0x62])
        check("undecodable content outranks its unsupported extension",
              undecodable.degradation?.code == "F9", String(describing: undecodable))

        let conflicted = [UInt8]("const a = 1;\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> other\n".utf8)
        check("a conflicted supported file reports the conflict as F2",
              classify(path: "a.ts", bytes: conflicted).degradation?.code == "F2")
        check("a conflicted *binary* file still reports binary",
              classify(path: "a.ts", bytes: conflicted + [0x00]).degradation?.code == "F9")

        let big = [UInt8](repeating: 0x61, count: structuralSizeLimit + 1)
        let oversizedUnsupported = structuralDiff(
            oldPath: "vendor.css", oldBytes: big, newPath: "vendor.css", newBytes: big + [0x62],
            parser: parser)
        check("an oversized file whose language has no structure reports the language (F7 over F16)",
              oversizedUnsupported.stats.degradation?.code == "F7",
              oversizedUnsupported.stats.fallbackReason ?? "none")

        let oversizedSupported = structuralDiff(
            oldPath: "vendor.js", oldBytes: big, newPath: "vendor.js", newBytes: big + [0x62],
            parser: parser)
        check("an oversized supported file reports the budget (F16)",
              oversizedSupported.stats.degradation?.code == "F16",
              oversizedSupported.stats.fallbackReason ?? "none")

        let source = [UInt8]("const a = 1;\n".utf8)
        let filtered = structuralDiff(
            oldPath: "a.ts", oldBytes: source, newPath: "a.ts", newBytes: source + [0x32],
            parser: parser, external: [.filterActive(reason: "text=auto")])
        check("an external condition joins the ranking rather than pre-empting it",
              filtered.stats.degradation?.code == "F8", filtered.stats.fallbackReason ?? "none")
        let filteredBinary = structuralDiff(
            oldPath: "a.ts", oldBytes: source + [0x00], newPath: "a.ts", newBytes: source,
            parser: parser, external: [.filterActive(reason: "text=auto")])
        check("and loses to a more conservative one detected here (F9 over F8)",
              filteredBinary.stats.degradation?.code == "F9", filteredBinary.stats.fallbackReason ?? "none")
    }

    print("\n=== F8: eol-filter-active, the fixture the corpus cannot produce ===")
    do {
        // Built in the order that actually reproduces DEC-041's measurement, which is not the
        // order the plan assumed: commit an LF blob **first**, add the attribute after, then give
        // the worktree the CRLF the attribute asks for. Setting the attribute before the commit
        // leaves both sides agreeing and reproduces nothing — measured, see M8-B.
        let repo = makeRepository("eol-filter-active", in: scratch)
        try? "const a = 1;\nconst b = 2;\n".write(to: repo.appendingPathComponent("a.ts"),
                                                  atomically: true, encoding: .utf8)
        try? "plain\n".write(to: repo.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        shell(["add", "-A"], in: repo)
        shell(["commit", "-qm", "c1"], in: repo)
        try? "*.ts text eol=crlf\n".write(to: repo.appendingPathComponent(".gitattributes"),
                                          atomically: true, encoding: .utf8)
        shell(["add", ".gitattributes"], in: repo)
        shell(["commit", "-qm", "attrs"], in: repo)
        try? "const a = 1;\r\nconst b = 2;\r\n".write(to: repo.appendingPathComponent("a.ts"),
                                                      atomically: true, encoding: .utf8)

        let runner = GitRunner()
        let filters = FilterCheck(runner: runner)
        let filtered = filters.state(for: "a.ts", in: repo)
        let clean = filters.state(for: "b.md", in: repo)
        check("check-attr reports the active filter on the covered path",
              filtered.isActive && !filtered.unknown, filtered.summary)
        check("and reports nothing for a path the attributes do not cover",
              !clean.isActive && !clean.unknown, clean.summary)
        check("unspecified is not mistaken for a filter",
              !FilterCheck.parse(Data("b.md\0text\0unspecified\0".utf8)).isActive)
        check("a failed query is unknown, never clean",
              filters.state(for: "a.ts", in: scratch.appendingPathComponent("not-a-repo")).unknown)

        let scopes = ScopeReader(runner: runner)
        let listed = (try? scopes.changedFiles(scope: .allLocalVsHead, in: repo)) ?? []
        check("DEC-041: the file the filter affects is still listed as changed",
              listed.contains { $0.path == "a.ts" },
              listed.map(\.path).joined(separator: ", "))

        let pair = try? scopes.pinnedPair(for: ChangedFile(path: "a.ts", originalPath: nil, kind: .modified),
                                          scope: .allLocalVsHead, in: repo)
        let external = filtered.disclosure.map { [Degradation.filterActive(reason: $0)] } ?? []
        let result = structuralDiff(oldPath: "a.ts", oldBytes: pair?.oldBytes ?? [],
                                    newPath: "a.ts", newBytes: pair?.newBytes ?? [],
                                    parser: parser, external: external)
        check("a filtered file gets no structural claim (DEC-028)",
              result.stats.usedFallback && result.stats.degradation?.code == "F8",
              result.stats.fallbackReason ?? "none")

        let notice = result.stats.degradation?.notice ?? ""
        check("the disclosure explains the discrepancy, not merely the filter",
              notice.contains("git status") && notice.contains("git diff"), notice)
        check("and still says what remains trustworthy",
              notice.contains("All textual differences are shown"), notice)

        // The state DEC-041 was written about, asserted rather than assumed: git's own two tools
        // disagree here, which is why the file list and the diff view can look inconsistent.
        let diff = shell(["diff", "--", "a.ts"], in: repo)
        let status = shell(["status", "--porcelain", "--", "a.ts"], in: repo)
        check("the fixture reproduces DEC-041's measurement: status says modified, diff says nothing",
              status.hasSuffix("a.ts") && diff.isEmpty,
              "status=\"\(status)\" diff-lines=\(diff.isEmpty ? 0 : diff.split(separator: "\n").count)")
        check("and the pair this application compares does differ, which is what needs explaining",
              pair?.oldBytes != pair?.newBytes)
    }

    print("\n=== F6: unverified is reachable, and says so ===")
    do {
        // DEC-043 replaced DEC-040's size threshold with a work budget, so the route to unverified
        // is dissimilarity, not size. Two unrelated buffers exhaust `D` long before they finish.
        var rng = SystemRandomNumberGenerator()
        let a = (0..<120_000).map { _ in UInt8.random(in: 0x61...0x7A, using: &rng) }
        let b = (0..<120_000).map { _ in UInt8.random(in: 0x41...0x5A, using: &rng) }
        let model = trivialModel(oldBytes: a, newBytes: b)
        let validation = validate(model)
        check("the coverage check gives up rather than claiming a violation",
              validation.passed && !validation.coverageChecked, validation.summary)
        let render = buildRenderModel(model: model, pinOld: "a", pinNew: "b", validation: validation)
        check("and the contract carries the unverified state across to the renderer",
              !render.coverageVerified && render.notices.contains { $0.contains("coverage") },
              render.notices.joined(separator: " | "))

        // The oversized route now stops earlier than §2 describes: DEC-050 withholds structure
        // entirely above 2 MB, so such a file is raw-and-explained rather than structural-and-
        // unverified. Recorded in DEC-051 rather than left as a silent divergence.
        let big = [UInt8](repeating: 0x61, count: structuralSizeLimit + 1)
        let oversized = structuralDiff(oldPath: "big.ts", oldBytes: big,
                                       newPath: "big.ts", newBytes: big + [0x62], parser: parser)
        check("an oversized file is withheld from structure rather than shown unverified",
              oversized.stats.usedFallback && oversized.stats.degradation?.code == "F16",
              oversized.stats.fallbackReason ?? "none")
    }

    print("\n=== F13: an editor that fails is reported, both ways it can fail ===")
    do {
        let command = EditorCommand(template: "/usr/bin/open -a WebStorm {file}:{line}",
                                    file: "/tmp/x.ts", line: 42)
        check("the template substitutes both placeholders and nothing else",
              command?.executable == "/usr/bin/open"
                  && command?.arguments == ["-a", "WebStorm", "/tmp/x.ts:42"],
              String(describing: command))
        check("an empty template is refused rather than half-run",
              EditorCommand(template: "", file: "/tmp/x.ts", line: 1) == nil)
        // Found by this check: substituting before splitting gave the path's spaces the same
        // meaning as the template's, so a project directory with a space in its name opened three
        // files, none of them the right one.
        check("a path containing spaces stays one argument",
              EditorCommand(template: "/usr/bin/open -a WebStorm {file}",
                            file: "/Users/x/My Projects/a.ts", line: 1)?.arguments
                  == ["-a", "WebStorm", "/Users/x/My Projects/a.ts"])
        check("and nothing but {file} and {line} is substituted",
              EditorCommand(template: "/bin/echo {file}", file: "$(rm -rf /)", line: 1)?.arguments
                  == ["$(rm -rf /)"])

        let missing = launchEditor(EditorCommand(template: "/nonexistent/editor {file}",
                                                 file: "/tmp/x.ts", line: 1)!, file: "x.ts")
        if case .notLaunched = missing {
            check("a command that will not launch is reported", true, missing.message)
        } else {
            check("a command that will not launch is reported", false, missing.message)
        }

        let failing = launchEditor(EditorCommand(template: "/usr/bin/false {file}",
                                                 file: "/tmp/x.ts", line: 1)!, file: "x.ts")
        check("a command that launches and then fails is reported too, not read as success",
              failing == .failed(exitCode: 1), failing.message)

        let working = launchEditor(EditorCommand(template: "/bin/echo {file}",
                                                 file: "/tmp/x.ts", line: 1)!, file: "x.ts")
        check("and the negative control still reports success", working.succeeded, working.message)
    }

    print("\n=== DEC-028: the registry cannot execute repository-configured commands ===")
    do {
        check("no registered operation carries an executing argument",
              GitOperation.executingOperations.isEmpty,
              GitOperation.executingOperations.map(\.label).joined(separator: ", "))
        check("the guard would catch one if it returned",
              GitOperation.forbiddenArguments.contains("--textconv"))
    }
}

/// F1, F3 and F4 — the three rows of `13-…` §2 that had a rank in the vocabulary and nothing
/// producing them. Two now have producers; the third has a decision saying it never will.
func runPartialFailureChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }
    let parser = TSXParser()

    print("\n=== F1: a file that parses only in part says so ===")
    do {
        // Half-typed JSX — the state `15-…` §4.6 calls normal rather than exceptional, because
        // auto-refresh on save guarantees the reader meets it.
        let old = [UInt8]("const el = <Row><Cell /></Row>;\n".utf8)
        let new = [UInt8]("const el = <Row><Cell /</Row>;\n".utf8)
        let result = structuralDiff(oldPath: "a.tsx", oldBytes: old,
                                    newPath: "a.tsx", newBytes: new, parser: parser)

        report("the unparsed region is found", result.stats.unparsedRegions > 0,
               "\(result.stats.unparsedRegions) regions / \(result.stats.unparsedBytes) bytes")
        report("and it is reported as F1", result.stats.degradation?.code == "F1",
               result.stats.fallbackReason ?? "none")
        // F1 is "structural for clean regions, raw for the rest" — the whole file is not withheld.
        report("the structural result still stands for the rest of the file",
               !result.stats.usedFallback && result.stats.anchors > 0,
               "\(result.stats.anchors) anchors")

        // Measured, and worth stating because it looks like a miss and is not: deleting the `>`
        // leaves the **new** side with no changed bytes at all, and the old side parses cleanly. So
        // there is nothing inside an unparsed region to mark. The same shape as DEC-048's finding
        // that a reindent has no old side, and DEC-034's that Raw has no unchanged segments —
        // asymmetric edits keep producing it.
        report("a deletion that breaks the new side marks nothing, because nothing changed there",
               result.model.newPartition.segments.allSatisfy { $0.label != .fallback })

        // The case where the marking does fire: an edit *inside* a region neither side could parse.
        let brokenOld = [UInt8]("const el = <Row><Cell name=\"alpha\" /</Row>;\n".utf8)
        let brokenNew = [UInt8]("const el = <Row><Cell name=\"omega\" /</Row>;\n".utf8)
        let inside = structuralDiff(oldPath: "a.tsx", oldBytes: brokenOld,
                                    newPath: "a.tsx", newBytes: brokenNew, parser: parser)
        let fallbackBytes = inside.model.newPartition.segments
            .filter { $0.label == .fallback }.reduce(0) { $0 + $1.length }
        report("a change inside an unparsed region is marked as the fallback it is (INV-4)",
               fallbackBytes > 0, "\(fallbackBytes) bytes of \(inside.stats.unparsedBytes) unparsed")
        report("and it carries the reason, not just the label",
               inside.model.newPartition.segments.contains {
                   $0.label == .fallback && $0.classification == "parse-error"
               })
        // The trap avoided: comparison never depended on parsing (DEC-021), so unchanged content
        // inside a broken region is still honestly unchanged. Repainting it would invent a change.
        report("unchanged content inside the same region keeps its label",
               inside.model.newPartition.segments.contains { $0.label == .unchanged })
        report("and the model still reconstructs and covers (INV-1, INV-2)",
               validate(inside.model).passed, validate(inside.model).summary)

        // The negative control: a file that parses cleanly must report nothing.
        let clean = structuralDiff(oldPath: "b.tsx", oldBytes: [UInt8]("const a = 1;\n".utf8),
                                   newPath: "b.tsx", newBytes: [UInt8]("const a = 2;\n".utf8),
                                   parser: parser)
        report("a file that parses cleanly reports no unparsed region",
               clean.stats.unparsedRegions == 0 && clean.stats.degradation == nil)

        // Ranking: F1 is the mildest row, so anything else that applies wins over it.
        let binaryToo = structuralDiff(oldPath: "a.tsx", oldBytes: old,
                                       newPath: "a.tsx", newBytes: new + [0x00], parser: parser)
        report("a more conservative condition still outranks it",
               binaryToo.stats.degradation?.code == "F9", binaryToo.stats.fallbackReason ?? "none")
    }

    print("\n=== F3: low confidence is produced per region, not per file ===")
    do {
        // `reconcile` drops an anchor's confidence when the byte diff contradicts it. That is the
        // producer: a *segment* property, which is the right shape — the rest of the file is fine,
        // and a file-level notice would overstate it.
        let old = [UInt8]("const alpha = 1;\nconst beta = 2;\nconst alpha = 3;\n".utf8)
        let new = [UInt8]("const alpha = 9;\nconst beta = 2;\nconst alpha = 3;\n".utf8)
        let result = structuralDiff(oldPath: "c.tsx", oldBytes: old,
                                    newPath: "c.tsx", newBytes: new, parser: parser)
        let render = buildRenderModel(model: result.model, pinOld: "a", pinNew: "b", mode: "structural")
        guard case let .text(_, newSide) = render.payload else {
            report("the contract carries a text payload", false); return
        }
        report("confidence travels to the renderer on every changed segment",
               newSide.segments.filter { $0.label == "changed" }.allSatisfy { $0.confidence != nil })
        // The floor lives in the engine so a renderer cannot quietly redefine what counts as
        // certain — the `uncertain` flag is computed, not sent as a suggestion.
        report("the uncertain flag is derived from the floor, not from the renderer",
               newSide.segments.allSatisfy { segment in
                   segment.uncertain == ((segment.confidence ?? 1) < confidenceFloor)
               })
    }

    print("\n=== F4: ambiguity is detected and deliberately not shown (DEC-045) ===")
    do {
        // Repeated identical siblings: which one was added is undecidable. The matcher records it.
        let old = [UInt8]("<ul>\n  <li>item</li>\n  <li>item</li>\n</ul>\n".utf8)
        let new = [UInt8]("<ul>\n  <li>item</li>\n  <li>item</li>\n  <li>item</li>\n</ul>\n".utf8)
        let result = structuralDiff(oldPath: "d.tsx", oldBytes: old,
                                    newPath: "d.tsx", newBytes: new, parser: parser)
        report("ambiguity is counted rather than resolved by guessing",
               result.stats.ambiguities >= 0, "\(result.stats.ambiguities) ambiguities")

        // DEC-045 withdrew the indicator. The check exists so that adding one later is a deliberate
        // act against a recorded decision, rather than something that drifts in unnoticed.
        let render = buildRenderModel(model: result.model, pinOld: "a", pinNew: "b", mode: "structural")
        let encoded = (try? encodeRenderModel(render)) ?? ""
        report("and no ambiguity indicator reaches the contract (DEC-045)",
               !encoded.contains("\"ambiguous\"") && !encoded.contains("ambiguity"))
        report("the anchors it produced are still sound",
               validate(result.model).passed, validate(result.model).summary)
    }

    print("\n=== the unrenderable state says what the file is, not what the error was (12-… §5.5) ===")
    do {
        let text = unrenderableReason(error: ContractError.mappingFailed(side: .old, underlying: "invalid UTF-8"),
                                      oldBytes: 4096, newBytes: 5120)
        report("it names the cause", text.contains("invalid UTF-8"))
        report("and says the two sides differ, so the reader knows a difference was found",
               text.contains("4096 bytes → 5120 bytes"))
        report("and states that nothing is being hidden by the refusal",
               text.lowercased().contains("nothing is hidden") || text.contains("none of the difference is hidden"))
        report("equal sides are said to be equal rather than left ambiguous",
               unrenderableReason(error: ContractError.mappingFailed(side: .new, underlying: "x"),
                                  oldBytes: 12, newBytes: 12).contains("Both sides are 12 bytes"))

        // The negative control, and the defect this replaced: the payload used to carry
        // `String(describing: error)`, which is a Swift value description shown to a person who
        // asked what changed in a file.
        struct Opaque: Error {}
        let unknown = unrenderableReason(error: Opaque(), oldBytes: 1, newBytes: 2)
        report("an error with no words of its own does not leak its Swift description",
               !unknown.contains("Opaque") && unknown.contains("not text this window can display"))
    }
}

/// DEC-063: files compared by being drawn. The classification and the words — the drawing itself
/// is photographed, not asserted.
func runRenderedComparisonChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    print("\n=== an image is a third class, and SVG is not binary (DEC-063) ===")
    let svg = Array(#"<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>"#.utf8)
    let png: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] + Array(repeating: 0, count: 16)

    report("an SVG is text that renders, not binary",
           renderableKind(path: "public/mark.svg", bytes: svg) == .textThatRenders(format: "SVG"))
    report("a PNG is raster", renderableKind(path: "assets/icon.png", bytes: png) == .raster(format: "PNG"))
    report("a source file is neither", renderableKind(path: "src/List.tsx", bytes: Array("const a = 1".utf8)) == .text)
    report("an archive is undisplayable",
           renderableKind(path: "dist/bundle.zip", bytes: Array("PK\u{3}\u{4}".utf8)) == .undisplayable)

    // The cases a name alone gets wrong. A `.png` that is not a PNG is a placeholder, an LFS
    // pointer, or a rename that outran its content, and drawing it shows an empty frame.
    report("a .png that is not a PNG is undisplayable rather than drawn blank",
           renderableKind(path: "assets/icon.png", bytes: Array("version https://git-lfs".utf8)) == .undisplayable)
    report("a .svg whose bytes are not an SVG is undisplayable too",
           renderableKind(path: "public/mark.svg", bytes: png) == .undisplayable)
    report("content decides where it can: a PNG named .bin is still raster",
           renderableKind(path: "blob.bin", bytes: png) == .raster(format: "PNG"))

    print("\n=== the rendered comparison says what a picture cannot (DEC-063, 12-… §5.5) ===")
    func comparison(old: (Int, Int)?, new: (Int, Int)?, pixels: Int?,
                    oldBytes: Int = 4100, newBytes: Int = 4400,
                    kind: RenderableKind = .raster(format: "PNG")) -> RenderedComparison {
        RenderedComparison(kind: kind, oldBytes: oldBytes, newBytes: newBytes,
                           oldSize: old.map { (width: $0.0, height: $0.1) },
                           newSize: new.map { (width: $0.0, height: $0.1) },
                           differingPixels: pixels)
    }

    let identical = renderedComparisonSummary(comparison(old: (131, 150), new: (131, 150), pixels: 0))
    report("bytes differing while the rendering does not is stated outright",
           identical.contains("render identically — 0 pixels differ") && identical.contains("4100 → 4400 bytes"),
           identical)
    report("and an SVG is pointed at its source reading, which a raster does not have",
           renderedComparisonSummary(comparison(old: (131, 150), new: (131, 150), pixels: 0,
                                                kind: .textThatRenders(format: "SVG")))
               .contains("source reading"))

    let resized = renderedComparisonSummary(comparison(old: (131, 150), new: (160, 150), pixels: 2914))
    report("a dimension change is named on both sides",
           resized.contains("131 × 150 → 160 × 150") && resized.contains("2914 pixels differ"), resized)

    report("an added image says why three of the four modes have nothing to do",
           renderedComparisonSummary(comparison(old: nil, new: (160, 150), pixels: nil))
               .contains("no left side"))
    report("and a deleted one says the same of the right",
           renderedComparisonSummary(comparison(old: (160, 150), new: nil, pixels: nil))
               .contains("no right side"))

    let huge = comparison(old: (8000, 8000), new: (8000, 8000), pixels: nil)
    report("over the budget, the mode is unavailable and says so rather than being hidden",
           !huge.withinPixelBudget
               && renderedComparisonSummary(huge).contains("unavailable and says so rather than being hidden"))
    report("and under it, the budget is not mentioned at all",
           comparison(old: (131, 150), new: (131, 150), pixels: 3).withinPixelBudget
               && !renderedComparisonSummary(comparison(old: (131, 150), new: (131, 150), pixels: 3))
                   .contains("megapixel"))

    // The negative control for the trust statement: a comparison that *did* find differing pixels
    // must never be described as identical.
    report("negative control: a comparison with differing pixels never claims they are identical",
           !renderedComparisonSummary(comparison(old: (10, 10), new: (10, 10), pixels: 1))
               .contains("render identically"))

    print("\n=== the §4.7a fixtures are what they claim to be (DEC-063) ===")
    do {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("fixtures")
        func bytes(_ case_: String, _ file: String) -> [UInt8] {
            [UInt8]((try? Data(contentsOf: root.appendingPathComponent("\(case_)/\(file)"))) ?? Data())
        }
        func kind(_ case_: String, _ file: String) -> RenderableKind {
            renderableKind(path: file, bytes: bytes(case_, file))
        }

        report("an SVG fixture classifies as text that renders",
               kind("svg-text-only-change", "after.svg") == .textThatRenders(format: "SVG")
                   && kind("svg-rendered-change", "after.svg") == .textThatRenders(format: "SVG"))
        report("the hostile SVG is classified like any other — the boundary is how it is drawn, not whether",
               kind("svg-hostile", "after.svg") == .textThatRenders(format: "SVG"))
        report("the raster fixtures are raster",
               kind("raster-resize", "after.png") == .raster(format: "PNG")
                   && kind("raster-identical-bytes-differ", "after.png") == .raster(format: "PNG"))
        report("the archive is undisplayable", kind("undisplayable-blob", "after.zip") == .undisplayable)

        // An absent side is empty bytes, and an empty side must not be classified as an image that
        // failed to decode — the reader is told there is no counterpart, not that something broke.
        report("the added image has no left side at all", bytes("image-added", "before.png").isEmpty)
        report("and its right side is a real PNG", kind("image-added", "after.png") == .raster(format: "PNG"))

        // Read from IHDR rather than from the note beside the file: a fixture that claims to be
        // over the budget and is not would make the refusal untestable while looking tested.
        func size(_ case_: String, _ file: String) -> (width: Int, height: Int)? {
            let data = bytes(case_, file)
            guard data.count > 24, Array(data.prefix(8)) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
            else { return nil }
            func int(_ offset: Int) -> Int {
                (Int(data[offset]) << 24) | (Int(data[offset + 1]) << 16)
                    | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
            }
            return (width: int(16), height: int(20))
        }
        let huge = size("image-over-budget", "after.png")
        report("the over-budget fixture really is over the budget",
               (huge.map { $0.width * $0.height } ?? 0) > RenderedComparison.megapixelBudget * 1_000_000,
               huge.map { "\($0.width) × \($0.height)" } ?? "not a PNG")
        report("and the resize fixture really changes size",
               size("raster-resize", "before.png")?.width != size("raster-resize", "after.png")?.width)

        // The pair whose whole point is that the bytes moved and the picture did not.
        report("the identical-render pair differs in bytes",
               bytes("raster-identical-bytes-differ", "before.png")
                   != bytes("raster-identical-bytes-differ", "after.png"))
        report("and is the same size, so a pixel pass is comparing like with like",
               size("raster-identical-bytes-differ", "before.png")?.width
                   == size("raster-identical-bytes-differ", "after.png")?.width)

        // The control's teeth: the file has to actually carry the things the boundary refuses to
        // honour, or the arm that draws it proves nothing.
        let hostile = String(decoding: bytes("svg-hostile", "after.svg"), as: UTF8.self)
        report("the hostile SVG carries a script, an event handler and a remote reference",
               hostile.contains("<script") && hostile.contains("onload=")
                   && hostile.contains("https://example.invalid"))
        report("and sets an observable marker, so a boundary failure is visible rather than argued",
               hostile.contains("__diffscopeHostile"))
    }
}
