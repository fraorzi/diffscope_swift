import Foundation

/// One reading of `git status --porcelain -uall -z`, parsed once.
///
/// Three places in this module ask git the same question and each parsed the answer itself:
/// `Scopes.statusFiles` builds the changed-file list, `RepositoryStateReader.staging` builds the
/// box beside each path, and `Repository.uncommittedCount` counts. A refresh runs the first two
/// back to back, so **every refresh spent two full status reads on the same bytes** — on the main
/// thread, where the reader can feel it.
///
/// Worse than the cost: two readings of a repository taken a few milliseconds apart can disagree,
/// and the interface then draws a file list from one and a set of checkboxes from the other. Parsed
/// once, they cannot.
///
/// `-z` and `-uall` are DEC-111's, and the reasons are on `GitOperation.statusPorcelainZ`: nothing
/// is quoted, entries are NUL-separated, and an untracked directory is listed as its files rather
/// than collapsed to a folder.
public struct StatusSnapshot: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// The two status characters, index side then worktree side.
        public let index: Character
        public let worktree: Character
        public let path: String
        /// Where a rename or copy came from. Git emits it as the following entry, not as part of
        /// this one, which is why parsing has to consume two.
        public let original: String?

        public init(index: Character, worktree: Character, path: String, original: String?) {
            self.index = index
            self.worktree = worktree
            self.path = path
            self.original = original
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// Parses the raw NUL-separated output. Kept separate from the reading so it can be checked
    /// against bytes a test writes rather than against a repository a test has to build.
    public init(porcelainZ output: Data) {
        let parts = String(decoding: output, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
        var entries: [Entry] = []
        var cursor = 0
        while cursor < parts.count {
            let entry = parts[cursor]
            cursor += 1
            guard entry.count > 3 else { continue }
            let characters = Array(entry)
            let index = characters[0], worktree = characters[1]
            var original: String?
            if index == "R" || index == "C" || worktree == "R" || worktree == "C" {
                if cursor < parts.count {
                    original = parts[cursor]
                    cursor += 1
                }
            }
            entries.append(Entry(index: index, worktree: worktree,
                                 path: String(characters[3...]), original: original))
        }
        self.entries = entries
    }
}
