import Foundation

/// The failure taxonomy of `13-error-and-fallback-model.md` §2, with the precedence of §5 attached
/// to it as data.
///
/// §5, transcribed verbatim so that editing one without the other is visible:
///
/// > When multiple conditions apply, the **most conservative** wins. Precedence, highest first:
/// >
/// >     F10 stale pin  →  F9 binary  →  F8 filter  →  F5 invariant violation
/// >     →  F2 whole-file parse failure  →  F7 unsupported  →  F6 unverified
/// >     →  F3/F4 confidence/ambiguity  →  F1 partial parse error
///
/// Precedence is **not** evaluation order, and conflating the two is the trap this type exists to
/// remove. Evaluation order is chosen by cost — the DEC-050 size gate fires before parsing because
/// parsing a 31 MB bundle costs a second — while precedence decides *which reason is shown* when
/// several conditions hold at once. Before this type they were the same list, so a binary `.png`
/// was reported as "unsupported language": true, but the milder of the two true statements.
///
/// Every case ends in raw. The rank never changes what is shown, only what is said about it — and
/// under INV-4 what is said about it is the whole of the guarantee.
public enum Degradation: Sendable, Equatable {
    /// F10 — the pinned pair could not be read without a write racing it (DEC-049).
    case stalePin(reason: String)
    /// F9 — binary or otherwise non-text content. Invalid UTF-8 is mapped here: it is not a row of
    /// its own in §2, and "content this tool cannot treat as text" is exactly what F9 names.
    case binary(reason: String)
    /// F8 — a Git filter is active for the path (DEC-028), so the compared bytes and `git diff`'s
    /// bytes need not agree and no structural claim is made.
    case filterActive(reason: String)
    /// F5 — the structural result failed the invariant checks and was discarded whole (DEC-022).
    case invariantViolation(reason: String)
    /// F2 — no usable tree for the whole file. Merge-conflict markers are mapped here: the file is
    /// not source, which is the same condition a parse failure reports.
    case parseFailure(reason: String)
    /// F7 — the language has no structural support. An ordinary labelled state, not an error.
    case unsupportedLanguage(reason: String)
    /// F16 — a structural budget was exceeded (DEC-050). Added to the taxonomy by DEC-051: §2 was
    /// written before the budgets existed, and a condition with no row cannot be given a rank.
    ///
    /// Ranked below F7 deliberately. For a file whose language has no structural support the size
    /// is beside the point — it would be raw at any size — so "unsupported" is the more useful of
    /// two true statements.
    case budgetExceeded(reason: String)
    /// F6 — the independent cross-check did not run (DEC-040 as amended by DEC-043). The file is
    /// **unverified**, which is not the same as suspect.
    case unverified(reason: String)
    /// F3/F4 — confidence below the floor, or a match the matcher will not resolve arbitrarily.
    case lowConfidence(reason: String)
    /// F1 — a parse error in part of a file; the clean regions stay structural.
    case partialParseError(reason: String)

    public var code: String {
        switch self {
        case .stalePin: return "F10"
        case .binary: return "F9"
        case .filterActive: return "F8"
        case .invariantViolation: return "F5"
        case .parseFailure: return "F2"
        case .unsupportedLanguage: return "F7"
        case .budgetExceeded: return "F16"
        case .unverified: return "F6"
        case .lowConfidence: return "F3/F4"
        case .partialParseError: return "F1"
        }
    }

    /// Lower is more conservative. Dense and gapless, so a new row cannot be added without deciding
    /// where it sits.
    public var rank: Int {
        switch self {
        case .stalePin: return 0
        case .binary: return 1
        case .filterActive: return 2
        case .invariantViolation: return 3
        case .parseFailure: return 4
        case .unsupportedLanguage: return 5
        case .budgetExceeded: return 6
        case .unverified: return 7
        case .lowConfidence: return 8
        case .partialParseError: return 9
        }
    }

    public var reason: String {
        switch self {
        case let .stalePin(reason), let .binary(reason), let .filterActive(reason),
             let .invariantViolation(reason), let .parseFailure(reason),
             let .unsupportedLanguage(reason), let .budgetExceeded(reason),
             let .unverified(reason), let .lowConfidence(reason),
             let .partialParseError(reason):
            return reason
        }
    }

    /// The sentence a reader sees, in the three-part form of §6. An invariant violation is a
    /// different event from an unavailable analysis — the tool caught itself rather than met an
    /// unusual file — so it keeps its own opening clause.
    public var notice: String {
        switch self {
        case .invariantViolation: return discardedNotice(reason: reason)
        default: return fallbackNotice(reason: reason)
        }
    }

    /// The most conservative condition of those that apply, or `nil` when none do.
    ///
    /// Ties are impossible by construction: ranks are distinct per case, so two conditions of the
    /// same kind resolve to the first offered, which is the order the caller gathered them in.
    public static func mostConservative(_ candidates: [Degradation]) -> Degradation? {
        candidates.min { $0.rank < $1.rank }
    }

    /// Every case, for checks that must cover the whole vocabulary rather than the cases someone
    /// remembered. A new case that is not added here fails the totality check.
    public static let all: [Degradation] = [
        .stalePin(reason: ""), .binary(reason: ""), .filterActive(reason: ""),
        .invariantViolation(reason: ""), .parseFailure(reason: ""),
        .unsupportedLanguage(reason: ""), .budgetExceeded(reason: ""),
        .unverified(reason: ""), .lowConfidence(reason: ""),
        .partialParseError(reason: ""),
    ]
}
