import DiffScopeEngine
import DiffScopeSyntax
import Foundation

/// DEC-087. Myers does not choose among equally-minimal alignments; these are the properties of the
/// choice this repository now makes, and the ones it must not buy it with.
func runAlignmentChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    func hunks(_ old: String, _ new: String) -> [Hunk] {
        guard case let .exact(result) = canonicalDiff(old: [UInt8](old.utf8), new: [UInt8](new.utf8))
        else { return [] }
        return result
    }
    func wholeLines(_ hunks: [Hunk], _ old: String, _ new: String) -> Bool {
        let a = [UInt8](old.utf8), b = [UInt8](new.utf8)
        func aligned(_ buffer: [UInt8], _ start: Int, _ end: Int) -> Bool {
            guard start == 0 || buffer[start - 1] == 0x0A else { return false }
            return end == start || end == 0 || buffer[end - 1] == 0x0A
        }
        return hunks.allSatisfy {
            aligned(a, $0.oldStart, $0.oldEnd) && aligned(b, $0.newStart, $0.newEnd)
        }
    }

    print("\n=== DEC-087: the alignment lands on line boundaries ===")
    do {
        // The owner's first case. The byte-level common prefix runs through the shared word
        // `import `, so before this the untouched second line read as removed-and-re-added.
        let old = "import clsx from 'clsx';\n\nimport ButtonLink from './ButtonLink';\n"
        let new = "import clsx from 'clsx';\n\nimport styles from './styles.css';\n\n"
            + "import ButtonLink from './ButtonLink';\n"
        let result = hunks(old, new)
        report("an insertion before a line starting with the same word covers whole lines",
               wholeLines(result, old, new), result.map(\.description).joined(separator: " "))
        report("and the untouched line is outside every hunk",
               result.allSatisfy { hunk in
                   let text = String(decoding: [UInt8](new.utf8)[hunk.newStart..<hunk.newEnd], as: UTF8.self)
                   return !text.contains("ButtonLink")
               })

        // The owner's third case: the shared leading indentation, which put the highlight on the
        // *next* line's whitespace.
        let oldMember = "export interface P {\n  title?: string;\n  text: string;\n}\n"
        let newMember = "export interface P {\n  title?: string;\n  hasDivider?: boolean;\n"
            + "  text: string;\n}\n"
        let members = hunks(oldMember, newMember)
        report("an insertion sharing its indentation covers whole lines",
               wholeLines(members, oldMember, newMember),
               members.map(\.description).joined(separator: " "))
        report("and no hunk ends inside the following line's indentation",
               members.allSatisfy { hunk in
                   let text = String(decoding: [UInt8](newMember.utf8)[hunk.newStart..<hunk.newEnd],
                                     as: UTF8.self)
                   return !text.contains("text:")
               })
    }

    print("\n=== and does not invent one where none is reachable ===")
    do {
        // A single token inside a line: every shift is blocked, so the alignment must stay exactly
        // where Myers put it rather than growing to the whole line.
        let old = "const total = alpha + beta;\n"
        let new = "const total = gamma + beta;\n"
        let result = hunks(old, new)
        let bytes = [UInt8](new.utf8)
        report("a mid-line edit stays a mid-line edit",
               !result.isEmpty && result.allSatisfy { $0.newStart > 0 && bytes[$0.newStart - 1] != 0x0A },
               result.map(\.description).joined(separator: " "))
        report("and it presents only the token that changed, not the line holding it",
               result.reduce(0) { $0 + ($1.newEnd - $1.newStart) } <= "gamma".utf8.count,
               result.map(\.description).joined(separator: " "))
    }

    print("\n=== the shift keeps the diff minimal and the partition whole ===")
    do {
        // Minimality is asserted against a brute-force LCS on random pairs elsewhere in this suite.
        // What belongs here is the structural property the shift could break: matches and hunks
        // still tile both files, with no overlap and no gap.
        var generator = SystemRandomNumberGenerator()
        var tiled = true
        var covered = true
        for _ in 0..<200 {
            let alphabet = Array("ab \n;xy")
            func sample() -> [UInt8] {
                [UInt8](String((0..<Int.random(in: 1...80, using: &generator)).map { _ in
                    alphabet.randomElement(using: &generator)!
                }).utf8)
            }
            let a = sample(), b = sample()
            let matches = canonicalMatches(old: a, new: b).matches
            guard case let .exact(result) = canonicalDiff(old: a, new: b) else { continue }

            var oldCursor = 0, newCursor = 0
            for match in matches {
                if match.oldStart < oldCursor || match.newStart < newCursor { tiled = false }
                guard match.length > 0 else { tiled = false; continue }
                if Array(a[match.oldStart..<match.oldStart + match.length])
                    != Array(b[match.newStart..<match.newStart + match.length]) { tiled = false }
                oldCursor = match.oldStart + match.length
                newCursor = match.newStart + match.length
            }
            // Every byte is either inside a match or inside a hunk, and never inside both.
            var accounted = Set<Int>()
            for match in matches { for i in 0..<match.length { accounted.insert(match.oldStart + i) } }
            for hunk in result { for i in hunk.oldStart..<hunk.oldEnd {
                if accounted.contains(i) { covered = false }
                accounted.insert(i)
            } }
            if accounted.count != a.count { covered = false }
        }
        report("every match is still a real match, in order", tiled)
        report("every old byte is in exactly one of a match or a hunk", covered)
    }

    print("\n=== a boundary already on a line boundary is not widened ===")
    do {
        guard let parser = TSXParser() else { report("parser for the alignment checks", false); return }
        let source = [UInt8]("const alpha = 1;\nconst beta = 2;\n".utf8)
        guard let tree = parser.parseTree(source) else { report("alignment fixture parses", false); return }
        let boundaries = SyntaxBoundaries(tree: tree)

        // Line 2 in full: already whole-line, so the pass has nothing to rescue.
        let kept = snapToBoundaries([(17, 33)], boundaries: boundaries, budget: 16, bytes: source)
        report("a whole-line range is left exactly as it is", kept.map(\.start) == [17]
                   && kept.map(\.end) == [33], "\(kept)")

        // Mid-token, which is what the budget is for. Widening still happens there.
        let widened = snapToBoundaries([(23, 26)], boundaries: boundaries, budget: 16, bytes: source)
        report("a mid-structure range is still widened onto boundaries",
               widened.count == 1 && (widened[0].start < 23 || widened[0].end > 26), "\(widened)")

        // Without the bytes there is no line to be on, and the pass behaves as it always did.
        let legacy = snapToBoundaries([(17, 33)], boundaries: boundaries, budget: 16)
        report("the guard needs the bytes, and says so by doing nothing without them",
               legacy.count == 1)
    }

    print("\n=== DEC-093: a lexical rank below the line rank ===")
    do {
        func unshifted(_ old: String, _ new: String) -> [Hunk] {
            guard case let .exact(result) = canonicalDiff(old: [UInt8](old.utf8),
                                                          new: [UInt8](new.utf8), applyShift: false)
            else { return [] }
            return result
        }
        func newText(_ hunks: [Hunk], _ new: String) -> [String] {
            let bytes = [UInt8](new.utf8)
            return hunks.map { String(decoding: bytes[$0.newStart..<$0.newEnd], as: UTF8.self) }
        }

        // The owner's fifth case, and the one no line boundary can reach: a union member inserted
        // between two others. Myers anchors after the shared `'`, so the mark reads `compact' | '`
        // and the apostrophe of `'wide'` — a byte nobody touched — is drawn as changed.
        let oldUnion = "  TextColumnSize: 'base' | 'wide';\n"
        let newUnion = "  TextColumnSize: 'base' | 'compact' | 'wide';\n"
        report("an inserted union member is presented as whole tokens",
               newText(hunks(oldUnion, newUnion), newUnion) == ["'compact' | "],
               "\(newText(hunks(oldUnion, newUnion), newUnion))")
        report("negative control: without the shift it lands where Myers put it",
               newText(unshifted(oldUnion, newUnion), newUnion) == ["compact' | '"],
               "\(newText(unshifted(oldUnion, newUnion), newUnion))")

        let oldSize = "  TitleSize: 'XL' | 'XXL';\n"
        let newSize = "  TitleSize: 'L' | 'XL' | 'XXL';\n"
        report("and so is one inserted at the head of the union",
               newText(hunks(oldSize, newSize), newSize) == ["'L' | "],
               "\(newText(hunks(oldSize, newSize), newSize))")

        // Rank before position. Both of DEC-087's cases sit at shift 0 already, and a lexical
        // candidate one byte away must not be allowed to pull them off a line boundary — the
        // regression this rank order exists to prevent, and the reason shift 0 is scored.
        let oldMember = "function f({\n  a = 'x',\n}: P) {\n  return 1;\n}\n"
        let newMember = "function f({\n  a = 'x',\n  b = false,\n}: P) {\n  const q = 1;\n\n  return 1;\n}\n"
        let members = hunks(oldMember, newMember)
        report("a whole-line position still outranks a lexical one",
               wholeLines(members, oldMember, newMember),
               members.map(\.description).joined(separator: " "))
        report("and the line above the insertion keeps no mark",
               newText(members, newMember).allSatisfy { !$0.contains("a = 'x'") },
               "\(newText(members, newMember))")

        // Shift 0 survives where nothing is reachable: DEC-087's rule 3, which rank 2 must not
        // quietly repeal. The hunk is byte-identical with the shift on and off.
        let oldToken = "const total = alpha + beta;\n"
        let newToken = "const total = gamma + beta;\n"
        report("a mid-token edit is not moved by the lexical rank either",
               hunks(oldToken, newToken) == unshifted(oldToken, newToken),
               hunks(oldToken, newToken).map(\.description).joined(separator: " "))

        // `\r` and `\n` are the same class, so no boundary can be invented between them.
        let oldCRLF = "a\r\nb\r\n"
        let newCRLF = "a\r\nx\r\nb\r\n"
        let crlf = hunks(oldCRLF, newCRLF)
        report("no hunk boundary falls between a CR and its LF",
               crlf.allSatisfy { hunk in
                   let bytes = [UInt8](newCRLF.utf8)
                   func safe(_ at: Int) -> Bool {
                       at == 0 || at == bytes.count || !(bytes[at - 1] == 0x0D && bytes[at] == 0x0A)
                   }
                   return safe(hunk.newStart) && safe(hunk.newEnd)
               }, crlf.map(\.description).joined(separator: " "))

        // Bytes at or above 0x80 are word bytes, so a class transition never falls inside a UTF-8
        // sequence. `D` has never promised scalar boundaries — Myers cuts wherever minimality says
        // and `snapToGraphemeBoundaries` repairs it afterwards (DEC-021) — so what is asserted here
        // is the property the rank is responsible for: the shift never moves a boundary *into* a
        // character it was clear of.
        var generator = SystemRandomNumberGenerator()
        var scalarSafe = true
        var matchedEqual = true
        for _ in 0..<200 {
            let alphabet = Array("ab ;'|_$\nżąć😀🙂")
            func sample() -> String {
                String((0..<Int.random(in: 1...60, using: &generator)).map { _ in
                    alphabet.randomElement(using: &generator)!
                })
            }
            let a = sample(), b = sample()
            let bytes = [UInt8](b.utf8)
            var scalarStarts = Set([0, bytes.count])
            var offset = 0
            for scalar in b.unicodeScalars {
                offset += String(scalar).utf8.count
                scalarStarts.insert(offset)
            }
            func cuts(_ hunks: [Hunk]) -> Int {
                hunks.reduce(0) {
                    $0 + (scalarStarts.contains($1.newStart) ? 0 : 1)
                       + (scalarStarts.contains($1.newEnd) ? 0 : 1)
                }
            }
            if cuts(hunks(a, b)) > cuts(unshifted(a, b)) { scalarSafe = false }
            // Minimality is invariant under the shift: it moves both ends of a hunk by the same
            // amount, so the total matched length cannot change. Asserted directly rather than
            // inferred from the LCS check, which runs on a different alphabet.
            let shifted = canonicalMatches(old: [UInt8](a.utf8), new: bytes).matches
            let plain = canonicalMatches(old: [UInt8](a.utf8), new: bytes, applyShift: false).matches
            if shifted.reduce(0, { $0 + $1.length }) != plain.reduce(0, { $0 + $1.length }) {
                matchedEqual = false
            }
        }
        report("the shift never cuts more multi-byte characters than Myers already did", scalarSafe)
        report("and the shift leaves the total matched length exactly where it was", matchedEqual)
    }

    print("\n=== DEC-097: a short match may be consumed, a long one may not ===")
    do {
        // The owner's fourth case. A parameter added to a signature and a block added to the body,
        // with `}: P) {` between them: the match holding that line is too short for either
        // insertion to shift within, so the alignment used to anchor on its `{` and the untouched
        // line read as edited.
        let old = "function f({\n  a = 1,\n}: P) {\n  return 1;\n}\n"
        let new = "function f({\n  a = 1,\n  b = 2,\n}: P) {\n  const q = 0;\n\n  return 1;\n}\n"
        let result = hunks(old, new)
        report("an insertion either side of a short match covers whole lines",
               wholeLines(result, old, new), result.map(\.description).joined(separator: " "))
        report("and the line between them carries no hunk at all",
               result.allSatisfy { hunk in
                   let text = String(decoding: [UInt8](new.utf8)[hunk.newStart..<hunk.newEnd],
                                     as: UTF8.self)
                   return !text.contains("}: P) {")
               },
               result.map { String(decoding: [UInt8](new.utf8)[$0.newStart..<$0.newEnd], as: UTF8.self) }
                   .joined(separator: " | "))

        // The bound has to bind, or it is not a bound. A long match between two changes stays a
        // match: consuming it would relocate presented bytes across content nobody touched.
        let spacer = String(repeating: "  keep = 1;\n", count: 8)
        let oldLong = "let a = 1;\n" + spacer + "let b = 2;\n"
        let newLong = "let A = 1;\n" + spacer + "let B = 2;\n"
        let long = hunks(oldLong, newLong)
        report("negative control: a match longer than the floor is not consumed",
               long.count == 2, long.map(\.description).joined(separator: " "))
        report("and none of the untouched lines between them is inside a hunk",
               long.allSatisfy { hunk in
                   !String(decoding: [UInt8](newLong.utf8)[hunk.newStart..<hunk.newEnd], as: UTF8.self)
                       .contains("keep")
               })

        // The legality argument, asserted rather than reasoned: consuming moves the boundary between
        // the hunk and *each* of its neighbours by the same amount, so the matched total cannot move.
        var generator = SystemRandomNumberGenerator()
        var preserved = true
        for _ in 0..<300 {
            let alphabet = Array("ab \n;{}xy")
            func sample() -> [UInt8] {
                [UInt8](String((0..<Int.random(in: 1...90, using: &generator)).map { _ in
                    alphabet.randomElement(using: &generator)!
                }).utf8)
            }
            let a = sample(), b = sample()
            let shifted = canonicalMatches(old: a, new: b).matches
            let plain = canonicalMatches(old: a, new: b, applyShift: false).matches
            if shifted.reduce(0, { $0 + $1.length }) != plain.reduce(0, { $0 + $1.length }) {
                preserved = false
            }
            if shifted.contains(where: { $0.length <= 0 }) { preserved = false }
        }
        report("consuming a match leaves the total matched length where it was, and drops the match",
               preserved)
    }
    print("\n=== DEC-124: the consume floor, and the sweep that chose it ===")
    do {
        // The value is a measurement, so the check is that the measurement is still reachable and
        // that the two computations of `D` agree about it. `matchConsumeFloor` is a global `let`
        // rather than a setting for exactly that reason: the model and `Validation` derive `D`
        // independently (DEC-039), and a floor that differed between them would make INV-2 fail for
        // a reason that is not a defect.
        report("the floor is the value DEC-124 measured", matchConsumeFloor == 16,
               "\(matchConsumeFloor)")

        // A pair the floor decides: two insertions with a short match between them. At a floor
        // below the match's length the match survives and the reader is shown two marks with an
        // island; at or above it the shift may consume it and show one.
        let old = [UInt8]("const value = alpha;\n".utf8)
        let new = [UInt8]("const value = alphaXXXbetaYYYalpha;\n".utf8)
        let model = trivialModel(oldBytes: old, newBytes: new)
        let marks = model.newPartition.segments.filter(\.isPresented).count
        report("and a pair whose alignment it decides still validates", validate(model).passed,
               "\(marks) marks")
    }
}
