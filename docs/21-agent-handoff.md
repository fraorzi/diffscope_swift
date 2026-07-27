# 21 — Agent Handoff

**Start here if you are new to this project.** This document is kept current; everything below reflects the state as of the last completed milestone.

Reading order: this document → `glossary.md` → `04-decision-log.md` → `19-roadmap.md`.

---

## 0. Where the project stands right now

**Last completed milestone: M7 part one — navigation, folding, and the keyboard map, on top of a complete M6. 288/288 checks pass.**

| Milestone | State |
|---|---|
| M0 verification gates | Complete — DEC-042 confirmed |
| M1 engine skeleton, invariant harness | Complete |
| M2 Git layer | Complete |
| M3 raw diff end to end | Complete |
| M4 parsing and partition construction | Complete |
| M5 matching and alignment | Complete |
| **M6 classification, moves, trust surface** | **Complete except formatting-only collapse**, which needs M7's folding |
| M7 refresh, watching, navigation | **Partly done** — navigation, folding and the keyboard map landed; FSEvents, debounce and scroll anchoring remain |
| M8 hardening and beta | Not started |

Run everything:

```
swift run diffscope-verify          # 288 checks, exit 1 on failure
swift run -c release diffscope-verify --survey ~/YourProjects
swift run -c release diffscope-app  # the application
```

`DIFFSCOPE_SELFTEST=1 swift run -c release diffscope-app` proves the whole native pipeline headlessly and exits: raw ŻABKA probe → structural render with a formatting-only label → INV-5 mode agreement across the webview → invisible-difference disclosure naming `U+0307` → a relocated block reported as one move. Adding `DIFFSCOPE_SNAPSHOT_DIR=/some/dir` writes `structural.png`, `expanded.png`, `disclosure.png` and `moved.png` of what the webview actually drew — the only way to check legibility, which the probe cannot see.

### What exists in code

| Module | Contains |
|---|---|
| `DiffScopeEngine` | Byte partition, canonical Myers diff, invariant validation, UTF-16 mapping, render contract. Imports only `Foundation`. |
| `DiffScopeGit` | Read-only Git layer: closed operation registry, four scopes, base cascade, discovery, parallel sweep |
| `DiffScopeSyntax` | tree-sitter parsing, partition construction, matcher, structural diff |
| `CTreeSitter`, `CTreeSitterTSX` | Vendored C, MIT |
| `diffscope-verify` | The whole check suite, headless |
| `diffscope-app` | AppKit shell + `WKWebView` |
| `Renderer/src` | CodeMirror renderer; build with `npm run build` in `Renderer/` |

### What M6 landed

- **Classification** (DEC-046). Byte-level equivalence tests over the aligned gap pair, computed before reconciliation because that is the only point where both sides of a change are known to correspond. Vocabulary: `whitespace`, `quote-style`, `trailing-comma`, `paren-only` → `formatting-only`; `reordering` → `potentially-behavior-affecting`. Measured on 120 real files: 97.8% recall on a whitespace-only edit, **0 false formatting-only claims of 1111** on a rename (M6-A).
- **The diagnostic labels are gone.** `anchor`, `filler`, `refined` and `moved-content` no longer exist; the suite asserts nothing outside the typed vocabulary reaches presentation. Note the trap this sprang: `reconcile` identified anchors by testing `classification == "anchor"`, so removing the strings silently changed its behaviour until anchor identity was passed explicitly — and that mechanism has since been replaced entirely by the move search.
- **The application shows structure.** `diffscope-app` runs `structuralDiff` for the structural modes and raw otherwise; a structural result that fails validation is discarded whole and replaced by raw with the reason shown (INV-4). Status line reports anchors, moves, formatting-only and ambiguity counts.
- **Raw · Structural · Expanded** as presentation flags over one model (DEC-013). Expanded simply drops the quietening of grouped marks, so INV-5 holds by construction and is checked both in the harness and across the webview.
- **Boundary snapping** (DEC-047, measured in M6-B). Changed ranges widen outward onto named-node boundaries within a 16-byte budget: **34.3% → 97.0%** of boundaries land on a syntax boundary, costing **+4.4%** bytes presented. Applied *after* labelling — widening the mask `reconcile` consumes would manufacture `moved` claims out of a presentation setting.
- **Invisible-difference disclosure** (DEC-023, measured in M6-C). `normalization-form`, `invisible-control` and `whitespace-lookalike` ride as a second axis beside classification, because the axes cross — a trailing non-breaking space is both formatting and invisible. Expanded names the codepoints. **Read M6-C before touching it:** Swift's `String ==` is canonical equivalence, so the obvious NFC test is always false and the detector silently detected nothing while its fixtures passed.
- **Confidence is indicated, not merely computed.** `confidenceFloor = 0.8` lives in the engine and the contract carries a computed `uncertain` flag, so a renderer cannot quietly redefine what counts as certain.
- **Deliberate move search** (DEC-038, measured in M6-D). Line-matched, byte-identical, linked pair by pair; 120 of 120 corpus files recognise a relocation with **0 false moves**. The old reconciliation-derived `moved` label is gone — it claimed a move while seeing one side only, so it could not check the condition DEC-038 names. The rejection floor is *counted* (`movesBelowFloor`), because DEC-038 records git's silent floor as the thing to avoid.
- **`runBundleFreshnessCheck` is now actually registered.** It was written in M5 and never called, so a stale renderer bundle would have shipped silently. Worth remembering as a class of defect: a check that is not run is not a check.

### Read this before planning M7

A benchmark after M5 (`22-experiment-log.md` → M5-B) established that **the structural layer contributes nothing to alignment quality** — and cannot, because INV-2 caps the "unchanged" set at whatever the canonical byte diff already found. Measured identical to a tenth of a percent across four perturbations on 120 real files each.

Its remaining value is three things: `moved` labels (bytes cannot express moves), classification, and **where a change is shown to begin and end**. The third is the slider problem: only 38% of canonical-diff hunk boundaries land on a tree-sitter node boundary, and 91% of files contain at least one misalignment.

**Boundary snapping now addresses the presentation half of that** (DEC-047) — 97.0% of boundaries land on a syntax boundary for +4.4% bytes shown. **Tie-breaking proper is still not done and cannot be under INV-2 as recorded**, because choosing a different equally-minimal alignment moves bytes out of the presented set while the validator recomputes one specific alignment and demands containment. Reopen DEC-021 first if you want it; do not attempt it as an implementation detail.

**Do not add work to the matcher on the assumption that better matching means better alignment. It does not.**

### What M7 landed so far

- **Change stops and folds are computed in the engine**, carried on the render contract in UTF-16, and merely executed by the renderer — so both are checkable headlessly (M7-A). Navigation follows the **canonical diff**, not the presented segments, because presented ranges are supersets after snapping and walking the superset drifts from the alignment INV-2 is stated against.
- **A fold is offered only where both sides are byte-equal.** Folding is the one presentation act that hides content, so it is the one place the "never suppress" invariant has teeth. Byte-equality also keeps the two panes aligned while folded.
- **The keyboard map lives in the menu bar** (DEC-016): modes ⌘1–3, scopes ⇧⌘1–4, ⌘N/⌘P next and previous change, ⌘E expand, ⌘[ ⌘] files, ⇧⌘[ ⇧⌘] repositories, ⌥⌘1–3 focus, ⌘O open in editor.
- **Editor integration** (DEC-015): a `{file}`/`{line}` template defaulting to WebStorm, overridable through `DIFFSCOPE_EDITOR`, never populated from repository content, with failure shown in the status line.

### What to do next

1. **FSEvents watching** (DEC-027, `node_modules` excluded) with the trailing-edge debounce and cap of DEC-026, and R-9's mid-analysis-change fixture.
2. **Scroll anchoring on refresh** (DEC-034) — anchor to the nearest unchanged segment above the viewport top. The fold pairing already relies on the same "must exist on both sides" argument, so the machinery rhymes.
3. **Formatting-only collapse** — the fold machinery now exists, so this is a small addition: group by `formatting-only` runs rather than by unchanged stretches.
4. F15's forced watcher drop and the fixtures that cannot occur locally (M8).

**Ambiguity display was withdrawn by DEC-045** — detection stays as a guard against ambiguous anchors, but no indicator is built.

Known weaknesses recorded rather than hidden: anchor selection is greedy by old-side position rather than a longest-increasing-subsequence; moved-and-modified content presents as delete plus add (accepted in DEC-038); the file list has no keyboard path yet (M7).

**When adding a field to `Segment`, grep for every place that rebuilds one.** `snapPresentation` merges neighbouring segments and silently dropped the move `link`, so a verified move reached the renderer unpaired while every harness check passed. The application selftest caught it — see M6-D.

The native window layout **has** now been looked at — repository list, file list, scope and mode controls, and the founding case rendering with children preserved. Everything below that in the interface (gutter, navigation, collapsed ranges) is still absent rather than unverified.

---

## 1. What this is

A macOS desktop application for reviewing diffs in local Git repositories. It aligns edits **structurally** rather than line-by-line, so a removed JSX wrapper reads as a wrapper change with its children preserved, instead of a large deletion followed by a nearly identical insertion.

It is not a website, not a Git client, not an AI review tool, and not a semantic diff. It never decides a change is unimportant.

## 2. The core invariant — the thing you must not break

> Structural analysis may change how edits are aligned, grouped, labeled, and presented. It must never suppress or discard any textual difference. The exact source text is the source of truth.

Formally (DEC-021, specified in `14-losslessness-and-trust-model.md`):

- **INV-1** both sides reconstruct byte-for-byte from the model
- **INV-2** every byte of the canonical diff's hunks lies **within** a presented range (containment, not intersection)
- **INV-3** "no changes" shown **iff** the sides are byte-equal
- **INV-4** every fallback is marked as a fallback
- **INV-5** Structural and Expanded produce identical segment sets

Comparison is on **bytes**. **Normalisation is never applied anywhere**, including inside the structural layer. This was settled by measurement: the corpus contains `'ŻABKA'` where `Ż` is `U+005A U+0307`, canonically equivalent to `U+017B` and **rendering identically**. Normalised comparison reports no difference for a real byte change.

## 3. Architecture (DEC-042)

**Swift shell and engine · tree-sitter via C API · CodeMirror 6 in `WKWebView` · Git CLI.**

| Layer | Choice | Why |
|---|---|---|
| Engine host | Swift | Byte-native tree-sitter offsets; every Node binding reports UTF-16 while typing it as bytes |
| Model | Total ordered **byte partition** | Makes INV-1 and INV-2 hold by construction |
| Renderer | CodeMirror 6 | Measured; 667 KB vs Monaco's 9.3 MB; neither offers external-diff APIs anyway |
| Git | CLI, `--no-optional-locks` always | Plain `git status` rewrites the index when the stat cache is stale |
| Matcher | From publications, node mapping only | Edit scripts cannot project onto a byte partition without reviving the move-swallows-delta bug |

## 4. Accepted scope

`18-version-one-scope.md` is authoritative. Headlines: macOS only; strictly read-only; never fetches; four comparison scopes; TS/TSX/JS/JSX structural, everything else raw and labelled; side-by-side only; three modes over two code paths; byte-identical moves only; multiple user-chosen roots with no default path.

## 5. Important rejected alternatives, and why

| Rejected | Reason |
|---|---|
| Normalising before comparison | Hides real byte changes — measured in this corpus |
| Edit scripts from the matcher | Cannot project onto a byte partition without losing move deltas |
| difftastic as an engine | Binary-only crate, no `src/lib.rs`; its JSON cannot reconstruct either file |
| GumTree source | LGPL-3.0 — implement from papers instead |
| libgit2 | CLI faster (46 ms vs 264 ms), healthier bindings, simpler licence, and Raw mode must match `git diff` by definition |
| oxc parser | Returns an **empty program** for 94.77% of truncated TSX while appearing to succeed |
| Babel parser | Throws on 91.67% of truncations; `errorRecovery` does not cover that error class |
| Executing repo-configured filters | Repository content would decide what executes — an RCE surface |
| Full-web architecture | Would require a permanent UTF-16→byte conversion surface whose failure mode is silent |
| Hiding clean repositories | A clean repository can be commits ahead of base |
| Default `~/WebstormProjects` path | WebStorm-specific; nothing in the product depends on WebStorm |

## 6. Questions that must not be silently re-decided

Each has a recorded rationale. Reopen explicitly against its revisit trigger, or not at all.

1. **Normalisation** — never, anywhere. Not reopenable; disqualified by measurement.
2. **Read-only** — no writes, no fetch, no exceptions. `--no-optional-locks` everywhere.
3. **Byte partition as primitive** — the invariants depend on it structurally.
4. **Matcher output as mapping, not script.**
5. **Formatting-only is a label, never a filter.**
6. **Raw mode always available**, on the same pinned pair.
7. **Ambiguity surfaced, never resolved arbitrarily.**
8. **No executing repository-defined commands.**
9. **No network, no telemetry, no runtime AI.**
10. **No editor-specific defaults** — the root-path lesson generalises.

## 7. Known risks

| Risk | Status |
|---|---|
| ~~`tree-sitter-typescript` #306~~ | **Resolved in M0-1.** Mischaracterised in planning: it is "JSX captures whitespaces in nested, multiline tags", not a range defect. Grammar remains stale (last release 2024-11-11) — a generic maintenance risk |
| ~~Engine↔renderer serialisation cost~~ | **Cleared in M0-2** — 5149 segments cross in 1.13 ms. Do not "optimise" with a smaller binary encoding; measured 6.5× slower |
| Byte↔UTF-16 conversion in the webview | The one place X-1's hazard survives. One function, independently tested |
| Matcher cost on dense JSX | The performance risk everywhere. Budget on **node count**, not bytes |
| tree-sitter error recovery | ~38.4% of bytes outside `ERROR` on truncated files — a quality ceiling, accepted |
| Auto-gc on large repositories | OQ-046, unverified |

## 8. Required experiments before implementation

M0 in `19-roadmap.md`: verify #306, measure serialisation, assess Swift binding health. **M0 can invalidate DEC-042** — that is why it is first.

## 9. Testing expectations

- Invariant tests apply to **every** fixture automatically; no per-case expectation file.
- T-1 and T-3 implemented **independently of the partition code**. X-1 found a defect that passes T-0 and T-1 and fails only T-3.
- R-8, the read-only proof, is a **snapshot** of `.git` before and after every Git operation. New Git call without a proof fails CI.
- Fixture bytes verified against recorded hashes — editors silently repair CRLF and NFD.
- Several fixtures cannot occur locally and must be constructed deliberately (`20-implementation-plan.md` §6).

## 10. File map

| Document | Role |
|---|---|
| `00-index.md` | Status, authority, reading order |
| `glossary.md` | **Terminology — read before the rest** |
| `04-decision-log.md` | **Authoritative for all decisions** (DEC-001 … 042) |
| `05-open-questions.md` | What is undecided (OQ-001 … 054) |
| `09-recommended-architecture.md` | The chosen architecture |
| `10-diff-engine-specification.md` | Engine behaviour |
| `11-git-behavior-specification.md` | Git interaction |
| `12-desktop-ux-specification.md` | Interface behaviour |
| `13-error-and-fallback-model.md` | Failure behaviour |
| `14-losslessness-and-trust-model.md` | **The invariant** |
| `15-test-corpus-plan.md` | Fixtures and invariant tests |
| `16-performance-and-scaling.md` | Budgets — estimates marked as such |
| `17-security-privacy-and-licensing.md` | Threat model, licences |
| `18-version-one-scope.md` | In, deferred, rejected |
| `19-roadmap.md` | Milestones M0 … M8 |
| `20-implementation-plan.md` | How to start |
| `22-experiment-log.md` | Spike results with methods |
| `research/` | Raw research with citations |

## 11. Milestone order

M0 verification gates → M1 engine skeleton and invariant harness → M2 Git layer → M3 raw diff end to end → M4 parsing and partition → M5 matching → M6 classification and trust surface → M7 refresh and navigation → M8 hardening.

**M3 is the first milestone with visible output.** M1 and M2 produce no interface. This is intentional: the trust machinery precedes what it protects, because retrofitting it means re-deriving every result already produced.

## 12. Definition of done

`18-version-one-scope.md` §"Definition of done". In short: every P0 fixture passes T-0…T-11; R-8 covers every Git operation; wrapper removal reads correctly; prop reordering never reports "no change"; parser failure degrades visibly; a 63-file working tree is reviewable from the keyboard; the application is demonstrably incapable of modifying a repository.

## 13. Keeping this synchronised

**§0 of this document is the entry point and must be updated at every milestone boundary** — last milestone, check count, what the next milestone should do, and any new known weakness. If §0 is stale, a fresh agent starts from a false picture, which is worse than starting from none.

A decision changed in code but not in `04-decision-log.md` is a **defect**. New decisions get the full format including rejected options and a revisit trigger. Measurements go in `22-experiment-log.md` with method. When research invalidates a decision, reopen it explicitly rather than working around it.

## 14. One habit worth copying

Several findings in this planning set **contradicted the reasoning that preceded them** — `.git` size does not predict status cost; libgit2 handles built-in CRLF correctly; `carrefour-inapp` is unborn-HEAD, not detached; a rendering measurement was void because `scrollTop` silently stayed 0.

Each was found by checking rather than assuming, and each is recorded **with the correction visible** rather than quietly edited out. Keep doing that. The corrections are more useful to you than the conclusions.
