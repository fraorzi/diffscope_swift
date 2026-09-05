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


---

# Verdicts

Labels assigned by the lead agent against the measurements above. Where a number comes from the
instrumented standalone copy of `CanonicalDiff.swift` rather than the shipped binary it is marked
**(probe)**, because that is a copy someone has to trust rather than re-run.

## The finding that refutes the largest family

**`reconcile` demotes. The presented byte set is exactly the canonical mask.**

Area D established it (`tasks/verify-D.md` → E-A) and it decides seven candidates in this area at
once. `StructuralDiff.swift`'s `reconcile` has two arms; the first rewrites every part of an
anchor-derived `.changed` segment that lies **outside** the canonical mask to `.unchanged,
confidence: 1`. So when `coverageKnown` is true the anchors, the five filters, the greedy scan and
the gap comparison decide **not one presented byte** — only its subdivision, its classification and
its confidence.

Every candidate arguing that a bad alignment is "laundered" into presentation by reconcile, or that
reconcile can only promote, is therefore wrong about the mechanism. What over-marks is downstream of
it, which M-A2 measures: of 9079 false lines, **2373 are the alignment's and 6706 are the widening
passes'**.

## Grouped verdicts

### The consume floor — the claim is right and every stated mechanism is wrong

**A3, A10, A20, A27, A33 — CONFIRMED on the claim, REFUTED on the mechanism.**

Right: `matchConsumeFloor = 8`'s recorded justification is stale. `CanonicalDiff.swift:97` says
"M11-G finds 8, 16, 24, 48 and 96 identical on the corpus"; M11-G was **eleven files of one
repository** (`22-experiment-log.md:2978`). M-A4 **(probe)** over 4016 pairs: at 16 the corpus has
105 fewer matches, 75 fewer hunks, **61 fewer canonical false lines** and a different alignment
digest. The curve does not saturate at 8.

Wrong: every one of these candidates explains the floor as swallowing multi-byte runs —
indentation, `});`, `" />`. M-A3 **(probe)** counts consumed lengths: **1 byte 1167, 2 bytes 147,
3–6 bytes 65, 7 bytes 152, 8 bytes 17.** Three quarters of all consumes are a single byte. The
"nesting depth reads the floor" story (A3, A20, A33) is not what the corpus does.

### The noise branch — confirmed, and A39 has it backwards

**A4, A11, A21, A28 — CONFIRMED.** M-A3 **(probe)**: of 1572 consumes, **595 (38%) were authorised
by the noise branch alone**, and **477 shifts landed at no rank at all** — which is exactly the
noise consumes, since by construction they bypass the rank. The escape hatch is not an exception.

**A39 — REFUTED.** It claims the predicate "protects punctuation-only matches and discards
identifier fragments". Consumed content is **756 punctuation-only against 816 containing a word
byte** — punctuation is consumed slightly less than half the time, not protected.

### The tie-break — confirmed as a fact, refuted as a defect

**A19, A29 — CONFIRMED as fact, REFUTED as defect.** M-A5 **(probe)**: the within-rank tie-break is
positional and nothing else, and ties are common — 3216 of 11738 chosen landings had another
candidate at the same rank (p90 = 2, max = 12). But reversing it makes the corpus **worse**: false
lines 2373 → 2532, missed 7183 → 7207. The shipped direction is not arbitrary in effect, whatever it
is in form.

**A38 — DUPLICATE of A19** for the tie-break half; its second half (the shift's position is moved by
the later passes) is CONFIRMED — see A40.

### The canonical work budget — confirmed, and half of it is now fixed

**A6, A13, A17, A31, A37 — CONFIRMED.** M-A6 **(probe)** and independently reproduced with the
shipped binary: **39 of 4016 pairs (0.97%)** exhaust the 40 M budget, none minified.

Three silences were claimed and they are not equal:
- `changeStops` returned `[]`, so the unified layout had no blocks and ⌘↓ had nowhere to go —
  **fixed, DEC-118.**
- `--emit-structural` printed `validation: passed` — **fixed, DEC-118.**
- `reconcile` becomes the identity, so on those 39 pairs the anchor/gap marks ship unclipped and
  INV-2 is never checked — **still open.** The notice bar does say *coverage not verified for this
  file* (`Contract.swift:141`, checked since DEC-043), so it is disclosed; what is not disclosed is
  that the marks on those files are the anchors' rather than the byte diff's.

**A18 — NEEDS-MEASUREMENT.** *"Budget is spent on the prefix, so the tail of a file is coarser."*
Plausible from `divide`'s recursion order and not measured. *Run:* prepend increasing churn before a
fixed small edit and plot presented bytes for the edit.

### Relocation — measured, and the candidates have the sign wrong

**A5, A22, A30 — REFUTED as defects, NEEDS-MEASUREMENT on locality.** M-A1, reproducible with
`DIFFSCOPE_NO_RELOCATE=1`: turning relocation **off** costs 603 false lines, 661 uncertain marks and
623 reflowed blocks. It is a net win, reproducing M12-J exactly. The locality bound the candidates
ask for is genuinely unmeasured. *Run:* log relocation displacement and inspect the tail beyond 40
bytes.

### The slide's whole-line preference

**A1 — REFUTED.** `score` requires a rank on **both** sides and returns the **worse** of the two:

```swift
guard let oldRank = rank(old, oldFrom, oldTo), let newRank = rank(new, newFrom, newTo)
else { return nil }
return max(oldRank, newRank)
```

A position that reads as a whole line on one side and mid-expression on the other scores `nil` or
rank 3 and cannot outrank a position that is clean on both.

**A34 — REFUTED.** Whole-line outranking everything is DEC-087/DEC-088's decision, measured, and
M-A5's reversal shows the alternative is worse.

**A2 — REFUTED on "without bound".** The mechanism is real — a consumed match merges hunks, and the
merged hunk is reachable again — but M-A5 **(probe)** reports **max displacement 118 bytes** over
4016 pairs. Bounded in practice.

**A8, A9, A23, A25, A36 — NEEDS-MEASUREMENT.** All five say the slide lands on the wrong member of a
repeated group. Nothing measured compares the chosen landing against the node mapping's own
correspondence. *Run:* for each hunk, record whether the post-slide range still overlaps the anchor
gap it came from; sort by displacement and read the tail.

### Reflow and indentation

**A12, A26 — NEEDS-MEASUREMENT.** The decisive experiment is stated in A26 and was not run: build a
provably layout-only subset by re-running prettier at a narrower print width, and count pairs
yielding any non-whitespace segment. The corpus has **no** pair that is equal after stripping
per-line leading whitespace (area D, E-G), so this subset must be constructed.

**A35 — REFUTED.** The two post-passes are not confluent, and the order is deliberate and recorded:
`CanonicalDiff.swift` — *"Relocation first: it changes which matches exist, and the shift's ranks are
about the hunks between whichever ones do (DEC-110)."*

### Amplification

**A32, A40 — CONFIRMED.** M-A2: the alignment contributes 2373 of 9079 false lines; the widening
passes add 6706. Area D's E-B on a 60-pair sample: **4516 bytes marked outside the canonical mask**,
falling to 3100 with `snap=0 island=0`. No pass in the pipeline ever narrows a presented range, so a
misplacement can only grow. **This is the largest unaddressed number in the audit.**

**A14, A15 — NEEDS-MEASUREMENT.** Argument-order asymmetry and the single-element-append shape;
neither was run. *Run:* A14 — the corpus forward and with the sides swapped, mirrored and diffed.
A15 — filter for pure appends to a comma-separated list and count pairs presenting more than the
appended line plus its comma.

**A7, A16, A24 — REFUTED.** See the finding at the top: reconcile demotes, so it cannot launder a
bad alignment into presentation. A16's second half — *the confidence signal is invisible* — is
CONFIRMED and is area C's C17, so it is a DUPLICATE there.

### A tooling gap the candidates could not see

**A7 also surfaced M-A7, which is a finding of its own.**
`canonicalMatches(old:new:workBudget:applyShift:)` has **no CLI route**: `--emit-matches` calls it
with both defaults, `matchConsumeFloor` is a `public let` with no override, and `applyShift: false`
is reachable only from inside the check suite. Every "run it with the shift off / the floor at N"
experiment in this area needed a rebuild, which is why five candidates here are
NEEDS-MEASUREMENT rather than settled.

## Label per candidate

| | | | |
|---|---|---|---|
| A1 REFUTED | A2 REFUTED | A3 CONFIRMED¹ | A4 CONFIRMED |
| A5 NEEDS-MEASUREMENT | A6 CONFIRMED | A7 REFUTED | A8 NEEDS-MEASUREMENT |
| A9 NEEDS-MEASUREMENT | A10 CONFIRMED¹ | A11 CONFIRMED | A12 NEEDS-MEASUREMENT |
| A13 DUPLICATE of A6 | A14 NEEDS-MEASUREMENT | A15 NEEDS-MEASUREMENT | A16 REFUTED |
| A17 DUPLICATE of A6 | A18 NEEDS-MEASUREMENT | A19 CONFIRMED² | A20 DUPLICATE of A3 |
| A21 DUPLICATE of A4 | A22 NEEDS-MEASUREMENT | A23 NEEDS-MEASUREMENT | A24 REFUTED |
| A25 DUPLICATE of A9 | A26 NEEDS-MEASUREMENT | A27 DUPLICATE of A3 | A28 DUPLICATE of A4 |
| A29 DUPLICATE of A19 | A30 DUPLICATE of A5 | A31 DUPLICATE of A6 | A32 CONFIRMED |
| A33 DUPLICATE of A3 | A34 REFUTED | A35 REFUTED | A36 NEEDS-MEASUREMENT |
| A37 DUPLICATE of A6 | A38 DUPLICATE of A19 | A39 REFUTED | A40 CONFIRMED |

¹ CONFIRMED on the claim that the floor's justification is stale; REFUTED on the mechanism every one
of them gives for it.
² CONFIRMED that the tie-break is positional; REFUTED that the shipped direction is a defect.

**Tally: 8 CONFIRMED · 12 NEEDS-MEASUREMENT · 8 REFUTED · 12 DUPLICATE.**

## What the candidates missed

1. **The consume rule's own numbers had never been counted.** 92 592 offered sites, 6346 shifts,
   1572 consumes, and a landing-rank histogram in which 477 shifts land on no boundary at all. None
   of this was reachable before this pass, because there is no CLI route to it (M-A7).
2. **`matchConsumeFloor`'s comment cites a measurement made on 11 files as if it were the corpus.**
   That is a documentation defect with a decision resting on it, and it is the kind of thing only a
   re-measurement finds.
3. **The alignment is responsible for a quarter of the error it is blamed for.** M-A2 is the number
   that should steer the next milestone: 2373 against 6706.
