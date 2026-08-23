import Foundation

/// How far a mark may be widened to finish the word it cut. A word longer than this is not a word
/// a reader loses track of; it is a URL or a base64 blob, and dragging the mark across all of it
/// would show more than the change.
public let wordSnapBudget = 24

/// A hyphen is part of a word **only where there is no grammar to say otherwise** (DEC-107).
///
/// In TypeScript `a-b` is a subtraction and joining its operands would be a claim about code. In a
/// `.css` file, `--animated-background-active-hover` is one name and `200ms` is one value, and there
/// is no parser to tell the two cases apart — so the rule travels with the path: the structural path
/// says no, the fallback path says yes.
func isIdentifierByte(_ byte: UInt8, hyphenIsWord: Bool = false) -> Bool {
    if hyphenIsWord, byte == 0x2D { return true }
    return isIdentifierByteCore(byte)
}

private func isIdentifierByteCore(_ byte: UInt8) -> Bool {
    (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
        || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte == 0x24 || byte >= 0x80
}

/// Inside a string, everything that is not whitespace and not the quote itself. `md:hover:bg-red-500`
/// is one word to the reader and thirteen tokens to the language; the reader is who this is for.
func isStringWordByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x20, 0x09, 0x0A, 0x0D, 0x22, 0x27, 0x60: return false
    default: return true
    }
}

/// Finishes the word a mark cut in half (DEC-100, shape `shredded-word`).
///
/// The corpus survey over 4016 real changes reports this as one of the two shapes that recur in
/// nearly half of all pairs. Its cause is not the alignment: `bg-opacity-30` becoming `bg-black/50`
/// shares the leading `bg-`, so a minimal diff *correctly* starts the change at `o`, and
/// `snapPresentation` cannot rescue it because the only syntax boundaries inside a string literal
/// are the quotes — which the 16-byte budget will not reach on a 130-byte class attribute.
///
/// **Monotone, so INV-2 survives by construction**, exactly as DEC-021's grapheme snap and DEC-047's
/// syntax snap do: a presented range only ever grows, so a canonical changed byte that was contained
/// stays contained. The theorem the absorption pass needed does not apply here and is not claimed:
/// widening *can* add a line to `changedLines`, in the one case where a word straddles a line
/// terminator — which it cannot, because a terminator is not a word byte on either rule.
///
/// Two rules, chosen by where the edge falls:
///
/// - **inside a string or template literal**, a word runs from whitespace to whitespace, so a class
///   name, a URL segment or a path is finished whole;
/// - **anywhere else**, a word is the language's identifier rule, so `t⟧ransition` is finished and
///   `a-b` is not — a hyphen is a minus sign outside a string, and joining the two operands of a
///   subtraction would be a claim about code rather than about a name.
///
/// The budget is per edge and bounded by the word itself, so unlike a snap budget it cannot be
/// spent spilling into neighbouring content: there is nothing to spill into but more of the word.
public func snapToWordBoundaries(
    _ partition: Partition,
    bytes: [UInt8],
    stringRegions regions: [(start: Int, end: Int)],
    budget: Int = wordSnapBudget,
    hyphenIsWord: Bool = false
) -> Partition {
    guard budget > 0, !bytes.isEmpty else { return partition }
    let presented = partition.segments.filter(\.isPresented).map { (start: $0.start, end: $0.end) }
    guard !presented.isEmpty else { return partition }

    func inString(_ offset: Int) -> Bool {
        var low = 0
        var high = regions.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if regions[mid].end <= offset { low = mid + 1 }
            else if regions[mid].start > offset { high = mid - 1 }
            else { return true }
        }
        return false
    }

    func isWord(_ offset: Int, string: Bool) -> Bool {
        guard offset >= 0, offset < bytes.count else { return false }
        return string ? isStringWordByte(bytes[offset])
                      : isIdentifierByte(bytes[offset], hyphenIsWord: hyphenIsWord)
    }

    var widened: [(start: Int, end: Int)] = []
    for range in presented {
        var start = range.start
        var end = range.end
        let startInString = inString(start)
        if isWord(start - 1, string: startInString), isWord(start, string: startInString) {
            var candidate = start
            while candidate > 0, start - candidate < budget,
                  isWord(candidate - 1, string: startInString) { candidate -= 1 }
            if start - candidate < budget { start = candidate }
        }
        let endInString = inString(max(0, end - 1))
        if isWord(end - 1, string: endInString), isWord(end, string: endInString) {
            var candidate = end
            while candidate < bytes.count, candidate - end < budget,
                  isWord(candidate, string: endInString) { candidate += 1 }
            if candidate - end < budget { end = candidate }
        }
        widened.append((start, end))
    }

    widened.sort { $0.start < $1.start }
    var merged: [(start: Int, end: Int)] = []
    for range in widened {
        if let last = merged.last, range.start <= last.end {
            merged[merged.count - 1] = (last.start, max(last.end, range.end))
        } else {
            merged.append(range)
        }
    }
    return widenPresented(partition, to: merged)
}

/// Merges two marks that meet **inside a word**, so `⟦t⟧⟦ransition⟧` is one mark (DEC-100, shape
/// `split-mark`).
///
/// `coalesceAdjacent` already merges neighbours that make the same claim, and refuses three cases on
/// purpose: a differing `disclosure`, a differing `link`, and a junction crossing `confidenceFloor`.
/// The third is what leaves this shred behind — `reconcile` gives a byte the canonical mask claims
/// but no anchor explains a confidence of 0.6, so a one-byte sliver of a word ends up below the
/// floor while the rest of the word sits above it. The corpus reports 30942 such junctions across
/// 4016 changes: it is the most frequent shape in the survey by a factor of two.
///
/// **The refusal is right at every junction except this one.** The floor is the line the interface
/// reads, and merging across it does spread doubt onto bytes that were attributed cleanly. What
/// makes a word different is that the *claim itself* is not divisible there: nothing in the file
/// distinguishes the `t` of `transition` from its `ransition`, so two marks do not report two facts,
/// they report one fact twice. The merge takes the **lower** confidence, which is the direction that
/// shows the reader more doubt rather than less — `⟦~transition⟧`, not `⟦transition⟧`.
///
/// Nothing else is loosened: `disclosure` and `link` still refuse, and a junction that falls between
/// words — at a space, a quote, a brace — is left to `coalesceAdjacent` exactly as before.
public func coalesceAcrossWords(
    _ partition: Partition,
    bytes: [UInt8],
    stringRegions regions: [(start: Int, end: Int)],
    hyphenIsWord: Bool = false
) -> Partition {
    guard partition.segments.count > 1, !bytes.isEmpty else { return partition }

    func inString(_ offset: Int) -> Bool {
        var low = 0
        var high = regions.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if regions[mid].end <= offset { low = mid + 1 }
            else if regions[mid].start > offset { high = mid - 1 }
            else { return true }
        }
        return false
    }

    /// True when `offset` falls strictly inside a word: the byte before and the byte at it are both
    /// word bytes under the rule that applies where the junction is.
    func insideWord(_ offset: Int) -> Bool {
        guard offset > 0, offset < bytes.count else { return false }
        let string = inString(offset)
        let before = bytes[offset - 1]
        let at = bytes[offset]
        return string
            ? isStringWordByte(before) && isStringWordByte(at)
            : isIdentifierByte(before, hyphenIsWord: hyphenIsWord)
                && isIdentifierByte(at, hyphenIsWord: hyphenIsWord)
    }

    var out: [Segment] = []
    for segment in partition.segments {
        guard let last = out.last, last.isPresented, segment.isPresented,
              last.end == segment.start, last.label == segment.label,
              last.disclosure == segment.disclosure, last.link == segment.link,
              insideWord(segment.start)
        else {
            out.append(segment)
            continue
        }
        out[out.count - 1] = Segment(
            start: last.start, end: segment.end, label: last.label,
            classification: last.classification == segment.classification ? last.classification : nil,
            disclosure: last.disclosure,
            confidence: min(last.confidence ?? 1, segment.confidence ?? 1),
            link: last.link
        )
    }
    return Partition(totalLength: partition.totalLength, segments: out)
}
