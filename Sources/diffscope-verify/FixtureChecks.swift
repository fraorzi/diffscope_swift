import CryptoKit
import DiffScopeEngine
import DiffScopeSyntax
import Foundation

/// The fixture corpus, run against the T-series of `15-test-corpus-plan.md` §3 by number.
///
/// Two things this file exists to stop happening again.
///
/// **Every fixture used to be validated on the raw path only.** The loop built `trivialModel` —
/// the whole-file fallback partition — so `jsx-wrapper-removal`, the founding case of the product,
/// had never had its *structural* model checked against the invariants by the fixture harness.
/// Structural correctness was exercised only on inputs written inline in other check files.
///
/// **`MANIFEST.json` was read by nothing**, while `21-agent-handoff.md` §9 stated that fixture
/// bytes are verified against recorded hashes. That verification did not exist. Third instance of
/// the same defect class in this project, after `runBundleFreshnessCheck` and `checkAttr`.

struct FixturePair {
    let name: String
    let oldPath: String
    let newPath: String
    let old: [UInt8]
    let new: [UInt8]
}

func loadFixtures(root: URL) -> [FixturePair] {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
    var pairs: [FixturePair] = []
    for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard let beforeURL = files.first(where: { $0.lastPathComponent.hasPrefix("before.") }),
              let afterURL = files.first(where: { $0.lastPathComponent.hasPrefix("after.") }),
              let beforeData = try? Data(contentsOf: beforeURL),
              let afterData = try? Data(contentsOf: afterURL)
        else { continue }
        pairs.append(FixturePair(
            name: dir.lastPathComponent,
            oldPath: beforeURL.lastPathComponent, newPath: afterURL.lastPathComponent,
            old: [UInt8](beforeData), new: [UInt8](afterData)
        ))
    }
    return pairs
}

func fixtureHash(_ bytes: [UInt8]) -> String { sha256(bytes) }

private func sha256(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
}

/// Regenerates `MANIFEST.json`. Kept behind a flag so that adding a fixture is two deliberate acts
/// rather than an edit that quietly passes: the corpus records what the bytes *were*, and a
/// recording that updates itself records nothing.
func writeFixtureManifest(root: URL) {
    var manifest: [String: [String: [String: Any]]] = [:]
    for fixture in loadFixtures(root: root) {
        manifest[fixture.name] = [
            "before": ["bytes": fixture.old.count, "ext": String(fixture.oldPath.split(separator: ".").last ?? ""),
                       "sha256": sha256(fixture.old)],
            "after": ["bytes": fixture.new.count, "ext": String(fixture.newPath.split(separator: ".").last ?? ""),
                      "sha256": sha256(fixture.new)],
        ]
    }
    guard let data = try? JSONSerialization.data(
        withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    else { print("could not encode manifest"); return }
    let url = root.appendingPathComponent("MANIFEST.json")
    try? (String(decoding: data, as: UTF8.self) + "\n").write(to: url, atomically: true, encoding: .utf8)
    print("wrote \(manifest.count) fixtures to \(url.path)")
}

func runFixtureChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("fixtures")
    let fixtures = loadFixtures(root: root)
    let parser = TSXParser()

    print("\n=== fixture bytes match MANIFEST.json ===")
    do {
        // Editors silently repair CRLF and NFD, which is precisely what `line-ending-change` and
        // `nfc-vs-nfd` exist to carry. A fixture repaired by an editor still passes every
        // invariant — it just stops testing the thing it was written for.
        let manifestURL = root.appendingPathComponent("MANIFEST.json")
        let raw = (try? Data(contentsOf: manifestURL)) ?? Data()
        let manifest = (try? JSONSerialization.jsonObject(with: raw)) as? [String: [String: [String: Any]]]
        report("MANIFEST.json parses", manifest != nil)

        var mismatches: [String] = []
        var unrecorded: [String] = []
        // A malformed manifest used to `return` out of the whole function, taking every T-series
        // check with it — the suite would have gone green on a corpus it never looked at. The
        // manifest failing is a manifest failure, not a reason to stop checking fixtures.
        for fixture in fixtures where manifest != nil {
            guard let entry = manifest?[fixture.name] else { unrecorded.append(fixture.name); continue }
            for (side, bytes) in [("before", fixture.old), ("after", fixture.new)] {
                guard let recorded = entry[side] else { unrecorded.append("\(fixture.name)/\(side)"); continue }
                if (recorded["sha256"] as? String) != sha256(bytes) {
                    mismatches.append("\(fixture.name)/\(side) hash")
                }
                if (recorded["bytes"] as? Int) != bytes.count {
                    mismatches.append("\(fixture.name)/\(side) length")
                }
            }
        }
        report("every fixture on disk matches its recorded hash and length",
               mismatches.isEmpty, mismatches.joined(separator: ", "))
        // The silent case is the new fixture nobody recorded, which would otherwise be exempt from
        // the check for as long as it existed.
        report("every fixture has a manifest entry", unrecorded.isEmpty, unrecorded.joined(separator: ", "))
        let recordedNames = Set(manifest?.keys ?? [:].keys)
        let presentNames = Set(fixtures.map(\.name))
        report("the manifest records no fixture that has been deleted",
               recordedNames.subtracting(presentNames).isEmpty,
               recordedNames.subtracting(presentNames).sorted().joined(separator: ", "))
    }

    print("\n=== fixtures: T-0…T-11 on both paths ===")
    report("fixture directory was found and non-empty", !fixtures.isEmpty, "found \(fixtures.count)")

    var structuralRuns = 0
    var skipped: [String] = []
    for fixture in fixtures {
        let raw = trivialModel(oldBytes: fixture.old, newBytes: fixture.new)
        assertTSeries(fixture: fixture, model: raw, path: "raw", parser: parser, report: report)

        // The structural path is only defined for the languages DEC-004 admits; a skip is reported
        // rather than silently passed over, because "no structural check ran" and "the structural
        // check passed" look identical in a green suite.
        let classification = classify(path: fixture.newPath, bytes: fixture.new)
        guard classification.isStructural else {
            skipped.append("\(fixture.name) (\(classification.reason ?? "not structural"))")
            continue
        }
        let result = structuralDiff(oldPath: fixture.oldPath, oldBytes: fixture.old,
                                    newPath: fixture.newPath, newBytes: fixture.new, parser: parser)
        structuralRuns += 1
        // Printed rather than asserted: what the structural layer actually made of each fixture is
        // the audit's raw material, and a T-check that never fires (T-11 with no moves in the
        // corpus) is invisible without it.
        let stats = result.stats
        var hunks = 0
        var hunkBytes = 0
        if case let .exact(hs) = canonicalDiff(old: fixture.old, new: fixture.new) {
            hunks = hs.count
            hunkBytes = hs.reduce(0) { $0 + ($1.oldEnd - $1.oldStart) + ($1.newEnd - $1.newStart) }
        }
        print("      \(fixture.name): \(hunks) hunks/\(hunkBytes)B, \(stats.anchors) anchors, \(stats.movesFound) moves"
            + " (\(stats.movesBelowFloor) below floor), \(stats.formattingOnlySegments) formatting-only,"
            + " \(stats.behaviorAffectingSegments) reordered, \(stats.invisibleSegments) invisible"
            + (stats.usedFallback ? " — FELL BACK: \(stats.fallbackReason ?? "")" : ""))
        // `DIFFSCOPE_SEGMENTS=<fixture> swift run diffscope-verify` prints one fixture's reconciled
        // segments with their text. Kept because the counts above say *that* something did not
        // happen and never *why*: this is what showed the move search a line beginning with an
        // `export ` the byte diff had already matched elsewhere (M8-C).
        if ProcessInfo.processInfo.environment["DIFFSCOPE_SEGMENTS"] == fixture.name {
            for (side, part, bytes) in [("old", result.model.oldPartition, fixture.old),
                                        ("new", result.model.newPartition, fixture.new)] {
                for seg in part.segments {
                    let text = String(decoding: bytes[seg.start..<seg.end], as: UTF8.self)
                    print("        \(side) \(seg.start)..<\(seg.end) \(seg.label.rawValue) \(text.debugDescription)")
                }
            }
        }
        assertTSeries(fixture: fixture, model: result.model,
                      path: result.stats.usedFallback ? "structural→fallback" : "structural",
                      parser: parser, report: report)

        // T-9 — parser failure yields fallback, never a missing change. Driven by whether the
        // parser actually reported error nodes rather than by whether the run happened to fall
        // back: tree-sitter recovers from most broken input, so the interesting case is the file
        // that parsed *with* errors and still had to present every difference.
        let brokenParse = (parser?.parse(fixture.new)?.hasErrorNodes ?? true)
            || (parser?.parse(fixture.old)?.hasErrorNodes ?? true)
        if brokenParse {
            let validation = validate(result.model)
            // Either side, not the new one: `truncated-file` and `invalid-tsx` are pure deletions,
            // so the new side has no changed bytes to show and asserting on it alone fails a
            // correct result. Found by this check on its first run.
            let presentsChange = (result.model.oldPartition.segments
                + result.model.newPartition.segments).contains { $0.label != .unchanged }
            report("T-9 \(fixture.name): broken source still presents every difference",
                   validation.passed && (presentsChange || fixture.old == fixture.new),
                   "fellBack=\(result.stats.usedFallback) \(validation.summary)")
        }
    }
    print("      structural path ran on \(structuralRuns) of \(fixtures.count) fixtures")
    for skip in skipped { print("      skipped: \(skip)") }
}

/// One assertion set, applied to every fixture on every path, named by T-number so the output reads
/// as the coverage table it is supposed to be.
private func assertTSeries(
    fixture: FixturePair,
    model: DiffModel,
    path: String,
    parser: TSXParser?,
    report: (String, Bool, String) -> Void
) {
    let tag = "\(fixture.name) [\(path)]"

    // T-0 — partition well-formedness, the cheap structural assertion.
    let defects = partitionDefects(model.oldPartition) + partitionDefects(model.newPartition)
    report("T-0 \(tag): partition is well-formed", defects.isEmpty,
           defects.map(\.description).joined(separator: "; "))

    // T-1/T-2 — reconstruction, computed here rather than by asking the partition about itself.
    // §"On T-0 versus T-1/T-3": a partition with a bug in its own checking would mark its own
    // homework.
    report("T-1 \(tag): old side reconstructs byte-for-byte",
           reconstruct(model.oldPartition, from: model.oldBytes) == fixture.old, "")
    report("T-2 \(tag): new side reconstructs byte-for-byte",
           reconstruct(model.newPartition, from: model.newBytes) == fixture.new, "")

    let validation = validate(model)

    // T-3 — every canonical hunk byte lies inside a presented range. Containment, not intersection.
    if validation.coverageChecked {
        report("T-3 \(tag): every changed byte is contained in a presented range",
               validation.passed, validation.summary)
    } else {
        // Not silently skipped: an unchecked file is reported as unchecked, which is the whole
        // point of DEC-043's "unverified means not checked, never failed".
        report("T-3 \(tag): coverage unverified, and says so", !validation.coverageChecked, "")
    }

    // T-4 — "no changes" iff byte-equal, asserted in both directions.
    let presentsNoChange = model.oldPartition.segments.allSatisfy { $0.label == .unchanged }
        && model.newPartition.segments.allSatisfy { $0.label == .unchanged }
    report("T-4 \(tag): no-change is shown exactly when the sides are byte-equal",
           presentsNoChange == (fixture.old == fixture.new),
           "presents=\(presentsNoChange) equal=\(fixture.old == fixture.new)")

    // T-5 — a fallback that reaches the contract is marked as one.
    let render = buildRenderModel(model: model, pinOld: fixtureHash(fixture.old),
                                  pinNew: fixtureHash(fixture.new), mode: "structural",
                                  validation: validation)
    let fallbackSegments = model.oldPartition.segments.filter { $0.label == .fallback }
    if !fallbackSegments.isEmpty {
        report("T-5 \(tag): fallback ranges arrive marked",
               marksFallback(render), "\(fallbackSegments.count) fallback segments")
    }

    // T-7 — determinism, on the encoded contract rather than on a summary string. A model that
    // differed only in a field the summary omits used to pass this.
    let again = buildRenderModel(model: model, pinOld: fixtureHash(fixture.old),
                                 pinNew: fixtureHash(fixture.new), mode: "structural",
                                 validation: validate(model))
    report("T-7 \(tag): identical input produces an identical contract",
           (try? encodeRenderModel(render)) == (try? encodeRenderModel(again)), "")

    // T-6 — Structural and Expanded present the same segments. They are flags over one model, so
    // this holds by construction; it is asserted per fixture because "by construction" has been
    // wrong before (M6-D).
    let expanded = buildRenderModel(model: model, pinOld: fixtureHash(fixture.old),
                                    pinNew: fixtureHash(fixture.new), mode: "expanded",
                                    validation: validation)
    report("T-6 \(tag): Structural and Expanded agree on what changed",
           segmentSignature(render) == segmentSignature(expanded), "")

    // T-8 — no normalisation happened anywhere. Comparison is on bytes (DEC-021), so a pair that
    // is canonically equivalent and byte-different must still report a change.
    //
    // The comparison below goes through **scalar arrays**. M6-C paid for that lesson: Swift's
    // `String ==` is canonical equivalence, so the obvious `nfc(a) != a` test is always false and
    // a detector written on it silently detects nothing while its fixtures pass.
    if let oldText = String(bytes: fixture.old, encoding: .utf8),
       let newText = String(bytes: fixture.new, encoding: .utf8) {
        let oldScalars = Array(oldText.precomposedStringWithCanonicalMapping.unicodeScalars)
        let newScalars = Array(newText.precomposedStringWithCanonicalMapping.unicodeScalars)
        if oldScalars == newScalars && fixture.old != fixture.new {
            let presentsChange = !model.newPartition.segments.allSatisfy { $0.label == .unchanged }
            report("T-8 \(tag): canonically equivalent but byte-different still reports a change",
                   presentsChange, "normalised comparison would report nothing here")
        }
    }

    // T-10 — presented ranges land on grapheme-cluster boundaries. Comparison stays on bytes
    // (DEC-021); it is *display* that must not cut a combining mark off its base.
    let oldOffsets = graphemeBoundaries(fixture.old)
    let newOffsets = graphemeBoundaries(fixture.new)
    let oldOffenders = model.oldPartition.segments.filter {
        !oldOffsets.contains($0.start) || !oldOffsets.contains($0.end)
    }
    let newOffenders = model.newPartition.segments.filter {
        !newOffsets.contains($0.start) || !newOffsets.contains($0.end)
    }
    report("T-10 \(tag): presented ranges start and end on grapheme boundaries",
           oldOffenders.isEmpty && newOffenders.isEmpty,
           (oldOffenders + newOffenders).prefix(3).map { "\($0.start)..<\($0.end)" }.joined(separator: " "))

    // T-11 — a move carries its delta. DEC-038 admits byte-identical moves only, so any linked
    // pair must be byte-equal; a move that had swallowed an edit would not be.
    var moves: [Int: (old: [UInt8], new: [UInt8])] = [:]
    for segment in model.oldPartition.segments {
        guard let link = segment.link else { continue }
        moves[link, default: ([], [])].old += fixture.old[segment.start..<segment.end]
    }
    for segment in model.newPartition.segments {
        guard let link = segment.link else { continue }
        moves[link, default: ([], [])].new += fixture.new[segment.start..<segment.end]
    }
    if !moves.isEmpty {
        let broken = moves.filter { $0.value.old != $0.value.new }
        report("T-11 \(tag): every move's two sides are byte-equal, so no delta was swallowed",
               broken.isEmpty, "\(broken.count) of \(moves.count) links differ")
    }
}

/// Byte offsets at which a grapheme cluster starts, plus the end of the buffer. Invalid UTF-8 has
/// no grapheme structure to speak of, so every offset is admitted rather than failing a file the
/// product deliberately refuses to interpret.
func graphemeBoundaries(_ bytes: [UInt8]) -> Set<Int> {
    guard let text = String(bytes: bytes, encoding: .utf8) else { return Set(0...max(bytes.count, 0)) }
    var offsets: Set<Int> = [0, bytes.count]
    var offset = 0
    for character in text {
        offset += String(character).utf8.count
        offsets.insert(offset)
    }
    return offsets
}

/// INV-4 asks that a fallback be *marked*, not that it be marked in one particular place. A file
/// that cannot be decoded has no segments to mark, so it is marked whole: the payload says
/// `unrenderable` with a reason and the notice says the same in words (DEC-044). Accepting only the
/// per-segment form would have failed `invalid-utf8` and `binary-file` for being correct.
private func marksFallback(_ render: RenderModel) -> Bool {
    switch render.payload {
    case let .text(old, new):
        return (old.segments + new.segments).contains { $0.label == "fallback" }
    case .unrenderable:
        return render.notices.contains { $0.contains("not valid UTF-8") }
    }
}

private func segmentSignature(_ render: RenderModel) -> String {
    guard case let .text(old, new) = render.payload else { return "unrenderable" }
    return (old.segments + new.segments)
        .map { "\($0.start)-\($0.end)-\($0.label)" }
        .joined(separator: "|")
}
