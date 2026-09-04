# Verification — Area A (alignment), candidates A1…A40

Read-only audit pass. Verifier notes appended incrementally.

## Measurements this pass ran (referenced by ID below)

All against the shipped release binary `.build/release/diffscope-verify` and, where the shipped
binary has no knob, against an **instrumented copy of `Sources/DiffScopeEngine/CanonicalDiff.swift`
alone**, compiled standalone with `swiftc` into `/tmp/probe` (no repo build, no repo file touched;
the file was copied to `/tmp/pb/CD.swift` and patched there). The copy adds counters and two env
knobs — `DS_FLOOR` for `matchConsumeFloor`, `DS_REVERSE` for the within-rank tie-break direction —
and changes nothing else. Its baseline reproduces the shipped alignment exactly.

**M-A0 — baseline reproduced.** `--corpus-survey corpus /tmp/base.json` over 4016 pairs reproduces
the stated baseline to the digit: false 9079 (17.5%), missed 7083 (19.9%), marks 70039, presented
2699559, loud 2607458 (96.6%), uncertain 4564, `shredded-word` 541, `split-mark` 26330,
`micro-island` 1332, `reflowed-block` 5822/2295, `duplicated-line` 106, `silent-old-side` 203,
`mark-confetti` 39. Every number below is against that.

**M-A1 — relocation A/B.** `DIFFSCOPE_NO_RELOCATE=1 --corpus-survey corpus`:

| | shipped | no relocate |
|---|---|---|
| false lines | 9079 (17.5%) | 9682 (18.7%) |
| missed lines | 7083 | 7080 |
| marks | 70039 | 70689 |
| presented bytes | 2699559 | 2708682 |
| uncertain marks | 4564 (6.5%) | 5225 (7.4%) |
| `shredded-word` | 541 | 613 |
| `split-mark` | 26330 | 27046 |
| `reflowed-block` | 5822 | 6445 |
| `crosses-the-floor` refusals | 4622 | 5378 |

Reproduces M12-J exactly. Relocation is a net win of 603 false lines and 661 uncertain marks.

**M-A2 — the alignment's own share of the error.** Counting *canonical hunk* lines against
`meta.json`'s `gitOldLines`/`gitNewLines` over all 4016 pairs, before any structural or widening
pass:

- canonical false lines **2373** — the shipped pipeline reports 9079. The alignment contributes
  **26%** of the false lines; the widening passes downstream add the other 6706.
- canonical missed lines **7183** — the shipped pipeline reports 7083. Every missed line but a
  hundred is already missed by the time the alignment ends; the downstream passes *recover* 100 and
  can never recover more, because they only widen what a hunk already touches.

**M-A3 — the consume rule, counted.** Over 4016 pairs, at the shipped floor of 8, the shift is
offered **92 592** inter-match sites, moves **6346** of them (6.9%), and consumes a neighbouring
match **1572** times (1268 downward, 304 upward).

| permission | consumes |
|---|---|
| rank only (consumed match is not noise) | 924 (59%) |
| noise only (rank would have refused) | 595 (38%) |
| both | 53 (3%) |

Consumed content: **756 punctuation-only, 816 containing at least one word byte**. Consumed length:
1 byte 1167, 2 bytes 147, 3–6 bytes 65, 7 bytes 152, 8 bytes 17. Landing rank of every shift the
pass chose: rank 1 **3556**, rank 2 **1833**, rank 3 **480**, *no rank at all* **477**. The 477
land-nowhere shifts are exactly the noise consumes, which by construction bypass the rank.

**M-A4 — `matchConsumeFloor` swept, 4016 pairs.** Canonical-level metrics and an order-independent
digest of every match in the corpus:

| floor | matches | hunks | canonical false lines | consumes | digest changed |
|---|---|---|---|---|---|
| 0 | 104112 | 97253 | 3207 | 0 | — |
| 2 | 98477 | 91623 | 2559 | 1307 | yes |
| 4 | 98295 | 91442 | 2514 | 1363 | yes |
| **8 (shipped)** | **97994** | **91277** | **2373** | **1572** | — |
| 16 | 97889 | 91202 | **2312** | 1634 | **yes** |
| 32 | 97860 | 91174 | 2297 | 1648 | yes |
| 96 | 97853 | 91167 | 2288 | 1648 | yes |

**The curve does not saturate at 8 on this corpus.** `CanonicalDiff.swift:97` says "M11-G finds 8,
16, 24, 48 and 96 identical on the corpus" — M11-G was *eleven files of one repository*
(`docs/22-experiment-log.md:2978`). On the 4016-pair corpus 16 is measurably different from 8: 105
fewer matches, 75 fewer hunks, **61 fewer canonical false lines**, and a different alignment digest.
The comment's justification for the constant is stale, even if 8 turns out to be the right value
after a pipeline-level re-measure.

**M-A5 — the within-rank tie-break reversed.** Recompiled with the downward walk keeping the
*first* candidate at each rank instead of the last (and the upward walk the reverse):

| | shipped | reversed |
|---|---|---|
| matches | 97994 | 98119 |
| canonical false lines | 2373 | **2532** |
| canonical missed lines | 7183 | **7207** |
| consumes down / up | 1268 / 304 | 915 / 521 |
| max displacement | 118 | 61 |
| digest | −2842908797258706742 | −894550381307190338 |

The tie-break is **positional and nothing else** — "the furthest position down the file wins" — and
reversing it moves the corpus by 159 false lines and 24 missed lines, in the shipped direction's
favour. Ties are common: 3216 of 11738 chosen landings had at least one other candidate at the same
rank, p90 = 2, max = 12.

**M-A6 — the work budget is exhausted on the corpus, and nothing says so.** `canonicalMatches` at
the shipped `defaultCanonicalDiffWorkBudget` = 40 000 000 reports `exceededBudget` on **39 of 4016
pairs** (0.97%), none of them minified — ordinary `.tsx` page files. Worst observed work: 40 015 458.
Consequences, all silent, verified on
`corpus/5bonsai__website__nextjs/1326287cc991__src_app__locale__page.tsx`:

```
$ .build/release/diffscope-verify --emit-structural before.tsx after.tsx x.tsx
path: structural  anchors=93  ambiguities=7  moved=0  formatting-only=0
validation: passed
…
=== UNIFIED BLOCKS ===        ← empty
```

against a non-exhausted control pair which prints four blocks. Three separate silences:

1. `StructuralDiff.swift:240` — `if case let .exact(hunks) = canonicalDiff(…)` — leaves
   `coverageKnown = false`, so `reconcile` is a no-op, the changed mask is empty and the layout
   classification never runs. The gaps between anchors are presented whole: lines 13–24 of that file
   are drawn as changed although only line 12 was touched.
2. `Navigation.swift:77` — `guard case let .exact(hunks) = canonicalDiff(…) else { return [] }` —
   **`changeStops` returns the empty list**, so the unified view has no blocks and navigation has no
   stops at all.
3. `Validation.swift:69` — `public var passed: Bool { violations.isEmpty }` — `coverageChecked` is
   set to false on exhaustion and `passed` does not read it, so the emitter prints
   `validation: passed`. The string that would have told the truth,
   `"unverified (coverage budget exceeded)"`, lives in `summary`, which is only printed when
   `passed` is already false.

No `Degradation` is raised anywhere on this path; `usedFallback` stays false; the corpus survey
counts these 39 pairs as "structural" and `whole-file-fallback` reads 0.

**M-A7 — a gap in the tools.** `canonicalMatches(old:new:workBudget:applyShift:)` has **no CLI
route**. `--emit-matches` (`Sources/diffscope-verify/main.swift:63`) calls
`canonicalMatches(old: old, new: new)` with both defaults, so neither `applyShift: false` nor a
different `workBudget` is reachable from the command line. `applyShift: false` is reachable only
from inside `AlignmentChecks.swift`/`WordSnapChecks.swift`; `matchConsumeFloor` is a `public let`
with no override at all. Every "run it with the shift off / the floor at N" check below therefore
needs either a new CLI flag or a rebuild — that is the gap, and it is why several candidates in this
area could not be graded on the shipped binary alone.

---

