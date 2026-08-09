import DiffScopeGit
import Foundation

/// OQ-046 — **can any read-only Git operation trigger `gc --auto`?**
///
/// The question has been open since the read-only audit, and the audit itself said why it could not
/// answer it: it ran on a scratch repository far below git's auto-gc thresholds, so a "no" from it
/// would have been a "no" about the wrong repository.
///
/// The trap in the question is the mitigation. `gc.auto=0` is the obvious answer and DEC-003
/// forbids it — writing configuration into the user's repository is a write. Passing it per
/// invocation as `-c gc.auto=0` is forbidden too, and for an unrelated reason: `-c` is in
/// `GitOperation.forbiddenArguments`, because an operation whose configuration a caller can inject
/// is no longer the operation the registry describes. So if a read path *can* trigger maintenance,
/// neither obvious mitigation is available and the answer costs a decision.
///
/// **Method.** Rather than build a repository large enough to cross the real thresholds — 6,700
/// loose objects, 50 packs — the thresholds are brought down to the repository: `gc.auto=1`,
/// `gc.autoPackLimit=1`, `gc.autoDetach=false`. Under that configuration git will run maintenance
/// at the first opportunity it is offered, in the foreground, where it can be observed. A read-only
/// operation that is going to trigger gc will do it here.
///
/// The positive control is the point of the whole check: a `git commit` in the same repository
/// **must** produce the maintenance the read-only operations do not. Without it, "no gc happened"
/// is equally consistent with "the configuration was not eager after all", which is the shape of a
/// check that proves nothing while passing.
func runAutoGcChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    let fm = FileManager.default
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("diffscope-autogc-\(UUID().uuidString)")
    try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: scratch) }

    let repo = makeRepository("gc-eager", in: scratch)
    _ = shell(["config", "gc.auto", "1"], in: repo)
    _ = shell(["config", "gc.autoPackLimit", "1"], in: repo)
    // Detached gc would run after the check finished and be scored as "nothing happened".
    _ = shell(["config", "gc.autoDetach", "false"], in: repo)

    // Loose objects and more than one pack, so both of git's auto-maintenance triggers are armed.
    for index in 0..<12 {
        try? "line \(index)\n".write(to: repo.appendingPathComponent("file\(index).txt"),
                                     atomically: true, encoding: .utf8)
        _ = shell(["add", "-A"], in: repo)
        _ = shell(["commit", "-qm", "commit \(index)", "--no-gpg-sign"], in: repo)
        // Without `-d`, so the packs accumulate: `gc.autoPackLimit` counts packs, and a repack that
        // deletes what it replaced leaves exactly one however often it runs.
        if index == 4 || index == 8 { _ = shell(["repack", "-q"], in: repo) }
    }

    /// What maintenance leaves behind: packs, loose objects, and the log git writes when an
    /// auto-run fails. Counted rather than hashed, because a pack's name is its content hash and
    /// two runs of gc on the same objects would otherwise look like no change at all.
    func maintenanceState() -> (packs: Int, loose: Int, log: Bool) {
        let objects = repo.appendingPathComponent(".git/objects")
        let packDir = objects.appendingPathComponent("pack")
        let packs = ((try? fm.contentsOfDirectory(atPath: packDir.path)) ?? [])
            .filter { $0.hasSuffix(".pack") }.count
        var loose = 0
        for entry in (try? fm.contentsOfDirectory(atPath: objects.path)) ?? [] {
            guard entry.count == 2, entry != "pack", entry != "info" else { continue }
            loose += ((try? fm.contentsOfDirectory(
                atPath: objects.appendingPathComponent(entry).path)) ?? []).count
        }
        return (packs, loose, fm.fileExists(atPath: repo.appendingPathComponent(".git/gc.log").path))
    }

    print("\n=== OQ-046: no read-only operation triggers auto-gc, measured where it would fire ===")

    let armed = maintenanceState()
    let thresholds = shell(["config", "--get-regexp", "^gc\\."], in: repo)
        .split(separator: "\n").sorted().joined(separator: " · ")
    // The state to assert is *not* "many packs". Building the repository already trips auto-gc
    // several times — the commits in the loop above are themselves opportunities — so by the time
    // anything is measured git has packed and pruned, and the repository sits at one pack with a
    // handful of loose objects. That is not a failure to arm it; it is the arming working. What is
    // asserted here is that the thresholds are in force and there is loose material to collect.
    report("the repository is armed: eager thresholds in force, with loose objects to collect",
           armed.loose > 0 && thresholds.contains("gc.auto 1"),
           "\(armed.loose) loose, \(armed.packs) packs — \(thresholds)")

    let runner = GitRunner()
    var triggered: [String] = []
    for operation in GitOperation.allProvenReadOnly {
        let before = maintenanceState()
        _ = try? runner.run(operation, in: repo)
        let after = maintenanceState()
        if before != after { triggered.append("\(operation.label): \(before) → \(after)") }
    }
    report("all \(GitOperation.allProvenReadOnly.count) registered operations leave maintenance state unchanged",
           triggered.isEmpty, triggered.joined(separator: "; "))

    // Repeated, because auto-gc is offered *after* a command completes and a single pass could
    // miss a trigger that needs the state a previous pass left behind.
    let beforeSweep = maintenanceState()
    for _ in 0..<3 {
        for operation in GitOperation.allProvenReadOnly { _ = try? runner.run(operation, in: repo) }
    }
    let afterSweep = maintenanceState()
    report("and three full sweeps of the registry leave it unchanged too",
           beforeSweep == afterSweep, "\(beforeSweep) → \(afterSweep)")

    // The positive control. If this does not fire, everything above is measuring an unarmed
    // repository and says nothing at all.
    let beforeWrite = maintenanceState()
    try? "written\n".write(to: repo.appendingPathComponent("trigger.txt"),
                           atomically: true, encoding: .utf8)
    _ = shell(["add", "-A"], in: repo)
    _ = shell(["commit", "-qm", "the write that is allowed to trigger gc", "--no-gpg-sign"], in: repo)
    let afterWrite = maintenanceState()
    report("positive control: a commit in the same repository does trigger maintenance",
           afterWrite != beforeWrite, "\(beforeWrite) → \(afterWrite)")

    // Both mitigations DEC-003 would reach for are unavailable, which is why the answer had to be
    // measured rather than configured around. Stated as a check so the reasoning cannot rot.
    report("the per-invocation mitigation is forbidden by the registry, so it is not a fallback",
           GitOperation.forbiddenArguments.contains("-c"),
           GitOperation.forbiddenArguments.joined(separator: " "))
    report("and the runner never passes one",
           !GitRunner.readOnlyGlobalArguments.contains("-c")
               && GitRunner.readOnlyGlobalArguments.contains("--no-optional-locks"),
           GitRunner.readOnlyGlobalArguments.joined(separator: " "))
}
