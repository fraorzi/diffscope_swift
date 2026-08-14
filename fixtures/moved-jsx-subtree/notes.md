# moved-jsx-subtree

A `<Legend>` subtree relocated above the `<table>` it used to follow, with nothing inside it
changed. §4.5's *structural move*, and the case that says what DEC-038's line rule can and
cannot pair **in JSX**, which is the language this product is for.

## What it produces

`2 hunks/192B, 74 anchors, 1 moves (0 below floor)` — and the move spans several lines, so this
fixture is one of the three shapes T-11 is exercised by (`moved-block`, `moved-two-blocks` are
the others).

## Which lines paired, and which did not

Measured with `DIFFSCOPE_SEGMENTS=moved-jsx-subtree`:

```
old 272..<296 changed "\n      <Legend>\n        "
old 296..<317 moved   "Reported by DiffScope"
old 317..<326 changed "\n        "
old 326..<352 moved   "Warsaw office, third floor"
old 352..<367 changed "\n      </Legend"
```

**The two text lines are the move; the two tag lines are not.** `<Legend>` and `</Legend>` are
marked changed rather than moved, because DEC-038 pairs a line only when its *trimmed* content
lies **entirely** inside a changed run — and the `<` and `>` of a tag are matched as unchanged
against the `<table>`, `<tbody>`, `<tr>` tags the subtree moved past. One byte of common prefix
is enough to disqualify the line.

This is `moved-function`'s trap reproduced in JSX, and it is worth having a fixture for precisely
because JSX makes it the normal case rather than the unlucky one: every line begins with `<` or
`{`, so relocated markup is systematically harder to pair than relocated statements. Nothing is
lost when it happens — the unpaired lines are still presented as changed (T-3), and the move
label *regroups* what is presented and never removes it (`10-…` §3.7).

## The version that produced no move at all

The first attempt swapped a nine-line `<table>` block with a ten-line `<aside>` block, both full
of `{xs.map((x) => (` and `key={x.id}` — and it produced **62 hunks / 272B and zero moves**. Two
blocks of the same shape share so much line-internal text that the canonical diff interleaves
them rather than deleting one and inserting it elsewhere, so no line is wholly inside a changed
run and there is nothing for the move search to pair.

The rule this fixture is built on: **a relocated subtree is only detectable as a move when it is
lexically unlike what it moved past.** That is a real limit, not a defect — a move is
byte-identical or it is not a move (DEC-038), and the alternative is guessing.
