import Foundation

public struct DiscoverySource: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case root
        case individualRepository
    }

    public let url: URL
    public let kind: Kind

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }
}

public struct DiscoveredRepository: Sendable, Equatable {
    public let url: URL
    public let discoveredVia: URL

    /// DEC-069. The dedupe key, and **not** a path: a repository reached through a root and again
    /// through an individually added source arrives spelled two different ways — different case,
    /// or `/var` against `/private/var` — and two rows for one working tree means two watchers, two
    /// sweeps, and a reader editing in one while the other goes stale.
    ///
    /// Scanning was never the problem: `contentsOfDirectory` hands back the filesystem's own
    /// spelling. An individually added repository is taken verbatim from the configuration, which
    /// is where the two spellings meet (M9-F).
    public var identity: String { PathIdentity.of(url.path) }
    /// What the list is ordered by. `identity` is a device and an inode, and sorting by those would
    /// order the rail by whatever the filesystem happened to allocate.
    public var sortKey: String { url.standardizedFileURL.path }
    public var displayName: String { url.lastPathComponent }
}

public enum DiscoveryDiagnostic: Sendable, Equatable, CustomStringConvertible {
    case sourceMissing(URL)
    case symlinkEscapesRoot(URL)
    case symlinkCycle(URL)
    case notARepository(URL)

    public var description: String {
        switch self {
        case let .sourceMissing(url): return "configured source does not exist: \(url.path)"
        case let .symlinkEscapesRoot(url): return "symlink escapes its root, skipped: \(url.path)"
        case let .symlinkCycle(url): return "symlink cycle, skipped: \(url.path)"
        case let .notARepository(url): return "not a git repository: \(url.path)"
        }
    }
}

public struct DiscoveryResult: Sendable {
    public let repositories: [DiscoveredRepository]
    public let diagnostics: [DiscoveryDiagnostic]
}

public struct RepositoryDiscovery: Sendable {
    public let maximumDepth: Int

    private var fileManager: FileManager { FileManager.default }

    public init(maximumDepth: Int = 2) {
        self.maximumDepth = maximumDepth
    }

    public func isRepository(_ url: URL) -> Bool {
        let dotGit = url.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return false }
        return true
    }

    public func discover(sources: [DiscoverySource]) -> DiscoveryResult {
        var found: [String: DiscoveredRepository] = [:]
        var diagnostics: [DiscoveryDiagnostic] = []

        for source in sources {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.url.path, isDirectory: &isDirectory) else {
                diagnostics.append(.sourceMissing(source.url))
                continue
            }

            switch source.kind {
            case .individualRepository:
                guard isRepository(source.url) else {
                    diagnostics.append(.notARepository(source.url))
                    continue
                }
                let repository = DiscoveredRepository(url: source.url, discoveredVia: source.url)
                found[repository.identity] = repository

            case .root:
                var visited = Set<String>()
                scan(
                    directory: source.url,
                    root: source.url,
                    depth: 0,
                    visited: &visited,
                    found: &found,
                    diagnostics: &diagnostics
                )
            }
        }

        return DiscoveryResult(
            repositories: found.values.sorted { $0.sortKey < $1.sortKey },
            diagnostics: diagnostics
        )
    }

    private func scan(
        directory: URL,
        root: URL,
        depth: Int,
        visited: inout Set<String>,
        found: inout [String: DiscoveredRepository],
        diagnostics: inout [DiscoveryDiagnostic]
    ) {
        guard depth <= maximumDepth else { return }

        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        if visited.contains(resolved.path) {
            diagnostics.append(.symlinkCycle(directory))
            return
        }
        visited.insert(resolved.path)

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        if resolved.path != resolvedRoot.path, !resolved.path.hasPrefix(resolvedRoot.path + "/") {
            diagnostics.append(.symlinkEscapesRoot(directory))
            return
        }

        if depth > 0, isRepository(directory) {
            let repository = DiscoveredRepository(url: directory.standardizedFileURL, discoveredVia: root)
            found[repository.identity] = repository
            return
        }
        if depth == 0, isRepository(directory) {
            let repository = DiscoveredRepository(url: directory.standardizedFileURL, discoveredVia: root)
            found[repository.identity] = repository
            return
        }

        guard depth < maximumDepth else { return }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            scan(
                directory: entry,
                root: root,
                depth: depth + 1,
                visited: &visited,
                found: &found,
                diagnostics: &diagnostics
            )
        }
    }
}
