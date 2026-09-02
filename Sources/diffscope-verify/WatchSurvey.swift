import Foundation
import DiffScopeGit

/// The two numbers the UI audit could not settle by reading, measured against the reader's own
/// repositories rather than against a fixture.
///
/// **The exclusion budget.** `FSEventStreamSetExclusionPaths` takes at most eight paths, and
/// `RepositoryWatcher` spends them on `node_modules` directories found within three levels. Over
/// the limit the surplus **stays watched** — a noisier watcher, never a deaf one — and the
/// truncation is disclosed only into the status line, where the next sentence overwrites it. So the
/// question is not whether it fails but how often it is exceeded, and by how much.
///
/// **The mid-write refusal rate.** `settledRead` brackets a read with a stat, re-reads, and
/// confirms after a delay, retrying five times. DEC-068 measured 42–52 refusals per 100 pins at a
/// 20 ms confirm delay; the delay is 5 ms now and has never been re-measured. A refusal is not a
/// defect — it is the guard doing its job — but a *rate* is what says whether the guard has become
/// a nuisance on this machine.
func runWatchSurvey(root: String) {
    let url = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
    let discovery = RepositoryDiscovery(maximumDepth: 2)
    let found = discovery.discover(sources: [DiscoverySource(url: url, kind: .root)])
    print("=== the watcher's exclusion budget, over \(found.repositories.count) repositories ===")
    print("   limit is \(RepositoryWatcher.exclusionLimit), searched to depth 3\n")

    var over: [(String, Int)] = []
    var totals: [Int] = []
    for repository in found.repositories {
        let count = RepositoryWatcher.nodeModulesDirectories(under: repository.url).count
        totals.append(count)
        if count > RepositoryWatcher.exclusionLimit {
            over.append((repository.url.lastPathComponent, count))
        }
    }
    let worst = totals.max() ?? 0
    print(String(format: "   node_modules found: max %d · mean %.1f · over the limit: %d of %d",
                 worst, totals.isEmpty ? 0 : Double(totals.reduce(0, +)) / Double(totals.count),
                 over.count, totals.count))
    for (name, count) in over.sorted(by: { $0.1 > $1.1 }).prefix(10) {
        print("     \(name): \(count) — \(count - RepositoryWatcher.exclusionLimit) stay watched")
    }
    if over.isEmpty { print("     none — every repository fits inside the budget") }

    print("\n=== the mid-write refusal rate, on this filesystem ===")
    let scopes = ScopeReader()
    var reads = 0, refused = 0
    var slowest: (String, Int)?
    for repository in found.repositories.prefix(12) {
        guard let files = try? scopes.changedFiles(scope: .allLocalVsHead, in: repository.url,
                                                   baseRef: nil), !files.isEmpty else { continue }
        var repoReads = 0, repoRefused = 0
        for file in files.prefix(20) {
            for _ in 0..<3 {
                guard let pair = try? scopes.pinnedPair(for: file, scope: .allLocalVsHead,
                                                        in: repository.url, mergeBaseRev: nil)
                else { continue }
                reads += 1; repoReads += 1
                if !pair.stable { refused += 1; repoRefused += 1 }
            }
        }
        if repoRefused > 0, repoRefused > (slowest?.1 ?? 0) {
            slowest = (repository.url.lastPathComponent, repoRefused)
        }
        _ = repoReads
    }
    if reads == 0 {
        print("   no changed files anywhere under \(url.path) — nothing to read")
    } else {
        print(String(format: "   %d reads · %d refused · %.1f%%",
                     reads, refused, Double(refused) * 100 / Double(reads)))
        print("   DEC-068 measured 42–52 refusals per 100 pins at a 20 ms confirm delay.")
        if let slowest { print("   most refusals in one repository: \(slowest.0) — \(slowest.1)") }
    }
}
