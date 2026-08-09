# moved-block

T-11's **second relocation shape**: a whole multi-line function relocated past two other
declarations, with no internal change. `moved-function` moves one statement; this moves a block, so
each side arrives as several segments carrying the same `link` and the pairing is exercised rather
than a single range being relabelled.

The first line of the moved block is `async function loadConfig(...)`. That matters, and it is the
lesson `moved-function` paid for: a relocated line whose leading bytes align with a neighbour's
identical prefix is matched by the canonical diff and never becomes a whole changed line for the
move search to pair (M8-C, and again in M8-L). No other line in this fixture begins with `async`.

One candidate is rejected below the content floor and counted (`movesBelowFloor`), which is the
number DEC-038 asks for: git's silent floor is the thing being avoided.
