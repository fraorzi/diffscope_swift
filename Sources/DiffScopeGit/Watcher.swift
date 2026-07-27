import CoreServices
import Foundation

/// DEC-026: trailing edge, because leading edge can fire inside the window where an atomic
/// replace has unlinked the target and not yet renamed the new file into place — measured, one
/// WebStorm-shaped save produces five events in ~11 ms and the target path is briefly absent.
///
/// The clock is a parameter rather than `Date()` so the shape is checkable without waiting on
/// wall time: a debounce tested by sleeping is a debounce tested once, on one machine.
public struct RefreshDebounce: Sendable {
    /// DEC-007's value. At ~30× the ~25 ms needed to coalesce one save it is not a save
    /// coalescer but a burst quiet-period detector, which is the job that is actually wanted.
    public static let quietPeriod: TimeInterval = 0.4
    /// Required, not optional: without it a file on a tight autosave interval never refreshes.
    public static let maximumDelay: TimeInterval = 2.0

    public let quietPeriod: TimeInterval
    public let maximumDelay: TimeInterval

    private var firstEvent: TimeInterval?
    private var lastEvent: TimeInterval?

    public init(quietPeriod: TimeInterval = RefreshDebounce.quietPeriod,
                maximumDelay: TimeInterval = RefreshDebounce.maximumDelay) {
        self.quietPeriod = quietPeriod
        self.maximumDelay = maximumDelay
    }

    public var isPending: Bool { firstEvent != nil }

    /// The instant this burst should fire, or `nil` while nothing is pending.
    public var deadline: TimeInterval? {
        guard let firstEvent, let lastEvent else { return nil }
        return min(lastEvent + quietPeriod, firstEvent + maximumDelay)
    }

    /// Returns the (possibly moved) deadline. The cap is applied against the *first* event of the
    /// burst, so continuous saving fires on a fixed cadence instead of never.
    @discardableResult
    public mutating func admit(at now: TimeInterval) -> TimeInterval {
        if firstEvent == nil { firstEvent = now }
        lastEvent = now
        return deadline ?? now
    }

    /// True when the burst is due. Clears the burst, so one burst fires exactly once.
    public mutating func fireIfDue(at now: TimeInterval) -> Bool {
        guard let deadline, now >= deadline else { return false }
        firstEvent = nil
        lastEvent = nil
        return true
    }
}

/// What the watcher asks the application to do. `rescan` exists because FSEvents can drop events
/// and says so; the recovery is a full rescan (F15). Measurement found zero drops in 40,000
/// creations, so this arm will not be exercised by ordinary use — hence `deliver(flags:)` below.
public enum WatchSignal: String, Sendable, Equatable {
    case changed
    case rescan
    case rootChanged
}

public struct WatchDiagnostic: Sendable, Equatable {
    public let message: String
}

/// One stream for the currently open repository (DEC-007 narrows watching to it, and DEC-006
/// rejected watching every repository on cost grounds).
///
/// Configuration (i) of `research/git-mechanism-and-watching.md`: `FileEvents | NoDefer |
/// WatchRoot`, **latency 0.0**, with the debounce above in our own code. Configuration (ii)
/// (latency 0.4, `NoDefer` off) coalesces just as well but hides the debounce inside a framework
/// parameter that cannot express a maximum-delay cap. `NoDefer` with a non-zero latency is the
/// measured worst case — it splits one save across two callbacks separated by the full latency.
public final class RepositoryWatcher {
    /// Verbatim from the local SDK header, and a hard ceiling rather than a soft one.
    public static let exclusionLimit = 8

    public let root: URL
    public private(set) var exclusions: [String] = []
    public private(set) var diagnostics: [WatchDiagnostic] = []

    private let onSignal: (WatchSignal) -> Void
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?
    private var debounce = RefreshDebounce()
    private var timer: DispatchSourceTimer?

    public init(root: URL, queue: DispatchQueue = .main, onSignal: @escaping (WatchSignal) -> Void) {
        self.root = root
        self.queue = queue
        self.onSignal = onSignal
    }

    deinit { stop() }

    /// DEC-027: `node_modules` is 93% of watched paths in the largest corpus repository. The
    /// exclusion is a CPU concern, not a correctness one — a change Git tracks inside
    /// `node_modules` is still a real change, and this only narrows what is *watched*.
    public static func nodeModulesDirectories(under root: URL, maximumDepth: Int = 3) -> [String] {
        var found: [String] = []
        var frontier = [(url: root, depth: 0)]
        let fm = FileManager.default
        while let (url, depth) = frontier.popLast() {
            guard depth < maximumDepth else { continue }
            let entries = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])) ?? []
            for entry in entries {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                if entry.lastPathComponent == "node_modules" {
                    found.append(entry.path)
                } else {
                    frontier.append((entry, depth + 1))
                }
            }
        }
        return found.sorted()
    }

    @discardableResult
    public func start() -> Bool {
        stop()

        let candidates = RepositoryWatcher.nodeModulesDirectories(under: root)
        exclusions = Array(candidates.prefix(RepositoryWatcher.exclusionLimit))
        if candidates.count > RepositoryWatcher.exclusionLimit {
            // DEC-027 names silent truncation as the thing to avoid: the remaining directories
            // stay watched, which costs CPU, and the cost is stated rather than discovered.
            diagnostics.append(WatchDiagnostic(
                message: "\(candidates.count) node_modules directories, but FSEvents excludes at most "
                    + "\(RepositoryWatcher.exclusionLimit) — \(candidates.count - RepositoryWatcher.exclusionLimit) stay watched"
            ))
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, _, eventFlags, _ in
                guard let info else { return }
                let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
                var combined: FSEventStreamEventFlags = 0
                for index in 0..<count { combined |= eventFlags[index] }
                watcher.deliver(flags: combined)
            },
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.0,
            flags
        ) else {
            diagnostics.append(WatchDiagnostic(message: "could not create a file-system stream for \(root.path)"))
            return false
        }

        if !exclusions.isEmpty {
            FSEventStreamSetExclusionPaths(created, exclusions as CFArray)
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            diagnostics.append(WatchDiagnostic(message: "file-system stream refused to start for \(root.path)"))
            return false
        }
        stream = created
        return true
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        debounce = RefreshDebounce()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// The callback body, separated so the drop and root-changed arms can be exercised
    /// deliberately (F15). A path that cannot be triggered locally will otherwise ship untested.
    public func deliver(flags: FSEventStreamEventFlags, now: TimeInterval = Date().timeIntervalSince1970) {
        let dropped = flags & UInt32(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
        )
        if dropped != 0 {
            // A drop means the event list is incomplete, so a debounced "something changed" would
            // understate it: the whole repository has to be re-read.
            cancelPending()
            queue.async { self.onSignal(.rescan) }
            return
        }
        if flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
            cancelPending()
            queue.async { self.onSignal(.rootChanged) }
            return
        }
        schedule(admitting: now)
    }

    private func cancelPending() {
        timer?.cancel()
        timer = nil
        debounce = RefreshDebounce()
    }

    private func schedule(admitting now: TimeInterval) {
        let deadline = debounce.admit(at: now)
        arm(after: max(0, deadline - now))
    }

    private func arm(after interval: TimeInterval) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            guard self.debounce.fireIfDue(at: now) else {
                // A one-shot timer that wakes a hair early would otherwise swallow the burst.
                guard let deadline = self.debounce.deadline else { return }
                self.arm(after: max(0.005, deadline - now))
                return
            }
            self.timer = nil
            self.onSignal(.changed)
        }
        timer.resume()
        self.timer = timer
    }
}
