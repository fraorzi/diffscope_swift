# 15 — Test Corpus and Validation Plan

**Status:** Draft, stack-independent. Refine after Phase 5 (engine spec) and Phase 7 (architecture).
**Depends on:** [14-losslessness-and-trust-model.md](14-losslessness-and-trust-model.md) — the invariants are what the corpus enforces.

Per DEC-001, the corpus is written **before** the architecture decision, so that it specifies correctness rather than being shaped to flatter a chosen design.

Per DEC-002, the diff engine must run **headlessly** — the corpus runs in CI with no GUI. Any architecture that cannot execute the engine outside a running macOS application is disqualified on these grounds.

---

## 1. Two kinds of test

**Invariant tests** — apply to *every* fixture, automatically, with no per-fixture expectation file. They enforce §3 below. These are the tests that make the guarantee real; they cannot be forgotten, because they are not written per case.

**Alignment-quality tests** — apply to specific fixtures with recorded expectations. These check that the engine produces *good* output, not merely *correct* output. They are allowed to fail without the product being wrong; a quality regression is a bug of a different severity class than an invariant violation.

Keeping these separate matters. Conflating them produces a suite where a cosmetic regression looks like a correctness failure, which trains people to ignore failures.

## 2. Fixture layout

```
fixtures/
  <group>/<case-name>/
    before.<ext>
    after.<ext>
    notes.md          required: what this case exercises, why it is hard
    expected.json     optional: alignment-quality expectations
    meta.json         optional: encoding, EOL, size class, expected fallback
```

Rules:

- `before` and `after` are stored as **exact bytes**. No editor may normalize them on save — a fixture whose CRLF or NFD content is silently repaired by a formatter is worse than no fixture, because it passes while testing nothing. Fixtures must be verified byte-for-byte in CI against recorded hashes.
- Absent `expected.json`, a fixture is still fully exercised by the invariant tests.
- `notes.md` is required. A fixture whose purpose is not written down becomes unmaintainable within months.

## 3. Invariant tests — applied to every fixture

Derived directly from DEC-021, DEC-022, DEC-013.

| ID | Test | Invariant |
|---|---|---|
| T-0 | **Partition well-formedness** — no gaps, no overlaps, Σ lengths == file length, both sides | DEC-024 |
| T-1 | Old side reconstructs byte-for-byte from the model | INV-1 |
| T-2 | New side reconstructs byte-for-byte from the model | INV-1 |
| T-3 | Every byte of every canonical-diff hunk is contained in a presented range | INV-2 |
| T-4 | "No changes" is presented iff `O = N` byte-equal | INV-3 |
| T-5 | Every fallback range is marked as fallback | INV-4 |
| T-6 | Structural and Expanded produce identical presented-range sets | INV-5 |
| T-7 | Output is deterministic — same input, same output, across runs and orderings | — |
| T-8 | No normalization occurred: a fixture pair differing only in normalization form must report a difference | DEC-021 |
| T-9 | Parser failure yields fallback, never a missing change | §7.7 |
| T-10 | Presented ranges are aligned to grapheme-cluster boundaries | §4 |
| T-11 | Detected moves carry their internal delta | §7.3 |

T-3 and T-8 are the two that would actually catch the failure this product fears. T-7 matters more than it looks: a non-deterministic matcher makes every other test flaky and every bug irreproducible.

**On T-0 versus T-1/T-3.** Under DEC-024 the model is a byte partition, so T-0 passing means T-1 and T-3 pass by construction. They are retained anyway, and deliberately implemented **independently** of the partition code rather than by asking the partition about itself. A partition implementation with a bug in its own invariant checking would otherwise mark its own homework. T-0 is the cheap structural assertion; T-1 and T-3 are the independent verification.

Additional partition-specific test: **zero-width segments must not exist.** tree-sitter `MISSING` nodes are zero-width and break the partition if admitted; they belong in annotations instead.

### 3.1 Property-based testing

Beyond fixed fixtures, generate random source pairs and assert INV-1 through INV-3. Generators worth building:

- Random edits (insert, delete, replace) applied to real files drawn from the corpus.
- Random whitespace and formatting perturbations.
- Random reorderings of props, imports, and object properties.
- Random truncation, to produce syntactically invalid source cheaply.
- Random injection of NFD sequences, zero-width characters, and NBSP.

Property tests are the mechanism most likely to find the case nobody thought of. Failures must shrink to a minimal reproducing pair and be promoted into the fixed corpus.

## 4. Fixture groups

Priority reflects version-one scope: **P0** must pass for v1; **P1** should; **P2** is deferred scope, kept as a fixture so behavior is at least defined.

### 4.1 The founding cases — P0

| Case | Exercises |
|---|---|
| `jsx-wrapper-removal` | `<div>` → `<>` with children preserved. The headline case. |
| `jsx-wrapper-added` | Inverse direction. |
| `jsx-wrapper-type-change` | `<div>` → `<section>`, children unchanged. |
| `jsx-text-punctuation` | Added period in JSX text; must not replace the whole element. |
| `string-single-character` | `"Witaj użytkowniku"` → `"Witaj, użytkowniku"`. |
| `identifier-typo` | `recepientEmail` → `recipientEmail`. |
| `repeated-identifier-change` | Same rename in many places; may group, must keep every occurrence reviewable. |
| `prop-value-change` | Single attribute value edit. |
| `prop-reordering` | Reordered + reformatted props, values unchanged. Must **never** report "no change". |
| `spread-prop-reordering` | `{...defaults}` moved relative to `value`. Must not normalize away; classify as potentially behavior-affecting. |

### 4.2 Token and string-level — P0

| Case | Exercises |
|---|---|
| `tailwind-class-removal` | `"flex items-center gap-4"` → `"flex gap-4"`. Must emerge from general token comparison, not a Tailwind subsystem. |
| `class-order-change` | Same classes, different order. |
| `template-literal-change` | Literal text edit inside a template. |
| `template-literal-expression-change` | Edit inside `${…}`. |
| `clsx-expression-change` | Conditional class expression edit. |
| `quote-style-change` | `'` → `"`. |

### 4.3 Formatting and reordering — P0

Formatting cases are where "grouped but never hidden" is proven.

| Case | Exercises |
|---|---|
| `prettier-formatting` | Whole-file reformat, no semantic change. |
| `eslint-autofix` | Autofix churn. |
| `whitespace-only` | Must report changes, grouped, with disclosed count. |
| `indentation-change` | Tabs vs spaces, depth changes. |
| `semicolon-change` | Added/removed semicolons. |
| `import-reordering` | Reordered import statements. |
| `import-item-removal` | Removed named import. |
| `object-property-reordering` | Potentially behavior-affecting. |
| `comment-only-change` | Comments are content, not decoration. |

### 4.4 Unicode and encoding — P0

Elevated from the original sketch: 51% of the real corpus contains non-ASCII, and the `ŻABKA` case is drawn from actual source.

| Case | Exercises |
|---|---|
| `nfc-vs-nfd` | Canonically equivalent, byte-different. **Must report a change.** Sourced from the real `ŻABKA` line. |
| `unicode-graphemes` | Combining sequences, emoji ZWJ sequences; boundary snapping. |
| `zero-width-characters` | ZWJ, ZWNJ, ZWSP, soft hyphen. |
| `bidi-controls` | Trojan-Source-shaped input. |
| `nbsp-vs-space` | Whitespace lookalike disclosure. |
| `line-ending-change` | LF → CRLF. Real: 34 files in the corpus contain CRLF. |
| `eol-filter-active` | **Required by DEC-025.** Repository with `.gitattributes` `text eol=crlf` or `core.autocrlf`. Asserts the compared pair matches what `git diff` uses, and that filter application is disclosed. **Cannot be covered by the current corpus** — 0 of 21 repositories have filters active, so without this fixture the behavior is untested until it fails in production. |
| `mixed-line-endings` | Not currently present in the corpus; define behavior before it appears. |
| `invalid-utf8` | Not currently present; must not crash. |

### 4.5 Structure and movement — P1

| Case | Exercises |
|---|---|
| `moved-function` | Move detection with no internal change. |
| `moved-function-modified` | **Move with internal delta.** The losslessness trap (OQ-026). |
| `moved-jsx-subtree` | Structural move. |
| `duplicated-nodes` | Repeated identical siblings — genuine ambiguity; must lower confidence, not guess (OQ-027). |
| `multiple-similar-siblings` | Near-identical JSX siblings. |

### 4.6 Degenerate and hostile input — P0 for fallback behavior

| Case | Exercises |
|---|---|
| `invalid-tsx` | Half-typed JSX. **Normal state**, not exceptional — auto-refresh on save guarantees it. |
| `truncated-file` | Parse fails mid-construct. |
| `merge-conflict-markers` | Must not be interpreted as source. |
| `minified-file` | Very long single lines; worst case for side-by-side (DEC-014). |
| `huge-file` | Above the runtime validation threshold; must mark **unverified**, not silently skip. |
| `generated-file` | Behavior to be defined (OQ-029). |
| `binary-file` | Must not attempt text diff. |
| `image-file` | Non-text handling. |
| `empty-file` | Empty → content and reverse. |
| `no-trailing-newline` | Classic off-by-one source. |

### 4.7 File-level operations — P1

| Case | Exercises |
|---|---|
| `deleted-file` | Old side only. |
| `added-file` | New side only. |
| `renamed-file` | Rename with no content change. |
| `renamed-and-modified-file` | Rename plus edit — rename detection must not swallow the edit. |
| `untracked-file` | No old side in Git. |
| `symlink` | Must not follow into arbitrary content. |
| `unsupported-language` | Raw fallback path — the **majority case by file count** under DEC-004. |

### 4.7a Files that render — P1, added by DEC-063

The rendered comparison is the first surface where a *correct* comparison can still mislead, so the fixtures are chosen around that rather than around file formats.

| Case | Exercises |
|---|---|
| `svg-text-only-change` | Source differs — a `<title>`, a colour written `#fff` versus `#FFFFFF` — and **not one pixel moves**. F18: the comparison must say the rendering is identical and the bytes are not. The case that would otherwise read as a false positive. |
| `svg-rendered-change` | Source and rendering both differ. Both readings must agree that something changed. |
| `svg-hostile` | An SVG carrying `<script>` and an external reference. Nothing executes and nothing is fetched — the negative control for the `<img>` boundary, and the reason that boundary is in DEC-063 rather than in a code comment. |
| `raster-resize` | Dimensions change. The changed number is stated, not silently rescaled. |
| `raster-identical-bytes-differ` | Re-encoded at the same visual result. F18 again, on the raster path. |
| `image-added` | No left side. Blend, Split and Pixel diff disabled with their reason (F19). |
| `image-over-budget` | Above 16 megapixels. Pixel diff disabled with its reason; both renderings still shown (F17). |
| `undisplayable-blob` | An archive. `#unrenderable`, stating what it is and why nothing is compared. |

### 4.8 Deferred-scope fixtures — P2

Kept so behavior is defined even though structural support is deferred: `css-declaration-change`, `css-selector-change`, `inline-style-property-change`, `json-change`, `markdown-change`, `html-change`. Under DEC-004 all of these take the raw fallback path in v1; the fixtures assert that fallback is correct and labeled, not that structural output is good.

## 5. Repository-level and concurrency tests

Not file-pair fixtures; these need a scratch Git repository built by the test harness.

| ID | Test | Ref |
|---|---|---|
| R-1 | Base detection resolves via `origin/HEAD` | DEC-009 |
| R-2 | Base detection falls back to unique local `main`/`master` | DEC-009 |
| R-3 | Base detection prompts when nothing resolves | DEC-009 |
| R-4 | Detached HEAD produces defined behavior, no crash | OQ-008 |
| R-5 | Repository with no remote falls back to local base ref | DEC-010 |
| R-6 | Ahead-count shows explicit unknown, never a fabricated zero | DEC-012 |
| R-7 | All four scopes produce correct blob pairs | DEC-008 |
| R-8 | **No Git operation writes to the repository** — see §5.1 | DEC-003 |
| R-9 | File changed mid-analysis cannot produce a mixed-version diff | DEC-007 |
| R-10 | Scan depth honored; descent stops at first repository found | DEC-018 |
| R-11 | Symlink cycles and root escapes are refused | DEC-018 |

### 5.1 The read-only test

R-8 deserves its own mechanism rather than being a normal assertion, because it is the product's central safety claim.

Approach: snapshot the entire repository directory — file contents, mtimes, and `.git` internals — before an operation, run the operation, snapshot again, and assert byte-equality. This catches incidental writes that no reviewer would anticipate, notably the index rewrite that plain `git status` can perform.

This test should run against **every** Git operation the application can issue, enumerated explicitly, so that adding a new Git call without a corresponding read-only proof fails CI.

**What R-8 does not cover, since DEC-053.** The built-in terminal runs the *user's* commands, and those may write anything at all. R-8 is a claim about the application's own operations and remains exactly as strong as it was; it must never be quoted as though it covered the terminal. The terminal's own proofs are different in kind: the user's shell startup files hashed around a session (unchanged), a count of the places that may write to a PTY (DEC-028), and the single command the application composes checked against a real shell over hostile paths (DEC-056).

### 5.2 Concurrency

R-9 is a correctness test, not a UI test. Modify a file *while* analysis is in flight and assert the result is either the pre-change pin or the post-change pin, never a blend of the two.

## 6. Corpus sourcing

Fixtures should be drawn from **real code in the actual repositories** wherever possible, reduced to the smallest pair that still exercises the case. Synthetic fixtures miss the things that make real code hard: the decomposed `Ż`, the CRLF HTML packages, deeply nested monorepo paths, generated files.

Sourcing rule: fixtures are copied out of repositories, never referenced in place. The corpus must be stable and self-contained; a fixture that reads live repository state changes meaning as the repository changes.

## 6.5 Where the corpus stands

**47 fixtures as of M8-O** (2026-08-09), up from 9. §4 above is now **transcribed into `FixtureCatalog` and checked against the directory**: a P0 case named here and absent from `fixtures/` fails the suite, and a case that cannot be a file pair must name where it is proven instead. Thirteen P0 cases were missing on that check's first run, eight of them in §4.1 - see `22-experiment-log.md` -> **M8-O**. Every one runs through **both** paths — raw and structural — with T-0…T-11 asserted by number, and every one is recorded in `MANIFEST.json`, which is now read by a check rather than being dead data.

Which test is proven where, and what could fail it: **`26-coverage-audit.md`**. Read it before adding a fixture; the gaps it names are worth more than another instance of a case already covered.

## 7. What "done" means for the corpus

- Every P0 **case** named in §4 exists in the corpus or names where it is proven instead - checked, not asserted - and every fixture passes T-1 through T-11.
- The read-only proof (§5.1) covers every Git operation the application can issue.
- Property-based generators run in CI with a fixed seed for reproducibility plus a rotating seed to find new cases.
- Every invariant violation ever found in development is promoted into a permanent fixture. The corpus grows monotonically; nothing is removed because it started passing.

## 8. Open questions owned by this document

- Threshold for `huge-file` (OQ-043) and its unverified marking.
- Whether alignment-quality expectations are recorded as JSON structures or as approved snapshots. Snapshots are cheaper to author and much easier to review as diffs; they also rot silently if approved carelessly.
- Test harness and property-testing library (OQ-037) — blocked on the stack decision.
- How to keep fixture bytes safe from editor and formatter interference in practice (recorded hashes are the proposed mechanism, but tooling must respect them).
