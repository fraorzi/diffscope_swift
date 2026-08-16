import DiffScopeEngine
import DiffScopeGit
import DiffScopeSyntax
import Foundation

/// M8-K — the four things `23b-spec-vs-app-audit.md` still listed as missing or shallow, all of
/// them statements the interface makes about its own trustworthiness:
///
/// - §1.10 the **parser-state indicator**, the last of `12-…` §5.2's seven;
/// - §2 the **branch**, listed as displayed and living in a tooltip;
/// - §2 the **uncommitted-count convention**, required on screen and stated nowhere;
/// - §2 the **mode pill**, reporting the reader's selection rather than the path taken.
///
/// The first and last are computed in the engine and carried on the contract, so they are checked
/// here. The middle two are shell strings, so what is checked here is that the sentence exists in
/// one place, that it is *true* of the operation actually run, and that the shell reads it from
/// there — with the window itself covered by the application selftest.
func runTrustSurfaceChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    print("\n=== the parser state is stated, not inferred (12-… §5.2, 23b-… §1.10) ===")
    do {
        let raw = ParserStateReport.of(structuralRequested: false, structuralUsed: false,
                                       degradation: nil)
        report("raw mode says the file is not parsed, and why",
               raw.state == "not-parsed" && (raw.detail ?? "").contains("raw mode"), raw.chipText)

        let withheld = ParserStateReport.of(
            structuralRequested: true, structuralUsed: false,
            degradation: .unsupportedLanguage(reason: "`.css` has no structural support"))
        report("a withheld structural run reports the condition that withheld it",
               withheld.state == "not-parsed" && (withheld.detail ?? "").contains(".css"),
               withheld.chipText)

        // The default matters: a fallback with no recorded condition must still say something,
        // because "not parsed" with no reason is the shape of an unexplained failure.
        let unexplained = ParserStateReport.of(structuralRequested: true, structuralUsed: false,
                                               degradation: nil)
        report("a withheld run with no recorded condition still gives a reason",
               unexplained.detail?.isEmpty == false, unexplained.chipText)

        let partial = ParserStateReport.of(structuralRequested: true, structuralUsed: true,
                                           degradation: .partialParseError(reason: "…"),
                                           unparsedRegions: 2, unparsedBytes: 41)
        report("a partly-parsed file says how much of it was not parsed",
               partial.state == "partial" && partial.chipText.contains("2 regions")
                   && partial.chipText.contains("41 bytes"), partial.chipText)

        let one = ParserStateReport.of(structuralRequested: true, structuralUsed: true,
                                       degradation: .partialParseError(reason: "…"),
                                       unparsedRegions: 1, unparsedBytes: 9)
        report("one region is one region, not `1 regions`",
               one.chipText.contains("1 region and"), one.chipText)

        let clean = ParserStateReport.of(structuralRequested: true, structuralUsed: true,
                                         degradation: nil)
        // "Nothing further" means no *failure* detail. It names the grammar that read the file,
        // which the adopted design asks for and which is a disclosure in its own right: every
        // supported extension is read by the TSX grammar, so a reader looking at plain JavaScript
        // is being told, correctly, that it was parsed as TSX.
        report("a file that parsed says so, and names the grammar that read it",
               clean == .parsed && clean.chipText == "parser: parsed — tree-sitter tsx",
               clean.chipText)

        // The negative control, and the reason the indicator is worth building at all: before it,
        // a reader inferred the parse state from the presence of a notice. A filter is a notice
        // that says nothing whatsoever about the parser.
        let filtered = ParserStateReport.of(structuralRequested: true, structuralUsed: true,
                                            degradation: .filterActive(reason: "eol=crlf"))
        report("a condition unrelated to parsing leaves the parser state alone",
               filtered.state == "parsed", filtered.chipText)

        report("the three states are the three words the specification names",
               ParserStateReport(state: "parsed", detail: nil).chipText == "parser: parsed"
                   && ParserStateReport(state: "partial", detail: nil).chipText
                       == "parser: partially parsed"
                   && ParserStateReport(state: "not-parsed", detail: nil).chipText
                       == "parser: not parsed")
    }

    print("\n=== the parser state comes from the run, not from a second opinion ===")
    do {
        let parser = TSXParser()

        let clean = structuralDiff(oldPath: "a.tsx", oldBytes: [UInt8]("const a = 1;\n".utf8),
                                   newPath: "a.tsx", newBytes: [UInt8]("const a = 2;\n".utf8),
                                   parser: parser)
        report("a real structural run on TSX reports `parsed`",
               clean.stats.parserState == .parsed, clean.stats.parserState.chipText)

        let unsupported = structuralDiff(oldPath: "a.css", oldBytes: [UInt8]("a{color:red}".utf8),
                                         newPath: "a.css", newBytes: [UInt8]("a{color:blue}".utf8),
                                         parser: parser)
        report("an unsupported language reports `not parsed` with F7's reason",
               unsupported.stats.parserState.state == "not-parsed"
                   && unsupported.stats.degradation?.code == "F7",
               unsupported.stats.parserState.chipText)

        // The same half-typed JSX F1 is measured on in `runPartialFailureChecks`.
        let broken = structuralDiff(
            oldPath: "a.tsx", oldBytes: [UInt8]("const el = <Row><Cell name=\"alpha\" /</Row>;\n".utf8),
            newPath: "a.tsx", newBytes: [UInt8]("const el = <Row><Cell name=\"omega\" /</Row>;\n".utf8),
            parser: parser)
        report("a file that parses in part reports `partial`, and the result still stands",
               broken.stats.parserState.state == "partial" && !broken.stats.usedFallback,
               broken.stats.parserState.chipText)

        // DEC-077: **what the reader is shown**, which is a different question from what the state
        // is, and this is the one the entry changed. The state, the detail, the grammar and
        // `chipText` are all still computed and all still asserted above; what follows is the far
        // shorter list of what reaches the screen.
        print("\n=== and almost none of it is drawn (DEC-077, and INV-4 is the exception) ===")

        report("a normal file says nothing at all about how it was read",
               clean.stats.parserState.plainSentence == nil, clean.stats.parserState.chipText)
        // Raw is a choice, not a degradation. `not-parsed` is the honest state for it and there is
        // nothing to disclose: the reader asked for the file exactly as it is.
        report("nor does a file the reader asked for in Raw",
               ParserStateReport.of(structuralRequested: false, structuralUsed: false,
                                    degradation: nil).plainSentence == nil)
        // The floor, and it does not move. A file that could not be read as code carries a
        // degradation, and the degradation's notice is the sentence — one sentence, in the
        // reader's language, saying what the window did, why, and that nothing was dropped.
        let unsupportedNotice = unsupported.stats.degradation?.notice ?? ""
        report("a file that could not be read as code says so in plain words (INV-4)",
               unsupportedNotice.contains("This file is shown as plain text")
                   && unsupportedNotice.contains("Every difference in it is still shown"),
               unsupportedNotice)
        report("and it does not say it twice, in two wordings",
               unsupported.stats.parserState.plainSentence == nil,
               unsupported.stats.parserState.chipText)
        // The one case with no notice behind it: the structural result stands and part of the file
        // is inside it without a structural claim. Nothing else on screen says so.
        report("a partial parse says which part, because nothing else does",
               (broken.stats.parserState.plainSentence ?? "")
                   .hasPrefix("Part of this file is shown as plain text"),
               broken.stats.parserState.plainSentence ?? "nothing")

        // Two controls. The first is the wording the entry replaced — a check that accepted it
        // would be a check about nothing; the second is the state that must stay silent.
        report("negative control: the machinery's own words are no longer the sentence",
               !unsupportedNotice.contains("Structural analysis unavailable"), unsupportedNotice)
        report("negative control: a parsed file with a sentence would be caught",
               ParserStateReport(state: "partial", detail: "1 region and 2 bytes could not be read as code")
                   .plainSentence != nil)
    }

    print("\n=== the mode pill reports the path taken, not only the selection (23b-… §2) ===")
    do {
        report("agreement says one thing", modeChipText(selected: "raw", pathTaken: "raw")
                   == "mode: raw")
        report("disagreement says both",
               modeChipText(selected: "structural", pathTaken: "raw")
                   == "mode: structural — showing raw",
               modeChipText(selected: "structural", pathTaken: "raw"))
        // The defect exactly as recorded: `mode: structural` beside a notice saying structural
        // analysis was unavailable. It must no longer be possible to say the first alone.
        report("the selection alone is never the whole sentence when the path differs",
               modeChipText(selected: "expanded", pathTaken: "raw") != "mode: expanded")
        // Unclaimed stays unclaimed: a caller that knows nothing about the path says nothing about
        // it, rather than having a claim invented for it.
        report("a caller that makes no claim gets the selection alone",
               modeChipText(selected: "structural", pathTaken: nil) == "mode: structural")

        // Three modes over two code paths (DEC-013). The first version of the pill compared the
        // path against the *mode*, so Expanded — a presentation flag over the structural path —
        // read as `mode: expanded — showing structural`, a disagreement the wording invented. The
        // selftest caught it, because that arm runs in Expanded.
        report("expanded rendered structurally is agreement, not a fallback",
               modeChipText(selected: "expanded", pathTaken: "structural") == "mode: expanded",
               modeChipText(selected: "expanded", pathTaken: "structural"))
        report("and expanded rendered raw is still a fallback",
               modeChipText(selected: "expanded", pathTaken: "raw")
                   == "mode: expanded — showing raw")
        report("the three modes map onto the two code paths",
               impliedPath(ofMode: "raw") == "raw" && impliedPath(ofMode: "structural") == "structural"
                   && impliedPath(ofMode: "expanded") == "structural")
    }

    print("\n=== both reach the renderer as words, decided once ===")
    do {
        let model = trivialModel(oldBytes: [UInt8]("a\n".utf8), newBytes: [UInt8]("b\n".utf8))
        let stated = buildRenderModel(model: model, pinOld: "x", pinNew: "y", mode: "structural",
                                      pathTaken: "raw",
                                      parser: ParserStateReport(state: "not-parsed",
                                                                detail: "budget exceeded"))
        report("the contract carries the path taken", stated.pathTaken == "raw")
        report("and composes the pill itself",
               stated.modeChip == "mode: structural — showing raw", stated.modeChip)

        let json = (try? encodeRenderModel(stated)) ?? ""
        // Carried as text rather than assembled in JavaScript: the renderer draws it and the
        // headless probe reads it, and a sentence written in two languages drifts in one of them.
        report("the encoded model carries the parser chip's words",
               json.contains("\"chipText\":\"parser: not parsed — budget exceeded\""))
        report("and the pill's words", json.contains("\"modeChip\":\"mode: structural — showing raw\""))

        let silent = buildRenderModel(model: model, pinOld: "x", pinNew: "y", mode: "raw")
        report("a caller that says nothing about the parser carries no parser claim",
               silent.parser == nil && !((try? encodeRenderModel(silent)) ?? "").contains("chipText"))
        report("and its pill still says what was selected", silent.modeChip == "mode: raw")

        // Round-tripping matters because the probe decodes what the document received.
        let decoded = try? JSONDecoder().decode(
            RenderModel.self, from: Data(((try? encodeRenderModel(stated)) ?? "").utf8))
        report("the model round-trips with both fields intact",
               decoded?.pathTaken == "raw" && decoded?.parser?.state == "not-parsed"
                   && decoded?.modeChip == stated.modeChip)
    }

    print("\n=== the uncommitted count states its convention (12-… §2, X-4) ===")
    do {
        let sentence = RepositoryReader.uncommittedCountConvention
        report("the sentence names the command it describes",
               sentence.contains("git status --porcelain"), sentence)
        report("and the disagreement it exists because of — an untracked directory counts once",
               sentence.lowercased().contains("untracked directory"), sentence)

        // The sentence has to be **true**, which is a different check: `-uall` would expand
        // untracked directories and make the same words a false statement (63 vs 165 in X-4).
        let operation = GitOperation.statusPorcelain()
        report("the operation actually run matches the sentence",
               operation.arguments.contains("--porcelain") && !operation.arguments.contains("-uall"),
               operation.arguments.joined(separator: " "))

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let shell = (try? String(contentsOf: root.appendingPathComponent("Sources/diffscope-app/main.swift"),
                                 encoding: .utf8)) ?? ""
        report("the shell reads the sentence from the Git layer rather than restating it",
               shell.contains("RepositoryReader.uncommittedCountConvention"))
        // **On the count's own row, since DEC-086.** `12-…` §2 asks the count to state its
        // convention; it did so in a caption under the whole list, drawn permanently for every
        // reader who had not asked — DEC-077's subject exactly. It rides with the row now, which is
        // where the question gets asked. The requirement is unchanged and its address is not.
        report("and puts it on the row whose count it is about",
               shell.contains("+ RepositoryReader.uncommittedCountConvention")
                   && shell.contains("cell.toolTip"))
    }

    print("\n=== an unavailable scope states its reason where it can be read (12-… §3) ===")
    do {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let shell = (try? String(contentsOf: root.appendingPathComponent("Sources/diffscope-app/main.swift"),
                                 encoding: .utf8)) ?? ""
        // The segment is disabled and its reason is in a tooltip — which is where DEC-058 found
        // three other statements hiding. A greyed control with no stated reason is the interface
        // silently disagreeing with itself between repositories, which is what §3 forbids.
        report("the reasons are collected as the segments are disabled",
               shell.contains("unavailable.append(\"\\(scope.title) — \\(reason)\")"))
        report("and reach the status line rather than only the tooltip",
               shell.contains("· unavailable: "))
    }

    print("\n=== the branch is displayed, not hovered (12-… §2, 23b-… §2) ===")
    do {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let shell = (try? String(contentsOf: root.appendingPathComponent("Sources/diffscope-app/main.swift"),
                                 encoding: .utf8)) ?? ""
        // A tooltip is not a display: it is invisible until pointed at, so a reader walking the
        // list from the keyboard — the path M8-J made a definition-of-done item — never sees it.
        // Asked of the assignment itself rather than of a slice of the file. The slice version
        // broke the moment the collapsed rail added a second `text.toolTip` above this one, and
        // it broke by *passing over* the row it was written about — the failure mode a check
        // should never have.
        // Asked of the assignment, not of a slice of the file — and re-asked when the row became
        // columns: the head state moved from the middle of one string into a field of its own, and
        // a check pinned to the old string would have failed for a change that improved the thing
        // it was protecting.
        report("the row's own text carries the head state",
               shell.contains("head.stringValue = snapshot.head.displayText"))
        report("and the head state is a field in the row, not a tooltip",
               shell.contains("let head = label("))

        // DEC-060's rail is 44 px and holds three letters. It is a collapsed state, not a hidden
        // one: the head state stays one hover and one ⌃⌘1 away, and the check says so rather than
        // leaving the exception unstated.
        let rail = shell.components(separatedBy: "if reposCollapsed {").dropFirst().first ?? ""
        report("and the collapsed rail keeps it reachable rather than dropping it",
               rail.contains("snapshot.head.displayText"))

        // The three head states, because the two unusual ones are the ones worth displaying:
        // `no commits yet` is the sentence that explains why all four scopes are greyed out.
        report("a branch reads as its name", HeadState.onBranch("main").displayText == "main")
        report("a detached head says so",
               HeadState.detached("0123456789abcdef").displayText == "detached at 01234567")
        report("an unborn head says there are no commits, and names the intended branch",
               HeadState.unborn(intendedBranch: "main").displayText == "no commits yet (main)")
    }
}
