import Foundation

public struct SweepOutcome: Sendable {
    public let snapshots: [RepositorySnapshot]
    public let failures: [(url: URL, message: String)]
    public let elapsedSeconds: Double
}

public struct RepositorySweep: Sendable {
    public let reader: RepositoryReader
    public let maximumConcurrency: Int

    public init(reader: RepositoryReader = RepositoryReader(), maximumConcurrency: Int = 0) {
        self.reader = reader
        self.maximumConcurrency = maximumConcurrency > 0
            ? maximumConcurrency
            : max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
    }

    public func run(over repositories: [URL], baseOverrides: [String: String] = [:]) -> SweepOutcome {
        let started = Date()
        let lock = NSLock()
        var snapshots: [Int: RepositorySnapshot] = [:]
        var failures: [(URL, String)] = []

        let semaphore = DispatchSemaphore(value: maximumConcurrency)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "diffscope.sweep", attributes: .concurrent)

        for (index, url) in repositories.enumerated() {
            semaphore.wait()
            queue.async(group: group) {
                defer { semaphore.signal() }
                do {
                    let override = baseOverrides[url.standardizedFileURL.path]
                    let snapshot = try reader.snapshot(of: url, baseOverride: override)
                    lock.lock()
                    snapshots[index] = snapshot
                    lock.unlock()
                } catch {
                    lock.lock()
                    failures.append((url, String(describing: error)))
                    lock.unlock()
                }
            }
        }
        group.wait()

        let ordered = repositories.indices.compactMap { snapshots[$0] }
        return SweepOutcome(
            snapshots: ordered,
            failures: failures.map { (url: $0.0, message: $0.1) },
            elapsedSeconds: Date().timeIntervalSince(started)
        )
    }
}
