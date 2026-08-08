import Foundation

/// The changed-file list, grouped (DEC-033 as amended, 2026-07-31).
///
/// DEC-033 specified **group headers per workspace package**, on the planning-time observation that
/// "12 of 21 repositories are pnpm monorepos". Measured at implementation time: 12 repositories do
/// contain a `pnpm-workspace.yaml`, and **not one of them declares a `packages:` key**; no
/// `package.json` in the corpus carries a `workspaces` key either. Grouping by workspace package
/// would therefore put a single header reading "everything" above the same flat list, in every
/// repository the product owner actually has.
///
/// So the rule is: **a workspace package where one is declared, the file's parent directory
/// otherwise.** That keeps DEC-033's intent — monorepo context preserved, two `page.tsx` entries in
/// different places distinguishable — and delivers it on the repositories that exist. The 20 changed
/// files in `philips__signify-wiz-euro__preact` sit under seven directories; that is the grouping
/// that makes the list scannable.
public enum FileListRow: Sendable, Equatable {
    /// A label, never a focus stop (DEC-033: headers that take focus add navigation stops carrying
    /// no content).
    case header(String)
    /// The file, and how much of its path is worth drawing. DEC-033 asks for middle elision so that
    /// "the start identifies the package, the end identifies the file" — but under a header the
    /// start is already on screen one row above, and repeating it spends the width elision existed
    /// to save. So a grouped row shows the path *relative to its group*, and an ungrouped one shows
    /// the whole path.
    case file(ChangedFile, display: String)

    public var file: ChangedFile? {
        if case let .file(file, _) = self { return file }
        return nil
    }

    public var display: String {
        switch self {
        case let .header(title): return title
        case let .file(_, display): return display
        }
    }
}

/// Groups declared by the repository, if any. Empty is the normal case in this corpus.
public func declaredWorkspacePackages(in repository: URL) -> [String] {
    var prefixes: [String] = []

    if let yaml = try? String(contentsOf: repository.appendingPathComponent("pnpm-workspace.yaml"),
                              encoding: .utf8) {
        var inPackages = false
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("packages:") { inPackages = true; continue }
            // Any other top-level key ends the list. `onlyBuiltDependencies:` is the key every
            // file in this corpus actually has, and reading its entries as packages would invent
            // groups named after build tools.
            if inPackages, !line.hasPrefix(" "), !line.hasPrefix("\t"), !trimmed.hasPrefix("-"),
               !trimmed.isEmpty { inPackages = false }
            guard inPackages, trimmed.hasPrefix("- ") else { continue }
            let glob = trimmed.dropFirst(2)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
            let prefix = glob.replacingOccurrences(of: "/**", with: "")
                .replacingOccurrences(of: "/*", with: "")
            if !prefix.isEmpty, prefix != "." { prefixes.append(prefix) }
        }
    }

    if let data = try? Data(contentsOf: repository.appendingPathComponent("package.json")),
       let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        let globs = (json["workspaces"] as? [String])
            ?? ((json["workspaces"] as? [String: Any])?["packages"] as? [String])
            ?? []
        for glob in globs {
            let prefix = glob.replacingOccurrences(of: "/**", with: "")
                .replacingOccurrences(of: "/*", with: "")
            if !prefix.isEmpty, prefix != "." { prefixes.append(prefix) }
        }
    }

    return Array(Set(prefixes)).sorted()
}

/// The group a path belongs to: the deepest declared workspace prefix that contains it, or its
/// parent directory. Files at the repository root fall into one bucket rather than a nameless one.
public func groupKey(for path: String, workspacePackages: [String]) -> String {
    let matching = workspacePackages
        .filter { path == $0 || path.hasPrefix($0 + "/") }
        .max(by: { $0.count < $1.count })
    if let matching { return matching }
    let parent = (path as NSString).deletingLastPathComponent
    return parent.isEmpty ? "(repository root)" : parent
}

/// Rows for the list, headers included.
///
/// **Headers are suppressed when grouping buys nothing.** If nearly every file sits in its own
/// group, headers double the length of the list and separate nothing — so past a threshold the list
/// stays flat. Stated as a rule rather than left to taste, because "it looked cluttered" is not
/// something a later reader can check.
public func fileListRows(
    _ files: [ChangedFile],
    workspacePackages: [String] = [],
    groupingThreshold: Double = 0.5
) -> [FileListRow] {
    guard !files.isEmpty else { return [] }

    var order: [String] = []
    var grouped: [String: [ChangedFile]] = [:]
    for file in files {
        let key = groupKey(for: file.path, workspacePackages: workspacePackages)
        if grouped[key] == nil { order.append(key) }
        grouped[key, default: []].append(file)
    }

    // One group per file is not grouping. So is one group in total: a single header above the whole
    // list says nothing that the repository name has not already said.
    let ratio = Double(grouped.count) / Double(files.count)
    guard grouped.count > 1, ratio <= groupingThreshold else {
        return files.map { .file($0, display: $0.path) }
    }

    var rows: [FileListRow] = []
    for key in order.sorted() {
        rows.append(.header(key))
        for file in (grouped[key] ?? []).sorted(by: { $0.path < $1.path }) {
            let relative = file.path.hasPrefix(key + "/")
                ? String(file.path.dropFirst(key.count + 1))
                : file.path
            rows.append(.file(file, display: relative))
        }
    }
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
