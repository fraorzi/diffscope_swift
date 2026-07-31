import Foundation

/// Where the application's own settings live (DEC-052).
///
/// A plain JSON file the user can open and read, rather than `UserDefaults`. Two reasons, both
/// drawn from decisions already made: a product whose entire claim is that it hides nothing should
/// not keep its configuration somewhere the user cannot look at, and a file path can be injected so
/// the check suite runs against a temporary directory instead of the real machine's preferences.
///
/// The file lives outside every repository, so DEC-003's read-only guarantee is untouched by it.
public struct ConfiguredSource: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        /// Scanned to `RepositoryDiscovery.maximumDepth`, stopping at the first repository found —
        /// per root, since DEC-037 allows several.
        case root
        /// Added directly and never scanned. This is also the answer for a repository nested deeper
        /// than the depth limit would ever reach.
        case repository
    }

    public let kind: Kind
    public let path: String

    public init(kind: Kind, path: String) {
        self.kind = kind
        self.path = path
    }

    public var url: URL { URL(fileURLWithPath: path) }

    public var discoverySource: DiscoverySource {
        DiscoverySource(url: url, kind: kind == .root ? .root : .individualRepository)
    }
}

/// What a configured source turned out to be on disk, checked at load rather than assumed.
public enum SourceState: String, Sendable, Equatable {
    case present
    /// The path no longer exists. Reported, never removed: a root that silently disappears from the
    /// list is indistinguishable from one the user never added, and the user is the only one who
    /// can tell those apart.
    case missing
    /// Added as a repository, and it is not one.
    case notARepository
}

public struct InspectedSource: Sendable, Equatable {
    public let source: ConfiguredSource
    public let state: SourceState
}

public struct Configuration: Sendable, Equatable, Codable {
    public var sources: [ConfiguredSource]

    public init(sources: [ConfiguredSource] = []) {
        self.sources = sources
    }

    public var isEmpty: Bool { sources.isEmpty }
}

public enum ConfigurationLoad: Sendable, Equatable {
    /// No file yet. First run — not an error, and not something to report at the user.
    case firstRun
    case loaded(Configuration)
    /// The file exists and could not be read as configuration. **The file is left exactly as it
    /// was**: overwriting it would destroy the user's configured roots to recover from a problem
    /// they might be able to fix by hand, which is the same family of defect as hiding a change.
    case unreadable(reason: String)

    public var configuration: Configuration {
        if case let .loaded(configuration) = self { return configuration }
        return Configuration()
    }

    public var problem: String? {
        if case let .unreadable(reason) = self { return reason }
        return nil
    }
}

public struct ConfigurationStore: Sendable {
    public let url: URL

    /// `~/Library/Application Support/DiffScope/config.json`, or wherever `DIFFSCOPE_CONFIG` points.
    ///
    /// The override exists so a test run cannot touch the real configuration — the same reason the
    /// path is injectable at all, applied to the case where the caller is a whole application
    /// rather than a function.
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["DIFFSCOPE_CONFIG"] {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DiffScope/config.json")
    }

    public init(url: URL = ConfigurationStore.defaultURL) {
        self.url = url
    }

    public func load() -> ConfigurationLoad {
        guard FileManager.default.fileExists(atPath: url.path) else { return .firstRun }
        guard let data = try? Data(contentsOf: url) else {
            return .unreadable(reason: "the configuration file could not be read")
        }
        do {
            return .loaded(try JSONDecoder().decode(Configuration.self, from: data))
        } catch {
            return .unreadable(reason: "the configuration file is not valid: \(error)")
        }
    }

    /// Atomic, so an interrupted write cannot leave a half-written configuration behind.
    @discardableResult
    public func save(_ configuration: Configuration) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(configuration).write(to: url, options: .atomic)
            return nil
        } catch {
            return "the configuration could not be saved: \(error)"
        }
    }

    /// Checks each source against the disk. Called at load and after every change, because a root
    /// can be moved while the application is open.
    public func inspect(_ configuration: Configuration) -> [InspectedSource] {
        let discovery = RepositoryDiscovery()
        return configuration.sources.map { source in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return InspectedSource(source: source, state: .missing) }
            if source.kind == .repository, !discovery.isRepository(source.url) {
                return InspectedSource(source: source, state: .notARepository)
            }
            return InspectedSource(source: source, state: .present)
        }
    }
}

/// Labels for the repository list.
///
/// DEC-037 §Consequences: with several roots the folder name is no longer a unique key — two roots
/// can each hold `website`. Row identity is the path already; this is about what the reader sees,
/// so a name is qualified with as much parent directory as it takes to separate it, and **only
/// where there is a collision**. Qualifying every row would make the common case harder to read in
/// order to solve a case that is not present.
public func disambiguatedNames(for paths: [String]) -> [String: String] {
    var result: [String: String] = [:]
    var byName: [String: [String]] = [:]
    for path in paths {
        byName[URL(fileURLWithPath: path).lastPathComponent, default: []].append(path)
    }

    for (name, group) in byName {
        guard group.count > 1 else {
            if let only = group.first { result[only] = name }
            continue
        }
        var components: [String: [String]] = [:]
        for path in group {
            components[path] = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
        }
        // Take one more parent at a time until the labels differ, so the qualification is the
        // shortest that actually distinguishes rather than a full path nobody can scan.
        var depth = 1
        while depth < 8 {
            var labels: [String: String] = [:]
            for path in group {
                let parts = components[path] ?? []
                labels[path] = parts.suffix(depth + 1).joined(separator: "/")
            }
            if Set(labels.values).count == group.count {
                for (path, label) in labels { result[path] = label }
                break
            }
            depth += 1
            if depth == 8 {
                // Still colliding at eight levels: fall back to the full path, which is unique by
                // construction. Ugly, and honest.
                for path in group { result[path] = path }
            }
        }
        _ = name
    }
    return result
}
