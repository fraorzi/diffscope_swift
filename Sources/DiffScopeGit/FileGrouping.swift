import Foundation

/// The changed-file list, as a **tree** (DEC-099, answering OQ-041 and superseding DEC-033's
/// grouping and DEC-074's shortening).
///
/// DEC-033 gave the list one header per group and a flat run of files under it, and OQ-041 recorded
/// that this was "a middle position, not an answer". The position it was in the middle of is this
/// one: a header is a *label*, it says where the files under it are and nothing about how those
/// places relate, and two sibling directories spent forty characters each never saying they were
/// siblings. The indentation says it for free.
///
/// What DEC-033 got right is kept exactly: **the rows that are not files are not focus stops**, so
/// stepping through the list costs one keystroke per file however deep it nests.

public enum FileListRow: Sendable, Equatable {
    /// A directory. A label, never a focus stop (DEC-033's rule, kept by DEC-099): a row that takes
    /// the selection and shows nothing is a stop carrying no content.
    ///
    /// `key` is the full path, which is what the collapse state is keyed by; `title` is what the row
    /// draws — the last component, or the whole compressed chain where one was folded.
    case directory(key: String, title: String, depth: Int, collapsed: Bool)
    /// The file, its own name, and how deep it sits. DEC-033 asked for middle elision so that "the
    /// start identifies the package, the end identifies the file"; in a tree the start is the
    /// indentation, so the row draws the name and nothing else.
    case file(ChangedFile, display: String, depth: Int)

    public var file: ChangedFile? {
        if case let .file(file, _, _) = self { return file }
        return nil
    }

    public var display: String {
        switch self {
        case let .directory(_, title, _, _): return title
        case let .file(_, display, _): return display
        }
    }

    public var depth: Int {
        switch self {
        case let .directory(_, _, depth, _): return depth
        case let .file(_, _, depth): return depth
        }
    }

    public var directoryKey: String? {
        if case let .directory(key, _, _, _) = self { return key }
        return nil
    }
}

/// The rows of the changed-file list, as a tree (DEC-099).
///
/// Three rules, and each is here rather than in the view because each is a claim a check can ask
/// about:
///
/// 1. **A chain of single-child directories is one row.** `app/[locale]/(dev)/components` is four
///    path components and one branch; drawing four rows would spend four lines saying nothing.
/// 2. **Directories before files, alphabetically**, at every level.
/// 3. **A collapsed directory takes its whole subtree with it** — including directories inside it,
///    whose own collapse state is remembered but not consulted while their parent is folded.
public func fileTreeRows(_ files: [ChangedFile], collapsed: Set<String> = []) -> [FileListRow] {
    guard !files.isEmpty else { return [] }

    final class Node {
        let key: String
        var title: String
        var children: [String: Node] = [:]
        var files: [ChangedFile] = []
        init(key: String, title: String) {
            self.key = key
            self.title = title
        }
    }

    let root = Node(key: "", title: "")
    for file in files {
        var components = file.path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { continue }
        components.removeLast()
        var node = root
        var prefix = ""
        for component in components {
            prefix = prefix.isEmpty ? component : prefix + "/" + component
            if let existing = node.children[component] {
                node = existing
            } else {
                let child = Node(key: prefix, title: component)
                node.children[component] = child
                node = child
            }
        }
        node.files.append(file)
    }

    // Rule 1, applied bottom-up: a directory with no files of its own and exactly one child folds
    // that child into itself and takes its children. The compressed row keeps the **deepest** key,
    // so collapsing it is remembered against the directory the reader actually sees.
    func compress(_ node: Node) -> Node {
        for (name, child) in node.children { node.children[name] = compress(child) }
        guard node.files.isEmpty, node.children.count == 1, let only = node.children.values.first,
              !node.key.isEmpty else { return node }
        let merged = Node(key: only.key, title: node.title + "/" + only.title)
        merged.children = only.children
        merged.files = only.files
        return merged
    }
    let tree = compress(root)

    var rows: [FileListRow] = []
    func walk(_ node: Node, depth: Int) {
        for child in node.children.values.sorted(by: { $0.title.lowercased() < $1.title.lowercased() }) {
            let folded = collapsed.contains(child.key)
            rows.append(.directory(key: child.key, title: child.title, depth: depth, collapsed: folded))
            if !folded { walk(child, depth: depth + 1) }
        }
        for file in node.files.sorted(by: { $0.path.lowercased() < $1.path.lowercased() }) {
            rows.append(.file(file, display: (file.path as NSString).lastPathComponent, depth: depth))
        }
    }
    walk(tree, depth: 0)
    return rows
}

/// Where the selection lands when the reader steps through the list.
///
/// DEC-033 makes headers labels rather than focus stops, so stepping has to walk past them: the
/// measured 63-file list sits under nine headers and must still cost 62 keystrokes, not 71. Extracted
/// out of the table-view delegate so a 63-file list can be walked headlessly — the claim in the
/// definition of done is about a list of that size, and the check that stands behind it should not
/// need a window (M8-J).
///
/// `nil` means there is nowhere further to go in that direction; the caller leaves the selection
/// where it is rather than wrapping, because wrapping at the end of a file list reads as a jump to
/// somewhere else.
public enum RowNavigation {
    public static func step(rows: [FileListRow], from current: Int?, delta: Int) -> Int? {
        guard !rows.isEmpty, delta != 0 else { return nil }
        var candidate = current.map { $0 + delta } ?? (delta > 0 ? 0 : rows.count - 1)
        candidate = max(0, min(rows.count - 1, candidate))
        while candidate >= 0, candidate < rows.count {
            if rows[candidate].file != nil { return candidate == current ? nil : candidate }
            candidate += delta
        }
        return nil
    }

    /// The first row that can hold the selection at all — the row an empty selection resolves to,
    /// and the one a refresh falls back to when the previously selected file is gone.
    public static func firstSelectable(in rows: [FileListRow]) -> Int? {
        rows.firstIndex { $0.file != nil }
    }

    /// Whether a row may be selected. A header is not selectable by *any* route — arrow key, click,
    /// or ⌘] — because a selection that shows nothing is a dead stop wherever it comes from.
    public static func isSelectable(rows: [FileListRow], row: Int) -> Bool {
        row >= 0 && row < rows.count && rows[row].file != nil
    }
}

/// What the list can say about a file **without reading all of it** (`12-…` §4, §6).
///
/// The list is drawn for every changed file at once, so anything it shows has to be cheap. These
/// three are: the extension is free, the size is a `stat`, and a NUL byte in the first few kilobytes
/// is decisive on its own.
///
/// Deliberately **not** here: invalid UTF-8, which needs the whole file to rule out, and anything
/// the parser would have to decide. The list says what it can know cheaply; the diff view says
/// everything. A list that guessed would be worse than one that stays quiet.
public enum FileAnnotation: String, Sendable, Equatable {
    case unsupported
    case binary
    case oversized

    public var badge: String {
        switch self {
        case .unsupported: return "raw"
        case .binary: return "bin"
        case .oversized: return "big"
        }
    }
}

/// What the list says about size of change (`12-…` §4, the adopted design's file rows).
///
/// `binary` is a state, not a zero. Git reports `-` in both columns where a line count would be
/// meaningless, and inventing `+0 −0` there would be the same class of misstatement as an
/// ahead-count of 0 for a base that could not be determined.
public struct ChangeCount: Sendable, Equatable {
    public let added: Int
    public let deleted: Int
    public let isBinary: Bool

    public init(added: Int, deleted: Int, isBinary: Bool) {
        self.added = added
        self.deleted = deleted
        self.isBinary = isBinary
    }

    /// `+9 −11`, or the word. Composed here so the list and any other reader of it cannot word the
    /// same fact two ways.
    public var text: String {
        if isBinary { return "binary" }
        var parts: [String] = []
        if added > 0 { parts.append("+\(added)") }
        if deleted > 0 { parts.append("−\(deleted)") }
        return parts.isEmpty ? "±0" : parts.joined(separator: " ")
    }
}

/// `git diff --numstat`: added, deleted, path — tab separated, with `-` for binary. A rename is
/// reported with the new path, which is the path the list is keyed by.
public func parseNumstat(_ output: String) -> [String: ChangeCount] {
    var counts: [String: ChangeCount] = [:]
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { continue }
        let added = String(fields[0])
        let deleted = String(fields[1])
        var path = String(fields[2...].joined(separator: "\t"))
        // `{old => new}` for a rename inside one directory, and `old => new` across directories.
        if let arrow = path.range(of: " => ") {
            let tail = String(path[arrow.upperBound...])
            path = tail.replacingOccurrences(of: "}", with: "")
            if let open = String(path[path.startIndex...]).firstIndex(of: "{") {
                path.remove(at: open)
            }
            if let brace = String(fields[2...].joined(separator: "\t")).range(of: "{") {
                let prefix = String(fields[2...].joined(separator: "\t")[..<brace.lowerBound])
                path = prefix + path
            }
        }
        let binary = added == "-" && deleted == "-"
        counts[path] = ChangeCount(added: Int(added) ?? 0, deleted: Int(deleted) ?? 0,
                                   isBinary: binary)
    }
    return counts
}

private let structuralExtensions = [".tsx", ".ts", ".jsx", ".js", ".mts", ".cts", ".mjs", ".cjs"]

public func annotate(
    path: String,
    in repository: URL,
    sizeLimit: Int,
    probeBytes: Int = 4096
) -> FileAnnotation? {
    let url = repository.appendingPathComponent(path)
    if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
       size > sizeLimit {
        return .oversized
    }
    if let handle = try? FileHandle(forReadingFrom: url) {
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: probeBytes)) ?? Data()
        // A NUL needs no context to interpret, which is why it is the one content test the list is
        // allowed to make on a partial read.
        if prefix.contains(0) { return .binary }
    }
    let lower = path.lowercased()
    if !structuralExtensions.contains(where: { lower.hasSuffix($0) }) { return .unsupported }
    return nil
}
