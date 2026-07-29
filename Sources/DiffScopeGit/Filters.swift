import Foundation

/// What `git check-attr` says about a path, for the attributes that can make the bytes this
/// application compares differ from the bytes `git diff` compares (DEC-025, DEC-028).
public struct FilterState: Sendable, Equatable {
    /// Attribute name → value, for attributes that are set to something. `unspecified` and `unset`
    /// are dropped, because "no filter" is not a filter and must not read as one.
    public let active: [String: String]
    /// True when the attribute query itself failed. Not the same as "no filter": DEC-013's rule is
    /// that unknown is said, never guessed, so a failed query must not be reported as clean.
    public let unknown: Bool

    public var isActive: Bool { !active.isEmpty }

    public var summary: String {
        active.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    /// The reason text for F8, or `nil` when no filter applies. The caller wraps it — this module
    /// does not import the engine, so the taxonomy row is attached one layer up.
    ///
    /// DEC-041 requires the disclosure to explain the *discrepancy*, not merely name the filter.
    /// Without the second clause the interface looks broken: the file list says the file changed
    /// and the diff can legitimately show nothing changed, and both are correct.
    public var disclosure: String? {
        if unknown { return "whether a Git filter applies to this file could not be determined" }
        guard isActive else { return nil }
        return """
            a Git filter is active for this file (\(summary)), so the bytes on disk and the bytes \
            recorded in the object database are not the same text. This view compares them as they \
            are actually stored, which is why the file can be listed as changed by `git status` \
            while `git diff` reports nothing, and why what is shown here can differ from both
            """
    }
}

/// Reads filter attributes for a path. Read-only: `check-attr` is in the proven registry, and this
/// type never runs a filter — knowing that one applies is the whole point (DEC-028 rejected running
/// them on the grounds that repository content would decide what executes).
public struct FilterCheck: Sendable {
    /// `filter` covers clean/smudge drivers; `text` and `eol` cover the built-in EOL conversion
    /// that DEC-025 measured as the one that actually occurs in the wild.
    public static let attributes = ["filter", "text", "eol"]

    private let runner: GitRunner

    public init(runner: GitRunner) {
        self.runner = runner
    }

    public func state(for path: String, in repository: URL) -> FilterState {
        guard let result = try? runner.run(.checkAttr(FilterCheck.attributes, path: path), in: repository),
              result.succeeded
        else { return FilterState(active: [:], unknown: true) }
        return FilterCheck.parse(result.standardOutput)
    }

    /// `check-attr -z` emits NUL-separated triples: path, attribute, value. Parsed positionally
    /// rather than by line, because a path may contain a newline and `-z` exists for that reason.
    public static func parse(_ output: Data) -> FilterState {
        let fields = output.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var active: [String: String] = [:]
        var index = 0
        while index + 2 < fields.count {
            let attribute = fields[index + 1]
            let value = fields[index + 2]
            if value != "unspecified" && value != "unset" { active[attribute] = value }
            index += 3
        }
        return FilterState(active: active, unknown: false)
    }
}
