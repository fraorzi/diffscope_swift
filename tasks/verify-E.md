# Verification — Area E (block-level presentation)

Status: in progress. Written incrementally.

## 0. The root cause the lead found — confirmed, with the mechanism quoted

### 0.1 Mechanism

Reproduced exactly as reported (`/tmp/vE/e.tsx` → `/tmp/vE/f.tsx`, `--emit-structural`):

```
=== UNIFIED BLOCKS ===
   0  old 1–1 new 1–4
```

control (`e.tsx` → `g.tsx`, closing `/>` moved onto the last changed line):

```
=== UNIFIED BLOCKS ===
   0  old 1–1 new 1–4 reflowed — the whole old half is withheld
```

The deciding line is `Sources/DiffScopeEngine/Unified.swift:81`:

```swift
let newTokens = layoutTokens(new[block.newStart..<block.newEnd])
```

The withholding question is asked **against the block's own new half and nothing else**. The block's
new half is built in `unifiedBlocks` at `Sources/DiffScopeEngine/Unified.swift:180-189` from the
snapped union of the hunks:

```swift
let newRange = snap(new, stop.newStart, stop.newEnd)
...
newStart: last.newStart, newEnd: max(last.newEnd, newRange.end))
```

so `block.newEnd` is the end of the **last line any hunk touched**. Prettier's closing `/>` sits on
its own line, is byte-identical to nothing on the old side and is touched by no hunk, so it is one
line past `block.newEnd`.

Then at `Sources/DiffScopeEngine/Unified.swift:95-103` the per-line walk runs out of tape:

```swift
for token in lineTokens {
    var found = false
    while walker < newTokens.count {
        let candidate = newTokens[walker]
        walker += 1
        if candidate == token { found = true; break }
    }
    if !found { matched = false; break }
}
```

The old line's tokens are `< Img src = { a . src } alt = "" / >`. `/` and `>` are not in
`newTokens` because they live at new line 5. `matched` goes false, the line is kept, and — since it
is the only old line — nothing is withheld at all. The old element is printed in full beside its own
rewrap, with **no** "re-wrapped — N lines not printed" note, because `buildUnified`
(`Renderer/src/main.js:500`) only writes the note when `hiddenLines > 0`.

The failure is all-or-nothing per line, and JSX elements that Prettier explodes are usually one old
line, so "one token short" and "the whole element printed twice" are the same event.

**A second consequence, not in the report:** this shape is invisible to the corpus survey.
`duplicatedLineBreakdown` (`Sources/diffscope-verify/CorpusSurvey.swift:449-455`) only counts an old
line as duplicated when some **byte-identical** new line exists in the block:

```swift
guard let newIndex = newLines.indices.first(where: {
    !taken.contains($0) && Array(new[newLines[$0].start..<newLines[$0].end]) == text
}) else { continue }
```

A rewrapped line has no byte-identical partner by construction, so the whole family scores 0 on
`duplicated-line`. That is why the shipped 106 duplicated lines look small next to what a reader
sees.


---

## Evidence gathered for the sweep

### E-1 · Can the withholding rule hide a deletion? On the shipped rule, I could not make it.

Four adversarial pairs, run through `--emit-structural`:

```
key removed during a rewrap
  const o = { a: 1, b: 2, c: 3 };  →  const o = {\n  a: 1,\n  c: 3,\n};
  → 0  old 1–1 new 1–3            (nothing withheld; the old line prints)

reorder plus one deletion of a duplicated line
  → 0  old 2–2 new —              (the deleted helper(); is its own block)

wrapper removed
  → 0  old 1–2 new —   1  old 3–3 new —

duplicated line, one deleted, the other rewrapped
  foo(a);\nfoo(a);  →  foo(\n  a,\n);
  → 0  old 1–2 new 1–2 withheld old lines 1–1   (one copy withheld, one printed)
```

In every one the removal stays on screen. **The protection is the single forward cursor**: an old
line's tokens must be found *after* everything the previous withheld line consumed, so a line that
is genuinely gone pushes the cursor and then fails.

**The one hole that did exist was mine.** DEC-119's first version let the walk skip into the context
past the block, and `const first = 1;` → `const first = 111;` had its old half withheld because the
`1` it needed was found in `const value1 = 1;` below. Closed by DEC-119a and pinned by a check.

### E-2 · The status line and the keystroke count the same list

`Renderer/src/main.js:1493` — `return { index: stopIndex, total: stops.length, at: target }` — and
every navigation path indexes `stops` (`:1454`, `:1634`, `:1648`, `:1688`). **Blocks are never
walked.** The whole family claiming the counter is over stops and the keystroke over merged blocks is
built on a mechanism that does not exist.

### E-3 · `reflowTokenBudget` never fires on this corpus

It is 64 KB and is tested against block sizes, which are bounded by the file. `--budget-survey`
reports the largest structural file at **20 816 B** — a factor of three below the budget, on the
biggest file of 400. Every candidate about the budget's threshold behaviour is untestable here and
needs a constructed file.

### E-4 · What `silent-old-side` actually is

The worst pair, `5bonsai…/src/middleware.ts` with five instances. Old line 62 against new line 62:

```
−   const inpirationsPathnames  = Object.entries(routing.pathnames['/inspirations']).map(
+   const ⟦changed|inspirationsPathnames⟧ = Object.entries(routing.pathnames['/inspirations']).map(
```

A typo fix: one inserted `s`. The byte diff makes it a **pure insertion**, so the old side has no
changed bytes at all and correctly carries no mark; the new side's mark is the whole identifier,
which is the word snap doing its job (DEC-100).

So `silent-old-side` is not a family of defects. It is what a pure insertion inside a line looks like
in a line-based layout, and git prints the same shape.

**What the case does show is a real asymmetry nobody in this area named**: the new side marks
twenty-one bytes and the old side marks none, so in two panes the reader has a highlighted identifier
on the right and nothing on the left to compare it against. That is area B's **B32** — *each side
widens independently, so linked marks stop corresponding* — and this is a concrete confirmation of it.

---

# Verdicts

## Grouped

**E1, E9, E21, E26, E33 — REFUTED.** See E-2. `total` is `stops.length` and navigation indexes the
same array. The counter and the keystroke cannot disagree, because there is only one list.

**E5, E12, E18, E28, E35 — REFUTED for the shipped rule.** See E-1: four constructed attacks, the
removal visible in all four. Recorded with the historical exception, which was real and is closed.

**E16, E20, E30, E37 — REFUTED on this corpus.** See E-3: the budget is a factor of three out of
reach. The claims are not disproved in principle; they are unreachable, and saying which is the point
of the label.

**E23, E29 — REFUTED.** See E-4. The 172 instances are dominated by pure insertions, where the old
side has nothing removed and marking nothing is the correct answer.

**E4 — REFUTED.** The rewrap header is an expander and says so:
`.ds-hunk-reflowed { cursor: pointer; border-top-style: dashed; … }` and the selftest reads its label
back — `3 re-wrapped lines, the same code is on the right — ⌘E, or click, to expand`. It is not a door
the reader cannot see.

**E10 — REFUTED.** The coverage test is byte overlap with an explicit width guard, not a
containing-line lookup:

```swift
stops.contains { to($0) > from($0) && from($0) < end && to($0) > start }
```

A point stop has `to == from` and is excluded by the first clause. The candidate's supposed
implementation is not the one in the file.

**E38 — REFUTED.** Folds are built one kind at a time (`kind: "unchanged"`, `"formatting"`,
`"reflow"`) and never merged across kinds, so a marker cannot hold a mixed basket.

**E6, E13, E36 — CONFIRMED.** `Unified.swift`: `cursor = lineTokens.isEmpty ? cursor : walker`, and
the line is withheld regardless. A token-free line matches vacuously, consumes nothing, and — because
withheld ranges are merged where they touch — bridges two islands into one count.

**E17, E19 — CONFIRMED.** The marker states a line count and nothing distinguishes a line withheld
because it is byte-identical from one withheld because a token walk found its tokens scattered ahead.
The tokeniser has no grammar, so a comment's prose words are tokens like any other.

**E11, E40 — CONFIRMED.** Withheld ranges are merged wherever they touch, and only the full-half case
is named `reflowed` and given the expander. A partial withholding of two unrelated islands is one
count and one marker.

**E14 — CONFIRMED.** The peel fires only on a leading or trailing **pair**
(`guard oldTo > oldFrom, newTo > newFrom, oldTo - oldFrom == newTo - newFrom`), so an edge line that
outward snapping added on the longer side has no partner and is structurally unpeelable.

**E24 — CONFIRMED.** There is no INV-1 analogue for the rendered document. INV-1 constrains the
partition against the source; nothing concatenates what the window actually prints, with every marker
opened, and compares it to the pinned bytes. A rendering that dropped lines silently would satisfy
every listed invariant.

**E31 — CONFIRMED.** `unifiedBlocks`' `snap` has the branch explicitly: an empty range inside a line
returns `(lineStart, lineEnd)`, so the line prints as removed although no byte of it was deleted.
This is the mechanism behind E-4, and it is correct rather than wrong — but it is the mechanism.

**E8 — CONFIRMED.** Stops are derived from the model before folding decides what is out of sight, so
`m` does not change when a fold opens and the revealed lines have no stop of their own.

**E2, E27, E39 — NEEDS-MEASUREMENT.** Whether split and unified mark the same original lines.
*Run:* per pair, the set of original-file line numbers marked in split against those reachable from
unified's signed lines, and classify the differences by stage.

**E3, E25 — NEEDS-MEASUREMENT.** Whether a stop's anchor can end up outside every rendered block
after the peel. *Run:* assert it over the corpus; it is a one-line property and nothing asserts it.

**E7, E22 — NEEDS-MEASUREMENT.** Whether the peel's terminator-inclusive coverage and `changedLines`'
no-claim-past-newline convention disagree on the same boundary line. *Run:* for each of the 137
duplicated lines, record which peel clause failed and compare against `changedLines`' verdict.

**E15 — NEEDS-MEASUREMENT.** Same experiment as E2, from the metric side: recompute the false and
missed figures per layout.

**E32 — NEEDS-MEASUREMENT.** *Run:* build the multiset of hidden line numbers per side, assert it is
a set, and assert its size equals the sum of the stated counts.

**E34 — NEEDS-MEASUREMENT, and unreachable here.** A terminator-only difference blocking the peel is
code-true, and `docs/14-…` §4.2 records that the corpus's 34 CRLF files are CRLF on both sides, so no
pair exercises it. Needs a fixture.

## Label per candidate

| | | | |
|---|---|---|---|
| E1 REFUTED | E2 NEEDS-MEASUREMENT | E3 NEEDS-MEASUREMENT | E4 REFUTED |
| E5 REFUTED | E6 CONFIRMED | E7 NEEDS-MEASUREMENT | E8 CONFIRMED |
| E9 DUPLICATE of E1 | E10 REFUTED | E11 CONFIRMED | E12 DUPLICATE of E5 |
| E13 DUPLICATE of E6 | E14 CONFIRMED | E15 NEEDS-MEASUREMENT | E16 REFUTED |
| E17 CONFIRMED | E18 DUPLICATE of E5 | E19 CONFIRMED | E20 DUPLICATE of E16 |
| E21 DUPLICATE of E1 | E22 DUPLICATE of E7 | E23 REFUTED | E24 CONFIRMED |
| E25 DUPLICATE of E3 | E26 DUPLICATE of E1 | E27 DUPLICATE of E2 | E28 DUPLICATE of E5 |
| E29 DUPLICATE of E23 | E30 DUPLICATE of E16 | E31 CONFIRMED | E32 NEEDS-MEASUREMENT |
| E33 DUPLICATE of E1 | E34 NEEDS-MEASUREMENT | E35 DUPLICATE of E5 | E36 DUPLICATE of E6 |
| E37 DUPLICATE of E16 | E38 REFUTED | E39 DUPLICATE of E2 | E40 DUPLICATE of E11 |

**Tally: 8 CONFIRMED · 6 NEEDS-MEASUREMENT · 7 REFUTED · 19 DUPLICATE.**

## Can a deletion be hidden?

**No, on the shipped rule — and yes, for one day, on a rule I wrote.** Four constructed attacks all
leave the removal on screen; the ordering of the single forward cursor is what prevents it. The one
demonstrated hole was DEC-119's first version skipping into context, and it is closed, checked, and
written up in DEC-119a.

The honest caveat is that this is four constructed cases and a code argument, not a proof or a
corpus-wide assertion. **The assertion that would settle it does not exist**: nothing checks that
every line git reports as removed is either marked or printed. That is the same missing check area D
found for the 19.9%, and it is one property covering both.

## What the candidates missed

1. **`reflowTokenBudget` is unreachable on this corpus** — four candidates argue about behaviour at a
   threshold that is three times the largest file.
2. **The counter and the keystroke are the same array**, which five candidates independently assumed
   they were not.
3. **The real asymmetry is per-side widening, not per-layout** (E-4): a pure insertion inside a word
   marks twenty-one bytes on the new side and nothing on the old, so two panes cannot be compared at a
   glance. Area B's B32 named it; this area found the case.
4. **There is no reconstruction check for the rendered document.** INV-1 covers the partition. Nothing
   covers what the window prints.
