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

    print("\n=== DEC-069: one directory is one repository, however it is spelled ===")
    do {
        // Which world this machine is in, asked rather than assumed. On a case-sensitive volume the
        // second spelling is a genuinely different directory that does not exist, there is no
        // defect to catch, and the arm passes for that reason instead — which the detail says out
        // loud, because an arm that passes for two different reasons should name the one it used.
        let probe = scratch.appendingPathComponent("CaseProbe")
        try? fm.createDirectory(at: probe, withIntermediateDirectories: true)
        let insensitive = fm.fileExists(atPath: scratch.appendingPathComponent("caseprobe").path)

        let root = scratch.appendingPathComponent("CaseRoot")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        _ = makeRepository("web", in: root)
        let lowered = scratch.appendingPathComponent("caseroot")

        let discovery = RepositoryDiscovery(maximumDepth: 2)
        let both = discovery.discover(sources: [
            ConfiguredSource(kind: .root, path: root.path).discoverySource,
            ConfiguredSource(kind: .root, path: lowered.path).discoverySource,
        ])
        // DEC-037 put roots and individually added repositories in the same list, which is what
        // makes this easy to reach: the same directory named twice, once per source. Two rows means
        // two watchers and two sweeps over one working tree, and a reader editing in one row while
        // the other goes stale.
        report("two spellings of one root list the repository once",
               both.repositories.count == 1,
               "\(both.repositories.count) on a case-\(insensitive ? "insensitive" : "sensitive") volume")

        let mixed = discovery.discover(sources: [
            ConfiguredSource(kind: .root, path: root.path).discoverySource,
            ConfiguredSource(kind: .repository,
                             path: lowered.appendingPathComponent("web").path).discoverySource,
        ])
        report("and a root plus the same repository added individually is still one",
               mixed.repositories.count == 1, "\(mixed.repositories.count)")

        // The configuration half. `removeSource` asks which configured source a selected repository
        // came from, and a source the user typed in one case cannot be removed if discovery
        // reported another.
        let source = ConfiguredSource(kind: .root, path: lowered.path)
        report("a source matches the repository it produced, whatever the spelling",
               source.contains(repositoryPath: root.appendingPathComponent("web").path),
               "\(lowered.path) vs \(root.path)/web")

        // A path with no inode still has to have an identity: DEC-052 keeps missing sources rather
        // than dropping them, so identity cannot depend on the file being there.
        let absent = scratch.appendingPathComponent("Gone/Away").path
        report("a path that does not exist still has a decidable identity",
               PathIdentity.of(absent) == PathIdentity.of(absent.lowercased()),
               PathIdentity.of(absent))

        // The control. Everything above would also pass if the two spellings were secretly the same
        // string — so this asserts they are not, which is what makes the deduplication above an
        // observation rather than a tautology. Before DEC-069 these two produced two rows.
        let asStrings = Set([root.appendingPathComponent("web").path,
                             lowered.appendingPathComponent("web").path])
        report("control: as strings the two spellings are two different paths",
               asStrings.count == 2, asStrings.sorted().joined(separator: " · "))
        report("and the identity of one of them is not a path at all",
               !PathIdentity.of(root.appendingPathComponent("web").path).hasPrefix("/"),
               PathIdentity.of(root.appendingPathComponent("web").path))
    }

    print("\n=== the assumption the NFC half rests on, asserted rather than believed ===")
    do {
        // M6-C: this project has already been wrong about Swift's comparison semantics once, in the
        // other direction — `String ==` is canonical equivalence, so an NFC test written the
        // obvious way is always false and the detector silently detected nothing. Here the same
        // semantics are load-bearing in the opposite sense: they are the whole reason OQ-054's
        // normalisation half needs no code. If a future Swift changes it, this says so.
        let nfc = "\u{017C}abka"
        let nfd = "z\u{0307}abka"
        report("String == is canonical equivalence, so NFC and NFD compare equal", nfc == nfd)
        report("and hasPrefix agrees with it", (nfc + "/pkg").hasPrefix(nfd))
        report("and so does Set membership, which is what a visited-set depends on",
               Set([nfc]).contains(nfd))
        // The control: the two really are different bytes, so the equality above is a property of
        // the comparison and not of the inputs being secretly identical.
        report("while the bytes themselves differ, which is what makes that a property of ==",
               Array(nfc.utf8) != Array(nfd.utf8))
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

/// DEC-033 as amended (2026-07-31): the file list groups by workspace package where one is
/// declared, and by parent directory otherwise — because **no repository in this corpus declares
/// one**, so the specified grouping would have produced a single meaningless header.
func runFileListChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    func file(_ path: String) -> ChangedFile {
        ChangedFile(path: path, originalPath: nil, kind: .modified)
    }

    print("\n=== the file list groups by what actually groups it (DEC-033) ===")
    do {
        // The shape measured in `philips__signify-wiz-euro__preact`: twenty files under a handful
        // of directories, no workspace packages anywhere in sight.
        let files = [
            "src/components/features/Boxes/Expanded/ExpandedSection1.tsx",
            "src/components/features/Boxes/Expanded/ExpandedSection2.tsx",
            "src/components/features/Boxes/Expanded/ExpandedSection3.tsx",
            "src/scripts/boxes.ts", "src/scripts/header.ts", "src/scripts/video.ts",
        ].map(file)
        let rows = fileListRows(files)
        let headers = rows.compactMap { if case let .header(h) = $0 { return h } else { return nil } }
        report("directories become the groups when no workspace is declared",
               headers == ["src/components/features/Boxes/Expanded", "src/scripts"],
               headers.joined(separator: " | "))
        report("every file still appears exactly once",
               rows.compactMap(\.file).count == files.count)
        report("headers are not files, so navigation can skip them",
               rows.filter { $0.file == nil }.count == 2)
        // The header already says the directory; repeating it on every row spends the width that
        // middle elision existed to save.
        report("a grouped row shows the path relative to its group",
               rows.compactMap { if case let .file(_, display) = $0 { return display } else { return nil } }
                   .contains("ExpandedSection1.tsx"),
               rows.compactMap { if case let .file(_, d) = $0 { return d } else { return nil } }.joined(separator: " "))
        report("an ungrouped row still shows its whole path",
               fileListRows(["a/one.ts", "b/two.ts", "c/three.ts"].map(file))
                   .allSatisfy { $0.display.contains("/") })
    }

    print("\n=== grouping that would not group is not applied ===")
    do {
        // One file per directory: headers would double the list and separate nothing.
        let scattered = ["a/one.ts", "b/two.ts", "c/three.ts"].map(file)
        report("a list with one file per directory stays flat",
               fileListRows(scattered).allSatisfy { $0.file != nil })

        // Everything in one directory: a single header says nothing the repository name did not.
        let together = ["src/a.ts", "src/b.ts", "src/c.ts"].map(file)
        report("a list with a single group stays flat",
               fileListRows(together).allSatisfy { $0.file != nil })

        report("an empty list produces no rows", fileListRows([]).isEmpty)
    }

    print("\n=== a declared workspace package wins over the directory ===")
    do {
        let files = ["packages/ui/src/Button.tsx", "packages/ui/src/Card.tsx",
                     "packages/api/index.ts", "packages/api/routes.ts"].map(file)
        let rows = fileListRows(files, workspacePackages: ["packages/ui", "packages/api"])
        let headers = rows.compactMap { if case let .header(h) = $0 { return h } else { return nil } }
        report("files group under their package, not their directory",
               headers == ["packages/api", "packages/ui"], headers.joined(separator: " | "))
        report("the deepest matching package wins",
               groupKey(for: "packages/ui/nested/x.ts",
                        workspacePackages: ["packages", "packages/ui"]) == "packages/ui")
        report("a file at the repository root gets a named bucket, not an empty one",
               groupKey(for: "README.md", workspacePackages: []) == "(repository root)")
    }

    print("\n=== pnpm-workspace.yaml is read for packages, and nothing else ===")
    do {
        let fm = FileManager.default
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diffscope-ws-\(UUID().uuidString)")
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // Exactly the file every repository in this corpus has: no `packages:` key at all.
        try? "onlyBuiltDependencies:\n  - '@tailwindcss/oxide'\n  - esbuild\n"
            .write(to: scratch.appendingPathComponent("pnpm-workspace.yaml"),
                   atomically: true, encoding: .utf8)
        report("build-tool entries are never mistaken for packages",
               declaredWorkspacePackages(in: scratch).isEmpty,
               declaredWorkspacePackages(in: scratch).joined(separator: ", "))

        try? "packages:\n  - 'packages/*'\n  - 'apps/**'\nonlyBuiltDependencies:\n  - esbuild\n"
            .write(to: scratch.appendingPathComponent("pnpm-workspace.yaml"),
                   atomically: true, encoding: .utf8)
        report("declared packages are read, and the key after them ends the list",
               declaredWorkspacePackages(in: scratch) == ["apps", "packages"],
               declaredWorkspacePackages(in: scratch).joined(separator: ", "))

        try? #"{"workspaces":["libs/*"]}"#
            .write(to: scratch.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        report("npm-style workspaces in package.json are read too",
               declaredWorkspacePackages(in: scratch).contains("libs"))
    }

    print("\n=== the list says only what it can know cheaply (12-… §4) ===")
    do {
        let fm = FileManager.default
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diffscope-annot-\(UUID().uuidString)")
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        try? "const a = 1;\n".write(to: scratch.appendingPathComponent("a.ts"),
                                    atomically: true, encoding: .utf8)
        try? ".a { color: red }\n".write(to: scratch.appendingPathComponent("a.css"),
                                         atomically: true, encoding: .utf8)
        try? Data([0x89, 0x50, 0x00, 0x4E]).write(to: scratch.appendingPathComponent("logo.ts"))
        try? Data(repeating: 0x61, count: 64).write(to: scratch.appendingPathComponent("big.ts"))

        report("an ordinary source file gets no badge",
               annotate(path: "a.ts", in: scratch, sizeLimit: 1024) == nil)
        report("an unsupported extension is named", annotate(path: "a.css", in: scratch, sizeLimit: 1024) == .unsupported)
        report("a NUL in the first bytes is decisive, so it can be read from a prefix",
               annotate(path: "logo.ts", in: scratch, sizeLimit: 1024) == .binary)
        report("size comes from a stat, not a read",
               annotate(path: "big.ts", in: scratch, sizeLimit: 32) == .oversized)
        report("a file that no longer exists is not invented into a badge",
               annotate(path: "gone.ts", in: scratch, sizeLimit: 1024) == nil)
    }
}

/// The remaining items of `23b-spec-vs-app-audit.md` §1: the base-branch override (DEC-009), the
/// staleness wording (DEC-010/DEC-011), and configuration that predates a field.
func runScopeChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    print("\n=== the base branch is overridable, and the override survives (DEC-009) ===")
    do {
        let fm = FileManager.default
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diffscope-base-\(UUID().uuidString)")
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let store = ConfigurationStore(url: scratch.appendingPathComponent("config.json"))
        var configuration = Configuration(sources: [ConfiguredSource(kind: .root, path: "/tmp/x")])
        configuration.baseOverrides["/tmp/x/repo"] = "origin/develop"
        store.save(configuration)
        report("an override is written and read back",
               store.load().configuration.baseOverrides["/tmp/x/repo"] == "origin/develop")
        report("and it travels beside the sources rather than instead of them",
               store.load().configuration.sources.count == 1)

        // A configuration written before overrides existed must still load. Losing the user's roots
        // to a schema change would be the same defect as losing them to a corrupt file.
        try? #"{"sources":[{"kind":"root","path":"/tmp/y"}]}"#
            .write(to: store.url, atomically: true, encoding: .utf8)
        let old = store.load()
        report("a configuration file without the overrides key still loads",
               old.problem == nil && old.configuration.sources.count == 1,
               String(describing: old))
        report("and gets an empty override table rather than a failure",
               old.configuration.baseOverrides.isEmpty)

        // The override the repository layer already accepted, now actually reachable.
        let runner = GitRunner()
        let repo = makeRepository("based", in: scratch)
        try? "x\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        shell(["add", "-A"], in: repo)
        shell(["commit", "-qm", "c1"], in: repo)
        shell(["branch", "release"], in: repo)
        let reader = RepositoryReader(runner: runner)
        let overridden = try? reader.snapshot(of: repo, baseOverride: "release")
        report("a snapshot taken with an override reports that ref",
               overridden?.baseRefUsed == "release", overridden?.baseRefUsed ?? "nil")
        let detected = try? reader.snapshot(of: repo)
        report("and without one it goes back to detection",
               detected?.baseRefUsed != "release" || detected?.base.ref == nil,
               detected?.baseRefUsed ?? "nil")
    }

    print("\n=== the editor command is configuration, not a constant (DEC-015, 12-… §10) ===")
    do {
        let fm = FileManager.default
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diffscope-editor-\(UUID().uuidString)")
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let store = ConfigurationStore(url: scratch.appendingPathComponent("config.json"))
        var configuration = Configuration(sources: [ConfiguredSource(kind: .root, path: "/tmp/x")])
        configuration.editorTemplate = "/usr/local/bin/code --goto {file}:{line}"
        store.save(configuration)
        report("a chosen editor command is written and read back",
               store.load().configuration.editorTemplate == "/usr/local/bin/code --goto {file}:{line}")
        report("and it travels beside the sources",
               store.load().configuration.sources.count == 1)

        // Absent means *the default*, not an empty command. A file written before this setting
        // existed is an older file, not a broken one — the same rule the overrides follow.
        try? #"{"sources":[]}"#.write(to: store.url, atomically: true, encoding: .utf8)
        report("a configuration written before the setting existed still loads",
               store.load().configuration.editorTemplate == nil)

        let shell = (try? String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                                     .appendingPathComponent("Sources/diffscope-app/main.swift"),
                                 encoding: .utf8)) ?? ""
        // Order matters and is stated in one place: the environment overrides for the F13 arm,
        // then the user's setting, then the built-in default.
        report("the shell resolves the template from the configuration, not only the environment",
               shell.contains("state.configuration.editorTemplate"))
        report("and the default is still the fallback rather than an empty command",
               shell.contains("?? EditorCommand.defaultTemplate"))
        report("the last attempt is kept, so Preferences can show a failure the status line has lost",
               shell.contains("lastEditorAttempt"))
    }

    print("\n=== a stranger's first run explains itself (G3) ===")
    do {
        let message = noRepositoriesFoundMessage(paths: ["/Users/x/Documents"], depth: 2)
        report("the folders that were searched are named", message.contains("/Users/x/Documents"))
        // The likeliest reason a repository is missing, stated where it is discovered rather than
        // left in a document the tester does not have open.
        report("the depth limit is stated, since it is the usual reason nothing was found",
               message.contains("2 folders deep"), message)
        report("and the way round it is offered", message.contains("Add Repository"))
        report("the depth quoted is the one actually used, not a number typed into a sentence",
               noRepositoriesFoundMessage(paths: [], depth: 3).contains("3 folders deep"))
    }

    print("\n=== staleness is stated in words, not in a date (DEC-010, DEC-011) ===")
    do {
        let now = Date()
        func ago(_ days: Int) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.string(from: now.addingTimeInterval(-Double(days) * 86_400))
        }
        report("today reads as today", stalenessDescription(of: ago(0), now: now) == "today")
        report("one day is singular", stalenessDescription(of: ago(1), now: now) == "1 day old")
        report("under a fortnight counts days", stalenessDescription(of: ago(5), now: now) == "5 days old")
        // The figure `12-…` §3 uses as its example.
        report("nine weeks reads as weeks", stalenessDescription(of: ago(63), now: now) == "9 weeks old",
               stalenessDescription(of: ago(63), now: now) ?? "nil")
        report("months for a stale branch", stalenessDescription(of: ago(200), now: now) == "6 months old",
               stalenessDescription(of: ago(200), now: now) ?? "nil")
        report("years for an abandoned one", stalenessDescription(of: ago(800), now: now) == "2 years old",
               stalenessDescription(of: ago(800), now: now) ?? "nil")
        report("an unknown date says nothing rather than guessing",
               stalenessDescription(of: nil) == nil && stalenessDescription(of: "not a date") == nil)
        report("a clock skew is stated, not shown as negative",
               stalenessDescription(of: ago(-3), now: now) == "dated in the future")

        // The phrase matters as much as the number: "last fetched" is what a reader wants to know
        // and what this cannot tell them, so the words say which of the two they are getting.
        report("the scope-4 line names the ref and the age of its newest commit",
               baseSummary(ref: "origin/master", chosenByUser: false, committerDate: ago(63), now: now)
                   == "base origin/master · newest commit 9 weeks old",
               baseSummary(ref: "origin/master", chosenByUser: false, committerDate: ago(63), now: now))
        report("a ref the user chose says so",
               baseSummary(ref: "release", chosenByUser: true, committerDate: ago(1), now: now)
                   == "base release (yours) · newest commit 1 day old")
        // DEC-013's rule reaching one more corner: unknown is said, never substituted.
        report("an unknown age is said, not passed off as fresh",
               baseSummary(ref: "origin/main", chosenByUser: false, committerDate: nil, now: now)
                   == "base origin/main · newest-commit age unknown")
        // The base row is one row and says one of two things: for scope 4 the ref and its age, and
        // otherwise which two sides are being compared. Both are composed where they can be
        // checked rather than assembled in the window.
        report("each scope names its two sides",
               ComparisonScope.allLocalVsHead.comparisonDescription == "HEAD ↔ working tree"
                   && ComparisonScope.unstagedVsIndex.comparisonDescription == "index ↔ working tree"
                   && ComparisonScope.stagedVsHead.comparisonDescription == "HEAD ↔ index")
        report("and no two scopes describe the same comparison",
               Set(ComparisonScope.allCases.map(\.comparisonDescription)).count
                   == ComparisonScope.allCases.count)
        let shell = (try? String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                                     .appendingPathComponent("Sources/diffscope-app/main.swift"),
                                 encoding: .utf8)) ?? ""
        // The intent is unchanged and the surface moved (DEC-072): the base must be **displayed**,
        // not folded into the status line and not left in a tooltip. It is a block in the scope row
        // now, so that is what this asks about — restated rather than loosened, which is the rule
        // for a check whose subject has changed.
        report("what the scope compares is drawn beside the control, not folded into the status line",
               shell.contains("comparisonLabel.stringValue"))
        report("and the base is a block in the scope row, drawn from one composition",
               shell.contains("baseBlock.show(ChromeLabels.baseBlock(")
                   && shell.contains("detail: detail"))

        report("an unresolved base points at the way to fix it",
               baseSummary(ref: nil, chosenByUser: false, committerDate: nil, now: now)
                   .contains("choose one"))
    }
}

/// DEC-062: search within the changed set. The engine half — the interface's half is a field and a
/// list, and neither can be checked headlessly.
func runSearchChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    print("\n=== search finds what is there, and says which question it answered (DEC-062) ===")
    let files = [
        (path: "packages/web/src/results/ResultsList.tsx",
         text: "import { useSelection } from './useSelection';\nconst handle = useSelection(query);\n"),
        (path: "packages/ui/src/list/List.tsx",
         text: "export const List = () => null;\n// useselection is mentioned in lower case here\n"),
    ]

    let hits = search(query: "useSelection", in: files).hits
    // Four, not three: the import line carries the symbol and the module path, and the second
    // file mentions it in lower case. Writing the expectation down first got this wrong, which is
    // the argument for having the check rather than reasoning about the string.
    report("every occurrence is found, including two on one line and one in another file",
           hits.count == 4, "\(hits.count)")
    report("line numbers are 1-based, as an editor and a reader both expect",
           hits.first?.line == 1 && hits.last?.line == 2)
    report("a hit carries the line split around it, so the mark and the search agree",
           hits.first?.before == "import { " && hits.first?.match == "useSelection"
               && hits.first?.after == " } from './useSelection';")

    report("case is ignored by default",
           search(query: "USESELECTION", in: files).hits.count == 4)
    report("and respected when asked",
           search(query: "USESELECTION", in: files, options: SearchOptions(matchCase: true)).hits.isEmpty)

    // Two occurrences on one line, and the second must not be swallowed by the first.
    let twice = [(path: "a.ts", text: "aa\n")]
    report("two matches on one line are two hits", search(query: "a", in: twice).hits.count == 2)

    let capped = search(query: "a", in: twice, options: SearchOptions(limit: 1))
    report("the limit stops the search and says so", capped.hits.count == 1 && capped.truncated)
    report("and a search that was not capped does not claim to be",
           !search(query: "a", in: twice).truncated)

    report("an empty query searches nothing rather than matching everything",
           search(query: "", in: files).hits.isEmpty)
    report("negative control: a query that is not there finds nothing",
           search(query: "notInAnyFile", in: files).hits.isEmpty)

    // The scope is part of the answer, not decoration: the same count means different things over
    // the changed set and over the worktree.
    report("the summary names the scope it searched",
           searchSummary(query: "useSelection", result: search(query: "useSelection", in: files),
                         scope: .changedFiles).contains("changed files"))
    report("and says so when nothing matched, with the scope again",
           searchSummary(query: "zzz", result: search(query: "zzz", in: files), scope: .wholeWorktree)
               == "no matches for “zzz” in 2 whole worktree")
    // The field is the interface (DEC-062, the adopted design): a modal that asks for a query and
    // disappears cannot show the reader which scope answered them, and the scope is half the
    // answer.
    let shell = (try? String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                                 .appendingPathComponent("Sources/diffscope-app/main.swift"),
                             encoding: .utf8)) ?? ""
    // `SearchField` since DEC-088 — an `NSSearchField` subclass whose only job is to install a cell
    // that lays the text out beside the magnifier rather than under it. Still a field in the
    // window, which is the whole of what this asserts.
    report("search is a field in the window rather than a modal",
           shell.contains("searchField = SearchField()") && !shell.contains("prompt.messageText = \"Find"))
    report("and the field says which scope it will answer for",
           shell.contains("searchField.placeholderString = \"Find in \\(scope.title)\""))
    report("an empty query is the way back to the file list, not an empty result",
           shell.contains("// An empty field is not an empty result"))

    report("a capped result says there are more rather than showing a prefix silently",
           searchSummary(query: "a", result: capped, scope: .changedFiles).contains("there are more"))
}

/// DEC-061: the two lenses. Parsers only — a lens's interface is a list, and the list is
/// photographed rather than asserted.
func runLensChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    print("\n=== blame and history are parsed, including the cases a repository will not produce on demand (DEC-061) ===")

    // Two blocks and an uncommitted one, in the shape `--porcelain` actually emits: fields appear
    // once per block and the following lines inherit them.
    let blameOutput = """
        4d70b1e9c0a1b2c3d4e5f60718293a4b5c6d7e8f 1 1 2
        author M. Ostrowska
        author-time 1753000000
        author-tz +0200
        summary Add Footer count
        filename src/List.tsx
        \texport function List() {
        4d70b1e9c0a1b2c3d4e5f60718293a4b5c6d7e8f 2 2
        \t  return null;
        0000000000000000000000000000000000000000 3 3 1
        author Not Committed Yet
        author-time 1754000000
        filename src/List.tsx
        \t  // still being written
        """
    let blame = parseBlamePorcelain(blameOutput)
    report("every line comes back, in file order", blame.count == 3 && blame.map(\.line) == [1, 2, 3],
           "\(blame.count)")
    report("a block's second line inherits the author it did not repeat",
           blame.count > 1 && blame[1].author == "M. Ostrowska" && blame[1].sha == blame[0].sha)
    report("the content line keeps its own leading whitespace",
           blame.count > 1 && blame[1].text == "  return null;")
    report("an uncommitted line is recognised by its all-zero sha, not by its author string",
           blame.last?.isUncommitted == true && blame.first?.isUncommitted == false)
    report("and a committed line is not marked uncommitted by accident",
           blame.prefix(2).allSatisfy { !$0.isUncommitted })
    report("author time becomes a date the interface can age",
           blame.first?.committed.hasPrefix("2025-") == true || blame.first?.committed.hasPrefix("2026-") == true,
           blame.first?.committed ?? "none")

    // The separator is the point: a subject can contain anything a person types.
    let logOutput = "a1c93f2\u{1f}you\u{1f}2026-08-09T10:00:00Z\u{1f}Flatten | drop\tPanel\u{1f}HEAD -> main\n"
        + "4d70b1e\u{1f}M. Ostrowska\u{1f}2026-08-06T09:00:00Z\u{1f}Add Footer count\u{1f}\n"
    let commits = parseLog(logOutput)
    report("both commits parse", commits.count == 2)
    report("a subject containing a pipe and a tab survives intact",
           commits.first?.subject == "Flatten | drop\tPanel")
    report("refs are carried where they exist and empty where they do not",
           commits.first?.refs == "HEAD -> main" && commits.last?.refs == "")
    report("the short sha is what a reader quotes", commits.first?.shortSha == "a1c93f2")
    report("negative control: a truncated record is dropped rather than half-read",
           parseLog("only-a-sha\u{1f}and-an-author\n").isEmpty)

    // DEC-010's rule reaching the history list: what is on disk may be weeks behind the remote.
    report("the history header says these are the commits on disk and that nothing is fetched",
           historySummary(commits: commits, branch: "main", ahead: 3)
               == "2 commits on main · 3 ahead of base · as they are on disk; DiffScope never fetches")
    report("an unknown ahead-count is said, not shown as zero",
           historySummary(commits: commits, branch: "main", ahead: nil).contains("unknown"))

    // R-8 covers what the registry lists, so a lens that runs beside it would be outside the proof.
    report("both lens operations are in the registry the read-only proof runs over",
           GitOperation.allProvenReadOnly.contains { $0.label == "blame" }
               && GitOperation.allProvenReadOnly.contains { $0.label == "log" })
}
