import DiffScopeGit
import Foundation

/// DEC-052 (where configuration lives) and DEC-036 / DEC-037 (what it holds).
///
/// The interesting cases here are all about *not losing things quietly*: a corrupt file must not be
/// overwritten, a moved root must not disappear from the list, and two repositories with the same
/// folder name must not become indistinguishable.
func runConfigurationChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    let fm = FileManager.default
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("diffscope-config-\(UUID().uuidString)")
    try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: scratch) }

    print("\n=== configuration storage (DEC-052) ===")
    do {
        let store = ConfigurationStore(url: scratch.appendingPathComponent("nested/config.json"))
        // No file yet is the first run, which is a state and not a failure.
        if case .firstRun = store.load() {
            report("a missing configuration file is first run, not an error", true)
        } else {
            report("a missing configuration file is first run, not an error", false,
                   String(describing: store.load()))
        }

        let configuration = Configuration(sources: [
            ConfiguredSource(kind: .root, path: "/tmp/one"),
            ConfiguredSource(kind: .repository, path: "/tmp/two"),
        ])
        report("saving creates the directory it needs", store.save(configuration) == nil)
        report("what was saved is what loads back", store.load().configuration == configuration,
               String(describing: store.load().configuration))

        // The defect this guards: recovering from a bad file by rewriting it destroys the user's
        // configured roots to fix a problem they might have repaired by hand.
        let corrupt = "{ this is not json"
        try? corrupt.write(to: store.url, atomically: true, encoding: .utf8)
        let load = store.load()
        report("a corrupt file is reported rather than treated as empty", load.problem != nil,
               String(describing: load))
        report("and the corrupt file is left exactly as it was",
               (try? String(contentsOf: store.url, encoding: .utf8)) == corrupt)
        report("while the application still starts, with no sources",
               load.configuration.sources.isEmpty)
    }

    print("\n=== sources are inspected, never silently dropped (DEC-036) ===")
    do {
        let store = ConfigurationStore(url: scratch.appendingPathComponent("state.json"))
        let present = makeRepository("present", in: scratch)
        let plain = scratch.appendingPathComponent("plain-folder")
        try? fm.createDirectory(at: plain, withIntermediateDirectories: true)

        let inspected = store.inspect(Configuration(sources: [
            ConfiguredSource(kind: .repository, path: present.path),
            ConfiguredSource(kind: .root, path: scratch.appendingPathComponent("gone").path),
            ConfiguredSource(kind: .repository, path: plain.path),
        ]))
        report("a source that exists reads as present", inspected[0].state == .present)
        report("a moved or deleted source is reported missing, not removed",
               inspected[1].state == .missing && inspected.count == 3,
               String(describing: inspected.map(\.state)))
        report("a folder added as a repository that is not one says so",
               inspected[2].state == .notARepository)
    }

    print("\n=== every configured source is scanned (DEC-037, DEC-018) ===")
    do {
        let rootA = scratch.appendingPathComponent("rootA")
        let rootB = scratch.appendingPathComponent("rootB")
        for root in [rootA, rootB] { try? fm.createDirectory(at: root, withIntermediateDirectories: true) }
        let a1 = makeRepository("alpha", in: rootA)
        let b1 = makeRepository("beta", in: rootB)

        // Deeper than depth 2 from rootA, so scanning can never reach it. This is the case DEC-037
        // says individually added repositories exist to answer.
        let deepParent = rootA.appendingPathComponent("x/y/z")
        try? fm.createDirectory(at: deepParent, withIntermediateDirectories: true)
        let deep = makeRepository("deep", in: deepParent)

        let discovery = RepositoryDiscovery(maximumDepth: 2)
        let roots = discovery.discover(sources: [
            ConfiguredSource(kind: .root, path: rootA.path).discoverySource,
            ConfiguredSource(kind: .root, path: rootB.path).discoverySource,
        ])
        let paths = Set(roots.repositories.map(\.url.path))
        report("two roots merge into one list",
               paths.contains(a1.path) && paths.contains(b1.path), paths.sorted().joined(separator: " "))
        report("and the depth limit applies to each root, so the deep one is missed",
               !paths.contains(deep.path))

        let withIndividual = discovery.discover(sources: [
            ConfiguredSource(kind: .root, path: rootA.path).discoverySource,
            ConfiguredSource(kind: .repository, path: deep.path).discoverySource,
        ])
        report("an individually added repository bypasses scanning entirely",
               withIndividual.repositories.contains { $0.url.path == deep.path })

        let missing = discovery.discover(sources: [
            ConfiguredSource(kind: .root, path: scratch.appendingPathComponent("nope").path).discoverySource,
        ])
        report("a missing source produces a diagnostic rather than silence",
               missing.diagnostics.contains { if case .sourceMissing = $0 { return true }; return false })
    }

    print("\n=== identically named repositories stay distinguishable (DEC-037) ===")
    do {
        let labels = disambiguatedNames(for: [
            "/Users/x/work/website",
            "/Users/x/side/website",
            "/Users/x/work/api",
        ])
        report("a unique name is left alone", labels["/Users/x/work/api"] == "api",
               labels["/Users/x/work/api"] ?? "nil")
        report("a colliding name gains just enough parent to separate it",
               labels["/Users/x/work/website"] == "work/website"
                   && labels["/Users/x/side/website"] == "side/website",
               "\(labels["/Users/x/work/website"] ?? "nil") vs \(labels["/Users/x/side/website"] ?? "nil")")

        let deeper = disambiguatedNames(for: [
            "/a/one/same/website",
            "/b/two/same/website",
        ])
        report("and keeps taking parents until they actually differ",
               Set(deeper.values).count == 2, deeper.values.sorted().joined(separator: " vs "))
        report("every path gets a label", deeper.count == 2 && labels.count == 3)
    }
}
