import Foundation

/// What version two has to read before it can offer to write (DEC-092).
///
/// All of it goes through `GitRunner` and the read registry, so R-8 covers it: the branch list, the
/// stash stack, the conflicted paths, the graph and the mid-operation state are reads like any
/// other, and none of them may write to say what it says.

public struct BranchInfo: Sendable, Equatable {
    public let name: String
    public let upstream: String?
    /// What `%(upstream:track)` said, parsed: how far this branch is from its upstream.
    public let ahead: Int
    public let behind: Int
    public let isCurrent: Bool
    public let objectName: String

    public var hasUpstream: Bool { upstream != nil && !(upstream?.isEmpty ?? true) }
}

public struct StashEntry: Sendable, Equatable {
    public let ref: String
    public let subject: String
    public let date: String
}

/// A path git cannot merge by itself. `stages` is which of the three sides exist: 1 base, 2 ours,
/// 3 theirs — a path with no stage 1 was added on both sides, and the interface should not offer
/// "take the base" for it.
public struct ConflictEntry: Sendable, Equatable {
    public let path: String
    public let stages: Set<Int>

    public var addedOnBothSides: Bool { !stages.contains(1) }
    public var deletedByThem: Bool { !stages.contains(3) }
    public var deletedByUs: Bool { !stages.contains(2) }
}

public struct GraphCommit: Sendable, Equatable {
    public let sha: String
    public let parents: [String]
    public let author: String
    public let date: String
    public let subject: String
    public let refs: String
    /// Which column this commit is drawn in, and which columns have a line running through the row.
    public var lane: Int = 0
    public var lanes: [String] = []
}

public struct ReflogEntry: Sendable, Equatable {
    public let sha: String
    public let selector: String
    public let action: String
    public let date: String
}

public struct WorktreeEntry: Sendable, Equatable {
    public let path: String
    public let branch: String?
    public let isMain: Bool
    public let isCurrent: Bool
}

/// A repository in the middle of something. This is the state a Git GUI most often hides and the
/// one a reader most needs: the status line carries it as a banner with the three verbs on it.
public enum RepositoryOperation: Sendable, Equatable {
    case none
    case merging
    case rebasing(step: Int?, total: Int?)
    case cherryPicking
    case reverting
    case bisecting
    case detached(String)

    public var isInProgress: Bool {
        switch self {
        case .none, .detached: return false
        default: return true
        }
    }

    /// What the banner says. Composed here rather than in the window, for the reason every other
    /// sentence in this product is: a sentence the interface assembles cannot be checked.
    public var bannerText: String? {
        switch self {
        case .none: return nil
        case .merging: return "Merging — resolve the conflicts, then continue"
        case let .rebasing(step, total):
            if let step, let total { return "Rebasing — commit \(step) of \(total)" }
            return "Rebasing"
        case .cherryPicking: return "Cherry-picking"
        case .reverting: return "Reverting"
        case .bisecting: return "Bisecting — mark this commit good or bad"
        case let .detached(sha): return "Detached at \(String(sha.prefix(7))) — no branch is checked out"
        }
    }

    /// Which verbs the banner offers. `Continue` is absent from bisect on purpose: its two answers
    /// are *good* and *bad*, and a third button reading Continue would be a fourth thing to explain.
    public var verbs: [String] {
        switch self {
        case .merging: return ["Continue", "Abort"]
        case .rebasing: return ["Continue", "Skip", "Abort"]
        case .cherryPicking, .reverting: return ["Continue", "Abort"]
        case .bisecting: return ["Good", "Bad", "Skip", "Reset"]
        case .detached, .none: return []
        }
    }
}

public struct RepositoryStateReader: Sendable {
    public let runner: GitRunner

    public init(runner: GitRunner = GitRunner()) { self.runner = runner }

    private func lines(_ operation: GitOperation, in repository: URL) -> [String] {
        guard let result = try? runner.run(operation, in: repository), result.succeeded else { return [] }
        return String(decoding: result.standardOutput, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    public func branches(in repository: URL) -> [BranchInfo] {
        lines(.branchList(), in: repository).compactMap { line in
            let parts = line.components(separatedBy: "\u{1f}")
            guard parts.count >= 5 else { return nil }
            let (ahead, behind) = parseTrack(parts[2])
            return BranchInfo(name: parts[0], upstream: parts[1].isEmpty ? nil : parts[1],
                              ahead: ahead, behind: behind,
                              isCurrent: parts[3] == "*", objectName: parts[4])
        }
    }

    /// `%(upstream:track)` is `[ahead 2, behind 1]`, or `[gone]`, or nothing at all. Parsed rather
    /// than displayed, because the two numbers go on two different controls.
    func parseTrack(_ text: String) -> (ahead: Int, behind: Int) {
        var ahead = 0, behind = 0
        for token in text.replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .components(separatedBy: ", ") {
            let parts = token.split(separator: " ")
            guard parts.count == 2, let count = Int(parts[1]) else { continue }
            if parts[0] == "ahead" { ahead = count }
            if parts[0] == "behind" { behind = count }
        }
        return (ahead, behind)
    }

    public func remoteBranches(in repository: URL) -> [String] {
        lines(.branchListRemote(), in: repository).compactMap {
            let name = $0.components(separatedBy: "\u{1f}").first ?? ""
            // `origin/HEAD` is a symbolic ref, not a branch anybody checks out from a list.
            return name.hasSuffix("/HEAD") || name.isEmpty ? nil : name
        }
    }

    public func tags(in repository: URL) -> [String] {
        lines(.tagList(), in: repository).compactMap { $0.components(separatedBy: "\u{1f}").first }
    }

    public func stashes(in repository: URL) -> [StashEntry] {
        lines(.stashList(), in: repository).compactMap { line in
            let parts = line.components(separatedBy: "\u{1f}")
            guard parts.count >= 3 else { return nil }
            return StashEntry(ref: parts[0], subject: parts[1], date: parts[2])
        }
    }

    public func conflicts(in repository: URL) -> [ConflictEntry] {
        guard let result = try? runner.run(.lsFilesUnmerged(), in: repository), result.succeeded else { return [] }
        var stages: [String: Set<Int>] = [:]
        for record in String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\0") {
            // `<mode> <object> <stage>\t<path>`
            let halves = record.split(separator: "\t", maxSplits: 1).map(String.init)
            guard halves.count == 2 else { continue }
            let fields = halves[0].split(separator: " ")
            guard let stage = fields.last.flatMap({ Int($0) }) else { continue }
            stages[halves[1], default: []].insert(stage)
        }
        return stages.keys.sorted().map { ConflictEntry(path: $0, stages: stages[$0] ?? []) }
    }

    public func reflog(in repository: URL, limit: Int = 100) -> [ReflogEntry] {
        lines(.reflog(limit: limit), in: repository).compactMap { line in
            let parts = line.components(separatedBy: "\u{1f}")
            guard parts.count >= 4 else { return nil }
            return ReflogEntry(sha: parts[0], selector: parts[1], action: parts[2], date: parts[3])
        }
    }

    public func worktrees(in repository: URL) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var path: String?
        var branch: String?
        var isFirst = true
        func flush() {
            guard let path else { return }
            entries.append(WorktreeEntry(path: path, branch: branch, isMain: isFirst,
                                         isCurrent: URL(fileURLWithPath: path).standardizedFileURL
                                             == repository.standardizedFileURL))
            isFirst = false
        }
        for line in lines(.worktreeList(), in: repository) {
            if line.hasPrefix("worktree ") {
                flush()
                path = String(line.dropFirst("worktree ".count))
                branch = nil
            } else if line.hasPrefix("branch ") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            }
        }
        flush()
        return entries
    }

    /// The commit list with lanes assigned. The lane assignment is this application's, computed
    /// from `%P`; git's own `--graph` drawing is a presentation and is not parsed.
    public func graph(in repository: URL, limit: Int = 200, all: Bool = false) -> [GraphCommit] {
        var commits = lines(.logGraph(limit: limit, all: all), in: repository).compactMap { line -> GraphCommit? in
            let parts = line.components(separatedBy: "\u{1f}")
            guard parts.count >= 6 else { return nil }
            return GraphCommit(sha: parts[0],
                               parents: parts[1].split(separator: " ").map(String.init),
                               author: parts[2], date: parts[3], subject: parts[4], refs: parts[5])
        }
        assignLanes(&commits)
        return commits
    }

    /// One pass down the list, keeping a column per commit still waiting to be drawn.
    ///
    /// A commit takes the leftmost column that is waiting for it, or a new column if none is; its
    /// first parent inherits that column and the others take columns of their own. That is the
    /// whole of it — the same rule every graph drawing uses, and it is here rather than in the view
    /// because a lane is a fact about the history, not about the pixels.
    func assignLanes(_ commits: inout [GraphCommit]) {
        var columns: [String?] = []
        for index in commits.indices {
            let sha = commits[index].sha
            var lane = columns.firstIndex { $0 == sha }
            if lane == nil {
                lane = columns.firstIndex { $0 == nil } ?? columns.count
                if lane! == columns.count { columns.append(nil) }
            }
            commits[index].lane = lane!
            commits[index].lanes = columns.map { $0 ?? "" }
            columns[lane!] = commits[index].parents.first
            for parent in commits[index].parents.dropFirst() {
                if columns.contains(parent) { continue }
                if let free = columns.firstIndex(where: { $0 == nil }) { columns[free] = parent }
                else { columns.append(parent) }
            }
            // A column nobody is waiting for is freed, so the next commit can reuse it.
            for position in columns.indices where columns[position] != nil {
                if !commits[(index + 1)...].contains(where: { $0.sha == columns[position] }) &&
                    !commits[index].parents.contains(columns[position]!) {
                    columns[position] = nil
                }
            }
        }
    }

    /// Which operation the repository is in the middle of, read from `.git` rather than inferred
    /// from an error message.
    public func operation(in repository: URL, head: HeadState) -> RepositoryOperation {
        let gitDirectory = self.gitDirectory(of: repository)
        let manager = FileManager.default
        func exists(_ component: String) -> Bool {
            manager.fileExists(atPath: gitDirectory.appendingPathComponent(component).path)
        }
        if exists("rebase-merge") || exists("rebase-apply") {
            let base = exists("rebase-merge") ? "rebase-merge" : "rebase-apply"
            let step = Int((try? String(contentsOf: gitDirectory.appendingPathComponent("\(base)/msgnum"),
                                        encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            let total = Int((try? String(contentsOf: gitDirectory.appendingPathComponent("\(base)/end"),
                                         encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            return .rebasing(step: step, total: total)
        }
        if exists("CHERRY_PICK_HEAD") { return .cherryPicking }
        if exists("REVERT_HEAD") { return .reverting }
        if exists("MERGE_HEAD") { return .merging }
        if exists("BISECT_LOG") { return .bisecting }
        if case let .detached(sha) = head { return .detached(sha) }
        return .none
    }

    /// `.git` is a directory in a normal checkout and a file pointing elsewhere in a linked
    /// worktree. Both are read here, because version two adds worktrees and would otherwise report
    /// every linked one as *not in any operation*.
    public func gitDirectory(of repository: URL) -> URL {
        let candidate = repository.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else { return candidate }
        if isDirectory.boolValue { return candidate }
        guard let text = try? String(contentsOf: candidate, encoding: .utf8),
              let range = text.range(of: "gitdir: ") else { return candidate }
        let path = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : repository.appendingPathComponent(path).standardizedFileURL
    }

    public func headSha(in repository: URL) -> String? {
        guard let result = try? runner.run(.revParse("HEAD"), in: repository), result.succeeded else { return nil }
        return result.trimmedOutput.isEmpty ? nil : result.trimmedOutput
    }

    public func commitMessage(of rev: String, in repository: URL) -> String {
        guard let result = try? runner.run(.commitMessage(rev), in: repository), result.succeeded else { return "" }
        return String(decoding: result.standardOutput, as: UTF8.self)
    }
}
