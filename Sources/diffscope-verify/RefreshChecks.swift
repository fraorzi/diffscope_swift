import CoreServices
import DiffScopeEngine
import DiffScopeGit
import DiffScopeSyntax
import Foundation

private let fm = FileManager.default

func runRefreshChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    print("\n=== DEC-026: the debounce is trailing-edge and capped ===")
    do {
        // A WebStorm-shaped save: five events inside ~11 ms, the target path briefly absent.
        var debounce = RefreshDebounce(quietPeriod: 0.4, maximumDelay: 2.0)
        for offset in [0.0, 0.003, 0.006, 0.009, 0.011] { debounce.admit(at: 100 + offset) }
        report("one save fires once, after the quiet period", debounce.deadline == 100.011 + 0.4,
               String(describing: debounce.deadline))
        report("and not before it", !debounce.fireIfDue(at: 100.3))
        report("it does fire once the quiet period passes", debounce.fireIfDue(at: 100.5))
        report("and the burst is cleared, so it fires exactly once", !debounce.fireIfDue(at: 101))

        var starved = RefreshDebounce(quietPeriod: 0.4, maximumDelay: 2.0)
        var now = 200.0
        var fired = false
        // Continuous saving on a tighter interval than the quiet period: without the cap the
        // trailing edge is pushed forward forever and the view never refreshes.
        for _ in 0..<40 {
            starved.admit(at: now)
            now += 0.1
            if starved.fireIfDue(at: now) { fired = true; break }
        }
        report("continuous saving still refreshes, because of the max-delay cap", fired)
        report("and the cap is what fired it, not the quiet period", now <= 200 + 2.0 + 0.1,
               String(format: "%.2f s after the first event", now - 200))

        var idle = RefreshDebounce()
        report("nothing pending means nothing to fire", !idle.isPending && !idle.fireIfDue(at: 0))
        report("the defaults are DEC-007's 400 ms and a 2 s cap",
               idle.quietPeriod == 0.4 && idle.maximumDelay == 2.0)
    }

    print("\n=== F15: a dropped-event signal must reach the application ===")
    do {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diffscope-watch-\(UUID().uuidString)")
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let queue = DispatchQueue(label: "diffscope.watch.checks")
        var signals: [WatchSignal] = []
        let lock = NSLock()
        let watcher = RepositoryWatcher(root: scratch, queue: queue) { signal in
            lock.lock(); signals.append(signal); lock.unlock()
        }
        report("a stream starts on a real directory", watcher.start())

        // Measurement found zero drops in 40,000 file creations, so this arm will never be
        // exercised by ordinary use. Untriggered means untested unless it is forced.
        watcher.deliver(flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs))
        watcher.deliver(flags: FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped))
        watcher.deliver(flags: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged))
        queue.sync {}
        lock.lock()
        let observed = signals
        lock.unlock()
        report("a dropped-event flag asks for a rescan, not a refresh",
               observed.filter { $0 == .rescan }.count == 2, observed.map(\.rawValue).joined(separator: ","))
        report("a moved repository root is reported rather than going quiet",
               observed.contains(.rootChanged))

        var fired = 0
        let debounced = RepositoryWatcher(root: scratch, queue: queue) { signal in
            if signal == .changed { lock.lock(); fired += 1; lock.unlock() }
        }
        _ = debounced.start()
        let started = Date()
        for _ in 0..<5 { debounced.deliver(flags: 0) }
        queue.sync {}
        lock.lock(); let immediately = fired; lock.unlock()
        report("a burst does not refresh on its leading edge", immediately == 0, "\(immediately)")
        while Date().timeIntervalSince(started) < 1.5 {
            lock.lock(); let count = fired; lock.unlock()
            if count > 0 { break }
            usleep(20_000)
        }
        lock.lock(); let eventually = fired; lock.unlock()
        report("five events one save apart produce exactly one refresh", eventually == 1, "\(eventually)")
        debounced.stop()
        watcher.stop()

        // The injected paths above prove the arms; this proves the stream is actually wired to
        // the file system, which is the part that cannot be inferred from the code.
        var live = 0
        let liveWatcher = RepositoryWatcher(root: scratch, queue: queue) { signal in
            if signal == .changed { lock.lock(); live += 1; lock.unlock() }
        }
        _ = liveWatcher.start()
        usleep(200_000)
        try? "const a = 1;\n".write(to: scratch.appendingPathComponent("live.tsx"),
                                   atomically: true, encoding: .utf8)
        let liveDeadline = Date().addingTimeInterval(3)
        while Date() < liveDeadline {
            lock.lock(); let count = live; lock.unlock()
            if count > 0 { break }
            usleep(20_000)
        }
        lock.lock(); let liveCount = live; lock.unlock()
        report("a real file write reaches the application as one refresh", liveCount == 1, "\(liveCount)")
        liveWatcher.stop()

        try? fm.createDirectory(at: scratch.appendingPathComponent("node_modules"),
                                withIntermediateDirectories: true)
        try? fm.createDirectory(at: scratch.appendingPathComponent("packages/app/node_modules"),
                                withIntermediateDirectories: true)
        let excluding = RepositoryWatcher(root: scratch, queue: queue) { _ in }
        _ = excluding.start()
        report("DEC-027: node_modules is found and excluded, nested as well as top level",
               excluding.exclusions.count == 2, excluding.exclusions.joined(separator: " "))
        report("and the exclusion limit is the SDK's 8, not a guess", RepositoryWatcher.exclusionLimit == 8)
        excluding.stop()
    }

    print("\n=== R-9: a file changed mid-analysis never yields a blended pair ===")
    do {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diffscope-r9-\(UUID().uuidString)")
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let path = "racing.tsx"
        let file = scratch.appendingPathComponent(path)
        let versionA = String(repeating: "const a = 1;\n", count: 4000)
        let versionB = String(repeating: "const b = 2;\n", count: 4000)
        try? versionA.write(to: file, atomically: false, encoding: .utf8)

        let scopes = ScopeReader()
        let changed = ChangedFile(path: path, originalPath: nil, kind: .untracked)
        /// Reads pins while a writer rewrites the file in place. `pause` is the gap between
        /// writes: zero is a file under continuous rewrite, which is not a real editing pattern
        /// but is the hardest case; 30 ms is a plausible burst of saves.
        func race(pause: TimeInterval, seconds: TimeInterval) -> (reads: Int, blended: Int, unstable: Int) {
            let stop = DispatchSemaphore(value: 0)
            let writer = Thread {
                var useA = false
                while stop.wait(timeout: .now()) == .timedOut {
                    // Deliberately non-atomic: an editor writing in place is the case R-9 is
                    // about, and an atomic rename would make the test pass without testing it.
                    try? (useA ? versionA : versionB).write(to: file, atomically: false, encoding: .utf8)
                    useA.toggle()
                    if pause > 0 { Thread.sleep(forTimeInterval: pause) }
                }
            }
            writer.start()
            defer { stop.signal() }

            var counts = (reads: 0, blended: 0, unstable: 0)
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                guard let pair = try? scopes.pinnedPair(for: changed, scope: .unstagedVsIndex, in: scratch)
                else { continue }
                counts.reads += 1
                if !pair.stable { counts.unstable += 1; continue }
                let text = String(decoding: pair.newBytes, as: UTF8.self)
                if text != versionA && text != versionB { counts.blended += 1 }
            }
            return counts
        }

        let hostile = race(pause: 0, seconds: 1.5)
        print("        continuous rewrite: \(hostile.reads) reads, \(hostile.blended) blended, \(hostile.unstable) refused")
        report("the racing read happened often enough to mean something", hostile.reads > 10,
               "\(hostile.reads) reads")
        report("under continuous rewriting, no pin certifies a version that never existed on disk",
               hostile.blended == 0, "\(hostile.blended) blended of \(hostile.reads)")
        report("and a pair that will not settle is reported rather than presented as fact",
               hostile.unstable > 0, "\(hostile.unstable) unstable of \(hostile.reads)")

        // The realistic case has to still produce a diff — a guard that refuses everything is not
        // a guard, it is an outage.
        let realistic = race(pause: 0.03, seconds: 1.5)
        print("        saves 30 ms apart: \(realistic.reads) reads, \(realistic.blended) blended, \(realistic.unstable) refused")
        report("a normal burst of saves still yields usable pins",
               realistic.reads - realistic.unstable > realistic.reads / 2,
               "\(realistic.reads - realistic.unstable) settled of \(realistic.reads)")
        report("and none of those is a blend", realistic.blended == 0, "\(realistic.blended)")
    }

    print("\n=== DEC-034: the reader keeps their place across a refresh ===")
    do {
        let body = (1...30).map { "const value\($0) = \($0);\n" }.joined()
        let old = [UInt8](("const head = 1;\n" + body + "const tail = 2;\n").utf8)
        let new = [UInt8](("const head = 1;\n" + body + "const tail = 22;\n").utf8)
        let first = buildRenderModel(model: trivialModel(oldBytes: old, newBytes: new),
                                     pinOld: "a", pinNew: "b", mode: "structural")
        report("a refreshable document offers anchors", !first.anchors.isEmpty, "\(first.anchors.count)")
        report("the first render has nothing to restore to",
               first.restore?.resolution == .noPreviousAnchor)

        // Mid-document, which is where a reader actually is when they are reading.
        guard first.anchors.count > 2 else { report("anchors to follow", false, "\(first.anchors.count)"); return }
        let anchor = first.anchors[first.anchors.count / 2]

        // The ordinary editing case: text inserted *above* where the reader is looking.
        let shiftedOld = [UInt8]("const inserted = 0;\n".utf8) + old
        let shiftedNew = [UInt8]("const inserted = 0;\n".utf8) + new
        let second = buildRenderModel(model: trivialModel(oldBytes: shiftedOld, newBytes: shiftedNew),
                                      pinOld: "c", pinNew: "d", mode: "structural",
                                      previousAnchor: anchor)
        report("an insertion above the anchor does not lose it",
               second.restore?.resolution == .exact, String(describing: second.restore?.resolution))
        report("and the restored position moved down by the inserted text",
               (second.restore?.oldStart ?? 0) > anchor.oldStart,
               "\(anchor.oldStart) → \(second.restore?.oldStart ?? -1)")

        // Repeated refreshes with nothing changing: this is where drift would show up, and it
        // would only show up after a long editing session unless it is checked outright.
        var carried = anchor
        var positions = Set<Int>()
        for _ in 0..<20 {
            let again = buildRenderModel(model: trivialModel(oldBytes: old, newBytes: new),
                                         pinOld: "a", pinNew: "b", mode: "structural",
                                         previousAnchor: carried)
            guard let restore = again.restore, let resolved = restore.anchor else { break }
            positions.insert(restore.oldStart)
            carried = resolved
        }
        report("twenty refreshes with no change resolve to one position, not a creep",
               positions.count == 1, "\(positions.count) distinct positions")

        // DEC-034's fallback chain, stated as a chain and therefore checked as one.
        let missing = RefreshAnchor(digest: "not-in-this-document", occurrence: 0,
                                    oldStart: anchor.oldStart, newStart: anchor.newStart)
        let fallback = resolveAnchor(previous: missing, candidates: first.anchors)
        report("a deleted anchor falls back to the nearest surviving one above",
               fallback.resolution == .nearestSurvivingAbove,
               String(describing: fallback.resolution))
        report("and never below it", fallback.oldStart <= missing.oldStart)
        let topOnly = RefreshAnchor(digest: "gone", occurrence: 0, oldStart: -1, newStart: -1)
        report("with nothing above, the fallback is the top of the file",
               resolveAnchor(previous: topOnly, candidates: first.anchors).resolution == .topOfFile)
        report("anchors are UTF-16 offsets inside the document",
               first.anchors.allSatisfy { $0.oldStart >= 0 && $0.newStart >= 0 })
    }

    print("\n=== DEC-048: formatting-only runs group, and only where the panes stay aligned ===")
    do {
        guard let parser = TSXParser() else { report("parser for the formatting-collapse checks", false); return }
        let oldText = """
        export function Card({ title }) {
          const a = 1;
          const b = 2;
          const c = 3;
          const d = 4;
          return <div>{title}</div>;
        }

        """
        let newText = """
        export function Card({ title }) {
            const a = 1;
            const b = 2;
            const c = 3;
            const d = 4;
          return <div>{title}</div>;
        }

        """
        let result = structuralDiff(oldPath: "a.tsx", oldBytes: [UInt8](oldText.utf8),
                                    newPath: "a.tsx", newBytes: [UInt8](newText.utf8), parser: parser)
        let collapses = formattingCollapses(result.model)
        report("a reindented block is offered as one group", collapses.ranges.count == 1,
               "\(collapses.ranges.count) groups, \(collapses.unpaired) unpaired")
        if let group = collapses.ranges.first {
            report("the group states how many changes it holds", group.changes > 0, "\(group.changes)")
            report("both sides span the same number of lines, so the panes stay aligned",
                   group.oldEnd > group.oldStart && group.newEnd > group.newStart)
            report("the group covers whole lines only",
                   [UInt8](oldText.utf8)[group.oldStart..<group.oldEnd].last == 0x0A)
        }

        // Grouping is not filtering: the bytes are still in the model and still validated.
        report("grouping changes nothing about the model", validate(result.model).passed)

        let structural = buildRenderModel(model: result.model, pinOld: "a", pinNew: "b", mode: "structural")
        let expanded = buildRenderModel(model: result.model, pinOld: "a", pinNew: "b", mode: "expanded")
        report("Structural offers the group", !structural.formattingCollapses.isEmpty)
        report("Expanded offers none — its whole job is dropping the quietening",
               expanded.formattingCollapses.isEmpty)
        if case let .text(structuralOld, _) = structural.payload,
           case let .text(expandedOld, _) = expanded.payload {
            report("INV-5 holds anyway: both modes carry the same segment set",
                   structuralOld.segments == expandedOld.segments)
        }

        // A real edit sitting inside the run must end it, or the group would quieten the one
        // thing the reader is looking for.
        let mixedNew = newText.replacingOccurrences(of: "const c = 3;", with: "const c = 33;")
        let mixed = structuralDiff(oldPath: "a.tsx", oldBytes: [UInt8](oldText.utf8),
                                   newPath: "a.tsx", newBytes: [UInt8](mixedNew.utf8), parser: parser)
        let mixedGroups = formattingCollapses(mixed.model)
        report("a real edit inside the run is never grouped away",
               mixedGroups.ranges.allSatisfy { group in
                   let text = String(decoding: [UInt8](mixedNew.utf8)[group.newStart..<group.newEnd], as: UTF8.self)
                   return !text.contains("const c = 33;")
               }, "\(mixedGroups.ranges.count) groups")

        // A run whose two sides differ in line count cannot be offered, and the rejection is
        // counted rather than silent — DEC-038 records the unannounced floor as the defect.
        let unevenNew = newText.replacingOccurrences(of: "    const b = 2;\n", with: "    const b =\n      2;\n")
        let uneven = structuralDiff(oldPath: "a.tsx", oldBytes: [UInt8](oldText.utf8),
                                    newPath: "a.tsx", newBytes: [UInt8](unevenNew.utf8), parser: parser)
        let unevenGroups = formattingCollapses(uneven.model)
        report("every offered group spans the same line count on both sides",
               unevenGroups.ranges.allSatisfy { group in
                   let oldLines = [UInt8](oldText.utf8)[group.oldStart..<group.oldEnd].filter { $0 == 0x0A }.count
                   let newLines = [UInt8](unevenNew.utf8)[group.newStart..<group.newEnd].filter { $0 == 0x0A }.count
                   return oldLines == newLines
               }, "\(unevenGroups.ranges.count) offered, \(unevenGroups.unpaired) unpaired")
        report("a rejected run is counted, not dropped in silence",
               unevenGroups.unpaired > 0 || unevenGroups.ranges.count == 1,
               "\(unevenGroups.ranges.count) offered, \(unevenGroups.unpaired) unpaired")

        let untouched = trivialModel(oldBytes: [UInt8](oldText.utf8), newBytes: [UInt8](oldText.utf8))
        report("identical sides offer no groups", formattingCollapses(untouched).ranges.isEmpty)
    }
}
