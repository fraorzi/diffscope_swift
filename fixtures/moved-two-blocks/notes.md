# moved-two-blocks

Two independent relocations in one file: a class moved to the top, an async function moved to the
bottom, both byte-identical on each side. This is the fixture that makes `link` mean something —
with one move in the corpus, a `link` field that always read `0` would have passed every check.
T-11 compares the two sides of each link, so a cross-paired link fails it.

## The version of this fixture that produced no moves at all

The first attempt swapped two **short single lines**:

```
let retryLimit = 3;              →  moved to the bottom
export type Session = { id: string };  →  moved to the top
```

Zero moves, 10 hunks. The canonical byte diff had matched `" = "` and `";"` across the two lines,
because both contain them — so on the old side `let retryLimit = 3;` is not a whole changed line,
it is two changed fragments with an unchanged `" = "` between them, and the line-based move search
of DEC-038 has no whole line to pair.

This is the **third** time this shape has appeared: `export const VAT_RATE` in M8-C, the two
near-identical functions before it, and now two short lines that happen to share punctuation. The
generalisation is worth stating once: *the shorter the relocated line, the more likely the canonical
diff has already spent its bytes matching fragments elsewhere.* Blocks relocate detectably; short
statements often do not.

Widening the search to lines that are only partly inside changed content would put bytes the
canonical diff calls unchanged inside a `moved` range — a reopening of DEC-038, not an
implementation detail.
