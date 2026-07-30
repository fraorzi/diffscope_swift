# moved-function

A statement relocated with no internal change: byte-identical on both sides, so DEC-038
admits it as a move, and T-11 has something to prove — the two linked sides must be equal.

Two versions of this fixture failed to produce a move at all, and both failures are more
interesting than the fixture:

1. **Swapping two nearly-identical functions is not a move at byte level.** The minimal
   diff touches only the names and literals, because everything around them is common
   substring. There is no deletion and insertion to pair.
2. **`export const VAT_RATE` did not move either** — the relocated line began with
   `export `, which the canonical alignment matched against the *function's* `export `.
   That left the line only partly inside changed content, and the line-based move search
   (DEC-038) requires a whole line. Recorded in `22-experiment-log.md` → M8-C.

The line here therefore starts with `const`, sharing no prefix with its neighbour.
