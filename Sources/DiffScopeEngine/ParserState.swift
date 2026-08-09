import Foundation

/// Parser state — the sixth of the seven indicators `12-desktop-ux-specification.md` §5.2 calls
/// *"not optional features … how the invariant becomes visible"*, and the last one still missing
/// (`23b-spec-vs-app-audit.md` §1.10).
///
/// It was visible only *indirectly* before: a reader inferred "this file did not parse" from the
/// presence of a fallback notice, and inferred "it parsed" from the absence of one. Both inferences
/// are wrong in one direction each. A file can parse completely and still carry a notice — an
/// active filter (F8) says nothing about the parser — and a file can be **partially** parsed while
/// the structural result stands, which produces a notice that reads like a whole-file failure.
///
/// So the state is stated rather than inferred, and it is computed here rather than in the shell,
/// for the reason M7-A gives for navigation stops: a fact about the model belongs to the model, and
/// a fact assembled in the interface cannot be checked without a window.
public struct ParserStateReport: Codable, Sendable, Equatable {
    /// One of `parsed`, `partial`, `not-parsed`. A closed vocabulary — the three states §5.2 names.
    public let state: String
    /// What the reader needs beyond the state itself: why it was not parsed, or how much of it was
    /// not. `nil` only for the fully-parsed case, where there is nothing further to say.
    public let detail: String?

    public init(state: String, detail: String?) {
        self.state = state
        self.detail = detail
    }

    public static let parsed = ParserStateReport(state: "parsed", detail: nil)

    /// The words the reader sees. Composed here and **carried across the wire** rather than
    /// assembled in JavaScript: the renderer draws it, the headless probe reads it, and a sentence
    /// that exists in two languages drifts in one of them.
    public var chipText: String {
        let label: String
        switch state {
        case "parsed": label = "parsed"
        case "partial": label = "partially parsed"
        default: label = "not parsed"
        }
        return detail.map { "parser: \(label) — \($0)" } ?? "parser: \(label)"
    }

    private enum CodingKeys: String, CodingKey { case state, detail, chipText }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encode(chipText, forKey: .chipText)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(String.self, forKey: .state)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }

    /// The state that follows from what the structural path actually did.
    ///
    /// - Parameters:
    ///   - structuralRequested: whether the reader's mode asks for structure at all. Raw is not a
    ///     failure — the file is simply not parsed in it, and saying so is more honest than leaving
    ///     the chip off and letting its absence mean two different things.
    ///   - structuralUsed: whether a structural result survived to presentation.
    ///   - degradation: the ranked condition that applies, if any (DEC-051).
    ///   - unparsedRegions / unparsedBytes: F1's counts, which only exist when the result stands.
    public static func of(structuralRequested: Bool, structuralUsed: Bool,
                          degradation: Degradation?,
                          unparsedRegions: Int = 0, unparsedBytes: Int = 0) -> ParserStateReport {
        guard structuralRequested else {
            return ParserStateReport(state: "not-parsed", detail: "raw mode does not parse the file")
        }
        guard structuralUsed else {
            return ParserStateReport(state: "not-parsed",
                                     detail: degradation?.reason ?? "structural analysis unavailable")
        }
        if unparsedRegions > 0 {
            let regions = unparsedRegions == 1 ? "1 region" : "\(unparsedRegions) regions"
            return ParserStateReport(state: "partial",
                                     detail: "\(regions), \(unparsedBytes) bytes shown without a structural claim")
        }
        // A condition that is not about parsing — F8's filter, F6's unverified — leaves the parser
        // state alone. Reporting "not parsed" for a file that parsed perfectly would make the
        // indicator agree with the notice bar and disagree with the truth.
        return .parsed
    }
}

/// The mode pill's words, given what the reader selected and which path was actually taken.
///
/// `23b-…` §2 records the defect this closes: the pill read the reader's *selection*, so
/// `mode: structural` could sit beside a notice saying structural analysis was unavailable. The two
/// facts are different and both are worth having — the selection is what ⌘1–3 will return to, the
/// path is what is on screen — so neither replaces the other and the pill states both when they
/// disagree.
/// - Parameter pathTaken: `structural` or `raw` — the two code paths of DEC-013, not the three
///   modes. The comparison is against the path the *selection implies*, which is the distinction
///   the first version of this function missed: Expanded is a presentation flag over the structural
///   path, so an Expanded selection rendered structurally is agreement, and saying
///   `mode: expanded — showing structural` was a disagreement invented by the wording.
public func modeChipText(selected: String, pathTaken: String?) -> String {
    guard let pathTaken, pathTaken != impliedPath(ofMode: selected) else { return "mode: \(selected)" }
    return "mode: \(selected) — showing \(pathTaken)"
}

/// Which of DEC-013's **two code paths** a mode asks for. Three modes, two paths — the mapping is
/// the whole of DEC-013 and it is stated once.
public func impliedPath(ofMode mode: String) -> String {
    mode == "raw" ? "raw" : "structural"
}
