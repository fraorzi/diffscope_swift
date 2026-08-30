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
