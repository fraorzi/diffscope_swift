import Foundation

/// Search within the changed set (DEC-062, amending DEC-017).
///
/// The default scope is the changed files, because that is the material under review; the whole
/// worktree is the second question and is asked explicitly. The two answer different things and a
/// reader who does not know which they asked cannot read the count, so the scope is stated on
/// screen rather than inferred.
///
/// **Read-only, and nothing here is a Git operation.** Searching reads the worktree the same way
/// the diff already does. No repository content is executed, and no command is built from it
/// (DEC-028) — the query comes from the reader and is matched as a literal, never as a pattern
/// compiled from a file.
public struct SearchHit: Sendable, Equatable {
    public let path: String
    /// 1-based, because it is shown to a person and used to open an editor.
    public let line: Int
    /// The text of the line, split around the match so the interface can mark it without
    /// searching the string a second time and disagreeing with this one.
    public let before: String
    public let match: String
    public let after: String

    public init(path: String, line: Int, before: String, match: String, after: String) {
        self.path = path
        self.line = line
        self.before = before
        self.match = match
        self.after = after
    }
}

public enum SearchScope: String, Sendable, Equatable, CaseIterable {
    case changedFiles
    case wholeWorktree

    public var title: String {
        switch self {
        case .changedFiles: return "changed files"
        case .wholeWorktree: return "whole worktree"
        }
    }
}

public struct SearchOptions: Sendable, Equatable {
    public var matchCase: Bool
    /// A cap, because a one-character query over a large worktree is a legitimate thing to type by
    /// accident. The interface says when it was reached rather than quietly showing a prefix.
    public var limit: Int

    public init(matchCase: Bool = false, limit: Int = 500) {
        self.matchCase = matchCase
        self.limit = limit
    }
}

public struct SearchResult: Sendable, Equatable {
    public let hits: [SearchHit]
    /// True when `limit` stopped the search before the files ran out.
    public let truncated: Bool
    public let filesSearched: Int

    public init(hits: [SearchHit], truncated: Bool, filesSearched: Int) {
        self.hits = hits
        self.truncated = truncated
        self.filesSearched = filesSearched
    }
}

/// Searches the given file contents. Taking the text rather than reading it here is what makes the
/// whole thing checkable without a repository on disk — the same reason the engine takes bytes.
public func search(query: String, in files: [(path: String, text: String)],
                   options: SearchOptions = SearchOptions()) -> SearchResult {
    guard !query.isEmpty else { return SearchResult(hits: [], truncated: false, filesSearched: 0) }
    var hits: [SearchHit] = []
    var truncated = false
    var searched = 0

    for file in files {
        searched += 1
        // Split on newlines rather than searching the whole text: a match must belong to a line,
        // and a hit that spans one would be reported at a line it is not on.
        for (index, line) in file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(line)
            var cursor = text.startIndex
            while let range = text.range(of: query,
                                         options: options.matchCase ? [] : [.caseInsensitive],
                                         range: cursor..<text.endIndex) {
                guard hits.count < options.limit else {
                    return SearchResult(hits: hits, truncated: true, filesSearched: searched)
                }
                hits.append(SearchHit(path: file.path,
                                      line: index + 1,
                                      before: String(text[text.startIndex..<range.lowerBound]),
                                      match: String(text[range]),
                                      after: String(text[range.upperBound..<text.endIndex])))
                // `range.upperBound` rather than one character on: overlapping matches of the same
                // query are one hit, which is what a reader counting occurrences expects.
                cursor = range.upperBound
                if cursor == text.endIndex { break }
            }
        }
    }
    return SearchResult(hits: hits, truncated: truncated, filesSearched: searched)
}

/// What the results header says. Composed here for the reason `baseSummary` is: a sentence the
/// interface assembles cannot be checked, and this one has to state the scope — a count over the
/// changed set and a count over the worktree are different answers to different questions.
public func searchSummary(query: String, result: SearchResult, scope: SearchScope) -> String {
    guard !query.isEmpty else { return "type to search \(scope.title)" }
    let files = Set(result.hits.map(\.path)).count
    if result.hits.isEmpty {
        return "no matches for “\(query)” in \(result.filesSearched) \(scope.title)"
    }
    let matches = result.hits.count == 1 ? "1 match" : "\(result.hits.count) matches"
    let where_ = files == 1 ? "1 file" : "\(files) files"
    let capped = result.truncated ? " · stopped at the first \(result.hits.count), there are more" : ""
    return "\(matches) in \(where_) of \(result.filesSearched) \(scope.title)\(capped)"
}
