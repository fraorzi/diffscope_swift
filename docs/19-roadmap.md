# 19 — Roadmap

**Status:** Phase 8. Milestone order is a recommendation with stated reasoning, not an arbitrary sequence.

---

## Ordering principle

**Build the trust machinery before the thing it protects.** The invariants, the fixture harness, and the read-only proof come first — not because they are glamorous, but because retrofitting them means re-deriving every result already produced. Spike X-1 demonstrated the concrete case: a coordinate defect passes T-0 and T-1 and fails only T-3, so a project without T-3 in place would have shipped it.

Second principle: **the raw path is not a fallback to add later.** It is the majority path by file count (DEC-004) and the destination of every failure mode. It is built first and is never "the degraded version".

---

## M0 — Verification gates ✅ COMPLETE (2026-07-27)

**Goal.** Settle the risks that could invalidate DEC-042 before any structure was built on it.

**Result: all three gates passed. DEC-042 confirmed.** Full methods and figures in `22-experiment-log.md`.

| Gate | Question | Outcome |
|---|---|---|
| M0-1 | `tree-sitter-typescript` #306 | **Mischaracterised in planning.** It is *"JSX captures whitespaces in nested, multiline tags"*, not a range defect. 1370 real `.tsx` files: **zero overlaps, 1370/1370 valid partitions** |
| M0-2 | Engine↔renderer serialisation | 5149 segments, 276 KB JSON → **1.13 ms** steady state. Not a bottleneck |
| M0-3 | Swift binding health | `swift-tree-sitter`: BSD-3-Clause, released 2026-03-18, 3 open issues, maintained in the tree-sitter org |

**Incidental findings carried forward.**
- ~26% of bytes land in **filler segments** (tree-sitter leaves exclude inter-token whitespace). Filler segments *are* the formatting — a natural home for `formatting-only`.
- `node-tree-sitter` throws at exactly **32,768 characters**. Irrelevant to this architecture; it would have silently broken Option B.
- **Process lesson:** #306 was carried as the top blocking risk through six documents and an architecture decision, on a one-line summary nobody had opened the source for. Verify the primary source before elevating anything to blocking.

**Non-goals.** Any application code. *(Respected — M0 produced only throwaway measurement code, per DEC-032.)*

**Skills.** Swift, tree-sitter internals.

---

## M1 — Engine skeleton and the invariant harness ✅ COMPLETE (2026-07-27)

**Goal.** A headless Swift engine that produces a valid byte partition and proves it.

**Scope.** Partition data structure; construction from bytes alone (no parser yet — every file is one fallback segment); INV-1 reconstruction; independent Myers-over-bytes `D` (DEC-039); INV-2 containment; INV-3; partition assertions; fixture harness; determinism check.

**Non-goals.** Parsing, matching, UI, Git.

**Dependencies.** M0.

**Deliverables.** Swift engine module, CLI test target, fixture runner.

**Tests.** T-0, T-1, T-2, T-3, T-4, T-7 — all passing against a trivial partition.

**Acceptance — met.** 68/68 checks pass. Fixtures run headlessly via `swift run diffscope-verify`, exit code 1 on failure. `D` is a separate implementation, cross-checked against an independent DP LCS on 600 random pairs.

**Outcome.** `DiffScopeEngine` (557 lines) imports only `Foundation`, so DEC-002's headless requirement is structural rather than aspirational. The harness was proven by injecting four deliberate defects and confirming each is caught.

**A decision was amended.** Measurement showed DEC-040's 2 MB file-size threshold had the wrong *shape*: unrelated 100 KB files did not finish in 120 s, while realistically-churned 2 MB validated in 153 ms. Replaced by a **work budget** (DEC-043); pathological input now returns in ~81 ms marked *unverified*.

**Toolchain note.** Neither `Testing` nor `XCTest` ships with Command Line Tools. The harness is a plain executable — which DEC-002 wanted regardless.

**Skills.** Swift, diff algorithms.

**Handoff note.** This milestone deliberately produces *no visible output*. Its value is that everything after it is checkable.

---

## M2 — Git layer ✅ COMPLETE (2026-07-27)

**Result: 101/101 checks pass.** 760 lines in `DiffScopeGit`.

Writes are **unexpressible**: `GitOperation` is a closed registry of factory methods with no case for `commit`, `fetch`, `add` or `reset`. `GitRunner` prepends `--no-optional-locks` to every invocation and records every operation label executed, so the suite can assert that nothing ran which was not proven read-only.

R-8 passed for all 16 registered operations, including under a stale stat cache — the condition where plain `git status` genuinely does rewrite the index.

Verified against the real corpus: 21 repositories, base resolution **17 / 3 / 1** exactly matching Phase 0. `carrefour-inapp` reports *no commits yet* with ahead **unknown**; `5bonsai` reports 0 changed but **2 ahead**.

**Performance correction:** sequential sweep 15,478 ms → parallel **478 ms**. The earlier "well under 100 ms" estimate was derived from a `status`-only sweep; a full snapshot issues ~7 Git invocations per repository (~147 spawns for 21 repos). 478 ms is the honest figure; the lever for improving it is fewer invocations, not more threads.

**Goal.** Correct, provably read-only access to the four scopes.

**Scope.** CLI invocation with `--no-optional-locks` everywhere; blob retrieval; four scopes (DEC-008); base detection cascade (DEC-009); remote-tracking preference and age (DEC-010); unborn-HEAD detection via `rev-parse --verify HEAD`; pinned source pairs; discovery across multiple roots and individual repositories (DEC-037); status sweep.

**Non-goals.** Any write path. Any UI.

**Dependencies.** M1 (for pinning).

**Tests.** R-1 … R-11, especially **R-8**, the snapshot-based read-only proof covering every operation issued.

**Acceptance.** R-8 passes and fails CI if a new Git call lacks a proof. Unborn HEAD handled without `symbolic-ref`.

**Risks.** OQ-046 auto-gc exposure on large repositories — unverified.

**Skills.** Git internals, Swift subprocess handling.

---

## M3 — Raw diff end to end ✅ COMPLETE (2026-07-27)

**Result: 125/125 checks pass.** First milestone with visible output.

Conversion **moved to the Swift side** (DEC-044) — the model crosses carrying UTF-16 offsets only, so JavaScript never sees a byte offset. Confined to one function, tested with the X-1 probe plus a **negative control** confirming the failure is still reachable without it. Two test bugs were found and fixed while writing those checks, both in the expectation rather than the code.

CodeMirror as two plain `EditorView`s, 356 KB bundle. DEC-035 validated live: syntax colour untouched, change meaning carried by underline and texture.

Native path proven headlessly via `DIFFSCOPE_SELFTEST`: the `ŻABKA` pair crosses Swift → `WKWebView` → CodeMirror rendering **identically** while differing in length by one, pin identity intact.

Still open: alignment gaps, collapsed regions, gutter, navigation (M6/M7); the native window's layout was not visually verified; every file is still one `fallback` segment until M4.

---

## M3 — original scope

**Goal.** The first thing a human can look at: repository list → scope → file list → raw side-by-side diff.

**Scope.** AppKit shell; `WKWebView` with CodeMirror; the engine↔renderer contract including **byte↔UTF-16 conversion in one tested function**; repository sidebar with two signals; flat grouped file list (DEC-033); Raw mode; linked scrolling.

**Non-goals.** Structural analysis of any kind.

**Dependencies.** M1, M2.

**Acceptance.** A real repository is reviewable end to end in Raw mode. Raw output agrees with `git diff`.

**Risks.** The conversion function is where X-1's hazard lives in this architecture. It gets X-1's discriminating probe as its test, including 4-byte characters and the corpus's decomposed `Ż`.

**Skills.** Swift, AppKit, WebKit, CodeMirror.

**Handoff note.** After this milestone the product is *useful*, if unremarkable. Everything subsequent improves alignment; nothing subsequent is required for correctness.

---

## M4 — Parsing and partition construction ✅ COMPLETE (2026-07-27)

**Result: 151/151 checks pass.** tree-sitter core and the TSX grammar vendored as MIT C targets (9 MB), 232 lines of Swift over them.

**The architecture's premise tested directly:** the X-1 probe against tree-sitter through its C API confirms **byte-native offsets** — no conversion layer, which is exactly what Option B could not have had.

**400 real `.tsx` files:** every partition well formed, every one reconstructs byte for byte, **23.3% filler** — independently confirming M0-1's 25.9% measured through a different binding and implementation.

`ERROR` leaves are labelled `.fallback` with confidence 0, so broken source degrades presentation and nothing else. Classification adds content-based fallback for binary, invalid UTF-8, and merge-conflict markers.

Still open: no matching yet — both sides are partitioned independently. That is M5.

---

## M4 — original scope

**Goal.** Real syntax trees converted into valid byte partitions.

**Scope.** tree-sitter via C API; partition construction (drop zero-width, clamp overlaps, fill gaps from bytes); file classification (DEC-004); parse-failure fallback (F1, F2).

**Dependencies.** M0, M1.

**Tests.** T-0 … T-11 on real TSX. Truncation corpus. **Valid files too** — the `JSDocComment` aliasing defect appears on 4 of 120 *valid* files, so a truncation-only suite misses it.

**Acceptance.** Partition assertions hold on every corpus file, valid and broken.

**Risks.** tree-sitter leaves only ~38.4% of bytes outside `ERROR` on truncated files — a quality ceiling, accepted in DEC-042.

**Skills.** Swift, tree-sitter, C interop.

---

## M5 — Matching and alignment ✅ COMPLETE (2026-07-27)

**Result: 177/177 checks pass.** The founding case works: wrapper removal preserves the children.

Matcher implemented from the papers (DEC-030), consumed as a node mapping only (DEC-029), `minimumHeight` 1 rather than the JSX-hostile default of 2.

**The invariant caught a real defect.** Prop reordering failed INV-2: a structural anchor claimed `disabled` was unchanged while the canonical byte diff had aligned the file differently and counted those bytes deleted. Fixed by reconciling structural labels against the canonical diff mask — the rule `14-…` §7.1 already stated.

Reconciliation applied in both directions also produced **character-level refinement for free**: the brief's comma example now reports the comma alone, 31 of 32 bytes unchanged.

Corpus: 120 real `.tsx` files, rename-like edit, **0 invariant failures, 92.3% mean unchanged**.

Still open: DEC-017 classification vocabulary, deliberate move search, LIS anchor selection, and wiring the structural model into the app.

---

## M5 — original scope

**Goal.** The product's actual value: wrapper removal that reads as a wrapper change.

**Scope.** Matcher from publications (DEC-030); node mapping only (DEC-029); ambiguity surfacing (DEC-031); nested refinement; JSX-appropriate hyperparameters — **not** the Java-derived `minHeight = 2`.

**Dependencies.** M4.

**Tests.** Founding-case fixtures; ambiguity fixtures; determinism.

**Acceptance.** Wrapper removal shows children preserved. Prop reordering never reports "no change". Ambiguity is visible, never silently resolved.

**Risks.** **The matcher is the performance risk everywhere.** Budget on node count. Cost-model tuning never finishes — treat it as taste, not correctness.

**Skills.** Tree-diff algorithms, JSX semantics.

---

## M6 — Classification, moves, and trust surface

**Scope.** Classification vocabulary; formatting-only grouping with disclosed counts; byte-identical move detection (DEC-038); confidence and parser-state indicators; invisible-difference disclosure (DEC-023); Structural and Expanded modes as one renderer with flags (DEC-013).

**Tests.** INV-5 mode agreement; formatting fixtures; Unicode fixtures including the real `ŻABKA` case.

**Acceptance.** Formatting changes grouped but never hidden. Structural and Expanded produce identical segment sets.

---

## M7 — Refresh, watching, and navigation

**Scope.** FSEvents with `node_modules` excluded (DEC-027); trailing-edge debounce with cap (DEC-026); scroll anchoring to nearest unchanged segment (DEC-034); complete keyboard map (DEC-016); previous/next change; collapsed ranges; editor integration (DEC-015).

**Tests.** R-9 mid-analysis change; F15 forced watcher drop; keyboard coverage — any pointer-only function is a defect.

**Risks.** Case-folding and NFC path matching (OQ-054); atomic-replace save patterns against live WebStorm.

---

## M8 — Hardening and beta

**Scope.** Performance budgets measured and enforced; degradation ordering (`13-…` §5); error copy following the "what was withheld, why, what remains trustworthy" form; the fixtures that cannot occur locally — `eol-filter-active`, forced watcher drops, oversized files.

**Acceptance.** All of §"Definition of done" in `18-version-one-scope.md`.

---

## Sequencing notes

- **M3 is the first milestone with visible output**, and it is deliberately late. M1 and M2 produce no interface. This is intentional and should be stated to anyone tracking progress, because it looks like slow going and is not.
- **M0 could invalidate DEC-042.** It is first for that reason.
- M4 and M5 are the only milestones where the product's distinctive value appears. Everything before is scaffolding; everything after is polish and trust surface.
- Parallelisable: M2 (Git) is independent of M4/M5 (engine) once M1 exists.
