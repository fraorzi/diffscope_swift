import CryptoKit
import Foundation

public enum ComparisonScope: String, Sendable, CaseIterable {
    case allLocalVsHead
    case unstagedVsIndex
    case stagedVsHead
    case branchVsMergeBase

    public var title: String {
        switch self {
        case .allLocalVsHead: return "All local changes vs HEAD"
        case .unstagedVsIndex: return "Unstaged vs index"
        case .stagedVsHead: return "Staged vs HEAD"
        case .branchVsMergeBase: return "Branch vs merge-base"
        }
    }
}

public enum ScopeAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }
}

public enum ChangeKind: String, Sendable, Equatable {
    case added, modified, deleted, renamed, untracked, typeChanged, unmerged
}

public struct ChangedFile: Sendable, Equatable {
    public let path: String
    public let originalPath: String?
    public let kind: ChangeKind

    public init(path: String, originalPath: String?, kind: ChangeKind) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
    }
}

public enum SideSource: Sendable, Equatable {
    case blob(rev: String, path: String)
    case worktree(path: String)
    case absent
}

public struct PinnedSourcePair: Sendable {
    public let oldBytes: [UInt8]
    public let newBytes: [UInt8]
    public let oldHash: String
    public let newHash: String
    public let oldSource: SideSource
    public let newSource: SideSource
    /// False when a worktree side would not read the same twice (DEC-049, test R-9). The pair is
    /// still returned, because discarding it silently is the failure the flag exists to prevent.
    public let stable: Bool

    public var isByteEqual: Bool { oldHash == newHash }
}

public func contentHash(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
}

public struct ScopeReader: Sendable {
    public let runner: GitRunner
    public let reader: RepositoryReader

    public init(runner: GitRunner = GitRunner()) {
        self.runner = runner
        self.reader = RepositoryReader(runner: runner)
    }

    public func availability(
        of scope: ComparisonScope,
        head: HeadState,
        base: BaseBranchResolution
    ) -> ScopeAvailability {
        if case .unborn = head {
            return .unavailable(reason: "repository has no commits yet")
        }
        if scope == .branchVsMergeBase {
            if case .detached = head {
                return .unavailable(reason: "HEAD is detached")
            }
            if base.ref == nil {
                return .unavailable(reason: "base branch could not be determined")
            }
        }
        return .available
    }

    public func changedFiles(scope: ComparisonScope, in repository: URL, baseRef: String? = nil) throws -> [ChangedFile] {
        switch scope {
        case .allLocalVsHead, .unstagedVsIndex, .stagedVsHead:
            return try statusFiles(scope: scope, in: repository)
        case .branchVsMergeBase:
            guard let baseRef else { return [] }
            let mergeBase = try runner.run(.mergeBase(baseRef, "HEAD"), in: repository)
            guard mergeBase.succeeded, !mergeBase.trimmedOutput.isEmpty else { return [] }
            let diff = try runner.run(.diffNameStatus([mergeBase.trimmedOutput, "HEAD"]), in: repository)
            guard diff.succeeded else { return [] }
            return parseNameStatus(String(decoding: diff.standardOutput, as: UTF8.self))
        }
    }

    private func statusFiles(scope: ComparisonScope, in repository: URL) throws -> [ChangedFile] {
        let result = try runner.run(.statusPorcelain(), in: repository)
        guard result.succeeded else { return [] }
        var files: [ChangedFile] = []
        for line in String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n") {
            guard line.count > 3 else { continue }
            let chars = Array(line)
            let index = chars[0]
            let worktree = chars[1]
            var path = String(chars[3...])
            var original: String?
            if let arrow = path.range(of: " -> ") {
                original = String(path[path.startIndex..<arrow.lowerBound])
                path = String(path[arrow.upperBound...])
            }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            let staged = index != " " && index != "?"
            let unstaged = worktree != " " && worktree != "?"
            let untracked = index == "?" && worktree == "?"

            let include: Bool
            switch scope {
            case .stagedVsHead: include = staged
            case .unstagedVsIndex: include = unstaged || untracked
            case .allLocalVsHead: include = staged || unstaged || untracked
            case .branchVsMergeBase: include = false
            }
            guard include else { continue }

            let marker = scope == .stagedVsHead ? index : (unstaged ? worktree : index)
            files.append(ChangedFile(path: path, originalPath: original, kind: kind(for: marker, untracked: untracked)))
        }
        return files.sorted { $0.path < $1.path }
    }

    private func kind(for marker: Character, untracked: Bool) -> ChangeKind {
        if untracked { return .untracked }
        switch marker {
        case "A": return .added
        case "M": return .modified
        case "D": return .deleted
        case "R": return .renamed
        case "T": return .typeChanged
        case "U": return .unmerged
        default: return .modified
        }
    }

    private func parseNameStatus(_ text: String) -> [ChangedFile] {
        var files: [ChangedFile] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 2, let marker = parts[0].first else { continue }
            if marker == "R", parts.count >= 3 {
                files.append(ChangedFile(path: parts[2], originalPath: parts[1], kind: .renamed))
            } else {
                files.append(ChangedFile(path: parts[1], originalPath: nil, kind: kind(for: marker, untracked: false)))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    public func sources(
        for file: ChangedFile,
        scope: ComparisonScope,
        mergeBaseRev: String?
    ) -> (old: SideSource, new: SideSource) {
        let oldPath = file.originalPath ?? file.path
        switch scope {
        case .allLocalVsHead:
            return (file.kind == .untracked || file.kind == .added ? .absent : .blob(rev: "HEAD", path: oldPath),
                    file.kind == .deleted ? .absent : .worktree(path: file.path))
        case .unstagedVsIndex:
            return (file.kind == .untracked ? .absent : .blob(rev: "", path: oldPath),
                    file.kind == .deleted ? .absent : .worktree(path: file.path))
        case .stagedVsHead:
            return (file.kind == .added ? .absent : .blob(rev: "HEAD", path: oldPath),
                    file.kind == .deleted ? .absent : .blob(rev: "", path: file.path))
        case .branchVsMergeBase:
            let base = mergeBaseRev ?? "HEAD"
            return (file.kind == .added ? .absent : .blob(rev: base, path: oldPath),
                    file.kind == .deleted ? .absent : .blob(rev: "HEAD", path: file.path))
        }
    }

    public func readSide(_ source: SideSource, in repository: URL) throws -> [UInt8] {
        switch source {
        case .absent:
            return []
        case let .worktree(path):
            let url = repository.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url) else { return [] }
            return [UInt8](data)
        case let .blob(rev, path):
            let result = try runner.run(.catFileBlob(rev: rev, path: path), in: repository)
            guard result.succeeded else { return [] }
            return [UInt8](result.standardOutput)
        }
    }

    /// How many times a worktree read is repeated before the pair is reported unstable (DEC-049).
    public static let settleAttempts = 5
    /// Between attempts. One measured atomic save spans ~11 ms, so a save in flight is over well
    /// inside the budget; a file genuinely being written without pause never settles, and that is
    /// reported rather than papered over.
    public static let settleRetryDelay: TimeInterval = 0.02

    /// Identity and last-write time, taken either side of a read. Nanosecond `mtime` on APFS, so
    /// a write that overlapped the read moves it — re-reading and comparing *content* is not
    /// enough on its own, because two torn reads of an editor writing in a loop can agree.
    private struct FileStamp: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: TimeInterval
    }

    private func stamp(of url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = attributes[.systemFileNumber] as? UInt64 ?? (attributes[.systemFileNumber] as? Int).map(UInt64.init),
              let size = attributes[.size] as? UInt64 ?? (attributes[.size] as? Int).map(UInt64.init),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return FileStamp(inode: inode, size: size, modified: modified.timeIntervalSince1970)
    }

    /// DEC-049, test R-9: a worktree file being written while it is read can be read half-old and
    /// half-new, and hashing that blend would certify a version that never existed on disk. Blob
    /// sides come from the object database and are immutable, so only worktree sides are guarded.
    ///
    /// The guard brackets the read with a stat **and** repeats the read, requiring both to agree.
    ///
    /// Each half is insufficient, and each was measured to be insufficient rather than argued about:
    ///
    /// - **Content alone** let 3 blends through in 8,095 reads (M7-B). Comparing two reads asks
    ///   whether they matched, not whether anything wrote between them.
    /// - **The stat bracket alone** let 6 blends through in 20 reads under load (M8-H). The reason
    ///   is that a single large `write` stamps `mtime` once, at the start, while the copy continues:
    ///   both stats see the same timestamp, and the read in between lands mid-copy. The bracket can
    ///   tell that no write *started*; it cannot tell that none is *in flight*.
    ///
    /// Together they close each other's hole. A blend now has to survive an unchanged inode, size
    /// and modification time **and** be byte-identical to a second read taken afterwards.
    private func settledRead(_ source: SideSource, in repository: URL) throws -> (bytes: [UInt8], stable: Bool) {
        guard case let .worktree(path) = source else { return (try readSide(source, in: repository), true) }
        let url = repository.appendingPathComponent(path)
        var bytes: [UInt8] = []
        for attempt in 0..<ScopeReader.settleAttempts {
            let before = stamp(of: url)
            bytes = try readSide(source, in: repository)
            let after = stamp(of: url)
            if before != nil, before == after {
                // The second read is what catches a write already in flight when the first stat ran.
                let confirmation = try readSide(source, in: repository)
                if confirmation == bytes, stamp(of: url) == after { return (bytes, true) }
            }
            if attempt + 1 < ScopeReader.settleAttempts {
                Thread.sleep(forTimeInterval: ScopeReader.settleRetryDelay)
            }
        }
        return (bytes, false)
    }

    public func pinnedPair(
        for file: ChangedFile,
        scope: ComparisonScope,
        in repository: URL,
        mergeBaseRev: String? = nil
    ) throws -> PinnedSourcePair {
        let (oldSource, newSource) = sources(for: file, scope: scope, mergeBaseRev: mergeBaseRev)
        let old = try settledRead(oldSource, in: repository)
        let new = try settledRead(newSource, in: repository)
        return PinnedSourcePair(
            oldBytes: old.bytes,
            newBytes: new.bytes,
            oldHash: contentHash(old.bytes),
            newHash: contentHash(new.bytes),
            oldSource: oldSource,
            newSource: newSource,
            stable: old.stable && new.stable
        )
    }
}
