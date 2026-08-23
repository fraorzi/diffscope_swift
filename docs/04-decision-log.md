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
- **Status:** Accepted — **amended 2026-08-01 by DEC-053**, which admits a built-in terminal. Everything below still holds of the *application's own* operations: no automatic path writes, and R-8 proves it. What changed is that the user can now type `git commit` into a shell the application hosts. The text below is left as it was written; the correction is visible rather than edited in.

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
- **Status:** Accepted — **amended 2026-08-09 by DEC-061**, which admits History and Blame as lenses over the selected file. The four scopes below are unchanged; what changed is that a commit-vs-commit comparison is now reachable, through a door this entry did not anticipate. Left as written; the correction is visible rather than edited in.

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
- **Status:** Accepted — **amended 2026-08-09 by DEC-059**, which makes unified the default layout and side-by-side a mode. The reasoning below for side-by-side still holds of the case it was written about; what it missed is which layout a reader arrives already able to read. Left as written.

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
- **Status:** Accepted — **amended 2026-08-09 by DEC-064**, which admits motion. Reduced motion is still honoured; it is now honoured by a checked off switch rather than by there being nothing to switch off. Left as written.

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
- **Status:** Accepted — **amended 2026-08-09 by DEC-062**, which brings search within the diff into version one. The minimap, annotations and filter-by-change-type stay deferred. Left as written.

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

### Amendment, 2026-07-31 — group by directory, because no repository here declares packages

Measured at implementation time, against the corpus this decision was written for:

| Measured | Result |
|---|---|
| Repositories containing `pnpm-workspace.yaml` | **12** |
| …of those, declaring a `packages:` key | **0** |
| `package.json` files declaring a `workspaces` key | **0** |

The planning-time claim "12 of 21 repositories are pnpm monorepos" was drawn from the *presence of the file*. Every one of those files declares only `onlyBuiltDependencies`. Grouping by workspace package would therefore have produced a **single header above the whole list, in every repository the product owner has** — a label saying what the repository name already said.

**Amended decision: the group is the declared workspace package where one exists, and the file's parent directory otherwise.** The workspace mechanism is kept, because it is right where it applies and costs nothing where it does not.

Two consequences the original wording did not anticipate:

- **Headers are suppressed when grouping buys nothing.** One group per file doubles the list and separates nothing; one group in total says nothing. Both fall back to a flat list, at a stated threshold rather than by taste.
- **A grouped row shows its path relative to its group.** DEC-033 asked for middle elision so that "the start identifies the package, the end identifies the file" — but under a header the start is already on screen one row above, and repeating it spends the width elision existed to save. `src/components/…ExpandedSection1.tsx` becomes `ExpandedSection1.tsx` under its directory header, with the full path on hover.

Measured on `philips__signify-wiz-euro__preact`: 20 changed files, 8 directory groups, every row a filename.

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
- **Status:** Accepted · **Strengthened twice — see the M8-H addendum below, and DEC-068 (2026-08-11)**

> **Amended by DEC-068.** This entry's guard asks *did anything change while I looked*, and takes both looks at the same instant. A file caught between `truncate` and its rewrite is zero bytes and genuinely quiescent, so every term here is satisfied and the pin certifies an empty file — measured at **4 per 1,000 reads** once the R-9 arm was bounded by reads rather than by a second and a half. DEC-068 separates the confirming read from the first in time. Nothing below is withdrawn.

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

---

### Amendment, 2026-07-31 — the stat bracket needs a second read beside it

**Observed:** the R-9 racing check failed while a release build ran concurrently — **6 blended pins of 20 reads** — then passed six times in a row on an idle machine. A trust guarantee that holds when nobody is looking is not a guarantee, so it was measured rather than retried.

**Ruled out by measurement.** Timestamp granularity: 200 rewrites of a 52 KB file produced **200 distinct modification times**, smallest gap 114 µs. `mtime` moves on every write, so the bracket is not blind to writes in general.

**The actual hole.** A single large `write` stamps `mtime` **once**, when it starts, while the copy continues. Both stats then see the same timestamp and the read in between lands mid-copy. The bracket can establish that no write *started* during the read; it cannot establish that none was already *in flight*. Load widens the window, which is why it appeared under a concurrent build and not on an idle machine.

**Amended decision: the read is bracketed by a stat *and* repeated, and both must agree.**

Each half is insufficient, and each was measured to be insufficient rather than argued about:

| Guard | Measured failure |
|---|---|
| Content compared across two reads, alone | 3 blends in 8,095 reads (M7-B) |
| Stat bracket, alone | 6 blends in 20 reads under load (M8-H) |
| Both together | 0 blends; the hostile case refuses every read, the realistic one still yields usable pins |

They close each other's hole: the bracket catches a write that starts during the read, the second read catches one already in flight when the first stat ran. Cost is one extra read of the worktree side, on the path that was already reading it.

**The original consequence still stands:** a pair that will not settle is not rendered at all, because a blend shown with a warning is still a blend.

---

## DEC-050 — Structural budgets: size, node count, and counted matching work

- **Date:** 2026-07-28
- **Topic:** Replaces the estimates in `16-performance-and-scaling.md` §3 with measured values, and gives the structural path the gates it did not have.
- **Status:** Accepted

### Context

`16-…` §2 identified the matcher as the product's performance risk and said to budget on **node count, not bytes**, citing difftastic #373 — a moderate-size lockfile consuming 64 GB. The two numbers written down (~50,000 nodes, 500 ms) were marked as estimates.

Until now the structural path enforced **none of it**: `structuralDiff` classified, parsed and matched anything it was handed. Measured (M8-A): matching a 900 KB build chunk takes ~2 s, and the cost grows roughly quadratically in node count. A file being reviewed while the interface waits is the worst version of this — a hang is worse than a fallback, because raw would have shown every byte immediately.

### Options considered

1. **Three gates: byte size, node count, counted matching work.**
2. **Node count only.** Still parses a 31 MB bundle first, which costs ~1.1 s before any decision.
3. **A wall-clock deadline on matching.** Simplest to explain, and it makes the *result* depend on machine load — the same file would diff structurally on an idle machine and fall back on a busy one. T-7 requires determinism, and giving up is part of the output.
4. **A byte budget.** Rejected by §2 on the product's own evidence, and confirmed by M8-A: 33 KB of minified code costs twice what 57 KB of JSX costs.

### Final decision

**Option 1**, in cost order, each degrading to raw with a stated reason:

| Gate | Value | Checked |
|---|---|---|
| `structuralSizeLimit` | 2 MB | before parsing |
| `structuralNodeBudget` | 30,000 nodes | after parsing, before matching |
| `matchWorkBudget` | 10,000,000 counted candidate comparisons | during matching |

Measured at ~40,000 work units per millisecond, so the work budget is about a quarter of a second of matching. The corpus median uses ~10,000 units — about a thousandth of it.

### Consequences

- **A breach costs structure, never content.** Raw shows every byte, and the reason is carried through `StructuralStats.fallbackReason` into a notice (INV-4).
- **A partial mapping is discarded, not used.** Matching that gave up halfway produces fewer anchors and therefore *more* apparent change than the file contains — a worse answer wearing the same clothes.
- On the 400-file corpus, 84.5% of files stay structural and every rejected file is build output; the eight nearest the gates are all `.next` chunks. A budget that rejected hand-written source would be in the wrong place, so the survey reports what sits nearest each gate.
- The work counter is charged where the superlinearity lives — candidate comparisons in the bottom-up phase, weighted by the descendant sets being intersected.
- 2 MB matches DEC-040's independent-validation threshold, so a file that is too large to validate is also too large to analyse structurally. One number, two uses, deliberately.
- The values are machine-relative in the *time* they correspond to, not in behaviour: the same file is treated identically everywhere, and only the wall-clock cost of the ceiling varies.

### Revisit trigger

Reopen if a hand-written source file in any real repository is rejected by a gate, or if the matcher is changed in a way that alters the work-to-time relationship measured in M8-A.

---

## DEC-051 — Degradation precedence is data, and F8/F13 are wired to it

- **Date:** 2026-07-29 · **Topic:** Makes `13-error-and-fallback-model.md` §5 executable; resolves the untested rows of §3 · **Status:** Accepted
- **Discovered by:** M8 implementation reading

### Context

§5 states a precedence over the failure taxonomy — *"when multiple conditions apply, the most conservative wins"* — and until now nothing implemented it. The order was implicit in the sequence of guards inside `classify` and `structuralDiff`, which was right by accident and had nothing keeping it right.

It was also already wrong in one place. §5 ranks **F9 binary** above **F7 unsupported**, but `classify` returned on its first guard, so a binary `.png` reported *"unsupported language"* — true, and the milder of two true statements. Under INV-4 the reason **is** the guarantee, so the milder statement is a defect even when the outcome (raw) is identical.

Two further gaps came out of the same reading:

- **F8 was never implemented.** `GitOperation.checkAttr` existed and was never called, so DEC-028 (no structural claim under an active filter) and DEC-041 (the list follows `git status`, the view explains the discrepancy) were both unenforced. Same class of defect as `runBundleFreshnessCheck` in M5: *a check that is not run is not a check*.
- **F13 covered one of its two arms.** §2 says "non-zero exit / not found"; the application reported only the launch that throws, so an editor command that started and then failed read as success.

And one hazard found in passing: `GitOperation.catFile` carried **`--textconv`**, which runs a command the *repository* configures. It was unused, but it sat inside `allProvenReadOnly` — a registry whose entire purpose is to make "we never execute repository content" structural. R-8 proved it does not **write**; that is a different property from not **executing**, and it satisfied the first while breaking the second for two milestones.

### Options considered

1. **Precedence as data on a typed vocabulary**, with the ordering asserted against §5 and multi-condition inputs constructed to exercise it.
2. **Keep the guard order and document it.** Free today; identical to the state that already drifted.
3. **A single "degraded" flag with a free-text reason.** What exists now; cannot express "which of these conditions wins" at all.

### Final decision

**Option 1.** `Degradation` in `DiffScopeEngine` carries a `code`, a `rank` transcribing §5, and `mostConservative(_:)`. `classify` gathers every condition that holds instead of returning on the first, and `structuralDiff` takes an `external:` seam through which the Git layer supplies conditions the syntax layer cannot detect.

Three mappings the code needs and §2 does not supply, recorded rather than invented silently:

| Condition | Row | Why |
|---|---|---|
| Invalid UTF-8 | **F9** | No row of its own; "content this tool cannot treat as text" is what F9 names |
| Merge-conflict markers | **F2** | A file mid-merge is not source, which is the condition a whole-file parse failure reports |
| Structural budget exceeded (DEC-050) | **new F16** | §2 predates the budgets. Ranked *below* F7: for a file whose language has no structure the size is beside the point |

`cat-file --textconv` is removed from the registry, with `GitOperation.forbiddenArguments` standing guard so it cannot return as a convenience.

### Consequences

- **Evaluation order and precedence are now separate concepts.** Gates still fire where they are cheapest — the 2 MB check before parsing — while the *reason shown* is chosen from the conditions that are true. Conflating them is what produced the F9/F7 defect.
- **F8 costs one `git check-attr` per file the reader opens**, not per file listed. The disclosure belongs to the diff view, and a 63-file sweep would pay 63 invocations for an answer nobody is looking at.
- **An external condition joins the ranking rather than pre-empting it**, so a filtered binary file still reports binary (F9 over F8).
- **A filter is disclosed even when the two sides are byte-equal.** That is the DEC-041 case exactly: the list says changed, the view shows nothing, and both are correct. INV-3 is untouched — nothing is labelled changed, a sentence is added.
- The application's status summary and the renderer's notice now come from the same vocabulary, so a fallback cannot acquire wording that has not been reviewed.
- Building the F13 fixture found a defect nobody had reported: the editor template was substituted **before** being split, so a path containing a space became three arguments and the editor opened the wrong file. Templates are now tokenised first and filled afterwards.

### Revisit trigger

Reopen if a new failure condition does not fit any existing row — the mapping table above is the precedent for adding one, not for stretching an existing row to cover it. Reopen the F8 cost decision if per-file `check-attr` becomes visible in interaction latency.

---

## DEC-052 — Application configuration is a JSON file the user can read

- **Date:** 2026-07-31 · **Topic:** Where the application's own settings live. Required by DEC-036, DEC-037 and DEC-009, none of which said · **Status:** Accepted
- **Discovered by:** implementing root management

### Context

Three accepted decisions depend on persisted settings — configured roots and individually added repositories (DEC-037), the empty state that appears when none exist (DEC-036), and per-repository base-branch overrides (DEC-009). `12-…` §3 says overrides are "stored in application configuration". **No document said what that is**, so the first feature to need it had to settle it.

### Options considered

1. **A JSON file at `~/Library/Application Support/DiffScope/config.json`**, with an injectable path.
2. **`UserDefaults`.** The macOS default, one line per setting, no file handling.
3. **A file inside each repository.** Rejected immediately: DEC-003 forbids writing to repositories, and this would make the application's settings travel in the user's commits.

### Final decision

**Option 1.** A plain JSON file, path injectable, overridable for a whole process through `DIFFSCOPE_CONFIG`.

Behaviour, following the trust rules the rest of the product already follows:

- **Missing file → first run.** A state, not an error, and nothing is reported at the user.
- **Corrupt file → reported, and left exactly as it is.** The application starts with no sources and says so.
- **Writes are atomic**, so an interrupted write cannot leave half a configuration.
- Configured sources are **inspected, never filtered**: a root that has been moved appears as *missing*, because a source that silently disappears from the list is indistinguishable from one the user never added.

### Consequences

- **`UserDefaults` was rejected on two grounds.** It is global mutable state on the machine, so the check suite would either pollute the user's real preferences or need a parallel suite name that no longer tests the shipping path. And a configuration the user cannot open and read sits badly with a product whose entire claim is that it hides nothing.
- The file is outside every repository, so DEC-003 is untouched.
- `DIFFSCOPE_CONFIG` and `DIFFSCOPE_ROOT` are **testing hooks, not settings**. `DIFFSCOPE_ROOT` adds a root for one launch and is never written to the file, so it cannot quietly become a default again — which is exactly what the hardcoded `~/WebstormProjects` had become.
- Base-branch overrides (DEC-009) now have a home. The storage-key fragility DEC-037 warned about — the same repository reachable by more than one path — remains unsolved and is deferred with the override UI itself.

### Revisit trigger

Reopen if the application is ever sandboxed: OQ-035 notes that each root would then need a security-scoped bookmark persisted alongside its path, which changes what the file holds but not where it lives.

---

## DEC-053 — The built-in terminal enters version one, and what it costs the read-only sentence

- **Date:** 2026-08-01 · **Topic:** Resolves OQ-055 in favour of building; amends DEC-003 and `18-version-one-scope.md`; leaves DEC-028 untouched · **Status:** Accepted — **amended 2026-08-10 by DEC-067**, which admits several sessions in tabs and moves the drawer across the window. Everything below still holds of each session; *one* was the smallest thing that could answer T0's question, never the point. Left as written.
- **Decided by:** the product owner, 2026-07-31. Gated on T0, measured 2026-08-01.

### Context

DEC-003 made version one **strictly read-only**, `18-version-one-scope.md` admits no command execution at all, and `21-agent-handoff.md` §6 lists read-only among the questions that must not be silently re-decided. A terminal inside the application runs whatever the user types, including `git commit`. That is the feature, not a defect — but it cannot arrive as an implementation detail of a UI, because it changes a sentence the product has been making everywhere.

The feature turns on one question, which is why T0 came before any of it: **can the application know when the shell is sitting at a prompt?** Without that, a keystroke cannot be routed between a local editor and a running program, and the Warp-style input line — the thing actually asked for — is not deliverable.

### Options considered

1. **Build it, with shell integration and a prompt-aware input line.** Requires OSC 133 marks from the user's shell, which requires touching their shell startup — the part that can go wrong invisibly.
2. **A plain terminal with no prompt detection.** Everything raw, no local editing. Cheap, and it is not what was asked for; it was the recorded fallback if T0 failed on (1).
3. **Do not build it.** "Open in Terminal here" plus clipboard commands, both already in scope and neither executing anything. This was the recommendation OQ-055 carried, and the product owner overrode it. Their call.
4. **Build it and forbid Git commands.** Rejected outright: a terminal that inspects what the user types in order to refuse it is both defeatable and dishonest about what it is.

### Final decision

**Option 1**, with the boundaries stated before the code rather than after:

- **The terminal runs what the user types, and nothing else.** No repository script is run, no command line is prefilled from repository content, nothing auto-executes. **DEC-028 survives intact** and is now the entire safety story: once a shell exists inside the application, *content never decides what runs* is the only line that still holds.
- **R-8 continues to mean what it meant.** It proves the **application's own** Git usage writes nothing. The terminal is the user's. No document may conflate the two.
- **Shell integration never writes to the user's files.** A generated `ZDOTDIR` sources their real startup files and appends hooks with `add-zsh-hook`; bash gets `--rcfile`. Verified in T0 by hashing `~/.zshrc` and `~/.zprofile` before and after — R-8's pattern pointed at the home directory.
- **The escape hatch is mandatory, not optional.** Detection will be wrong sometimes, and being unable to type into an `ssh` password prompt would be worse than never having the feature.

### Consequences

- **The product can no longer say "it cannot change your repositories."** It can say the application itself never writes to one, and that anything else happened because the user typed it. `25-tester-packet.md` promises the older sentence today and **must be rewritten in T4**; a check should hold that file to whatever the sentence becomes.
- **`18-version-one-scope.md` and DEC-003 are amended, not overridden.** Read-only remains true of the engine, the Git layer and every automatic path. The terminal is a user-driven surface bolted beside them, and the distinction has to survive in the wording or it will not survive in the code.
- **OQ-056 is not answered by this.** A terminal grants the same power sideways; staging and committing *as product features* still require reopening DEC-003 properly, with the hunk model DEC-003's own sequencing argument depends on.
- **The input surface is open.** T0 measured all six macOS motions working identically in `NSTextView` and in a `WKWebView` text field, so the input line need not be AppKit overlaid on the grid.
- **Spawning is not free.** ~340 ms to the first prompt on this machine, and every interactive shell leaves an `ssh-agent` behind because the user's rc starts one — 363 were already running when T0 measured. Shell startup must stay off the interface's critical path.

### Revisit trigger

Reopen if prompt-mark detection proves unreliable in real use rather than in seventeen scenarios — the fallback is Option 2, a plain terminal, with the reason recorded. Reopen separately if the product ever wants to *act* on repositories itself, which is OQ-056 and DEC-003, not this entry.

---

## DEC-054 — The output grid is xterm.js, pinned and bundled; the input line is not it

- **Date:** 2026-08-01 · **Topic:** T1 of `26-terminal-plan.md`; adds the first third-party runtime dependency since CodeMirror · **Status:** Accepted
- **Depends on:** DEC-053 (the terminal is in scope), DEC-042 (why a webview renders text here at all)

### Context

The terminal needs a grid: a virtualised, reflowing, attribute-aware screen with scrollback, an alternate buffer, and answers to the device queries a full-screen program asks. Gate T0 measured what happens without one — `vim` asks who it is talking to and waits, and the probe had to answer `DA2` and `DSR-cursor` by hand to get past it.

### Options considered

1. **xterm.js in a second `WKWebView`.** MIT. The webview plumbing, the renderer build step and the token file all already exist here.
2. **SwiftTerm.** MIT, Swift-native, no webview. Fewer moving parts, and less battle-tested for reflow — which is the part that is hard and the part a reader notices when it is wrong.
3. **A hand-written VT parser and grid.** Weeks, for a solved problem, in the milestone whose *point* is that the shell works.

### Final decision

**Option 1**, with the boundaries that make it checkable:

- **Pinned to exact versions** (`@xterm/xterm` 6.0.0, `@xterm/addon-fit` 0.11.0), both MIT, both bundled by the existing esbuild step. A check holds `package.json` to exact versions, because a caret would let the grid change under a build that reports no change at all.
- **Colours come from `tokens.css`** like every other visual value (G2). Sixteen ANSI names are the only literal colours in that file — a palette is what programs address by index, and `Canvas` cannot express "red". They are written out one by one rather than assembled in a loop, so the existing "every declared token is used" check can see them.
- **Bytes cross as base64 of the raw PTY output**, never as a decoded string: a UTF-8 sequence splits across reads routinely, and this product's entire claim is that bytes are the source of truth.
- **Output is coalesced into one frame's worth** before crossing (T1-A: 2,605 reads become 9 deliveries for 2.7 MB, every byte preserved).
- **The grid is output only.** Keystrokes cross back through one message handler into `TerminalSession.send`, and the Warp-style input line — local editing at a prompt, raw passthrough while a program runs — is T2's, not a property of this choice.

### Consequences

- **The privacy claim now covers code we did not write.** `25-tester-packet.md` says the renderer makes no requests; since T1 the bundle carries xterm.js, so the check that backs that sentence was widened from `main.js` to every renderer source *and* every built bundle. Both are clean today, and a future dependency bump is now answerable rather than assumed.
- **348 KB** for the grid, beside CodeMirror's 380 KB. The number that made this an easy call is DEC-042's: Monaco was rejected at 9.3 MB.
- **The grid paints on `requestAnimationFrame`, which WebKit suspends while the window is occluded.** Measured in T1-A: the buffer fills and the screen stays blank, with every other signal healthy. The reader never sees this — an occluded window is one nobody is looking at — but a *selftest* does, so the arm that asserts drawn glyphs states plainly when it could not.
- **A second webview is a second attack surface and a second thing to keep in step.** It loads a local file, has no network entitlement, and is covered by the same freshness hash as the first.
- SwiftTerm remains the way out if the webview becomes the wrong host: the module boundary is `TerminalSession`, and nothing above it knows how the grid is drawn.

### Revisit trigger

Reopen if xterm.js goes unmaintained the way `tree-sitter-typescript` did (`17-…` §4.3 records what that looks like), or if the input line T2 builds cannot be made to work inside the same webview — in which case the grid and the input line split hosts and this entry chooses again.

---

## DEC-055 — The input line replaces the shell's line editor, and hands it back on Tab

- **Date:** 2026-08-01 · **Topic:** T2 of `26-terminal-plan.md`; delivers the thing OQ-055 actually asked for · **Status:** Accepted
- **Decided with the product owner** on the Tab/history question, 2026-08-01

### Context

The terminal was asked for because ordinary emulators pass keys through a line discipline, so **Option+←/→ and Cmd+←/→ do not work in a command line**. T1 produced a working terminal that has exactly that problem. Fixing it means the application, not the shell, owns the line being typed — and owning it means owning everything the shell's line editor used to do: completion, reverse search, history, interrupt, EOF.

Two things were already measured and decide the shape: a `<textarea>` in a `WKWebView` performs all six macOS motions identically to `NSTextView` (T0, S8c), and OSC 133 prompt marks are reliable on this machine's zsh (T0, S1–S6).

### Options considered

1. **Local line at a prompt, handing over to the shell on Tab and ⌃R**, with ↑/↓ walking this session's own history.
2. **Handing over on ↑/↓ as well**, so history is always the shell's real history. Rejected by the product owner and on merit: the recalled command is then edited in *zsh's* editor, without the motions this feature exists to provide.
3. **Implementing completion ourselves** — what Warp does. Weeks of work and a second set of rules to keep beside zsh's, which `26-…` §4 already put out of scope.
4. **No local line at all**, only key bindings layered on the shell. This is the arrangement OQ-055 describes and rejects: bindings cannot give a shell the platform's text engine.

### Final decision

**Option 1.** Concretely:

- **JS owns text editing, Swift owns routing.** Ordinary characters and caret motion never leave the page — that is the whole point, and it costs nothing. Only eight keys are intercepted, once per line, and `InputRouter` decides what each one means. The rules are therefore **checked headlessly** rather than looked at.
- **The page is told which keys to intercept** (`InputRouter.interceptedKeys`) instead of holding its own list. Two copies of a keyboard map drift, and the drift is invisible.
- **Tab and ⌃R hand the line over**: the typed text goes first, then the key, and the mode becomes raw until the next prompt mark. The reader's own zsh completion and menu behave exactly as they do in their terminal, because they *are* their zsh.
- **Raw modes give the keyboard back to xterm**, which already encodes arrows, modifiers and escape sequences correctly. Writing a second encoder would be reimplementing the part of xterm that works.
- **The mode chip reports the mode the code is in** — `prompt`, `program`, `raw — forced`, `raw — the shell has the line`. Deliberately not the diff's mode chip, which reports the reader's *selection* and is a recorded weakness for exactly that reason.
- **The escape hatch is a menu item** (⌥⌘R) and a clickable chip. Detection will be wrong sometimes; being unable to type into an `ssh` password prompt would be worse than never having the feature.
- **History is this session's**, and `~/.zsh_history` is never read. Showing readers what they just typed is not the same act as opening their private history file, and the real history stays one ⌃R away — at the shell. A check greps for both history files, with comments stripped, because the first version of it failed on the sentence saying we do not read them.

### Consequences

- **A key is never swallowed in silence.** Anything not in the intercepted list stays with the field, and the router's default is `editLocally`. The negative control in the suite asserts that an ordinary character and a macOS motion are *not* the router's business.
- **⌃D over typed text does nothing**, unlike a real shell where it would close the session. Closing a shell under a command the reader has not run yet is a worse surprise than an ignored keystroke.
- **A restarted session clears the grid.** Two shells' output in one scrollback with nothing between them leaves no way to tell which shell said what — found by looking at a snapshot, not by a check.
- **The shell is still the authority on what runs.** Nothing in the input line rewrites, completes or interprets a command; it edits text and sends bytes. DEC-028 is untouched.
- Prompt detection failing now has a visible cost — the input line appears at the wrong moment — which is why the hatch is in the menu bar rather than behind a gesture.

### Revisit trigger

Reopen if handover proves annoying in daily use (the tell would be reaching for Tab and losing the line's motions often enough to notice), or if Warp-style blocks are taken up, which would change what the input line is attached to.

---

## DEC-056 — The terminal follows the reader's selection, under guard

- **Date:** 2026-08-01 · **Topic:** T3 of `26-terminal-plan.md`; the one place the application composes a command · **Status:** Accepted
- **Decided with the product owner**, 2026-08-01

### Context

The terminal sits under the diff so that a command and its consequences are visible together. That only works if it is *in the repository the reader is looking at*. Opening there is easy; the question is what happens when the reader switches repositories while a shell is already running.

This is also the first time the application would **compose a command for the user's shell**, which is a boundary this product has been careful about since DEC-028.

### Options considered

1. **Send `cd` automatically, but only when there is provably nothing to disturb**, and offer an explicit action otherwise.
2. **Never send anything**; show where the terminal is and let the reader act every time. Purest, and it makes "follows the selection" mean only "opens there".
3. **Restart the shell in the new directory.** Always consistent, and it discards shell state, history and — worst — whatever program was running. Each restart also costs ~340 ms and another `ssh-agent` (T0).

### Final decision

**Option 1.** The guard is a conjunction, and each term is there for a reason:

| Condition | Why |
|---|---|
| a prompt mark has actually been seen | not "the shell is named zsh" — an unrecognised shell may still mark prompts through the reader's own integration (T3-A) |
| the mode is `local` | a program running, a forced raw mode, or a handed-over line all mean somebody else owns the keyboard |
| the input field is empty | a `cd` in front of a half-typed command would destroy it |

Otherwise **nothing is sent**: the pane shows that the terminal's directory and the selection disagree, and ⌥⌘K performs it when the reader asks.

**The path is quoted by one function** (`shellSingleQuoted`) and the command is `cd -- <path>`. Single quotes because a POSIX shell expands nothing inside them; `--` because a directory whose name starts with `-` would otherwise be read as options. Both are checked against a **real shell** over twelve hostile names, including `$(id)`, a backtick, a semicolon, a newline and an embedded quote — a string check would only confirm the idea of quoting.

**Where the shell is comes from the shell** (OSC 7), not from where it was started. A shell that reports nothing is shown as *directory unknown* rather than as the directory it was launched in.

### Consequences

- **This is the closest the product has come to running a command.** It composes exactly one, with exactly one argument, through exactly one function, under a three-term guard, with hostile fixtures. DEC-028 is untouched in the sense that matters: nothing here derives from repository *content* — the path is the reader's own selection.
- **A finished command refreshes the repository sweep, not the file list.** Measured first (T3-A): FSEvents already sees `git commit`, because `.git` is inside the watched root. What it does not see is the uncommitted count and ahead-of-base beside every repository, and that is all the command mark is used for — debounced against the watcher's own quiet period.
- **A refusal is silent.** The pane already shows the divergence; a status line that announced every refusal would be noise for a condition the reader created deliberately by typing.
- If prompt detection is ever wrong, the guard's other two terms still hold — which is why it is a conjunction and not a preference.

### Revisit trigger

Reopen if the terminal ever needs to send anything other than `cd` — a second composed command is a different decision, not an extension of this one.

---

## DEC-057 — The keyboard map is data, and the menu is generated from it

- **Date:** 2026-08-09 · **Topic:** DEC-016's coverage commitment, `12-desktop-ux-specification.md` §9, OQ-023 · **Status:** Accepted — **its bindings superseded 2026-08-09 by DEC-065.** The mechanism below is untouched: the map is still data, the menu is still built from it, and a specified function with no binding still fails the suite. Only the contents changed. Left as written.

### Context

DEC-016 commits to full keyboard operation and says *"any function reachable only by pointer is a defect"*. `12-…` §9 lists nine functions as binding coverage and defers the concrete keys to implementation, which left the map living in two places that could not disagree out loud: a Markdown table, and a hand-written list inside `buildMenu`.

They did disagree. **Show raw for the current region was specified and never built**, and stayed missing through M6, M7 and M8 without a single check noticing — the same shape as `runBundleFreshnessCheck` and `checkAttr`, which is now the fourth instance in this project of *a requirement nothing runs*.

The definition of done §6 — *a 63-file working tree is reviewable entirely from the keyboard* — was equally unverified, and its ordinary route was broken: group headers took the selection under the arrow keys, where the handler returned in silence and the diff pane went on showing the previous file. Only ⌘] / ⌘[ obeyed DEC-033.

### Options considered

1. **The map as data in a shared target, the menu built from it, the coverage checked.** One source; a specified function with no binding fails the suite.
2. **A check that greps `main.swift` for each function's title.** Cheap, and it tests the spelling of menu titles rather than what a keystroke does. `DesignChecks` reads sources this way for CSS, where there is nothing else to read; here there is a real value to hold.
3. **Leave the map in the menu and transcribe §9 into a checklist a human runs.** This is what was already happening, and it is what let a specified function go missing for three milestones.

### Final decision

**Option 1.** `Sources/DiffScopeShell/KeyboardMap.swift` — AppKit-free, linked by the application *and* by `diffscope-verify`, so the check suite measures the shipping map rather than a copy of it (the T1 lesson from gate T0). `KeyboardFunction` transcribes §9's nine rows with their sentences; each binding declares which row it satisfies; `buildMenu` iterates the map and `selector(for:)` is the single place an identifier becomes a method.

The concrete bindings — settling OQ-023 and `12-…` §12's open item — are the map's contents. The one added in this milestone:

| | |
|---|---|
| **⌥⌘V** | Raw for Current Region |

**⌥⌘V is not a fourth mode.** Change stops come from the canonical diff, so stop *n* is the same region in every mode; ⌥⌘V records the stop and the mode, switches to Raw on the same pinned pair, and jumps back to that stop. A second press returns to the mode it left, at the same place. Choosing a mode by hand ends the excursion, because the reader has said where they want to be.

`V` rather than `R`: ⌘R reads as *refresh*, and refresh here is automatic (DEC-027's watcher, DEC-006's focus refresh). ⌥⌘R is already the terminal's escape hatch.

**Headers are refused at the source.** `tableView(_:shouldSelectRow:)` returns false for a header row, so arrows, clicks and ⌘] finally agree with DEC-033 instead of one route out of three.

### Consequences

- **A function specified in §9 and not bound fails `diffscope-verify`**, naming the row. So does a second binding on one keystroke, since the loser of a collision is a function reachable only by pointer.
- **The definition of done §6 is measured, not asserted.** `Scripts/keyboard-tree.sh` builds a 63-file working tree and the application selftest walks it with **real key events through the real menu bar** — 63 files, 62 keystrokes, zero stops on a header. Calling the `@objc` methods directly would have proved the methods work and said nothing about whether anything is bound to them.
- **The map is now the place bindings are added.** There is nowhere else; a binding absent from it is absent from the menu.
- Walking the list at keyboard speed found a **crash** nothing else could: renders ran concurrently on one shared tree-sitter parser and aborted the process inside `ts_parser_parse_string`. The parser now holds a lock and renders are serialised, newest selection wins. Recorded in M8-J.

### Revisit trigger

Reopen if a second interface surface appears that needs its own bindings — a preferences window, or the terminal claiming keys the diff also wants. The map is one flat list today because there is one window.

---

## DEC-058 — The interface states its parser state and the path it took, rather than letting the reader infer both

- **Date:** 2026-08-09 · **Topic:** `12-desktop-ux-specification.md` §5.2, `23b-spec-vs-app-audit.md` §1.10 and §2 · **Status:** Accepted

### Context

Four items were left in the audit, and they are one kind of thing: statements the interface makes about how far to trust what it is showing.

**Parser state** was the last of §5.2's seven indicators, and the only one visible purely by inference — a reader concluded "this parsed" from the absence of a notice. That inference is wrong in both directions. An active filter (F8) produces a notice and says nothing about the parser; a partial parse (F1) leaves the structural result standing while its notice reads like a whole-file failure.

**The mode pill** reported the reader's selection, so it could read `mode: structural` beside a notice saying structural analysis was unavailable.

### Options considered

1. **Compute both in the engine, carry them on the render contract, compose the words once.** Checkable headlessly; the renderer draws a sentence rather than assembling one.
2. **Derive the parser state in the renderer from the notices already present.** This is the inference itself, moved into code — it would be wrong in exactly the two directions above, and wrong silently.
3. **Replace the mode pill with the path taken.** Loses the selection, which is the thing ⌘1–3 returns to. The reader needs both, and only when they differ.

### Final decision

**Option 1.** `ParserStateReport` in the engine, with three states matching §5.2's words; `StructuralStats.parserState` derives it beside the statistics, so the check suite exercises the derivation the window uses. `RenderModel` carries `parser` and `pathTaken`, and composes both chips as **text** (`chipText`, `modeChip`) rather than leaving the renderer to word them — a sentence written in two languages drifts in one of them.

Both fields are **optional on the contract**. A check that fabricates a model has nothing to say about a parser it never ran, and an absent chip is honest where a defaulted one would be a claim.

A structural result **discarded by validation** reports `parsed`. The parse succeeded; what failed came after it, and §5.2 lists parser state separately from fallback marking precisely so the two stages can disagree.

The two shell items are settled the same way: the branch moves out of the tooltip and into the row, and the uncommitted count's convention is stated on screen from `RepositoryReader.uncommittedCountConvention`, which lives beside the operation it describes.

### Consequences

- **Three modes, two code paths.** `impliedPath(ofMode:)` states DEC-013's mapping once. The first version of the pill compared the path against the mode and invented a disagreement for Expanded; the selftest caught it because that arm renders in Expanded.
- **The chips are asserted in the document**, not in the model. The structural arm requires `parser: parsed`, the degradation arm requires `mode: structural — showing raw` and `parser: not parsed`.
- **The convention sentence is checked for truth, not only for presence** — a check asserts the operation actually run is `--porcelain` without `-uall`, because `-uall` would make the same words false.
- A tooltip is not a display. This is the general form and it is worth keeping: anything §2 or §5.2 lists as shown must survive a reader who never touches the pointer.

### Revisit trigger

Reopen if a fourth mode or a second structural path appears — `pathTaken` is a two-valued field today because DEC-013 has two code paths. Also reopen if DEC-045 is reopened, since ambiguity would become the eighth chip and the notice bar is already crowded.

---

## DEC-059 — Unified becomes the default layout, side-by-side becomes a mode

- **Date:** 2026-08-09 · **Topic:** DEC-014, `12-desktop-ux-specification.md` §5, the adopted design · **Status:** Accepted · **Amends DEC-014**

### Context

DEC-014 chose side-by-side and put unified out of scope, reasoning that a structural diff is about correspondence and correspondence wants two columns. The product owner reviewed the adopted design on 2026-08-09 and chose the opposite default: unified, with side-by-side as a mode reached by ⌥⌘→.

Their reason is the one the decision did not weigh — **unified is the shape a reader already knows**, from `git diff`, from GitHub, from every review tool they use. DEC-014 compared the two layouts on how well each expresses a structural alignment and never asked which one a reader arrives already able to read.

There is a real cost, and it is the reason this is a decision rather than a preference. In side-by-side, *added* and *removed* are separated by **which pane the line is in**; that separation is free and it survives greyscale. Unified has no panes, so without something else the distinction collapses onto hue — which DEC-035 forbids, and which the first version of the design did in fact do, marking both with the same gutter bar and the same texture.

### Options considered

1. **Unified default with a dedicated sign column**, side-by-side as a mode over the same pinned pair.
2. **Keep side-by-side only.** Preserves DEC-014 and rejects the owner's instruction.
3. **Unified only.** Cheaper, and it discards the layout that is right for a large restructure — the wrapper-removal case this product exists to show.

### Final decision

**Option 1.** Unified is the default view. Added and removed lines carry **`+` and `−` in a dedicated sign column**, a shape that survives greyscale; hue only reinforces them. Side-by-side stays available for the case it is better at, which is checking that two versions correspond after a restructure.

Both layouts read the **same canonical diff over the same pinned pair**, so switching layout can change neither what is compared nor which change stop the reader is standing on. That is the rule DEC-013 already imposes on modes, applied to a second axis.

### Consequences

- **DEC-014's out-of-scope line is retired**; `18-version-one-scope.md` moves unified from the deferred table into scope, and `12-…` §5 is rewritten around two layouts.
- **The sign column is load-bearing** and joins `24-design-contract.md` §3: it may be restyled and may not be hidden, because in unified it is the only greyscale-surviving signal of direction.
- **The two-panes-stay-aligned rule** in contract §5 now applies to the side-by-side mode specifically, not to the product as a whole.
- **Minimum usable width falls out at 1180 px** — 246 rail + 296 list + 80 monospace columns and gutters — which settles the second open item in `12-…` §12. Below 1180 side-by-side falls back to unified, which is available because unified is now the default rather than an absent feature.

### Revisit trigger

Reopen if the sign column is measured to be missed — a reader who reports mistaking an addition for a deletion in unified is evidence that pane separation was carrying more than this decision assumed.

---

## DEC-060 — Three independent collapses, not one focus mode

- **Date:** 2026-08-09 · **Topic:** `12-desktop-ux-specification.md` §1, the adopted design · **Status:** Accepted

### Context

The design first offered a single "Focus" button that collapsed both sidebars at once. The product owner asked for them separately: collapse repositories without collapsing changed files, and the reverse.

This is not only a convenience. The two lists answer different questions and a reader stops needing them at different moments — the repository list goes quiet once you are inside one repository, while the file list stays in use for the whole review.

### Options considered

1. **Three independent toggles** — repositories, changed files, terminal — freely combinable.
2. **One focus mode**, as first drawn. Fewer states to draw and to test; it forces the reader to give up the list they are still using in order to lose the one they are not.
3. **Draggable splitters only.** Continuous, and it has no keyboard form, which DEC-016 forbids as the only route.

### Final decision

**Option 1.** Each region has two states and its own binding: repositories full ↔ 44 px rail (⌃⌘1), changed files full ↔ spine (⌃⌘2), both at once (⌃⌘0), terminal drawer (⌃`). Collapsed is **not hidden**: the rail keeps three letters and a change dot, the spine keeps one bar per file with its kind glyph, so neither collapse removes information from the window — it reduces the space that information takes.

The kind glyph on the spine is required rather than decorative: the bars were drawn coloured by change kind and nothing else, which is colour-alone meaning and fails DEC-035.

### Consequences

- **`12-…` §1's information architecture gains states.** Two persistent regions become two regions with two states each, and the diff pane's width is a function of both.
- **Four combinations must be drawn and photographed**, not one, and the density check is the worst case: both collapsed with the terminal open.
- The eight-state space is small enough to enumerate, which is why it is enumerated rather than left to a splitter's continuous range.

### Revisit trigger

Reopen if a third list appears in the window — the binding scheme is `⌃⌘<n>` per region and it runs out of obvious digits at three.

---

## DEC-061 — History and Blame enter version one as lenses over the selected file

- **Date:** 2026-08-09 · **Topic:** DEC-008, the adopted design · **Status:** Accepted · **Amends DEC-008**

### Context

DEC-008 fixed four scopes and deferred branch-vs-branch, commit-vs-commit and their pickers, on the reasoning that a picker is a second interface and version one should have one. The adopted design brings back two of the things that deferral removed, in a different shape: **History**, where selecting one commit compares it against the working tree and selecting two compares them with each other, and **Blame**, which is authorship rather than comparison and was never in any scope at all.

The product owner accepted both. What makes them acceptable now and not in July is that they are **lenses over the file already selected**, not a second place to be: the same window, the same file, the same gutter geometry, so switching lens does not move the code under the reader's eyes.

### Options considered

1. **Both, as lenses on the current file**, with the scope bar untouched.
2. **History only.** Blame is the more speculative of the two and the one no document has ever asked for.
3. **Neither** — hold DEC-008 as written and ship the four scopes.

### Final decision

**Option 1.** `⌃⌘D` / `⌃⌘B` / `⌃⌘H` switch lens. History's two-commit selection is the deferred commit-vs-commit comparison arriving through a door DEC-008 did not anticipate, and this entry says so rather than pretending otherwise.

**Both are read-only and both go through the closed operation registry.** `git log`, `git blame` and the two-commit diff are added to the registry with their `--no-optional-locks` flags, which means R-8's proof covers them the moment they exist; an operation that is not in the registry cannot be issued at all.

**Blame marks uncommitted lines rather than tinting them.** The change language owns tint and texture in this window; a blame view that tinted rows would be a second meaning for the same signal.

### Consequences

- **`18-version-one-scope.md`'s deferred table loses two rows** and the scope of R-8's read-only proof grows by three operations.
- **The base-ref age applies to History as well.** The commit list is what is on disk; the application still never fetches, so a history that looks complete may be nine weeks behind and must say so in the same words the scope bar uses.
- Blame introduces the first **per-line attribution** in the product, which is a second thing a line can carry beside a change mark. The design keeps them in different columns for that reason.

### Revisit trigger

Reopen if History grows a filter, a search or a graph — at that point it is the second interface DEC-008 refused, and the reasoning that admitted it as a lens no longer holds.

---

## DEC-062 — Search within the diff enters version one

- **Date:** 2026-08-09 · **Topic:** DEC-017, the adopted design · **Status:** Accepted · **Amends DEC-017**

### Context

DEC-017 deferred search within the diff along with the change minimap and personal annotations, as presentation features that could wait. The product owner asked for it back on review of the design: ⌘F with a destination, results grouped by file, scoped to changed files by default with the whole worktree as an opt-in.

### Options considered

1. **Search over the changed files, with whole-worktree as an explicit second scope.**
2. **Search the current file only.** Small, and it fails the case the feature is for — finding where else the symbol you are looking at is used.
3. **Keep it deferred.**

### Final decision

**Option 1.** Default scope is the changed set, because that is the material under review; whole-worktree is one click away and is stated on screen rather than inferred, since the two answer different questions and a reader who does not know which they asked cannot read the count.

**Hits are marked by more than a highlight colour.** The design's first version used a yellow fill alone, which is the DEC-035 failure in its plainest form; the current hit carries an outline as well, and the current hit within the set carries a marker glyph.

### Consequences

- **Whole-worktree search reads files that are not in any diff**, which is the first time the application opens a file for a reason other than comparing it. Read-only, and inside the same path discipline: no repository content is ever executed or used to build a command (DEC-028).
- **`18-version-one-scope.md` loses the search row** from its deferred table. Filter-by-change-type stays deferred; it was listed in the same DEC-017 line and nothing in the design asks for it.

### Revisit trigger

Reopen if search becomes the way people navigate rather than a way to answer a question — a minimap and a filter were deferred together with it, and if search is carrying their weight the deferral was the wrong shape.

---

## DEC-063 — Rendered comparison for images and SVG, and the `<img>` boundary

- **Date:** 2026-08-09 · **Topic:** DEC-004, DEC-028, `13-error-and-fallback-model.md`, the adopted design · **Status:** Accepted

### Context

A binary file has, until now, been a file the product declines to compare. The product owner asked for the shape other review tools use — Before / After, Blend, Split, Pixel diff — after seeing it in Bitbucket.

Working through it surfaced a classification error the documents have carried since DEC-004: **SVG is not binary.** It is text that also renders. Treating it as binary hides a real textual diff; treating it as text alone hides that the rendered mark moved. Both readings exist and the reader picks.

### Options considered

1. **Three classes** — text-that-renders (SVG), raster, and genuinely undisplayable — with the rendered comparison for the first two and a stated refusal for the third.
2. **Hand the file to an external comparison application.** This was the design's first answer. It needs a second configurable command, it leaves the window, and it makes the product's honesty claim depend on a program it did not write.
3. **Leave binary files undisplayed**, as today.

### Final decision

**Option 1.** SVG gets a Rendered / Source switch and both are complete; raster gets the rendered comparison only; a `.zip` or a generated blob gets the `#unrenderable` state, which states what the file is and why no comparison is attempted.

**The security boundary is the reason this entry exists and not only the feature.** An SVG is repository content and SVG can carry script. It is rendered **through an `<img>` element from a `blob:` URL**, never inlined into the document: script does not execute in an image context, and the renderer's CSP forbids remote loads regardless. This is DEC-028's rule — *never execute anything derived from repository content* — applied to a surface DEC-028 did not foresee. The visible cost is real and is accepted: nothing can style the inside of an SVG, so the transparency checkerboard sits behind the image rather than being composed into it.

**Pixel comparison has a budget** — 16 megapixels — and above it Pixel diff is **disabled with its reason stated**, not hidden, in the same form as an unavailable scope. Both renderings are still shown.

**An image whose bytes differ and whose rendering does not must say so**: *"The two files render identically — 0 pixels differ. The bytes differ."* This is DEC-023's invisible-difference disclosure at the level of a whole file, and without it a reader would read a blank comparison as a false positive.

### Consequences

- **`13-error-and-fallback-model.md` gains the image states**: dimensions changed, renders identically, no counterpart, over budget.
- **`15-test-corpus-plan.md` gains fixtures** it has never had — an SVG whose text changes without moving a pixel, an SVG whose rendering changes, a raster resize, and a file that is neither.
- **The changed-file list's `binary` word narrows.** It now means *undisplayable*, and an image says its dimensions instead.
- The `<img>` boundary is checkable: a check can assert the renderer never inserts SVG markup into the document, with a hostile input as its negative control.

### Revisit trigger

Reopen if a format arrives that is text, renders, and cannot be shown safely in an `<img>` — an HTML fragment is the obvious candidate, and the answer for it is probably *no rendered view at all* rather than a sandboxed frame.

---

## DEC-064 — Motion enters the product, and reduced motion becomes a checked path rather than an absent one

- **Date:** 2026-08-09 · **Topic:** DEC-016, `24-design-contract.md` §5 · **Status:** Accepted · **Amends DEC-016**

### Context

DEC-016 committed to respecting reduced motion, and the contract implemented that commitment by construction: *"Nothing animates. There are no transitions to disable, and adding one would need that decision reopened."* The product owner has reopened it — they want the interface to move.

The reasoning that produced the original rule was sound and is worth keeping visible: **a reduced-motion setting that is honoured by having no motion cannot be got wrong.** Every animation added from here is a thing that can fail to have an off switch.

### Options considered

1. **Motion allowed, with a register**: every transition declares duration, curve, what moves, and its reduced-motion path, and a check enforces that the path exists.
2. **Motion allowed, reduced motion left to reviewers.** This is how the failure normally happens — the guard is remembered for the first five transitions and forgotten for the sixth.
3. **Hold the no-motion rule.** Rejected by the product owner, who was told the cost above and confirmed.

### Final decision

**Option 1.** The design's Motion table is the register and it has a *Reduce Motion path* column for every row; a transition with no entry in that column is not shippable.

The construction-based guarantee is replaced by a **check with a negative control**, because that is the only thing that replaces it: every animated property in the stylesheet must be neutralised inside a `@media (prefers-reduced-motion: reduce)` block, and a deliberately unguarded animation must fail the check. Contract §5's *"nothing animates"* becomes *"nothing animates without an off switch"*.

**Scroll re-anchoring keeps its non-animated path explicitly** (DEC-034 already required one): under reduced motion the jump is instantaneous and the status line reports *"re-anchored at line 412"* instead of moving.

### Consequences

- **`24-design-contract.md` §5 is rewritten**, and the rule moves from the list of things checks cannot enforce into the list of things they refuse.
- **DEC-016's structural argument weakens by one clause.** It said the accessibility commitments were met by construction in three places; now two.
- A snapshot cannot photograph motion, so this is the first interface property with no picture in the selftest. The register plus the check is what stands in for one.

### Revisit trigger

Reopen if the reduced-motion check is ever weakened to a warning. The check is the whole of what replaced the construction guarantee.

---

## DEC-065 — The keyboard map is re-cut around arrows and modifier tiers

- **Date:** 2026-08-09 · **Topic:** DEC-057, `12-desktop-ux-specification.md` §9 · **Status:** Accepted · **Supersedes DEC-057's bindings, keeps its mechanism**

### Context

DEC-057 made the map data and the menu a function of it. That mechanism stands and this entry does not touch it. What changes is the map's contents: the design assigned its own keys, they disagreed with the shipped map in nine of eleven rows, and the product owner asked for whichever set is better rather than either as drawn.

### Options considered

1. **A tiered arrow scheme**: the same direction key at three modifier levels for the three nesting levels of the thing being moved through.
2. **The design's map as drawn.** It used `⌃1`–`⌃4` for scopes, which macOS takes for switching desktops, and it put focus movement on ⇥ alone, which a text field in the terminal drawer claims.
3. **The shipped map as built.** Bracket keys for both files and repositories, and `⌘1` on Raw — the least used of the three modes sitting on the first digit.

### Final decision

**Option 1.** Movement is arrows, and the modifier says what is being moved through: `⌘↑↓` change, `⌥↑↓` file, `⇧⌘↑↓` repository. Digits are grouped the same way: `⌘1–3` modes with **Structural on `⌘1`**, `⇧⌘1–4` scopes, `⌥⌘1–3` focus, `⌃⌘0–2` layout. `⌃\`` opens the terminal, matching what every other editor on this machine does.

**Two reversals of DEC-057 are recorded rather than quietly applied:**

- **Region-raw moves from `⌥⌘V` to `⌘R`.** DEC-057 rejected `R` on the grounds that `⌘R` reads as *refresh*. That reasoning assumed a reader who might press it looking for a refresh — but refresh here is automatic and has no binding, so there is nothing for the mistake to collide with, and region-raw is a control move a reader makes constantly. A constant action belongs on the primary tier.
- **Open-in-editor moves from `⌘O` to `⌘⏎`.** `⌘O` is *Open…* everywhere in macOS, and this application does have things to open — roots and repositories — which now hold `⇧⌘O` and `⇧⌘R`.

**Functions the design introduces are bound but not yet listed in `12-…` §9.** §9's table is the coverage contract and DEC-057's check fails on a row nothing binds; a row is added there when the function it names exists, not when it is drawn.

### Consequences

- **`KeyboardModifiers` gains `.control`**, which the shell must translate, since no binding needed it before.
- **The tester packet changes.** It names `⌥⌘T` for the terminal, and `DesignChecks` asserts that string; both move to `⌃\`` in the same commit as the rebinding, or the check catches the drift — which is the mechanism working.
- **`12-…` §9's key column is rewritten** when the bindings change, not before. Until then it states the shipped map, because the column is a transcription of code and a transcription that runs ahead of its source is the drift DEC-057 exists to prevent.

### Revisit trigger

Reopen if a second window appears — DEC-057 named this trigger for preferences, and preferences now exist as a design (DEC-015's editor command). A preferences window that claims keys the diff also wants is exactly the case the flat list does not handle.

---

## DEC-066 — The design is delivered as a token table, and the table says which tokens the chrome mirrors

- **Date:** 2026-08-09 · **Topic:** `24-design-contract.md` §2 and §7, the adopted design · **Status:** Accepted

### Context

The contract says a design is pasted into `Renderer/src/tokens.css` and mirrored by hand into `Theme.swift`, and that mirroring is the step with no check behind it. The first version of the adopted design made that worse by naming no tokens at all: every colour was a literal inside a component, including the sixteen ANSI colours the terminal cannot invent for itself and the four values xterm.js reads as a set.

### Options considered

1. **The design delivers a table** of `name · dark · light · mirrored · description`, and the table is the interface between design and build.
2. **The design delivers a stylesheet.** It is the same information with the mirrored flag lost, which is the flag the chrome needs.
3. **Extract tokens from the components during implementation.** This is what would have happened by default, and it is how a value ends up literal in two places.

### Final decision

**Option 1.** Eighty tokens, in groups, each row carrying both appearances, a one-line description of where it is used, and a **mirrored** flag marking the rows `Theme.swift` must carry because AppKit draws that surface.

The set is closed deliberately at both ends: the four terminal values (`--ds-term-fg`, `-bg`, `-cursor`, `-selection`) are present as a set because xterm.js invents any one that is missing, and the sixteen ANSI colours stay literal rather than derived from the neutrals, for the reason contract §2 already gives — a program asks for *green* by index.

### Consequences

- **A third token check becomes possible**, beside *every declared token is used* and *no `var()` without a declaration*: **every row marked mirrored has a counterpart in `Theme.swift`**. The hand-mirroring step gains the check it has never had.
- **`--ds-row-selected` and `--ds-row-ring` are one entry with two halves.** Selection is not carried by the background alone; the ring is the shape that survives when a system setting removes the fill.
- The table is the reason the design is implementable at all in one pass. Without the mirrored column, two thirds of the window would be styled by inference.

### Revisit trigger

Reopen if a token is needed that has no single value — a gradient that must be composed per surface, or a colour that depends on the file's state. The table's shape assumes one value per name per appearance.

---

## DEC-067 — The terminal holds several sessions, in tabs, and the drawer spans the window

- **Date:** 2026-08-10 · **Topic:** DEC-053's one session and DEC-054's single grid; the adopted design's terminal drawer · **Status:** Accepted · **Amends DEC-053**

### Context

DEC-053 built one terminal because one was what the feature needed to prove: that a prompt could be detected, that a keystroke could be routed, that shell integration could avoid writing to the user's files. All three held, and the number *one* was never the point — it was the smallest thing that could answer the question.

The adopted design draws the terminal as a **drawer across the window** with a **tab strip**, and the product owner asked for it. Two claims are inside that request and they are separable:

- **Several sessions.** A reader running a test suite in one shell and `git log` in another is the ordinary case, and today the second command waits for the first.
- **Full width.** The drawer sits under the diff pane today, which means a command's output is wrapped to a third of the window while two lists nobody is reading keep their space.

### Options considered

1. **Several sessions, one grid, switched by replaying scrollback.** One xterm instance, and the pane replays a buffer when a tab is selected. Needs a per-session byte log, capped, and a replay that reproduces cursor state — which a byte log does not carry.
2. **Several sessions, one xterm instance each, hidden and shown.** The emulator keeps its own scrollback and cursor per tab, because that is what an emulator is for. Costs memory per tab and nothing else.
3. **Several windows.** Rejected by DEC-005, which is about the diff and applies here for the same reason: one window, no second place to be.
4. **Keep one session.** The product owner asked for tabs; recommending it once is enough.

### Final decision

**Option 2, and the drawer moves below the three panes.**

- **One `TerminalSession` per tab, one xterm instance per tab**, all in the same webview. The emulator holds scrollback, cursor and alternate-screen state per tab because those are the emulator's business; the shell holds everything else. Switching a tab shows a grid that was never asked to forget anything.
- **A tab is a shell, and it says where it is.** The strip shows the shell's name and the directory *it* reports (OSC 7), not the one the reader selected — which is the same distinction DEC-056 drew for the single pane, now visible per tab.
- **Following the selection follows the active tab only.** A reader who changes repository is telling the shell they are looking at, not four of them. The others keep their directories, and the divergence marking (DEC-056) is what says so when the reader comes back.
- **Everything DEC-053 fixed stays fixed.** Each session is spawned exactly as the first one is — the same generated `ZDOTDIR`, the same `add-zsh-hook`, the same argv — so shell integration still writes to nothing of the user's, and DEC-028 is untouched: what runs is what the user typed into *that* tab.
- **Spawning stays lazy.** DEC-053 measured ~340 ms to a prompt and one leaked `ssh-agent` per interactive shell. A tab starts its shell when it is created, not when the drawer opens, and the drawer still opens with one.

### Consequences

- **`TerminalPane` stops being a session and becomes a list of them.** The single-session API it exposes today — `session`, `start`, `stop`, `toggleForcedRaw` — becomes *the active session's*, and the selftest arms keep working because they are arms about one shell.
- **The window's layout changes.** The drawer becomes a sibling of the three-pane split rather than of the diff, so the lists compress with everything else. `12-…` §1's diagram is redrawn.
- **Memory grows per tab** — an xterm instance with a 10,000-line scrollback is the cost, and it is the same cost the reader chose when they opened a second shell.
- **Four leaked `ssh-agent`s instead of one**, for four tabs, and that is the user's shell configuration rather than this application's doing. Worth stating because DEC-053 counted them.

### Revisit trigger

Reopen if tabs turn out to want their own working directories *persisted* across launches — that is configuration, and DEC-052's file would have to carry it. Also reopen if the drawer wants to be a panel that detaches, which is DEC-005's territory rather than this entry's.

---

## DEC-068 — A pin's confirming read is separated from the first read in time

- **Date:** 2026-08-11 · **Topic:** DEC-049's settle guard · **Status:** Accepted · **Amends DEC-049** · **Its delay corrected the same day — see the addendum at the end of this entry**

### Context

DEC-049 refuses a pin taken from a file that is still being written, and M8-H strengthened it after measuring that each half of the guard leaks on its own: content comparison alone let **3 blends through in 8,095 reads**, the stat bracket alone let **6 through in 20 under load**. The combination — three stats that must agree, two reads that must be byte-identical — was believed to close both holes.

It does not close one, and the reason it was never seen is the check rather than the code. The R-9 arm ran for **1.5 seconds**, which on this machine buys **15 reads**, and it asserted *no pin certifies a version that never existed on disk* on those fifteen. Bounding the same arm by **reads** instead (M9-C) took it to 200, and blends appeared immediately: **4 per 1,000 reads under continuous rewrite**, clustered rather than spread, which is what phase-locking between a reader and a writer looks like.

**Every one of them was a zero-length file** — `0/52000 bytes, 0 A-lines + 0 B-lines`, reported by the arm itself now that it says what it saw.

The mechanism is not subtle once the shape is known. A non-atomic in-place save truncates and then writes. In the window between those, the file is genuinely zero bytes and genuinely **quiescent**: three stats agree that the size is 0, both reads return nothing, and every term of the guard is satisfied. The guard asks *did anything change while I looked*, and nothing did — the file was empty for the whole of a very short look.

Two things hid it further. Both sides of the fixture are exactly 52,000 bytes, so `FileStamp`'s **size** term could never discriminate between them and only `mtime` was doing any work. And the presentation of the defect is the loudest one available: a file caught mid-save renders as **the whole file deleted**.

### Options considered

1. **Separate the confirming read from the first read in time.** The guard already owns a delay — `settleRetryDelay`, 20 ms, sized against a measured 11 ms atomic save — and uses it only *between* failed attempts. Putting it *inside* an attempt makes the two reads span a window rather than an instant, so any transient state has to persist across it to be certified.
2. **Confirm only empty reads.** Zero cost on the normal path, and it closes exactly what was measured. Rejected as too narrow: it fixes the shape rather than the cause. A writer that emits in chunks produces non-empty partial states, and the same argument that certified 0 bytes would certify 30,000 of them.
3. **Refuse a zero-length worktree read outright.** Rejected: a deliberately emptied file exists, and this would make it permanently unreadable — a guard that refuses a legitimate state is an outage, which is the objection R-9's second arm exists to raise.
4. **Require the file to be quiescent by clock** — `mtime` older than the read by some margin. Rejected: it needs a margin nothing has measured, and it fails differently rather than better on a filesystem with coarse timestamps.

### Final decision

**Option 1.** `settledRead` sleeps `settleRetryDelay` between the read and its confirmation, so the pair spans a window instead of an instant. A state that is transient cannot survive it; a state that is real does.

This is a strictly stronger guard than DEC-049's, not a different one. Every term it already checked, it still checks.

### Consequences

- **A worktree read costs at least one settle delay.** On a quiet file that is ~20 ms added to selecting a file and to each refresh — against a 46 ms `git status`, and imperceptible next to it.
- **During an active save burst it costs more, and refuses more.** Each attempt now has a 20 ms window a write can land in, so more attempts fail and the retry loop runs further. The arm that exists to catch this — *a normal burst of saves still yields usable pins* — is the one to watch, and the measured settle rate is in `22-experiment-log.md` → **M9-E**.
- **The check that missed it is fixed independently** (M9-C): the R-9 arms are bounded by reads rather than by a second and a half, and the blend arm now reports the **shape** of what got through rather than only the count. `1 blended of 200` sends the next reader back to re-run the suite; `0/52000 bytes` names the cause.
- **DEC-049 and M8-H stay as they are.** Both were right about what they measured, and neither claimed this window. The amendment pointer goes on DEC-049.

### Revisit trigger

Reopen if a worktree read ever needs to be on a latency-critical path — today it happens when a reader selects a file or a refresh fires, and 20 ms is invisible there. Also reopen if a partial, **non-empty** read is ever observed being certified: that would mean the window is still too short rather than absent, and the delay is the number to change.

---

## DEC-069 — Path identity is asked of the filesystem, not computed from the string

- **Date:** 2026-08-11 · **Topic:** OQ-054; DEC-018 discovery, DEC-037 multiple sources, DEC-052 configuration · **Status:** Accepted · **Closes OQ-054**

### Context

OQ-054 had been open since Phase 3.5, raised by measurement, and asked for **case-folded and NFC-normalized** path matching. It stated the consequence as: a case mismatch means **auto-refresh silently stops updating that file**.

Measured before anything was built, and **the entry was wrong in both halves**:

- **The watcher never matches paths.** `RepositoryWatcher.deliver` ORs the event flags and signals `.changed` for the whole repository. No FSEvents path is ever compared with a Git path, so the stated failure mode cannot occur. The entry was written against a per-file watching design that was never built.
- **Normalisation needs no code.** Swift's `String ==`, `hasPrefix` and `Set` membership are **canonical equivalence** — `"\u{017C}abka" == "z\u{0307}abka"` is `true`, and so are the prefix and set forms. This is M6-C pointing the other way: there, canonical equivalence made an NFC detector silently detect nothing; here it makes half of OQ-054 free.

The filesystem was measured too: **case-insensitive and normalization-insensitive for lookup, normalization-preserving for storage.** So *reading* a file never fails for these reasons — the kernel resolves it. Only Swift-side comparison breaks, and only on case.

**And root scanning was never broken either.** `contentsOfDirectory` returns the filesystem's own spelling, and `resolvingSymlinksInPath` canonicalises case as well as resolving links — both measured. A repository found by scanning always carries the canonical path.

What is left after all of that is narrow, real, and easy to reach under DEC-037, which put roots and individually added repositories in the same list:

- **An individually added repository is taken verbatim from the configuration.** The same working tree reached once by scanning and once by being added directly arrives spelled two ways, and `identity` was `standardizedFileURL.path` — a string. **Two rows for one repository**: two watchers, two sweeps, and a reader editing in one row while the other goes stale.
- **Two spellings differ in more ways than case.** `NSTemporaryDirectory()` gives `/var/folders/…` while `contentsOfDirectory` gives `/private/var/folders/…` for the same file, and `standardizedFileURL` resolves neither. A rule written in string arithmetic has to anticipate every such difference.
- **`removeSource` compared the two strings exactly**, so a source the user typed in another case could not be removed — the window said *select a repository to remove the source it came from* while one was selected.
- **Adding a folder already configured under another spelling added it twice.**

### Options considered

1. **Ask the filesystem.** Identity is device plus inode where the path exists, which is the filesystem's own answer to *are these the same file*, and settles case, normalisation and symlinked ancestors in one question.
2. **Fold the string** — `precomposedStringWithCanonicalMapping.lowercased()` everywhere. One function, no filesystem calls, works for paths that do not exist. Rejected as the guess: it is wrong on a case-**sensitive** volume, where folding merges two directories that really are different, and it does nothing about `/var` versus `/private/var`.
3. **Fold, gated on `volumeSupportsCaseSensitiveNames`.** Correct per volume and cheaper than option 1, but still string identity, so it still misses two paths reaching one directory through a link.
4. **Key by first-commit hash.** Rejected here for the reason `Configuration.swift` already gives for `baseOverrides`: a Git call per repository at startup, to answer a question a `stat` answers.

### Final decision

**Option 1, with option 2 as the fallback where there is nothing to ask.**

- **`PathIdentity.of(_:)`** returns `"<device>:<inode>"` where the path exists — the same mechanism `ScopeReader.FileStamp` already uses — and a lowercased standardised path where it does not. DEC-052 keeps a configured source that has gone missing, and its identity still has to be decidable; that is the only case the fallback reaches, and the only consequence of being wrong there is two missing sources reported as one.
- **`PathIdentity.resolved(_:)`** is the separate answer for *containment*, because an inode cannot express *underneath*. It is `resolvingSymlinksInPath().standardizedFileURL.path` — measured to return the canonical case and resolve symlinked ancestors, which is the same pair of differences expressed as a string.
- **`DiscoveredRepository.identity` becomes the dedupe key and stops being a path**, so the list gains `sortKey` — ordering the rail by an inode would order it by whatever the filesystem happened to allocate.

**Deliberately not applied**, so a later reader knows these were considered:

- **`ChangedFile.path` comparisons** and the `FileGrouping` prefix tests. Both sides come from Git, so the spelling is identical by construction, and folding there would only hide a real defect.
- **The watcher's `node_modules` test.** DEC-027 states that exclusion is a CPU concern and not a correctness one.

### Consequences

- **One `stat` per identity comparison**, on a path already being stat-ed by discovery. Not on any per-file path — identity is decided per repository and per configured source.
- **`identity` is no longer readable as a path in a debugger.** `sortKey` is, and the checks print both.
- **`baseOverrides` keeps its recorded fragility** (`Configuration.swift`), narrowed. Case and symlinked ancestors were one instance of *the same repository reached two ways*; a bind mount or a copy is another, and that one still wants the first-commit hash this entry rejected on cost.
- **Ten checks**, including two negative controls: that the two spellings really are different strings, so the deduplication is an observation rather than a tautology; and that Swift's canonical equivalence holds, since the normalisation half of the fix is entirely that assumption. 1598 → 1608.

### Revisit trigger

Reopen if the application ever has to decide identity for a path on a volume it cannot stat — a network mount that is offline, or a security-scoped bookmark that has not been resolved (OQ-035 makes that likely). The fallback is a guess, and that is the case where it would start mattering.

### Addendum to DEC-068, 2026-08-11 — the separation is 5 ms, not 20, and reusing the retry delay was the error

The decision above is unchanged: the confirming read is separated from the first in time. **What was wrong is the number, and why it was chosen.**

`settleRetryDelay` is 20 ms and is sized against a **whole save** — one measured atomic replace spans ~11 ms. The separation inside a read has to outlast something else entirely: the window between `truncate` and the first byte of the rewrite, which is microseconds. Reusing the constant was convenient rather than measured, and this entry's consequences said the cost would be "about three pins in ten".

Measured, it was **about five in ten**, and it put the suite on the floor of the arm that exists to object:

```
20 ms · saves 30 ms apart · refused of 100:  42, 46, 48, 52   ← the last one failed the >50% floor
 5 ms · saves 30 ms apart · refused of 100:   6,  8,  9,  9
20 ms · continuous rewrite · blended:        0 of 800
 5 ms · continuous rewrite · blended:        0 of 800
```

Two thirds of every attempt sat inside a window a write could land in, so the retry loop ran to exhaustion and the pair was reported unstable. At 5 ms the guarantee is unchanged — **no blend in 800 reads under continuous rewriting** — and an ordinary burst of saves keeps **91–94%** of its pins instead of half.

`ScopeReader.settleConfirmDelay` is now its own constant, so the two quantities cannot be confused again. **The general form: a constant that already exists is not a measurement, and borrowing one because it is nearby is how a number ends up sized for the wrong thing.**

---

## DEC-070 — The focus ring is drawn only while the reader is using the keyboard

- **Date:** 2026-08-11 · **Topic:** DEC-016's visible-focus commitment; `12-…` §9's 2 px ring · **Status:** Accepted · **Clarifies DEC-016**

### Context

`12-…` §9 asks for a 2 px focus ring on the focused region's own border, and DEC-016 commits to full keyboard operation with the focus **visible**. What was built draws the ring whenever a region holds first responder — which is always, since something always does.

The product owner reported it as the first thing they noticed: *"widzę też jakieś niebieskie obramowania, czy to są focusy? nie podobają mi się i nigdy nie widziałem w apce natywnej focusów."*

They are right about the native behaviour, and it is worth being exact about why. AppKit **does** draw focus rings; it draws them when the reader is navigating by keyboard and not when they are using the mouse. A ring that is lit permanently is answering a question nobody asked — the mouse user already knows where they are, because they just clicked there.

So this is not a disagreement with DEC-016. It is DEC-016 being implemented as *always* rather than *when it helps*.

### Options considered

1. **Draw it only while the keyboard is in use.** A keystroke lights it, a click puts it out. What AppKit does.
2. **Remove it.** What was literally asked for, and it drops DEC-016's commitment: a reader working from the keyboard would have no way to tell which of three regions the arrows are talking to. Rejected, and offered to the owner as an option rather than decided for them.
3. **Keep it always, styled down** — thinner, in a neutral rather than the system accent. Rejected: still present for a mouse user, so it answers the objection with cosmetics.
4. **Follow `NSApp.isFullKeyboardAccessEnabled`.** Rejected as the wrong question: that setting says whether Tab *reaches* every control, not whether this person is using the keyboard right now.

### Final decision

**Option 1**, chosen by the product owner. `navigatingByKeyboard` starts **false** — a window that has just opened has been touched by nobody, and the first thing most readers do is click.

It is set in two places, deliberately:

- **At the action**, in `moveFocus` — ⌥⌘1–3 are its only callers, so arriving there *is* keyboard navigation.
- **At the event**, by a local monitor on `.keyDown`, for everything else; a click on either mouse button clears it.

Both are needed. A key equivalent delivered through the menu — which is how ⌥⌘1–3 arrive — **does not pass through `addLocalMonitorForEvents`**, so the monitor alone would never light the ring for the one gesture the ring exists to explain.

### Consequences

- **A mouse-only reader never sees a focus ring**, which is the whole of the request.
- **DEC-016 is unchanged and still met**: the focus is visible whenever the keyboard is what is moving it.
- **The selftest can only reach half of it.** A synthesized `NSEvent` sent through `sendEvent` does not traverse a local monitor, so the arm exercises the real path for the keyboard half (through `moveFocus`) and asserts the *drawing* for the mouse half. The monitor is covered by a reader with a real mouse and nothing else — recorded rather than papered over.
- **The arm's second half is the control.** The ring as it shipped would pass the first assertion perfectly and fail the second, because it was drawn whenever a region held first responder.

### Revisit trigger

Reopen if a region ever gains focus by a route that is neither `moveFocus` nor a key event — a drag, or a programmatic focus change following a refresh. The flag would then be stale in the direction that hides the ring, which is the safer of the two but still wrong.

---

## DEC-071 — The two lists carry headers, and a pointer route may only open a binding the map already has

- **Date:** 2026-08-12 · **Topic:** the adopted design's `REPOSITORIES` and `CHANGED FILES` column headers, and the `+` beside the first of them · **Status:** Accepted

### Context

`ReviewScreen.dc.html` draws each sidebar under a header: `REPOSITORIES` with a `+` at its right edge, and `CHANGED FILES` with the number of files in it. What was built has neither. Both tables set `headerView = nil`, so the two lists are unlabelled columns of text, and the only count anywhere in the window is in the status line — one sentence for the whole window (`63 files · Unstaged`), at the opposite edge from the list it is counting.

That is the defect DEC-058 paid for three times: a fact displayed far from the thing it is about, or in a tooltip, is a fact the reader does not have. The count belongs beside what it counts.

The `+` raises a second question, which is why this entry is one decision and not two. Adding a source is already a function with a binding — `⇧⌘O` and `⇧⌘R`, drawn in the Sources menu from `KeyboardMap.bindings` since DEC-057. A button is a **third** surface for it, and the packet's drift (M8-P) is the record of what a third hand-written copy of the keyboard map does.

### Options considered

1. **`NSTableView`'s own header view.** Rejected: it is one row per column styled by the system, it scrolls with the column, and it cannot hold a button — so the `+` would have to go somewhere else anyway.
2. **A header band above each scroll view, on that pane's own surface.** A `ChromeBar` with a bottom hairline, which is the same view the title bar and the status line already are.
3. **No headers; keep the counts in the status line.** Rejected. The status line carries the scope, the watcher, and the last thing that happened; it is the line a reader glances at, not the label of a list.

### Final decision

**Option 2.** The caption and the count are composed by `ChromeLabels` in `DiffScopeShell` — an AppKit-free target the check suite links — for the reason `KeyboardMap` lives there: a sentence the interface makes should be checkable without a window.

**The `+` opens a menu built from `KeyboardMap.bindings(in: .sources)`.** It invents no titles and no shortcuts; each item shows the same key equivalent the menu bar shows, because it *is* the same binding. Generalised, and this is the half of the entry that outlives the button: **a pointer affordance may only open a function the keyboard map already has.** A control that reaches something the map does not is a function reachable only by pointer, which DEC-016 calls a defect.

**Collapsed (DEC-060), the word goes and the count stays.** A 44 pt rail and a 34 pt spine cannot hold `REPOSITORIES`; the repositories header collapses to the number of repositories and the changed-files header to the number of files. `···` was rejected — it says a header is here and says nothing about what it counts. Above 999 the collapsed count reads `999+` rather than being clipped by the label, so the number never lies about its own magnitude, and `fitsCollapsedPane` is asserted over 0…10,000.

### Consequences

- **Each list says what it is**, and the changed-file count sits above the files rather than in the status line.
- **The status line keeps its own sentence.** The count now appears twice, in two voices; that is deliberate and is the DEC-058 shape — the list's header answers *how many of these*, the status line answers *what just happened*.
- **`ChromeLabels` is where chrome copy goes from now on.** Anything the window says about itself is composed there and checked headlessly; the header captions are the first four strings in it.
- **The `+` cannot drift from the menu bar**, because it is drawn from the same array. A binding removed from the map removes the item.
- **A new pointer affordance is now a checkable claim**: every menu the chrome pops up is built from `KeyboardMap`, and the check suite refuses a title composed by hand.

### Revisit trigger

Reopen if a header ever needs to carry an action that is *not* a keyboard function — a filter, a sort, a mode — because that is the point at which the rule above stops being free and becomes a constraint on the design.

---

## DEC-072 — The scope row spans the window, and the base is a block that says it can be changed

- **Date:** 2026-08-12 · **Topic:** where the scope control lives, and how scope 4's base is drawn · **Status:** Accepted · **Refines DEC-010, DEC-011**

### Context

The four scopes are drawn as a pill control **inside the diff pane**, in a band with the mode and lens switches, and scope 4's base is a line of plain text under them. The design draws a `SCOPE` row across the whole window between the title bar and the panes, with a block at its right end reading `Base | origin/master · newest commit 9 weeks old ⇧⌘B`.

The placement is not decoration. **Changing the scope changes the middle pane** — the whole changed-file list — and only then what the diff pane shows. A control drawn inside the diff pane says it belongs to the diff pane; this one governs the window.

The base is the second half. It is the one input to the comparison the reader chooses (⇧⌘B, DEC-011), and it is currently the only such input drawn as prose. Plain text says *this is a fact*; the design's block says *this is a fact you can change*, with the keystroke on it.

### Options considered

1. **Leave the pills where they are and restyle the base.** Rejected: it keeps a window-wide control inside one pane, which is the thing the design is fixing.
2. **A full-width row between the title bar and the panes.** The scope, what it compares, and the base, in the order a reader asks them.
3. **Fold the scope into the title bar, beside the repository name.** Rejected: the title bar answers *which repository*, and it already carries the traffic lights and the search field. A bar that says four things is harder to read than two bars that each say one.

### Final decision

**Option 2.** A `ChromeBar` with a bottom hairline, above the three panes and below the title bar, holding `SCOPE`, the pill control, what the chosen scope compares, and the base block at the far end. The mode and lens switches stay in the diff pane's band for now.

**The base block is dashed when the scope is not `vs base`.** This is the entry's substantive half. `newest commit 9 weeks old` sitting in the same row as `HEAD ↔ working tree` reads as a statement about what is on screen, and it is not one — it is a fact about a ref nothing on screen is currently compared against. A **dashed rim** says so in the vocabulary the window already has: `PillControl` dashes a scope that cannot be chosen and `ChipView` dashes an ahead-count that is unknown, both because DEC-035 requires a distinction to survive greyscale. Solid rim: this block describes the comparison you are looking at. Dashed: it describes a ref you are not.

**`baseDetail` is split out of `baseSummary`** in the Git layer, so the block's three parts and the status line's one sentence are the same composition rather than two. The block's keystroke comes from `KeyboardMap.binding(id: "sources.baseBranch")`, under DEC-071's rule.

### Consequences

- **The scope is drawn where its effect is.** The file list is directly under the row that decides its contents.
- **`#showing` in the diff pane is unchanged.** It still receives the same sentence, which is the DEC-058 shape: the chrome says what the window is comparing, the pane says what the reader is looking at.
- **`ConfigurationChecks`'s "the base row is drawn under the scope control" is re-expressed rather than dropped.** Its intent — the base is *displayed*, not folded into the status line or a tooltip — is restated against the block.
- **One more thing in the window is drawn dashed**, and the vocabulary is now three deep: a scope that cannot be chosen, a count that is unknown, a base that is not being compared. All three mean *this is a different kind of thing from its neighbours*, and all three survive a greyscale screenshot.
- **`FactBlock` is a view the chrome draws**, so it is in `24-…` §3's chrome table in the same commit, which the check now requires.

### Revisit trigger

Reopen if the row gains a third control. Two — the pills and the base block — is a row a reader parses at a glance; the moment something else needs a window-wide home, the question of whether this is a *scope* row or a *comparison* row has to be answered rather than assumed.

---

## DEC-073 — Every pill prints its key, and an empty scope says so in the same shape as an unavailable one

- **Date:** 2026-08-12 · **Topic:** key hints on the three pill controls; the *available and empty* scope state · **Status:** Accepted · **Extends DEC-016, DEC-057**

### Context

The design writes the shortcut on each pill — `All local ⇧⌘1` — and lists a scope state the window does not draw: `Staged — nothing staged`.

Both are about the same gap. DEC-016 commits to full keyboard operation and DEC-057 made the map data, but **the map is only visible in the menu bar**: a reader looking at the scope control has no way to learn that ⇧⌘1 selects it without opening a menu that is three items deep. M8-J measured the keyboard path and found it complete; nothing measured whether it is *discoverable*.

The second half is a state the window currently cannot distinguish. A scope has three conditions, and the interface draws two of them: **available with work in it**, **unavailable with a reason** (`12-…` §3, dashed and stated since M9-A), and **available with nothing in it**, which today looks exactly like the first — a selected pill above an empty list, with the count `0` in the header and no word anywhere about why.

### Options considered

1. **Hints on the scope pills only**, where the row has room. Rejected as arbitrary: a reader who learns that pills carry their key from one control will look for it on the others.
2. **Hints on all three pill controls.** One mechanism, uniformly applied, drawn from `KeyboardMap` under DEC-071's rule.
3. **A tooltip.** Rejected outright — DEC-058 has paid three times for a fact that is invisible until pointed at, and the keyboard reader M8-J measured never points at anything.

For the empty state:

1. **Ask every scope whether it is empty, on every refresh.** Rejected on cost and on honesty: three more Git invocations per repository per refresh, for an answer that is stale the moment the reader saves a file.
2. **Say it for the scope that is selected**, which is the one whose count the window already has, exactly. Nothing is claimed about the other three, which is DEC-013's rule — *unknown is said, never guessed* — in its quiet form: unknown is not said at all.
3. **Put the sentence in the file pane** instead of the scope row. Rejected as a duplicate of the changed-files header, which already reads `0`.

### Final decision

**Option 2 in both halves.**

The hint is a property of a segment, composed by `ChromeLabels.pillHint(bindingID:)` from `KeyboardMap`, and drawn after the title in the faintest ink at the smallest size — a key is a different kind of thing from a name, and the design draws it as one.

The empty scope reads `Staged — nothing staged`, in **the same shape as the unavailable state** the window already draws: `title — reason`. The words are the scope's own (`ComparisonScope.emptyDescription`), composed in the Git layer beside `comparisonDescription` for the reason that one is — a sentence the interface assembles cannot be checked. It replaces the comparison text in the scope row while it holds, because *what this scope compares* is not the reader's question when the answer is nothing.

### Consequences

- **The keyboard map is visible on the controls**, not only in the menu bar. Three surfaces now draw it and all three read `KeyboardMap`: the menu, the `+`'s pop-up, and the pills.
- **The pills are wider.** Measured: the scope control goes from 268 pt to about 380, and the mode and lens controls together no longer fit a diff pane at its 300 pt minimum — they already did not, and the hints make the clipping easier to hit. Recorded here rather than fixed; the row that will hold the mode switch is the status line (still to come), which is window-wide.
- **An empty scope is a stated state.** A reader who presses ⇧⌘3 and sees nothing is told *nothing staged* rather than being left to wonder whether the tool failed.
- **Nothing is claimed about scopes that are not selected**, and that is a deliberate silence rather than an oversight.

### Revisit trigger

Reopen the second half if the sweep ever computes per-scope counts for another reason. The cost objection disappears the moment the number is already in hand, and the design's own form — a state on each pill — becomes reachable without a single extra invocation.

---

## DEC-074 — A group header is the shortest front-anchored form that stays unique

- **Date:** 2026-08-12 · **Topic:** what the file list's group headers say · **Status:** Accepted · **Amends DEC-033 (as amended 2026-07-31)**

### Context

DEC-033's amendment groups changed files by declared workspace package where there is one and by parent directory otherwise, and the header is **the group key verbatim**. On the corpus that means headers like `packages/app-2/src/components/nested` — five components, in a pane 320 pt wide, truncated from the head so the reader sees `…/components/nested` and the part that distinguishes one group from another is the part that was cut.

The design writes `PACKAGES/WEB`.

### Options considered

1. **The last two components.** Rejected by the corpus: nine groups of the fixture tree end in `components/nested`, so all nine headers would be the same words — which is worse than a truncated path, because it *looks* like an answer.
2. **The first two components, with an ellipsis where more follow, lengthened until every header in the list is unique.** `packages/web` → `PACKAGES/WEB`, and the nine deep groups → `PACKAGES/APP-0…` … `PACKAGES/APP-8…`.
3. **Elide the common middle** — `PACKAGES/APP-0/…/NESTED`. Rejected as a rule with two moving parts and no better answer on any real input in the corpus.
4. **Leave the paths and let the pane truncate.** What ships today, and the failure is silent: the truncation removes exactly the distinguishing prefix.

### Final decision

**Option 2**, with uniqueness as the invariant that makes shortening safe.

The rule: take the first *n* components, upper-cased, and append `…` when the key has more; start at *n* = 2 and raise it for the whole list until no two headers are equal. Where two keys differ only in case — `a/Web` and `a/web` — upper-casing cannot separate them at any depth, and the whole list falls back to the keys verbatim rather than drawing two identical headers.

**Front-anchored, because that is where identity lives.** In a monorepo the package is the first component or two; the tail is `src/components/…` in every group and separates nothing. This is the opposite end from the file rows, which show the path *relative* to their group — between them the reader has the whole path, and the row's tooltip still carries it in full.

**The sentinel `(repository root)` is passed through unchanged.** It is already a label rather than a path, and upper-casing it would produce `(REPOSITORY ROOT)`.

### Consequences

- **Two groups can never share a header.** That is asserted as a property over generated keys, not only over the examples, because the whole safety of shortening rests on it.
- **The full path is still available** on the row's tooltip and, for the files themselves, in the diff pane's `#file-path` — which is where DEC-058 requires a displayed fact to be.
- **Headers get shorter as a list gets more homogeneous, and longer as it gets more varied**, which is the right direction: a list whose groups differ only deep in the tree is a list where the deep part is what the reader needs.
- `fileListRows` is unchanged and still carries the group key. The short form is computed beside it and looked up when a header is drawn, so nothing that reasons about grouping has to know about presentation.

### Revisit trigger

Reopen if a repository ever produces more than about ten groups whose first two components are identical: the rule then lengthens every header in the list at once, and the pane may be better served by lengthening only the headers that collide.

---

## DEC-075 — The status line carries the watcher, the modes and the keys, and it prints the keys the map actually binds

- **Date:** 2026-08-12 · **Topic:** what the bottom bar says; where the mode switch lives; the design's key legend · **Status:** Accepted · **Extends DEC-026, DEC-027, DEC-064**

### Context

The design's status line has three fields: `● Watching · refreshed 4s ago` at the left, the mode switch in the middle, and at the right the layout control, `Wrap long lines`, and a legend reading `⌥↑↓ change · ⌘⏎ open in editor`.

What ships is one label carrying whatever happened last. Three things are missing from it and one is wrong in the design.

**The watcher has never been visible.** DEC-027 watches the open repository and DEC-026 debounces; the reader is told only when it *fails* (`auto-refresh unavailable for …`). A reader looking at a diff has no way to know whether what they are seeing is live, and *nothing is happening* looks exactly like *watching, nothing has changed*. It is also the one fact that makes the rest of the window trustworthy: every count in it is as old as the last refresh.

**The legend in the design is wrong about this product.** It writes `⌥↑↓ change`, and DEC-065 gives `⌥↑↓` to **files**; changes are `⌘↑↓`. A legend is a promise about a keystroke, and one printed from a picture rather than from the map is the tester packet's defect on a surface every reader sees.

### Options considered

1. **Draw the design's legend as written.** Rejected outright: it names a key that does something else.
2. **Compose the legend from `KeyboardMap`** — three entries, `⌘↑↓ change · ⌥↑↓ file · ⌘⏎ open in editor` — under DEC-071's rule, with a check that every keystroke it prints is one the map composes.
3. **Drop the legend.** Rejected: it is the only place in the window that says movement has keys at all, and the pills say it for the things that are pills.

For the watcher:

1. **A dot and a word, with the age of the last refresh** — `● Watching · refreshed 4s ago`, and `○ Not watching — <reason>` where the watcher failed or stopped. Shape as well as colour (DEC-035): a filled dot against a hollow one.
2. **A word only.** Rejected: *watching* without an age says nothing about how old the counts are, which is the question the field exists to answer.
3. **An age only.** Rejected in the other direction: `refreshed 4s ago` beside a dead watcher would be a true sentence in the service of a false impression.

### Final decision

**Option 1 and option 2.** The bar's three fields are the design's, and the legend is the map's.

**`refreshed Ns ago` is measured from the last time the window actually re-read the repository** — `reloadFiles` and the sweep, the two places that replace what is on screen — not from the last keystroke, the last render or the last file-system event. An event the debounce swallowed changed nothing and must not reset the clock (DEC-026). Before the first refresh the clause is absent rather than zero.

**The mode switch moves here from the diff pane's band.** It applies to the whole window's reading of a file and it is now the only pill left with nowhere to be; the lens stays in the pane, because a lens *is* about that pane.

**The words are `Unified` and `Side by side`, not icons.** The design draws glyphs; this project has no icon set, and a glyph a reader cannot name is worse than a word. Recorded so the next revision does not read the absence as an oversight.

### Consequences

- **The window says how old it is.** Every count in it is as old as the last refresh, and until now nothing said when that was.
- **A failed watcher is visible while it is failing**, not only in the moment it failed. The old message was transient: it was overwritten by the next thing that happened, and the reader was left with a window that quietly stopped following the disk.
- **The transient message keeps its place beside the watcher field**, so nothing that used to be said stops being said.
- **The legend disagrees with the design on purpose**, and the check is what keeps it that way: every keystroke printed in the chrome must be one `KeyboardMap` composes.
- **The bar is 30 pt rather than 24**, because a 24 pt pill cannot sit in a 24 pt bar.

### Revisit trigger

Reopen if the age ever needs to be per-repository rather than per-window: the sweep refreshes all of them and the watcher follows only the open one, so a reader looking at the repository list is reading counts of two different ages. Today the list is swept as a whole and the distinction does not arise.

---

## DEC-076 — The tertiary ink is re-measured against every surface it is drawn on, not against the paper

- **Date:** 2026-08-12 · **Topic:** `--ds-faint` in both appearances · **Status:** Accepted · **Amends DEC-066's token table; extends `27-…` §3**

### Context

`27-…` §3 records the adopted design's tertiary text failing contrast at 2.7:1 in light and 3.8:1 in dark, and being **fixed by measurement rather than by eye** to 5.1:1 and 5.8:1. Those two numbers were measured against the paper — `--ds-bg`. The chrome has eight other surfaces, and nothing had ever measured them.

Photographed in light for the first time (step 62) and measured, `--ds-faint` at `#6b6b74` / `#86868f` is **4.47:1** on the chrome band, **4.32:1** on the control trough, **4.12:1** on a selected row, and **3.47:1** on the raised thumb in dark. Those four carry the key hints, the status line's legend, the `SCOPE` caption, the base block, a selected repository's path, and every pill that is not chosen.

### Options considered

1. **Move the labels to `--ds-dim`** and draw `--ds-faint` on the two panel surfaces only. Shipped as the immediate fix in step 62; it flattens the design's three-step hierarchy to two wherever the chrome is not a panel, and leaves a token that is a trap for the next person.
2. **Darken it in light and lighten it in dark, until it clears every surface.** Chosen by the product owner.
3. **Give the raised thumb its own ink.** Rejected: it is one site, and a per-surface exception is the rule this entry exists to remove.

### Final decision

**Option 2**, at **`#62626b` in light and `#9e9ea7` in dark**, and the threshold is the substance of the entry.

The binding surfaces are the extremes rather than the paper: `--ds-row-selected` in light (4.72:1) and `--ds-control-thumb` in dark (4.72:1) — the raised thumb is a *light* surface inside a dark window, so an ink that clears it must be nearly as bright as `--ds-dim`.

**The target is 4.7, not 5.0**, and that number was measured rather than chosen. At 5.0 the dark value comes out at `#a3a3ac`, which is **1.06:1 against `--ds-dim`** — the third ink and the second become the same ink, and a hierarchy of three that reads as two is worse than a step that clears the threshold by a tenth. At 4.7 the step is 1.34:1 in light and 1.13:1 in dark, and every surface clears 4.72:1 with room for rounding.

### Consequences

- **The third ink is usable on every surface the chrome draws**, so step 62's substitutions are reverted: the key hints, the legend, the `SCOPE` caption, the base block's shortcut and a repository's path are tertiary again, as the design draws them.
- **The check outlives the fix.** `runChromeChecks` holds every ink/surface pair to 4.5:1 in both appearances; its negative control is now the **previous value on the chrome band** as a literal, so the check that caught this cannot be quietly satisfied by the change that fixed it.
- **The webview surfaces were measured too** — `--ds-bg`, `--ds-code`, `--ds-fold` — because the same token is drawn there: 5.40, 6.04 and 5.64 in light, 7.90, 7.90 and 7.25 in dark.
- **`27-…` §3's numbers are superseded, not deleted.** They were right about the paper and were never wrong; they were incomplete, and this entry says which surfaces they did not cover.

### Revisit trigger

Reopen if a surface lighter than `--ds-control-thumb` is added to the dark appearance, or darker than `--ds-row-selected` to the light one. Both are the extremes this pair is sized against, and a new extreme moves the constraint rather than merely adding a row to the check.

---

## DEC-077 — The interface gets quieter: the reader is a frontend developer, not the tool's author

- **Date:** 2026-08-13 · **Topic:** the product owner's second session with the built window · **Status:** Accepted · **Amends DEC-016, DEC-017, DEC-035, DEC-058, DEC-070, DEC-073; amends `24-…` §5's track rule**

### Context

The owner used the finished chrome and reported fourteen things. Read one by one they are a styling list; read together they are one sentence, and the owner wrote it themselves:

> *"wyobraź sobie że tworzysz UI dla juniora ale frontenda a nie experta od algorytmów, diffów, gita"* — and, decisively: *"jeśli coś nie wiadomo czy mi się przyda jako info czy nie, to usuń, najwyżej jak będę miał chęć dodania to osobno poproszę."*

This project has been building for the reader who wants to know **how the tool reached its answer**. `parser: parsed — tree-sitter tsx`, `confidence: high`, `mode: structural`, a keystroke printed on every control, a focus ring, a scroll track that stays visible while disabled — each of those is a decision with a rationale, and each was written for someone auditing the diff engine. The person using it wants to open a repository, look at what changed, and commit.

**The trust apparatus is not the same thing as the trust display.** The invariants, the validator and the 1673 checks are what make the product's claim true; the chips are one way of *saying* it, and DEC-017 chose the loudest one available. That choice is what this entry revisits — not the claim.

### Options considered

1. **Keep everything and restyle it.** Rejected by the owner explicitly: the information density is the complaint, not the colours.
2. **Remove every technical statement.** Rejected here, and it is the one place this entry pushes back: **INV-4 — *every fallback is marked as a fallback*** — is the core invariant made visible. A file that could not be parsed and is being shown as plain text must say so, or the product's central promise becomes unobservable. That sentence stays, in plain words.
3. **Quiet by default, in the reader's language, with the detail available on request.** Chosen.

### Final decision

**Option 3.** Specifically, and each of these reverses something recorded:

- **The three trust chips go** (`parser:`, `confidence:`, `mode:`). What replaces them is **nothing at all while everything is normal**, and one plain sentence when it is not: *this file is shown as plain text*, *some parts could not be matched confidently*. DEC-017's requirement is met by the sentence rather than by a permanent readout; DEC-058's parser state is computed exactly as before and is simply not printed while it says *parsed*.
- **Keystrokes leave the interface** (DEC-073's hints, the status line's legend, the base block's `⇧⌘B`). The map is unchanged and the menu bar still draws it; the pills stop teaching it. A place to look them up belongs in Settings, later.
- **The focus ring goes** (DEC-070's option 2, which was offered and declined then, and is chosen now). DEC-016's *visible focus* is carried by the selection itself.
- **A change is a tint over the whole line, and a stronger tint on the bytes that changed** — no underlines. This touches DEC-035, which forbids colour alone, so the rule is restated rather than dropped: **the two tints must differ in luminance**, so the distinction survives greyscale, and the sign column and the gutter mark stay. Underlines were the shape carrier; they are also what makes a line hard to read, which is the complaint.
- **The switches become popovers**: a control shows the chosen option, and the others appear when it is clicked.
- **Glass, where the system has it.** `NSGlassEffectView` (macOS 26) is real API — `contentView`, `cornerRadius`, `tintColor`, `style`, and `NSGlassEffectContainerView` for merging neighbours. Under `if #available(macOS 26, *)`, with the drawn pill as the fallback, so nothing imitates a material it does not have.
- **The horizontal track is hidden when there is nothing to scroll**, reversing `24-…` §5's *quietened, never removed*. The rule was written about a control a reader might need; this one **cannot be used**, and a dead control is worse than an absent one.

### Consequences

- **The window says less and the checks say the same.** Every fact removed from the screen is still computed and still asserted; what changes is who it is shown to.
- **Six checks are re-expressed, not deleted** — the hint checks, the legend check, the mark-shape check. Each keeps its intent: a keystroke *drawn anywhere* must still be one the map composes, and a mark must still survive greyscale.
- **The engine is untouched.** Nothing here changes what is compared, aligned or validated.
- **DEC-017 is narrowed, not withdrawn.** A degradation is still stated; a normal file is now silent about the machinery that read it.

### Revisit trigger

Reopen the first point the moment a reader is surprised by an answer — the chips exist because a tool that aligns code structurally can be wrong in ways a reader cannot see, and *silent and right* and *silent and wrong* look identical. The sentence for a degradation is the floor, and it does not move.

---

## DEC-078 — Expanding a fold is reversible, and one command does both directions

- **Date:** 2026-08-14 · **Topic:** `⌘E` expands every collapsed range and there is no way back · **Status:** Accepted · **Amends DEC-017; item 4 of [28-interface-plan.md](28-interface-plan.md)**

### Context

DEC-017 permits folding — the one presentation act that puts content out of sight — **only while the count of what is hidden is shown and it is one keystroke from opening**. That is a rule about getting *in* to the folded state, and it was written from the position of a reader who is worried about losing a difference. It says nothing about getting back out, and nothing did: `expandAll` adds every fold index to a set that is only ever cleared when a new model arrives.

The owner reported it as a defect, and it is one in the plain sense — a reader who presses `⌘E` on a file with sixty folded lines to check one of them cannot get the file back to the shape they were reading it in. Their remedy today is to select another file and select this one again.

There is a second-order cost. Folding exists because unchanged text is noise; a reader who cannot re-fold has to weigh *do I want to see this* against *am I willing to lose the shape of the file*, which is exactly the kind of small irreversible choice that makes people stop using a control.

### Options considered

1. **A second command and a second key** — `⌘E` expands, `⇧⌘E` collapses. Rejected: the map is already at four modifier tiers, and DEC-077 has just taken every printed keystroke off the screen, so a reader would have to *learn* the second one from a menu. Two commands also make it possible to be in a state neither of them describes.
2. **Collapse restores exactly what was folded before, per fold.** Rejected as more than was asked for and less checkable: a fold that was opened by clicking it, and a fold that was opened because a jump landed inside it (`goToStop` opens whatever covers its target), would restore differently, and no button label can honestly describe that.
3. **One command that toggles: expand everything, unless everything is already expanded, in which case collapse everything.** Chosen.

### Final decision

**Option 3.** Specifically:

- `expandAll` expands every fold **unless every fold is already expanded**, in which case it collapses every fold. One key, one menu item, one button.
- The rule is deliberately *everything is expanded*, not *anything is expanded*: a reader who has opened one fold by clicking it, or who has jumped into one, presses `⌘E` to open the rest — which is the reading of the key they already have. The second press closes them all.
- **The button says which way it will go** — `Expand` or `Collapse`, recomputed whenever the footer is. A control whose effect depends on hidden state has to state the effect, and this is the one place in the pane where that state is not otherwise visible.
- The menu item is renamed to name the toggle rather than one of its directions.
- The button stops printing `⌘E`, completing DEC-077 in the one place it had been missed: the rule was written about the chrome and this label lives in the webview.

### Consequences

- **DEC-017 is unchanged in substance.** The count is still shown, the content is still one keystroke away, and the folded state is still the one the model arrives in. What is added is the way back.
- **A new state is reachable that was not before**: everything folded again after having been unfolded. It is the state the model arrives in, so nothing new has to be drawn for it.
- The disclosed count in the footer already describes the folded state, so the bar is correct in both directions with no change.
- Checked with both directions and their controls: two presses return the document to the fold count it started with, and a press with one fold already open expands rather than collapses.

### Revisit trigger

Reopen if a reader asks for *this fold* back rather than all of them — that is option 2, and it needs a per-fold record and a label that can describe it.

---

## DEC-079 — The motion register lives in this repository, and it is a checked list rather than a promise

- **Date:** 2026-08-14 · **Topic:** DEC-064's register is a table in a document nobody here can open · **Status:** Accepted · **Amends DEC-064; item 8 of [28-interface-plan.md](28-interface-plan.md)**

### Context

DEC-064 admitted motion and replaced a guarantee by construction — *nothing animates, so reduced motion cannot be got wrong* — with a guarantee by check. The check it named has two halves: **every animated property is neutralised under `prefers-reduced-motion`**, which is built and carries two negative controls; and **the register**, which it placed in the adopted design's Motion table: *"a transition with no entry in that column is not shippable."*

The register half has never been enforceable. The design lives behind the owner's login (`27-…`, `21-…` §0 have said so since the transcription), so *is this transition in the register* is a question nobody in this repository can answer. `28-…` item 8 asks for the register and the code to list the same set, which is the first time that gap has had to be closed rather than noted.

The second half of the problem is that the register is empty in practice. Three transitions ship, all in the webview, and DEC-064's own list of what should move — popovers, the collapse, a scope change, a file selection — is mostly unbuilt.

### Options considered

1. **Ask the owner for the Motion table and transcribe it.** Rejected as the primary answer for the reason the token table was transcribed rather than linked: a table that arrives once and is then hand-copied drifts, and the drift is invisible. It remains worth asking for as a *review* of what is written here.
2. **Drop the register and keep only the reduced-motion check.** Rejected: that check answers *does this animation have an off switch*, never *should this animation exist*. Option 2 of DEC-064 — motion allowed, review left to reviewers — was rejected there for the same reason, and this would arrive at it by omission.
3. **The register is a table in `24-design-contract.md`, and a check requires it and the stylesheet to list the same set.** Chosen.

### Final decision

**Option 3.** The register is `24-…` §5's Motion table: one row per transition, naming **what moves, where, its duration token, and its reduced-motion path**. Two rules, both checked:

- **Every animated property in the stylesheet appears in the register**, and every row of the register appears in the stylesheet. A transition added to the code without a row fails; a row with nothing behind it fails.
- The reduced-motion half of DEC-064 is unchanged and still carries its two negative controls.

The chrome is in the register too, and its off switch is `accessibilityDisplayShouldReduceMotion` rather than a media query — AppKit has no media queries, which is why that clause was already in the contract's rule 9.

### Consequences

- **The register is now falsifiable**, which is the whole of what it was missing. It was a promise about a document, and it is a list two files have to agree on.
- **Ask the owner to review it against their Motion table** rather than to supply it. That is a smaller, answerable question, and it is the same shape as the outstanding request for the light-mode screenshots.
- A snapshot still cannot photograph motion (DEC-064's own consequence). What is photographed is the **reduced-motion path**, which is a static state and the one that matters for the guarantee.

### Revisit trigger

Reopen if the design's Motion table turns out to disagree with this list in kind rather than in wording — that would mean the interface moves in a way the design did not ask for, which is a design question rather than a bookkeeping one.

---

## DEC-080 — The four surfaces become a ladder, and the transcribed values move for the first time

- **Date:** 2026-08-14 · **Topic:** *"nie widać przejrzyście gdzie zaczyna się miejsce z diffem, gdzie z plikiem, gdzie wyboru opcji"* · **Status:** Accepted · **Amends DEC-066, DEC-076; item 9 of [28-interface-plan.md](28-interface-plan.md)**

### Context

The window has four surfaces — the chrome band, the repository list, the changed-file list and the code — and DEC-066 gave each of them a token from the adopted design's table. Measured, they are within a few percent of each other: in light, `#ececed`, `#f6f6f8`, `#fbfbfd` and `#ffffff`, a spread of nineteen values out of 255. In dark the ladder is not even monotone — the repository pane (`#0b0b0d`) is *darker* than the file pane (`#0e0e11`) while the chrome above both is lighter than either.

The owner's report is that they cannot see where one region ends and the next begins, and their own diagnosis — *"pewnie przez to że 99% wyglądu to czarny i biały"* — is right about the cause. Every check this project has about colour is about **ink on a surface**; nothing has ever asked whether two surfaces are distinguishable from each other.

**This is the first change to a transcribed value.** DEC-066 delivered the design as a token table and every value since has been the design's. `28-…` item 9 says outright that this is the one item where that table is the starting point rather than the constraint, and `27-…` records that since the transcription this repository is the source of truth for what ships.

### Options considered

1. **Borders instead of values.** A hairline between panes already exists (`ChromeBar`), and adding more is what a design does when it cannot change the surfaces. Rejected as the primary answer: the complaint is that the regions look the same, and a line between two identical greys says *there is a boundary here* without saying *these are different places*.
2. **Only the dark appearance**, where the ladder is not monotone and the defect is worst. Rejected: light is where the owner works and its spread is nineteen values.
3. **A measured ladder in both appearances, with a floor, checked.** Chosen.

### Final decision

**Option 3.** The four surfaces are a ladder from the code outward, and **each step is at least 1.10:1** — the same floor DEC-076 put between the second and third inks, for the same reason: two things that must read as different should not be a hundredth apart.

| Surface | Light | Dark |
|---|---|---|
| `--ds-code` — the diff | `#ffffff` | `#000000` |
| `--ds-panel-files` | `#f2f2f6` | `#131317` |
| `--ds-panel-repos` | `#e6e6ed` | `#1e1e25` |
| `--ds-chrome` | `#d9d9e1` | `#26262d` |

The content is the extreme in both appearances and the chrome is furthest from it, so the window reads as *the thing you are looking at, and the furniture around it*. `--ds-row-selected`, `--ds-row-ring`, `--ds-bg`, `--ds-fold`, `--ds-control-trough` and `--ds-empty-bg` move with them; the ANSI palette, the syntax colours and the change tints do not.

**Two inks move with the surfaces, and DEC-076's arithmetic is redone rather than inherited.** Darker panels take `--ds-faint` below 4.5:1, so light's second and third inks become `#42424a` and `#57575f`. Every ink/surface pair the chrome draws clears **4.72:1** in dark and **4.91:1** in light, against the 4.5 threshold — better than the values this replaces, because DEC-076 sized them against surfaces that have now moved apart.

A check holds the ladder in both appearances, adjacent step by adjacent step, with the shipped values as its negative control.

### Consequences

- **The window has a hierarchy that survives greyscale**, which is the same rule the change language follows: the distinction is luminance, so a screenshot and a colour-blind reader both keep it.
- **DEC-076's check is unchanged and still passes**, at a wider margin. Its three negative controls are literals and remain valid.
- **The design's table and this repository now disagree in four rows, deliberately.** Ask the owner whether the ladder should be steeper or shallower — a preference this document cannot answer and a screenshot would settle in a second.
- Every recorded light-mode measurement from 2026-08-12 (`#ececed` for the title bar and so on) is now historical. It is left as written and superseded here rather than rewritten.

### Revisit trigger

Reopen if the owner reads the chrome as *dimmed* rather than as *behind*: a ladder that goes too far turns furniture into something that looks disabled, and the fix is a shallower step rather than a border.

---

## DEC-081 — The file-kind glyphs get colour, as the second carrier and never the first

- **Date:** 2026-08-14 · **Topic:** *"nie widzę żeby te ikonki miały kolor np żółty gdy było coś zmieniane w pliku"* · **Status:** Accepted · **Extends DEC-035, DEC-066, DEC-080; item 10 of [28-interface-plan.md](28-interface-plan.md)**

### Context

Every row in the changed-file list carries a glyph for its kind — `+` added, `−` deleted, `→` renamed, `✎` modified — and all of them are drawn in the ordinary ink. The glyphs exist because DEC-035 forbids colour alone and `24-…` records the adopted design getting this wrong once already: it drew the collapsed spine's bars distinguished by **hue alone**, which is the failure this project refuses.

Having corrected that, the interface went to the other extreme and used no hue at all. A reader scanning sixty rows for *what happened to this file* is doing character recognition on one glyph at the smallest size the window draws. Colour is the channel that answers that at a glance, and it costs nothing that DEC-035 protects — **as long as it is added to the shape rather than substituted for it.**

### Options considered

1. **Colour every kind.** Seven kinds, seven hues, four of which a reader meets rarely. Rejected: a palette sized to fill a table rather than to answer a question, and seven hues at 4.5:1 on three surfaces is a search with no good answers at the end of it.
2. **Colour the row, not the glyph.** Rejected outright: a tinted row is the change language's own vocabulary (`24-…` — *tint and texture belong to the change language, and a second meaning for them is a meaning nobody can read*), and it would collide with the selected-row treatment.
3. **Colour the four kinds the reader meets, leave the rest in the ordinary ink.** Chosen.

### Final decision

**Option 3.** `--ds-kind-added`, `--ds-kind-modified`, `--ds-kind-deleted` and `--ds-kind-renamed`, in both appearances, mirrored in `Theme.swift`. Untracked, type-changed and unmerged keep `--ds-text`: a kind with no colour of its own is still a kind with a glyph, and inventing three more hues to fill the table would weaken the four that mean something.

**The glyph is the carrier and the colour is the reinforcement.** The order matters and is checked the way DEC-035 has always been checked — the glyph vocabulary is untouched, so every kind survives greyscale exactly as it did before this entry.

Each colour clears **4.5:1 on all three surfaces a row is drawn on** — the file pane, the repository pane and a selected row — added to the hand-maintained pair list `runChromeChecks` holds. That list is the reason this is cheap: DEC-076 built it after the tertiary ink was found failing on four surfaces nobody had measured, and adding a colour to the window now means adding its rows.

### Consequences

- **Twelve new pairs in the contrast check**, and they pass at 4.51:1 to 7.44:1.
- The collapsed spine's bar takes the kind's colour too, so the rail and the full list say the same thing in the same way.
- **This is the second entry in two days to add tokens the design's table does not have** (after [DEC-080](04-decision-log.md)). Both are on `28-…`'s list and both are recorded here rather than in a stylesheet; ask the owner to review the four hues against theirs.

### Revisit trigger

Reopen if a kind ever becomes distinguishable by colour alone — a glyph dropped for space, a spine narrowed until only the bar fits. That is DEC-035's line and this entry does not move it.

---

## DEC-082 — The default editor template opens the line, through the launcher rather than through a URL

- **Date:** 2026-08-14 · **Topic:** `⌘⏎` opens the file at the top, because the default template has no `{line}` · **Status:** Accepted · **Completes DEC-015; §3 of [28-interface-plan.md](28-interface-plan.md)**

### Context

DEC-015 made opening the editor a template the reader sets, with `{file}` and `{line}` substituted. The template shipped is `/usr/bin/open -a WebStorm {file}` — **no `{line}`** — so the default cannot jump to a line and `⌘⏎` opens the file at the top until the reader configures something else. `23b-…` §1 recorded it as the last open item of the POC audit, and `21-…` and `28-…` both described it as *one line to fix*.

**It is one line, and calling it that was still wrong**, because the line is not the hard part: `open -a` cannot take a line number at all. The choice is between three mechanisms, and it is a question about what is installed rather than about what to write.

### Options considered

Measured on this machine rather than reasoned about (`22-experiment-log.md` → M10-A).

1. **`open` with a `jetbrains://web-storm/navigate/reference?path={file}:{line}` URL.** The handler *is* registered here, and `open` percent-encodes a space, a `%` and non-ASCII by itself — so the encoding worry is mostly unfounded. **It leaves `#` and `?` raw**, and both are legal in a path: `…/note#1/a.ts` arrives as a URL fragment and WebStorm receives `path=…/note`. That is **the wrong file, opened silently**, with `open` exiting 0. Rejected on that alone; `#` in a path is not exotic in a JavaScript project. Fixing it needs a second substitution token, because `{file}` must stay raw for every `open -a`-shaped template — so it stops being one line and becomes a new item in the template vocabulary.
2. **Leave it as it is** and let the reader configure a template. Rejected: the default is what a stranger meets, and `25-…` tells them `⌘⏎` opens the file — at the top, without saying so.
3. **The IDE's own launcher: `/Applications/WebStorm.app/Contents/MacOS/webstorm --line {line} {file}`.** Chosen.

### Final decision

**Option 3.** No URL is parsed, so `#` and `?` in a path are ordinary characters — and `EditorCommand` already splits the template *before* substituting, which is what keeps a path with a space one argument (the defect `05-…` OQ-041 records finding).

**Two limits, both measured and neither hidden:**

- **The launcher exits 0 whatever it is given** — a missing file and a non-numeric line both returned 0 in 0.5 s. So `launchEditor` cannot distinguish *opened* from *forwarded and ignored*. This is the same limit option 1 has, and it is narrower here: the only way to reach it is a file that does not exist, and the file being opened is the one the diff has just read.
- **The path is an install location.** A WebStorm installed only through JetBrains Toolbox is not at `/Applications`, and the default then fails — **visibly**, as `.notLaunched`, because `Process.run()` throws for an executable that is not there and `13-…` §2's F13 already reports it in the status line. A default that fails loudly is worth more than one that opens the wrong line quietly.

### Consequences

- **`⌘⏎` lands on the line the reader is looking at**, which is what DEC-015 promised and what `diffscopeCurrentLine` was built to supply.
- `23b-…` §1's last open item is closed; `23a-…`, `19-…`, `25-…` and `21-…` carry the new default.
- A check requires the default to contain both tokens, with the old template as its negative control — a default that silently loses `{line}` again is the regression this entry exists to prevent.

### Revisit trigger

Reopen if the owner's WebStorm moves, or if a reader reports `⌘⏎` doing nothing — that is the silent arm above, and the answer is a template pointing at their own install rather than a change here.

---

## DEC-083 — The third session: the interface stops explaining itself, and starts being clickable

- **Date:** 2026-08-14 · **Topic:** the product owner's third session, on the packaged build `03d963e` · **Status:** Accepted · **Amends DEC-017, DEC-035, DEC-058, DEC-077; work list in [28-interface-plan.md](28-interface-plan.md) §5**

### Context

The owner used the packaged build against real repositories — five of their own, twenty changed files — and reported seven things. Read one by one they are a mixed bag; read together they are two sentences, and both are continuations rather than reversals.

**The first is DEC-077 carried one step further.** That entry took the *machinery's* vocabulary off the screen — `parser:`, `confidence:`, `mode:`. What is left is the same vocabulary in two quieter forms: a diagonal texture behind changed bytes whose only job is to distinguish `formatting` from `behaviour` from `uncertain`, and a grey word after the line saying which of those it is. The owner asked for both to go. The reasoning that admitted them is DEC-017's — *the invariant becomes visible* — and DEC-077 already established the answer: the apparatus is not the display, and a distinction the reader has not asked for is noise however quietly it is drawn.

**The second is that things do not look clickable, and some are hard to hit.** No `cursor: pointer` anywhere in the chrome and in two places in the webview; the `+` and the two collapse chevrons are unbordered buttons with no size of their own, so the hit area is the glyph — 11 pt — and when a pane is collapsed to a 44 pt rail the chevron is the only target in it. This is not a taste report. `12-…` §9 and DEC-016 are about the keyboard being sufficient; nothing has ever said the pointer has to be *comfortable*, and the result is a window that is fully operable and unpleasant to operate.

Two of the seven are plain defects rather than either sentence: **the selected file is not marked**, and **the diff pane's background starts 18 pt below the two lists'**.

### Options considered

1. **Take the reports one at a time as styling.** Rejected for the reason DEC-077 was written rather than a stylesheet edit: two of these reverse recorded decisions and one collides with DEC-035, and a check that is loosened without an entry is a rule that quietly stops holding.
2. **Keep the textures and drop only the words.** Rejected: the texture exists *to* carry the distinction the words spell out. Keeping one and dropping the other leaves a signal nobody can read.
3. **Both go; the tint pair carries greyscale; the pointer gets sized targets.** Chosen.

### Final decision

**Option 3**, item by item.

- **The change textures go** (`--ds-tex-*`, all seven). This touches DEC-035, so the rule is restated rather than dropped, exactly as DEC-077 restated it for the underline: **the mark's greyscale signal is the tint pair**, which differs in luminance by measurement and is already checked. `ds-moved` keeps its dashed outline and `ds-invisible` its dotted one — those two are shapes rather than textures, and both mark something a reader cannot otherwise detect.
- **The line notes go** (`ds-note`): `formatting`, `uncertain`, `reordered`, `M1`, `inserted`, `removed`. The contract already calls them *annotation only* and forbids them from being the sole carrier of anything, so nothing becomes invisible — the sign column, the gutter edge and the tint pair say what changed, and `#diff-footer` still discloses the grouped count DEC-017 requires.
- **`#showing`'s legend goes with them.** *"+ added, − removed in the sign column"* explains a convention every reader of a diff already has. What the row keeps is **what is being compared**, which is the half DEC-058 was paid for three times.
- **The selected file is marked**, the way the selected repository is — a fill and a bar at the leading edge. It was never a styling gap: the row is selected on click and lost on the next sweep, which is the defect DEC-077 fixed for repositories and nobody carried to the second list.
- **The three surfaces start at the same height.** The pane headers are 22 pt and the diff pane's control band is 40, so the code's background sits 18 pt below the lists'. The band matches the headers.
- **Anything that can be clicked says so**, and is big enough to hit: `cursor: pointer` on every pointer affordance in both webviews, `NSCursor.pointingHand` on every control the chrome draws, and a **minimum 24 × 24 pt hit area** on the `+` and the two chevrons — which is what makes a collapsed 44 pt rail usable.
- **The metal-rimmed buttons of the adopted design are deferred**, not rejected. The design is behind the owner's login and this is the fourth thing that cannot be read from here; it is written down as blocked on one screenshot rather than guessed at.

### Consequences

- **Six of the seven marks lose their texture and keep their meaning.** The greyscale rule moves onto a measurement that already exists, so DEC-035 is satisfied by fewer mechanisms rather than by a weaker one — and the checks that enforced the texture are re-expressed, not deleted.
- **`ds-note` leaves the class table** and the design contract loses a row. Nothing referenced it as a sole carrier, which is why this is cheap.
- **Four questions are now queued for the owner**, all answerable with a screenshot: the glass, DEC-080's ladder, DEC-081's hues, and this entry's button rim. That is a standing cost of a design nobody in the repository can open, and it is worth stating plainly rather than re-discovering.

### Revisit trigger

Reopen the first point if a reader ever asks *why is this line marked* — the textures and the notes were the answer to that question, and what replaces them is the footer's count plus Expanded. Reopen the second if a pointer target still misses at any window size the reader actually uses.

---

## DEC-084 — The `+` becomes a rimmed disc, and the rim is a gradient because that is what "metal" means

- **Date:** 2026-08-14 · **Topic:** the adopted design's button treatment, unblocked by a screenshot · **Status:** Accepted · **Extends DEC-066, DEC-076, DEC-083; item 6 of [28-interface-plan.md](28-interface-plan.md) §5**

### Context

[DEC-083](04-decision-log.md) deferred this item rather than guessing at it: the adopted design is behind the owner's login, and *metalowe obramowanie* can be built three ways that look nothing like each other. The owner sent the button.

**What the screenshot settles**, and these are read off the image rather than inferred:

- The control is a **disc**, not a glyph in a row. The current `+` is a borderless button whose whole appearance is the character.
- The rim is a **gradient around the ring** — brighter along the top, falling away toward the bottom. That is the whole of why it reads as metal: a specular highlight where light would land, and a flat stroke of the same colour does not read that way at any width.
- The fill is **darker than the rim and close to the surface behind it**, so the disc reads as cut into the chrome rather than sitting on it.
- The glyph is light, thin, and centred.

**What the screenshot does not settle, and this is stated rather than quietly decided.** It arrived as a small paste and never reached this machine as a file, so nothing in it was *measured*: no hex values, no rim width in points, no gradient stops. Every number below is derived from the token ladder this repository already holds, so the button stays inside the design system instead of importing four colours nobody can check. **Two of them are guesses and are named as such in the consequences.**

### Options considered

1. **A flat stroke in `--ds-button-rim`.** This is what the empty state's two buttons already draw, and it is what "add a border" would have produced. Rejected on the evidence: the screenshot's ring is plainly lighter at one edge than the other, and a flat ring is the thing the owner has now asked twice not to get.
2. **An image asset.** Rejected — a bitmap rim cannot follow the appearance, cannot be held to a contrast ratio, and would be the first value in this window that a design could not change from the token table.
3. **A gradient-clipped ring drawn from two tokens.** Chosen.

### Final decision

**Option 3.** `RimButton` draws a disc: the fill, then the rim as an `NSGradient` clipped to the ring between two circles, running from `--ds-rim-highlight` at the top to `--ds-rim-shadow` at the bottom. It subclasses `HandButton`, so it inherits DEC-083's pointing hand and 24 × 24 pt floor rather than restating them.

Four tokens, in both appearances and mirrored in `Theme.swift`: `--ds-rim-highlight`, `--ds-rim-shadow`, `--ds-rim-fill`, and the glyph keeps `--ds-text`.

**The rim is a pair, and the pair is what is checked.** A gradient whose two ends are the same colour is a flat stroke wearing a gradient's clothes, so the two are held **1.30:1 apart in luminance** — the same form of assertion the change tints get, for the same reason: the effect is a *lightness* difference and a check on hue would pass a rim nobody can see. The glyph is added to the contrast list against the fill it is drawn on, which is DEC-076's rule and the reason that list is hand-maintained.

Applied to the `+` alone. The empty state's two buttons keep their flat rim: they are standard `NSButton`s by decision, drawn *around* rather than replacing, and a gradient there would mean drawing them ourselves and losing the key-equivalent ring.

### Consequences

- **Two numbers are guesses**, and the owner should overrule either: the **rim width** (1.5 pt) and the **diameter** (24 pt, DEC-083's floor). Both are legible on this machine and neither was measured from the design.
- The colours are derived, not transcribed: the highlight and shadow are the existing `--ds-button-rim` opened out in both directions along the ladder DEC-080 established. **If the design's values differ, this is a token edit and nothing else** — which is the whole point of them being tokens.
- **This is the fourth question answered out of four asked**, and the first one where the answer arrived as a picture. The other three — the glass, DEC-080's ladder, DEC-081's hues — are still open.

### Revisit trigger

Reopen if the owner reads the disc as *pressed* rather than as *raised*: that is the gradient running the wrong way, and the fix is to swap the two tokens rather than to redraw anything.

---

## DEC-085 — The fourth session: the window becomes adjustable, and the metal becomes real metal

- **Date:** 2026-08-16 · **Topic:** the owner's fourth session, on `25ef945` · **Status:** Accepted · **Amends DEC-072, DEC-083, DEC-084; work list in [28-interface-plan.md](28-interface-plan.md) §6**

### Context

Six reports, and they fall into three groups rather than six problems.

**One is a regression, and it is the worst of the six.** The sidebars cannot be resized by dragging their edge. The collapse button works and un-collapses again, so the pane is not stuck — what is gone is the manual middle ground between 44 pt and 320. DEC-077 recorded this as *fixed* (`splitViewDidResizeSubviews` writes the drawn widths back), and the owner has now reported it twice. **A defect reported twice after being called fixed is a defect that was never measured**: nothing in the suite drags a divider, so every check about panes has been about the two states a button produces.

**Two are the same layout question asked more precisely than last time.** The lens switch — Diff / Blame / History — should sit at the height of the **scope** switch, not in a band of its own, and the diff pane's surface should begin level with `CHANGED FILES` rather than level with the list under it. Last session's fix aligned the three *contents*; the owner wants the diff surface to start one band higher, where the headers are. That is a different line, and re-reading the original report it is the line they meant.

**Three are about the material.** The rim reads as *a gradient* rather than as *light falling on metal* — which is fair: [DEC-084](04-decision-log.md) built a two-stop axial ramp, and a specular highlight is not a ramp. The same treatment is wanted on the search field and on the checkbox, which is still drawing the system's blue. And `Sources ⌄` is not the same control as the other switches, its chevron reads as a plain `>`, and that chevron sits wrong against both its text and its own padding.

### Options considered

1. **Take the six as styling.** Rejected for the reason DEC-083 was: one is a regression with no check behind it, and three change what a material *is* rather than what colour it takes.
2. **Rebuild the switches on `NSPopUpButton`** so `Sources ⌄` and the rest are the same control for free. Rejected: `PillControl` exists because the system control cannot draw an unavailable option with its reason (`12-…` §3), and DEC-077's popover carries that. Converging on the system control would drop the thing the custom one was built for.
3. **Fix the regression with a check under it, move the band, and make the material a material.** Chosen.

### Final decision

**Option 3**, and the parts that are decisions rather than work:

- **A dragged divider is a checked behaviour, not a fixed one.** The arm drags — `setPosition`, then a layout pass — and asserts the pane *keeps* the width across the pass that follows. Nothing in this suite has ever done that, which is why the regression survived a session that fixed it.
- **The lens switch moves into the scope row** (amending DEC-072, which put the scope row above the panes and left the lens in the pane). One row of switches, at one height, across the window: the scope changes what the file list holds, and the lens changes what the diff pane answers, but a reader reads them as one row of controls and the window should agree.
- **The diff surface begins at the pane headers' top**, not at the lists' top. The three panes then share a single horizontal seam.
- **The rim becomes specular.** Two stops make a ramp; light on a curved metal edge is bright along a narrow arc, falls off quickly either side, and lifts again at the opposite edge. That is a multi-stop gradient, and it is the difference between *a gradient* and *a highlight*. It is applied wherever the design uses a rim: the `+`, the search field and the checkbox.
- **The checkbox stops being the system's blue.** It is drawn, and this is a cost accepted with the entry: a drawn checkbox loses the system's own focus ring and pressed state, which is exactly why the empty state's buttons are **not** drawn. The difference is that a checkbox's whole surface is the affordance, while a push button's is its rim.
- **`Sources ⌄` becomes the same control as the other switches**, and the chevron becomes a drawn glyph rather than a typed character — sized, weighted and **centred against its own box** rather than against a font's idea of where a `⌄` sits.

### Consequences

- **A drag arm is a new class of check for this window**: every pane assertion until now has been about a state a *command* produces. Two of the three defects this session are in the space between those states.
- **The chrome grows a drawn control** (the checkbox) for the first time since `PillControl`, and the contract's table grows with it.
- The specular rim is a **shape of light**, so it is checked as one: the ramp must have more than two stops and the highlight must be off-centre, or it is the thing this entry replaced.

### Revisit trigger

Reopen the material if the owner reads the specular arc as *dirt* rather than as *light* — that is a highlight too narrow or too bright for the surface it sits on, and the fix is the stop positions rather than the colours.

---

## DEC-086 — The window sits on the desktop, stops explaining itself, and stops ticking

- **Date:** 2026-08-16 · **Topic:** the owner's fourth session, second half · **Status:** Accepted · **Amends DEC-012, DEC-075, DEC-077, DEC-083; work list in [28-interface-plan.md](28-interface-plan.md) §7**

### Context

Five more reports, and one of them makes a check of this project's own refuse the work.

**The uncommitted-count convention is on screen.** *`counts: git status --porcelain — an untracked directory counts once`* sits under the repository list. It is DEC-012's disclosure — the number beside a repository is a count of *entries*, not of files, and an untracked directory is one entry however much is inside it. It is also, exactly, the thing DEC-077 was written about: an explanation of how the tool arrived at a number, drawn permanently, for a reader who wants to know what changed.

**The horizontal track is still there and still does nothing.** DEC-077 made `#track` absent when there is nothing to scroll, and the owner reports a strip they can grab that moves nothing. Two candidates and they need telling apart: `#track` shown when it should not be, or CodeMirror's own scroller showing a bar under the code. The second is not ours and has to be styled away rather than hidden.

**The title bar does not line up with the window's own buttons**, and the band behind it should be **transparent with a blur** so the desktop shows through.

That last one is refused by a check written three days ago. DEC-083 forbids `NSVisualEffectView` anywhere in the chrome, under the heading *nothing imitates the material where the system has none*. **The rule was right and its wording was too wide.** What that entry banned was a *drawn approximation of glass* on systems that do not have `NSGlassEffectView`. A window whose title band is the system's own vibrancy is not an imitation of anything — it is the platform's API for exactly this, and it has been since long before glass existed.

**The status line ticks once a second.** *refreshed 4s ago* becomes *5s ago* becomes *6s*, in the corner of the eye, forever. The owner wants to keep the fact and lose the flicker.

### Options considered

For the ticking, three: **static** (write it once and let it go stale — rejected, a stale *2s ago* is a false sentence and DEC-075's whole point is that a window which has stopped following the disk says so); **coarser wording** (*just now / under a minute / 3 minutes* — the number changes rarely and means the same thing); **a longer interval** (still per-second wording, redrawn every 15 s — the same flicker, less often, and the sentence is wrong for up to fifteen seconds).

Chosen: **coarser wording**. It is the only one of the three where the sentence is never false and the pixels rarely change.

### Final decision

- **The convention caption goes.** DEC-012's disclosure moves to the tooltip on the count it describes, which is where a reader asks the question — and the count itself is unchanged, which is what that decision was actually about.
- **`#track` is removed outright**, not conditionally. DEC-077 kept it for the case where there *is* something to scroll; the owner reports it dead in that case too, and two linked panes that scroll with the wheel and the keyboard do not need a second control that only a pointer can use. CodeMirror's own horizontal bar is styled away with it, so one gesture does not leave two strips.
- **The title bar's content lines up with the traffic lights** — `trafficLightInset` is applied as a *leading* inset on the row rather than to the stack inside it, which is what left the label a few points out.
- **The title band is the system's material.** `NSVisualEffectView`, `.headerView`, behind a transparent titlebar. **DEC-083's ban is narrowed rather than dropped**: it forbids vibrancy *standing in for glass on a control*, which is what it was written about; a window band is not a control and the system's blur is not an imitation of the system's blur. The check is re-expressed to name the surface rather than the class.
- **The watcher's age is worded in steps** — *just now*, *under a minute*, *N minutes*, *N hours* — so the label is rewritten when the meaning changes rather than when the clock does.

### Consequences

- **A check of ours was in the way and it was our wording, not the request.** Re-expressed rather than deleted: the ban on imitation still holds where DEC-083 aimed it, and now names *where* instead of *what*.
- **The status line stops changing every second**, which also removes the one thing in this window that laid out on a timer — the reason M9-K's centring defect was ever observable.
- Losing `#track` loses the only pointer-reachable horizontal control; the panes still scroll with the wheel, and `12-…` §5.4's requirement was that the two panes share a position, not that a slider exist.

### Revisit trigger

Reopen the caption if a reader is ever surprised by the uncommitted count — that number is a count of entries and the disclosure exists because the surprise is real; it has moved, not gone.
## DEC-087 — The canonical diff shifts its match boundaries onto line boundaries, and the validator shifts with it

- **Date:** 2026-08-16 · **Topic:** Reopens the question DEC-047 left open, on the evidence of `22-experiment-log.md` → M11-A · **Status:** Accepted · **Amends DEC-039**
- **Prompted by:** the owner's fourth diff session — an untouched `import` line drawn as removed-and-re-added, and an inserted interface member putting its highlight on the *next* line's indentation

### Context

DEC-047 closed with a sentence that has now come due: *"the equally-minimal-alternative question stays open."* M11-A is what came of leaving it open. Against eleven real files:

- **35 of 159 lines** the model reports as changed on the new side are untouched by the change.
- **9 of 11 files** contain at least one insertion that makes its *neighbour* read as edited.
- **36 segments** end inside the following line's leading whitespace, which reads as *this line was re-indented* — a claim the tool never made.

The mechanism is one line of `CanonicalDiff.swift`: the common-prefix scan (`:107-115`) runs over **bytes**, so an insertion before `import ButtonLink …` anchors after the shared word `import `, and an insertion before `  text: string;` anchors after the shared indent. Myers does not select a unique alignment; where several are equally short it picks arbitrarily, and the arbitrary one is usually the one that starts mid-line.

`coalesceAdjacent` (M11-A) took the corpus from 443 marks to 175 and could not touch any of this: how many segments carry a boundary is a different question from where the boundary is.

### Why this is not the sliding DEC-047 refused

DEC-047's objection was precise and it was about **one thing moving while the other stood still**:

> Sliding moves bytes **out** of the presented set. INV-2 as recorded requires every byte of *the canonical diff's* hunks to lie within a presented range, and the validator recomputes those hunks with the same deterministic implementation. A slid presentation therefore fails validation by construction.

That is an argument against sliding the **presentation** away from a fixed `D`. It is not an argument about which `D` is the canonical one. Here `D` itself moves: the shift happens inside `canonicalMatches`, which is the single function both the model and `Validation` call, so the presentation and the check move together and containment holds byte for byte.

INV-2 names four properties of `D` — *minimal*, *deterministic*, *over bytes*, *no structural input*. A shift keeps all four:

- **Minimal.** A shift moves the boundary between a hunk and its neighbouring match by the same amount at both ends, so the total matched length is unchanged. The suite already asserts this directly — *"matched length equals LCS on 600 random pairs"* (`diffscope-verify/main.swift:155-158`) — and that check is the reason this option is safe to take rather than a check to weaken.
- **Deterministic.** One shift is chosen by a total order over candidates, below.
- **Over bytes**, and **no structural input** — which is why **the boundary set is `0x0A` and nothing else.** Snapping to lexer tokens or tree-sitter nodes would fix more and would make `D` depend on a parse that can fail, at which point the independent check is no longer independent of the thing it checks. That door stays shut.

### Options considered

1. **Nothing.** Rejected on the numbers above: 22% of the reported changed lines are wrong, and a reviewer who finds one wrong line stops trusting the other five.
2. **Line-granular canonical `D`.** Rejected, and with a counterexample rather than a preference: for `O = "a\nb\n"`, `N = "b\na\n"` a line-level LCS marks `old[2..4)`/`new[0..2)` while the byte diff marks `old[0..2)`/`new[2..4)` — **disjoint**. Line hunks do not contain byte hunks, so this re-bases INV-2 and reopens DEC-021.
3. **Present `lineExpand(D)`** — widen every hunk to whole lines. Free and monotone, but it does not fix the report: the untouched `import ButtonLink` line is still inside a hunk, and now inside a wider one.
4. **Shift the match boundaries onto line boundaries inside `canonicalMatches`.** Chosen.

### Decision

**Option 4.** For each hunk, compute the range of shifts over which the alignment stays valid — the standard condition, and the same one git uses — then choose among the reachable positions by this total order:

1. positions where the hunk **begins at a line start and ends at a line start** (a whole number of lines);
2. among those, **the largest shift** — the position furthest down the file;
3. if there is no such position, **shift 0**: the alignment is left exactly where Myers put it.

Rule 2 is not a taste. For the owner's import case both `import styles …;\n\n` and `\nimport styles …;\n` are whole-line candidates, and only the later one renders as *two lines added after the blank line* rather than as *a blank line added, then an import*. It is also what git prints for the same file, which is worth matching where nothing argues against it.

Rule 3 is what keeps this honest on the cases it cannot help: a replacement whose two sides cannot shift together stays where it was, and no boundary is invented.

**And, in the same entry because it is the same fact: the boundary snap stops widening a boundary that is already on a line boundary.** This was not foreseen when the shift was written; it was measured afterwards, and the measurement is the argument. DEC-047's snap exists to rescue a change that *begins mid-structure*. Once the alignment lands on whole lines there is nothing to rescue, and the 16-byte budget is spent spilling into the neighbouring line instead — which is precisely how an inserted interface member came to put its highlight on the *next* line's indentation. With the shift in place and this guard absent, the corpus reports **42** wrong lines against a baseline of 35: the shift alone is a regression. With it, **24**. A mid-structure boundary is still widened exactly as before.

### Consequences

- **DEC-039's independence is weakened in a way that must be said plainly.** `canonicalMatches` is already the single implementation behind both the model and its check — that predates this entry — and shifting inside it means a defect in the shift is a defect in both. The honest reading is that INV-2's runtime check has been a regression guard rather than an independent test for some time; this entry does not create that and does not fix it. It is written down as the next thing to repair.
- **Move detection changes, and a latent defect in it came out.** `findMoves` extended a move while consecutive entries of its *changed-lines array* matched — and those entries are adjacent whenever the lines between them are unchanged. With the new alignment, `moved-two-blocks` produced **one** record spanning two blocks that land in different places, so `link` counted instead of pairing and T-11's third assertion failed. Extension now requires the two lines to be neighbours in the file with nothing but whitespace between them; a blank line inside a moved block is still one move.
- **The 16-byte snap budget (DEC-047, M6-B) keeps its value and loses its reach.** Rather than re-deriving a number, the pass is given the one condition it was always missing: it does not widen what is already whole-line.
- Presented bytes go **down**, not up, for the first time in this series — the opposite direction from the snap. That is safe only because `D` moved first, and it is the whole reason the order of the two passes matters.

### Revisit trigger

Reopen if a corpus measurement shows the whole-line preference losing to the alternative on files with no blank lines between blocks — minified or generated sources, where "the furthest position down the file" may run a hunk past the construct it belongs to.

> **Numbering.** This entry was written as DEC-086 on a branch while DEC-086 was being
> written on `main`. Both are wanted and both are kept; the branch's became **DEC-087** at
> the merge. Two entries sharing a number is the one thing this log cannot carry.

---

## DEC-088 — The fifth session: the chrome becomes one surface, and four bands stop reporting nothing

- **Date:** 2026-08-16 · **Topic:** The owner's fifth reading session · **Status:** Accepted · **Reverses DEC-080, amends DEC-083 and the design contract**
- **Prompted by:** six items in one message, with a screenshot of the top of the diff pane

### Context

Six reports, and five of them are the same complaint from different angles: **the window spends height and ink saying things the reader did not ask about.** The sixth is a defect nobody could have seen in a screenshot.

### The six

1. **The magnifier sat on top of the search text**, and the fix is not where it looked. A resting `NSSearchField` has always drawn its glyph at x=2 and its text at x=26 — every picture of the field, and every reading of `searchTextRect(forBounds:)`, said it was correct. `select(withFrame:)` and `edit(withFrame:)` hand the field editor the cell's **whole frame** when the field is unbezeled, which this one is because DEC-085 put the design's rim around it instead of the system's bezel. So the moment the reader clicked in and typed, the string was laid out from x=0, on the glyph. **The defect is in the editing path and the drawing path was never wrong**, which is why the arm that proves it focuses the field and measures the *field editor* — the cell's own rectangles pass identically before and after.

   The obvious repair is also wrong and was photographed being wrong: overriding `searchTextRect(forBounds:)` moves the rectangle the cell asks for without moving the one it draws, and the field then renders its string **twice**, a few points apart. What moves is the whole interior (`drawInterior`), so the glyph and the text keep their spacing, and the editor is put on the cell's own text rectangle shifted to match.

   The vertical half — *4px paddingu wertykalnego* — belongs **around** the field, not inside it. The first version took `searchTextPadding` off the top and bottom of the editor, and on a field whose `intrinsicContentSize` is 14 points that left seven points for an eleven-point line. `RimHost` insets the field by the padding instead, so the control is taller and the line keeps every point it has.

2. **The repository list, the changed-file list and the scope row are one surface**, which reverses DEC-080 eleven days after it. DEC-080 answered *I cannot see where one region ends and the next begins* by pulling four neutrals nineteen values apart into a ladder with a 1.10:1 floor. The owner's answer to the same complaint is the other one: make them the same surface and let the seams separate them. The check inverts with it — three values held **equal**, and one step, the code against the chrome around it. *Nearly the same* is what is rejected now, for DEC-080's own reason: three neutrals a hundredth apart read as a mistake.

3. **`#showing` is removed** — `SHOWING HEAD ↔ working tree · unified`, a band on every file. DEC-083 kept it because DEC-058 had been paid three times for stating a fact only in the chrome, far from the pane being read. It is stated in the chrome **twice** — the status line and the title band — and the layout word names the thing the reader has just pressed ⌘E for. The sentence is still composed in the Git layer and still checked; what goes is the third copy. **The empty notice bar goes with it**: `#notices` kept its padding and its seam while holding nothing, which on a normal file is every file the reader opens, so it collapses when empty exactly as the row above it did.

4. **`untracked` stops wearing `?`.** It was `?` because that is what `git status --porcelain` calls it, and beside a filename a question mark reads as a **missing icon** — the owner reported it as one twice. To the reader of a diff an untracked file and an added file are the same fact, so untracked now says `+` in the added hue. The kind survives everywhere it matters (the tooltip, the grouping, the engine); the one place it is *drawn* it says what it means. DEC-081's uniqueness check is restated rather than loosened: the kinds meant to be tellable apart each keep a glyph of their own, this one pair is named, and a second kind joining them is a separate control.

5. **The lists' scrollbar is narrower, and drawn only while the reader scrolls.** The second half is not a size but a style: an overlay scroller fades in on a scroll, a legacy one is painted for as long as the list is longer than the pane, and which one you get is a **system preference** — `NSScrollView.scrollerStyle` is overwritten from `NSScroller.preferredScrollerStyle` whenever it changes. So the scroll view answers `.overlay` for itself, in the setter as well as the getter, and the scroller draws its own knob with **no slot behind it**. A track is the part that is visible when nothing is happening, so *quietened, never removed* has nothing to quieten here; this is the same exception `#track` earned in DEC-077.

6. **The three pane headers are one height.** Two of them are `ChromeBar`s of `Theme.paneHeaderHeight`; the third is a `<div>` in a webview and was `space3 + text + space3` = 27, so the seam under `src/components/…` sat five points above the seam under `CHANGED FILES`. One line across the window, laid out twice. `--ds-pane-header-height` is the number, and the check does the arithmetic on both sides rather than matching a name — a token whose two sides hold different values is precisely the drift this catches, and the literal 27 is its control.

### Amendment, same day — the status line keeps a surface of its own

Item 2 collapsed `--ds-chrome` into the panels' value, and `--ds-chrome` was also the status line's. The owner read the result and asked for that one band back: *"status bar zostaw ciemniejszy niż panele."*

It is the right exception and it is worth stating why. Every other band in the window **holds** part of what is being read — the scope row holds the control that changes the file list, the pane headers hold the lists' own captions. The status line **reports on** the window: what the watcher is doing, how old the reading is, which file of how many. A band that is about the window rather than part of it is the one band that may sit apart from it.

`--ds-status-bar` is `#d9d9e1` light and `#08080a` dark. **The check is an ordering, not a ratio**, and that is a measurement rather than a preference: below `--ds-panel-*` in dark there is almost nothing left before the code's black, so the honest assertion is *which way* — darker than the panels, in both appearances — with the ratio printed rather than asserted. Measured, it is **1.26:1 in light and 1.08:1 in dark**. The hairline at the bar's top edge is what separates it; the surface reinforces the seam rather than replacing it.

The three ink pairs the status line draws are added to the contrast list, which is the list's own rule: adding a label means adding its pair.

### Consequences

- DEC-080's ladder check becomes an equality check; its measurement of the *original* four values is kept as a control, because that failure is still what the section exists over.
- The live style audit puts a chip into `#notices` before it measures it. It had been reading an empty bar and calling `:empty` a hidden notice bar — and asking the question with a notice present is the stronger form of INV-4 anyway.
- `Theme.chrome`, `Theme.panelRepositories` and `Theme.panelFiles` are one value under three names. The names stay: the token table is the design's, and a design may pull them apart again.

### Reopen if

The owner reports the window reading flat — four regions and no seams is the failure DEC-080 was written against, and this entry is a bet that a hairline is enough separation where nineteen values were not.

---

## DEC-089 — The terminal becomes one input surface: the prompt is withheld from the grid and drawn beside the caret

- **Date:** 2026-08-16 · **Topic:** T2's arrangement, reopened through DEC-055's own revisit trigger · **Status:** Accepted · **Amends DEC-055, removes `--ds-term-input-surface`**
- **Prompted by:** the owner opening the terminal — *"czemu mam dwa miejsca na wpisanie komendy"*

### Context

DEC-054 made the grid **output only** and DEC-055 put the line in a real `<textarea>`, because a shell's line editor cannot be driven with ⌥←/→ and ⌘←/→ and that is the whole of OQ-055. Both decisions are right and together they produce the thing the owner reported: at a prompt zsh prints its prompt **into the grid** and the reader types into a field **under it**. Two surfaces, two cursors — xterm draws its inactive cursor where the prompt is, the field draws a caret below — and one act.

DEC-055's revisit trigger names this exit exactly: *"or if Warp-style blocks are taken up, which would change what the input line is attached to."*

### Decision

**The prompt's last line is withheld from the grid and drawn in the input row, beside the caret.** The row loses its border and its own surface and becomes the grid's last line; xterm's inactive cursor is switched off, so there is one caret on screen.

### The invariant this rests on, and why the alternatives do not

> **Nothing is removed from the grid's byte stream. A span of it is held back and released in order.**

The withheld bytes go to xterm **before anything else is ever written to it** and **before anything is sent to the PTY**. `appendLocked` and `send` are the only two doors, and both release first — one place each, because the alternatives are four (submit, hand-over, raw passthrough, `follow`'s `cd`) and a fifth would be added one day by somebody who had not read this.

That is not fastidiousness. ZLE's redraw arithmetic is **relative to where it believes the cursor is**. A design that *drops* the prompt, or re-renders it into the grid itself, leaves xterm's model of the screen and zsh's model of the screen disagreeing by exactly one prompt width, and every subsequent redraw lands in the wrong column. Delaying the bytes cannot do that; dropping or reordering them must.

### What may be drawn inline, and what is refused

Allowed: plain text, `SGR`, and zero-width `OSC`. The last of those is not a nicety — **the integration emits `OSC 7` inside the prompt span**, so a rule of "SGR only" would have refused every prompt this product installs. That case is a negative control.

Refused: any other `CSI`, and a bare `\r`. A prompt that positions the cursor or overprints is not a run of spans, and drawing it as one would move text the shell put somewhere specific. **A refusal releases the whole capture and reports no inline prompt** — the row falls back to what it was before this entry, which is a state a check can name and a snapshot can show.

A **two-line prompt keeps only its last line** inline; the head goes to the grid where every other line of output lives. That is what makes `p10k` and `starship` work at all, and it costs one `lastIndex(of:)`.

### Consequences

- `TerminalScanner` reports the **byte range** of each mark (`onEventRange`). `TerminalEvent` is not widened: it is `Equatable` and the suite compares it by value in dozens of places.
- **A start mark with no end mark cannot swallow the grid.** Found by this suite's own `printf ';A'; cat` fixture, and it is not a test artefact — the integration appends `;B` to `PROMPT`, so any shell whose `PROMPT` is replaced after the rc file runs emits one mark and never the other. A capture that outlives two flushes is given up and released in order.
- **An empty slice is not a write.** The first version released the prompt the instant it withheld it, because the split calls `appendLocked` with whatever follows the last mark and after `OSC 133;B` at the end of a read that is nothing at all. The arm caught it: the prompt was in the row *and* in the grid.
- The SGR parse lives in **Swift**, so the rules are checked headlessly rather than looked at. The sixteen ANSI colours cross as `--ds-term-*` **names**, so the inline prompt and the grid cannot end up with two reds; 256-colour and truecolor cross as literals, because those are the shell's output rather than the design's palette.
- `--ds-term-input-surface` is removed. It existed to make the boundary between what the reader was typing and what the shell had said visible — and that boundary is precisely what was reported.

### Reopen if

A prompt in daily use is refused often enough to notice — the tell is the row falling back to a bare field with the prompt above it — in which case the refusal rule is what needs work, not the withholding.

---

## DEC-090 — The terminal drawer gets a control of its own, and the window server has to be told before a picture is taken

- **Date:** 2026-08-16 · **Topic:** DEC-071's rule applied to the one pane that had no pointer route · **Status:** Accepted
- **Prompted by:** the owner, with a picture of a `>_` — *"chcę żeby dało się otworzyć terminal tą ikonką a nie tylko skrótem"*

### Context

Every other region of the window can be reached with a pointer: the two lists have collapse chevrons, the diff has the lens, the scope row has its pills. **The terminal drawer had ⌃` and nothing else** — so it existed only for a reader who already knew the keystroke, and DEC-016 calls a function reachable only one way a defect in whichever direction it points.

### Decision

`TerminalButton` in the **status line**, drawing `>_`.

- **In the status line because that is the edge the drawer comes out of.** A control belongs beside the thing it moves — the same reasoning that put the scope row above the lists rather than inside a pane on the far side of them.
- **A route, not a capability** (DEC-071). Its action is the selector the keyboard map resolves for `terminal`, and its words are `KeyboardMap`'s — a button and a menu item that describe one command two ways is drift this project has now paid for three times.
- **The mark is drawn, not typed.** DEC-085 item 6 recorded what happens to a glyph typed into a title: `⌄` is a *modifier letter*, it carries its own side bearings and baseline, so it read as a `>` and sat wherever the font put it. `Theme.drawPrompt` is the same two-stroke construction `drawChevron` uses, turned a quarter turn, with the prompt's rule beside it.
- **The state is a shape as well as an ink.** Open, it wears the raised surface the chosen pill wears; closed, it is the bare mark. A toggle that changes only its colour is one a reader has to remember rather than read.

### And the thing that was actually found

**`keyboard.png` showed the button raised with the drawer shut.** The state was right — the arm that asked said `closed=true` — the invalidation was right, and the pixel was several turns old. `CGWindowListCreateImage` asks the **window server** what it has, and what it has is whatever was last committed to it; nothing in this project had ever forced that commit before photographing.

`windowSnapshot` now draws, displays and calls `CATransaction.flush()` before it captures. This is the AppKit twin of `window.diffscopeSettle()` and it is the **fourth** instance of the same class of defect here: a picture of a pass that has not run is a picture of something that was never on screen.

**Two speculative fixes were written first and both were measured and removed** — a `wantsUpdateLayer` override on the button, and a `displayIfNeeded()` in `setTerminalVisible`'s hidden branch. Each was plausible, each was tested by taking it away again, and neither changed a pixel. *Measure the control before believing the check*, applied to a repair rather than to a check.

The arm now renders the button in **both** states and requires the two pictures to differ. A stale pixel cannot pass that, and no assertion about state ever could.

### Consequences

- `Theme.space1` joins the mirrored spacing scale; `Theme.drawPrompt` and `Theme.promptRuleWidth` are the mark.
- Every snapshot in the suite is now taken after a commit, so the whole gallery is a turn newer than it was.

---

## DEC-091 — Every icon in the chrome is a path, and a chevron is taller than it is wide

- **Date:** 2026-08-16 · **Topic:** the marks on the chrome's controls · **Status:** Accepted · **Extends DEC-085 item 6 to the rest of them**
- **Prompted by:** the owner on DEC-090's button — *"nie używaj `>` w tej ikonce, użyj poprawnego chevron bo to jest za szerokie… widać że nie jest profesjonalna ikonka"*

### Context

DEC-085 item 6 already recorded the mechanism, on one control: `Sources ⌄` typed the chevron into its own title, and `⌄` is a **modifier letter** — it carries its own side bearings and its own baseline, so it read as a `>` and sat wherever the font put it. That entry drew *that* chevron and stopped there.

Three character marks were left, and each is the same defect:

- **`«` and `»` on the collapse buttons.** These are **guillemets** — quotation marks in French and Polish typography — used as arrows, set in the text face at the text weight with the spacing a quotation mark needs. They never matched the chevron on the switches beside them because they are not one.
- **`+` inside the rimmed disc.** Set in the *proportional* face at 12 pt semibold, so it wore that font's stroke weight and optical centre inside a disc this project draws itself.
- **`>_` on DEC-090's own button**, which was drawn — and drawn wrong. It used `chevronArmWidth` for the span *and* the drop, so the mark was **7 × 7**: a square, which is the shape of the `>` character and not the shape of a chevron.

### Decision

**A control's picture is a path; its title is only its name.** `MarkButton` draws a closure over its bounds and `RimButton` draws one over its disc. Titles stay — VoiceOver reads them, the arms name controls by them, and the collapse mark reads its own title back to decide which way to point.

**A chevron's arms are about twice as long as they are far apart**: `promptChevronWidth` 4, `promptChevronHeight` 8. That ratio is the whole difference between a chevron and a `>`, and it is checked, with the square one as the control — a check on *either* number alone would have passed the shape being replaced.

One construction, `drawChevronArm`, so the single chevron on `>_` and the pair on the collapse buttons cannot drift apart the way a string in one place and a path in another always do.

### What stays a character, and why

Not everything shaped like a glyph is an icon.

- **The file-kind marks `+ − → ✎ ⇄ !` and the unified sign column.** DEC-035 requires a *character* that carries the kind with every colour removed, and these are **content** in a list of paths, set in the same monospaced face the paths are. Drawing them would make them chrome.
- **`▍` in the collapsed spine** — a bar chart, a data mark, in the same cell as the kind it belongs to.
- **`···` in a truncated group header** — an ellipsis. Typography, not an icon.
- **`●` / `○` in the watcher sentence.** A bullet **inside a sentence** composed in `ChromeLabels` — `● Watching · refreshed just now` reads as prose with a leading marker, and filled-against-hollow is the shape carrier DEC-035 asks of it. Reopen if the owner reads it as an indicator rather than as punctuation.

### Consequences

- `Theme.drawChevronArm`, `drawDoubleChevron` and `drawPlus` join `drawChevron` and `drawPrompt`; `promptChevronWidth`, `promptChevronHeight`, `doubleChevronScale` and `plusArmLength` are the proportions.
- `RimButton` no longer draws a title at all, so the font and tint it was given are gone with it.

---

## DEC-092 — Version two: the application writes

- **Date:** 2026-08-16
- **Topic:** Whether DiffScope acquires Git write operations as product features. **Reopens [DEC-003](#dec-003--write-operations-in-version-one) explicitly, per the rule in `21-agent-handoff.md` §6, and resolves OQ-056.** Amends DEC-011 and fires DEC-061's revisit trigger.
- **Status:** Accepted — direction and shape. Each milestone still gets its own entry before its code.

### Context

The product owner compared the application against lazygit's feature list and asked for **all of it**, plus staging, unstaging and committing as a GUI — "proste zarządzanie co stageować co usunąć ze stage jaki commit czy wiadomość czy pusty" — with **GitHub Desktop named as the visual reference**.

DEC-003 made version one strictly read-only and said why: a defect could not damage a repository while the diff engine was unproven. It also wrote the sequencing for exactly this moment — *"Staging is positioned as a natural version-two capability. It requires a correct and trusted hunk model, which is precisely what version one establishes."* That model exists now: the byte partition, INV-1 reconstruction, INV-2 containment, the independent canonical diff, and 1832 checks over them.

The full study — GitHub Desktop's anatomy, what it hides and what that costs, the operation inventory with plumbing and risk classes, the interface mapping, the proof machinery and the milestone order — is [29-git-operations-plan.md](29-git-operations-plan.md). This entry records only what was decided.

### Options considered

1. **Leave it.** The terminal drawer already runs `git commit`; the sideways grant is real (DEC-053).
2. **Staging and commit only.** The GitHub Desktop half, no history rewriting, no network.
3. **The union of both products.** GitHub Desktop's staging surface and lazygit's power, sequenced.

### Product owner's input

Option 3, and four sub-decisions answered the same day:

- **Staging model: the hybrid.** A checkbox per file that means *include in this commit*, implemented as a **real index write**, with the four scope pills (DEC-008) staying on screen so the index is visible rather than hidden. GitHub Desktop hides the index; anything else on the machine can write to it, and a hidden index then misreports a state it did not author.
- **Network last.** Fetch, pull and push are in scope, at M16, never automatic.
- **Conflicts are handed to the editor**, as GitHub Desktop does: list them, take ours/theirs, abort, block the merge — do not build a three-way merge surface yet.
- **No read-only mode.** A per-repository *review only* lock was offered and declined; the application writes where the user tells it to, and there is one fewer concept in the interface.

### Final decision

**Version two writes.** DEC-003 governs version one and stays as written; from M11 the application performs Git operations that modify repository state, on explicit user action, and never on any automatic path.

**R-8 splits rather than weakens.** `allProvenReadOnly` keeps its proof unchanged and keeps `--no-optional-locks`. A second registry holds every write, each declaring a risk class, through a separate runner that can never open an editor and can never block on a prompt. A Git invocation from neither registry still fails the suite.

**R-8b is the new proof, and it is the one this product can make that no other client can: it wrote exactly what it showed.** A staging operation builds its patch from the partition, and the check asserts the index moved by **exactly the selected byte ranges and nothing else**. Stated over bytes as **INV-6**.

### Consequences

- **DEC-011 is amended at M16**, not before: never *automatically* fetches survives; user-initiated fetch, pull and push become available. Force push is `--force-with-lease` behind a typed branch name.
- **DEC-061's revisit trigger fires at M14.** A graph and a filter in History make it the second interface DEC-008 refused; it needs its own entry, not a commit.
- **⌘⏎ is claimed twice.** DEC-065 gives it to *open in editor*; the commit box takes it while it has focus, which is GitHub Desktop's own rule.
- **Index-lock contention with WebStorm stops being avoidable** and becomes a reported state rather than an error string. The pinned pair (DEC-049) is now mutated from inside as well as outside.
- **The true sentence about writing changes again.** The retired-phrase check in `DesignChecks` — written when DEC-053 falsified eleven documents — must hold the new one: *it writes only what you asked for, and it shows you the command it ran*, with a command record in the interface backing the second half.
- **Every class-B and class-C operation records a restore point before it runs.** That is lazygit's ⌃Z with a mechanism under it; `reflog` is the backstop and is surfaced as the safety net.
- Discarded untracked files go to the **Trash**, never `rm`.

### Revisit trigger

Reopen if M11 or M12 cannot make R-8b hold on the fixture corpus — a staging surface that cannot prove which bytes it wrote is worse than no staging surface, and the terminal drawer remains the honest fallback.

---

## DEC-093 — The canonical shift ranks lexical boundaries below line boundaries

- **Date:** 2026-08-17 · **Topic:** Where a hunk begins and ends *below* the line · **Status:** Accepted · **Amends DEC-087**
- **Prompted by:** the owner's fifth diff session — `'base' | 'wide'` becoming `'base' | 'compact' | 'wide'`, drawn as `'base' | '⟦compact' | ⟧⟦~'⟧wide'`, with the apostrophe of `'wide'` — a byte nobody touched — carrying a mark of its own

### Context

DEC-087 moved `D`'s match boundaries onto line boundaries and fixed the case where an untouched line
read as removed-and-re-added. It fixed nothing below the line, and said so: **the boundary set is
`0x0A` and nothing else.**

The owner's fifth session is the case that lives there. Inserting a union member anchors after the
shared `'`, so the mark reads `compact' | ` and stops one byte short of where a reader would put it.
The stray apostrophe is the visible half; the other half is that `reconcile` then finds the byte mask
overlapping a tree anchor it had right, and emits a second segment at `confidence 0.6`, which
`coalesceAdjacent` refuses to merge because the floor is between them. One misplaced boundary, three
marks where one was wanted.

### Why this is inside DEC-087's argument rather than against it

DEC-087 shut the door on **"lexer tokens or tree-sitter nodes"**, and it named the reason: they would
make `D` depend on a parse that can fail, at which point the independent check is no longer
independent of the thing it checks.

A **byte-class transition is a pure function of the bytes.** There is no parser, so there is nothing
to fail. The four properties INV-2 names all hold:

- **Minimal.** A shift moves both ends of a hunk by the same amount, so the total matched length is
  invariant — DEC-087's argument unchanged, now asserted directly against the unshifted alignment as
  well as transitively through the 600-pair LCS check.
- **Deterministic.** One shift is chosen by a total order.
- **Over bytes**, and **no structural input.** The door DEC-087 shut stays shut.

DEC-039's weakened independence is unchanged by this entry and is restated rather than dropped: a
defect in the shift is a defect in both the model and its check, because `canonicalMatches` is the
single implementation behind both. That was true before this entry and is still the next thing to
repair.

### Decision

The total order gains two ranks between DEC-087's whole-line rank and its shift-0 floor. Classes are
**word** (`A-Z a-z 0-9 _ $` and every byte ≥ `0x80`), **whitespace**, and **other**:

1. both sides begin and end at a **line** start;
2. both boundaries sit on a **class transition with whitespace on one side of it**;
3. both boundaries sit on a **class transition**;
4. shift 0 — the alignment stays exactly where Myers put it.

Within a rank, the largest shift wins: the position furthest down the file, DEC-087's rule 2 unchanged.

**Rank 2 exists because rank 3 does not separate the case that prompted this.** Both `…| '⟦compact' |
⟧'wide'` and `…| ⟦'compact' | ⟧'wide'` are class transitions at both ends; only whitespace adjacency
prefers the second, which is the one a reader would write.

**Bytes ≥ `0x80` are word bytes** so that a class transition can never fall inside a UTF-8 sequence.
It also puts `\r` and `\n` in one class, so no boundary can be invented between them.

**And, in the same entry because it is the same fact: shift 0 is now scored as a candidate.** DEC-087
could leave it out — it accepted only whole-line positions, so moving from one to another cost
nothing. With a second rank in the order that is no longer true, and leaving it out is a regression
rather than an omission: measured, an insertion Myers had already placed on a line boundary was
pulled one byte up onto a rank-2 position, and the corpus reported **two** wrong lines where it had
reported one. Scoring shift 0 is what makes rank 1 able to win at the place Myers already chose.

### Consequences

- **The change is confined to hunks where DEC-087 chose shift 0**, because rank 1 is still searched
  first and still wins wherever it is reachable. M11-B's 24 wrong lines is therefore a ceiling, not a
  hope, and M11-C measures 23.
- **The line-counting metric understates this.** A boundary that moves within a line changes no line's
  status, so `false` falls by one while the two union cases go from three marks to one each. Segments
  over the corpus: 185 → 182. The metric M11-B introduced cannot see most of what this entry does,
  which is worth saying rather than dressing up.
- **`canonicalMatches` and `canonicalDiff` gain `applyShift`,** defaulting to on. Production never
  passes `false`; the suite does, because a check asserting where a hunk lands cannot otherwise tell a
  shift that fired from one that was never needed. Same precedent as `boundarySnapBudget: 0`.
- **It does not touch the confetti.** Single-byte matches held inside a large insertion are *matched*
  bytes; dropping them would lower the matched length below the LCS and the 600-pair check would fail
  on the first run. That is a presentation problem by necessity and not by preference, and it is
  DEC-094's.

### Options considered

1. **Nothing.** Rejected: the stray apostrophe is in every union edit, and union edits are common in
   the corpus that prompted this.
2. **Tree-sitter or lexer boundaries.** Rejected for DEC-087's reason, unchanged.
3. **Relax "no neighbouring match may be consumed".** Legal — a shift that consumes a match preserves
   the total matched length; it merges two hunks — and it would reach the cases M11-B named, where a
   one-line match between two insertions bounds the search to nothing. Deferred rather than dismissed:
   it moves `changeStops`, and navigation, folds, formatting collapses and the unified blocks all key
   off stops. Its own entry, with its own measurement.
4. **Rank lexical boundaries, scoring shift 0.** Chosen.

### Revisit trigger

Reopen if a corpus measurement shows "furthest down" losing for rank 2 specifically. That tie-break
was derived for whole lines in DEC-087 and inherited here rather than re-measured.

---

## DEC-094 — Short unchanged islands inside a change are absorbed into it

- **Date:** 2026-08-17 · **Topic:** Confetti — the unchanged single bytes byte-minimality leaves inside an insertion · **Status:** Accepted
- **Prompted by:** the owner's fifth diff session — a nine-line JSX block inserted whole, drawn with six unchanged islands punched through it: the `r` of `number`, the `im` of `img`, a lone space

### Context

Myers minimises the edit script over bytes, and byte-minimality reuses whatever it finds. Inside a
block that did not exist before, it will hold single characters as *matched* because matching them
is shorter. With the boundary snap turned off, the corpus shows it plainly:

```
*   41 |     typeof img?.width⟧ ⟦changed|===⟧ ⟦changed|'numbe⟧r⟦changed|' &&
*   42 |     typeof img.h⟧e⟦changed|igh⟧t⟦changed| === 'n⟧u⟦changed|mbe⟧r⟦changed|' &&
```

The reader is shown new code with holes in it and has to work out that none of the holes means
anything. DEC-047's snap papers over some of this at 16 bytes and cannot reach the rest.

### Why this cannot be fixed in `D`, which is the load-bearing fact

Those islands are **matched bytes**. Dropping them lowers the total matched length below the LCS,
and `matched length equals LCS on 600 random pairs` fails on the first run. Byte-minimality is the
right objective for a validator and the wrong one for a picture — `06-domain-research.md` §3.6
recorded both maintainer sources saying so — and the two are separated here rather than reconciled.

Anyone reaching for `CanonicalDiff.swift` to fix confetti should read that paragraph first.

### Why it needs no invariant reopened

Relabelling `.unchanged` as presented only ever **grows** the presented set, and growth is monotone:
a byte of `D`'s hunks that was contained stays contained. This is DEC-021's argument for grapheme
snapping and DEC-047's for boundary snapping, applied a third time. INV-2 holds by construction.

### Decision

An unchanged segment is absorbed into the run around it when **all** of:

1. it is flanked on both sides by presented segments — a trailing gap is where the change ended, not
   an island inside it;
2. it is no longer than `absorbIslandBytes` (**8**, from M11-D);
3. it is no longer than the shorter of its two flanks — scale-free, and it is what saves a 6-byte gap
   between two 3-byte edits, where the gap is real context between two real edits;
4. **every line it touches already carries a presented byte from one of its flanks.**

Rule 4 is load-bearing and it is a theorem rather than a heuristic: **absorption never changes
`changedLines`.** The metric M11-B introduced — a line reported changed that was not — cannot move
in the wrong direction at any floor, and M11-D confirms it empirically at every floor from 0 to 24.
It is what lets an island span a newline, which the confetti case requires, without the pass ever
being able to claim a line it was not already claiming.

And the run must agree with itself: the two flanks must share a `label`, a `disclosure`, a `link`,
and a side of `confidenceFloor`. `coalesceAdjacent` refuses to merge across exactly those, and this
pass must not smuggle past it what that one turns away.

**A `moved` flank is refused outright.** A move is the one label that is a claim about *both* sides —
DEC-038 requires the two ranges to be byte-identical — and the two sides are absorbed independently,
so widening one is not guaranteed to widen the other. T-11 found this by failing on 192
disagreements. It is a refusal rather than a guard, because a rule that holds only when the two sides
happen to agree is not a rule.

**There is no per-run allowance, and there was going to be one.** The fear is a long alternation of
small edits swallowing its context whole; the answer looked like a cap on absorbed bytes per run.
Rule 3 already implies it: with flanks `f₁ … fₙ` and islands `iₖ ≤ min(fₖ, fₖ₊₁)`, the absorbed total
is at most `f₁ + … + fₙ₋₁`, strictly less than the run's own changed bytes. A cap at or above that is
a knob that can never turn, and this repository has three recorded defects that were exactly that.
The bound is asserted as a property instead.

### Pass order

`absorbIslands` → `snapPresentation` → `snapToGraphemeBoundaries` → `markUnparsed` → `coalesceAdjacent`.

Absorption goes **first**, for two reasons that are the same reason twice. An absorbed island removes
two boundaries from the presented set, so the 16-byte snap has strictly less to rescue — DEC-087
established that the order of these passes is load-bearing, and this is that fact from the other
side. And were absorption to run *after* the snap, its input would be a function of
`boundarySnapBudget`, so the budget-0 control the suite depends on would be exercising a different
absorption from the shipped one.

### Consequences

- **Marks fall and bytes barely rise.** Over the corpus: 182 segments → **159**, for 5542 presented
  bytes → **5581**. Twenty-three fewer marks for thirty-nine more bytes, 0.7%.
- **`false` does not move at any floor**, which is rule 4 being a theorem rather than an argument.
- The absorbed island inherits its flanks' classification when they agree and `nil` when they do not,
  and the lower confidence — `coalesceAdjacent`'s rules, reused deliberately. Inheriting an agreed
  classification is what stops M6-B's trap recurring, where splitting a classified change into a
  classified core and unclassified flanks dropped M6-A's recall from 97.8% to 40.9%.
- **It does not reach two things, and both are alignment rather than presentation.** A run split only
  by the confidence floor has no island between its halves — `⟦~s⟧⟦rc⟧` over an unchanged `src` is two
  *presented* segments, and no widening pass can unmark them. And `titleSize?: '2.5xl' | '2xl' | 'xl'`
  keeps its five marks because rule 3 correctly refuses a 5-byte island between a 5-byte and a 1-byte
  flank. Both are DEC-093's deferred option (c): relax "no neighbouring match may be consumed".

### Revisit trigger

Reopen if a case appears where absorption merges two changes a reviewer needed to see as separate —
DEC-047's own trigger, restated for this pass.

---

## DEC-095 — A language with no grammar gets a real diff, and the hairline marks a region rather than a file

- **Date:** 2026-08-17 · **Topic:** What the fallback path shows · **Status:** Accepted
- **Prompted by:** the owner's fifth diff session — a new `.module.css` file drawn with a near-opaque box around its entire body, and `raw` appended to its name in the status line

### Context

`SyntaxPartition.swift` gates structural analysis on eight extensions. Everything else — `.css`,
`.json`, `.md`, `.yml`, `.py`, `.sh` — reports F7 `unsupportedLanguage`, and `fallbackResult` answered
that with `wholeFilePartition`: **one segment covering the file, confidence 0.** Measured on the
owner's own machine, a 589-line `globals.css` with a ten-line change marked all 589.

The renderer then drew `.ds-fallback`'s solid hairline around the whole body. The rule's own comment
says what it was written for — *"a **partial** parse, where the result stands and named regions
inside it were never read as code"* — which is `markUnparsed`, not this.

### The premise that was wrong

F7 is a statement about **structure**. Comparison never depended on parsing — that is DEC-021, and it
is why the byte diff is the thing the structural path is *validated against*. Painting every line was
never required by any decision; it was the shape of `wholeFilePartition`, inherited from a time when
the fallback path had nothing else to offer. It has had the byte diff all along.

### Decision

`fallbackPartitions` builds the two partitions from `canonicalDiff`, labels every presented range
`.fallback`, and runs the passes that need no parse: DEC-094's absorption, grapheme snapping,
coalescing. DEC-093's shift is already inside `canonicalDiff`, so the alignment arrives on line and
token boundaries. `snapPresentation` is skipped, because it is the one that needs a tree.

- **INV-4 is unchanged.** Every presented range is still marked as produced without structural
  analysis, and `fallbackNotice` still says the file is shown as plain text. What changes is that the
  bytes that did not change are labelled `.unchanged` instead of being painted with the rest.
- **Raw mode takes the same route, in the same function.** DEC-013 makes Raw a *path* and not a worse
  answer, and two implementations of "what a file looks like when nothing parsed" would drift.
- **Where the diff cannot be computed, the whole file is still the answer**, because nothing smaller
  is known. That branch is kept and tested.
- **The fallback path gets its own work budget**, a tenth of the default. A file arrives here
  *because* something about it was too expensive or too unknown to analyse, so spending the full
  budget re-deriving that is the wrong trade — measured, the dense-JSX gate case went from 0.98 s to
  the parse baseline and back again.
- **The hairline moves to `ds-parse-error`**, which `markUnparsed` sets and nothing else does.
  `ds-fallback` keeps the tint, so it is still a mark and still survives greyscale; what it loses is
  a box it would now draw around every change in a stylesheet.
- **The status line says `plain text — …` rather than `raw — …`.** `pathTaken` keeps `raw`: that is
  the contract's word. The reader's word collided with the Raw *mode* in the pill, which means
  something else entirely.

### Consequences

- Over three real files: **809 lines painted becomes 17, against git's 16** (M11-E).
- **`GutterChecks`' "a raw model marks every line of a changed file" is inverted**, and the old value
  is kept as a printed control. Its comment argued the case — *Raw claims no structure, and the
  gutter must not imply one* — and the argument was sound while the premise was not. The old value
  is now the negative control: *it is not marking every line and calling it precision.*
- `ClassificationChecks`' "its segments are labelled fallback, not unchanged" becomes "every
  *presented* segment is labelled fallback", which is what INV-4 says.
- `canonicalDiff` is now computed on the fallback path as well as in `validate` and `changeStops`.
  That is three times per model where it was twice. Recorded in `tasks/todo.md` as a threading
  opportunity, not a blocker.

### Revisit trigger

Reopen if a file class appears where the byte diff on the fallback path is both affordable and
misleading — the case this entry assumes does not exist, because comparison does not depend on
parsing.

---

## DEC-096 — The unified blocks are computed in the engine, and byte-identical lines are peeled off them

- **Date:** 2026-08-17 · **Topic:** Where the unified layout's blocks are decided · **Status:** Accepted
- **Prompted by:** the owner's fifth diff session — `}: ImageTextProps) {` and `  return (` printed on both sides of a block whose actual change was the twelve lines between them

### Context

`unifiedBlocks` lived in `main.js`. Every other fact of that shape — `changedLines`, `stops`,
`collapses`, `formattingCollapses`, `anchors` — is computed in the engine, for the reason M7-A gave
and `main.js` still states three lines above the function: *a fact about the model belongs to the
model, and one the renderer works out for itself cannot be checked without a webview.* This was the
one part of the unified layout deciding **what is shown**, and it had never been checkable.

### Decision

`Sources/DiffScopeEngine/Unified.swift`. The snap-and-merge is ported unchanged, including the
empty-range branch that makes `7` → `77` print as a changed line rather than an added one with
nothing to compare against. `RenderModel` carries `unifiedBlocks` in UTF-16 units like everything
else the renderer sees; `buildUnified` reads them.

And the peel: a leading or trailing line pair comes off a block when the old and new lines are
byte-equal **and** no stop covers any byte of either, terminator included.

The terminator counting is the whole of the rule's correctness, and the first draft had it wrong. It
excluded the terminator, following `changedLines`' convention that a segment ending exactly on a
newline does not claim the line after it — true there, and the wrong question here. What a peel must
preserve is not which line a stop *claims* but which bytes it *covers*. **The property check caught
it**: on `moved-function` a stop covering a newline and nothing else fell out of every block, which
is a difference the layout would have stopped showing.

### Consequences, including the one that argues against this entry

- **The peel fires on one fixture of 51, and on none of the eleven real files** (M11-F). DEC-093 got
  there first: once the alignment lands on line boundaries, a stop stops grazing the line above it,
  and there is nothing left to peel. This entry is worth having for the move into the engine and for
  the property that move made checkable; it is **not** what fixed the owner's report, and saying
  otherwise would be false.
- **The duplication the owner saw is still there, 36 lines of it, and it is alignment rather than
  layout.** `}: ImageTextProps) {` prints twice because a stop covers its `{`, and `  return (`
  because a stop covers `return `. Both lines are byte-identical and both carry a claim that they are
  not. The peel must refuse them — a rule that peeled a line carrying a mark would hide a difference
  — so the answer is DEC-093's deferred option (c), not this.
- Unlike DEC-094's rejected per-run allowance, this rule **can** turn, and does. That is the
  distinction worth keeping: the allowance was provably unreachable given the rule beside it, and
  this is reachable and currently rare.

### Revisit trigger

Reopen if option (c) lands and the peel is then unreachable rather than rare — at that point it is
the allowance, and it should go the same way.

---

## DEC-097 — A shift may consume a short match, and merge the two hunks either side of it

- **Date:** 2026-08-17 · **Topic:** The bound DEC-093 deferred · **Status:** Accepted · **Amends DEC-087, DEC-093**
- **Prompted by:** three findings pointing at one cause — M11-B's remaining files, M11-D's `⟦~s⟧⟦rc⟧`, and M11-F's 36 lines printed twice

### Context

DEC-093 listed this as option (c) and deferred it. Everything since has pointed back at it. The shift
walk is bounded by `current.length` and `previous.length`, so **a four-byte match between two
insertions bounds it to nothing** — which is precisely the owner's fourth case: a parameter added to
a signature and a block added to the body, with `}: ImageTextProps) {` between them. Neither
insertion could move, so the alignment anchored on that line's `{` and an untouched line read as
edited, and then printed twice in the unified view.

### Why it is legal, which is the part DEC-093 had already established

A shift moves the boundary between the hunk and **each** of its neighbouring matches by the same
amount: `previous` grows by the shift and `current` shrinks by it. At `shift == current.length`,
`current` shrinks to nothing and `previous` has grown by exactly as much — **the total matched length
is invariant**, which is the property INV-2's minimality rests on and the one the 600-pair LCS check
asserts. What changes is the number of hunks, not the size of the edit script.

DEC-087's sentence — *"a match shrinking to nothing merges two hunks into one, which is a different
edit script rather than the same one written down better"* — is the half of this that was wrong. It
is the same edit script. It is a different *partition* of that script into hunks, and a hunk is a
presentation unit rather than a fact about the edit.

### Decision

A neighbouring match may be consumed when it is **no longer than `matchConsumeFloor` (8 bytes)** and
the resulting position is **rank 1** — a whole number of lines on both sides. Anything else keeps
DEC-087's bound. Consumed matches are dropped from the list rather than kept at zero width.

Rank 1 only, because merging two hunks is the one thing this pass does that a reader can see as a
*different* answer rather than a better-placed one. A token boundary does not earn it.

**Eight, because that is where the curve saturates.** M11-G finds 8, 16, 24, 48 and 96 identical on
the corpus. Consuming is the one direction in this pass that relocates presented bytes rather than
renaming a boundary, so the smallest value buying the whole effect is the one to take — the opposite
of the reasoning that picked DEC-094's floor, and for the opposite reason.

### Consequences

- `}: ImageTextProps) {` **carries no mark at all now**, and the insertion either side of it reads as
  two clean line-aligned blocks. That was one of the five cases the owner reported.
- Over the corpus: false lines 23 → **22**, presented bytes 5581 → **5570**, lines printed twice in
  the unified view 36 → **32**. Segments 159 → 160: merging two hunks into one occasionally splits a
  run elsewhere, and one extra mark for four fewer duplicated lines is the trade.
- **It does not reach `⟦~s⟧⟦rc⟧` over an unchanged `src`, nor `return (`.** Both sit inside a
  reflowed JSX element where the surrounding matches are far longer than any floor worth setting, and
  raising the floor to 96 changes neither. What is left there is the reflow case the log has carried
  since M11-B: the old bytes are a subsequence of the new, and a minimal alignment legitimately puts
  every changed byte on one side. The answer is a presentation that shows a substitution on **both**
  sides, which is a different entry and a larger one.
- `changeStops` moves, so navigation, folds, formatting collapses and the unified blocks all move
  with it. Each has its own checks and all of them pass; the one that would have caught a mistake
  here is DEC-096's containment property, which is why that entry came first.

### Revisit trigger

Reopen if a corpus shows hunks merging across content a reviewer needed to read as two changes. The
floor is the dial, and the measurement to redo is M11-G.

---

## DEC-098 — M11 and M12: the write path, and the proof that replaces R-8

- **Date:** 2026-08-17
- **Topic:** How version two's first two milestones are built. Implements [DEC-092](#dec-092--version-two-the-application-writes); nothing here reopens it.
- **Status:** Accepted — built, checked and shipped in this state.

### What was built

**M11, the write foundation.** `GitWriteOperation` is a second closed registry with a declared risk class per operation; `GitWriter` is a separate runner that does *not* pass `--no-optional-locks`, handles `index.lock` contention explicitly, can never open an editor (`GIT_EDITOR`, `GIT_SEQUENCE_EDITOR`) and can never block on a prompt. `RestorePoint` records HEAD, the index as a tree object, and — where the working tree is at risk — a stash, **before** the operation rather than after. Unstage, stage, discard, and the command record.

**M12, staging and the commit.** `StagingPatch.swift` computes a line walk of the two sides, emits a unified patch for a selection, and — along a path the patch has no hand in — computes the bytes that selection should produce. The commit box is under the file list with GitHub Desktop's two fields and one wide button; the checkbox beside each path is a **real index write**; the hunk under the caret stages from the keyboard.

**Also built, ahead of their milestones, because they cost little once the registry existed:** branches, stashes, conflicts with the state banner, tags, worktrees, reflog, bisect, revert, cherry-pick, reset, the remote (fetch, pull, push, force-with-lease), history rewriting (reword, squash, fixup, drop, move, amend-old) and custom commands.

### The three findings

**A hidden `NSView` keeps its constraints.** The banner was given `isHidden` and a 26 pt height, and a repository with nothing in progress drew a 26 pt gap over the status line. Same shape as DEC-088's empty notice bar, one band down; the height is a held constraint now.

**A button's title became a floor under the pane.** `Commit to some-long-branch` and `Amend the last commit` are strings the reader's repository decides the length of, and pinned to both edges at the default resistance they set the file pane's minimum width — measured at 292 pt against a divider dragged to 260, which is a divider that refuses to move because of a button's title. Every control in the box holds `.defaultLow` horizontal resistance now, and `dragSelftest` is what caught it.

**`fixup! <sha>` is not what `--autosquash` matches.** *Amend an old commit* wrote its own message and the fixup commit stayed on the branch, visible in the check as `fixup! a75edbc… | three | two | one`. git composes the subject autosquash recognises — `fixup! <the target's own subject>` — and `commit --fixup=<sha>` is the way to get it. The oldest commit needed `rebase --root` beside it: without that, the one commit in a repository that could not be amended was the first one.

### Consequences

- **R-8 split rather than weakened.** The read registry keeps its byte-identical proof; the write registry keeps the closure property and adds **INV-6** — a staging operation moves the index by exactly the selected byte ranges and nothing else, asserted against bytes computed without the patch.
- The application's single raw `git` spawn — the selftest fixture — is now **one function with a runtime guard** that refuses any directory outside `NSTemporaryDirectory()`. It was a comment in a check before, and a comment is not a refusal.
- `12-…` §9b is the keyboard coverage table for functions that write, and four operations are deliberately unbound with their reason.

### The renderer's half, built after the rest

The two items this entry first recorded as *not built* — the graph column and clicking a line to stage it — needed `Renderer/node_modules`, which was not installed. It installed, and both landed:

- **History draws its topology.** `GraphCommit.laneColumn` composes the lane marks in the Git layer — `●`, `│`, and `─` where a merge reaches for its second parent — and the page draws them in a fixed-width column, so the lines join up between rows. git's own `--graph` output is still never parsed: it is a presentation, and the lanes come from `%P`.
- **A commit can be picked at last.** The shell has had a `pickCommit` handler since M9 and **the page never sent the message** — so DEC-061's two-commit comparison, and every verb in the Repository menu that acts on a commit, had no way to be given one. Found by writing the verbs, not by a check.
- **The sign column stages its line.** `+` and `−` are already the mark that says which side a line is on, so they carry the action rather than a second column of checkboxes saying the same thing. The message is validated like the sha beside it: a line number that becomes a patch against the index is input, not instruction.

---

## DEC-099 — The changed-file list is a tree

- **Date:** 2026-08-22
- **Topic:** How the changed-file list is structured. **Answers OQ-041**, open since Phase 4, and supersedes the grouping half of [DEC-033](#dec-033--changed-file-list-grouping-and-path-elision) and the whole of [DEC-074](#dec-074--group-headers-say-the-shortest-form-that-stays-unique).
- **Status:** Accepted — the product owner asked for it directly, with a picture.

### Context

DEC-033 gave the list **one header per group** — a workspace package where one is declared, the parent directory otherwise — and a flat run of files under it. OQ-041 recorded that this was "a middle position, not an answer" and left the tree open on purpose.

The owner reopened it with a screenshot of a directory tree: nested rows, disclosure arrows, indentation guides, `app/[locale]/(dev)/components` drawn as **one** row rather than four. Their words: *"chciałbym żeby changed files miało strukturę wizualną a nie tylko napisane w jakim są folderze."*

### What was wrong with the middle position

A header is a *label*: it says where the files under it are, and says nothing about how those places relate. `src/components/features/bg-img-banner` and `src/components/features/image-text` are siblings, and the flat form spent 40 characters twice to say so without ever saying it. DEC-074 then had to invent a shortening rule to make those headers fit — a rule whose entire job was to compress a fact the tree carries for free, in the indentation.

### Final decision

**The list is a directory tree.** Rows are directories and files; a directory's children are indented under it, with a guide line per level; a directory row can be collapsed and its subtree disappears with it.

Three rules make it a tree rather than a nesting of every path component:

1. **A chain of single-child directories is one row.** `app` → `[locale]` → `(dev)` → `components`, none of which holds a file of its own, is drawn as `app/[locale]/(dev)/components`. Four rows carrying no branch would be four rows carrying no information.
2. **Directories before files, each alphabetically**, at every level — the order every file browser uses, and the one a reader can predict without being told.
3. **Directory rows are labels, never focus stops** — DEC-033's rule, kept exactly. ⌥↑ / ⌥↓ still step *files*, so a 63-file list is still 62 keystrokes however deep it nests, and the definition of done's measurement is unchanged.

**Collapsing is per directory, by pointer or by keyboard**: ⌥← collapses the folder the selection is in, ⌥→ expands the folder under it. That is DEC-065's tier system unchanged — ⌥ is the file-list tier — and it adds one row to `12-…` §9's coverage table.

### Consequences

- **DEC-074 is retired.** Its shortening rule existed to fit a long path into a header; a tree draws the last component and the indentation says the rest. Its uniqueness property survives in a stronger form: two directories can only share a row if they are the same directory.
- **The workspace-package machinery is retired with it.** `pnpm-workspace.yaml` declared a prefix so the flat list could group by it; a tree puts `packages/app-2` on its own row because it *is* a directory, and the declaration adds nothing. Measured at implementation time (2026-07-31) that none of the twelve workspace files in this corpus declares a `packages:` key at all, which is why this costs nothing.
- **Indentation is a drawn guide, not spaces.** A vertical hairline per level, so a file eight levels deep can still be traced back to its parent — the reason a tree beats a header at all.
- The collapse state is per repository and lives in the window, not in the configuration file: which folders a reader had folded is not a setting they would look for later.

### Revisit trigger

Reopen if a repository in the corpus produces a tree deeper than the pane can indent — the guides are 10 pt each, and past about ten levels the names have nowhere left to start.

---

## DEC-100 — A mark finishes the word it cut, and two marks inside one word are one mark

- **Date:** 2026-08-23
- **Topic:** The two mark-level shapes a 4016-change corpus ranked first. Presentation only; no
  invariant is reopened.
- **Status:** Accepted — built, checked and measured.

### What the corpus said

The owner asked for the reflow case to be fixed *generally* rather than on the file they reported it
on, and for the fix to be steered by their own history rather than by one screenshot. So the first
thing built was not a fix: it was `Scripts/devtools/build-corpus.sh`, which extracts real
(before, after) pairs from thirteen Next.js repositories, and `--corpus-survey`, which runs the
shipped pipeline over all of them and names what recurs. 4016 pairs. The taxonomy is
[M12-A](22-experiment-log.md).

Two of the nine shapes are about *marks* rather than about alignment, and together they are the two
largest by instance count:

- **`split-mark`, 30942 instances in 40.1% of pairs** — two marks that touch, drawn as two. Most of
  them fall **inside a word**: `⟦t⟧⟦ransition⟧`.
- **`shredded-word`, 6723 instances in 22.6% of pairs** — a mark that starts or ends inside a word
  whose other half is *not* marked: `bg-o⟦pacity-30⟧`.

### The decision

**A word is one thing to a reader, so a mark may finish one and two marks may not divide one.**

- `snapToWordBoundaries` widens each mark's edges to the ends of the word they cut, with two rules
  chosen by where the edge falls: inside a string or template literal a word runs whitespace to
  whitespace (a Tailwind class, a URL segment, a path); everywhere else it is the language's
  identifier rule, so `a-b` is left alone — outside a string a hyphen is a minus sign.
- `coalesceAcrossWords` merges two presented segments whose junction falls inside a word, taking the
  **lower** confidence. This is the one place `coalesceAdjacent`'s refusal to merge across
  `confidenceFloor` is relaxed, and only there: nothing in the file distinguishes the `t` of
  `transition` from its `ransition`, so two marks do not report two facts, they report one twice.
  `disclosure` and `link` still refuse, and a junction between two words is still left alone.

**Budget 24 bytes**, from the curve in [M12-B](22-experiment-log.md). The curve does not saturate —
48 removes almost every shred — and 24 is where the marks it saves stop being worth the bytes it
spends: a "word" longer than 24 bytes is a URL or a hashed class name, not something a reader is
holding in their head.

**Why `snapPresentation` could not do this.** The syntax snap offers named-node boundaries, and the
only boundaries inside a 130-byte class attribute are its two quotes — which a 16-byte budget will
never reach. Raising that budget to reach them marks the whole attribute, which is a different and
worse answer. The word rule is what the syntax tree does not have.

### Consequences, measured over 4016 real changes ([M12-C](22-experiment-log.md))

- `shredded-word` **6723 → 682**, and the pairs affected 907 → 240.
- `split-mark` **30942 → 27284**; marks overall **81665 → 75873**, −7.1%.
- Presented bytes **2663458 → 2706941**, +1.6%. DEC-047 spent 4.4% for less.
- **`false` and `missed` lines do not move at all** — 9731 and 7075 either way. That is the property
  rather than a coincidence: a word cannot straddle a line terminator, because a terminator is not a
  word byte under either rule, so the widening cannot add a line to `changedLines`. Asserted over
  every fixture as well as measured over the corpus.
- `micro-island` rises 4766 → 5305: a widened mark leaves a shorter unchanged gap behind it, and
  absorption's relative rule then refuses that gap. Named here rather than left for someone to find.

### Revisit trigger

Reopen if a corpus shows marks reaching across content a reader needed to see as two names. The dial
is `wordSnapBudget`, and the measurement to redo is M12-B.

---

## DEC-101 — A rewrap says it is a rewrap

- **Date:** 2026-08-23
- **Topic:** Marks over the whitespace a reflow moved are classified `whitespace`, so a rewrapped
  element costs the reader one loud mark instead of twelve. Grouping under DEC-017, never filtering.
- **Status:** Accepted — built, checked and measured.

### The report and the shape behind it

*"A prop was added to `<Image>`, prettier rewrapped the element, and the whole element is shown as
changed twice."* The corpus says this is not one file: `reflow-insertion` — a block whose old tokens
are a subsequence of its new ones — occurs **3795 times in 46.0% of pairs**, and 13090 marks across
the corpus are made of **nothing but whitespace** and carry no classification at all.

`changeClassification` cannot reach them. It runs on the gap pair between two anchors, and
`reconcile` then cuts those gaps against the canonical mask — so by the time a mark exists it no
longer knows its counterpart. It also stops being able to say *whitespace* the moment anything else
in the pair changed, which is exactly the reported case: rewrap **plus** a new prop.

### The decision

The canonical hunk is a correspondence by construction, so the layout question is asked of it rather
than of the gap. Three rules, in order of how much they claim:

1. **`layoutOnly`** — the two sides of the region are equal ignoring whitespace: every mark in it is
   layout, whatever bytes it covers.
2. **`reflowed`** — one side's tokens are a subsequence of the other's: the marks made only of
   whitespace are layout; the marks over the inserted or removed tokens stay loud.
3. **`preserved gap`** — the finest, and the one that reaches the report: a gap between two tokens
   that are still **neighbours on the other side**. `<Image` was followed by `src` before and is
   followed by `src` now, so whatever happened between them is a line break moving.

The question is asked of the **region** the hunks jointly cover, not of each hunk: a reorder is only
visible at the scale of the thing reordered.

**A region whose tokens are a permutation is refused outright** (`reordered`), and the gap rule is
refused inside it. DEC-048 lets the interface collapse a `formatting-only` run, and a reorder with
one quiet gap in it is a reorder a reader can miss.

### Three drafts, and the suite refused two of them

1. *Any mark made only of whitespace is formatting.* True of the bytes in isolation and wrong about
   the change: `prop-reordering` moves four JSX attributes onto one line and four marks of a reorder
   came out `formatting-only`. The fixture's own check — **a reorder is never presented as
   formatting-only** — failed on the first run.
2. *Guard on the `reordering` classification.* Changed nothing, because that fixture produces **no
   classified segment at all**: its gap is subdivided by anchors before the classifier sees it.
   **Measure the control before believing the check**, twice in one pass.
3. *Ask the token sequence*, which is the question itself rather than a proxy for it — a reflow
   preserves it, a reorder permutes it. Then once more: equal token *counts* were still too strict,
   because `prop-reordering` also pulls `/>` onto the line, so the test is multiset containment.

### Consequences, over 4016 real changes

- Unclassified whitespace-only marks **13090 → 10495**, in 738 → 482 pairs.
- Quiet bytes **67457 → 99215**; the loud share of what is presented falls 97.5% → **96.3%**.
- Nothing is hidden, nothing is dropped, no byte enters or leaves the presented set — asserted.
- On the reported shape the whole rewrap is quiet and the added prop is the only loud mark, which is
  the case the check in `WordSnapChecks.swift` is written against.

**The honest part of this entry is how little it moves on its own.** Where the rewrap is the *only*
change in its region, `changeClassification` already said so and this pass adds nothing; the 20% it
does move is the case where a real edit sits in the same region and used to drown it out. The check
was rewritten to measure that case after the first version of it measured the classifier that was
already there.

### Revisit trigger

Reopen if a reader reports a change they had to look for because it was drawn quietly. The switch is
`classifyWhitespaceHunks`, and every rule above is off with it.

---

## DEC-102 — A rewrapped old half is withheld, not printed twice

- **Date:** 2026-08-23
- **Topic:** The other half of the owner's report: the unified view prints a rewrapped element on
  both sides. Extends [DEC-096](#dec-096--the-unified-blocks-are-computed-in-the-engine-and-byte-identical-lines-are-peeled-off-them);
  nothing in DEC-100 or DEC-101 could reach it.
- **Status:** Accepted — built, checked and measured.

### Why the mark-level entries could not fix it

*"The whole previous `<Image>` line is shown, and the new ones, although it is still the same thing
and the only change is one added prop."* DEC-100 and DEC-101 make the marks inside those lines right,
and change **nothing** about the report: `silent-old-side` and `reflow-insertion` sat at 3986 and 3795
before and after. They are not statements about where a mark begins; they are statements about which
*lines the unified layout prints*, and the layout printed both halves of every block because it had
no way to know the two halves said the same thing.

### The decision

`UnifiedBlock` gains **`reflowed`**, and the layout withholds the old half of a block that carries it
behind an expander in the hunk header.

**The test is subsequence in one direction, and the direction is the whole safety argument.** A block
is `reflowed` when every token of its old half appears on its new half, in order. Then everything the
withheld side says is still on screen and only the wrapping differs. The converse — new tokens being a
subsequence of old — is a **removal**, and what a removal deletes is exactly what a reviewer must see,
so a block that removes anything is never reflowed however tidy it looks. Both halves must be
non-empty, because a pure insertion has no old half and an expander over it would open onto nothing.

**Withheld, not dropped**, and by the standard DEC-048 already set for the formatting group: the
header says how many lines are behind it, one click brings them back, and the engine keeps the block
whole so every check about stops and containment reads the same as before. The flag is a *fact about
the block*, decided in the engine where it can be checked, and what the layout does with it stays the
layout's business — the same division M7-A drew for stops, folds and changed lines.

### Consequences, over the same 4016 changes

| shape | before | after |
|---|---|---|
| `silent-old-side` | 3986 (47.5% of pairs) | **202 (4.1%)** |
| `reflow-insertion` | 3795 (46.0%) | **0** |
| `duplicated-line` | 2320 (28.7%) | **1075 (14.0%)** |
| `reflowed-block` | — | 3910 in 46.6% of pairs |

**Nearly half of all the owner's changes contain at least one block this withholds.** The 202 that
remain are blocks where the old half holds a token the new half does not — a removal beside a
rewrap — and those are the blocks that *should* print both sides.

`duplicated-line` halves rather than vanishing for the same reason: what is left is byte-identical
lines inside blocks that are not rewraps, which is DEC-096's peel territory and a separate question.

### What it costs and what it does not

Nothing is hidden that the reader cannot open, the model is unchanged, and no invariant is touched:
the blocks, the stops and the segments are exactly what they were. The cost is one class of surprise —
a reader scanning the `−` column will not see a line that is, in the file, still there in a different
shape — and the header sentence is what pays it: *re-wrapped — N lines not printed, click to show*.

### Revisit trigger

Reopen if a reader reports missing a change that sat inside a withheld half. That cannot happen while
the subsequence test holds, so the first thing to check would be the test itself — the property is
asserted over every fixture, and the corpus survey counts the blocks.
