import Foundation

public enum HeadState: Sendable, Equatable {
    case onBranch(String)
    case detached(String)
    case unborn(intendedBranch: String?)

    public var displayText: String {
        switch self {
        case let .onBranch(name): return name
        case let .detached(sha): return "detached at \(sha.prefix(8))"
        case let .unborn(intended):
            return intended.map { "no commits yet (\($0))" } ?? "no commits yet"
        }
    }

    public var supportsHeadComparison: Bool {
        if case .unborn = self { return false }
        return true
    }
}

public enum BaseBranchResolution: Sendable, Equatable {
    case resolved(ref: String, source: Source)
    case needsUserChoice

    public enum Source: String, Sendable, Equatable {
        case originHead
        case uniqueLocalDefault
        case userOverride
    }

    public var ref: String? {
        if case let .resolved(ref, _) = self { return ref }
        return nil
    }
}

public struct RepositorySnapshot: Sendable {
    public let url: URL
    public let head: HeadState
    public let uncommittedCount: Int
    public let base: BaseBranchResolution
    public let baseRefUsed: String?
    public let baseRefCommitterDate: String?
    public let aheadCount: Int?

    public var displayName: String { url.lastPathComponent }
}

public struct RepositoryReader: Sendable {
    public let runner: GitRunner

    public init(runner: GitRunner = GitRunner()) {
        self.runner = runner
    }

    public func headState(of repository: URL) throws -> HeadState {
        let verified = try runner.run(.revParseVerifyHead(), in: repository)
        guard verified.succeeded else {
            let intended = try? runner.run(.symbolicRefHead(), in: repository)
            let name = (intended?.succeeded ?? false) ? intended?.trimmedOutput : nil
            return .unborn(intendedBranch: name.flatMap { $0.isEmpty ? nil : $0 })
        }
        let symbolic = try runner.run(.symbolicRefHead(), in: repository)
        if symbolic.succeeded, !symbolic.trimmedOutput.isEmpty {
            return .onBranch(symbolic.trimmedOutput)
        }
        return .detached(verified.trimmedOutput)
    }

    /// The sentence the interface must show beside the count (`12-…` §2).
    ///
    /// It is a correctness requirement rather than a caption: `git status --porcelain` collapses an
    /// untracked directory to one entry while libgit2's default expands it, and X-4 measured the
    /// same repository reading **63 or 165** depending on which convention is in force. A number
    /// whose convention is unstated is not a measurement, and this project has a whole document
    /// about not making claims the reader cannot check.
    ///
    /// It lives here, next to the operation it describes, so that changing `statusPorcelain()` to
    /// `statusPorcelainAll()` puts the two lines in the same diff.
    public static let uncommittedCountConvention =
        "counts: git status --porcelain -uall — every untracked file counts, one per file"

    /// The number on the repository row, read with **the same command the file list reads**
    /// (DEC-111).
    ///
    /// It used to be `--porcelain` without `-uall`, which collapses an untracked directory to one
    /// entry, while the list — since DEC-111 — expands it. X-4 measured that disagreement as 63
    /// against 165 on one repository and this project wrote a sentence under the number to explain
    /// which convention was in force. **A number that needs a footnote to agree with the list beside
    /// it is the wrong number**: the sentence stays, and now it describes both.
    ///
    /// A rename emits its old path as a second entry, which is one change and must not count twice.
    public func uncommittedCount(in repository: URL) throws -> Int {
        let result = try runner.run(.statusPorcelainZ(), in: repository)
        guard result.succeeded else { return 0 }
        let entries = String(decoding: result.standardOutput, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
        var count = 0
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            index += 1
            guard entry.count > 3 else { continue }
            let chars = Array(entry)
            count += 1
            if chars[0] == "R" || chars[0] == "C" || chars[1] == "R" || chars[1] == "C" {
                index += 1
            }
        }
        return count
    }

    public func resolveBaseBranch(in repository: URL, override: String? = nil) throws -> BaseBranchResolution {
        if let override, !override.isEmpty {
            return .resolved(ref: override, source: .userOverride)
        }
        let originHead = try runner.run(.originHead(), in: repository)
        if originHead.succeeded, !originHead.trimmedOutput.isEmpty {
            return .resolved(ref: originHead.trimmedOutput, source: .originHead)
        }
        var found: [String] = []
        for candidate in ["main", "master"] {
            let result = try runner.run(.showRefVerify("refs/heads/\(candidate)"), in: repository)
            if result.succeeded { found.append(candidate) }
        }
        if found.count == 1 {
            return .resolved(ref: found[0], source: .uniqueLocalDefault)
        }
        return .needsUserChoice
    }

    public func preferredBaseRef(in repository: URL, base: String) throws -> String {
        let remoteTracking = "refs/remotes/origin/\(base)"
        let result = try runner.run(.showRefVerify(remoteTracking), in: repository)
        if result.succeeded { return "origin/\(base)" }
        if base.hasPrefix("origin/") { return base }
        return base
    }

    public func committerDate(of ref: String, in repository: URL) throws -> String? {
        let result = try runner.run(.refCommitterDate(ref), in: repository)
        guard result.succeeded, !result.trimmedOutput.isEmpty else { return nil }
        return result.trimmedOutput
    }

    public func aheadCount(in repository: URL, baseRef: String) throws -> Int? {
        let mergeBase = try runner.run(.mergeBase(baseRef, "HEAD"), in: repository)
        guard mergeBase.succeeded, !mergeBase.trimmedOutput.isEmpty else { return nil }
        let count = try runner.run(.revListCount("\(mergeBase.trimmedOutput)..HEAD"), in: repository)
        guard count.succeeded else { return nil }
        return Int(count.trimmedOutput)
    }

    public func snapshot(of repository: URL, baseOverride: String? = nil) throws -> RepositorySnapshot {
        let head = try headState(of: repository)
        let uncommitted = try uncommittedCount(in: repository)
        let base = try resolveBaseBranch(in: repository, override: baseOverride)

        var baseRefUsed: String?
        var baseDate: String?
        var ahead: Int?

        if head.supportsHeadComparison, let resolved = base.ref {
            let ref = try preferredBaseRef(in: repository, base: resolved)
            baseRefUsed = ref
            baseDate = try committerDate(of: ref, in: repository)
            ahead = try aheadCount(in: repository, baseRef: ref)
        }

        return RepositorySnapshot(
            url: repository,
            head: head,
            uncommittedCount: uncommitted,
            base: base,
            baseRefUsed: baseRefUsed,
            baseRefCommitterDate: baseDate,
            aheadCount: ahead
        )
    }
}
