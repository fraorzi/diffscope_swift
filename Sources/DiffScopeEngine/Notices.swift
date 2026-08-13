import Foundation

/// Every visible failure states three things (`13-error-and-fallback-model.md` §6): **what** was
/// withheld, **why**, and **what remains trustworthy**.
///
/// The third is the one usually omitted and the one that matters most here. "Could not parse this
/// file" leaves a reader unsure whether the diff is complete; this product's whole claim is that it
/// is. Building the sentence in one place is what keeps it reading the same way everywhere — and
/// makes the three parts checkable rather than a matter of who wrote which string.
/// **The words are DEC-077's, and the three parts are `13-…`'s.** *Structural analysis unavailable*
/// is a sentence about the tool's machinery, written for a reader auditing a diff engine; the reader
/// this is for wants to know what they are looking at. So the subject is the file and the verb is
/// what the window did with it — and the *why* and the *what remains* are unchanged, because they
/// are the two parts a shorter sentence would drop.
///
/// This is the one technical statement DEC-077 keeps. Everything else the pane said about its own
/// machinery is gone; this stays because *silent and right* and *silent and wrong* look identical,
/// and it is INV-4 — every fallback is marked as a fallback — made visible.
public func fallbackNotice(reason: String) -> String {
    let why = reason.isEmpty ? "it could not be read as code" : reason
    return "This file is shown as plain text — \(why). Every difference in it is still shown."
}

/// The same form for a result that was computed and then thrown away, which is a different event: a
/// reader who sees this should know the tool caught itself, not that the file was unusual.
public func discardedNotice(reason: String) -> String {
    "This file is shown as plain text — the structural reading failed the tool's own checks "
        + "(\(reason)). Every difference in it is still shown."
}
