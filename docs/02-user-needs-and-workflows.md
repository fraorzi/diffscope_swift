# 02 — User Needs and Workflows

**Status:** Phase 1 complete. Reflects DEC-001 through DEC-020.
**Authority:** Descriptive; [04-decision-log.md](04-decision-log.md) wins on conflict.

---

## User

A single frontend developer working across roughly 21 client and personal repositories in `~/WebstormProjects`, primarily Next.js, Astro, and Preact projects, mostly pnpm monorepos. Editor is WebStorm. Work pattern is feature branches off `main` or `master`, with several repositories dirty at any time.

Distribution is undecided (DEC-020), so version one optimizes for this user specifically rather than for a general audience.

## Primary needs

**N1 — Review my own work before committing.** The dominant loop. Covered by scopes 1–3.

**N2 — Review an entire feature branch before pushing or opening a PR.** Covered by scope 4. Note this need exists even when the working tree is clean — measurement found a clean repository sitting 2 commits ahead of its base, which is why the repository list shows both signals (DEC-012).

**N3 — Understand a structural change without manual re-alignment.** The founding need. Wrapper changes, prop reordering, and formatting passes should not require mentally diffing two large blocks.

**N4 — Trust that nothing was hidden.** Non-negotiable and the reason N3 cannot be solved with a semantic diff.

**N5 — Get from a change to the code in WebStorm quickly.** Covered by DEC-015.

**N6 — See at a glance which repositories need attention.** Covered by DEC-006 and DEC-012.

## Main workflow, as settled

The eleven-step workflow from the brief was reviewed step by step. Below is the settled version, with each step annotated by what decided it and what remains open.

| # | Step | Status | Ref |
|---|---|---|---|
| 1 | Application launches | Settled — single window | DEC-005 |
| 2 | Scans all configured roots; also lists individually added repositories | Settled — any number of roots, no default path, depth 2 per root, stop at first repo found | DEC-018, DEC-036, DEC-037 |
| 3 | Identifies repositories, computes status in parallel | Settled — eager sweep at launch, refresh on focus | DEC-006 |
| 4 | Displays repository list | Settled — all repos, two signals each | DEC-012 |
| 5 | User selects a repository | Settled — last selection remembered | DEC-005 |
| 6 | Shows branch, base branch, and available scopes | Settled — base detected by cascade, displayed, overridable; base ref and age shown | DEC-009, DEC-010 |
| 7 | Displays changed-file list | **Partially open** — file tree vs flat list undecided | OQ-041 |
| 8 | Selecting a file opens the diff | Settled — side-by-side, Structural mode presumptive default | DEC-013, DEC-014 |
| 9 | Saving in WebStorm refreshes the app | Settled — auto-refresh, ~400 ms debounce, scroll anchor preserved | DEC-007 |
| 10 | Open file and line in WebStorm | Settled in shape — configurable command, WebStorm default | DEC-015 |
| 11 | Switch between view modes | Settled — Structural / Expanded / Raw | DEC-013 |

### Steps that gained requirements during review

- **Step 3** must use `git --no-optional-locks` or equivalent, because plain `git status` can rewrite the index and DEC-003 forbids writes.
- **Step 6** must display which ref the base comparison uses and how old it is, because DEC-011 removed fetching and age display now carries the entire staleness signal.
- **Step 9** requires the pinned-source-pair model, making mixed-version diffs structurally impossible rather than merely unlikely.
- **Step 10** needs defined behavior when the target line exists only on the old side of a deleted region.

### Steps not yet validated against real use

Recorded honestly rather than assumed working:

- Whether ~400 ms is the right debounce depends on how many file-system events a WebStorm save actually emits, including its atomic-replace save behavior. OQ-039.
- Whether scroll-anchor preservation feels stable depends on the anchoring semantics, which are unspecified. OQ-038.
- Whether the absence of a fetch button is tolerable rests on the assumption that WebStorm's background auto-fetch keeps refs fresh. Untested. DEC-011 revisit trigger.

## Secondary workflows

**Reviewing a clean repository's branch.** Needed by N2. Selecting a clean repository must lead naturally to scope 4 rather than presenting an empty view — an empty file list under scope 1 would be technically correct and practically useless.

**A repository where base detection fails.** `carrefour-inapp` today: **unborn HEAD** — no remote, zero refs, zero commits, everything untracked. Must produce an honest prompt and an explicit unknown ahead-count, never a fabricated zero (DEC-012).

This case is harder than it looks: `git symbolic-ref -q HEAD` returns `refs/heads/main` with exit 0, so the usual detection idiom reports a branch that does not exist. All four scopes are undefined, since there is no `HEAD` commit. Full behavior is OQ-050 (which supersedes the detached-HEAD framing of OQ-008).

**Encountering an unsupported file type.** The majority case by file count, since structural support is TS/TSX/JS/JSX only. Must be an ordinary, well-designed state — clearly labeled raw diff — not an error.

**Encountering unparseable source.** Half-typed JSX during editing is normal, not exceptional, given auto-refresh on save. Must fall back visibly and never lose a change.

## Explicit non-workflows

- Staging, committing, discarding, branching, fetching, or any repository modification (DEC-003, DEC-011).
- Comparing two repositories side by side (DEC-005).
- Reviewing arbitrary historical commits or arbitrary branch pairs — deferred with the pickers (DEC-008).
- Annotating or commenting on code (DEC-017).
- Any workflow requiring a network, a remote, or a forge.

## Keyboard-first expectation

DEC-016 commits to full keyboard operation of every function. This makes the keyboard map a specification deliverable rather than a convenience list, covering at minimum: repository selection, scope switching, file navigation, previous/next change, mode switching, expanding a collapsed range, showing a raw region, and opening in the editor. Tracked as OQ-023.
