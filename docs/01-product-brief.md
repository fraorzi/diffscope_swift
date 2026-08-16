# 01 — Product Brief

**Status:** Phase 1 complete. Reflects decisions DEC-001 through DEC-020.
**Authority:** Descriptive. Where this document and [04-decision-log.md](04-decision-log.md) disagree, the decision log wins.

---

## Positioning lines

> **"In a world of AI we don't need another text editor, we need a better code review."**

The product owner's line, 2026-08-15. Kept here because it is the shortest true statement of why this
application exists: the volume of code a person is asked to *read* rather than *write* is what
changed, and the interface that has not caught up is the diff.

Three more, 2026-08-16, the same claim at different lengths:

> **"We don't need another AI code editor. We need a better way to review code."**
>
> **"AI changed how we write code. It's time to change how we review it."**
>
> **"Code is written faster than ever. Review should catch up."**

All four are positioning lines for a future promotional site, **not interface copy** — nothing in the
application says any of them.

---

## One-paragraph summary

A macOS desktop application for reviewing diffs in local Git repositories. It discovers repositories under any number of user-chosen root directories — and accepts individually added repositories anywhere (DEC-037) — presents them with their branch and change state, and lets the user review changes under a chosen comparison scope.

**No default root path is assumed.** `~/WebstormProjects` was the brief's starting example and is what this user happens to use, but it is a WebStorm-specific name and carries no special status in the product (DEC-036 as amended). Its distinguishing property is a diff engine that aligns edits structurally rather than purely by line, so that structural frontend edits — a removed JSX wrapper, reordered props, a reformatted file — read as what they actually are, **without ever hiding a textual difference**.

## The problem

Line-based diffs represent small structural changes badly. Removing a wrapper around many JSX children appears as a large deletion followed by a nearly identical large insertion. The reviewer must mentally re-align two blocks to discover that almost nothing changed. The same failure appears with prop reordering, formatting passes, and import reordering.

The obvious fix — a semantic diff that reports "no behavioral change" — is the wrong fix, and this product explicitly rejects it. A reviewer who cannot trust that they are seeing everything cannot use the tool for review at all. The product's value depends on solving the alignment problem **without** acquiring the ability to hide things.

## The core invariant

> Structural analysis may change how edits are aligned, grouped, labeled, and presented. It must never suppress or discard any textual difference. The exact source text is the source of truth.

Everything in this document is subordinate to that sentence. Its precise machine-checkable formulation is Phase 5 work and is tracked as OQ-003.

## What version one is

| Dimension | Decision | Ref |
|---|---|---|
| Platform | macOS only, permanently | DEC-002 |
| Repository access | Strictly read-only | DEC-003 |
| Network access | None. Never fetches. | DEC-011 |
| Structural diff languages | TS, TSX, JS, JSX only | DEC-004 |
| All other file types | Raw textual diff, clearly labeled | DEC-004 |
| Window model | Single window, sidebar + diff pane | DEC-005 |
| Comparison scopes | Four (see below) | DEC-008 |
| Diff layout | Side-by-side only | DEC-014 |
| View modes | Structural / Expanded / Raw | DEC-013 |
| Audience | Personal tool; distribution undecided | DEC-020 |
| Stack | **Undecided.** Phase 3 research. | OQ-033 |

### The four comparison scopes

1. All local changes vs `HEAD`
2. Unstaged working tree vs index
3. Staged vs `HEAD`
4. Current branch vs merge-base of the detected base branch

Base branch is detected by cascade — `origin/HEAD`, then a unique local `main`/`master`, then prompt — and is displayed and overridable per repository (DEC-009). The base side uses the remote-tracking ref where available, falling back to local, always showing which ref was used and its age (DEC-010).

## What version one is not

- Not cross-platform. Linux and Windows are out of scope permanently.
- Not a Git client. It cannot stage, unstage, commit, discard, fetch, or modify anything.
- Not a semantic diff. It never concludes that a change does not matter.
- Not networked. No telemetry, no cloud processing, no AI at runtime.
- Not dependent on any remote, forge, or pull-request workflow.
- Not a general-purpose structural differ. Version one understands TS/TSX/JS/JSX; everything else is honest raw text.

## Trust model

The application's credibility rests on four commitments:

1. **It never writes on its own.** Not to the working tree, not to the index, not to Git config; `git fetch` is excluded too (DEC-003, DEC-011). Implementation consequence: Git invocations must be audited for incidental writes — plain `git status` can rewrite the index, `git --no-optional-locks status` does not. **Since DEC-053 the application also hosts a terminal**, which runs what the user types in it, including `git commit`. The commitment above is about what the application does by itself, and R-8 proves exactly that; the terminal is the user acting in their own shell.
2. **It never hides.** Formatting-only is a grouping with a disclosed count and immediate expansion, never a filter. "No changes" is displayed only when old and new content are byte-equal.
3. **It admits uncertainty.** Confidence, parser state, and fallback regions are displayed, not concealed. Low confidence degrades presentation visibly rather than producing a confident wrong answer.
4. **It always offers the control view.** Raw mode is always available, on the same pinned source pair, so any structural claim can be checked against plain text.

These are mandatory product properties, not features. They are not cuttable scope (DEC-017).

## Known hard problems

Recorded here so no later agent mistakes them for solved.

- **The exact invariant.** "Every changed byte" is probably wrong: encodings, BOMs, CRLF vs LF, Unicode normalization (NFC vs NFD — directly relevant to Polish text in these projects), and grapheme clusters all complicate it. Provisional formulation is reconstruction plus coverage. OQ-003.
- **Move detection carries a losslessness trap.** A move asserts content appears in two places; if the moved content also changed and the move discards its internal delta, a difference vanishes. OQ-026.
- **Repeated identical nodes are genuinely ambiguous.** Several near-identical JSX siblings admit multiple valid matchings. Ambiguity must lower confidence, never resolve arbitrarily. OQ-027.
- **Freshness is a correctness concern, not a UI concern.** Files change while a diff is open — that is the intended workflow. Every diff is bound to a pinned source pair so a mixed-version diff is structurally impossible. DEC-007.
- **Two color systems must coexist.** Syntax highlighting and change indication, while change meaning may not depend on color. OQ-040.

## Environment this is built for

Measured 2026-07-26 on the product owner's machine. Design target, not hypothesis.

- macOS 26.5.2, arm64. Full Xcode not installed; Swift 6.2.4 CLT present. Rust absent. Node 22 / pnpm 10 present.
- 21 repositories at `~/WebstormProjects`, all at depth 1. No nesting, no submodules, no worktrees. 12 are pnpm monorepos.
- 8 dirty, 13 clean. Largest working tree change count: 63 files.
- One repository (`carrefour-inapp`) has an **unborn HEAD**: no remote, zero refs, zero commits, everything untracked. The worst case for base detection exists today — and `git symbolic-ref -q HEAD` *succeeds* on it, returning a branch that does not exist. (Earlier drafts recorded this as detached HEAD; that was a Phase 0 misreading, corrected 2026-07-26. No repository in the population is detached.)
- Status sweep across all 21 repositories: 326 ms sequential, warm cache. Repository history size does not predict status cost.
- Base-ref ages range from 4 days to 9 weeks, so staleness is real and variable.
- "Clean" does not mean "nothing to review": one clean repository is 2 commits ahead of its base.

## Success criteria for version one

1. The JSX wrapper-removal case reads as a wrapper change with children preserved, not as a large delete plus a large insert.
2. Prop reordering with unchanged values is displayed as movement and formatting, never as "no change".
3. Every fixture in the Phase 6 corpus passes reconstruction and coverage checks.
4. Parser failure on invalid or partially-typed source produces a visible, correct raw fallback rather than a missing change.
5. Reviewing a 63-file working tree is practical via keyboard navigation.
6. The application is demonstrably incapable of modifying a repository **on any path of its own** — proven by R-8 over the closed set of Git operations it can issue. Commands the user types into the built-in terminal are theirs, and are the one way a repository changes while this application is open (DEC-053).
