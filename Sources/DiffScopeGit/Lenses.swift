import Foundation

/// The two lenses over the selected file (DEC-061).
///
/// A lens is not a scope: the file does not change, the pinned pair does not change, and the
/// gutter geometry is the same, so switching one does not move the code under the reader's eyes.
/// What changes is which question is being answered — *what changed*, *who wrote this*, *what
/// happened here*.
///
/// Both parsers take text rather than running Git, for the reason the engine takes bytes: a parser
/// that owns its own subprocess cannot be checked without a repository, and the cases worth
/// checking are the ones a real repository will not produce on demand — an uncommitted line, a
/// subject containing the field separator, a boundary commit.
public struct BlameLine: Sendable, Equatable {
    public let sha: String
    public let author: String
    /// ISO-8601, as Git reports it. Turned into words at the edge, the way `stalenessDescription`
    /// does for the base ref — a date makes the reader do the subtraction.
    public let committed: String
    public let line: Int
    public let text: String
    /// `git blame` reports work that is not committed yet with an all-zero sha. Marked rather than
    /// tinted: the change language owns tint and texture in this window (DEC-061).
    public var isUncommitted: Bool { sha.allSatisfy { $0 == "0" } }

    public init(sha: String, author: String, committed: String, line: Int, text: String) {
        self.sha = sha
        self.author = author
        self.committed = committed
        self.line = line
        self.text = text
    }
}

/// `git blame --porcelain`: a header line of `<sha> <origLine> <finalLine> [<count>]`, then
/// key-value lines, then the content line prefixed by a tab. Fields are only repeated for the
/// first line of each block, so the parser carries them forward — the format's whole design.
public func parseBlamePorcelain(_ output: String) -> [BlameLine] {
    var lines: [BlameLine] = []
    var authors: [String: String] = [:]
    var dates: [String: String] = [:]
    var sha = ""
    var lineNumber = 0
    var author: String?
    var date: String?

    for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
        let row = String(raw)
        if row.hasPrefix("\t") {
            let text = String(row.dropFirst())
            // A block's second and later lines repeat neither author nor date, so the last values
            // seen for that sha are the ones that apply.
            let resolvedAuthor = author ?? authors[sha] ?? "unknown"
            let resolvedDate = date ?? dates[sha] ?? ""
            authors[sha] = resolvedAuthor
            dates[sha] = resolvedDate
            lines.append(BlameLine(sha: sha, author: resolvedAuthor, committed: resolvedDate,
                                   line: lineNumber, text: text))
            author = nil
            date = nil
            continue
        }
        if row.hasPrefix("author ") {
            author = String(row.dropFirst("author ".count))
        } else if row.hasPrefix("author-time ") {
            let seconds = TimeInterval(row.dropFirst("author-time ".count)) ?? 0
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.string(from: Date(timeIntervalSince1970: seconds))
        } else {
            // A header: `<sha> <original line> <final line> [<lines in this block>]`.
            let parts = row.split(separator: " ")
            if parts.count >= 3, parts[0].count >= 7,
               parts[0].allSatisfy({ $0.isHexDigit }), let final = Int(parts[2]) {
                sha = String(parts[0])
                lineNumber = final
            }
        }
    }
    return lines
}

public struct Commit: Sendable, Equatable {
    public let sha: String
    public let author: String
    public let committed: String
    public let subject: String
    /// `HEAD -> main, origin/main`, as Git writes it, or empty. Shown because a commit that is the
    /// base of the current comparison is the one a reader is looking for.
    public let refs: String

    public init(sha: String, author: String, committed: String, subject: String, refs: String) {
        self.sha = sha
        self.author = author
        self.committed = committed
        self.subject = subject
        self.refs = refs
    }

    public var shortSha: String { String(sha.prefix(7)) }
}

/// The records `GitOperation.log` asks for, split on the unit separator. A subject can contain
/// anything a person can type, including tabs, pipes and the word `commit` — which is why the
/// separator is a control character no editor produces by accident.
public func parseLog(_ output: String) -> [Commit] {
    output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { row in
        let fields = row.split(separator: "\u{1f}", omittingEmptySubsequences: false)
        guard fields.count >= 4 else { return nil }
        return Commit(sha: String(fields[0]),
                      author: String(fields[1]),
                      committed: String(fields[2]),
                      subject: String(fields[3]),
                      refs: fields.count > 4 ? String(fields[4]) : "")
    }
}

/// What the History lens says above the list. The age rule of DEC-010 reaches here too: a history
/// read from disk can be nine weeks behind the remote and look complete, so the words say which
/// commits these are.
public func historySummary(commits: [Commit], branch: String, ahead: Int?) -> String {
    let count = commits.count == 1 ? "1 commit" : "\(commits.count) commits"
    let aheadText = ahead.map { "\($0) ahead of base" } ?? "ahead of base: unknown"
    return "\(count) on \(branch) · \(aheadText) · as they are on disk; DiffScope never fetches"
}
