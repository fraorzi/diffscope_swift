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
        let elapsed = measure {
            _ = structuralDiff(oldPath: "dense.tsx", oldBytes: denseBytes,
                               newPath: "dense.tsx", newBytes: [UInt8](denseEdited.utf8),
                               parser: parser)
        }
        let result = structuralDiff(oldPath: "dense.tsx", oldBytes: denseBytes,
                                    newPath: "dense.tsx", newBytes: [UInt8](denseEdited.utf8),
                                    parser: parser)

        report("a pathologically dense file falls back rather than matching",
               result.stats.usedFallback, result.stats.fallbackReason ?? "did not fall back")
        // Four, not two: two parses plus the node walk and the fallback partition, with room for
        // the scheduler. The number that matters is that it is a small multiple rather than the
        // unbounded one a hang would produce.
        report("and it costs about what parsing it costs, rather than hanging",
               elapsed < parseBaseline * 4 + 0.2,
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
        // Refused without building a tree. The remaining cost is `classify`'s content scan, which
        // runs first because a binary or conflicted file deserves the more specific reason
        // (`13-…` §5 precedence) — in a debug build that scan is most of the time below. So the
        // baseline is one pass over the same bytes: the work that cannot be avoided.
        let scanBaseline = measure {
            var sum = 0
            for byte in oversizeBytes { sum &+= Int(byte) }
            precondition(sum >= 0)
        }
        let oversizeElapsed = measure {
            _ = structuralDiff(oldPath: "big.ts", oldBytes: oversizeBytes,
                               newPath: "big.ts", newBytes: oversizeNew, parser: parser)
        }
        let oversizeResult = structuralDiff(oldPath: "big.ts", oldBytes: oversizeBytes,
                                            newPath: "big.ts", newBytes: oversizeNew, parser: parser)
        report("a file above the size limit is refused without parsing it",
               oversizeResult.stats.usedFallback && oversizeElapsed < scanBaseline * 12 + 0.2,
               String(format: "%.2f s against a %.2f s scan baseline · %@",
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
