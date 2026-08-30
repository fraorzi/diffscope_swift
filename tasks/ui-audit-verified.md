# UI audit — verified findings (plan phase 3)

Candidates from `ui-audit-candidates.md`, checked against the code. Labels:
**CONFIRMED** (found, with `file:line` and a reproduction) · **NEEDS-MEASUREMENT** (code located,
outcome depends on a runtime number) · **REFUTED** (the code does something else — quoted, so the
idea does not come back next session) · **DUPLICATE** (already in the plan's 31).

---

## CONFIRMED

### V-1 · Half the chrome never refreshes on the watcher path (from C5.3)

`refreshGitState()` (`Sources/diffscope-app/GitActions.swift:24`) is the **only** writer of
`state.branches` (`:31`), `state.stashes` (`:32`), `state.operation` (`:34`),
`operationBanner.show` (`:36`), `commitBox.branchName` (`:38`) and `branchButton.title` (`:40`).

It has exactly two callers:

- `main.swift:6484` — a repository **row selection change**
- `GitActions.swift:993` — `afterWrite()`, i.e. **the app's own writes**

The FSEvents path does not reach it. `handle(.changed)` calls `reloadFiles()` and
`refreshCurrentFile()` and nothing else. `applicationDidBecomeActive` → `rescan()` only reaches it
by accident — via `selectRowIndexes` firing the table delegate — and only when the selected
repository's **row index** changed; a sweep that returns the same repositories in the same order
fires no delegate call and refreshes no git state.

**Reproduction.** Open a file. In the terminal drawer type `git checkout other-branch`. FSEvents
fires, so the file list and the diff rebuild against the new branch — while the branch button, the
commit box's branch name and the operation banner keep naming the old one. Start a rebase in the
drawer and the conflict banner never appears at all.

This is worse than a stale label: the file list beside it is correct, so the two halves of the
window disagree with nothing marking which one to believe.

### V-2 · REFUTED half of the same candidate, recorded so it does not return

C5.3's sibling claim — C5.1, *"only the all-repositories sweep advances the refreshed-N-ago
caption"* — is **false**. `markRefreshed()` is called from the sweep completion
(`main.swift:4538`) **and** from `reloadFiles()` (`main.swift:5907`), so a file-system-driven
refresh does advance it. The caption is honest about the comparison; the chrome above it is not.
