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

    public func pinnedPair(
        for file: ChangedFile,
        scope: ComparisonScope,
        in repository: URL,
        mergeBaseRev: String? = nil
    ) throws -> PinnedSourcePair {
        let (oldSource, newSource) = sources(for: file, scope: scope, mergeBaseRev: mergeBaseRev)
        let oldBytes = try readSide(oldSource, in: repository)
        let newBytes = try readSide(newSource, in: repository)
        return PinnedSourcePair(
            oldBytes: oldBytes,
            newBytes: newBytes,
            oldHash: contentHash(oldBytes),
            newHash: contentHash(newBytes),
            oldSource: oldSource,
            newSource: newSource
        )
    }
}
