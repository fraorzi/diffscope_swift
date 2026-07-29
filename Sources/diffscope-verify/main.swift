import DiffScopeEngine
import DiffScopeGit
import Foundation

if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--emit-model" {
    let old = [UInt8]((try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) ?? Data())
    let new = [UInt8]((try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))) ?? Data())
    let model = trivialModel(oldBytes: old, newBytes: new)
    let render = buildRenderModel(model: model, pinOld: contentHashHex(old), pinNew: contentHashHex(new))
    print((try? encodeRenderModel(render)) ?? "{}")
    exit(0)
}

if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--budget-survey" {
    runBudgetSurvey(root: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}

if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--survey" {
    let root = URL(fileURLWithPath: CommandLine.arguments[2])
    let discovery = RepositoryDiscovery(maximumDepth: 2)
    let result = discovery.discover(sources: [DiscoverySource(url: root, kind: .root)])
    print("discovered \(result.repositories.count) repositories under \(root.path)\n")
    var sources: [String: Int] = [:]
    let sweep = RepositorySweep()
    let outcome = sweep.run(over: result.repositories.map(\.url))
    let started = Date().addingTimeInterval(-outcome.elapsedSeconds)
    for snapshot in outcome.snapshots {
        let baseText: String
        switch snapshot.base {
        case let .resolved(ref, source):
            sources[source.rawValue, default: 0] += 1
            baseText = "\(snapshot.baseRefUsed ?? ref) [\(source.rawValue)]"
        case .needsUserChoice:
            sources["needsUserChoice", default: 0] += 1
            baseText = "PROMPT"
        }
        let ahead = snapshot.aheadCount.map(String.init) ?? "unknown"
        print(String(format: "  %-40@  %-34@  %2d changed  ahead %-7@  %@",
                     snapshot.displayName as NSString,
                     snapshot.head.displayText as NSString,
                     snapshot.uncommittedCount,
                     ahead as NSString,
                     baseText as NSString))
    }
    print(String(format: "\n  elapsed %.0f ms", Date().timeIntervalSince(started) * 1000))
    print("  base resolution: \(sources.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  "))")
    for diagnostic in result.diagnostics { print("  diagnostic: \(diagnostic)") }
    exit(0)
}

func contentHashHex(_ bytes: [UInt8]) -> String { contentHash(bytes) }

var failures = 0
var checks = 0

func report(_ name: String, _ ok: Bool, _ detail: String = "") {
    checks += 1
    if ok {
        print("  PASS  \(name)")
    } else {
        failures += 1
        print("  FAIL  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func exactHunks(_ a: [UInt8], _ b: [UInt8]) -> [Hunk] {
    if case let .exact(h) = canonicalDiff(old: a, new: b) { return h }
    return []
}

func lcsLength(_ a: [UInt8], _ b: [UInt8]) -> Int {
    if a.isEmpty || b.isEmpty { return 0 }
    var previous = [Int](repeating: 0, count: b.count + 1)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        for j in 1...b.count {
            current[j] = a[i - 1] == b[j - 1]
                ? previous[j - 1] + 1
                : max(previous[j], current[j - 1])
        }
        swap(&previous, &current)
    }
    return previous[b.count]
}

struct Rng {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

print("=== canonical diff: minimality against DP reference ===")
do {
    var rng = Rng(state: 0x5EED)
    var worstMatched = 0
    var worstLcs = 0
    var mismatches = 0
    var nonEqualMatch = 0
    var misordered = 0
    var bothHunkAndMatch = 0
    var neitherHunkNorMatch = 0

    for _ in 0..<600 {
        let alphabet = 2 + rng.next(4)
        let aLen = rng.next(40)
        let bLen = rng.next(40)
        let a = (0..<aLen).map { _ in UInt8(rng.next(alphabet)) }
        let b = (0..<bLen).map { _ in UInt8(rng.next(alphabet)) }

        let matches = canonicalMatches(old: a, new: b).matches
        let matched = matches.reduce(0) { $0 + $1.length }
        let reference = lcsLength(a, b)
        if matched != reference {
            mismatches += 1
            if matched < worstMatched || mismatches == 1 { worstMatched = matched; worstLcs = reference }
        }
        for match in matches {
            for offset in 0..<match.length
            where a[match.oldStart + offset] != b[match.newStart + offset] {
                nonEqualMatch += 1
            }
        }
        var oldCursor = -1, newCursor = -1
        for match in matches {
            if match.oldStart <= oldCursor || match.newStart <= newCursor { misordered += 1 }
            oldCursor = match.oldStart + match.length - 1
            newCursor = match.newStart + match.length - 1
        }

        guard case let .exact(hunks) = canonicalDiff(old: a, new: b) else { continue }
        var inHunk = [Bool](repeating: false, count: a.count)
        for hunk in hunks { for i in hunk.oldStart..<hunk.oldEnd { inHunk[i] = true } }
        var inMatch = [Bool](repeating: false, count: a.count)
        for match in matches { for i in match.oldStart..<(match.oldStart + match.length) { inMatch[i] = true } }
        for i in 0..<a.count where inHunk[i] == inMatch[i] {
            if inHunk[i] { bothHunkAndMatch += 1 } else { neitherHunkNorMatch += 1 }
        }
    }

    report("matched length equals LCS on 600 random pairs", mismatches == 0,
           mismatches > 0 ? "\(mismatches) mismatches, e.g. matched \(worstMatched) vs LCS \(worstLcs)" : "")
    report("every reported match is byte-equal", nonEqualMatch == 0, "\(nonEqualMatch) bad bytes")
    report("matches are strictly increasing on both sides", misordered == 0, "\(misordered) out of order")
    report("no old byte is in both a hunk and a match", bothHunkAndMatch == 0, "\(bothHunkAndMatch) bytes")
    report("no old byte is in neither a hunk nor a match", neitherHunkNorMatch == 0, "\(neitherHunkNorMatch) bytes")
}

print("\n=== canonical diff: edge cases ===")
do {
    report("empty vs empty yields no hunks", exactHunks([], []).isEmpty)
    report("empty vs content yields one hunk", exactHunks([], [1, 2, 3]).count == 1)
    report("content vs empty yields one hunk", exactHunks([1, 2, 3], []).count == 1)
    report("identical input yields no hunks", exactHunks([1, 2, 3], [1, 2, 3]).isEmpty)
    let single = exactHunks([1, 2, 3], [1, 9, 3])
    report("single byte change yields one tight hunk",
           single.count == 1 && single[0].oldStart == 1 && single[0].oldEnd == 2,
           single.description)
}

print("\n=== partition assertions (T-0) ===")
do {
    let good = Partition(totalLength: 10, segments: [
        Segment(start: 0, end: 4, label: .unchanged),
        Segment(start: 4, end: 10, label: .changed),
    ])
    report("well-formed partition has no defects", partitionDefects(good).isEmpty)

    let gap = Partition(totalLength: 10, segments: [
        Segment(start: 0, end: 4, label: .unchanged),
        Segment(start: 6, end: 10, label: .changed),
    ])
    report("gap is detected", partitionDefects(gap).contains { if case .gap = $0 { return true }; return false })

    let overlap = Partition(totalLength: 10, segments: [
        Segment(start: 0, end: 6, label: .unchanged),
        Segment(start: 4, end: 10, label: .changed),
    ])
    report("overlap is detected", partitionDefects(overlap).contains { if case .overlap = $0 { return true }; return false })

    let zero = Partition(totalLength: 4, segments: [
        Segment(start: 0, end: 0, label: .unchanged),
        Segment(start: 0, end: 4, label: .changed),
    ])
    report("zero-width segment is detected",
           partitionDefects(zero).contains { if case .negativeOrZeroWidth = $0 { return true }; return false })

    let short = Partition(totalLength: 10, segments: [Segment(start: 0, end: 4, label: .changed)])
    report("truncated partition is detected", !partitionDefects(short).isEmpty)

    report("empty partition of length 0 is valid", partitionDefects(Partition(totalLength: 0, segments: [])).isEmpty)
}

print("\n=== validator catches deliberately broken models ===")
do {
    let old: [UInt8] = Array("hello world".utf8)
    let new: [UInt8] = Array("hello swift".utf8)

    let lying = DiffModel(
        oldBytes: old, newBytes: new,
        oldPartition: wholeFilePartition(length: old.count, label: .unchanged),
        newPartition: wholeFilePartition(length: new.count, label: .unchanged)
    )
    let lyingViolations = validate(lying).violations
    report("INV-3 catches 'no changes' on differing bytes",
           lyingViolations.contains { if case .claimedUnchangedButBytesDiffer = $0 { return true }; return false },
           lyingViolations.description)

    let equalBytes: [UInt8] = Array("same".utf8)
    let overclaiming = DiffModel(
        oldBytes: equalBytes, newBytes: equalBytes,
        oldPartition: wholeFilePartition(length: equalBytes.count, label: .changed),
        newPartition: wholeFilePartition(length: equalBytes.count, label: .changed)
    )
    report("INV-3 catches changes claimed on identical bytes",
           validate(overclaiming).violations.contains { if case .claimedChangedButBytesEqual = $0 { return true }; return false })

    let partialCover = DiffModel(
        oldBytes: old, newBytes: new,
        oldPartition: Partition(totalLength: old.count, segments: [
            Segment(start: 0, end: 6, label: .changed),
            Segment(start: 6, end: old.count, label: .unchanged),
        ]),
        newPartition: Partition(totalLength: new.count, segments: [
            Segment(start: 0, end: 6, label: .changed),
            Segment(start: 6, end: new.count, label: .unchanged),
        ])
    )
    report("INV-2 catches a changed byte left outside every presented segment",
           validate(partialCover).violations.contains { if case .uncoveredByte = $0 { return true }; return false })

    let brokenReconstruction = DiffModel(
        oldBytes: old, newBytes: new,
        oldPartition: Partition(totalLength: old.count, segments: [
            Segment(start: 0, end: 5, label: .fallback),
            Segment(start: 5, end: old.count, label: .fallback),
        ]),
        newPartition: Partition(totalLength: new.count + 3, segments: [
            Segment(start: 0, end: new.count, label: .fallback),
        ])
    )
    report("INV-1 catches a partition whose total length lies",
           validate(brokenReconstruction).violations.contains { if case .partitionMalformed = $0 { return true }; return false })
}

print("\n=== fixtures ===")
let fixtureRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("fixtures")
var fixtureCount = 0
if let entries = try? FileManager.default.contentsOfDirectory(at: fixtureRoot, includingPropertiesForKeys: nil) {
    for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard let beforeURL = files.first(where: { $0.lastPathComponent.hasPrefix("before.") }),
              let afterURL = files.first(where: { $0.lastPathComponent.hasPrefix("after.") }),
              let beforeData = try? Data(contentsOf: beforeURL),
              let afterData = try? Data(contentsOf: afterURL)
        else { continue }

        fixtureCount += 1
        let name = dir.lastPathComponent
        let old = [UInt8](beforeData)
        let new = [UInt8](afterData)

        let model = trivialModel(oldBytes: old, newBytes: new)
        let result = validate(model)
        report("\(name): invariants hold", result.passed, result.summary)
        report("\(name): coverage actually checked", result.coverageChecked || old == new)

        let again = validate(trivialModel(oldBytes: old, newBytes: new))
        report("\(name): deterministic", result.summary == again.summary)

        let hunksA = canonicalDiff(old: old, new: new)
        let hunksB = canonicalDiff(old: old, new: new)
        report("\(name): canonical diff deterministic", hunksA == hunksB)

        if old != new, case let .exact(hs) = hunksA {
            report("\(name): reports at least one hunk", !hs.isEmpty)
        }
    }
}
report("fixture directory was found and non-empty", fixtureCount > 0, "found \(fixtureCount)")


print("\n=== work budget: pathological input must terminate, not hang ===")
do {
    var rng = Rng(state: 0xBEEF)
    let n = 120 * 1024
    let a = (0..<n).map { _ in UInt8(97 + rng.next(26)) }
    let b = (0..<n).map { _ in UInt8(97 + rng.next(26)) }
    let started = Date()
    let outcome = canonicalDiff(old: a, new: b)
    let elapsed = Date().timeIntervalSince(started)
    var exceeded = false
    if case .budgetExceeded = outcome { exceeded = true }
    report("120 KB of unrelated bytes returns budgetExceeded", exceeded)
    report("and returns in under 2 seconds", elapsed < 2.0, String(format: "%.2f s", elapsed))

    let model = trivialModel(oldBytes: a, newBytes: b)
    let result = validate(model)
    report("validator reports unverified rather than a violation", result.passed && !result.coverageChecked, result.summary)
}

runContractChecks { name, ok, detail in report(name, ok, detail) }
runSyntaxChecks { name, ok, detail in report(name, ok, detail) }
runMatchingChecks { name, ok, detail in report(name, ok, detail) }
runClassificationChecks { name, ok, detail in report(name, ok, detail) }
runBoundaryChecks { name, ok, detail in report(name, ok, detail) }
runDisclosureChecks { name, ok, detail in report(name, ok, detail) }
runMoveChecks { name, ok, detail in report(name, ok, detail) }
runNavigationChecks { name, ok, detail in report(name, ok, detail) }
runRefreshChecks { name, ok, detail in report(name, ok, detail) }
runBudgetChecks { name, ok, detail in report(name, ok, detail) }
runGitChecks { name, ok, detail in report(name, ok, detail) }
runDegradationChecks { name, ok, detail in report(name, ok, detail) }
runBundleFreshnessCheck { name, ok, detail in report(name, ok, detail) }

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 { print("FAILED"); exit(1) }
print("OK")
