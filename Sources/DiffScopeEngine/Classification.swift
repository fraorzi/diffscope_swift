import Foundation

public enum ClassificationGroup: String, Sendable, Equatable, CaseIterable {
    case formattingOnly = "formatting-only"
    case potentiallyBehaviorAffecting = "potentially-behavior-affecting"
}

public enum ChangeClass: String, Sendable, Equatable, CaseIterable {
    case whitespace = "whitespace"
    case quoteStyle = "quote-style"
    case trailingComma = "trailing-comma"
    case parenOnly = "paren-only"
    case reordering = "reordering"
    /// A run whose parts were classified as **different kinds of formatting** (DEC-120).
    ///
    /// Nothing produces it directly; it is what `mergedClassification` returns when two neighbours
    /// disagree about which formatting they are and agree that they are formatting. It exists
    /// because the alternative was `nil`, and `nil` is the same value as *nobody looked*.
    case formatting = "formatting"

    public var group: ClassificationGroup {
        switch self {
        case .whitespace, .quoteStyle, .trailingComma, .parenOnly, .formatting:
            return .formattingOnly
        case .reordering:
            return .potentiallyBehaviorAffecting
        }
    }
}

/// The classification a merged run carries when its two parts disagree (DEC-120).
///
/// Every combining pass in the pipeline — `coalesceAdjacent`, `absorbIslands`, `coalesceAcrossWords`
/// and `widenPresented` — resolved a disagreement to `nil`, and `nil` is not neutral: it is the
/// value a segment nobody classified carries, and it is drawn at full weight. So a prettier rewrap,
/// which reliably produces `whitespace` beside `trailing-comma` beside `quote-style`, lost its
/// grouping at the last pass before the screen — three claims that agree on the thing that matters
/// collapsing into no claim at all.
///
/// **The strings disagree and the groups do not.** Where both parts are known classes of the same
/// group, the run keeps the group: for formatting that is `formatting`, a class with no producer of
/// its own whose only job is to be the answer here. Where the groups differ, or either part is
/// unknown, `nil` stands — a run holding a formatting change and a behaviour-affecting one has not
/// earned either label, which is the rule DEC-045 wrote down and this does not touch.
public func mergedClassification(_ a: String?, _ b: String?) -> String? {
    if a == b { return a }
    guard let a, let b,
          let groupA = classificationGroup(of: a), let groupB = classificationGroup(of: b),
          groupA == groupB, groupA == ClassificationGroup.formattingOnly.rawValue
    else { return nil }
    return ChangeClass.formatting.rawValue
}

public func classificationGroup(of name: String?) -> String? {
    guard let name, let known = ChangeClass(rawValue: name) else { return nil }
    return known.group.rawValue
}

public func segmentCount(in partition: Partition, group: ClassificationGroup) -> Int {
    partition.segments.filter { classificationGroup(of: $0.classification) == group.rawValue }.count
}
