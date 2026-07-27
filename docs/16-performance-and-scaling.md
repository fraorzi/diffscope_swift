# 16 — Performance and Scaling

**Status:** Phase 5. Budgets are **provisional** — derived from measurement where measurement exists, and marked as estimates where it does not.
**Principle:** degrade visibly, never silently. Every budget breach produces a stated reason in the interface (see [13-error-and-fallback-model.md](13-error-and-fallback-model.md)).

---

## 1. Measured baselines

All figures measured on the target machine (macOS 26.5.2, arm64) against the real repository population, 2026-07-26/27. Sources: [22-experiment-log.md](22-experiment-log.md) and the `research/` documents.

### 1.1 Git

| Operation | Measured |
|---|---|
| Process spawn floor | 6.2 ms |
| `status --porcelain`, 1.5 GB repository | 46 ms |
| `status`, slowest of 21 repositories | 70 ms |
| `status`, fastest | 24 ms |
| Full sequential sweep, 21 repositories | 326 ms |
| Branch read from `.git/HEAD`, 21 repositories | 52 ms |
| Ahead-of-base counts, 21 repositories sequential | 504 ms |
| libgit2 `status`, 1.5 GB repository | 264 ms (5.7× slower than CLI) |

**`.git` size does not predict status cost.** Cost tracks working-tree file count. The 1.5 GB repository is not the slowest; the spread across the population is roughly 3×, not orders of magnitude.

### 1.2 Parsing

| Operation | Measured |
|---|---|
| TypeScript, 51 KiB TSX | 0.3 ms |
| Slowest Rust candidate, large file | 16.7 ms |

**Parsing is a rounding error** relative to everything else.

### 1.3 Rendering (web candidates)

5000 lines, 795 decorations, 42 alignment gaps:

| Metric | Monaco 0.56.0 | CodeMirror 6.43.6 |
|---|---|---|
| Create both editors | 176.3 ms | 64.3 ms |
| Apply decorations | 18.1 ms | 17.1 ms |
| Alignment gaps | 2.8 ms | 9.3 ms |
| Scroll, 120 steps | 22.6 ms | 11.3 ms |
| 50,000-char lines, max step | 2.5 ms | 0.4 ms |
| Bundle size | 9.3 MB | 667 KB |

Measured as synchronous layout cost, not frame time — `requestAnimationFrame` was unavailable in the harness. Comparable to each other; **not quotable as frame rates**. Native macOS rendering is unmeasured.

### 1.4 File watching

| Property | Measured |
|---|---|
| Events per atomic-replace save | 5 |
| Event span, p50 / max | 11.1 ms / 13.3 ms |
| Largest repository, paths watched | 89,714 |
| After excluding `node_modules` | 6,047 (93% reduction) |
| 40,000 file creations | 40,041 events, **zero drops** |
| kqueue per-file descriptors, largest repo | 2,182 ms to arm, 97% of `kern.maxfilesperproc` |

## 2. Where the risk actually is

**Not Git. Not the parser. Not rendering.** All three are measured and comfortable.

**The matcher is the risk.** Precedent: difftastic issue #373 records a moderate-size lockfile consuming 64 GB. Tree matching is superlinear in node count, and JSX produces dense trees.

**Budget on node count, not bytes.** A 200 KB minified file and a 200 KB hand-written file have wildly different node counts and wildly different matching costs.

## 3. Budgets

Provisional. Each has a defined degradation, and none may be exceeded silently.

| Dimension | Budget | On breach |
|---|---|---|
| File size, structural path | 2 MB | Raw fallback |
| File size, independent `D` validation | 2 MB (DEC-040) | Label **unverified**; partition assertions still run |
| Node count per file | ~50,000 *(estimate, unmeasured)* | Raw fallback, reason stated |
| Matching time per file | 500 ms *(estimate)* | Abort matching, raw fallback |
| Single line length | 50,000 chars *(measured safe in rendering)* | Rendering degradation, not fallback |
| Launch sweep, all roots | < 1 s to first paint | Progressive fill |
| Refresh debounce | ~400 ms trailing edge + max cap (DEC-026) | — |

**Explicitly marked estimates** — node count and matching time — are the two that matter most and are exactly the two not yet measured. They must be derived during implementation against the fixture corpus, not carried forward as if they were data.

## 4. Scaling dimensions

**Repository count.** Measured comfortable at 21 across one root. DEC-037 allows arbitrary roots, so total count is user-controlled. Sweep is parallel; cost is linear in repositories. Re-measure past ~100.

**Changed-file count.** 63 today in the worst repository. The file list is virtualised; diffs are computed per selected file, not for the whole set. Only the status sweep touches all files.

**File size.** Handled by the budgets above.

**Line length.** Measured no cliff at 50,000 characters in either web renderer — notably with Monaco's 10,000-character truncation default *disabled*. DEC-014's side-by-side choice makes long lines the weak spot for legibility, not for performance.

**Node count.** The unmeasured dimension, and the one carrying the real risk.

## 5. Concurrency

The engine must not block the interface. Diff computation runs off the main thread; the pinning model (DEC-007) makes cancellation safe — a superseded pin's work is discarded rather than merged.

Status sweeps parallelise across repositories. Watching is confined to the currently open repository (DEC-027), not all of them, which was rejected in DEC-006 precisely on cost grounds.

## 6. Caching

Keyed by the **pinned content-hash pair**, which makes cache invalidation exact rather than heuristic: different bytes, different key. No time-based expiry is needed for correctness.

Worth caching: parse results per content hash, status per repository between focus events, merge-base per (branch, base) pair.

**Not to be cached:** anything that would let a stale result survive a pin change. The cache may never be the reason a diff shows old content.

## 7. Degradation ordering

Precedence is specified in [13-error-and-fallback-model.md](13-error-and-fallback-model.md) §5. Performance-driven degradations (size, node count, time) sit in the middle of that order: more conservative than confidence-driven fallback, less conservative than a stale pin or an invariant violation.

## 8. Open items

- Node-count and matching-time budgets require measurement against the fixture corpus.
- Re-derive the 2 MB `D` threshold once `D`'s real cost is known (DEC-040).
- Cold-cache Git behaviour is unmeasured; all figures are warm.
- Native macOS rendering is unmeasured (X-2 gap).
- Whether `D` or the matcher dominates diff latency in practice — this determines whether DEC-039's independence carries a real cost.
