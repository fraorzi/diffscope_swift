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

---

## Run A — verified (6 confirmed · 1 needs-measurement · 18 refuted · 5 duplicate)

### V-3 · **The unified layout's place-keeping reads the two panes it just emptied** (A5.1) — the root

`applyLayout`'s unified branch empties both split panes (`Renderer/src/main.js:807-808`):

```js
applySide(left, empty);
applySide(right, empty);
```

Every place-keeping function in the renderer reads **only** `left`/`right`:

| Function | Line | Reads |
|---|---|---|
| `diffscopeAnchorState` | `main.js:1227-1234` | `left.scrollDOM.scrollTop`, `left.coordsAtPos`, `left.lineBlockAt` |
| `diffscopeCurrentLine` | `main.js:1347-1354` | `right.state.doc`, `right.scrollDOM.scrollTop` |
| `restoreAnchor` | `main.js:1361` | `[[left, …], [right, …]]` |
| `firstVisibleStop` | `main.js:1372-1373` | `right` |
| `goToStop` | `main.js:1205` | dispatches `scrollIntoView` at `left`/`right` only |

**Unified is the launch default and the shell sets it** — `main.swift:997-999` sends
`diffscopeSetLayout("unified")` because `sideBySide = false` (`main.swift:209`). So this is not an
edge case; it is the path every reader is on unless they press ⌥⌘→.

Three consequences, all of them things the owner would experience as "it loses my place":

- **Every save returns the reader to the top.** `refreshCurrentFile` (`main.swift:5936`) asks for
  `diffscopeAnchorState()`; with `left` empty every candidate clamps to offset 0, so the answer is
  the top of the file. `restoreAnchor` then scrolls two invisible empty views and never touches the
  unified pane.
- **⌘⏎ always opens the editor at line 1.** `right.state.doc.length === 0`, so
  `doc.lineAt(0).number` is 1 for every file, in every position.
- **⌘↓ / ⌘↑ move nothing.** `stopIndex` advances, folds open, decorations rebuild, the status line
  prints "n of m" — and the pane does not move. Found while checking A5.1; a separate call site
  from the two the candidate named.

### V-4 · Line staging writes against a comparison that is not on screen (A5.6)

`main.js:585-588` posts a bare line number. `GitActions.swift:213-214` then re-reads a **different
scope** from the one being displayed:

```swift
let scope: ComparisonScope = unstage ? .stagedVsHead : .unstagedVsIndex
guard let pair = try? scopes.pinnedPair(for: file, scope: scope, in: repository.url) else { return }
```

The default scope is `.allLocalVsHead` (`main.swift:29`), so in the default view the old side on
screen is HEAD while the patch is built against the index. Worse than the candidate claimed, and it
composes with known findings #16/#17 into a write against the wrong file.

### V-5 · The footer's counts and its Expand button read different state (A5.3)

`updateFooter` (`main.js:1443-1447`) computes hidden and rewrapped totals from the model and never
consults `expanded` / `expandedReflows`. It is called from three places (`:698`, `:1411`, `:1699`)
and from **none** of `goToStop` (`:1199`, which opens folds at `:1211`), `expandFold` (`:1176`) or
`expandReflow` (`:1191`).

The destructive half: open two folds by clicking. The label still says **Expand**, but `allOpen` is
now true, so pressing it takes the `expandAll` branch at `:1404-1405` and does
`expanded = new Set(); expandedReflows = new Set();` — slamming shut everything the reader opened.

### V-6 · The reciprocal scroll guard is cleared before the echo arrives (A5.2, A2.3)

`main.js:675-684` sets `syncing = true`, assigns the follower's `scrollTop`, then clears it — but
scroll events are queued, not dispatched synchronously, so the follower's handler always runs with
`syncing === false` and writes back. Harmless while the values agree; not harmless when the
follower clamps. DEC-115's reflow folds are old-side-only (`reflowFolds`, `main.js:1639`), so the
left document is genuinely shorter.

### V-7 · The notice chip skips the re-measure every other height change gets (A5.4, A2.5)

`main.js:1599-1603` is the whole handler: toggle the flag, re-render the bar. No `requestMeasure`,
no `applyLayout`. Compare the render path, which sequences this deliberately and explains why at
`:1694-1698`. The candidate's second half — "numbers drift from their rows" — is **not** supported:
CodeMirror's own `ResizeObserver` on `scrollDOM` re-measures in a visible window.

### V-8 · Split panes are never row-aligned (A1.5, A3.2, A4.3)

`main.js:679-680` is a raw pixel copy of `scrollTop`/`scrollLeft`. The panes hold two different
documents with no padding, spacer widget or alignment machinery; the engine's alignment reaches
them only at discrete jumps. The file's own comment concedes it at `:1197-1198`.

### V-9 · NEEDS-MEASUREMENT — backing-scale change on display migration (A4.1)

The premise is code-true: nothing observes it. No `windowDidChangeBackingProperties`, no
`didChangeScreen` anywhere in `Sources/diffscope-app/`, and `diffscopeSettle()` is invoked from one
place (the snapshot path, `main.swift:3865`) plus `diffscopeSetWrap`. **To settle it:** drag the
window between a Retina and a non-Retina display and call `window.diffscopeSettle()` — a
non-identity `before→after` pair means the metrics were stale with nothing to correct them.

### Two more found while checking, outside the candidate list

- **The footer is drawn *above* the diff in unified.** DOM order at `index.html:416-421` is
  `#stage`, `#diff-footer`, `#unified`; with `#stage` hidden the fold bar sits between the notice
  bar and the code.
- **Change navigation silently disappears on large files.** `Navigation.swift:73-76` guards on
  `case let .exact(hunks)`, so a budget-exceeded byte diff yields an empty `stops` array,
  `goToStop` returns `null`, and nothing says navigation is unavailable. The one silent degradation
  found in the diff pane — and it is the true version of what two refuted candidates were circling.

### Notable refutations, so they do not come back

- **A1.1** gutter widening at line 9,999 — CodeMirror sizes the gutter from a whole-document
  spacer (`@codemirror/view` `initialSpacer`/`maxLineNumber`); width is constant for the scroll.
- **A1.2** change-density ribbon — no such control exists; DEC-086 removed it (`main.js:686-690`).
- **A1.3 / A1.6** silent bail and truncation — the fallback is labelled and counted
  (`TrivialPartition.swift:54-56`, `Contract.swift:257`), and nothing truncates the document.
- **A3.1** no sequence number on mode switch — `renderQueue` is serial (`main.swift:112`) and there
  is a newest-wins guard at `:6000`.
- **A3.3** stop ordinals differ per mode — `Navigation.swift:72-77` computes them from the raw byte
  pair, identical in every mode and layout.
- **A3.6** editors rebuilt per switch — `left`/`right` are module singletons, `unified` is built
  once, `link` runs once at module scope.
- **A5.5** `expandedReflows` leaking across files — the reset is per **pinned content pair**, not
  per comparison (`Scopes.swift:446-447`), so walking a directory does reset it. Residual: two
  files with byte-identical old *and* new sides share a pin.

---

## Run D — verified (20 confirmed · 10 refuted). Several were **reproduced**, not just read.

### V-10 · **Pipe deadlock on a noisy hook** (D4.1) — the worst thing in the audit

`Sources/DiffScopeGit/GitWrite.swift:556-557`, identically `GitRunner.swift:320-321`:

```swift
let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
```

Strictly sequential drain, on the calling thread, no readability handler. stdout reaches EOF only
when git **and every child** exit; a hook blocked writing into a full stderr pipe never exits.

**Reproduced.** Scratch repo, `pre-commit` writing ~200 KB to stderr and exiting 0, driven by a
harness copying `invoke`'s exact sequence: **still running after 40 s, killed.** Swap the read order
or drain concurrently and it completes instantly.

`perform` calls this **synchronously on the main thread** (`GitActions.swift:963-967`), so the
window is frozen, not merely slow — exit only by quitting. Any `eslint` / `lint-staged` report over
the pipe buffer (16–64 KB) on stderr triggers it.

### V-11 · **An INV-6 violation: a byte nobody selected is destroyed** (D2.4)

`StagingPatch.swift:291-294` re-emits an *unselected* removal as context carrying
`old.isUnterminated(oldIndex)`, and `:357-359` then writes `\ No newline at end of file` after it —
even when `+` lines follow in the same hunk.

**Reproduced.** Index holds `"alpha\nbeta"` (no trailing newline); worktree
`"alpha\nbeta\ngamma\n"`; the reader selects only `gamma`:

```
@@ -1,2 +1,3 @@
 alpha
 beta
\ No newline at end of file
+gamma
```

git **accepts** it (exit 0) and the index becomes `alpha\nbetagamma\n` — two lines merged, a byte
nobody selected destroyed. `applySelection` says the answer is `alpha\nbeta\ngamma\n`.

The existing INV-6 edge arm (`WriteChecks.swift:132-148`) selects *every* change, which is the one
selection that happens to be well-formed, so it passes.

### V-12 · Line staging and file staging commit different bytes (D2.3)

File staging is `git add` (`GitWrite.swift:41`); line staging is `git apply --cached` fed patch
bytes built from the raw index blob and the **raw worktree file** (`Scopes.swift:342-345`), so no
clean filter runs on either side.

**Reproduced.** `core.autocrlf=input`, CRLF worktree file, one line edited:

| Path | Index bytes |
|---|---|
| `git add f.txt` | `61 0a 42 0a 63 0a` (LF) |
| diffscope line staging | `61 0d 0a 42 0d 0a 63 0d 0a` (CRLF) |

**INV-6 is blind to it.** `makeRepository` (`GitChecks.swift:39-46`) sets only `user.email` and
`user.name` — no `core.autocrlf`, no `.gitattributes`, no clean/smudge driver — and the `crlf.txt`
arm compares two filter-free paths against each other. *Correction to the candidate:* the checkbox
does not stick at partial; git reports `M ` (fully staged). The lie is in the committed bytes.

### V-13 · Stage-hunk always stages the **first** hunk in the default layout (D2.5)

Same root as V-3. `diffscopeCurrentLine` (`main.js:1346-1354`) reads the split right pane, which
unified empties, so it returns **1 unconditionally**. `stageHunk` (`GitActions.swift:181-194`) feeds
that to `hunkSelection(walk:aroundNewLine:)`, whose nearest-run rule (`StagingPatch.swift:220-229`)
picks the first hunk and reports `"stage hunk — done"` naming nothing.

*The candidate's stated mechanism is refuted:* in **split** layout it is correct — folds are
`Decoration.replace`, not text deletion, so displayed row equals new-side line. The bug is the
layout, not the addressing.

### V-14 · Hooks inherit five scrubbed environment variables (D4.6)

`GitWrite.swift:532-538` sets `GIT_TERMINAL_PROMPT=0`, `GIT_CONFIG_NOSYSTEM=1`, `GIT_EDITOR=true`,
`GIT_SEQUENCE_EDITOR=true`, `GIT_PAGER=cat` — all inherited by every hook. DEC-114's comment two
lines above addresses **PATH only**; the other five were never revisited. The same commit passes
typed in the drawer and fails from the menu, reported faithfully as git's own words.

### V-15 · `--cleanup=strip` silently deletes `#` body lines, then the box is cleared (D4.5)

`GitWrite.swift:87` uses `--cleanup=strip`; the box is cleared on success at `GitActions.swift:263`.
**Reproduced:** a body containing `#1234 is the ticket` loses that line entirely, and the only copy
is gone. Issue references written `#123` are the common form.

### V-16 · A line click stages against a comparison that is not on screen (D2.1, = V-4)

Confirmed with one correction: **additions are safe**, because `.allLocalVsHead` and
`.unstagedVsIndex` share the same new side (the worktree). **Removals are not** — the sign column
posts `-oldLine` in HEAD's numbering (`main.js:585-586`) and `stageSelection` resolves it against
the index's numbering (`GitActions.swift:227`). In the default combined scope a click can only ever
mean stage (`main.swift:5604`).

### V-17 · The repository snapshot is never refreshed in place (D3.2, sharpens V-1)

`main.swift:4549-4555` re-selects the row only `if self.repoTable.selectedRow != row`. When the open
repository is already at that row — the normal case — the delegate never fires and
`state.selectedRepository` keeps the **old** snapshot with its old head, base and counts. So scope
availability (`main.swift:5822-5831`, computed from `repository.head`) drifts too, not just the
branch button.

### Also confirmed (D)

| # | Finding | Where |
|---|---|---|
| D5.4 | "done" attests to an exit code, not an effect; `RestorePoint` is returned and discarded with `_ =`, and **no restore affordance exists anywhere in the app** | `GitActions.swift:966`, `:260` |
| D5.3 | Every read collapses failure into emptiness — branches, stashes, conflicts, headSha, commitMessage — and reads never enter the record shown under "What DiffScope Ran" | `RepositoryState.swift:147,155,220,353,358` |
| D1.4 | A failed `changedFiles` is indistinguishable from a clean tree; full reload, selection dropped, empty-scope sentence | `main.swift:5850`, `Scopes.swift:199` |
| D5.6 | A saved command sends `force: true`, skipping all three guard terms, into whatever is running in the drawer | `GitActions.swift:918,922` |
| D2.2 | A line click that resolves to nothing returns bare — the keyboard route two dozen lines up does say so | `GitActions.swift:231`, cf. `:198` |
| D3.1 | Base override keyed by repository path, not branch | `main.swift:4675-4677` |
| D3.3 | The branch menu's current-branch exclusion is computed from a stale list; git refuses, and the `catch` asks the **wrong** second question and runs `-D` | `GitActions.swift:390`, `:412-418` |
| D3.5 | `pickedCommits` / `historyPair` cleared only on scope change — not on checkout, not on repository change | `main.swift:61-62`, `:5070`, `:4898` |
| D4.2 | The lock classifier is a substring test (`"Unable to create"` + `".lock"`) and **replays** the write; a `pre-commit` with side effects runs twice | `GitWrite.swift:518-520`, `:479-483` |
| D4.3 | stderr wins even when it carries only a runner's exit line, discarding the whole stdout report | `GitWrite.swift:503-504` |
| D5.5 | `trashItem` and `terminal.type` never enter the record titled "What DiffScope Ran" | `WriteActions.swift:97`, `GitActions.swift:918` |

### Notable refutations (D)

- **D1.1 echo-off passphrase** — "nothing typed" is **not** read from the visible buffer;
  `typedLine` comes from the app's own input field and the first guard term requires `mode ==
  .local`, which requires an OSC 133 prompt mark. During `ssh` the shell is `.programRunning` →
  refused. The real hole is `force: true`, which is D5.6.
- **D1.2 OSC 7 re-scopes the repository** — it does not; `onDirectoryChange` publishes a chip and a
  divergence flag, both drawer-local. No cd-back loop exists.
- **D1.3 amend produces no events** — `.git` is inside the watched root and is never excluded, and
  T3-A measured the signal at ~440 ms. The stale-header residue is real but is D3.2/D3.5.
- **D1.5 `add -p` answers land in the file table** — nothing re-focuses a view on refresh, and
  during `add -p` the session is `.programRunning`, so keystrokes go raw to the PTY.
- **D5.1 / D5.2 / D3.4 restore points and the shared stash stack** — all unreachable.
  `stashWorktree` defaults to `false` and no production caller overrides it; `RestorePoint` has no
  consumer; `Confirmation.required(for:)` has **zero call sites**. Two genuine latent bugs sit
  inside `capture` (`WriteActions.swift:45`, `:52`) but nothing arms them. *Side note found here:*
  `capture` still runs a real `git write-tree` on every commit, writing tree objects nobody reads.
- **D3.6 two writers of the configuration file** — the sweep only reads `baseOverrides`, and
  `Configuration.save` writes `options: .atomic`. No losing write.
