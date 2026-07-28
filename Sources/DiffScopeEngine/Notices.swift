import Foundation

/// Every visible failure states three things (`13-error-and-fallback-model.md` §6): **what** was
/// withheld, **why**, and **what remains trustworthy**.
///
/// The third is the one usually omitted and the one that matters most here. "Could not parse this
/// file" leaves a reader unsure whether the diff is complete; this product's whole claim is that it
/// is. Building the sentence in one place is what keeps it reading the same way everywhere — and
/// makes the three parts checkable rather than a matter of who wrote which string.
public func fallbackNotice(reason: String) -> String {
    let why = reason.isEmpty ? "structural analysis was unavailable" : reason
    return "Structural analysis unavailable — \(why). All textual differences are shown."
}

/// The same form for a result that was computed and then thrown away, which is a different event: a
/// reader who sees this should know the tool caught itself, not that the file was unusual.
public func discardedNotice(reason: String) -> String {
    "Structural analysis discarded — it failed its own checks (\(reason)). All textual differences are shown."
}
