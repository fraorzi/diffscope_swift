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

    /// What the pill says (DEC-073). The long `title` is the specification's name for the scope and
    /// is what a sentence uses; a control has room for two words, and the window had these four
    /// spelled out as literals beside the control until the empty state needed to compose
    /// `Staged — nothing staged` from the same word.
    public var shortTitle: String {
        switch self {
        case .allLocalVsHead: return "All local"
        case .unstagedVsIndex: return "Unstaged"
        case .stagedVsHead: return "Staged"
        case .branchVsMergeBase: return "vs base"
        }
    }

    /// What it means for *this* scope to have nothing in it (DEC-073). A scope that is available and
    /// empty looks exactly like one with work in it — a selected pill above an empty list — and the
    /// third state was the one the window could not say.
    ///
    /// Worded per scope rather than as one sentence: "nothing to show" would be true of all four and
    /// useful for none, and the reader's next move differs — staged is empty because they have not
    /// staged, and `vs base` is empty because the branch has not diverged.
    public var emptyDescription: String {
        switch self {
        case .allLocalVsHead: return "no local changes"
        case .unstagedVsIndex: return "nothing unstaged"
        case .stagedVsHead: return "nothing staged"
        case .branchVsMergeBase: return "no changes against the base"
        }
    }

    /// The two sides, named. `11-…` §"Scopes" is the table this transcribes, and the adopted design
    /// puts it on a row of its own under the scope control — because *which four scopes exist* and
    /// *what this one is comparing* are different questions, and a reader who has just switched
    /// scope is asking the second.
    ///
    /// Composed here rather than in the window, for the reason `baseSummary` is: a sentence the
    /// interface assembles cannot be checked.
    public var comparisonDescription: String {
        switch self {
        case .allLocalVsHead: return "HEAD ↔ working tree"
        case .unstagedVsIndex: return "index ↔ working tree"
        case .stagedVsHead: return "HEAD ↔ index"
        // Scope 4 names its base and its age instead; `baseSummary` owns those words, and saying
        // "merge-base ↔ working tree" here as well would be the same fact in two voices.
        case .branchVsMergeBase: return "merge-base ↔ working tree"
        }
    }
}

public enum ScopeAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool { self == .available }
}

public enum ChangeKind: String, Sendable, Equatable, CaseIterable {
    case added, modified, deleted, renamed, untracked, typeChanged, unmerged

    /// One character that means the same thing with every colour removed (DEC-035, DEC-060). The
    /// collapsed file list has room for this and nothing else, and the adopted design first drew
    /// those bars distinguished by hue alone.
    public var glyph: String {
        switch self {
        case .added: return "+"
        case .deleted: return "−"
        case .renamed: return "→"
        case .modified: return "✎"
        case .untracked: return "?"
        case .typeChanged: return "⇄"
        case .unmerged: return "!"
        }
    }
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

    /// Line counts for the same scope the list is showing (`12-…` §4). Separate from
    /// `changedFiles` because it is one more invocation and the list must appear before it
    /// arrives — the counts fill in, the rows do not wait for them.
    public func changeCounts(scope: ComparisonScope, in repository: URL,
                             baseRef: String? = nil) throws -> [String: ChangeCount] {
        var arguments: [String]
        switch scope {
        case .allLocalVsHead: arguments = ["HEAD"]
        case .unstagedVsIndex: arguments = []
        case .stagedVsHead: arguments = ["--cached"]
        case .branchVsMergeBase:
            guard let baseRef else { return [:] }
            let mergeBase = try runner.run(.mergeBase(baseRef, "HEAD"), in: repository)
            guard mergeBase.succeeded, !mergeBase.trimmedOutput.isEmpty else { return [:] }
            arguments = [mergeBase.trimmedOutput, "HEAD"]
        }
        let result = try runner.run(.diffNumstat(arguments), in: repository)
        guard result.succeeded else { return [:] }
        return parseNumstat(String(decoding: result.standardOutput, as: UTF8.self))
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

    // ---- History as a comparison (DEC-061) --------------------------------------------------
    //
    // DEC-008 deferred commit-vs-commit and its picker; DEC-061 admits it as a lens over the file
    // already selected, which is a door that decision did not anticipate and its amendment says
    // so. The four scopes are untouched: this is a second way of naming two sides, not a fifth
    // scope, and it goes through the same registry and the same pinning.
    public func changedFiles(between old: String, and new: String?,
                             in repository: URL) throws -> [ChangedFile] {
        // With no right-hand commit the comparison is *against the working tree*, which is what a
        // reader picking one commit means — "what has happened since this".
        let arguments = new.map { [old, $0] } ?? [old]
        let diff = try runner.run(.diffNameStatus(arguments), in: repository)
        guard diff.succeeded else { return [] }
        return parseNameStatus(String(decoding: diff.standardOutput, as: UTF8.self))
    }

    public func sources(for file: ChangedFile, between old: String,
                        and new: String?) -> (old: SideSource, new: SideSource) {
        let oldPath = file.originalPath ?? file.path
        return (file.kind == .added ? .absent : .blob(rev: old, path: oldPath),
                file.kind == .deleted ? .absent
                    : new.map { .blob(rev: $0, path: file.path) } ?? .worktree(path: file.path))
    }

    public func pinnedPair(for file: ChangedFile, between old: String, and new: String?,
                           in repository: URL) throws -> PinnedSourcePair {
        let (oldSource, newSource) = sources(for: file, between: old, and: new)
        let oldSide = try settledRead(oldSource, in: repository)
        let newSide = try settledRead(newSource, in: repository)
        return PinnedSourcePair(
            oldBytes: oldSide.bytes, newBytes: newSide.bytes,
            oldHash: contentHash(oldSide.bytes), newHash: contentHash(newSide.bytes),
            oldSource: oldSource, newSource: newSource,
            stable: oldSide.stable && newSide.stable
        )
    }

    /// What the base row says while a history comparison is on screen. One commit is *since*;
    /// two is *between*, and the order is the reader's selection order rather than the log's,
    /// because "compare this with that" is a sentence with a direction.
    public func historyComparisonDescription(old: String, new: String?) -> String {
        let short = { (rev: String) in String(rev.prefix(7)) }
        return new.map { "\(short(old)) ↔ \(short($0))" } ?? "\(short(old)) ↔ working tree"
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
    /// DEC-068's separation between a read and its confirmation — **a different quantity from the
    /// retry spacing above, and it was a mistake to reuse that one for it.**
    ///
    /// The retry delay is sized against a whole save (~11 ms measured). What this one has to outlast
    /// is the window between `truncate` and the first byte of the rewrite, which is microseconds.
    /// Twenty milliseconds against a 30 ms save cadence meant two thirds of every attempt sat inside
    /// a window a write could land in, and the guard refused **about half** the pins during an
    /// ordinary burst of saves — measured 42, 46, 48 and 52 refused of 100, straddling the floor
    /// that says a guard which refuses everything is an outage.
    public static let settleConfirmDelay: TimeInterval = 0.005

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
                // The second read is what catches a write already in flight when the first stat ran,
                // and DEC-068 is why it happens **later** rather than immediately. Taken back to
                // back, both looks land inside the same instant, and a file between `truncate` and
                // its rewrite is zero bytes and genuinely quiescent for the whole of it: three
                // stats agree the size is 0, both reads return nothing, every term here is
                // satisfied, and the pin certifies an empty file. Measured at 4 per 1,000 reads —
                // and it presents as *the whole file deleted*, which is the loudest way this
                // product can be wrong. Spanning a window instead of an instant means a transient
                // state has to persist to be believed, and a real one does.
                Thread.sleep(forTimeInterval: ScopeReader.settleConfirmDelay)
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
