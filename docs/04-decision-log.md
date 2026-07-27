# 04 — Decision Log

**This document is authoritative for all accepted decisions.** Where any other document contradicts a decision recorded here, that other document is wrong and must be corrected.

Terminology, including the meaning of each status value, is defined in [glossary.md](glossary.md).

Format for every entry: Identifier, Date, Topic, Status, Context, Options considered, Product owner's input, Recommendation, Final decision, Consequences, Revisit trigger.

"Product owner" throughout means the human directing this project. "Recommendation" is the recommendation that was put to them at decision time, recorded even where it was not followed.

---

## DEC-001 — Planning process and documentation structure

- **Date:** 2026-07-26
- **Topic:** Phase ordering for the planning process; structure of the documentation set.
- **Status:** Accepted

### Context

The original brief proposed phases 0–8, running product interview, then domain research, then technical research, then specifications, then test corpus, then architecture decision, then roadmap. Two ordering concerns were raised:

1. Some technical questions cannot be answered from documentation alone — for example whether a given parser's error recovery is usable on partially-typed JSX, whether a candidate engine is embeddable as a library or CLI-only in practice, and what Git latency actually looks like on the product owner's 1.5 GB repository. Choosing an architecture without measuring these would be guesswork.
2. If the architecture is chosen before the test corpus exists, the corpus tends to be written to flatter the chosen architecture. The corpus is the specification of correctness and should constrain the architecture, not follow it.

### Options considered

1. **Interleaved order with spikes and corpus-before-architecture.** Interview → domain research → technical research → timeboxed spikes (3.5) → UX spec → diff-engine spec → test corpus → architecture decision → roadmap, with small interview groups continuing throughout as research surfaces new decisions.
2. **All interview first.** Complete every product decision before research begins. Faster to a locked scope, but forces technical decisions without evidence, which later research reopens anyway.
3. **All research first.** Full domain and technical research plus spikes before any decisions. Maximum evidence, but risks deep research into scope the product owner would have cut in one sentence.
4. **Interleaved but without spikes.** Same order, no Phase 3.5. Cheaper, but the architecture decision would rest on vendor and documentation claims rather than measured behavior.

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

Interleaved order adopted:

```
0 inspection → 1 product interview → 2 domain research → 3 technical research
→ 3.5 spikes → 4 UX spec → 5 diff-engine spec → 6 test corpus
→ 7 architecture decision → 8 roadmap
```

Interviewing continues throughout in small, coherent groups rather than as a single batch.

Three additions to the proposed documentation structure were accepted as part of this decision:

- `glossary.md` — the brief requires precisely defined terms; without one canonical home, later documents drift in their usage.
- `research/` subdirectory — raw per-tool notes with citations, so that `07-technical-research.md` remains a readable synthesis rather than growing into a monolith no agent will read.
- `22-experiment-log.md` — durable home for Phase 3.5 spike results, which form the evidence base for the Phase 7 architecture record.

Documents are created when their phase runs, not pre-created as empty stubs.

### Consequences

- Phase 7 may not be finalized until Phase 3.5 results and the Phase 6 corpus exist.
- Spike code is disposable; only recorded findings survive. This must be respected — a spike that quietly becomes production code defeats the purpose and reintroduces unevaluated stack lock-in.
- The decision log will grow continuously rather than in one pass, and must be updated **immediately** when a decision is taken, not retrospectively.

### Revisit trigger

Reopen if the interview cadence proves to be blocking research progress for more than one working session, or if spike results arrive so early that the corpus-before-architecture sequencing becomes an artificial delay.

---

## DEC-002 — Platform scope

- **Date:** 2026-07-26
- **Topic:** Which operating systems version one, and the product generally, target.
- **Status:** Accepted with modification

### Context

The product owner works on macOS 26.5.2 (arm64). The brief listed macOS-only, cross-platform, and native-versus-cross-platform frameworks all as open research areas, and explicitly forbade choosing a stack in advance. This decision concerns **platform scope only** and deliberately does **not** select a stack.

### Options considered

1. **macOS-only for version one, with a deliberately portable core.** Ship macOS first, keep the diff engine platform-agnostic so that porting later stays cheap.
2. **Cross-platform from day one.** Linux and Windows supported in version one. Rules out macOS-native UI toolkits immediately and adds packaging, file-watching, and path-handling work before the core product is proven.
3. **macOS-only, permanently.** Commit to macOS indefinitely; allows deepest platform integration and permits the whole application, engine included, to assume macOS.

### Product owner's input

Selected option 3 — **macOS only, permanently.**

### Recommendation

Option 1 was recommended, on the grounds of asymmetric risk: a portable core stays portable at little cost, whereas cross-platform-first taxes every screen forever. The product owner chose the stronger commitment of option 3.

### Final decision

**macOS only, permanently.** Cross-platform support is not a product requirement and is not to be designed for. Linux and Windows are explicitly out of scope.

### Consequences

- macOS-native UI toolkits are now first-class candidates in Phase 3 research and are no longer penalized for lack of portability.
- **This still does not choose a stack.** A permanently-macOS application may be built with a native toolkit, or with Electron, Tauri, or another cross-platform runtime used in a macOS-only configuration. Phase 3 must still compare candidates on their merits — now weighted without any cross-platform criterion.
- **Headless operation of the diff engine remains a requirement, for testability rather than portability.** The Phase 6 fixture corpus must be executable without a UI, in CI. Any candidate architecture that can only run the diff engine inside a running macOS GUI application is disqualified on testing grounds. This consequence was raised at decision time and accepted.
- Platform-specific assumptions — file-system events, path semantics, sandboxing, notarization, code signing — may be made freely and should be documented where they affect design.
- Full Xcode is **not** currently installed on the host (Swift 6.2.4 Command Line Tools only). If Phase 3 recommends a stack requiring full Xcode, that installation is a prerequisite task, not a surprise.

### Revisit trigger

Reopen if any of the following occurs: demand appears for Linux or Windows support; a decision is taken to distribute the diff engine as a standalone CLI or CI tool for use beyond this application; or a Phase 3 candidate is otherwise clearly superior but is unavailable on macOS-native terms.

---

## DEC-003 — Write operations in version one

- **Date:** 2026-07-26
- **Topic:** Whether version one may modify repository state.
- **Status:** Accepted

### Context

The brief stated that version one "should probably be read-only" but explicitly required this to be discussed rather than assumed. The application's entire value proposition is trust: it claims never to hide a change. The product owner's repositories are actively worked in via WebStorm and the terminal, so any write path also introduces concurrency exposure.

### Options considered

1. **Strictly read-only.** No writes at all.
2. **Read-only plus stage/unstage of hunks.** Adds the most commonly wanted write operation.
3. **Full staging and commit.** Version one becomes a Git client.

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**Version one is strictly read-only.** The application performs no operation that modifies repository state, the index, the working tree, or Git configuration.

### Consequences

- A defect in version one cannot damage a repository. This is the property that makes the trust model credible while the diff engine is still unproven.
- Index-lock races and interference with concurrent WebStorm or terminal Git usage are avoided entirely in version one.
- `git fetch` remains prohibited as an automatic action; this is reinforced by, but independent of, this decision. Remote staleness must therefore be **communicated** rather than silently resolved — see OQ-006.
- Staging is positioned as a natural version-two capability. It requires a correct and trusted hunk model, which is precisely what version one establishes. Sequencing is therefore favorable rather than merely cautious.
- Read-only status should be **legible in the product**, not merely true. How prominently is a UX question, deferred to Phase 4.
- Non-mutating Git invocations that write to disk incidentally — for example commands that may refresh the index or create lock files — must be audited during Phase 5, since "read-only" is a claim about effects, not about command names.

### Revisit trigger

Reopen for version two once the diff engine has been validated against the Phase 6 corpus and the hunk model is proven. Any earlier reopening requires an explicit trust-model review.

---

## DEC-004 — Structural diff language scope for version one

- **Date:** 2026-07-26
- **Topic:** Which languages receive structural (non-line-based) diffing in version one.
- **Status:** Accepted

### Context

Structural diffing quality is not free per language: each format requires its own matching heuristics and its own fixture coverage. The product owner's repository population is dominated by frontend JavaScript and TypeScript work — Next.js, Astro, and Preact projects, twelve of them pnpm monorepos.

### Options considered

1. **TS / TSX / JS / JSX only.** Everything else falls back to a clearly labeled raw textual diff.
2. **Plus CSS, JSON, Markdown, HTML.** Broader coverage, roughly multiplying Phase 5 and Phase 6 work.
3. **Generic multi-language via one parser framework.** Superficially cheap, but without per-language matching heuristics and fixtures the structural output can be *worse* than plain text — which would violate the trust model in spirit.
4. **TS / TSX / JS / JSX plus CSS only.** Middle ground.

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**Structural diffing in version one covers TS, TSX, JS, and JSX only.** All other file types fall back to raw textual diff, clearly labeled as such in the interface.

### Consequences

- The fallback path is not a version-two concern. It must be built, specified, and tested in version one, because it is the path taken by the majority of file types. "Unsupported language" is a **first-class, tested state** from day one — this is a benefit of the decision, not a caveat.
- CSS, JSON, Markdown, and HTML structural support are **deferred**, not rejected. They remain candidates for version two. CSS is the strongest candidate given the frontend corpus.
- Phase 5 must specify how a file is classified into "structural" versus "fallback", including ambiguous and misleading cases: `.js` files containing JSX, `.ts` files containing TSX syntax, files with no extension, generated files, minified files, and files whose extension misrepresents their contents.
- Tailwind class handling must emerge from general nested-token comparison within string literals and from the TSX structural layer — not from a Tailwind-specific subsystem. The brief is explicit on this and it is reaffirmed here.
- Phase 3 parser research is narrowed but not trivialized: JSX and TSX support, error recovery on invalid or partially-typed source, and exact source-location preservation remain the decisive criteria.

### Revisit trigger

Reopen for version two, or earlier if Phase 6 corpus work reveals that a non-JS/TS format is common enough in the product owner's review flow that raw fallback is unacceptable in practice.

---

## DEC-005 — Window and navigation model

- **Date:** 2026-07-26
- **Topic:** How repositories and diffs are arranged in windows.
- **Status:** Accepted

### Context

The brief asked whether the project list and diff should share one window, whether repositories should open in tabs, and whether open repositories should be remembered. The population is 21 repositories, reviewed one at a time.

### Options considered

1. **Single window**, repository list in a sidebar, diff in the main pane, last-opened repository remembered.
2. **Single window with repository tabs**, restored on launch.
3. **Multiple windows**, one per repository.

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**One window.** Repository list in a sidebar, diff in the main pane. The last-opened repository is remembered across launches.

### Consequences

- No tab state, no tab restoration, and no per-tab staleness semantics to design or test. This is a meaningful reduction in the surface where a stale or mismatched view could appear.
- Side-by-side comparison of two repositories simultaneously is not supported. Accepted as a non-goal.
- Sidebar visibility, width, and collapse behavior become Phase 4 UX details.
- "Remembers last-opened repository" requires persisted application state. That state must be treated as a cache, never as a source of truth: if the remembered repository has moved, been deleted, or changed branch, the application must recover gracefully rather than trusting its own memory.

### Revisit trigger

Reopen if a workflow emerges that genuinely requires two repositories visible at once, or if repository switching proves frequent enough that re-selection friction becomes the dominant cost.

---

## DEC-006 — Repository status collection strategy

- **Date:** 2026-07-26
- **Topic:** How and when the repository list obtains branch and change-status data.
- **Status:** Accepted

### Context

An initial inference from `.git` directory sizes (204 KB to 1.5 GB) predicted severely non-uniform scan cost. **Measurement contradicted this** and the correction is recorded in `00-index.md`. Measured warm-cache figures: reading all 21 branch names from `.git/HEAD` takes 52 ms; a full sequential `git status` sweep of all 21 repositories takes 326 ms; the slowest single repository is 70 ms and the fastest 24 ms. Status cost tracks working-tree file count, not history size.

### Options considered

1. **Eager parallel sweep at launch**, refreshed on window focus.
2. **Progressive fill** — names and branches instantly, status filled per repository as results arrive.
3. **Lazy, on selection only.**
4. **Eager plus a continuous background file watcher** across all repositories.

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1, on the basis of the measurement above.

### Final decision

**Eager parallel status sweep at launch, refreshed on window focus.**

### Consequences

- Parallel execution across repositories is required; sequential execution at 326 ms would be perceptible at launch, parallel execution should be well under 100 ms at this scale.
- The list is fully informative on first paint, which preserves its primary value: seeing at a glance which repositories are dirty.
- Option 4 was rejected for version one specifically to avoid continuously watching 21 working trees, with the associated CPU and battery cost. Note this is a decision about the **repository list**; watching the **currently open repository** is a separate matter settled in DEC-007.
- All Git invocations used for status must use `git --no-optional-locks` or equivalent, to avoid the index write that plain `git status` can perform. Required by DEC-003.
- The measurement is warm-cache and at a scale of 21 repositories. Both limits are recorded in OQ-012 and remain open.

### Revisit trigger

Reopen if repository count grows substantially beyond the current scale (roughly, above 100), if cold-cache spike results in Phase 3.5 show launch-time cost materially worse than measured, or if the configurable root is pointed at a directory with a much larger or slower repository population.

---

## DEC-007 — Refresh behavior for an open diff

- **Date:** 2026-07-26
- **Topic:** What happens when a file changes on disk while its diff is displayed.
- **Status:** Accepted

### Context

Step 9 of the imagined workflow is that saving in WebStorm causes the application to refresh. The tension is that automatically replacing content can move the view while the user is reading it.

### Options considered

1. **Auto-refresh**, debounced, preserving file selection and scroll position.
2. **Banner** indicating the file changed on disk, refreshing only on user action.
3. **Hybrid** — the changed-file list updates live, the open diff waits for user action.
4. **Manual refresh only.**

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1, as the option matching the stated workflow most directly.

### Final decision

**Auto-refresh, debounced at approximately 400 ms, preserving file selection and scroll anchor.** The debounce interval is provisional and subject to tuning.

### Consequences

- The **pinned source pair** model is mandatory, not optional. Every displayed diff is bound to a content hash pair for both sides; recomputation produces a new pin atomically. This makes a *mixed-version diff* structurally impossible rather than merely unlikely. This would have been required under any of the four options, but auto-refresh makes it urgent.
- File watching is required for the currently open repository. This is narrower than the rejected option 4 in DEC-006, which would have watched all repositories continuously.
- "Preserve scroll position" is underspecified and cannot mean a raw pixel or line offset, since the content itself changes underneath. Anchoring must be semantic. Raised as OQ-038.
- Editors that save via atomic replace (write to a temporary file, then rename) generate file-system events that differ from in-place writes. The watcher must handle rename-based saves, which is the common case for JetBrains IDEs. To be verified in Phase 3.5.
- Debounce must be measured against real editor save behavior; a save can produce several events in quick succession.

### Revisit trigger

Reopen if auto-refresh proves disruptive in practice during beta use, in which case option 3 is the designated fallback rather than a redesign.

---

## DEC-008 — Comparison scopes in version one

- **Date:** 2026-07-26
- **Topic:** Which Git comparison scopes version one supports.
- **Status:** Accepted

### Context

The brief listed roughly seven candidate scopes. Two carry the daily loop: reviewing all local work before committing, and reviewing an entire feature branch. Scopes involving arbitrary commits or branches require picker interfaces, which are a substantial UI subsystem.

### Options considered

1. **Core four** — all local changes vs `HEAD`; unstaged vs index; staged vs `HEAD`; current branch vs merge-base of the detected base branch.
2. **Minimal two** — all local changes vs `HEAD`, and branch vs merge-base.
3. **Core four plus commit vs parent.**
4. **Full set** including branch-vs-branch and commit-vs-commit with pickers.

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**Four scopes in version one:**

1. All local changes vs `HEAD`
2. Unstaged working tree vs index
3. Staged vs `HEAD`
4. Current branch vs merge-base of the detected base branch

### Consequences

- **Base-branch detection becomes a version-one requirement**, not a nicety, because scope 4 depends on it. OQ-007 is now blocking and must be decided in the next interview group.
- No commit picker and no branch picker in version one. Branch-vs-branch, commit-vs-commit, and commit-vs-parent are **deferred**, not rejected.
- Detached HEAD, which exists in the current population (`carrefour-inapp`), constrains scope availability: scopes 1–3 remain meaningful, scope 4 may not. Behavior must be specified rather than left to fail. Tracked as OQ-008.
- Scopes 2 and 3 require the application to distinguish index state from working-tree state, which is also the foundation any future staging feature would need. This sequencing supports the version-two staging path described in DEC-003.
- Scope switching must preserve the selected file where that file exists in the new scope, and must degrade clearly where it does not.

### Revisit trigger

Reopen once version one is validated, or earlier if reviewing individual commits before pushing turns out to be a frequent need in practice.

---

## DEC-009 — Base-branch detection

- **Date:** 2026-07-26
- **Topic:** How the application determines which branch to compute a merge base against.
- **Status:** Accepted

### Context

DEC-008 made scope 4 (branch vs merge-base) a version-one requirement, which makes base-branch detection blocking. Measurement of the actual repository population on 2026-07-26:

| Signal | Count |
|---|---|
| `origin/HEAD` set | 17 of 21 |
| `origin/HEAD` unset but exactly one local `main` or `master` | 3 of 21 |
| No remote, no `main`, no `master` | 1 of 21 (`carrefour-inapp` — **unborn HEAD**: zero refs, zero commits) |

Default branch names split `master` 12 / `main` 8. No repository has both `main` and `master` locally. Hardcoding either name is therefore invalid, but a cascade resolves 20 of 21 automatically.

### Options considered

1. **Cascade with per-repository override** — `origin/HEAD`, then a unique local `main`/`master`, then ask; detected value visible and overridable.
2. **Cascade without override.**
3. **Always ask on first open**, remembered thereafter.
4. **Configuration file only**, no detection.

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**Detection cascade:** `origin/HEAD` → unique local `main` or `master` → prompt the user. The detected base branch is **displayed**, not hidden, and can be overridden per repository. Overrides are stored in application configuration.

### Consequences

- Overrides must be stored in the **application's own** configuration, never written into the repository or its Git config. Required by DEC-003.
- The detected base must be visible in the interface so a wrong detection is diagnosable rather than mysterious. A silently wrong base branch produces a plausibly-shaped but entirely wrong diff, which is a trust failure of the same class as hiding a change.
- Repositories with a base branch that is neither `main` nor `master` — for example `develop` or a release branch — are handled by the override path rather than by additional heuristics.
- `carrefour-inapp` requires the prompt path on first open. This is the designed behavior, not a failure.
- Override storage must be keyed to something stable. Keying by absolute path is fragile if repositories are moved or renamed; the key choice is a Phase 4 detail.

### Revisit trigger

Reopen if the prompt path is hit frequently in practice, which would indicate the cascade is too narrow, or if repositories commonly need a base that the cascade cannot infer.

---

## DEC-010 — Which ref merge-base comparison uses

- **Date:** 2026-07-26
- **Topic:** Whether the base side of a merge-base comparison is the local branch or the remote-tracking branch.
- **Status:** Accepted

### Context

A local `master` is frequently stale because it is rarely checked out; a remote-tracking `origin/master` reflects the last fetch and is what a branch will actually merge into. Measured base-ref ages in the current population range from 4 days to 9 weeks, so staleness is material and varies widely.

### Options considered

1. **Prefer remote-tracking, fall back to local**, always displaying which ref was used and its age.
2. **Always use the local branch.**
3. **Ask per comparison.**

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**Use `origin/<base>` where a remote-tracking ref exists; fall back to local `<base>` otherwise. Always display which ref was used and how old it is.**

### Consequences

- The interface must show base-ref provenance and age, for example "origin/master, 9 weeks old". This is the primary mechanism for communicating staleness, which matters more given DEC-011 (no fetch).
- Repositories without a remote — `carrefour-inapp` today — take the local fallback path automatically.
- "Age" must be defined precisely: committer date of the tip commit of the base ref, not the date the ref was last fetched. The latter is closer to what the user actually wants to know but is not reliably recoverable. This gap should be stated plainly in the UI copy rather than papered over. Recorded as a Phase 4 copy requirement.
- Because the fallback is silent, the displayed provenance is what makes it honest. Displaying the ref name is therefore a correctness requirement, not decoration.

### Revisit trigger

Reopen if the distinction between fetch age and commit age proves misleading in practice, or if DEC-011 changes.

---

## DEC-011 — Fetch policy

- **Date:** 2026-07-26
- **Topic:** Whether the application ever runs `git fetch`.
- **Status:** Accepted

### Context

The brief prohibits silent fetching. A stricter question remained: whether an explicit, user-initiated fetch belongs in version one. `git fetch` is non-destructive but does write refs and objects into `.git`, so it is not read-only in the sense of DEC-003. Relevant environmental fact: WebStorm auto-fetches in the background by default, so remote-tracking refs on this machine are typically kept reasonably fresh without any action by this application.

### Options considered

1. **Never fetch in version one**; surface base-ref age instead.
2. **Manual fetch button**, explicit and user-initiated only.
3. **Prompt to fetch** when the base ref is older than a threshold.

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**The application never runs `git fetch` in version one.** Staleness is communicated by displaying base-ref age.

### Consequences

- The claim "this application never writes to your repository" holds without qualification. This is the strongest available form of the trust proposition and is worth more in version one than the convenience of a fetch button.
- No network access is required by the application at all in version one. This materially simplifies sandboxing (OQ-035), entitlements, and the privacy story.
- The user must fetch through WebStorm or the terminal. Given WebStorm's background auto-fetch, this is expected to be near-invisible in practice — an assumption to validate during beta.
- Age display (DEC-010) carries the entire staleness-communication burden and must therefore be prominent rather than incidental.
- A manual fetch button is the designated version-two addition if this proves annoying.

### Revisit trigger

Reopen if staleness causes real confusion during beta use, or if the assumption about WebStorm background auto-fetch turns out not to hold on this machine.

---

## DEC-012 — Repository list signals

- **Date:** 2026-07-26
- **Topic:** What the repository list displays, and whether clean repositories are shown.
- **Status:** Accepted

### Context

13 of 21 repositories are clean. An early instinct was to hide or de-emphasize them. Measurement invalidated this: `5bonsai__website__nextjs` has **zero uncommitted changes but is 2 commits ahead of its base branch**. Under DEC-008 scope 4, that repository has substantial review material despite being "clean". Uncommitted state and unreviewed branch state are **independent** signals; collapsing them into one dirty/clean flag hides exactly the feature-branch review case that scope 4 exists to serve.

Cost measurement: computing ahead-of-base counts for all repositories takes 504 ms sequential, negligible when parallelized alongside the DEC-006 status sweep.

### Options considered

1. **Show all repositories with two independent signals** — uncommitted file count and commits-ahead-of-base.
2. **Show all, single dirty/clean signal, sorted dirty first.**
3. **Hide clean repositories by default, with a toggle.**

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**All repositories are shown. Each displays two independent signals: uncommitted file count, and commits ahead of base.**

### Consequences

- The launch sweep (DEC-006) now also computes merge-base and ahead-count per repository. Measured cost remains acceptable; it should be re-measured once combined, since the combined sweep is what the user actually waits for.
- Repositories where the base branch cannot be determined (DEC-009 prompt path) cannot show an ahead-count. The list must render this as an explicit unknown state, not as zero. Displaying zero would be a factual misstatement of the same family the core invariant forbids.
- Detached HEAD affects ahead-count semantics and needs specification. Tracked as OQ-008.
- Sorting and grouping of the list are Phase 4 UX decisions and remain open.

### Revisit trigger

Reopen if the combined launch sweep measurably slows startup, or if a third signal proves necessary — for example commits behind base, which indicates a branch needing a rebase.

---

## DEC-013 — Diff view modes

- **Date:** 2026-07-26
- **Topic:** Structure, definition, and naming of the diff presentation modes.
- **Status:** Accepted with modification

### Context

The brief proposed three modes — *Smart*, *Exact*, *Raw Git* — while explicitly marking the names and definitions as non-final. On analysis, *Exact* as described is not a distinct engine: it is the structural renderer with collapsing disabled and whitespace rendered. Implementing it as an independent mode would create two structural rendering paths that can drift apart, which is a correctness risk in the component the product's credibility depends on.

Separately, the name *Smart* carries an implication the product explicitly forbids — that the tool decides which changes matter.

### Options considered

1. **Three named modes, two code paths.** Named modes for memorability and single-keystroke switching, with *Expanded* specified as a preset over the structural renderer.
2. **Two modes plus free toggles.** Structural and Raw, with independent whitespace and expansion toggles. Most flexible, but produces many combined states and makes "which view am I in?" hard to answer, weakening the trust story.
3. **Three fully separate implementations.** Maximum freedom, at the cost of two structural renderers that can diverge.
4. **Option 1 with the original names retained.**

### Product owner's input

Selected option 1, as recommended — including the renaming.

### Recommendation

Option 1, with names changed from *Smart / Exact / Raw Git* to *Structural / Expanded / Raw*.

### Final decision

**Three named modes — Structural, Expanded, Raw — implemented over exactly two code paths.**

- **Structural** — structural alignment, nested token and character highlighting, formatting changes grouped and collapsible but always disclosed by count.
- **Expanded** — the *same renderer* as Structural, with collapsing disabled and whitespace rendered visibly. A preset, not a separate engine.
- **Raw** — ordinary textual Git diff. The trusted control view, always available.

### Consequences

- Only two rendering paths exist and must be tested: structural and raw. Structural and Expanded cannot disagree about *what changed*, because they are the same code — only presentation flags differ. This is the point of the modification.
- Test requirement follows directly: for any source pair, Structural and Expanded must produce identical edit sets. Any divergence is a bug by construction. This belongs in the Phase 6 corpus.
- All three modes must operate on the same **pinned source pair** (DEC-007), so mode switching can never change which versions are being compared.
- Naming rationale must be preserved in the UX specification, so that "Smart" is not reintroduced later by an agent unaware of the reasoning.
- Which mode is the default is not yet decided; Structural is the presumptive default and should be confirmed in Phase 4.

### Revisit trigger

Reopen if Expanded turns out to need behavior that genuinely cannot be expressed as presentation flags over the structural renderer — which would indicate the preset framing is wrong.

---

## DEC-014 — Diff layout

- **Date:** 2026-07-26
- **Topic:** Side-by-side versus unified diff layout in version one.
- **Status:** Accepted

### Context

Supporting both layouts roughly doubles the work in alignment rendering, gap insertion, and synchronized scrolling — the component carrying the product's core value. Side-by-side suits move and wrapper visualization on a desktop display; unified is more compact, handles long lines better, and matches what Git prints.

### Options considered

1. **Side-by-side only.**
2. **Unified only.**
3. **Both, side-by-side default.**

### Product owner's input

Selected option 1, as recommended. Note this recommendation was explicitly flagged as the most loosely held of the group.

### Recommendation

Option 1.

### Final decision

**Side-by-side only in version one.** Unified layout is deferred.

### Consequences

- Long lines are the known weak spot of this choice and must be handled deliberately rather than left to overflow. Word wrap, horizontal scrolling, and linked scrolling behavior become required Phase 4 specification items, not optional polish.
- Minified files and very long single-line files are the worst case for this layout and interact with OQ-029.
- Narrow window widths degrade side-by-side more sharply than unified. Minimum usable window width must be specified.
- Raw mode still shows a conventional textual diff, so a Git-shaped presentation remains reachable even though unified structural layout is deferred.
- Deferring unified rather than rejecting it keeps the door open, but the renderer should not be architected in a way that makes adding it prohibitive.

### Revisit trigger

Reopen if reviewing long-line or minified content proves painful in practice, or if the product owner finds they habitually read diffs unified.

---

## DEC-015 — External editor integration

- **Date:** 2026-07-26
- **Topic:** How the application opens a file and line in an external editor.
- **Status:** Accepted

### Context

Step 10 of the imagined workflow is opening the relevant file and location in WebStorm. Hardcoding WebStorm is simplest; a configurable command template costs roughly the same and avoids editor lock-in.

### Options considered

1. **Configurable command template with WebStorm default.**
2. **WebStorm only, hardcoded.**
3. **Defer to version two.**

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**A configurable command template with file and line placeholders, defaulting to WebStorm.**

### Consequences

- Behavior when the configured editor is not installed, or the command fails, must be specified and must fail visibly rather than silently doing nothing.
- The exact invocation mechanism is still open and is Phase 3 research: URL scheme versus command-line launcher, and their relative reliability on macOS 26 with a possibly-unregistered launcher. Tracked in OQ-025.
- Launching an external process has sandboxing implications (OQ-035) and must be considered when that decision is taken.
- A user-supplied command template is a user-supplied command line. It executes with the user's privileges and must be treated as configuration the user is responsible for — but it must never be populated from repository content, since repository content is untrusted input.
- Line and column mapping must be defined against which side of the diff is being viewed. Opening "this line" from the old side of a deleted region has no meaningful destination in the current file; behavior must be specified.

### Revisit trigger

Reopen if the chosen invocation mechanism proves unreliable in Phase 3.5 spikes.

---

## DEC-016 — Accessibility commitments for version one

- **Date:** 2026-07-26
- **Topic:** The accessibility level version one commits to.
- **Status:** Accepted

### Context

The brief requires that indicators not depend on red and green alone. How much further version one goes was undecided. Full screen-reader support for a custom-rendered diff view requires hand-building an accessibility tree over rendered content, which competes directly with diff-engine work.

### Options considered

1. **Baseline plus keyboard** — no reliance on color alone, full keyboard operation, respect for system contrast and reduced-motion settings.
2. **Baseline plus keyboard plus VoiceOver.**
3. **Color-independence only.**

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

Version one commits to:

- **No meaning conveyed by color alone.** Every added/removed/moved/formatting indicator must also carry shape, texture, symbol, or label.
- **Full keyboard operation** of every function, including repository selection, scope switching, file navigation, change navigation, and mode switching.
- **Respect for system settings** — contrast and reduced motion.

Screen-reader support is **deferred**, with the gap documented honestly rather than left implicit.

### Consequences

- Keyboard operation being a commitment rather than a feature means the Phase 4 specification must define a complete keyboard map, not a handful of shortcuts. OQ-023 is promoted from open question to required specification work.
- Color-independence constrains the visual design of the diff itself, not just its chrome. This must be settled during Phase 4 design rather than retrofitted, since retrofitting non-color encodings into a finished diff renderer is expensive.
- "Reduced motion" implies any animated transitions — for example scroll anchoring on refresh under DEC-007 — must have a non-animated path.
- Deferring screen-reader support must be stated as a known limitation in user-facing documentation, not silently omitted.

### Revisit trigger

Reopen if the application is ever distributed beyond personal use (OQ-002), which would change the obligations materially.

---

## DEC-017 — Presentation features in version one

- **Date:** 2026-07-26
- **Topic:** Which optional diff-presentation features are in scope for version one.
- **Status:** Accepted

### Context

The brief listed roughly twenty candidate presentation features without accepting any of them. Before offering choices, a distinction was drawn: some of those features are **not optional**, because they are the mechanism by which the core invariant becomes visible. If structural matching degrades and the interface does not say so, the invariant is violated in practice regardless of what the engine computed internally.

### Mandatory — not offered as choices

These are requirements derived from the core invariant, recorded here so they are never treated as cuttable scope:

- Confidence indication.
- Parser-state indication.
- Fallback-region marking (every fallback visible).
- "Show raw for this region" action.
- Formatting-only grouping **with disclosed counts** and immediate expansion.

### Options considered (optional features)

Navigation essentials; syntax highlighting; move and wrapper visualization; search plus filter by change type. Minimap and personal annotations were recommended for deferral before the question was put — minimap as redundant with previous/next navigation at these file sizes, annotations as a separate product concern better served by the editor.

### Product owner's input

Selected: navigation essentials, syntax highlighting, move and wrapper visualization. **Search and filter-by-change-type not selected.**

### Recommendation

The three selected, as recommended.

### Final decision

**In scope for version one:**

- **Navigation essentials** — previous/next change jumping, collapsed unchanged ranges with expansion, changed-file list.
- **Syntax highlighting.**
- **Move and wrapper visualization.**
- Plus all mandatory trust indicators listed above.

**Deferred:** search within diff, filter by change type, minimap, personal annotations.

### Consequences

- Navigation is load-bearing, not convenience: `mailingi-2025` has 63 changed files today, and reviewing that without change-jumping is impractical.
- **Two color systems now coexist** — syntax highlighting and change indication — and DEC-016 forbids change meaning from depending on color. Their separation must be designed deliberately in Phase 4, not resolved by tuning colors late.
- Move and wrapper visualization splits into two halves of very different cost. **Wrapper** visualization is close to free once structural alignment works and is the product's headline case. **Move** visualization depends on move detection, which carries the known losslessness trap of discarding a moved region's internal delta (OQ-026). Accepting this feature does **not** pre-decide OQ-026; if move detection is cut, wrapper visualization survives independently.
- Deferring search is a real cost on large diffs and should be re-examined after beta use rather than treated as settled forever.
- Filtering was deferred partly on risk grounds: a filter that removes changes from view is very close to the thing the product promises never to do, and would need careful design to avoid reading as suppression.

### Revisit trigger

Reopen search and filtering after beta use on a large working tree. Reopen minimap only if navigation proves insufficient.

---

## DEC-018 — Repository discovery scan depth

- **Date:** 2026-07-26
- **Topic:** How deeply the application scans the configured root for repositories.
- **Status:** Accepted

### Context

All 21 repositories in the current population sit at depth 1 with no nesting, but the root is configurable, so this cannot be assumed to hold generally.

### Options considered

1. **Configurable depth, default 2**, stopping descent once a repository is found.
2. **Depth 1 only.**
3. **Full recursion with ignore rules.**

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**Configurable scan depth, defaulting to 2. Descent stops as soon as a repository is found.**

### Consequences

- Grouped layouts such as `clients/project-name` are discovered without configuration.
- Stopping descent at the first repository found means `node_modules` is never traversed inside a repository, and nested repositories are not surfaced by default. This is a deliberate simplification consistent with the current population having none.
- **Consequence for nested repositories and submodules:** they will not appear as separate entries under this rule. OQ-014 and OQ-015 must be decided against this default rather than independently, and encountering one must not cause a crash or a misreport.
- Depth being configurable means the scan cost measurements in DEC-006 are valid for the default only. A user-raised depth over a large tree changes the cost profile entirely.
- Symlinked directories inside the scan root can produce cycles or escape the root. Traversal must guard against this. Recorded as a Phase 5 requirement.

### Revisit trigger

Reopen if repositories are commonly missed at the default depth, or if scan cost becomes noticeable at higher configured depths.

---

## DEC-019 — Theming

- **Date:** 2026-07-26
- **Topic:** How the application's appearance and syntax theme are determined.
- **Status:** Accepted

### Context

The brief asked whether syntax themes should follow WebStorm, the system, or the application. Matching WebStorm requires reading and interpreting JetBrains configuration files, which are undocumented for this purpose and subject to change across updates.

### Options considered

1. **Follow system light/dark** with a built-in syntax theme.
2. **Match WebStorm's theme.**
3. **Application-specific, user-selectable themes.**

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**Follow the macOS system light/dark appearance, with a built-in syntax theme for each.**

### Consequences

- No dependency on WebStorm's configuration format and no breakage when WebStorm updates.
- Both the light and dark variants must independently satisfy the DEC-016 commitments — contrast, and no meaning by color alone. Two themes means two sets of verification, not one.
- Visual divergence from the editor is accepted. Since the application is a review tool rather than an editing surface, exact visual parity with WebStorm is not a goal.
- Theme switching must respond to the system appearance changing while the application is running, including mid-diff.

### Revisit trigger

Reopen if the visual mismatch with WebStorm proves distracting in practice.

---

## DEC-020 — Audience and distribution intent

- **Date:** 2026-07-26
- **Topic:** Who the application is for, and whether distribution is planned.
- **Status:** Accepted

### Context

This decision has long reach: it governs licensing obligations for any embedded or forked engine, whether code signing and notarization matter, whether an update mechanism is needed, and whether the screen-reader gap deferred in DEC-016 is acceptable.

### Options considered

1. **Personal tool, distribution undecided.**
2. **Personal now, public release intended.**
3. **Internal team tool.**

### Product owner's input

Selected option 1.

### Recommendation

No option was pushed as recommended; the question was genuinely the product owner's to answer.

### Final decision

**A personal tool. Distribution is undecided and deliberately left open.**

### Consequences

- Version one carries no obligations for code signing, notarization, an update mechanism, or user support.
- **Licensing must still be checked carefully during Phase 3.** "Distribution undecided" is not the same as "distribution excluded". Adopting a strongly copyleft engine would foreclose the option quietly, and foreclosing an open option without noticing is exactly the kind of decision this planning process exists to prevent. Phase 3 must record the licensing implications of every serious candidate against a possible future distribution, not merely against personal use.
- The DEC-016 screen-reader deferral is acceptable under this decision and would need revisiting if it changes.
- Sandboxing (OQ-035) is not forced by any store requirement, which widens the technical options in Phase 3.
- No telemetry, no cloud processing, and no network access remain in force — reinforced by DEC-011.

### Revisit trigger

Reopen if the product owner decides to share the application with colleagues or publish it. At that point DEC-016, licensing conclusions from Phase 3, and packaging all require review.

---

## DEC-021 — The core invariant, formally

- **Date:** 2026-07-26
- **Topic:** The precise, machine-checkable formulation of the losslessness invariant.
- **Status:** Accepted
- **Supporting research:** [research/losslessness-invariant.md](research/losslessness-invariant.md)

### Context

The brief asked whether "every changed byte" is the correct invariant. Corpus measurement answered it decisively rather than theoretically.

Of 6105 scanned source files, 3126 (51%) contain non-ASCII content, so character handling affects the majority of this corpus. Four files are not NFC-normalized, two of them ordinary source:

```
5bonsai__website__nextjs/src/app/[locale]/case-studies/page.tsx:168
    company: 'ŻABKA'   where  Ż = U+005A U+0307  (Z + COMBINING DOT ABOVE)
                       NFC would be U+017B
```

These encodings are canonically equivalent and **render identically**. If that string is retyped with a Polish keyboard, the file changes by real bytes with no visible change at all. This single case discriminates between all candidate invariants: comparing normalized text finds **no difference**, which would violate the core invariant outright.

Also measured: 34 files contain CRLF (no file mixes line endings), zero byte-order marks, zero invalid UTF-8.

### Options considered

1. **Compare on bytes**, snap display outward to grapheme boundaries, never normalize; coverage by containment.
2. **Same, but coverage by intersection** — a presented region need only intersect each changed hunk. Cheaper to satisfy, but permits presenting a one-byte marker for a five-hundred-byte change and still passing validation.
3. **Compare on Unicode scalars** rather than bytes. More natural text boundaries, but requires a decode step that must itself be lossless, and has no defined behavior for invalid UTF-8 or binary content.

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**Comparison is performed on bytes. Normalization is never applied anywhere — not as preprocessing, not as an option, and not inside the structural layer. Display regions are snapped outward to grapheme-cluster boundaries.**

Five invariants are adopted. `O` and `N` are the exact byte sequences of the old and new sides of a pinned source pair; `M` is the presentation model; `R` is the set of byte ranges `M` presents as changed, including edits, moves, formatting-classified changes, and fallback regions.

- **INV-1 Reconstruction** — `reconstruct_old(M) = O` and `reconstruct_new(M) = N`, byte-for-byte.
- **INV-2 Coverage** — for a canonical minimal diff `D` of `O` and `N` computed over bytes by a fixed deterministic algorithm with no structural input, every byte in any hunk of `D` lies **within** some range in `R`. Containment, not intersection.
- **INV-3 Equality honesty** — `M` presents "no changes" if and only if `O = N`.
- **INV-4 Fallback visibility** — every range in `R` produced by fallback rather than structural analysis is marked as such.
- **INV-5 Mode agreement** — Structural and Expanded produce identical `R` for a given pinned source pair.

### Consequences

- **The structural layer may never normalize.** A parser or matcher that normalizes identifiers or string literals for comparison would report a changed string as unchanged. This must be an explicit engine rule (OQ-045) so it is not reintroduced later as an optimization.
- Grapheme snapping is safe precisely because outward expansion is **monotone**: growing a presented region cannot push a changed byte outside it. Correctness is defined on bytes, readability achieved on graphemes, without conflict.
- INV-1 does **not** subsume INV-2. A model can reconstruct both sides perfectly while presenting a region as unchanged, because reconstruction data and presentation data are different parts of the model. Both checks are needed.
- Comparing on bytes gives uniform behavior for text, binary, invalid UTF-8, and unknown encodings, with no decode step that could itself lose information.
- The diff engine receives exact bytes and performs no EOL or encoding transformation. Whether Git applies `core.autocrlf` or `.gitattributes` filters when producing blob content is a separate hazard, delegated to Git integration research. The 34 CRLF files make this concrete rather than theoretical.
- The canonical algorithm defining `D` must be fixed and deterministic, since the invariant is stated relative to it. It need not be the algorithm used for presentation. Tracked as OQ-042.

### Revisit trigger

Reopen only if a measured case shows byte-level comparison producing unusable presentation that grapheme snapping cannot fix. Normalization is not reopenable — it is disqualified by the corpus.

---

## DEC-022 — Invariant enforcement at runtime

- **Date:** 2026-07-26
- **Topic:** Whether the invariant checks run in production or only in tests.
- **Status:** Accepted

### Context

Reconstruction and containment checks are linear in file size with sorted intervals; the cost centre is computing the canonical diff `D` itself. This makes runtime enforcement plausible but not free.

### Options considered

1. **Runtime below a size threshold**, tests unconditionally.
2. **Tests only.**
3. **Runtime always, no threshold.**

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**Invariant checks run at runtime for every file below a size threshold, and unconditionally for all fixtures in tests.** On violation, the structural presentation for that file is discarded and the view falls back to raw, marked visibly. Files above the threshold are marked **explicitly as unverified**.

### Consequences

- The invariant becomes an **enforced property rather than a claim**. A matcher bug on a file shape no fixture covers degrades visibly instead of shipping a silent omission to the user.
- A defined failure action exists, which means "the checker failed" is a designed state rather than a crash or an inconsistency.
- "Unverified" must be a visible state in the interface. Silently skipping validation above the threshold would itself be a trust violation of the same family the invariant forbids.
- The threshold value is a Phase 5 number and depends on performance budgets (OQ-031, OQ-043).
- Runtime enforcement provides defense in depth against the structural layer normalizing text (DEC-021), which is otherwise a silent failure mode.

### Revisit trigger

Reopen if runtime checking proves too costly at the measured threshold, or if profiling shows the canonical diff dominating diff latency.

---

## DEC-023 — Invisible-difference disclosure

- **Date:** 2026-07-26
- **Topic:** Disclosing differences that are not visually apparent.
- **Status:** Accepted

### Context

A requirement not present in the original brief, forced by the `ŻABKA` finding in DEC-021. When a region is marked changed but old and new render identically, the user sees a highlight containing no visible change. That reads as a tool bug and damages trust — ironically because the tool was being *more* correct than expected.

### Options considered

Which classes of invisible difference to detect and disclose in version one, offered as a multiple selection: normalization forms; zero-width and bidi controls; whitespace lookalikes; homoglyphs.

### Product owner's input

Selected normalization forms, zero-width and bidi controls, and whitespace lookalikes. **Homoglyphs not selected.**

### Recommendation

The three selected, as recommended. Homoglyphs were presented as the larger commitment.

### Final decision

Version one detects and explicitly discloses:

- **Normalization-form differences** in canonically equivalent sequences. Measured present in this corpus.
- **Zero-width and bidirectional control characters** — ZWJ, ZWNJ, zero-width space, soft hyphen, bidi overrides.
- **Whitespace lookalikes** — non-breaking space vs space, tab vs spaces, other Unicode space characters.

**Deferred:** homoglyph detection, which requires the Unicode confusables table (UTS #39).

### Consequences

- Disclosure must use a non-color indicator, per DEC-016.
- Expanded mode is the natural home for always-on codepoint revelation, consistent with its DEC-013 definition as the everything-expanded preset. This avoids adding a fourth mode.
- **Security consequence, acquired rather than designed:** bidi controls and homoglyphs are the mechanism behind the Trojan Source attack class (CVE-2021-42574), where source renders differently from how it compiles, and diff tools that render such changes invisibly are the delivery vector. Two of the three accepted classes defend against this. The deferral of homoglyph detection leaves that half of the attack surface undisclosed, which should be stated plainly in user documentation rather than left implicit.
- These checks operate on presented regions only, so their cost scales with change size rather than file size.

### Revisit trigger

Reopen homoglyph detection if copied content from external sources proves to be a real source of confusion, or if the security property becomes a stated goal rather than a side effect.

---

## DEC-024 — Byte partition as the internal model primitive

- **Date:** 2026-07-26
- **Topic:** The internal representation of a diff, and how INV-1 and INV-2 are satisfied.
- **Status:** Accepted — refines DEC-021
- **Supporting research:** [research/domain-existing-tools.md](research/domain-existing-tools.md) §5.1

### Context

DEC-021 defined the invariants but left the model shape open, with coverage checked **after the fact** by comparing presented ranges against a canonical byte-level diff. Domain research surfaced a stronger option: make the model itself a structure that cannot violate the invariant.

The finding driving this: the root cause of losslessness failures in existing tools is that they build a **tree whose nodes happen to carry positions**, rather than a **partition of the bytes**. Once information lives only in the tree, anything the tree does not represent — inter-token whitespace, blank lines, trivia — is unrecoverable. The research characterises this as fatal and irreversible, and notes **no existing tool builds the byte partition as the primitive**.

### Options considered

1. **Total ordered byte partition as the primitive.** The model is a partition over both files' bytes — no gaps, no overlaps, segment lengths summing to file length — with structural labels attached to segments. INV-1 and INV-2 hold **by construction**.
2. **Leave DEC-021 unchanged.** Any model shape; coverage validated after the fact.
3. **Partition plus retained runtime validation.** Belt and braces.

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**The internal model is a total ordered partition over the bytes of each side, with structural labels attached to segments.** Invariants:

```
no gaps · no overlaps · Σ segment lengths == file length
```

for both the old and the new side.

### Consequences

- **INV-1 (reconstruction) becomes trivial**: concatenating the partition in order *is* the file. Not a check — an identity.
- **INV-2 (coverage) becomes structural** rather than after-the-fact: every byte belongs to exactly one segment, and every segment is either labeled unchanged or is presented. There is no way to express a byte that is neither.
- The expensive part of DEC-022 runtime validation — computing a canonical diff `D` for comparison — is **no longer needed for coverage**. Cheap assertions on the partition itself replace it. DEC-022's threshold and failure action remain in force for the assertions that survive.
- **The structural layer must attach labels to segments, never replace segments.** A move regroups segments; it may not substitute for the segments it contains. This makes the OQ-026 move trap structurally impossible rather than merely forbidden.
- Zero-width parser artifacts break the partition. Specifically, tree-sitter `MISSING` nodes are zero-width and **must be excluded from the partition** and represented as annotations instead. Recorded in the parser research.
- The partition is defined over **bytes**, consistent with DEC-021. Grapheme snapping remains a display concern applied over segment boundaries.
- This is a significant constraint on the Phase 7 architecture: any candidate that cannot express a byte partition as its primary model is disqualified, regardless of other merits. That includes reusing difftastic as an engine — its model discards exactly this information.

### Revisit trigger

Reopen only if the partition model proves unable to express a required presentation, for example a case where a byte must legitimately belong to two segments. No such case is currently known.

---

## DEC-025 — EOL/encoding filter regime for worktree comparisons

- **Date:** 2026-07-26
- **Topic:** Which bytes are compared when one side is a committed object and the other is the working tree.
- **Status:** Accepted
- **Supporting research:** [research/git-integration-and-watching.md](research/git-integration-and-watching.md) §2, verified by local measurement

### Context

Measured: `git cat-file` and `git show` return **raw object-database bytes** with smudge/EOL filters **not** applied. Filters are applied on checkout into the working tree.

```
blob in ODB                 : 61 0a 62 0a          ("a\nb\n")
git cat-file -p HEAD:lf.txt : 61 0a 62 0a          filter NOT applied
worktree after checkout     : 61 0d 0a 62 0d 0a    filter APPLIED
```

Consequence: for DEC-008 scopes 1 and 2, the two sides come from different filter regimes. Where a filter is active, they differ on every line. A byte-exact comparison would present the whole file as changed — technically true, useless in practice, and **in disagreement with `git diff`**, which applies filters and correctly reports no change.

That disagreement matters disproportionately: Raw mode is the **control view** (DEC-013), whose entire purpose is to let the user check a structural claim against plain Git output. A Raw mode contradicting `git diff` destroys the property it exists to provide.

Measured current exposure: **0 of 21 repositories** set `core.autocrlf` or `core.eol`, and no `.gitattributes` contains `text`/`eol`/`crlf` directives. The 34 CRLF files are CRLF in the object database too. **The hazard is latent, not active.**

### Options considered

1. **Match `git diff`.** The Git layer produces the byte pair Git's own diff would use, filters applied consistently to both sides, with disclosure when a filter was applied.
2. **Always raw ODB bytes.** Most literal reading of the invariant, but shows whole files as changed under an active filter and contradicts `git diff`.
3. **Detect and warn without choosing.** Honest, but leaves undefined what is actually displayed.

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**The Git layer owns filter handling and produces the byte pair that Git's own diff would use.** Where a filter was applied, the Git layer **discloses** it.

### Consequences

- The engine contract is unchanged: bytes in, bytes out, no transformation (DEC-021 §4.2). The engine receives whatever pair the Git layer produced and never transforms it itself. The responsibility boundary moves; the invariant does not weaken.
- Raw mode continues to agree with `git diff`, preserving its role as control view.
- Filter application is a **transformation between disk and compared bytes**, so it must be disclosed. Otherwise the tool would silently compare something other than what is on disk — a trust violation of the same family the invariant forbids, merely relocated.
- **This cannot be validated against the current corpus**, because no repository has filters active. It requires a dedicated fixture (`fixtures/eol-filter-active/`) added to the test corpus plan, or it will be discovered in production after cloning a repository configured by a Windows collaborator.
- The Git layer must be able to determine whether a filter is active for a given path, e.g. via `git check-attr` — audited as non-writing.

### Revisit trigger

Reopen if a repository is encountered where matching `git diff` conceals something the user needed to see, which would indicate the disclosure mechanism is insufficient.

### Amendment, 2026-07-26 — direction specified, obtainability now open

Subsequent measurement showed the original wording, "filters applied consistently to both sides", is **ambiguous and satisfiable in two ways, only one of which reproduces `git diff`**.

**[Measured]** `git diff` normalises the **worktree side downward into object-database form** — the *clean* direction — rather than smudging the committed side upward. Proven two ways: `git hash-object --stdin --path` of a CRLF worktree file yields the ODB OID, and a custom `clean`/`smudge` driver produced patch text in cleaned form.

**Amended decision:** the compared pair is **both sides in cleaned (ODB) form**.

**[Measured] New problem: those bytes are not directly obtainable read-only.** There is no Git plumbing that emits cleaned bytes for a worktree file. `git cat-file --filters` applies the *smudge* direction, the wrong way. `git hash-object` emits only an OID, not content (and does not write without `-w`). Tracked as **OQ-049**, which is now blocking for any repository with an active filter.

**[Measured] Second problem:** under an active EOL filter, `git status` and `git diff` **disagree** — status reports ` M` while diff reports zero lines, and this persists after an index-refreshing status. The changed-file list and the diff view would contradict each other. Tracked as **OQ-051**.

Neither problem is reachable in the current corpus, since 0 of 21 repositories have filters active. Both would appear on first contact with a repository configured by a Windows collaborator.

---

## DEC-026 — Debounce shape for auto-refresh

- **Date:** 2026-07-26
- **Topic:** Refines DEC-007. The edge and cap behavior of the ~400 ms debounce.
- **Status:** Accepted

### Context

Measured (20 trials, simulated atomic replace): one atomic-replace save produces **5 FSEvents events** in an event span of p50 11.1 ms, max 13.3 ms, arriving in 1–2 callbacks. The target path appears twice and **never carries `ItemCreated`**; roughly 60% of events are `___jb_tmp___` / `___jb_old___` noise. **There is a window in which the target path does not exist.**

This reframes the 400 ms value chosen in DEC-007. It is roughly 30× the ~25 ms floor needed to coalesce a single save, so it is not a save coalescer — it is a **burst quiet-period detector**, which is a different and still-useful job.

### Options considered

1. **Trailing-edge with a maximum-delay cap.**
2. **Leading-edge.**
3. **Defer to a Phase 3.5 spike.**

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**Trailing-edge debounce — fire after quiet, not on the first event — with a maximum-delay cap** so that continuous saving cannot starve refresh indefinitely. The ~400 ms value from DEC-007 stands.

### Consequences

- Leading-edge is rejected on measured grounds: it can fire inside the window where the target path does not exist, because atomic replace unlinks before renaming into place.
- The max-delay cap is required, not optional; without it a file saved on a tight autosave interval would never refresh.
- **[Measured] `NoDefer` combined with a non-zero latency is the worst FSEvents configuration** — it splits one save into two callbacks separated by exactly the latency. Two coherent configurations were identified in the research; the chosen one must be recorded in the UX/implementation spec.
- The measurement simulated temp-write-then-rename rather than driving a real WebStorm save. Confirming against a live WebStorm remains a Phase 3.5 item.

### Revisit trigger

Reopen if live WebStorm behavior differs materially from the simulated atomic replace, or if the cap value proves wrong in use.

---

## DEC-027 — Exclude `node_modules` from file watching

- **Date:** 2026-07-26
- **Topic:** Watch scope for the currently open repository.
- **Status:** Accepted

### Context

Measured: the largest repository contains **89,714 paths**; excluding `node_modules` reduces this to **6,047** — a 93% reduction. `FSEventStreamSetExclusionPaths` has a hard limit of **8 paths** (verbatim from the local SDK header); the maximum number of top-level `node_modules` directories in this corpus is **3**, so the limit is not binding here.

Also measured: 40,000 file creations delivered 40,041 events with **zero drops**. Exclusion is therefore a CPU concern, not a correctness one.

### Options considered

1. **Exclude.** 2. **Do not exclude.** 3. **Exclude, but configurable.**

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**`node_modules` is excluded from watching**, via `FSEventStreamSetExclusionPaths`.

### Consequences

- The 8-path limit is comfortable at 3 today but is a hard ceiling. A monorepo with more top-level `node_modules` directories would exceed it, and that case needs defined behavior rather than silent truncation.
- Because drops were not observed, the **drop-handling path will not be exercised by normal use** — so it will ship untested unless deliberately tested. FSEvents can drop events under load and signals this; the recovery path (full rescan) must exist and be covered by a test that forces it.
- Exclusion is about the *watched* set only. It must not be confused with which files are *diffed*; a change inside `node_modules` that Git tracks would still be a real change.

### Revisit trigger

Reopen if a repository exceeds the 8-path exclusion limit, or if watch CPU proves acceptable without exclusion.

---

## DEC-028 — Repositories with active EOL/smudge filters

- **Date:** 2026-07-26
- **Topic:** Resolves OQ-049. What the application does for files where a Git filter is active.
- **Status:** Accepted

### Context

The DEC-025 amendment established that `git diff` compares both sides in **cleaned (ODB) form**, and that **no read-only Git plumbing emits cleaned bytes** for a worktree file: `cat-file --filters` applies the smudge direction, `hash-object` returns only an OID. Reproducing `git diff` exactly would require running the repository's configured filter commands.

### Options considered

1. **Do not support structural diffing for filtered files; fall back to raw with explicit disclosure.**
2. **Execute the repository's configured filter commands.**
3. **Implement CRLF conversion internally**, covering `autocrlf` and `text`/`eol` but not external drivers.

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**For files with an active Git filter, no structural diff is produced. The file falls back to raw, with explicit disclosure that a filter is active.**

### Consequences

- **Security: option 2 was rejected on more than convenience grounds.** Executing repository-configured filter commands means repository *content* decides what executes. For an application that scans an entire projects directory and may open any repository found there, that is a genuine remote-code-execution surface reachable by cloning a hostile repository. This reasoning must be preserved so the option is not revived later as a feature.
- Degradation is visible and consistent with INV-4. No silent divergence from `git diff` can occur, because no structural claim is made about these files.
- OQ-051 (`git status` and `git diff` disagreeing under an active filter) is **narrowed but not resolved**: the changed-file list still has to decide which of the two it follows, even though the diff view now falls back.
- Option 3 remains a plausible later improvement, since built-in CRLF conversion is well-specified and requires executing nothing. Deferred rather than rejected.
- Detecting whether a filter is active for a path requires `git check-attr` — already audited as non-writing.
- Untestable against the current corpus (0 of 21 repositories affected); requires the `eol-filter-active` fixture.

### Revisit trigger

Reopen if a repository the product owner actually uses turns out to have filters active, making raw fallback a daily cost rather than a theoretical one.

---

## DEC-029 — Matcher output is consumed as a node mapping, never as an edit script

- **Date:** 2026-07-26
- **Topic:** The interface between the structural matching layer and the byte-partition model.
- **Status:** Accepted
- **Supporting research:** [research/parsers-and-tree-matching.md](research/parsers-and-tree-matching.md)

### Context

Chawathe's durable split separates **matching** (which node corresponds to which) from **script derivation** (what sequence of operations transforms one tree into the other). Essentially all subsequent work competes on matching only.

The research finding: an edit script **cannot be projected onto a byte partition without reintroducing the "move swallows its delta" problem** — the exact failure DEC-024 was adopted to make structurally impossible. A script says "move this subtree there"; a mapping says "this node corresponds to that node", leaving the partition free to represent the bytes independently.

### Options considered

1. **Node↔node mapping only.**
2. **Mapping as the basis, with the edit script as a secondary classification signal.**
3. **Leave open until Phase 5.**

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**The structural layer consumes matcher output exclusively as a node↔node mapping. Edit scripts are never derived, consumed, or stored.**

### Consequences

- Preserves DEC-024's guarantee at the layer boundary. Segments are labeled using the mapping; they are never rewritten according to a script.
- Classification (formatting-only, reordering, potentially behavior-affecting) must be derived from the mapping plus the byte partition, not from script operations. This is more work than reading operation types off a script, and is the price of the guarantee.
- Also rules out **classical tree edit distance** (Zhang–Shasha O(n²m²), Klein, RTED) as an engine component: those algorithms **have no move operation at all**, making them the wrong *shape* rather than merely too slow. They remain useful as a **test oracle**, which is where the test corpus should use them.
- This is an interface decision, so changing it later is expensive — which is why it was taken now rather than deferred.

### Revisit trigger

Reopen only if classification proves genuinely underdetermined without script information, which would indicate the mapping is too lossy an interface.

---

## DEC-030 — GumTree algorithms implemented from publications, not ported

- **Date:** 2026-07-26
- **Topic:** Licensing exposure on the matching-algorithm side.
- **Status:** Accepted

### Context

Parser licensing carries no risk: every candidate is MIT, Apache-2.0, or BSD-3, with Biome dual MIT-OR-Apache. **The only copyleft exposure found is on the algorithm side — GumTree is LGPL-3.0.**

Under DEC-020 distribution is deliberately undecided, and the recorded consequence there was that adopting a strongly copyleft dependency would quietly foreclose that option.

### Options considered

1. **Implement from the publications** (Falleri et al. 2014 and successors), using no GumTree source.
2. **Accept LGPL-3.0** and use GumTree directly.
3. **Avoid the GumTree family entirely** and build a matcher from scratch.

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**Matching algorithms are implemented from published papers. No GumTree source code is copied, ported, or adapted.**

### Consequences

- Algorithms are not copyrightable; specific implementations are. Working from papers keeps the DEC-020 distribution option open at no licensing cost.
- **Discipline required:** reading GumTree source for *understanding* is fine and useful; transcribing it is not. Any agent implementing this must be told the distinction explicitly, since the repository is public and easy to consult.
- Option 3 was rejected as over-correction — it would discard a decade of comparative results for no legal benefit.
- Reimplementation carries correctness risk that a port would not. The Phase 6 corpus and a TED-based oracle (DEC-029) are the mitigation.
- **[Fact] Hyperparameters alone move 21.8% of cases** (DAT, IEEE TSE 2023), so published comparisons using defaults measure configurations rather than algorithms. Our implementation must treat hyperparameters as tunable and record the values used.
- **[Fact] `minHeight = 2` is hostile to JSX**: `<Item />` is a height-1–2 subtree that *should* match, and the Java-derived default would fail worst exactly where this corpus is densest. Do not inherit defaults.

### Revisit trigger

Reopen if reimplementation quality proves unreachable and distribution is definitively abandoned.

---

## DEC-031 — Ambiguity is surfaced, not silently resolved

- **Date:** 2026-07-26
- **Topic:** Resolves OQ-027 — policy for repeated identical nodes.
- **Status:** Accepted

### Context

**[Fact]** 76% of commits contain at least one instance of repeated identical siblings (TOSEM 2024), and JSX makes this worse. Ambiguity is the common case, not an edge case.

**[Fact]** GumTree's top-down phase **already partitions candidates into `unique()` and `ambiguous()` sets** internally. The information exists and is discarded. No existing tool exposes it.

### Options considered

1. **Expose the ambiguous set as confidence.**
2. **Expose it plus a five-level contextual tie-break** (siblings → ancestors → position-in-parent → textual → absolute position), the scheme RefactoringMiner independently converged on.
3. **Lower confidence only**, without surfacing the set.

### Product owner's input

Selected option 1, as recommended.

### Recommendation

Option 1.

### Final decision

**Ambiguous matches are surfaced to the user as reduced confidence with the ambiguity made visible. The matcher never resolves an ambiguous match arbitrarily and presents it as certain.**

### Consequences

- This is the **cheapest genuine differentiator identified in the entire project**: the information is already computed by the matching algorithm and merely thrown away by every existing tool.
- Directly satisfies the trust-model rule that ambiguity must lower confidence rather than resolve arbitrarily (`14-…` §7.4).
- The five-level tie-break of option 2 is **deferred, not rejected**. It improves match quality where ambiguity is resolvable; surfacing must work correctly first.
- Determinism is still required (T-7): where a tie is broken, it must be broken the same way every run. Surfacing ambiguity is not a licence for non-deterministic output.
- Requires UI design for "we are not sure which of these matched" that does not read as a malfunction — a Phase 4 item.

### Revisit trigger

Reopen the tie-break question once ambiguity surfacing is implemented and its real frequency in daily use is known.

---

## DEC-032 — Phase 3.5 spike authorization, scope, and rules

- **Date:** 2026-07-26
- **Topic:** Whether throwaway spike code is permitted during planning, and the spike budget.
- **Status:** Accepted

### Context

The brief prohibits beginning implementation during the planning phase. DEC-001 nevertheless accepted timeboxed spikes as part of planning, on the grounds that some questions cannot be settled by reading. That tension needed explicit resolution before any code was written.

Three research documents proposed roughly 23 spikes totalling more than two working weeks, with substantial overlap. Prioritisation was required.

### Options considered

**On authorization:** throwaway code permitted; measurement-only using what is already installed; or no code at all, proceeding directly to architecture.
**On budget:** focused (~3 days); minimal (~1 day); full (~6–7 days).

### Product owner's input

Authorized throwaway code. Selected the focused ~3-day budget. Both as recommended.

### Recommendation

As selected.

### Final decision

**Spike code is authorized, under binding rules:**

1. Spike code lives **only** in the session scratchpad. It is never placed in the project repository.
2. **No dependencies are added to the project.** Installations for spikes happen in scratchpad-local scopes.
3. No framework is initialized, no application components are created.
4. Only the **recorded result** survives, in `22-experiment-log.md`. The code is discarded.
5. A spike that starts becoming production code is a process failure — it reintroduces unevaluated stack lock-in, which is exactly what DEC-001 was designed to prevent.

**Budget: approximately 3 days, four spikes**, selected on the principle that spikes which **eliminate** options are worth more per hour than spikes which rank them:

| Spike | Question | Box |
|---|---|---|
| **X-1 Coordinate trap** | Do candidate parser/binding pairs report the offsets they claim, on non-ASCII content? | 3 h |
| **X-2 Rendering bake-off** | Can a candidate render this diff at acceptable speed? Hard stop at the box. | 2 d |
| **X-3 Broken-JSX survival** | tree-sitter and oxc on the same 4800-truncation corpus already run against TypeScript and Babel | 1 d |
| **X-4 libgit2 measurement** | Remove the asymmetry whereby the CLI leads only because it alone was measured | 4 h |

### Consequences

- X-1 is scheduled first deliberately: it **eliminates parser/binding combinations** rather than ordering them, and its result may reduce the scope of X-2 and X-3.
- Spikes deferred from the research documents' proposals are not rejected; they are unfunded pending X-1…X-4 results. Several may become unnecessary.
- **X-3 must include valid files, not only truncated ones.** Measurement showed TypeScript's leaf tiling fails on 4 of 120 *valid* files via `JSDocComment` trivia aliasing — a spike testing only broken input would miss it.
- The architecture decision (Phase 7) may not be finalized before these results are recorded, per DEC-001.

### Revisit trigger

Reopen the budget if X-1 or X-2 produces a result that invalidates a candidate class entirely, changing what remains worth measuring.

---

## DEC-033 — Changed-file list presentation

- **Date:** 2026-07-27
- **Topic:** Resolves OQ-041.
- **Status:** Accepted

**Context.** 12 of 21 repositories are pnpm monorepos with paths 6–8 levels deep. `mailingi-2025` has 63 changed files today. DEC-016 commits to full keyboard operation, which makes list dimensionality a real constraint rather than a stylistic one.

**Options.** Flat list grouped by workspace package; directory tree; flat list without grouping.

**Product owner's input.** Selected the grouped flat list, as recommended.

**Decision.** **A flat, one-dimensional list with group headers per workspace package, and middle-elided paths.**

**Consequences.**
- Keyboard navigation stays one-dimensional: next/previous file is a single key, with no branch traversal. Under DEC-016 this is the decisive property.
- Monorepo context is preserved by grouping, so two `page.tsx` entries in different packages remain distinguishable.
- Path elision must preserve the **start and end** of a path — the beginning identifies the package, the end identifies the file. Eliding the end would defeat the purpose.
- Group headers are not focusable targets in the keyboard order; they are labels. Otherwise navigation gains stops that carry no content.
- Requires detecting workspace packages, which is `pnpm-workspace.yaml` parsing at minimum. Files outside any package need a fallback group.

**Revisit trigger.** Reopen if a repository appears with enough packages that group headers themselves become the navigation problem.

---

## DEC-034 — Scroll anchoring on refresh

- **Date:** 2026-07-27
- **Topic:** Resolves OQ-038, refining DEC-007.
- **Status:** Accepted

**Context.** DEC-007 promises preserved scroll position across auto-refresh, but the content changes underneath. A line number does not survive an insertion above the viewport — which is the ordinary case when editing in WebStorm.

**Options.** Nearest unchanged segment; change index; line number.

**Product owner's input.** Selected nearest unchanged segment, as recommended.

**Decision.** **Anchor to the nearest segment labeled unchanged above the viewport top.**

**Consequences.**
- DEC-024 supplies segments natively, so the anchor needs no separate index structure.
- An unchanged segment exists on **both** sides by definition, so the anchor is well-defined for both panes of a side-by-side view — which a change-index anchor would not be.
- Required fallback: if the anchor segment is itself deleted by the incoming change, fall back to the nearest surviving unchanged segment above it, then to the top of file. This chain must be specified, not left implicit.
- Anchoring must be exact enough not to drift over repeated refreshes. Re-anchoring to a *different* segment each refresh would produce slow creep during a long editing session.
- Under DEC-016's reduced-motion commitment, re-anchoring must have a non-animated path.

**Revisit trigger.** Reopen if drift is observed across long editing sessions.

---

## DEC-035 — Separation of syntax colour from change indication

- **Date:** 2026-07-27
- **Topic:** Resolves OQ-040.
- **Status:** Accepted

**Context.** DEC-017 put syntax highlighting in scope; DEC-016 forbids meaning carried by colour alone. The two colour systems occupy the same pixels.

**Options.** Change indication outside the text; desaturate syntax inside changed regions; user toggle.

**Product owner's input.** Selected change-indication-outside-the-text, as recommended.

**Decision.** **Change meaning is carried by the gutter, underlines, and background texture — never by the colour of a token. Syntax highlighting is left untouched.**

**Consequences.**
- Satisfies DEC-016 structurally rather than by tuning: shape and texture carry the information independently of hue, so the colour-blind case and the greyscale case are handled by construction.
- Code stays fully readable inside changed regions, which is where it most needs reading. The desaturation option was rejected precisely because it degrades legibility exactly where attention is highest.
- Character-level intra-line changes must therefore be marked by underline or texture rather than by recolouring the changed characters.
- DEC-023's invisible-difference disclosure fits this model cleanly, since it was already required to use a non-colour indicator.
- Both light and dark themes (DEC-019) must be verified independently for texture legibility, not only contrast.

**Revisit trigger.** Reopen if texture-based indication proves too subtle at normal reading distance.

---

## DEC-036 — Behaviour when the configured root does not exist

- **Date:** 2026-07-27
- **Topic:** Resolves OQ-017.
- **Status:** Accepted

**Context.** `~/WebstormProjects` is only a default. It may be absent on a fresh machine or after the directory is moved.

**Options.** Directory-picker screen; error message; create the directory.

**Product owner's input.** Selected the picker screen, as recommended.

**Decision.** **An empty-state screen that invites the user to choose a root directory, with `~/WebstormProjects` offered as a suggestion.**
> ⚠️ **Superseded in part — read the amendment below.** The suggested path was removed on 2026-07-27. The empty-state screen stands; the suggestion does not.

**Consequences.**
- One state serves both first run and a moved directory, rather than two separate flows.
- **Creating the directory was rejected on trust grounds.** It is a write to the user's disk without being asked. Although outside any repository and therefore not a DEC-003 violation, it contradicts the same principle, and an application whose central claim is that it never writes should not open by writing.
- The same screen is the natural home for the DEC-009 base-branch prompt path and for a repository-not-found state.
- The picker must handle the sandbox question (OQ-035), since choosing an arbitrary directory is exactly what a sandboxed application cannot do without user-granted access.

**Revisit trigger.** Reopen if the empty state proves to be reached often enough that the suggestion should become an action.

### Amendment, 2026-07-27 — the suggested default is removed

The product owner observed that `~/WebstormProjects` is a **WebStorm-specific name**, and that a user of VS Code or any other editor would not have such a directory. Nothing in the product depends on WebStorm.

This is the same reasoning already applied in DEC-015, which rejected hardcoding WebStorm as the editor in favour of a configurable command. Consistency requires applying it to the root directory too. Under DEC-020 distribution is deliberately open, and an editor-specific default is exactly the kind of choice that quietly narrows it.

**Amended decision:** the empty state is a **plain directory picker with no suggested path and no auto-detection**. `~/WebstormProjects` carries no special status; it is simply what this particular user will choose.

The auto-detection option — shallow-scanning the home directory for folders containing several repositories — was offered and **rejected** in favour of predictability over convenience.

---

## DEC-037 — Multiple roots and individually added repositories

- **Date:** 2026-07-27
- **Topic:** How many locations the application draws repositories from. Supersedes the single-root assumption inherited from the brief.
- **Status:** Accepted

### Context

The brief assumed a single configurable root. Removing the WebStorm-specific default (DEC-036 amendment) exposed the underlying assumption: that all of a user's repositories live under one directory. In practice they are frequently spread — some under `~/work`, some under `~/code`, one on an external volume.

### Options considered

1. **Multiple roots plus individually added repositories.**
2. **Multiple roots only** — every repository must live under some scanned directory.
3. **A single chosen root**, as before but without the hardcoded name.

### Product owner's input

Selected option 1.

### Recommendation

Option 1.

### Final decision

**The user may add any number of root directories to scan, and may also add individual repositories located anywhere.** The repository list merges all sources into one view.

### Consequences

- **DEC-006** (eager parallel sweep) now spans all configured roots. Measured cost — 326 ms sequential for 21 repositories, negligible parallelised — was for one root; total cost now scales with total repository count across roots, which the user controls directly.
- **DEC-018** (depth 2, stop at first repository found) applies **per root**.
- Individually added repositories **bypass scanning entirely**, which also gives a clean answer to repositories that would otherwise be missed by the depth limit.
- The repository list must **disambiguate identically-named repositories** from different roots. Name alone is no longer a unique key.
- **DEC-009's per-repository base-branch overrides** were already noted as needing a stable storage key; multiple roots make the fragility of an absolute-path key worse, since the same repository could be reachable by more than one configured path.
- **Sandboxing (OQ-035) gets materially harder.** A sandboxed macOS application needs user-granted access per location, persisted across launches via security-scoped bookmarks. One root meant one grant; arbitrary roots plus individual repositories means managing a set of them, including revocation and stale bookmarks. This is now a first-order input to the sandboxing decision rather than a detail.
- Removing a root must not silently discard the per-repository configuration of repositories under it.

### Revisit trigger

Reopen if managing multiple roots proves to be overhead the user never actually needs, or if sandboxing constraints make arbitrary locations impractical.

---

## DEC-038 — Move detection scope in version one

- **Date:** 2026-07-27 · **Topic:** Resolves OQ-026 · **Status:** Accepted

**Context.** DEC-024 removed the *safety* problem — under a byte partition a move regroups segments and cannot swallow their delta. What remained was cost and quality. Documented precedent is discouraging: `git --color-moved` matches whole lines, so it cannot express moved-and-modified, and applies a 20-alphanumeric-character floor that silently drops small moves.

**Options.** Exact moves only; full detection with `innerDiff`; defer entirely to v2.

**Product owner's input.** Selected exact moves only, as recommended.

**Decision.** **Version one detects moves only where the moved bytes are byte-identical** — `Move { fromRange, toRange, innerDiff }` with `innerDiff` necessarily empty.

**Consequences.**
- Covers the common "a block moved unchanged" case at low cost, with a trivially checkable pass condition: the two ranges are byte-equal or it is not a move.
- Moved-and-modified content presents as delete plus add. **This is correct, merely less legible** — no difference is lost, which is the property that matters.
- Narrows DEC-017, where move and wrapper visualisation were accepted together. **Wrapper visualisation is unaffected** and stays in v1; it falls out of structural alignment nearly for free and is the product's headline case.
- Keeps the `Move` container shape in the model, so extending to `innerDiff` in v2 is an addition rather than a redesign.
- Test T-11 becomes trivially satisfiable in v1 but **remains in the suite**, because it guards the v2 extension.

**Revisit trigger.** Reopen for v2 once alignment quality on the fixture corpus is known.

---

## DEC-039 — The canonical diff `D` is an independent implementation

- **Date:** 2026-07-27 · **Topic:** Resolves OQ-042 · **Status:** Accepted

**Context.** INV-2 is stated relative to a canonical minimal byte-level diff `D`. `D` is never displayed; it exists solely to validate the presentation model.

**Options.** Myers over bytes as a separate implementation; histogram over bytes; reuse the presentation algorithm.

**Product owner's input.** Selected Myers over bytes, independently implemented, as recommended.

**Decision.** **`D` is computed by Myers over bytes, implemented independently of any algorithm used for presentation.**

**Consequences.**
- **Independence is the point, not the algorithm.** Sharing an implementation between the thing checked and the check means a common defect passes both — validation would confirm itself rather than test anything. Same reasoning that keeps T-1 and T-3 separate from the partition code: spike X-1 found a coordinate bug that **passes T-0 and T-1 while failing T-3**.
- Histogram rejected as complexity without benefit: better hunk *boundaries* are irrelevant when the only question is which bytes differ.
- `D` must be deterministic, since the invariant is stated relative to it, and operates on bytes — never decoded or normalised text (DEC-021).

**Revisit trigger.** Reopen if `D` becomes the measured bottleneck, which would argue for a cheaper independent check — not a shared one.

---

## DEC-040 — Runtime validation threshold

- **Date:** 2026-07-27 · **Topic:** Resolves OQ-043, refines DEC-022 · **Status:** Accepted

**Context.** DEC-024 split validation into two very different costs: partition assertions are linear and cheap; the independent `D`-based check needs a full byte-level diff.

**Options.** Assertions always plus `D` below 2 MB; everything always; a line-based threshold.

**Product owner's input.** Selected assertions always, `D` below 2 MB, as recommended.

**Decision.**
- **Partition assertions — no gaps, no overlaps, Σ lengths == file length, no zero-width segments — run always, for every file, without exception.**
- **The independent `D`-based check (INV-2) runs for files below 2 MB.** Above that the file is labelled **unverified**.

**Consequences.**
- The cheap structural guarantee is never skipped, so no file is ever wholly unchecked. **"Unverified" means the independent cross-check did not run** — not that nothing was validated. Interface wording must convey exactly that.
- A byte threshold matches the cost being bounded, since `D` is byte-level. A line-based budget tracks matcher cost, which is a different limit belonging in performance budgets.
- 2 MB is provisional and should be re-derived once `D` is measured on real content.
- Interacts with DEC-004: most files above 2 MB will be generated, minified, or non-JS/TS, hence already on the raw path.

**Revisit trigger.** Re-derive once `D`'s real cost is measured; reopen if unverified files become common.

---

## DEC-041 — Changed-file list follows `git status` under an active filter

- **Date:** 2026-07-27 · **Topic:** Resolves OQ-051 · **Status:** Accepted

**Context.** Measured: under an active EOL filter, `git status` reports ` M` while `git diff` reports zero lines, persisting after an index-refreshing status. DEC-028 routes such files to raw with disclosure, but the file list still needed a source of truth.

**Options.** Follow `git status` with disclosure; follow `git diff`; a separate list section.

**Product owner's input.** Selected follow `git status`, as recommended.

**Decision.** **The changed-file list follows `git status`.** The file appears as changed; the diff view shows raw with the active filter disclosed.

**Consequences.**
- The file genuinely differs from the object database on disk, so listing it is factually correct.
- Following `git diff` would **remove a file the user's own Git reports as modified** — hiding, the one thing the product promises never to do. The apparent inconsistency is real and belongs on screen, explained.
- Disclosure must explain the *discrepancy*, not merely note the filter. Otherwise the interface looks broken: list says changed, diff says nothing changed.
- Untestable against the current corpus (0 of 21 affected); requires the `eol-filter-active` fixture.

**Revisit trigger.** Reopen if the explanation confuses in practice; the separate-section option is the designated fallback.

---

## DEC-042 — Architecture: Swift core with web rendering (Option C)

- **Date:** 2026-07-27 · **Topic:** Resolves OQ-033 and OQ-010 · **Status:** Accepted
- **Supporting evidence:** [08-architecture-options.md](08-architecture-options.md), spikes X-1 … X-5

### Context

Four options were developed. The choices were not independent: spike X-1 established that every Node-hosted parser binding reports **UTF-16 while typing offsets as bytes**, so the host language determines whether the byte partition (DEC-024) gets native coordinates or needs a conversion layer.

Spike X-5 was then funded specifically to close the remaining unknown, because it removed the blocker from **two** options at once. It found native rendering viable with no performance cliff, and in doing so **changed the native risk from performance to construction effort** — virtualised panes, gap widgets, collapsed regions, gutter and navigation are weeks of work the web renderers supply ready-made.

### Options considered

A — full native Swift · B — full web · C — Swift core with web rendering · D — Rust core with web rendering.

### Product owner's input

Selected **C**, as recommended. The decision was deliberately deferred once, to fund X-5 first.

### Final decision

**Swift application shell and engine, rendering in `WKWebView` with CodeMirror 6, Git via CLI subprocess.**

| Layer | Choice |
|---|---|
| Shell and engine | Swift, AppKit |
| Parser | tree-sitter via its C API (byte-native) |
| Renderer | CodeMirror 6 in `WKWebView` |
| Git | CLI subprocess, always `--no-optional-locks` |
| Headless engine | Swift CLI target sharing the engine module |

### Consequences

- **Byte-native offsets with no conversion layer.** The X-1 silent-corruption class is structurally absent rather than mitigated.
- **Rendering is measured and supplied.** CodeMirror led every measured axis except view-zone insertion, at 1/14th Monaco's bundle size.
- **The only irreversible commitment is the engine↔renderer contract.** Either side stays independently replaceable — the property that distinguished C from every alternative.
- **Full Xcode is not required**, established by X-5: AppKit and TextKit 2 build with Command Line Tools via `xcrun --sdk macosx swiftc`.
- **Testability is arguably the best of the four**: engine headless in Swift, renderer testable in a browser harness, with a documented contract between them.
- Native macOS facilities remain directly available — FSEvents, appearance changes, accessibility, and the **security-scoped bookmarks** that DEC-037's multiple roots require.

### The sub-decision this forces, recorded honestly

**The parser question resolves to tree-sitter by architecture, not by merit.** TypeScript is unreachable from Swift, so the tree-sitter vs TypeScript comparison — which measurement could not settle, because the two were measured with **incomparable metrics** — is decided structurally.

This means adopting the candidate with the **less impressive error-recovery number**: on 4800 truncations tree-sitter never threw but left only ~38.4% of bytes outside `ERROR` spans, where TypeScript never threw and retained ~76% of its tree. The metrics are not comparable and do not establish that TypeScript is better — but they do not establish that it is not, and the architecture removes the option either way.

Consequence to carry forward: **alignment quality on partially-typed files is bounded by tree-sitter's error recovery.** This is a quality ceiling, not a correctness problem — `ERROR` regions become visibly marked fallback segments (INV-4).

Two related risks are now first-order rather than incidental:

- **`tree-sitter-typescript` is stale** relative to tree-sitter core: last release 2024-11-11, last `master` commit 2025-01-30, 47 open issues — including #306. **Verified in M0-1 and downgraded:** the issue is "JSX captures whitespaces in nested, multiline tags" — a text-node concern, not a range defect. It does not threaten the byte partition.
- Swift bindings for tree-sitter must be assessed for maintenance health; only the C API's byte-native property has been established.

### Git mechanism

**CLI**, resolving OQ-010. It led on status performance (46 ms vs 264 ms), binding health, licensing under DEC-020, and Raw-mode fidelity — where it is the reference by definition. libgit2's single measured advantage, correct unborn-HEAD handling, is replicated on the CLI by using `git rev-parse --verify HEAD` instead of the `symbolic-ref` idiom, which returns exit 0 and a branch that does not exist.

### Revisit trigger

**Both original revisit conditions have now been tested and cleared (M0, 2026-07-27).** Serialisation cost measured at 1.13 ms for a 5149-segment model — not material. #306 verified and downgraded: it is *"JSX captures whitespaces in nested, multiline tags"*, not a range defect, with 1370/1370 real files producing valid partitions.

Reopen only if a genuine grammar defect emerges that a byte partition cannot absorb, or if serialisation cost changes character on much larger files than measured.

---

## DEC-043 — Validation is bounded by work, not by file size

- **Date:** 2026-07-27 · **Topic:** Amends DEC-040 · **Status:** Accepted
- **Discovered by:** M1 implementation measurement

### Context

DEC-040 set the runtime validation threshold at **2 MB of file size**: partition assertions always, the independent `D`-based coverage check below 2 MB. That number was provisional and explicitly flagged for re-derivation once `D` was measured.

Measurement invalidated the *shape* of the rule, not just the number.

Myers is **O(N·D)** where `D` is the edit distance. For files with realistic churn, `D` stays small and cost is fine. For files that differ substantially, `D` grows with `N`, making the algorithm effectively **O(N²)**.

Measured, release build:

| Case | Result |
|---|---|
| 2 MB, ~1 edit per 2 KB | **153 ms**, exact, 1259 hunks |
| 1 MB, ~1 edit per 2 KB | 41 ms, exact |
| **100 KB, unrelated content** | **did not finish in 120 s** |

A 100 KB file therefore blew a budget that a 2 MB file met comfortably. **File size does not bound the cost.**

### Decision

**The canonical diff carries an explicit work budget. Validation is bounded by work performed, not by input size.**

- Default budget: **40,000,000 work units**, where work is charged per Myers `d`-iteration across the whole recursion.
- On exhaustion, `canonicalDiff` returns `.budgetExceeded(workUsed:)` rather than a partial or approximate result.
- The validator then reports the model as **unverified**, exactly as DEC-040 intended for over-threshold files — **not** as a violation.

### Consequences

- **Termination is guaranteed.** Measured: unrelated 100 KB / 400 KB / 1 MB pairs all return in ~70–81 ms with `budgetExceeded`, against ">120 s" before.
- **The validator never claims a violation it cannot prove.** Budget exhaustion means "not checked", never "failed". Reporting a violation here would force whole-file raw fallback (DEC-022) on models that may be perfectly correct.
- DEC-040's two-tier structure **survives unchanged in spirit**: cheap partition assertions always run; the expensive independent cross-check is bounded. Only the bound changed from bytes to work.
- The 2 MB figure is **withdrawn as a threshold**. It remains accurate as an observation — 2 MB of realistically-churned source validates in ~153 ms.
- "Unverified" is now reachable by two distinct routes — very large files and very dissimilar files. The UI wording from `12-…` §5.2 must cover both without implying the file is suspect.
- Files that are wholly rewritten are exactly where structural alignment is least valuable, so degrading to unverified there costs little.

### Measurement note carried forward

**Debug builds are ~260× slower than release** for this code — 78.5 ms versus 0.3 ms on the same 24 KB pair. Any performance figure taken from a debug build is meaningless. Budgets must be tuned against release builds only.

### Revisit trigger

Re-tune the 40M figure if it proves either too permissive (slow validations in practice) or too strict (common real diffs coming back unverified). Both are observable in normal use.

---

## DEC-044 — Byte↔UTF-16 conversion happens on the Swift side

- **Date:** 2026-07-27 · **Topic:** Amends the contract rule in `09-recommended-architecture.md` §5 · **Status:** Accepted
- **Discovered by:** M3 implementation

### Context

`09-…` §5 specified: *"Ranges cross the boundary as byte offsets, converted to CodeMirror's UTF-16 positions on the webview side, in one place, tested independently."*

Implementation showed the webview is the wrong side to convert on. JavaScript receives a decoded string; to map a byte offset it would have to re-encode that string to UTF-8 and count — work it has no reason to do, on data it did not produce. Swift already holds the bytes and can emit correct offsets in the same pass that serialises the model.

### Decision

**The Swift side converts. The model crosses the boundary carrying UTF-16 offsets only.** JavaScript never sees a byte offset and performs no conversion.

### Consequences

- The X-1 hazard is confined to **one Swift function** (`Utf16OffsetMapper`), on the side that owns the bytes. The intent of the original rule — one place, tested independently — is preserved; only the side changed.
- The webview cannot misinterpret an offset, because it is never given one in a unit it would have to convert.
- Conversion **refuses rather than guesses**: an offset falling inside a multi-byte sequence, an out-of-range offset, or invalid UTF-8 all throw. Content that is not valid UTF-8 is declared `unrenderable` with a notice, never mangled into replacement characters.
- Tested with the X-1 discriminating probe in both directions: the positive assertion checks the *unit* (not merely that a round trip works, which a consistently-wrong converter would also pass), and a **negative control** confirms that applying the UTF-16 offset to the byte buffer still yields plausible wrong text.
- Cost: the sender walks the byte array once per side to build the boundary mapping. Negligible next to the measured 1.13 ms transfer.

### Revisit trigger

Reopen if the renderer ever needs byte offsets for its own purposes, which would reintroduce a conversion on the JS side.

---

## DEC-045 — Ambiguity is detected but not surfaced in the interface

- **Date:** 2026-07-27 · **Topic:** Amends DEC-031 · **Status:** Accepted
- **Prompted by:** the product owner asking whether recognising repeated identical siblings is actually useful in review

### Context

DEC-031 accepted surfacing matcher ambiguity on the grounds that an ambiguous match could otherwise become a **confident wrong claim of "unchanged"** — and that no existing tool exposes it, making it a cheap differentiator.

M5 changed the facts. Structural labels are now **reconciled against the canonical byte diff** (see the M5 entry in `22-experiment-log.md`). Any wrong "unchanged" claim is corrected by the textual layer regardless of whether the matcher guessed the right pairing. **The safety rationale for surfacing ambiguity has therefore lapsed** — the protection is now provided by a different mechanism.

What remains is a usability question the product owner put directly: what does a reviewer do with *"I am not sure which of these three `<Item />` matched"*? The bytes are shown correctly either way.

### Decision

**Ambiguity detection stays. Ambiguity display is dropped.**

- The matcher continues to record ambiguity, and **anchoring continues to refuse ambiguous nodes**. That guard is roughly twenty lines already written and costs nothing.
- No ambiguity indicator is designed or built for the interface. DEC-031's UI obligation is withdrawn.

### Consequences

- Removes UI design work from M6 for an indicator of unproven review value.
- The "cheapest genuine differentiator" framing in DEC-031 is retired. **A differentiator is not the same as a useful feature**, and that conflation is what carried the original decision.
- `NodeMapping.ambiguities` remains part of the engine API and is still asserted by tests, so the information is available if a use for it appears.
- Confidence display (a separate DEC-017 item) is untouched by this.

### Revisit trigger

Reopen if a case appears where an ambiguous match produces a *misleading* result that reconciliation does not correct — most plausibly a wrong `moved` label rather than a wrong `unchanged`.

---

## DEC-046 — Classification detectors are equivalence tests, and the shipped vocabulary is a subset

- **Date:** 2026-07-27 · **Topic:** Implements `10-diff-engine-specification.md` §3.8 · **Status:** Accepted
- **Prompted by:** M6 needing an actual definition of `formatting-only`, which the specification listed as a vocabulary without saying how a label is decided

### Context

§3.8 derived its vocabulary by inverting SemanticDiff's suppression list: `paren-only`, `literal-base`, `escape-style`, `trailing-comma`, `quote-style`, `object-key-reorder`, `jsx-attr-reorder`, `jsx-whitespace`, `import-reorder`, `tailwind-class-reorder`, `arrow-vs-function`. It did not say what evidence attaches a label.

That matters more than it looks. A `formatting-only` label invites a reviewer to skim, so a wrong one is a **trust defect**, and no invariant catches it — mislabelling violates none of INV-1…5, exactly as the M5-B `reconcile` bug violated none.

### Options considered

1. **Pattern matching on node types** — classify from the tree (a `jsx_attribute` reordered under the same element, etc.).
2. **Equivalence tests on bytes** — normalise both sides of an aligned pair by a transformation that provably preserves everything it does not remove, and label only on exact equality.
3. **Heuristic scoring** — similarity thresholds with a confidence.

### Decision

**Option 2. A classification is attached only when the two sides of an aligned pair are byte-equal after a normalisation, and the vocabulary shipped is the subset for which such a test exists.**

Shipped: `whitespace`, `quote-style`, `trailing-comma`, `paren-only` (group `formatting-only`); `reordering` (group `potentially-behavior-affecting`).

Not shipped, and deliberately absent rather than approximated: `literal-base`, `escape-style`, `arrow-vs-function`, and the per-construct reorder names (`object-key-reorder`, `jsx-attr-reorder`, `import-reorder`, `tailwind-class-reorder`) — the general `reordering` covers what those distinguish, and splitting them needs tree context this test does not have.

`jsx-whitespace` is subsumed by `whitespace`: the test cannot tell JSX text from any other whitespace, and claiming it could would be a false precision.

Classification is computed on the **aligned gap pair, before reconciliation**. That is the only point in the pipeline where both sides of a change are known to correspond; reconciliation splits each side against the canonical mask independently and the correspondence is gone afterwards.

### Consequences

- A missing label is the failure mode, never a wrong one. Measured (M6-A): 97.8% of changed segments recognised on a whitespace-only edit, **0 of 1111 falsely claimed formatting-only** on a rename.
- Option 1 was rejected because the tree cannot see inter-token whitespace at all — filler is ~24% of bytes and is *where formatting lives*. Option 3 was rejected outright: a threshold makes "formatting-only" a guess, and this label is read as a promise.
- `reordering` is grouped `potentially-behavior-affecting`, never `formatting-only`. Spread props and object keys can change behaviour, so the grouping must not invite skimming.
- The vocabulary is closed and typed (`ChangeClass`), and the suite asserts no segment carries a name outside it — the M5 diagnostic labels (`anchor`, `filler`, `refined`, `moved-content`) can no longer leak into presentation.

### Revisit trigger

Reopen if a real review case is found where a shipped label is wrong, or where an absent one costs a reviewer time — the first is a defect, the second is a scope question.

---

## DEC-047 — Change boundaries are snapped outward to syntax boundaries, never slid

- **Date:** 2026-07-27 · **Topic:** Resolves the slider problem recorded in `22-experiment-log.md` → M5-B · **Status:** Accepted
- **Prompted by:** M5-B concluding that tie-breaking among equally-minimal alignments is the strongest remaining argument for keeping the matcher

### Context

M5-B measured that only 38.0% of canonical hunk boundaries land on a tree-sitter node boundary, and that 91% of files contain at least one misalignment. Diffs routinely begin immediately after a closing brace and end mid-structure. Myers' minimality does not select a unique alignment; where several are equally short it picks arbitrarily.

The obvious remedy is git's: **slide** the hunk along the file while the alignment stays equally minimal, and stop where it reads best. That is what "tie-breaking among equally-minimal alignments" means, and it is what M5-B recommended looking at.

### Why sliding was not implemented

Sliding moves bytes **out** of the presented set. INV-2 as recorded requires every byte of *the canonical diff's* hunks to lie within a presented range, and the validator recomputes those hunks with the same deterministic implementation. A slid presentation therefore fails validation by construction — not incidentally, but because the invariant names one specific alignment as the thing to contain.

Sliding could be made legitimate, but only by **reopening DEC-021** and restating INV-2 as *"the presented model corresponds to some minimal alignment"* — checkable, but a different and weaker property, and one where a defect in the check no longer has an independent implementation behind it. That is not a change to make in passing.

### Options considered

1. **Slide onto boundaries** — best legibility, requires reopening the core invariant.
2. **Snap outward onto boundaries** — widen each changed range to the nearest syntax boundary within a byte budget. Monotone, so containment survives; presents slightly more than the minimal change.
3. **Nothing** — accept 38%.

### Decision

**Option 2, with a 16-byte budget, applied as a presentation pass after labelling.**

Measured across 150 real files on the slider case (M6-B):

| Budget | Boundaries on a syntax boundary | Bytes presented vs minimal |
|---|---|---|
| 0 B | 34.3% | +0.0% |
| 8 B | 85.3% | +2.6% |
| **16 B** | **97.0%** | **+4.4%** |
| 64 B | 99.7% | +5.4% |

16 bytes takes almost all of the available gain; beyond it the curve is flat and the cost keeps rising.

### Consequences

- **This is not tie-breaking, and must not be described as one.** It makes a change *begin and end* where the syntax does, at the price of showing about 4% more bytes than strictly changed. The equally-minimal-alternative question stays open.
- Applied **after** reconciliation, never before. Widening the mask that `reconcile` consumes would let the extra bytes be read as evidence of a move, and `moved` is a claim about content rather than about where a mark begins.
- The extra bytes are unchanged content shown *inside* a change — the direction that makes a reviewer read more, never less. The opposite direction would be an INV-2 violation.
- A widened flank inherits the run's classification only where every change in that run agrees on one; a run containing an unclassified change stays unclassified.
- Budget lives in `MatcherSettings.boundarySnapBudget`, so 0 is a supported configuration and is used as the negative control in the suite.

### Revisit trigger

Reopen if the 4% overhead proves visible as noise in review, or if a case appears where snapping merges two changes a reviewer needed to see as separate. Reopen DEC-021 first — not this decision — if true sliding is wanted.

---

## DEC-048 — A formatting-only group is offered only where both sides span the same lines

- **Date:** 2026-07-27
- **Topic:** The collapse condition for formatting-only runs (DEC-017's mandatory grouping, applied to the class DEC-046 defines).
- **Status:** Accepted

### Context

M7's fold machinery hides **unchanged** content, and refuses to unless the two sides are byte-equal. A formatting-only group hides content that *differs* by definition, so that condition cannot carry over — but the reason behind it still applies. The panes scroll together, so a group that removes four lines on the left and five on the right slides everything below it out of correspondence, and the misalignment persists for the rest of the file.

Measured while implementing: a reindent is almost always an **insertion**. The old side has no changed bytes at all, so a grouping driven by one side's segments finds nothing to pair on the left and offers nothing.

### Options considered

1. **Group by canonical hunks, offer only where both sides span the same number of lines.**
2. **Group by per-side runs of formatting-only segments.** Finds nothing for the ordinary reindent, for the reason above.
3. **Group regardless of line counts, and let the panes drift.** Cheapest, and it breaks side-by-side reading exactly where the reader is trying to skip noise.
4. **No formatting collapse.** Leaves a whole-file reformat as an unreadable diff, which is the case the classification exists for.

### Final decision

**Option 1.** Grouping is driven by the canonical hunks — stated on both sides by construction, the same reason `changeStops` uses them. Consecutive formatting hunks separated by at most `formattingCollapseGapLines = 2` lines are one group. A group is offered only when its two sides span the **same number of lines**, and rejections are **counted** (`unpaired`), never dropped in silence.

### Consequences

- **Grouping, never filtering.** The segments stay in the model, the marker states how many changes it holds and how many lines, ⌘E or a click opens it, and Expanded offers no formatting groups at all — dropping the quietening is Expanded's whole job. INV-5 is untouched: both modes carry the identical segment set.
- Whole lines are hidden, so a presented segment of any other kind anywhere on those lines disqualifies the group. A reindent and a renamed variable on the same line is not a formatting change.
- The `unpaired` count is the same shape of number as `movesBelowFloor` (DEC-038), and exists for the same reason: a floor a reviewer cannot see is indistinguishable from nothing having been found.
- Line-count equality is a **sufficient** condition for keeping the panes aligned, not a necessary one. A reformat that changes line counts — wrapping a long call across three lines — is real formatting and will not be grouped. That is the conservative direction.

### Revisit trigger

Reopen if line-count-changing reformats (Prettier's print width) prove common enough that the unpaired count dominates the offered one.

---

## DEC-049 — A pin is refused rather than taken from a file that is still being written

- **Date:** 2026-07-27
- **Topic:** Resolves the read half of test R-9. Refines DEC-007's pinning.
- **Status:** Accepted

### Context

`pinnedPair` read a worktree file with one `Data(contentsOf:)` and hashed the result. An editor writing in place — as opposed to writing a temp file and renaming — can be interrupted mid-write by that read, which then returns the first half of one version and the second half of another. Hashing it produces a pin that **certifies a version that never existed on disk**, and R-9 forbids exactly that: the result must be the pre-change pin or the post-change pin, never a blend.

**[Measured]** Re-reading and comparing content is not sufficient on its own. Against a writer rewriting a 52 KB file in a tight loop, two consecutive reads agreed on torn content **3 times in 8,095 reads**. Comparing content only asks whether two reads happened to match, not whether anything wrote between them.

### Options considered

1. **Bracket the read with a stat**: same inode, size and modification time before and after means nothing wrote during it. Retry a few times, then refuse.
2. **Re-read and compare content.** Measurably insufficient, above.
3. **Copy the file first.** Same race, one level down.
4. **Accept it and show a warning.** A warned blend is still a blend on screen.

### Final decision

**Option 1.** Five attempts, 20 ms apart; a pair that never settles is returned with `stable == false`, and **the application does not render it** — it says the file is being written and waits for the watcher to fire again. Blob sides come from the object database and are immutable, so only worktree sides are guarded.

### Consequences

- APFS timestamps are nanosecond-resolution, so an overlapping write moves `mtime` even for a same-size rewrite.
- **[Measured]** Under continuous rewriting, no stable pair was ever a blend, and every read was correctly refused. With a plausible 30 ms gap between saves, the large majority settle on the first attempt — a guard that refused everything would be an outage, not a guard.
- The refusal costs at most ~80 ms of retries before the view is left as it was. The watcher's trailing-edge debounce (DEC-026) then fires again once the writing stops, so the refusal is self-correcting rather than terminal.
- Deleted-file and permission cases are unchanged: those already read as empty.

### Revisit trigger

Reopen if a repository on a filesystem with coarse modification timestamps (a network mount) makes the guard either miss tears or refuse constantly.
