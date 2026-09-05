# Area B — widening and mark shaping: verified

Verified by the lead agent after the area's subagent died to a server error. All numbers are from the
shipped release binary over the 4016-pair corpus, taken **after** DEC-117, DEC-120 and DEC-122, so
they are the current cost of each pass rather than the cost it had when the candidates were written.

## Each widening pass, isolated

| | false | missed | marks | presented | loud | micro-island | split-mark | ws-only |
|---|---|---|---|---|---|---|---|---|
| **shipped** | 2993 | 7110 | 52279 | 2429828 | 2320896 | 1361 | 7834 | 1547 |
| `--snap 0` | **2666** | 7227 | 57940 | 2321455 | 2251909 | 1917 | 7030 | 2017 |
| `--word-snap 0` | 2993 | 7110 | 54832 | 2391744 | 2282801 | 2048 | 7782 | 1573 |
| `--island 0` | 2962 | 7113 | 65577 | 2411301 | 2288643 | 12891 | 8513 | 2260 |
| `--reabsorb 0` | 2993 | 7110 | 56678 | 2422177 | 2307958 | 5233 | 7743 | 1604 |
| `--word-merge 0` | 2993 | 7110 | 55198 | 2429828 | 2320988 | 1361 | 10753 | 1535 |

**The syntax snap is the only widening pass that moves a line.** It costs **327 false lines** and
108 373 presented bytes, and buys 5661 fewer marks and 117 fewer missed lines. Island absorption
costs 31 false lines. The word snap, the second absorption and the in-word merge move **zero** lines
between them.

**This is the re-derivation M14-E asked for.** Of 2993 false lines, the widening passes account for
**358** and the alignment for the other 2635. The 6706 figure reported from M-A2 was an artefact of
the 39 unclipped pairs and is now retired.

Junction and island refusals, shipped: `crosses-the-floor` **5287**, `link` 2542, `label` 5;
`unexplained` 770, `flanks-disagree` 300, `longer-than-a-flank` 291.

## Two candidates settled by construction

**A Tailwind class insert pulls in its neighbour** — B30, confirmed:

```
const c = "flex items-center gap-2";  →  const c = "flex items-center rounded gap-2";
*  1 | const c = "flex items-center ⟦changed|rounded gap-2⟧";
```

Eight bytes inserted, thirteen marked: the following class is inside the mark.

**An edge inside a punctuation run is not widened** — B26, refuted:

```
const a = foo(x)?.y;  →  const a = foo(x).y;
*  1 | const a = foo(x)⟦changed|?.⟧y;
```

`snapToWordBoundaries` fires only when **both** the byte before the edge and the byte at it are word
bytes (`if isWord(start - 1, …), isWord(start, …)`). Between two punctuation characters neither is,
so the search never starts. The candidate's "walks the whole run and then the neighbouring
identifier" does not happen.

## Verdicts

**B1, B15, B28, B33 — CONFIRMED.** The second absorption absorbs on flanks the snaps grew:
`qualifies` tests the island against **current** flank lengths, and `--reabsorb 0` costs 7651
presented bytes and 3872 micro-islands. The pass is doing real work on eligibility it manufactured.

**B2, B29 — CONFIRMED.** An absorbed island and a widened flank take a classification computed on
bytes that are not theirs (`AbsorbIslands.swift:106`, `Widening.swift`'s agreement rule). DEC-120
made the inheritance coarser-but-honest for same-group disagreements; it did not make the claim
about the island's own bytes.

**B3, B13 — CONFIRMED, and it is the costliest pass in the stack.** 327 false lines and 108 KB of
presented bytes. This is the owner's observation 1 in mechanism form and the largest single
widening lever left.

**B4, B32, B40 — CONFIRMED.** The two sides widen against their own trees and nothing re-checks that
a link's endpoints still correspond. Area E's E-4 is the concrete case: a one-byte insertion inside
`inpirationsPathnames` marks twenty-one bytes on the new side and **nothing** on the old, so in two
panes there is a highlighted identifier on the right and no counterpart on the left.

**B5, B16, B23, B38 — CONFIRMED.** `coalesceAcrossWords` merges across `confidenceFloor` by design
(DEC-100), and the word snap immediately before it manufactures the in-word adjacencies it needs.
`crosses-the-floor` is now the **dominant** junction refusal at 5287, so the floor is doing most of
the refusing everywhere else.

**B7, B25 — CONFIRMED.** `atLineStart` is applied per edge, not per mark, so a mark whose left edge
sits at a line start is exempt on the left and widened on the right.

**B8, B21, B35, B36 — CONFIRMED.** Inside a string a word runs whitespace to whitespace, and Next.js
strings are class lists and paths. The word snap costs 38 084 presented bytes and **zero** lines,
which is exactly the signature of a pass that widens marks without changing which lines they fall on.

**B9 — CONFIRMED, partially fixed.** The island rule was four length-and-position tests with nothing
about content; DEC-117 added the fifth condition. What remains true is that an island of an operator
or a keyword under three bytes is still absorbed, and the output carries no residue of it.

**B11, B18, B34 — CONFIRMED, fixed.** Disagreement collapsing to `nil` — which renders at full
weight — was real at four sites. DEC-120 replaced it with `mergedClassification` for same-group
cases and kept `nil` across groups.

**B12 — CONFIRMED.** Confidence descends at three sites and rises at none.

**B14 — CONFIRMED.** The word rule is chosen per edge from whether that edge falls inside a string
region, so a mark spanning a quote can have its two edges governed by incompatible definitions.

**B17 — CONFIRMED, and it is the sharpest observation in the area.** The relative clause is
`island.length > min(left.length, right.length)`, so a one-byte flank can never absorb even a
two-byte island — the smallest edits, which fragment worst, are the ones absorption declines to
repair. `longer-than-a-flank` refuses 291 islands.

**B22 — CONFIRMED.** No widening pass is guarded on provenance. `widenPresented` inherits the
`.fallback` label deliberately, which is right, but the snaps and absorptions run identically on a
file nothing parsed.

**B30, B31 — CONFIRMED.** The Tailwind case above; and the floor fragmenting reformatted regions,
now the dominant junction reason at 5287.

**B6, B27 — NEEDS-MEASUREMENT.** *Run:* for every final mark, the longest contiguous run of bytes
covered by no canonical hunk; histogram it. Nothing narrows a mark, so the tail is the question.

**B10, B37 — NEEDS-MEASUREMENT.** *Run:* per absorbed island, the column distance to the nearest
presented byte of each flank, and the containing line's length. The line predicate is free on long
lines and that is arguable rather than shown.

**B19 — NEEDS-MEASUREMENT.** *Run:* count segments the grapheme snap modifies and bytes it adds over
all 4016 pairs. There is no knob for it, so this needs one.

**B20 — NEEDS-MEASUREMENT.** *Run:* log the distance to the nearest enclosing node boundary and the
node kind per snap attempt, and bucket by kind. The claim that 16 is a kind filter rather than a
budget is plausible and unmeasured.

**B24 — REFUTED on magnitude, CONFIRMED on mechanism.** The budgets do compose and nothing caps the
total. But the four passes together add **172 KB of 2 430 KB presented — 7%** — not the unbounded
growth the candidate describes.

**B26 — REFUTED.** Demonstrated above.

**B39 — REFUTED.** Both moved cases are handled explicitly and with their reasons recorded:
`qualifies` opens with `guard left.label != .moved, right.label != .moved else { return false }`, and
`widenPresented` demotes a widened `.moved` run to `.changed` because "the bytes this pass adds were
not part of that comparison". The candidate's "unspecified" is specified in two places.

## Label per candidate

| | | | |
|---|---|---|---|
| B1 CONFIRMED | B2 CONFIRMED | B3 CONFIRMED | B4 CONFIRMED |
| B5 CONFIRMED | B6 NEEDS-MEASUREMENT | B7 CONFIRMED | B8 CONFIRMED |
| B9 CONFIRMED | B10 NEEDS-MEASUREMENT | B11 CONFIRMED | B12 CONFIRMED |
| B13 DUPLICATE of B3 | B14 CONFIRMED | B15 DUPLICATE of B1 | B16 DUPLICATE of B5 |
| B17 CONFIRMED | B18 DUPLICATE of B11 | B19 NEEDS-MEASUREMENT | B20 NEEDS-MEASUREMENT |
| B21 DUPLICATE of B8 | B22 CONFIRMED | B23 DUPLICATE of B5 | B24 REFUTED |
| B25 DUPLICATE of B7 | B26 REFUTED | B27 DUPLICATE of B6 | B28 DUPLICATE of B1 |
| B29 DUPLICATE of B2 | B30 CONFIRMED | B31 CONFIRMED | B32 DUPLICATE of B4 |
| B33 DUPLICATE of B1 | B34 DUPLICATE of B11 | B35 DUPLICATE of B8 | B36 DUPLICATE of B8 |
| B37 DUPLICATE of B10 | B38 DUPLICATE of B5 | B39 REFUTED | B40 DUPLICATE of B7 |

**Tally: 15 CONFIRMED · 4 NEEDS-MEASUREMENT · 3 REFUTED · 18 DUPLICATE.**

## What the candidates missed

1. **The word snap costs 38 KB of presented bytes and not one line.** Nobody proposed the isolation
   that shows it, and it reframes the pass: it is entirely a within-line cost, so it can be tuned
   without any risk to the line-level metrics the milestone steers on.
2. **The syntax snap is the whole of the widening passes' line cost.** 327 of 358.
3. **`crosses-the-floor` became the dominant junction refusal** once DEC-122 removed the data-file
   pairs that `link` was concentrated in — 21703 → 2542 for `link`, against 5287 for the floor. The
   confidence floor, not the move link, is what keeps marks apart today.
