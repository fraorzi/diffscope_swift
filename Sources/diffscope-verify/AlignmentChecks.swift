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
}
