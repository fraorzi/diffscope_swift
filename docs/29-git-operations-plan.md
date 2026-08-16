# 29 — Git operations plan (version two)

**Status:** Proposal, 2026-08-16. **Nothing here is decided.** This document exists so that the
decision it asks for — reopening [DEC-003](04-decision-log.md) — is taken with the whole shape of
the work visible, rather than one feature at a time. It answers [OQ-056](05-open-questions.md),
which has been open since 2026-07-31 and which says this must be reopened *explicitly or not at
all*.

Requested by the product owner, 2026-08-16: **the whole of lazygit's feature list, plus staging,
unstaging and committing as a GUI, with GitHub Desktop as the visual reference.**

Reading order for this document: §1 what it reverses → §2 what GitHub Desktop actually does → §3
the inventory → §4 where each lands in the window → §5 the proof machinery → §6 milestones → §7 the
five questions only the owner can answer.

---

## 1. What this reverses, and what it does not

| Reversed | Held |
|---|---|
| **DEC-003** — "the application performs no operation that modifies repository state" | The invariant of [01-product-brief.md](01-product-brief.md): structural analysis never suppresses a textual difference |
| **DEC-011** — never fetches (only if §7 OQ-B is answered *yes*) | Nothing is automatic. No write, no fetch, no push happens without a keystroke or a click that means that operation |
| **R-8** as a blanket claim — *every registered operation leaves `.git` byte-identical* | R-8 as a **proof over a registry**. It splits rather than dies; see §5 |
| **DEC-061**'s revisit trigger — History was admitted as a lens on condition it never grew a graph or a filter | The read path. The engine, the sweep and the four scopes stay read-only and keep `--no-optional-locks` |

**OQ-056 already wrote the sequencing**, and it is adopted here unchanged: *unstage before stage
(it destroys nothing), stage-whole-file before stage-hunk, commit after both, pull last and never
automatic.* Every milestone in §6 is that sentence expanded.

**DEC-003's own consequence anticipated this**: staging "requires a correct and trusted hunk model,
which is precisely what version one establishes". That model now exists — the byte partition,
INV-1 reconstruction, INV-2 containment and the independent canonical diff. **Staging is the first
feature in this product that gets to spend it**: writing exactly the bytes the interface claimed
were in a hunk is a checkable claim here in a way it is not in any other diff tool.

---

## 2. GitHub Desktop, as studied

Sources: the product documentation (Committing and reviewing changes; Managing branches; Managing
worktrees; Stashing changes; Syncing your branch; the ten commit-management articles; the keyboard
shortcut table). Labels below are quoted from it.

### 2.1 The anatomy

Four regions, and diffscope already has three of them:

1. **Toolbar of three controls** — *Current Repository*, *Current Branch*, and one sync button that
   changes its own label: **"Fetch origin"** → **"Pull origin"** / **"Push origin"**, with the
   ahead/behind count beside it. One button, three states, never two buttons disagreeing.
2. **Left column, two tabs** — *Changes* (⌘1) and *History* (⌘2). diffscope's left column is two
   *lists* (repositories, changed files) rather than two tabs, and its History is a lens.
3. **The commit box**, pinned to the bottom of the Changes list: avatar, **Summary** field,
   **Description** field, a co-author control in the corner of the description, and one wide button
   reading **"Commit to BRANCH"**. ⌘G jumps to the summary, ⌘⏎ commits.
4. **The diff**, right of the list, with a gear control carrying *Unified* / *Split* and *Hide
   Whitespace Changes*.

### 2.2 The one idea worth stealing, and the one worth refusing

**Steal: there is no visible index.** Each changed file carries a **checkbox**; the checkbox at the
top toggles all; Space toggles the highlighted rows. Inside a file, changed lines are highlighted
and you **click a line to remove it from the commit** — "click one or more changed lines so the
blue disappears". Staging is not a verb the user performs. It happens at commit time, and the
mental model is *what goes in this commit*, which is the question a person actually has.

**Refuse: the index does not stop existing because a UI hides it.** Anything else on the machine —
WebStorm, the terminal in our own drawer, a hook — can stage, and then the checkbox model is
lying about a state it did not author. diffscope's DEC-008 already draws unstaged-vs-index and
staged-vs-HEAD as two of its four scopes, so this product has the opposite starting point: **the
index is already on screen and already comprehensible.** §7 OQ-A asks the owner to choose; §4
recommends the hybrid.

### 2.3 What GitHub Desktop has that lazygit does not

Line-level *deselection* inside a diff; a commit box with real description and co-author fields;
drag-a-commit-onto-a-branch cherry-pick; drag-to-reorder and drag-to-squash without ever showing a
rebase todo list; **"New Worktree…"** with a worktree dropdown grouped into main and linked;
branch-switch prompting **"Leave my changes on CURRENT-BRANCH"** vs **"Bring my changes to
NEW-BRANCH"**; **"Force push origin"** appearing by itself after a rebase.

### 2.4 What GitHub Desktop refuses, and what it costs

- **No interactive rebase surface.** Reorder and squash are gestures; there is no todo list, no
  `edit`, no `exec`, no reword-in-place beyond amend.
- **No bisect. No reflog. No custom commands. No commit graph** — History is a flat list.
- **One stash per repository**: "you can only stash one set of changes at a time".
- **Conflicts are handed off**: "Resolve any merge conflicts in your preferred way, using a text
  editor, the command line, or another tool." The application only blocks the merge button and
  counts the conflicted files.

lazygit is the mirror image: everything above, and no commit description field worth the name.
**The owner asked for both**, which is the union — and the union is genuinely bigger than either
product, so §6 sequences it rather than pretending it is one milestone.

---

## 3. The inventory

Every operation, its plumbing, and its risk class. **Risk classes:** `A` additive (nothing existing
is lost, undo is trivial), `B` recoverable (undo needs a recorded restore point), `C` destructive
(data can leave the repository), `N` network.

### T1 — Working tree and index

| Operation | Plumbing | Risk |
|---|---|---|
| Unstage file / all | `restore --staged --` (`reset -q HEAD --` on unborn HEAD) | A |
| Stage file / all | `add --` | A |
| Stage / unstage **hunk** | patch built from *our* partition → `apply --cached [-R] --unidiff-zero` | A |
| Stage / unstage **lines** | same, from the line selection | A |
| Untracked file made hunk-addressable | `add -N` before the first patch | A |
| Discard file / hunk / lines | `restore --worktree` / `apply -R`; **untracked files go to the Trash, never `rm`** | C |
| Add to `.gitignore` | append to a repository file — the first write outside `.git` | B |
| Stash push (all / staged / keep-index / include-untracked) | `stash push` | B |
| Stash list / show / apply / pop / drop | `stash list`, `stash show -p`, `apply`, `pop`, `drop` | B / C on drop |
| Conflicts: list, take ours / theirs, mark resolved, abort | `ls-files -u`, `checkout --ours/--theirs`, `add`, `merge --abort` | B |

### T2 — Commit

| Operation | Plumbing | Risk |
|---|---|---|
| Commit summary + description | `commit -m -m` (message via file, never argv, so anything can be in it) | A |
| **Empty commit** (asked for by name) | `commit --allow-empty` | A |
| Co-author trailers | appended to the message body | A |
| Amend last commit (message and/or content) | `commit --amend` | B |
| Undo last commit | `reset --soft HEAD~1` | B |
| Reset to a commit — soft / mixed / hard | `reset --soft/--mixed/--hard` | B / **C** on hard |
| Revert a commit | `revert` | A (makes a commit) |
| Check out a commit (detached HEAD) | `checkout --detach` | B |
| Cherry-pick | `cherry-pick` | B |
| Tags: create, delete, push | `tag`, `tag -d`, `push --tags` | A / C / N |
| Hooks run and their output is shown | the user's own `pre-commit`, `commit-msg` | — |

### T3 — History rewriting

| Operation | Plumbing | Risk |
|---|---|---|
| Reorder commits | `rebase --onto` with a generated todo, `GIT_SEQUENCE_EDITOR` | C |
| Squash / fixup / drop / reword | same | C |
| Amend an **old** commit | `commit --fixup=<sha>` + `rebase --autosquash` | C |
| Interactive rebase as a visible todo list (lazygit) | same machinery, todo shown and edited in-app | C |
| Continue / skip / abort | `rebase --continue/--skip/--abort` | B |

### T4 — Branches, graph, worktrees

| Operation | Plumbing | Risk |
|---|---|---|
| Branch list, filter, checkout | `branch --format`, `checkout` | B |
| Create from HEAD or from any commit | `branch`, `checkout -b` | A |
| Rename, delete local, delete remote | `branch -m`, `-d/-D`, `push --delete` | B / C / N |
| Merge into current, squash-merge | `merge`, `merge --squash` | B |
| Rebase current onto | `rebase` | C |
| **Commit graph with topology** | `log --graph --format` parsed to lanes, drawn in the History lens | read |
| Reflog | `reflog --date=iso` | read |
| Bisect: start / good / bad / skip / reset, with a persistent state banner | `bisect …` | B |
| Worktrees: list, add, switch, remove | `worktree list --porcelain`, `add`, `remove` | A / C |
| Submodules | — | **deferred**, OQ-014/OQ-015 |

### T5 — Remote (only if §7 OQ-B is answered *yes*)

| Operation | Plumbing | Risk |
|---|---|---|
| Fetch | `fetch --prune` | N |
| Pull — merge or rebase, chosen explicitly | `pull --no-rebase` / `--rebase` | N + B |
| Push, publish branch, set upstream | `push -u` | N |
| Force push | **`push --force-with-lease` only**, never `--force` | N + C |
| Remotes: list, add, change URL | `remote` | B |
| **Credentials** | git's own credential helper. The application never renders a password field and never stores a token | — |
| Pull requests, checks, notifications | — | **out**: needs the GitHub API and an account model. "Open on GitHub" in the browser instead |

### T6 — Power

| Operation | Shape |
|---|---|
| Custom commands bound to keys, with context tokens (`{repo}`, `{branch}`, `{file}`, `{sha}`) | **Executed in the terminal drawer**, never invisibly. DEC-053's surface already exists, the output is already legible, and this way there is no second execution path to audit |
| Filter / search in every list | Extends the existing ⌘F. Repositories, files, branches, commits, stashes |
| A **command record** — every write the application performed, with its exact argv | New, and this product's own idea. It is what makes "it wrote what it showed" checkable *by the user* and not only by the suite |

---

## 4. Where each of these lands in the window

The chrome that exists — repositories list, changed-files list, diff pane, status line, terminal
drawer, three collapses (DEC-060) — takes almost all of this without a new region.

**The changed-files list becomes the Changes tab.** A checkbox column at the leading edge, Space to
toggle the selected rows, one checkbox in the list header. A **Stashed changes** row under the file
list with **Restore** and **Discard**, exactly where GitHub Desktop puts it — but plural, because
`git stash` is a stack and hiding that is a lie of the same family as §2.2.

**The commit box is pinned under it**: summary field, description field, co-author control, and one
wide button reading **Commit to `<branch>`**. ⌘G to the summary, ⌘⏎ to commit — the two GitHub
Desktop bindings that are worth keeping verbatim, and neither collides with the existing map
(DEC-065 owns ⌘⏎ for *open in editor*; **that collision is real and is resolved in favour of
commit when the commit box has focus**, which is exactly GitHub Desktop's own rule).

**The recommended staging model (OQ-A) is the hybrid**: the checkbox is *include in this commit*,
implemented as a **real index write**, and the four scope pills stay where they are so the user can
always see what the checkbox did. GitHub Desktop's clarity, without GitHub Desktop's lie — and it
costs nothing, because DEC-008 built the scopes already.

**The diff pane grows selection.** The sign column already exists per DEC-059 and becomes the
target: click a line to include or exclude it, drag or ⇧-click for a run, a per-hunk control in the
hunk header. Staged and unstaged bytes must be **visually distinguishable inside one file**, which
is the one genuinely new drawing problem in this plan and needs the design contract's greyscale
rule applied to it (a tint alone will not do).

**The status line takes the toolbar.** A branch control (list, filter, create, rename, delete,
checkout), a sync control with GitHub Desktop's one-button-three-states behaviour, and — when one
is running — a **state banner** for rebase / merge / bisect / detached HEAD, with *Continue*,
*Skip*, *Abort* on it. A repository in a mid-operation state is the single most confusing thing a
git GUI can hide, and the banner is why lazygit users trust lazygit.

**The History lens becomes the commit list with a graph column**, per-commit context actions
(checkout, revert, reset, cherry-pick, tag, create branch, amend-with-fixup), drag to reorder and
drag onto a branch to cherry-pick. **This fires DEC-061's own revisit trigger** — a graph and a
filter make History the second interface DEC-008 refused — so it needs a decision entry, not a
commit.

**The terminal drawer stays exactly as it is**, and gains the custom-command surface and the
command record.

**Every function needs a keyboard row.** DEC-016 says a function reachable only by pointer is a
defect, and `KeyboardMap` is data checked against the coverage table — so each operation above adds
a row there before it adds a button.

---

## 5. The proof machinery — what replaces R-8

R-8 today runs every registered operation against a scratch repository and asserts `.git` is
byte-identical before and after. That proof does not survive a write path, and **the point of this
section is that it splits rather than weakens.**

1. **Two registries.** `GitOperation.allProvenReadOnly` keeps its proof, unchanged, and keeps
   `--no-optional-locks` and `GIT_OPTIONAL_LOCKS=0`. A second registry, `allProvenWriting`, holds
   every write, each declaring its risk class from §3. A git invocation from neither registry still
   fails the suite — the closed-registry property is the thing this product has that other clients
   do not, and it must survive.
2. **A separate runner.** Writes go through their own type. It does *not* pass the read-only flags,
   it handles `index.lock` contention explicitly instead of pretending it cannot happen, it sets
   `GIT_EDITOR` and `GIT_SEQUENCE_EDITOR` to values that can never open an interactive editor, and
   it keeps `GIT_TERMINAL_PROMPT=0` so nothing can ever block on an invisible prompt.
3. **R-8b — "it wrote exactly what was shown".** New, and the reason DEC-003 sequenced staging
   after the engine. For a staging operation the check builds the patch from the partition, applies
   it, and then asserts that `diff --cached` differs from the pre-state by **exactly the selected
   byte ranges and nothing else**. This becomes **INV-6**, stated over bytes like the other five.
4. **Restore points.** Every class-B and class-C operation records HEAD, the index tree and, where
   the working tree is at risk, a stash — before it runs. That is lazygit's ⌃Z with a real
   mechanism under it. `reflog` is the backstop, and is surfaced in the UI as *the safety net*
   rather than as a power feature.
5. **Confirmation is proportional, and is a rule rather than a habit.** Class A commits silently;
   class B is undoable and says so in the status line; class C requires an explicit confirmation
   naming what is lost, and force-push requires typing the branch name.
6. **Concurrency stops being avoidable.** DEC-003 dodged index races by not writing. After a write:
   re-run the status sweep, invalidate the pinned pair (DEC-049) with the anchor machinery, and
   treat a lock held by WebStorm as a first-class reported state rather than an error string.
7. **The read-only wording checks change shape.** `DesignChecks`'s retired-phrase list currently
   catches documents claiming the application cannot write. After this, the true sentence is
   different again — *it writes only what you asked for, and it shows you the command it ran* — and
   the check has to hold the new sentence with the same negative control discipline.

---

## 6. Milestones

Each is a shippable state, each ends with `swift build` and `swift run diffscope-verify` green, and
each gets its own decision entry before its code.

| # | Milestone | Contents | Gate |
|---|---|---|---|
| **M11** | **The write foundation** | Second registry, write runner, restore points, confirmation classes, post-write refresh, command record. **Unstage, stage whole file, discard file.** | R-8 split; R-8b for whole-file staging; a lock-contention case that reports rather than throws |
| **M12** | **Hunk and line staging, and the commit** | Patch synthesis from the partition; selection in the sign column; the commit box; empty commit; amend; undo commit; hooks' output surfaced | **INV-6** over the fixture corpus; a fixture whose selection straddles CRLF, a BOM and a `\ No newline at end of file` |
| **M13** | **Branches, stashes, conflicts** | Branch control, create/rename/delete/checkout, switch-with-changes prompt, stash stack, conflict list with take-ours/theirs/abort, state banner | A repository left mid-merge is legible and recoverable from the banner alone |
| **M14** | **History that can act** | Graph column, reflog, revert, reset (three kinds), checkout commit, cherry-pick, tags. Fires DEC-061's revisit trigger | Graph lanes verified against `log --graph` on the fixture repositories |
| **M15** | **Rewriting** | Interactive rebase with a visible todo, reorder, squash, fixup, drop, reword, amend-old, continue/skip/abort | Every rewrite is reachable *backwards* from a restore point in one action |
| **M16** | **Remote** | Fetch, pull (merge or rebase, chosen), push, publish, upstream, force-with-lease. Reverses DEC-011 | Nothing on any automatic path touches the network; the suite proves it the way R-8 proves the read path |
| **M17** | **The rest of lazygit** | Bisect with its banner, worktrees, custom commands in the drawer, filter in every list | Bisect state survives a relaunch |

**M11 and M12 are the product.** Everything from M13 down is reachable today by typing in the
drawer; staging a line by hand is not.

---

## 7. What only the owner can answer

- **OQ-A — the staging model.** Hybrid (recommended, §4): checkboxes *and* the visible index.
  Alternative: GitHub Desktop's model exactly, index hidden, scopes reduced to two.
- **OQ-B — is the network in scope at all?** Fetch, pull and push reverse DEC-011. Recommendation:
  yes, but last (M16), and never automatic — DEC-011's actual reasoning was staleness and silence,
  both of which survive a user-initiated button.
- **OQ-C — rewriting pushed history.** Force-push-with-lease behind a typed confirmation, or refuse
  history rewriting on any branch with an upstream? Recommendation: allow, with the lease and the
  typed branch name.
- **OQ-D — conflicts.** Hand off to the editor as GitHub Desktop does (cheap, honest, M13), or
  build a three-way merge surface (a milestone of its own)? Recommendation: hand off first.
- **OQ-E — does read-only survive as a mode?** A per-repository *review only* lock would keep
  DEC-003's guarantee available for repositories the owner does not want touched. Cheap to build
  now, impossible to retrofit credibly later.

---

## 8. The honest summary of size

Version one is 24,000 lines of Swift and 1,832 checks, and it reads. **This plan is comparable in
size to it** — M11–M12 alone rebuild the trust apparatus for a direction it was never pointed in.
The sequencing in §6 exists so that value arrives at M12 rather than at M17, and so that the
product is never in a state where it can write but cannot prove what it wrote.
