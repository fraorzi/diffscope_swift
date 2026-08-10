# 12 — Desktop UX Specification

**Status:** Phase 4. Authoritative for interface behaviour.
**Constrained by:** DEC-005, DEC-006, DEC-007, DEC-012 – DEC-019, DEC-026, DEC-027, DEC-031, DEC-033 – DEC-036.
**Stack-independent.** Nothing here presumes a rendering technology (OQ-033 is open).

---

## 1. Information architecture

One window (DEC-005). Two persistent regions plus a transient one:

```
┌─────────────────┬──────────────────────────────────────┐
│ Repository list │ Scope bar                            │
│ (sidebar)       ├──────────────────────────────────────┤
│                 │ Changed-file list │ Diff view        │
│                 │ (grouped, flat)   │ (unified default)│
├─────────────────┴──────────────────────────────────────┤
│ Terminal drawer (⌃`), full width, panes compress       │
└────────────────────────────────────────────────────────┘
```

**Each of the three regions collapses independently** (DEC-060): repositories to a 44 px rail carrying three letters and a change dot (⌃⌘1), the changed-file list to a spine of one bar per file with its kind glyph (⌃⌘2), both at once (⌃⌘0), the drawer closed (⌃`). Collapsed is **reduced, never hidden** — a collapsed region still answers *which* and *how many*, in less space. The worst case for vertical density is both lists collapsed with the drawer open, and that is the combination to photograph.

No tabs, no secondary windows. Last-opened repository is restored (DEC-005), treated as a cache: if it has moved, been deleted, or changed state, the application recovers to the repository list rather than trusting its memory.

## 2. Repository list

Sources (DEC-037): **any number of user-added root directories**, scanned to depth 2 stopping at the first repository found (DEC-018), **plus individually added repositories** located anywhere. All sources merge into one list.

Populated by an eager parallel sweep at launch, refreshed on window focus (DEC-006). All repositories are shown, including clean ones (DEC-012).

Because two roots may contain identically-named repositories, **the list must disambiguate by more than name** — the row identity is the repository path, not its folder name.

Each row carries **two independent signals**:

| Signal | Source | Unknown state |
|---|---|---|
| Uncommitted file count | status | — |
| Commits ahead of base | merge-base + rev-list | **Explicit "unknown", never 0** |

The unknown state is mandatory, not cosmetic: displaying `0` when the base branch could not be determined is a factual misstatement of the same family the core invariant forbids.

**Semantics note.** The uncommitted count must state which convention it uses — `git status --porcelain` collapses untracked directories, libgit2's default expands them, and the same repository reads 63 or 165 depending on the choice (X-4). Whichever is adopted, it is documented and consistent.

Also displayed per repository: current branch, or the correct state where there is none — see §7.2.

## 3. Scope bar

Four scopes (DEC-008), always visible for the selected repository:

1. All local changes vs `HEAD`
2. Unstaged vs index
3. Staged vs `HEAD`
4. Current branch vs merge-base of base branch

Scope 4 additionally displays **which ref was used and how old it is** (DEC-010). This display is a correctness requirement, not decoration: it is the sole staleness signal, because the application never fetches (DEC-011).

**The copy is fixed, because the obvious wording would be a lie.** The age is the committer date of the ref tip, not the time of the last fetch, which `11-…` §"Scope 4" records as not reliably recoverable. So the row reads `origin/master · newest commit 9 weeks old`, never *"last fetched"*; where the ref cannot be read it says `age unknown`; and the explanation available in the status line states plainly that the application never fetches and that this is the age of what is on disk. A fetch performed elsewhere — another terminal, WebStorm — is picked up on the next refresh, because nothing here is remembered by the application.

The detected base branch is shown and is overridable per repository (DEC-009). Overrides are stored in application configuration, never written into the repository.

Scopes that are undefined for the current repository state are **disabled with a stated reason**, never hidden. Hiding them would make the interface silently disagree with itself between repositories.

## 4. Changed-file list

Flat, one-dimensional, with group headers per workspace package and middle-elided paths (DEC-033).

**Rows are columns.** Kind glyph, path, note, and the line counts right-aligned so a reader can run down the column instead of hunting for them at the end of paths of different lengths. The counts come from `diff --numstat`, and `binary` is a **state** rather than a zero: git reports `-` where a line count would be meaningless, and inventing `+0 −0` there is the same class of misstatement as an ahead-count of 0 for a base that could not be determined.

The counts arrive with the annotations rather than with the rows — one more Git invocation is not worth an empty pane.

- Path elision preserves **start and end**: the start identifies the package, the end identifies the file.
- Group headers are labels, not focus stops.
- Files outside any workspace package fall into a default group.

Per-file indicators: change kind (added / modified / deleted / renamed), and any degradation state from §6.

## 5. Diff view

**Unified by default; side-by-side is a mode** reached by ⌥⌘→ (DEC-059, amending DEC-014). Three modes over two code paths (DEC-013): **Structural** (default), **Expanded**, **Raw**. Three lenses over the same file (DEC-061): **Diff**, **Blame**, **History**.

All of them operate on the same pinned source pair and the same canonical diff, so changing mode, layout or lens can never change which versions are compared nor which change stop the reader is standing on.

**Unified needs a signal side-by-side got for free.** With no panes, *added* and *removed* would fall back onto hue. A dedicated sign column carries `+` and `−`; hue only reinforces it. The column is load-bearing (`24-…` §3) precisely because it is the only part of the distinction that survives greyscale.

**A commit in the History lens is something you compare against** (DEC-061): one picked commit compares it with the working tree, two compare the two in the reader's selection order, and a third starts again. This is not a fifth scope — the four are untouched — and picking a scope drops the selection rather than leaving the two to argue about which comparison the window shows.

**Blame marks uncommitted lines rather than tinting them**, so the change language keeps sole ownership of tint and texture, and the gutter geometry is identical across lenses so that switching one does not move the code.

### 5.1 Colour discipline

Change meaning is carried by **gutter, underline, and background texture — never by token colour** (DEC-035). Syntax highlighting is left untouched. Character-level intra-line changes are marked by underline or texture, not by recolouring characters.

This satisfies DEC-016 structurally: the information survives greyscale and colour-blindness because shape carries it.

### 5.2 Required indicators

Not optional features — these are how the invariant becomes visible (DEC-017):

| Indicator | Meaning |
|---|---|
| Confidence | How certain the structural alignment is |
| Ambiguity | Match was ambiguous; candidates not arbitrarily resolved (DEC-031) |
| Parser state | Whether the file parsed, partially parsed, or not at all |
| Fallback marking | This region is raw, not structural (INV-4) |
| Unverified | File exceeded the runtime validation threshold (DEC-022) |
| Invisible difference | Bytes differ but render identically (DEC-023) |
| Filter active | Git filter in play; structural diff withheld (DEC-028) |

### 5.3 Formatting groups

Formatting-only changes may be collapsed **with a disclosed count and immediate expansion** (DEC-017). The empty-diff state reads as *"no structural changes; N formatting differences (expand)"* — never a bare "no changes" unless the sides are byte-equal (INV-3).

### 5.4 Long lines

The side-by-side mode makes long lines the known weak spot. Horizontal scrolling is linked between panes; wrapping is available; neither may truncate content silently. Spike X-2 found no rendering cliff at 50,000-character lines in either web candidate.

### 5.5 Files that render (DEC-063)

Three classes, not two:

| Class | Shown as |
|---|---|
| Text that also renders — **SVG** | A **Rendered / Source** switch; both readings complete, source defaulted to off |
| **Raster** — png, jpg, webp, gif, avif | Rendered comparison only |
| Undisplayable — archive, generated blob | `#unrenderable`: what the file is, and why nothing is compared |

The rendered comparison has four modes — **Side by side, Blend, Split, Pixel diff** — with dimensions, size and format stated for each side. Rules that are correctness rather than styling:

- **Pixel diff has a 16-megapixel budget.** Above it the mode is **disabled with its reason stated**, in the same form as an unavailable scope, and both renderings are still shown.
- **Bytes differing while the rendering does not must be said out loud**: *"The two files render identically — 0 pixels differ. The bytes differ."* This is DEC-023's disclosure at whole-file scale; without it the reader reads a blank comparison as a false positive.
- **Changed pixels are marked by outline and hatch**, never by hue alone (DEC-035).
- **An SVG is rendered through an `<img>`**, never inlined (DEC-063, extending DEC-028). Nothing can style the inside of it; the transparency checkerboard sits behind it.

## 6. Degradation states

Every degradation is **visible**. Failure reduces visual quality, never correctness.

| State | Trigger | Presentation |
|---|---|---|
| Fallback region | Parse failure or low confidence | Region marked raw, reason stated |
| Whole-file fallback | Invariant violation at runtime (DEC-022) | File marked raw, reason stated |
| Unverified | Above validation size threshold | Explicitly labelled unverified |
| Unsupported language | Not TS/TSX/JS/JSX (DEC-004) | Ordinary raw diff, labelled — not an error |
| Filter active | Git filter detected (DEC-028) | Raw, with filter disclosed |
| Renderable non-text | Image or SVG (DEC-063) | Rendered comparison, §5.5 — an ordinary state, not a refusal |
| Undisplayable | Archive, generated blob | `#unrenderable`: what it is, and why nothing is compared |

The unsupported-language state is the **majority case by file count** and must be designed as an ordinary, well-finished state rather than an error condition.

## 7. Repository states requiring specific handling

### 7.1 Clean repository

Selecting it must lead naturally to scope 4, not to an empty scope-1 view. A clean repository can have substantial review material: one in the current corpus is clean but two commits ahead of base.

### 7.2 Unborn HEAD

Real today (`carrefour-inapp`): `.git/HEAD` points at `refs/heads/main`, zero refs, zero commits.

- Branch display: the state, not a fabricated branch name.
- Ahead count: explicit unknown.
- All four scopes: unavailable, with reason — there is no `HEAD` to compare against.
- **Detection must not use `git symbolic-ref -q HEAD`**, which returns exit 0 and a branch that does not exist. Use `git rev-parse --verify HEAD` failing, or libgit2's `head_is_unborn`.

### 7.3 Detached HEAD

Not present in the current corpus, but must not crash or misreport. Branch display shows the detached state; scope 4 is unavailable.

### 7.4 Base branch undeterminable

Prompt for it (DEC-009), on the same screen family as §7.5.

### 7.5 No roots configured, or a configured root missing

Empty-state screen with a **plain directory picker — no suggested path, no auto-detection** (DEC-036 as amended). The application does not create directories.

`~/WebstormProjects` has no special status: it is a WebStorm-specific name, and nothing in this product depends on WebStorm. This mirrors DEC-015, which rejected hardcoding WebStorm as the editor.

A configured root that has disappeared is reported as such and does not remove the user's other roots or their per-repository configuration.

## 8. Refresh behaviour

Auto-refresh on file change, trailing-edge debounce with a maximum-delay cap (DEC-007, DEC-026). `node_modules` excluded from watching (DEC-027).

**FSEvents configuration, as DEC-026 requires it to be recorded here:** one stream on the currently open repository, flags `FileEvents | NoDefer | WatchRoot`, **latency 0.0**, with the debounce in application code — 400 ms of quiet, capped at 2 s from the first event of a burst. The alternative configuration (latency 0.4, `NoDefer` off) coalesces equally well but cannot express the cap. A dropped-event flag produces a **full rescan**, not a refresh, and a `RootChanged` event stops the watcher and says so.

**A file still being written is not rendered** (DEC-049). The worktree read is bracketed by a `stat`; a pair that will not settle within five attempts leaves the current view alone and reports that the file is being written. The watcher fires again when the writing stops.

**Scroll anchoring** (DEC-034): anchor to the nearest segment labelled unchanged above the viewport top. Fallback chain when the anchor is deleted: nearest surviving unchanged segment above → top of file. Re-anchoring must not drift across repeated refreshes, and must have a non-animated path under reduced motion.

File selection is preserved across refresh where the file still exists in the scope, and degrades clearly where it does not.

## 9. Keyboard

DEC-016 commits to **full keyboard operation of every function**. This is a complete map, not a shortcut list. Minimum coverage:

| Function | Bound to (DEC-057) |
|---|---|
| Move between repositories | ⇧⌘↑ / ⇧⌘↓ |
| Move between files (one-dimensional, per DEC-033) | ⌥↑ / ⌥↓ , and ↑ / ↓ in the list |
| Switch scope | ⇧⌘1 … ⇧⌘4 |
| Next / previous change | ⌘↑ / ⌘↓ |
| Switch mode (Structural / Expanded / Raw) | ⌘1 / ⌘2 / ⌘3 |
| Expand a collapsed range or formatting group | ⌘E |
| Show raw for the current region | ⌘R |
| Open current file and line in the editor | ⌘⏎ |
| Focus movement between sidebar, file list, and diff | ⌥⌘1 / ⌥⌘2 / ⌥⌘3 |

The **coverage** above is binding: any function reachable only by pointer is a defect. Since DEC-057 the right-hand column is not documentation of the code — it *is* the code, transcribed from `KeyboardMap.bindings`, and a row nothing binds fails the check suite by name. Group headers are not stops (DEC-033), on any route.

**The key column above is DEC-065's map, and the code has it.** One direction key at three modifier tiers for the three nesting levels — change inside a file, file inside a repository, repository inside the list — with `⌘1` on Structural because it is the mode a reader returns to. Outside this table the same map binds `⌃\`` for the terminal, `⌥⌘R` to force raw in it, `⌥⌘K` to follow the selection, `⌥⌘W` for wrap, `⌥⌘→` for side-by-side, `⌃⌘1` / `⌃⌘2` / `⌃⌘0` for the three collapses (DEC-060), `⌘F` and `⇧⌘F` for search over the changed set and over the worktree (DEC-062), `⌘,` for Settings (DEC-015), and `⇧⌘O` / `⇧⌘R` / `⇧⌘B` for the Sources menu. The table above stays exactly the nine rows §9 specifies — those are the coverage contract, and the others are functions this document does not require.

**The functions the adopted design introduces arrive as they are built** — the collapses and search are bound; the two lenses and the image-comparison modes are not. A row is added **when the function comes to exist**, not when it is drawn: this column is a transcription of `KeyboardMap.bindings`, and a transcription that runs ahead of its source is the drift DEC-057 exists to prevent.

## 10. Editor integration

Configurable command template with file and line placeholders, defaulting to WebStorm (DEC-015).

**Where it lives:** `editorTemplate` in the application's configuration file, edited in Settings (⌘,). Absent means the built-in default — the file records what the user chose, not what the application would have done anyway. `DIFFSCOPE_EDITOR` overrides it for a launch and is never written, so the broken-editor arm (F13) has a way in that does not touch the reader's file.

- Search (DEC-062) is a **field in the window**, not a dialog: ⌘F puts the caret in it over the changed set, ⇧⌘F over the whole worktree, and the placeholder says which. An empty query is the way back to the file list. A modal cannot show which scope answered, and the scope is half the answer.
- **Results go in the pane, grouped by file**, each hit's line split around the match. The file list keeps showing files: results answer a question, they do not replace the thing being reviewed. ⌘G and ⇧⌘G move the marker and say where it is — they do not open the file, because opening replaces the pane the results are in and a reader stepping through nine matches would lose the list at the first one. ⌘⏎ opens the hit under the marker, at its line.
- Failure — editor absent, command fails — must be **visible**, never a silent no-op. The status line says it as it happens and Settings keeps the last attempt, because the line has moved on by the time a reader opens the settings to fix it.
- The template is user configuration and must never be populated from repository content, which is untrusted input.
- Opening "this line" from the old side of a deleted region has no destination in the current file; behaviour must be defined rather than left to produce a wrong jump.

## 11. Theming

Follows macOS system light/dark, with a built-in syntax theme per appearance (DEC-019). Appearance changes are handled while running, including mid-diff. Both variants are independently verified for contrast **and texture legibility**, since DEC-035 makes texture load-bearing.

Every value comes from the token table of DEC-066 — name, both appearances, and a flag marking the rows the AppKit chrome mirrors. Text below 18 px holds at least 4.5:1 against its own surface in both appearances; the first version of the adopted design failed that at 2.7:1 on the tertiary neutral and it was caught by measurement, not by looking.

## 11a. Motion

Since DEC-064 the interface animates. Every transition is registered with its duration, curve, what moves, and **its reduced-motion path**; a transition with no such path is not shippable, and the check refuses an animated property that is not neutralised under `prefers-reduced-motion: reduce`. Scroll re-anchoring keeps the explicit non-animated form DEC-034 already required: the jump is instantaneous and the status line reports *"re-anchored at line 412"*.

## 12. Open items owned by this document

- ~~Concrete key assignments~~ — **settled by DEC-057, 2026-08-09**, re-cut by DEC-065 the same day. The bindings are data (`KeyboardMap`), the menu bar is generated from them, and the coverage table above is transcribed into `KeyboardFunction` so a row nothing binds fails the check suite.
- Sorting and grouping order within the repository list.
- ~~Minimum usable window width~~ — **settled by DEC-059, 2026-08-09: 1180 px.** 246 rail + 296 list + 80 monospace columns and gutters. Below it side-by-side falls back to unified; below 1020 the file list collapses to its spine; 860 is the AppKit minimum content size.
- Visual design of ambiguity indication that does not read as malfunction (DEC-031).
- Whether the empty-state picker interacts with sandboxing (OQ-035).
