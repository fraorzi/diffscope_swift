import DiffScopeEngine
import DiffScopeSyntax
import Foundation

func runBudgetChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    guard let parser = TSXParser() else { report("parser for the budget checks", false); return }

    /// Wall-clock, measured rather than assumed.
    ///
    /// Two of the assertions below are about *cost*, and both were written against an absolute
    /// second. That is a bound on the machine, not on the behaviour: with four other processes
    /// saturating this one, the refusal that should take 2.0 s takes 2.3 s and the suite reports a
    /// failure while the code is doing exactly the right thing. DEC-050 rejected wall-clock
    /// deadlines for *behaviour* on precisely that reasoning, and the same shape survived inside a
    /// check of it.
    ///
    /// So each cost assertion now names a baseline measured on this machine, in this build, under
    /// whatever load is present, and asserts a **ratio**. Load inflates both numbers, so the ratio
    /// holds where the absolute does not — and the ratio is the claim anyway: *refused without
    /// parsing it* means "costs about what looking at the bytes costs", not "costs under a second".
    func measure(_ body: () -> Void) -> TimeInterval {
        let started = Date()
        body()
        return Date().timeIntervalSince(started)
    }

    print("\n=== DEC-050: the structural path has gates, and they fire before the cost does ===")
    do {
        // Two shapes with the same bytes and wildly different node counts — the reason the budget
        // is on nodes rather than bytes (`16-…` §2).
        let dense = syntheticDenseJSX(elements: 2000)
        let denseEdited = dense.replacingOccurrences(of: "item", with: "entry")
        let denseBytes = [UInt8](dense.utf8)
        // The baseline: parsing this file once. Parsing is linear and always happens; the budget
        // exists to stop the *matching* that follows, which is quadratic. A run that gave up at the
        // gate should therefore cost about what the two parses cost and nothing beyond them.
        let parseBaseline = measure { _ = parser.parseTree(denseBytes) }
        // **Build *and* validate, because that is what the reader waits for** (DEC-125). This used to
        // time `structuralDiff` alone, and timing a sub-path is how a cost gets attributed to the
        // wrong decision: the fallback's byte diff was given a tenth of the budget to keep *this*
        // number down, while `validate` went on computing the same diff at the full budget one
        // function later. The tenth bought nothing the product ever felt and cost an INV-2
        // violation on eleven real files.
        let elapsed = measure {
            let built = structuralDiff(oldPath: "dense.tsx", oldBytes: denseBytes,
                                       newPath: "dense.tsx", newBytes: [UInt8](denseEdited.utf8),
                                       parser: parser)
            _ = validate(built.model)
        }
        let result = structuralDiff(oldPath: "dense.tsx", oldBytes: denseBytes,
                                    newPath: "dense.tsx", newBytes: [UInt8](denseEdited.utf8),
                                    parser: parser)

        report("a pathologically dense file falls back rather than matching",
               result.stats.usedFallback, result.stats.fallbackReason ?? "did not fall back")
        // **Sixteen, and the number moved because the thing being measured did** (DEC-125). It was
        // four, against `structuralDiff` alone. Timed over the product path — build *and* validate,
        // which is what the reader waits for — the same file measures about ten times the parse
        // baseline: 1.12 s before DEC-125 and 1.65 s after, against 0.17 s.
        //
        // The difference is the price of the invariant. `fallbackPartitions` used a tenth of the
        // canonical budget while `validate` used all of it, so on files where `D` existed at the
        // full budget and not at a tenth the model was built from line anchors and then checked
        // against an alignment it had never seen — **eleven real files failed INV-2 that way**.
        // Equalising costs half a second on this synthetic worst case and removes the violation.
        //
        // Sixteen rather than ten, because the assertion is against a hang and the two numbers above
        // are what an ordinary machine reports under load. **The follow-up that would bring it back
        // down is to compute `D` once and hand it to both** — the independence DEC-039 requires is
        // between the *presentation path* and `D`, not between two calls to the same function.
        report("and it costs about what parsing it costs, rather than hanging",
               elapsed < parseBaseline * 16 + 0.2,
               String(format: "%.2f s against a %.2f s parse baseline", elapsed, parseBaseline))
        report("the fallback names which budget was exceeded",
               (result.stats.fallbackReason ?? "").contains("budget")
                   || (result.stats.fallbackReason ?? "").contains("limit"),
               result.stats.fallbackReason ?? "nil")
        report("and every byte still reaches the reader", validate(result.model).passed)

        // The gate must be the node count, not the byte count: a smaller file with more nodes is
        // the case a byte budget gets wrong.
        let minified = syntheticMinified(statements: 24_000)
        let minifiedEdited = minified.replacingOccurrences(of: "const a0=", with: "const a0=1+")
        let minifiedResult = structuralDiff(oldPath: "m.js", oldBytes: [UInt8](minified.utf8),
                                            newPath: "m.js", newBytes: [UInt8](minifiedEdited.utf8),
                                            parser: parser)
        report("a minified file is rejected on nodes though its bytes are modest",
               minifiedResult.stats.usedFallback
                   && [UInt8](minified.utf8).count < structuralSizeLimit,
               "\([UInt8](minified.utf8).count) bytes · \(minifiedResult.stats.fallbackReason ?? "nil")")

        let oversize = String(repeating: "const value = 1;\n", count: 200_000)
        let oversizeBytes = [UInt8](oversize.utf8)
        let oversizeNew = [UInt8]((oversize + "const tail = 2;\n").utf8)
        // Refused without building a tree, and the baseline is **the fallback it returns**.
        //
        // This used to compare against one pass over the bytes, on the reasoning that `classify`'s
        // content scan was most of the cost. DEC-095 changed what a fallback is: `trivialModel` now
        // runs a real byte diff so a whole-file fallback localises its change instead of painting
        // the file, and that diff — not the scan — is most of the 1.6 s this path takes. The old
        // baseline therefore modelled work the code no longer does, the threshold sat a hair above
        // the truth, and the check failed and passed on the same binary depending on how the scan
        // happened to time. It was intermittent for eight days and it was right to be: it was
        // measuring the wrong thing.
        //
        // Against the fallback itself the claim is exact and the margin is real: *refusing the file
        // costs no more than returning the answer it refuses to improve on*. A parse or a match
        // would show up as a multiple of it, which is what the check exists to catch.
        // The baseline is every piece of work this path is *supposed* to do, run here in the open:
        // the two content scans that rank the reason (`13-…` §5 precedence puts binary and conflicted
        // ahead of oversized, so both sides are classified before the size gate can answer), and the
        // fallback model itself. A parse or a match would be a multiple of this, which is what the
        // check is for.
        let scanBaseline = measure {
            _ = sourceDegradations(path: "big.ts", bytes: oversizeBytes)
            _ = sourceDegradations(path: "big.ts", bytes: oversizeNew)
            _ = trivialModel(oldBytes: oversizeBytes, newBytes: oversizeNew)
        }
        let oversizeElapsed = measure {
            _ = structuralDiff(oldPath: "big.ts", oldBytes: oversizeBytes,
                               newPath: "big.ts", newBytes: oversizeNew, parser: parser)
        }
        let oversizeResult = structuralDiff(oldPath: "big.ts", oldBytes: oversizeBytes,
                                            newPath: "big.ts", newBytes: oversizeNew, parser: parser)
        // A threshold nothing can exceed is not a threshold. This says what the check would cost if
        // the gate were removed, so the margin above is known to be crossable rather than assumed to
        // be — the same reason every other control in this suite exists.
        let parseCost = measure { _ = parser.parseTree(oversizeBytes) }
        report("positive control: parsing these bytes would break the threshold",
               scanBaseline + parseCost > scanBaseline * 1.3 + 0.2,
               String(format: "a parse costs %.2f s against a %.2f s margin",
                      parseCost, scanBaseline * 0.3 + 0.2))
        report("a file above the size limit is refused without parsing it",
               oversizeResult.stats.usedFallback && oversizeElapsed < scanBaseline * 1.3 + 0.2,
               String(format: "%.2f s against a %.2f s baseline of the work it must do · %@",
                      oversizeElapsed, scanBaseline, oversizeResult.stats.fallbackReason ?? "nil"))
    }

    print("\n=== a budget that rejects ordinary code is not a budget ===")
    do {
        // The negative control. This is a large hand-written-shaped component: several hundred
        // lines, ordinary JSX, the sort of file the product exists to review.
        let ordinary = syntheticDenseJSX(elements: 120)
        let edited = ordinary.replacingOccurrences(of: "className=\"item\"", with: "className=\"row\"")
        let result = structuralDiff(oldPath: "ordinary.tsx", oldBytes: [UInt8](ordinary.utf8),
                                    newPath: "ordinary.tsx", newBytes: [UInt8](edited.utf8),
                                    parser: parser)
        report("an ordinary component still takes the structural path", !result.stats.usedFallback,
               result.stats.fallbackReason ?? "")
        report("and finds anchors in it", result.stats.anchors > 0, "\(result.stats.anchors)")

        guard let tree = parser.parseTree([UInt8](ordinary.utf8)),
              let editedTree = parser.parseTree([UInt8](edited.utf8)) else {
            report("trees for the budget headroom check", false); return
        }
        let mapping = matchTrees(old: tree, new: editedTree)
        report("an ordinary file uses a small fraction of the work budget",
               mapping.workUsed * 10 < matchWorkBudget,
               "\(mapping.workUsed) of \(matchWorkBudget)")
    }

    print("\n=== T-7: giving up must be as deterministic as succeeding ===")
    do {
        let dense = syntheticDenseJSX(elements: 1200)
        let edited = dense.replacingOccurrences(of: "item", with: "entry")
        let first = structuralDiff(oldPath: "d.tsx", oldBytes: [UInt8](dense.utf8),
                                   newPath: "d.tsx", newBytes: [UInt8](edited.utf8), parser: parser)
        let second = structuralDiff(oldPath: "d.tsx", oldBytes: [UInt8](dense.utf8),
                                    newPath: "d.tsx", newBytes: [UInt8](edited.utf8), parser: parser)
        report("the same input reaches the same verdict twice",
               first.stats.usedFallback == second.stats.usedFallback
                   && first.stats.fallbackReason == second.stats.fallbackReason,
               "\(first.stats.fallbackReason ?? "structural") vs \(second.stats.fallbackReason ?? "structural")")

        // Counted work rather than elapsed time is what makes that true: a wall-clock deadline
        // would let a loaded machine produce a different diff from an idle one.
        guard let tree = parser.parseTree([UInt8](dense.utf8)),
              let editedTree = parser.parseTree([UInt8](edited.utf8)) else { return }
        let a = matchTrees(old: tree, new: editedTree, settings: MatcherSettings(matchWorkBudget: 50_000))
        let b = matchTrees(old: tree, new: editedTree, settings: MatcherSettings(matchWorkBudget: 50_000))
        report("a budget that bites spends exactly the same work each time",
               a.exceededBudget && b.exceededBudget && a.workUsed == b.workUsed,
               "\(a.workUsed) vs \(b.workUsed)")
        report("and a partial mapping never reaches a model",
               structuralDiff(oldPath: "d.tsx", oldBytes: [UInt8](dense.utf8),
                              newPath: "d.tsx", newBytes: [UInt8](edited.utf8), parser: parser,
                              settings: MatcherSettings(matchWorkBudget: 50_000)).stats.usedFallback)
    }

    print("\n=== the reason survives the crossing into the interface (INV-4) ===")
    do {
        let dense = syntheticDenseJSX(elements: 2000)
        let edited = dense.replacingOccurrences(of: "item", with: "entry")
        let result = structuralDiff(oldPath: "d.tsx", oldBytes: [UInt8](dense.utf8),
                                    newPath: "d.tsx", newBytes: [UInt8](edited.utf8), parser: parser)
        let notice = fallbackNotice(reason: result.stats.fallbackReason ?? "")
        let render = buildRenderModel(model: result.model, pinOld: "a", pinNew: "b",
                                      mode: "structural", notices: [notice])
        // The three parts of `13-…` §6, in DEC-077's words: *what* the window did with the file,
        // *why*, and *what the reader still gets*. The wording changed with that entry — the
        // sentence's subject is the file rather than the tool's machinery — and the three parts
        // did not, because they are what a shorter sentence would drop.
        report("the notice states what was withheld",
               render.notices.contains { $0.contains("shown as plain text") })
        report("and why", render.notices.contains { $0.contains("budget") || $0.contains("limit") })
        report("and what remains trustworthy",
               render.notices.contains { $0.contains("Every difference in it is still shown") },
               render.notices.joined(separator: " | "))
        // And that it says it in the reader's language: the sentence this replaced named the
        // machinery, which is the whole of what DEC-077 took off the screen.
        report("and it does not name the machinery to do it",
               !render.notices.contains { $0.contains("Structural analysis unavailable") })
    }
}
