# UI audit — divergent candidates (plan phase 2)

**Status: raw generator output. Nothing here is verified.** These came from isolated agents under
different cognitive frames, told explicitly *not* to cite file or line numbers because they had not
looked at the code. A guessed line number is worse than none. Every entry below is a hypothesis
until a verification pass labels it CONFIRMED / NEEDS-MEASUREMENT / REFUTED / DUPLICATE.

Frames that completed: A1–A5, B1–B4, C2–C4, D1. Frames pending: B5, C1, C5, D2, D3, D4, D5.

---

## Run A — the diff panes (webview)

### A1 · reader on a 50,000-line generated file
1. Gutter widens crossing line 9,999 → whole text body jumps sideways; with wrapping on, every visible long line re-wraps in the same frame and the tracked row slides. Scrolling back shrinks it and jumps back.
2. Change-density ribbon / scrollbar ticks placed in document-line space are a lie in a wrapped document; in a minified file hundreds of edits collapse onto one tick and clicking a mark scrolls to nothing.
3. Intra-line diff hits a cost guard inside a 200,000-character minified line, falls back to marking the whole line changed, **with no visible sign it bailed**. Precise on the next file, so the reader never learns which mode they are in.
4. Next-change scrolls the changed line's *first visual row* to the top, but the edited span is 40 wrapped rows further down, off screen. Reader presses again and is carried past the change without ever seeing it.
5. Split-pane sync by pixel offset drifts when the two sides wrap to different heights; thousands of rows down the panes show unrelated regions while the row bands still line up.
6. A size guard truncates the document but footer and notice bar keep describing the whole file. No end-of-truncation marker — the document just ends mid-line as if the file did.

### A2 · reader scrolled, folds open, selection active, autosave behind them
1. Selection restored by character offset survives the render but now covers a phrase the reader never selected; ⌘C returns the other text and the highlight looked continuous throughout.
2. Fold state restored by line index rather than by covered content: regions the reader opened come back collapsed, one they left folded is now open, and a placeholder's line count does not match what it hides.
3. Split layout, context expanded on one side only → the two panes are different heights, each scroll handler drives the other, the view shivers and settles a screenful away.
4. A sticky header naming the enclosing declaration computed from the pre-render snapshot announces a function the reader scrolled past minutes ago.
5. The notice bar sits in the vertical flow, so toggling a notice slides every line below it. No scroll event fires — the reader's line simply walks off the reading position, and back up on the next render.
6. The render swaps out the DOM subtree holding keyboard focus; focus falls to the shell, the next change-step keystroke moves the file-list selection instead, and ⌘C copies a filename.

### A3 · distrustful reader cross-checking modes and layouts
1. Rapid mode toggling: mode is set synchronously, content arrives over an async bridge with no request sequence number, so renders land out of order — the pill says Structural while the pane holds Raw.
2. Side-by-side pixel-locked sync pairs a deleted line opposite an unrelated added line once folds or wrapping differ; reader reads a rename as a rewrite.
3. Change-stop ordinals differ per mode because collapsed regions merge adjacent hunks in one projection and split them in another; "4 of 9" means two different things.
4. A whitespace-only / CRLF / reindent change shows as changed in one view and unchanged in another, with no statement that one projection normalises and the other shows bytes.
5. A truncation notice raised on the load path disappears on re-render while the truncation itself persists, and the footer count still comes from the pre-limit model.
6. Each mode/layout switch builds fresh editor instances, scroll listeners and bridge callbacks without tearing down the previous ones; the app punishes exactly the cross-checking behaviour, and a restart fixes it.

### A4 · saboteur: make the geometry wrong
1. Moving the window between displays of different backing scale fires no resize; cached character metrics go stale and line numbers drift progressively out of register down the document.
2. Plugging in a mouse, or setting scrollbars to "Always", changes content-box width with no resize event — tint stops short of the right edge, last character clipped.
3. Narrowing until a long line wraps on one side only invalidates cross-pane row alignment, which is recomputed from cached heights rather than remeasured.
4. Notice bar appearing or re-wrapping after the editor's height and scroll offset were captured shifts content by an unaccounted delta.
5. Light/dark appearance switch while occluded: the repaint is queued in an animation frame WebKit will not run, so the reader returns to dark text on dark background until they interact.
6. Toggling wrap on after scrolling right clamps content scrollLeft to zero without a scroll event, leaving a manually applied gutter offset stale — line numbers shifted left, unreachable because wrapping removed horizontal scroll.

### A5 · wild frame: the diff pane as a theatre stage
1. **In unified layout the place-keeper interrogates the two *split* panes, which unified deliberately empties.** It gets the honest answer "top of an empty document" and reports it as the reader's position — so every save returns them to the top, only in this layout. Same blindness makes "open at the line I'm looking at" hand the editor line 1.
2. Reciprocal pane scroll-following near the end of a file where one side is shorter: the shorter pane clamps, reports the clamped position back, and yanks the pane under the reader's pointer. The re-entrancy guard assumes the echo is instant; it arrives a beat later.
3. The footer keeps announcing folded line counts and an Expand label after next-change has silently opened those folds; pressing the button then slams shut everything the reader opened, because the command reads true state and the label read stale state.
4. Clicking the notice chip to expand it grows the strip above the diff *after* the editors were filled, skipping the re-measure that every other height-changing act is carefully sequenced before. Numbers drift from their rows and collapsing does not restore it.
5. Reflow-expansion memory is keyed by the block's ordinal position and reset only on comparison change, not on file change — so walking a directory opens blocks in later files that the reader never touched, and the set only grows.
6. Line-level staging sends a bare line number computed when the row was drawn, with no file, version or pin attached; between drawing and click the file can have been saved and re-pinned. The click is never wrong, only wrongly obeyed — and it is the one control in the pane that writes to the repository.

---

## Run B — the AppKit chrome

### B1 · reader with a 63-file tree, staging as they go
1. A collapsed folder's tri-state checkbox: first click is a no-op (mixed → mixed), second stages every file underneath including ones never opened, with no row visible to confirm what happened.
2. Fold state retained by row position rather than node identity: staging a file removes a row, and afterwards a different set of folders is collapsed.
3. Keyboard walk + stage: after every stage the first arrow press does nothing because focus was dropped by the table rebuild; the reader learns to double-tap and starts skipping files.
4. Flipping the scope pill twice quickly leaves the pill and the list disagreeing — the later-finishing load wins regardless of which click it belonged to.
5. Commit box loses its insertion point on each staging refresh; typed text lands mid-sentence, undo no longer reaches back, and the commit button's enablement is derived from a count captured before the operation completed.
6. Tree header count and comparison caption computed from the pre-filter file set and the scope in force when the pane was built; after staging they disagree with the rows below.

### B2 · keyboard-only reader
1. Arrow-walking the *repository* list fires a full git sweep and file-tree build per row passed through; a mouse user pays once, a keyboard user pays per row travelled.
2. Collapsing a pane whose focus ring is inside it takes focus with it — first responder is now a view with no window, and nothing on screen says where focus went.
3. Staging the selected file when it leaves scope drops selection to the top of the list; staging ten files down a tree costs fifty-five arrow presses.
4. A refresh regenerates the menu bar, which is also the keyboard dispatch table; keystrokes landing inside the rebuild window are dropped, indistinguishably from end-of-list.
5. A background refresh disables the segment currently holding first responder; the ring silently relocates and the next arrow key acts on a different surface.
6. The terminal drawer's focus policy is decided at construction rather than by an explicit enter/leave contract, so the boundary between app bindings and shell text is ambiguous in both directions.

### B3 · two monitors, window occluded, sleep and display changes
1. **WebContent process killed under memory pressure while occluded.** Chrome intact, both panes blank white — and the render dedupe skips redrawing because it believes that model is already on screen. Nothing observes web-view process termination.
2. Backing-scale change on display migration: metrics, gutter offsets, wrap column and image scaling all measured once at load, silently wrong afterwards.
3. Lid closed during an in-flight git write: the deadline is wall-clock and the poll is a repeating delay, so on wake the operation is declared dead on its first poll regardless of what git did. Banner and repository then disagree in the one place a wrong retry is destructive.
4. Undocking squeezes the window; AppKit-imposed pane widths are indistinguishable from a deliberate drag and get written down as the reader's preference, so the next launch on the big monitor opens with an invisible pane.
5. A repository on an unmounted volume reads as deleted rather than temporarily absent; per-repository UI memory keyed to a live entry is discarded and remounting gives back a repository that behaves as newly added.
6. Space switch / wake restores key window but not first responder; single-letter navigation keys land in the commit message field.

### B4 · reader constantly reshaping the window
1. Re-measure deferred behind a timer scheduled in the default run-loop mode never fires during event-tracking, so a slow drag is one frozen frame that snaps at mouse-up.
2. Geometry read out of the web view asynchronously and written back natively: under continuous resize several queries are in flight, replies arrive out of order, and an old measurement is applied to a newer layout. No generation token on the geometry path.
3. Shrinking below the point where three pane minimums are satisfiable makes the constraint set unsatisfiable; the broken constraint is removed permanently and divider behaviour is wrong for the rest of the session.
4. A collapsed pane's zero-width frame still participates in proportional redistribution on container resize, so the collapse flag and the geometry drift apart.
5. Full-screen transition moves the window to another Space; the web view is treated as occluded, compositing layers are discarded, and the diff blanks for a beat while the native panes do not — so it reads as a diff-loading problem.
6. **Dragging a divider with the drawer open pushes a new column count to the PTY on every intermediate frame**; the shell repaints, and whatever watches terminal activity to trigger a refresh cannot distinguish repaint noise from a command finishing. A geometry gesture crosses into the data-refresh path.

---

## Run C — the refresh path and performance

### C2 · reader halfway through an interactive rebase with conflicts
1. **The app's own reads write.** Running the changed-file listing and staging read refreshes git's index stat cache, which lands as a filesystem event inside the watched tree, which re-arms the debounce. The observer is part of the observed system and quiet is never reached; the 2 s cap turns it into a steady heartbeat.
2. A git invocation failing mid-refresh (index.lock, unresolvable HEAD, a ref being rewritten) is absorbed and the previous result stays on screen with nothing marking it stale. A no-op refresh is indistinguishable from a fresh one.
3. A scope that becomes impossible while selected is greyed with a reason **while its last output stays on screen and remains scrollable, openable and stageable**. The window argues with itself in two adjacent regions.
4. The base commit is remembered by the name it resolved from, not the object it resolved to; every pick rewrites the tip, and the diff goes on computing cleanly against a commit no ref reaches.
5. An unmerged path is legitimately both staged and unstaged; a model with one state per path shows it in one section while the totals count it in both, so the header exceeds the number of visible rows.
6. The staging control on a conflicted file is drawn as a two-way toggle but the action is one-way — staging collapses the stages and the reverse cannot restore them, while the interface reports the file as returned to its prior condition.

### C3 · external tool rewrites 200 files
1. Two annotation sweeps overlap; the older is never cancelled and keeps writing per-file results computed against a repository state that no longer exists, interleaved with current ones.
2. A refresh fired by the debounce cap runs git against a half-rewritten tree, and events landing during the git run are treated as belonging to the batch just serviced, so no follow-up is scheduled. The torn snapshot becomes the resting state.
3. A formatter turns a small diff into a whole-file rewrite; nothing caps how much the renderer will materialise in one go and nothing lets the queued newer refresh interrupt it, so the reader pays an unbounded cost twice with no chance to scroll away.
4. The change-stop baseline is advanced by refreshes the reader never looked at; changes introduced by the first pass are recorded as seen though they were replaced before being displayed for a frame.
5. `node_modules` exclusion matched too narrowly to survive nested packages, formatter cache files and atomic-write temporaries; the tree grows rows for files that no longer exist and the failure is memoised against a path never seen again.
6. A serial annotation sweep stalled on the lockfile leaves every row behind it showing a placeholder count indistinguishable from a real answer — the reader reads them as untouched.

### C4 · repository on a slow or synced filesystem
1. The mid-write stability check is a statement about two samples, not about the file; on a synced folder or a loaded machine it fails perpetually, and the refusal is terminal rather than retry-with-backoff.
2. A transient git failure is folded into the same presentation as a successful query returning nothing. "Nothing changed" and "I could not find out" render identically, and nothing retries.
3. Watching is presented as authoritative regardless of whether it can work on that volume; with no periodic sanity poll the display can be arbitrarily old while looking freshly refreshed.
4. Freshness by mtime+size hits one-second timestamp granularity, sync clients restoring original timestamps, and clock skew — all systematic false negatives exactly where reads are expensive enough that skipping feels justified.
5. During a stall every notification enqueues its own build with no collapsing of pending work for the same target; recovery time is proportional to outage length.
6. Staging acts on a snapshot captured at the last successful refresh and paints success immediately without confirming the patch matched what the reader saw.

---

## Run D — the terminal and git writes

### D1 · reader committing from the terminal drawer
1. **During an echo-off passphrase prompt the buffer looks empty, so the "nothing typed" guard term reads as satisfied** and a repository click writes a `cd` into the passphrase prompt. The failure looks like an SSH problem.
2. A plain `cd` in the drawer reports over OSC 7 and re-scopes the repository selection; the app's own follow logic can then `cd` back, so one shell navigation produces a directory the reader never asked for.
3. `git commit --amend` touches no tracked file, so no filesystem events fire. Header, diff and pinned object all belong to a commit that no longer exists until the reader switches away and back.
4. While a push or fetch holds locks the state probe errors; the failure is read as "nothing here", the table empties to its placeholder and the selection and diff are torn down — a full empty-state flash from a command that changed no files.
5. `git add -p` rewrites the index once per answered hunk; the list renumbers and reorders under the cursor mid-question, and a refresh that re-focuses a view sends the next `y`/`n` to the file table as a shortcut.
6. The record of commands the app ran is the basis of its undo affordance, and commits made from the drawer never enter it — so it offers to undo its own last write as if it were the most recent thing that happened.

### D3 · reader switching branches constantly
1. The base-branch override is keyed by repository, not by the branch the reader was standing on when they chose it. Two feature branches in one clone → the "vs base" scope compares against a ref never picked for this branch, and every later branch inherits it silently.
2. Whether the branch-vs-base scope is available, and the sentence explaining why not, is decided on repository-open or base-change, never when HEAD moves. The pill's enablement drifts further from the repository the longer the session runs.
3. The branch names the Repository menu offers come from a list gathered before the menu opened; the current-branch exclusion is computed from the same stale list, so the menu can offer to delete the branch the reader is standing on.
4. A restore point records a commit and possibly a stash but not which branch they belonged to; after a switch the undo affordance is still armed and moves the wrong branch. Unconsumed restore-point stashes accumulate indistinguishably from the reader's own.
5. A commit pinned in the History lens survives a checkout onto a branch that does not contain it — the two halves of the window describe different branches with no visible contradiction, and a later branch delete makes the pinned object unreachable.
6. The base override persists by writing the whole configuration file from an in-memory copy, and the post-checkout repository sweep writes the same file from a copy of its own. The losing write is invisible until relaunch.

### C1 · editor autosaving every 300 ms into the open file
1. The reader-position round trip is asked of a webview that is mid-navigation; the answer belongs to the previous document. Once every few saves the pane settles at the top or at a line that has moved — not every save, so it reads as random drift.
2. Row identity churns every save because the file's own stats change, so anything keyed on node identity rather than path resets each save.
3. The 1 Hz age caption is shared observable state whose tick invalidates views beyond itself, and under typing it is also reset every 400 ms — a timer nobody reads driving layout in the pane being read.
4. The activation rescan sweeps **every** repository and is bound to the exact gesture the reader makes when they want to look at the diff, so the heaviest refresh fires at the one moment they are looking.
5. The mid-write guard rejects and waits for the next FSEvent rather than scheduling its own retry; with a 300 ms autosave inside a 400 ms debounce the pane can stay in the rejected state for a whole typing burst.
6. Hunk boundaries shift as the file grows, so per-hunk state keyed on index or line range is silently remapped every save — expanded context re-collapses, and the next-change cursor points at a different hunk.

### D4 · repository with slow, noisy, refusing and rewriting hooks
1. **Pipe deadlock.** The app drains the command's standard output to its end and only then reads standard error, so both fixed-size buffers fill but only one is emptied. A `pre-commit` printing steadily on stderr for forty seconds fills the unread pipe, git's child blocks on a writer that will never be read, and the commit neither fails nor succeeds — indistinguishable from a merely slow hook, exit only by quitting.
2. **Hook text is an injection surface into the failure taxonomy.** The lock-contention classifier is a substring test for a lock path anywhere in the error text; a lint report naming a lockfile matches, and the app silently replays a non-idempotent write from the top, then blames another program for holding the repository.
3. The promise is git's own words, but the selection rule prefers stderr and falls back to stdout only when stderr is empty. Hook runners emit one uninformative line on stderr — name and exit code — while the actual complaint is on stdout, which is then discarded.
4. The restore point is captured **before** the commit runs, therefore before a formatter hook rewrites and re-stages. The commit contains bytes the app never held; restoring later puts the pre-formatter index back against formatted files and hands the reader a diff nobody typed, described as putting things back.
5. The message is composed by the app and handed to git with comment-stripping on, so any body line the reader began with `#` is deleted — and the box is cleared on success, destroying the only remaining copy.
6. Hooks inherit the app's scrubbed environment: system config suppressed, editor and sequence editor replaced with no-ops that report success, prompting disabled. A hook that shells out to git or opens an editor takes a different branch than it does in the drawer, so the same commit passes when typed and fails from the menu — reported faithfully as git's own words for a failure that exists only inside the application.
