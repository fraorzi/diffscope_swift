# Diff-engine audit — verified findings

Index over `tasks/verify-A.md` … `tasks/verify-E.md`, which carry the evidence, the reproductions and
the per-candidate reasoning. This file is the summary and the running state.

Candidates: `tasks/diff-audit-candidates.md`, 200 across five areas, produced by 25 isolated
generators with no code access.

## Tally

| area | CONFIRMED | NEEDS-MEASUREMENT | REFUTED | DUPLICATE |
|---|---|---|---|---|
| A — alignment | 8 | 12 | 8 | 12 |
| B — widening and mark shaping | 15 | 4 | 3 | 18 |
| C — classification and quietening | 20 | 2 | 7 | 11 |
| D — the structural layer | 12 | 11 | 10 | 7 |
| E — block-level presentation | 8 | 6 | 7 | 19 |
| **total** | **63** | **35** | **35** | **67** |

The UI audit's ratio held: **35 of 165 non-duplicate candidates were wrong**, and writing down why is
most of this file's value.

## Fixed

| | what it was | measured |
|---|---|---|
| **DEC-117** | absorption swallowed unchanged code between two flanks made only of layout bytes — the owner's observation 1 | loud bytes −6447; `false`/`missed`/`split-mark`/`duplicated-line` unmoved |
| **DEC-118** | `changeStops` returned `[]` when the byte diff ran out of budget, so the launch layout had **no blocks** and ⌘↓ was dead on 39 of 4016 pairs | 39 pairs → 0 with an empty block list; model unmoved to the digit |
| **DEC-119** + **119a** | a formatter's closing token on its own line made the whole element print twice — the owner's observation 2 | `silent-old-side` 205 → 174, `duplicated-line` 147 → 137 |
| **DEC-120** | four passes resolved a classification disagreement to `nil`, which renders at full weight, even when both parts were formatting | loud bytes −327 |
| **DEC-122** | on the same 39 pairs `reconcile` was the identity, so anchor marks shipped unclipped | **false lines 9079 → 2993**, presented −266 KB, marks −18 353 |

Suite: 2221 → 2244 checks, 41 → 42 selftest arms.

## Open, ranked by what the evidence says they cost

1. **The syntax snap is the whole of the widening passes' line cost** — B3. `--snap 0` moves false
   lines 2993 → 2666 and presented bytes by 108 KB. Of the 358 false lines the widening stack
   accounts for, 327 are this one pass. It widens to a node boundary within 16 bytes, which on a JSX
   attribute is the whole attribute.
2. **Observation 3 has no repair.** The engine classifies a wrapper's reindent correctly
   (`formatting-only=6` on the real corpus pair, six of eight added lines carrying only formatting
   marks) and **DEC-083 draws formatting identically to a real change**. Two routes were tried and
   both closed: a third tint does not fit the luminance ladder (1.267 light / 1.370 dark, splitting
   gives steps of ~1.10 against a 1.20 rule), and the formatting-group-in-unified route was not
   demonstrated and was reverted. DEC-083's own revisit trigger has fired.
3. **`matchConsumeFloor = 8`'s justification is stale** — A3. The comment cites M11-G as the corpus;
   M11-G was eleven files of one repository. Over 4016 pairs a floor of 16 gives 61 fewer canonical
   false lines and a different alignment digest.
4. **Nothing asserts that git's removed-line set is contained in the tool's marked set** — D22, and
   area E's closing question. 19.9% of removed lines carry no mark; most is explained (pure
   insertions), and the property that would prove it is not checked anywhere.
5. **There is no reconstruction check for the rendered document** — E24. INV-1 covers the partition.
   Nothing concatenates what the window prints, with every marker opened, and compares it to the
   pinned bytes.
6. **The relative-length clause is inverted for the smallest edits** — B17. A one-byte flank can
   never absorb a two-byte island, so the edits that fragment worst are the ones absorption declines
   to repair.
7. **Per-side widening breaks a linked pair** — B4, with area E's E-4 as the case: a one-byte
   insertion inside an identifier marks 21 bytes on the new side and none on the old.

35 NEEDS-MEASUREMENT items are recorded in the per-area files, each with the command or the
instrumentation that would settle it.

## The refutations worth carrying forward

- **`reconcile` demotes.** When `coverageKnown` is true the presented byte set is *exactly* the
  canonical mask. The anchors, the five filters, the greedy scan and the gap comparison decide **no
  presented byte** — only its subdivision, classification and confidence. This refuted eleven
  candidates in D and seven in A, all built on the opposite assumption.
- **The counter and the keystroke are one array.** `total: stops.length`, and every navigation path
  indexes `stops`. Blocks are never walked. Five candidates in E assumed otherwise.
- **A reflow does not destroy leaf anchors.** Whitespace lies *between* leaves, so the leaves' text
  is unchanged; on a wrapper-add pair the old side is tiled by matches end to end.
- **The consume rule swallows single bytes, not indentation runs.** 1167 of 1572 consumes are one
  byte. Five candidates explained the floor as eating multi-byte runs.
- **`reflowTokenBudget` is unreachable on this corpus.** 64 KB against a largest file of 20 816 B.
- **The word snap does not fire inside punctuation.** Both the byte before an edge and the byte at it
  must be word bytes.
- **The corpus has no pure-reindentation pair.** Zero pairs are equal after stripping per-line
  leading whitespace, so that subset has to be constructed.

## Corrections to my own briefs and reports

The plan asked for these to be recorded beside the findings.

1. **I reported "6706 of 9079 false lines come from the widening passes" and it was wrong.** M-A2
   compared canonical hunk lines against shipped lines over populations that were not the same: the
   39 budget-exhausted pairs contribute zero canonical hunks and a great deal of shipped error.
   Re-derived after DEC-122 by isolating each pass: **the widening stack accounts for 358 of 2993**,
   of which the syntax snap is 327.
2. **I shipped DEC-119 in a form that hid a real change**, and `diffscope-verify` was green for it.
   The application selftest caught it, in an arm about a keystroke round trip. Corrected in DEC-119a.
3. **I wrote a selftest arm that passed for the wrong reason.** It counted `.ds-fold` across the
   whole page where the model carried other folds. Rewritten to count the group's own marker — at
   which point it passed with the fix reverted too, so **the claim was not demonstrated and the fix
   was reverted**.
4. **I briefed the E verifier with a repair whose risk I had named and then implemented anyway.**
   The brief said an unbounded lookahead would eventually withhold a genuinely removed line. The
   first version was bounded in lines and unbounded in skipping, which is the same hole.

## Method notes

- **A negative control that cannot reach the code it controls for proves nothing.** DEC-117's control
  failed first because the synthetic case used a three-byte indent, so DEC-094's shorter-flank rule
  had already refused the island and the new rule was never consulted. Rebuilt with an
  eighteen-space indent, it failed and passed in the right order.
- **`swift run diffscope-verify` is not the whole gate.** A change touching no renderer file can
  change what the renderer receives. Every engine change that alters `unifiedBlocks`, `changeStops`,
  `folds` or `collapses` must run `DIFFSCOPE_SELFTEST=1 swift run diffscope-app` before commit.
- **A metric that improves by hiding its input is the defect, not the measurement.** DEC-118 made
  `duplicated-line` and `reflowed-block` worse because 39 pairs stopped producing nothing to count.
- **The decision log answers questions the code cannot.** Area C's headline — that DEC-083 removed
  the quietening and its revisit trigger has now fired — was unreachable from the source alone, and
  no code-blind generator could have proposed it.
