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

    public var group: ClassificationGroup {
        switch self {
        case .whitespace, .quoteStyle, .trailingComma, .parenOnly:
            return .formattingOnly
        case .reordering:
            return .potentiallyBehaviorAffecting
        }
    }
}

public func classificationGroup(of name: String?) -> String? {
    guard let name, let known = ChangeClass(rawValue: name) else { return nil }
    return known.group.rawValue
}

public func segmentCount(in partition: Partition, group: ClassificationGroup) -> Int {
    partition.segments.filter { classificationGroup(of: $0.classification) == group.rawValue }.count
}
