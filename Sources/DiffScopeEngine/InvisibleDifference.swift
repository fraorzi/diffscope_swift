import Foundation

/// Differences that are real in the bytes and absent on screen (DEC-023). A change marked but
/// not visible reads as a tool defect, so the tool has to say which kind of nothing you are
/// looking at. Homoglyphs are deliberately out of scope — they need UTS #39.
public enum InvisibleDifference: String, Sendable, Equatable, CaseIterable {
    case normalizationForm = "normalization-form"
    case invisibleControl = "invisible-control"
    case whitespaceLookalike = "whitespace-lookalike"
}

/// Zero-width and bidirectional controls. The bidi entries are also the Trojan Source
/// (CVE-2021-42574) mechanism: source that renders differently from how it compiles.
public let invisibleControlScalars: Set<Unicode.Scalar> = [
    "\u{00AD}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
    "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
    "\u{2060}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}", "\u{FEFF}",
]

/// Space characters that are not U+0020 and read as one.
public let whitespaceLookalikeScalars: Set<Unicode.Scalar> = [
    "\u{00A0}", "\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}",
    "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{202F}",
    "\u{205F}", "\u{3000}",
]

/// Swift's `String` equality is *canonical equivalence*, so `nfc(text) != text` is always
/// false and every comparison here would quietly answer the wrong question. Comparing scalar
/// arrays is the only way to ask about the actual code points — the same hazard DEC-021 was
/// written about, resurfacing inside the detector for it.
private func scalars(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }

/// Classifies one aligned pair of changed spans by *why it is invisible*, or `nil` when the
/// change is something a reader can actually see.
public func invisibleDifference(old: [UInt8], new: [UInt8]) -> InvisibleDifference? {
    guard old != new,
          let oldText = String(bytes: old, encoding: .utf8),
          let newText = String(bytes: new, encoding: .utf8)
    else { return nil }

    if scalars(oldText.precomposedStringWithCanonicalMapping)
        == scalars(newText.precomposedStringWithCanonicalMapping) {
        return .normalizationForm
    }

    let oldScalars = Set(oldText.unicodeScalars)
    let newScalars = Set(newText.unicodeScalars)
    let involved = oldScalars.symmetricDifference(newScalars)
    guard !involved.isEmpty else { return nil }

    func strip(_ text: String, _ removable: Set<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !removable.contains($0) }))
    }

    if !involved.isDisjoint(with: invisibleControlScalars),
       scalars(strip(oldText, invisibleControlScalars)) == scalars(strip(newText, invisibleControlScalars)) {
        return .invisibleControl
    }

    // Tab against spaces counts here too: both render as horizontal blank, and which one it is
    // decides nothing a reader can see at a glance.
    let spaceLike = whitespaceLookalikeScalars.union([" ", "\t"])
    if !involved.isDisjoint(with: spaceLike) {
        func collapse(_ text: String) -> String {
            var out = String.UnicodeScalarView()
            var pending = false
            for scalar in text.unicodeScalars {
                if spaceLike.contains(scalar) { pending = true; continue }
                if pending { out.append(" "); pending = false }
                out.append(scalar)
            }
            if pending { out.append(" ") }
            return String(out)
        }
        if scalars(collapse(oldText)) == scalars(collapse(newText)) { return .whitespaceLookalike }
    }

    return nil
}

/// True when a text is not in composed form — asked scalar-wise, for the reason above.
public func isDecomposed(_ text: String) -> Bool {
    scalars(text.precomposedStringWithCanonicalMapping) != scalars(text)
}

/// The codepoints worth naming inside a disclosed region, in order, as `U+XXXX` text.
public func revealedCodepoints(in bytes: [UInt8]) -> [String] {
    guard let text = String(bytes: bytes, encoding: .utf8) else { return [] }
    var out: [String] = []
    for scalar in text.unicodeScalars
    where invisibleControlScalars.contains(scalar)
        || whitespaceLookalikeScalars.contains(scalar)
        || (scalar.properties.canonicalCombiningClass != .notReordered) {
        out.append(String(format: "U+%04X", scalar.value))
    }
    return out
}
