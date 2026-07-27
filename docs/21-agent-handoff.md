# 21 — Agent Handoff

**Start here if you are new to this project.** This document is kept current; everything below reflects the state as of the last completed milestone.

Reading order: this document → `glossary.md` → `04-decision-log.md` → `19-roadmap.md`.

---

## 0. Where the project stands right now

**Last completed milestone: M5 — matching and alignment. 177/177 checks pass.**

| Milestone | State |
|---|---|
| M0 verification gates | Complete — DEC-042 confirmed |
| M1 engine skeleton, invariant harness | Complete |
| M2 Git layer | Complete |
| M3 raw diff end to end | Complete |
| M4 parsing and partition construction | Complete |
| M5 matching and alignment | Complete |
| **M6 classification, moves, trust surface** | **Next** |
| M7 refresh, watching, navigation | Not started |
| M8 hardening and beta | Not started |

Run everything:

```
swift run diffscope-verify          # 177 checks, exit 1 on failure
swift run -c release diffscope-verify --survey ~/YourProjects
swift run -c release diffscope-app  # the application
```

`DIFFSCOPE_SELFTEST=1 swift run -c release diffscope-app` proves the whole native pipeline headlessly and exits.

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

### What M6 should do next

1. Replace diagnostic segment labels (`anchor`, `filler`, `refined`, `moved-content`) with the DEC-017 classification vocabulary, so formatting-only grouping becomes possible.
2. Surface ambiguity and confidence in the renderer — the data exists in `NodeMapping.ambiguities` and is currently discarded before it reaches the UI (DEC-031 requires it be shown).
3. Wire `structuralDiff` into `diffscope-app`, which still calls `trivialModel` and therefore always shows raw.
4. Implement the Structural/Expanded mode pair as presentation flags over one renderer (DEC-013, INV-5).

Known weaknesses recorded rather than hidden: anchor selection is greedy by old-side position rather than a longest-increasing-subsequence; moves are only discovered where reconciliation reveals them; the native window layout has never been visually verified.

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
