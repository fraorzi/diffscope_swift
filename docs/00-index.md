# 00 — Index

> **Working name:** `diffscope` (placeholder). Final product naming is a deferred decision, tracked in [05-open-questions.md](05-open-questions.md) as OQ-001.

## What this project is

A local-first desktop application for reviewing diffs in local Git repositories.

The user opens the app, it discovers Git repositories under any number of user-chosen root directories — with no default path assumed, and with individually added repositories supported anywhere (DEC-036 amended, DEC-037) — presents them as selectable projects with their branch and change status, and lets the user inspect diffs for a chosen comparison scope (working tree, index, `HEAD`, merge-base against a base branch, branch-vs-branch, commit-vs-commit, and similar).

The distinguishing feature is the diff engine. Standard line-based diffs represent small structural frontend changes poorly: removing a JSX wrapper around many children shows as a large deletion followed by a nearly identical large insertion. This application aligns edits structurally so that such a change reads as what it actually is.

### What this project is NOT

- Not a website, cloud dashboard, browser extension, or hosted service.
- Not an AI code-review tool. AI is not required during normal application use.
- Not a "semantic diff" in the sense of deciding which changes matter. It never decides a change is unimportant enough to omit.
- Not dependent on GitHub, GitLab, Bitbucket, pull requests, or the existence of any remote.

## The core invariant

This is the single most important statement in the documentation set. Everything else is subordinate to it.

> **Structural analysis may change how edits are aligned, grouped, labeled, and presented. It must never suppress or discard any textual difference. The exact source text is the source of truth.**

Consequences that follow directly:

- "Formatting-only" is a **classification and a grouping**, never a filter. If formatting changes are collapsed by default, the count must be disclosed and expansion must be immediate.
- The application must never display "no changes" unless the exact old and new content are byte-equal.
- Every fallback to raw textual diffing must be **visible to the user**.
- A raw, exact, textual view must always be available as a control view.
- Parser failure must degrade **visual quality**, never **correctness**.

**The invariant is now formally specified and accepted.** See [14-losslessness-and-trust-model.md](14-losslessness-and-trust-model.md), settled by DEC-021 (formulation), DEC-022 (runtime enforcement), and DEC-023 (invisible-difference disclosure).

In brief: comparison is on **bytes**, normalization is **never** applied anywhere including inside the structural layer, display snaps outward to grapheme boundaries, and five invariants are enforced — reconstruction, coverage by containment, equality honesty, fallback visibility, and mode agreement. The decisive evidence was corpus measurement: this codebase contains a decomposed `Ż` (`U+005A U+0307`) in ordinary TSX source, which normalized comparison would report as unchanged after a real byte-level edit.

## Current planning status

**Planning complete. All phases 0–8 done.** 42 decisions recorded.

**M0 through M5 are complete (2026-07-27).** M0's gates confirmed DEC-042; M1 delivered the engine skeleton and invariant harness; M2 the Git layer; M3 the raw diff end to end; M4 parsing and partition construction; M5 matching and alignment. **177/177 checks pass.** Details in [22-experiment-log.md](22-experiment-log.md).

**Implementation is under way.** Code lives in `Sources/` and `fixtures/`.

```
swift run diffscope-verify
```

Read-only survey of a real directory tree:

```
swift run -c release diffscope-verify --survey ~/YourProjects
```

Run the application, or prove its whole native pipeline headlessly:

```
swift run -c release diffscope-app
```


Next milestone: **M6 — classification, moves and trust surface**, which turns diagnostic labels into the DEC-017 vocabulary and wires the structural model into the app. See [19-roadmap.md](19-roadmap.md). A new agent should start at [21-agent-handoff.md](21-agent-handoff.md).

**The stack is now chosen** (DEC-042, after five spikes): **Swift shell and engine, tree-sitter via its C API, CodeMirror 6 in a `WKWebView`, Git through the CLI.** See [09-recommended-architecture.md](09-recommended-architecture.md).

Spike results are in [22-experiment-log.md](22-experiment-log.md). They eliminated oxc and Babel as parser candidates and ruled out using UTF-16 offsets directly as partition coordinates. They did **not** settle tree-sitter vs TypeScript, Monaco vs CodeMirror, or CLI vs libgit2 — all three remain genuinely open going into Phase 7. Native macOS rendering was not measured and that gap is recorded rather than treated as a rejection.

*(Superseded — kept for history: during planning this section read "no application code exists, no stack has been chosen". Both ceased to be true when the product owner authorised M0 and then M1.)*

| Phase | Name | Status |
|---|---|---|
| 0 | Existing repository inspection | Complete — findings in this document |
| 1 | Product interview | Complete — DEC-001 … DEC-020 |
| 2 | Domain and competitor research | Complete — `06-domain-research.md` |
| 3 | Technical research | Complete — `07-technical-research.md` + 6 `research/` documents |
| 3.5 | Timeboxed spikes | Complete — X-1…X-4 in `22-experiment-log.md`; native rendering unmeasured |
| 4 | Product and UX specification | Complete — `12-…` and `13-…` |
| 5 | Diff-engine specification | Complete — `10-…`, `11-…`, `16-…` |
| 6 | Test corpus and validation plan | Draft exists (`15-…`); refine against Phase 5 |
| 7 | Architecture decision | Complete — DEC-042, Option C |
| 8 | Roadmap | Complete — `17-…` through `21-…` |

Phase order was modified from the original proposal and approved as DEC-001. Spikes were inserted as Phase 3.5; the test corpus (Phase 6) was moved **before** the architecture decision (Phase 7), so that the corpus specifies correctness rather than being written to flatter an already-chosen architecture.

## Which documents are authoritative

Only documents that exist are authoritative. Planned documents are listed below for structure but must not be treated as containing decisions until written.

| Document | Status | Authority |
|---|---|---|
| `00-index.md` | Exists | Authoritative for status and reading order |
| `04-decision-log.md` | Exists | **Authoritative for all accepted decisions** |
| `05-open-questions.md` | Exists | Authoritative for what is undecided |
| `glossary.md` | Exists | **Authoritative for terminology** |
| `01-product-brief.md` | Exists | Descriptive; decision log wins on conflict |
| `02-user-needs-and-workflows.md` | Exists | Descriptive; decision log wins on conflict |
| `03-feature-matrix.md` | Exists | Descriptive; decision log wins on conflict |
| `06-domain-research.md` | **Exists** | Synthesis; detail in `research/domain-existing-tools.md` |
| `07-technical-research.md` | **Exists** | Synthesis + index of all `research/` documents |
| `08-architecture-options.md` | **Exists** | Options considered and rejected |
| `09-recommended-architecture.md` | **Exists** | **Authoritative — accepted as DEC-042** |
| `10-diff-engine-specification.md` | **Exists** | Authoritative for engine behaviour |
| `11-git-behavior-specification.md` | **Exists** | Authoritative for Git interaction |
| `12-desktop-ux-specification.md` | **Exists** | Authoritative for interface behaviour |
| `13-error-and-fallback-model.md` | **Exists** | Authoritative for failure behaviour |
| `14-losslessness-and-trust-model.md` | **Exists** | **Authoritative for the invariant and its enforcement** |
| `15-test-corpus-plan.md` | **Exists** (draft, stack-independent) | Authoritative for invariant tests; refine after Phase 5/7 |
| `16-performance-and-scaling.md` | **Exists** | Budgets provisional; estimates marked as such |
| `17-security-privacy-and-licensing.md` | **Exists** | Threat model, licences |
| `18-version-one-scope.md` | **Exists** | Authoritative for v1 scope |
| `19-roadmap.md` | **Exists** | Milestones M0 … M8 |
| `20-implementation-plan.md` | **Exists** | How to start |
| `21-agent-handoff.md` | **Exists** | **Start here if you are new** |
| `22-experiment-log.md` | **Exists** | Authoritative for spike results |
| `research/losslessness-invariant.md` | Exists | Corpus measurements behind DEC-021 |
| `research/domain-existing-tools.md` | Exists | Phase 2 — known failure modes of existing tools |
| `research/stack-desktop-and-rendering.md` | Exists | Phase 3 — stacks and rendering |
| `research/git-integration-and-watching.md` | Exists (§1–3 verified, §4–5 delegated) | Phase 3 — read-only audit, measured |
| `research/parsers-and-tree-matching.md` | Exists (complete, measured) | Phase 3 — parsers, coordinate systems, matching |
| `research/git-mechanism-and-watching.md` | Exists (complete, measured) | Phase 3 — Git mechanism + file watching |

Three additions to the originally proposed structure were made and are justified in DEC-001: `glossary.md` (terminology must have one canonical home or later documents drift), `research/` (prevents `07` from growing into an unreadable monolith), and `22-experiment-log.md` (spike results are the evidence base for the architecture decision and need a durable home).

**Where documents conflict, `04-decision-log.md` wins.** If a specification document contradicts an accepted decision, the specification is wrong and must be corrected.

## Decisions that are final

Twenty decisions are accepted. Full records, including options rejected and revisit triggers, are in [04-decision-log.md](04-decision-log.md).

| ID | Decision |
|---|---|
| DEC-001 | Planning process: interleaved phases, spikes at 3.5, corpus before architecture |
| DEC-002 | Platform: **macOS only, permanently** |
| DEC-003 | **Strictly read-only** in version one |
| DEC-004 | Structural diff scope: **TS / TSX / JS / JSX only**; all else raw, labeled |
| DEC-005 | Single window, sidebar + diff pane; last repository remembered |
| DEC-006 | Eager parallel status sweep at launch, refresh on focus |
| DEC-007 | Auto-refresh on file change, ~400 ms debounce, scroll anchor preserved |
| DEC-008 | Four comparison scopes; pickers deferred |
| DEC-009 | Base-branch detection cascade with per-repository override |
| DEC-010 | Prefer remote-tracking base ref; always display ref and age |
| DEC-011 | **Never fetch** in version one |
| DEC-012 | Show all repositories with two independent signals |
| DEC-013 | Modes **Structural / Expanded / Raw** over two code paths |
| DEC-014 | **Side-by-side only**; unified deferred |
| DEC-015 | Configurable editor command, WebStorm default |
| DEC-016 | Accessibility: no color-alone meaning, full keyboard; screen reader deferred |
| DEC-017 | Presentation feature set; trust indicators mandatory |
| DEC-018 | Scan depth configurable, default 2, stop at first repository |
| DEC-019 | Follow system light/dark theming |
| DEC-020 | Personal tool; distribution undecided |
| DEC-021 | **Core invariant formalized** — bytes, never normalize, five invariants |
| DEC-022 | Invariant checks enforced at runtime below a size threshold |
| DEC-023 | Invisible-difference disclosure; homoglyphs deferred |
| DEC-024 | **Byte partition as the model primitive** — invariants hold by construction |
| DEC-025 | Git layer matches `git diff` filter regime and discloses it (amended: clean direction) |
| DEC-026 | Trailing-edge debounce with max-delay cap |
| DEC-027 | `node_modules` excluded from watching |
| DEC-028 | Filtered files fall back to raw; **never execute repo-configured filters** |
| DEC-029 | Matcher consumed as node mapping, **never as an edit script** |
| DEC-030 | GumTree algorithms implemented from papers, not ported (LGPL-3.0) |
| DEC-031 | Ambiguity surfaced as confidence, never resolved silently |
| DEC-032 | Spike authorization, rules, and ~3-day budget |
| DEC-033 | Flat file list grouped by workspace package |
| DEC-034 | Scroll anchored to nearest unchanged segment |
| DEC-035 | Change meaning outside the text; syntax colour untouched |
| DEC-036 | Plain directory picker — **no default path, no auto-detection** |
| DEC-037 | **Multiple roots plus individually added repositories** |
| DEC-038 | Move detection limited to byte-identical moves in v1 |
| DEC-039 | Canonical diff `D` independently implemented (Myers over bytes) |
| DEC-040 | Partition assertions always; `D` check below 2 MB |
| DEC-041 | File list follows `git status` under an active filter |
| DEC-042 | **Architecture: Swift core + CodeMirror in `WKWebView` + Git CLI** |
| DEC-043 | Validation bounded by **work**, not file size (amends DEC-040) |
| DEC-044 | Byte↔UTF-16 conversion happens on the Swift side |
| DEC-045 | Ambiguity is detected but not surfaced in the interface |
| DEC-046 | Classification detectors are equivalence tests; shipped vocabulary is a subset |
| DEC-047 | Change boundaries **snapped outward** to syntax boundaries, never slid |
| DEC-048 | Formatting-only groups only where both sides span the same lines |
| DEC-049 | A pin is **refused**, not blended, while a file is still being written |
| DEC-050 | Structural budgets: 2 MB, 30,000 nodes, 10M counted match comparisons |

## Decisions that remain open

Everything else. The significant open items are enumerated in [05-open-questions.md](05-open-questions.md). The largest open areas are:

- The exact losslessness invariant and how it is automatically verified.
- The entire technology stack. **No stack has been chosen and none may be assumed.**
- Repository discovery, scanning, and refresh behavior.
- Base-branch detection and remote-staleness communication.
- Window and navigation model.
- The diff presentation modes and their names.

## Recommended reading order

For a new agent joining this project:

1. `00-index.md` (this file) — orientation and status.
2. `glossary.md` — terminology. Do not skip; terms here are used precisely and differ from casual usage.
3. `04-decision-log.md` — what has been decided and why.
4. `05-open-questions.md` — what has not.
5. Then whichever phase documents exist, in numeric order.

## Phase 0 findings — inspection of `~/WebstormProjects`

Performed read-only on 2026-07-26. No repository was modified. These are measurements of the product owner's actual working environment and should be treated as the primary design target, not as a hypothetical.

**Repository population**

- 21 Git repositories, all at depth 1 beneath the root.
- Zero nested repositories found within depth 5.
- Zero submodules (`.gitmodules` absent everywhere).
- Zero linked worktrees (no `.git` regular files; all are directories).
- 12 of 21 are pnpm monorepos (`pnpm-workspace.yaml` present).

**State at time of inspection**

- 8 repositories dirty, 13 clean.
- Largest working-tree change count: `mailingi-2025` with 63 changed files.
- One repository, `carrefour-inapp`, has an **unborn HEAD** — `.git/HEAD` points at `refs/heads/main`, but there are **zero refs and zero commits**. Everything in it is untracked.

  **Correction.** This was originally recorded here as "detached HEAD". That was wrong. The Phase 0 sweep used `git rev-parse --abbrev-ref HEAD`, which prints `HEAD` on stdout while emitting `fatal:` on stderr — and stderr was suppressed, so the output was misread as a detached state. Verified 2026-07-26: **no repository in this population is on detached HEAD.**

  The corrected case is the more dangerous one. `git symbolic-ref -q HEAD` returns `refs/heads/main` with **exit code 0** for this repository — so the standard detached-HEAD detection idiom reports "on branch main" for a branch that does not exist. Any base-branch or scope logic built on that idiom will be confidently wrong. All four DEC-008 scopes are undefined here, since there is no `HEAD` commit to compare against.

**Size distribution** — `.git` directory sizes span 204 KB to 1.5 GB; total roughly 3.5 GB. Four repositories exceed 100 MB.

**Measured status latency** (2026-07-26, warm filesystem cache, `git --no-optional-locks status --porcelain`):

| Repository | `.git` size | Status time |
|---|---|---|
| `mailingi-2025` (63 changed) | 1.5 GB | 70 ms |
| `polska-bezgotowkowa__website__nextjs` | 415 MB | 38 ms |
| `5bonsai__website__nextjs` | 675 MB | 35 ms |
| `they__they-digital__nextjs` | 725 MB | 33 ms |
| `philips__signify-wiz-euro__preact` | 124 MB | 28 ms |
| `theymail__email_tester` | 504 KB | 24 ms |

- Reading branch names directly from `.git/HEAD` for all 21 repositories: **52 ms** total.
- Full sequential `git status` sweep across all 21 repositories: **326 ms** total.

**Correction to an earlier inference.** An initial reading of this data predicted that scan cost would be highly non-uniform with a long tail, inferred from `.git` directory size. **Measurement contradicts this.** Repository history size does not predict status cost; cost tracks working-tree file count instead. The spread between fastest and slowest repository is roughly 3×, not orders of magnitude. An eager status sweep at launch is therefore affordable, which materially changes the design space for OQ-012.

Caveat: these figures are warm-cache. Cold-boot behavior is unmeasured and is a Phase 3.5 spike candidate.

**Read-only implementation note.** Plain `git status` may refresh and rewrite the index as a side effect. `git --no-optional-locks status` avoids taking the index lock and the associated write. Under DEC-003 this distinction is load-bearing: "read-only" is a claim about effects, not about which commands are conventionally considered safe. Every Git invocation must be audited on this basis in Phase 5.

**Branch naming** — Default branches split roughly evenly between `main` and `master` across the population. Feature branches are predominantly `feature/*`. **Base-branch detection cannot hardcode either name.**

**Prior art in the workspace** — No existing planning documents, prototypes, or experiments for this product. Nothing to reuse. `.claude/` at the root contains only `launch.json` and `settings.local.json`.

**Host toolchain present** — macOS 26.5.2, arm64. git 2.50.1 (Apple Git-155). Node 22.22.0, pnpm 10.34.4. Swift 6.2.4 (Command Line Tools only; **full Xcode is not installed**). Rust is **not** installed. This is recorded as environmental fact for Phase 3 research; it does not constitute or imply a stack decision.

## What the next agent should do

If you are picking this up mid-planning:

1. Read the documents in the order given above.
2. Check `05-open-questions.md` for the questions blocking your area.
3. **Do not resolve an open question by assumption.** Bring it to the product owner as a decision with options, trade-offs, and a recommendation, then record the answer in `04-decision-log.md` immediately.
4. **Do not write application code.** The planning phase ends only when the product owner explicitly declares it complete.
5. If new research invalidates an accepted decision, do not silently work around it. Reopen the decision explicitly, referencing its revisit trigger.
