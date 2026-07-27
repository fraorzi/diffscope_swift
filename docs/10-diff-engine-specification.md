# 10 — Diff Engine Specification

**Status:** Phase 5. Authoritative for engine behaviour.
**Read first:** [14-losslessness-and-trust-model.md](14-losslessness-and-trust-model.md) — the invariants this engine exists to satisfy.
**Stack-independent.** No language, parser, or runtime is presumed (OQ-033 open).

---

## 1. Contract

**Input:** a pinned source pair — the exact bytes of the old and new sides, plus a content hash for each, produced by the Git layer (see [11-git-behavior-specification.md](11-git-behavior-specification.md)).

**Output:** a presentation model `M` satisfying INV-1 … INV-5.

**Prohibitions, absolute:**
- No EOL conversion.
- No encoding conversion.
- No Unicode normalisation — anywhere, including inside the structural layer.
- No mutation of input bytes.

Bytes in, bytes out, unmodified.

## 2. The model

`M` is a **total ordered partition of the bytes of each side** (DEC-024), independently for old and new:

```
no gaps · no overlaps · Σ segment lengths == file length · no zero-width segments
```

Each segment carries:

| Field | Meaning |
|---|---|
| `range` | Byte interval on its side |
| `label` | `unchanged` · `changed` · `moved` · `fallback` |
| `classification` | Optional: `formatting-only`, `reordering`, `potentially-behavior-affecting`, … |
| `confidence` | How certain the structural layer is about this segment's alignment |
| `link` | Correspondence to a segment on the other side, where one exists |
| `children` | Nested segments, for intra-segment detail |

**Why the partition is the primitive.** Tools that model a tree whose nodes happen to carry positions cannot represent what the tree omits — inter-token whitespace, blank lines, trivia — and that loss is irreversible. Making the partition primary inverts this: INV-1 becomes an identity (concatenation *is* the file) and INV-2 becomes structural (a byte outside every segment is not expressible).

## 3. Pipeline

```
pinned source pair
  → byte-equality check                    (INV-3 short-circuit)
  → file classification                    (structural vs fallback path)
  → [structural path only] parse both sides
  → node↔node matching                     (mapping only, never an edit script)
  → partition construction                 (drop zero-width, clamp overlaps, fill from bytes)
  → nested token / word / character refinement
  → move detection (exact only)
  → classification pass
  → invariant validation
  → presentation model
```

Every stage can fail to the raw path. No stage can remove a difference.

### 3.1 Byte-equality check

If old and new bytes are identical, `M` is a single `unchanged` segment per side and the interface reports no changes. **This is the only circumstance in which "no changes" may be shown** (INV-3).

### 3.2 File classification

Determines the structural or fallback path. Structural applies only to TS/TSX/JS/JSX (DEC-004). Must handle deliberately: `.js` containing JSX, `.ts` containing TSX syntax, extensionless files, files whose extension misrepresents contents, generated and minified files, binary content, and files with an active Git filter (DEC-028 → always fallback).

Fallback is the **majority path by file count** and is a first-class, tested state — not an error.

### 3.3 Parsing

The parser is **advisory**. It proposes alignment; it never decides whether something differs.

Requirements, in priority order:

1. **Exact byte ranges**, in the same coordinate system as the partition. Spike X-1 showed every Node-hosted binding measured reports UTF-16 while typing offsets as bytes, producing a partition that is wrong while passing its own structural checks. Any UTF-16-reporting parser requires an independently tested conversion layer.
2. **Error recovery.** Half-typed source is routine, not exceptional (DEC-007). Measured: TypeScript never throws (0/4800 truncations); tree-sitter never throws but leaves only ~38% of bytes outside `ERROR` spans; Babel throws on 91.67%; oxc returns an empty program for 94.77% while appearing to succeed.
3. Incremental parsing is **optional**. tree-sitter issue #4001 reports incremental parses producing error nodes a fresh parse does not — under save-driven refresh that would cause spurious visible degradation. Re-parsing fresh is acceptable given measured parse costs (§7).

### 3.4 Matching

Consumes matcher output **exclusively as a node↔node mapping** (DEC-029). Edit scripts are never derived, consumed, or stored — a script cannot be projected onto a byte partition without reintroducing the move-swallows-delta failure.

Algorithms are implemented from published papers, never ported from GumTree (LGPL-3.0, DEC-030). Hyperparameters are explicit and recorded: defaults move 21.8% of cases, and `minHeight = 2` is hostile to JSX, where `<Item />` is a height-1–2 subtree that should match.

**Ambiguity is surfaced, never resolved arbitrarily** (DEC-031). The top-down phase already partitions candidates into unique and ambiguous sets; that set is exposed as reduced confidence rather than discarded. 76% of commits contain at least one instance, so this is the common path.

Where a tie *is* broken, it must be broken identically every run (T-7).

### 3.5 Partition construction

No parser tiles a file. Measured: naive leaf concatenation fails 2.73% of truncations **and 4 of 120 valid files**, because `JSDocComment` nodes alias the following token's leading trivia, producing a simultaneous gap and overlap.

The construction is therefore explicit:

1. **Drop zero-width nodes** — tree-sitter `MISSING` nodes and equivalents. They break the partition; they become annotations instead.
2. **Clamp overlaps** so no byte belongs to two segments.
3. **Fill remaining gaps directly from the bytes**, as unlabelled segments.

Measured: this passes 0/4800 failures with 0.01% filler bytes.

### 3.6 Refinement

Within linked changed segments, recurse: token → word/subtoken → character/grapheme. Refinement only subdivides existing segments; it can never remove one.

Display boundaries snap **outward** to grapheme clusters. Outward expansion is monotone, so it cannot push a changed byte outside its segment (§4 of the trust model).

### 3.7 Move detection

Version one detects **only byte-identical moves** (DEC-038): `Move { fromRange, toRange, innerDiff }` with `innerDiff` necessarily empty. Moved-and-modified content presents as delete plus add — correct, merely less legible.

A move **regroups** segments. It never replaces them.

### 3.8 Classification

Labels attached to segments, affecting grouping and presentation only. Vocabulary derived by **inverting** SemanticDiff's suppression list: `paren-only`, `literal-base`, `escape-style`, `trailing-comma`, `quote-style`, `object-key-reorder`, `jsx-attr-reorder`, `jsx-whitespace`, `import-reorder`, `tailwind-class-reorder`, `arrow-vs-function`.

`formatting-only` is a grouping with a disclosed count and immediate expansion. It is never a filter.

Reorderings that can change behaviour — spread props, object properties — are classified `potentially-behavior-affecting` and never normalised away.

Tailwind handling **emerges from general nested-token comparison** inside string literals. No Tailwind-specific subsystem exists (DEC-004).

### 3.9 Validation

Per DEC-040:

- **Partition assertions run always**, for every file, no exception: no gaps, no overlaps, Σ lengths == file length, no zero-width segments.
- **The independent `D`-based check (INV-2) runs below 2 MB.** Above that the file is labelled **unverified** — meaning the cross-check did not run, not that nothing was validated.

`D` is Myers over bytes, **implemented independently** of any presentation-path algorithm (DEC-039). Independence is the point: shared code means a common defect passes both the thing and its check. Spike X-1 demonstrated the concrete case — a coordinate bug that passes T-0 and T-1 while failing T-3.

On violation: discard the structural result, fall back to raw for the whole file, mark it visibly.

## 4. Determinism

Identical input yields identical output, across runs and across iteration orders. Non-determinism makes every other test flaky and every bug irreproducible. Sources to control: hash-map iteration order, parallel work-item completion order, and tie-breaking in matching.

## 5. Modes

Structural and Expanded are **one renderer with presentation flags** (DEC-013) and must produce identical segment sets (INV-5). Raw is a separate path. All three operate on the same pinned source pair.

## 6. Concurrency and freshness

Every analysis is bound to its pinned pair. If the underlying content hash changes mid-analysis, the result is discarded and recomputed — never blended (F10). A mixed-version diff is a correctness defect, not a refresh nuisance.

## 7. Performance shape

Measured inputs: TypeScript parses a 51 KiB TSX file in 0.3 ms; the slowest Rust candidate handles a large file in 16.7 ms; Git spawn floor is 6.2 ms; status on a 1.5 GB repository is 46 ms.

**The parser and Git are not the risk. The matcher is.** Budget on **node count**, not bytes — difftastic #373 records a moderate lockfile consuming 64 GB. Detail in [16-performance-and-scaling.md](16-performance-and-scaling.md).

## 8. Explicit non-guarantees

- Alignment is not guaranteed optimal, or even good. It is guaranteed never to cost correctness.
- Classifications are not guaranteed correct. They are guaranteed never to remove anything from view.
- Move detection is not guaranteed complete — in v1 it is deliberately limited to exact matches.
- Nothing is claimed about *importance*. That judgement is out of scope by design.

## 9. Open items

- Comparable error-recovery metric for tree-sitter vs TypeScript — the two current measurements use different definitions and cannot rank them (OQ-P-series).
- Confidence scale definition and the threshold at which a region falls back.
- Matcher hyperparameter values for JSX, starting from the knowledge that Java-derived defaults are wrong here.
- Re-derivation of the 2 MB threshold from measured `D` cost.
