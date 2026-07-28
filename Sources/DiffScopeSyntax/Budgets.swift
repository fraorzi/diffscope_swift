import Foundation

/// The three gates on the structural path, in the order they are cheapest to check (DEC-050).
///
/// `16-performance-and-scaling.md` §2 names the matcher as the risk and says to budget on **node
/// count, not bytes** — a 200 KB minified bundle and a 200 KB hand-written component have wildly
/// different node counts and wildly different matching costs. All three values below come from the
/// corpus survey in `22-experiment-log.md` → M8-A, not from estimation.
///
/// Every breach ends in raw with a stated reason. Raw shows every byte, so a breach costs
/// structure, never content.

/// Above this, the file is not parsed at all. Parsing a 31 MB bundle costs ~1.1 s before any
/// decision can be made about it, and DEC-040 already puts the independent validation limit here.
public let structuralSizeLimit = 2 * 1024 * 1024

/// Above this many nodes on either side, matching is not attempted. Measured: matching cost grows
/// roughly quadratically in node count, and this is where the corpus stops containing hand-written
/// code and starts containing build output.
public let structuralNodeBudget = 30_000

/// Counted candidate comparisons, not milliseconds. Measured at roughly 40,000 work units per
/// millisecond, so this is about a quarter of a second of matching — and three orders of magnitude
/// above the corpus median of ~10,000 units.
public let matchWorkBudget = 10_000_000
