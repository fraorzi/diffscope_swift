# multiple-similar-siblings

Four `<Item />` siblings where three already existed and one is inserted between the first and
the second — and the inserted one is **near**-identical to its neighbour rather than identical:
same `icon="save"`, a different `label` and a different `shortcut`.

`duplicated-nodes` is the identical case, where which sibling was added is genuinely undecidable
(OQ-027). This is the case next to it: the answer *is* decidable, and the risk is the opposite
one — a matcher that pairs the wrong two siblings and reports three edits where there was one
insertion.

## What it produces

`1 hunks/62B, 71 anchors, 0 moves`. Measured with `DIFFSCOPE_SEGMENTS=multiple-similar-siblings`,
the entire difference is:

```
new 134..<184 changed "save\" label=\"Save copy\" shortcut=\"Cmd D\" />\n      "
new 184..<196 changed "<Item icon=\""
```

**Nothing on the old side is marked changed at all.** No existing sibling is claimed to have been
edited; the three that were there arrive unchanged and the fourth arrives as new content. That is
the property this fixture guards, and it is what *structural matching never invents equality*
means when the candidates are near-misses rather than strangers.

## The boundary is not where a reader would draw it

The two changed segments are worth reading. The minimal edit does not attribute the insertion to
one whole line: it aligns the new row's `<Item icon="` with the **first** row's prefix, so the
change is charged to the *tail* of the new row plus the *head* of the row after it. A reader
drawing this by hand would have outlined one line; the byte-minimal answer outlines something
that straddles two.

Both readings present the same bytes — T-3 holds, and the reader sees every changed byte — so
this is a fact about where marks land rather than a defect. It is recorded because near-identical
siblings are the shape that produces it, and because the temptation, on seeing it, is to "fix"
the alignment by snapping to node boundaries. DEC-024 and INV-1 are why that is not done: the
partition is over bytes, and a boundary invented for tidiness is a claim the engine cannot make.
