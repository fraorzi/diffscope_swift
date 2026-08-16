# 24 — Design contract

**Status:** Accepted 2026-07-31, gate G2 of `23-release-gates.md`. Authoritative for what a design may change and what it may not. **Amended 2026-08-09** by DEC-059 (a sign column), DEC-063 (surfaces that render), DEC-064 (motion) and DEC-066 (the token table as the delivery format), **2026-08-12** by DEC-071 … DEC-076 (the chrome, and the contrast threshold every ink is held to), and **2026-08-13** by [DEC-077](04-decision-log.md).

**What DEC-077 changes here, and how much of it has landed.** The owner asked for a quieter window, and three of this document's rules move with it:

| Rule | Was | Now | Landed |
|---|---|---|---|
| The focus ring | `--ds-focus-ring`, 2 px, drawn while the keyboard is in use (DEC-070) | **not drawn at all**; the selected row carries focus, marked by a fill *and* a bar at its leading edge | **yes** (`930e621`) |
| Keystrokes in the chrome | printed on every pill, in the status line and on the base block (DEC-073) | **never printed**; still composed for tooltips and the menu bar, and a check refuses a modifier run written by hand in any string the chrome shows | **yes** |
| `#track`, §3 | *quietened, never removed* | **absent when there is nothing to scroll** — that rule was written about a control a reader might need, and this one cannot be used | **yes** — both halves are asserted against the live document, and the span is taken from the layout that is showing rather than always from the left pane |
| Change marks | an underline plus a texture, because colour alone fails greyscale (DEC-035) | a tint over the whole line and a **stronger tint** on the changed bytes; the two must differ in **luminance**, and the sign column and gutter edge stay | **yes** — the three pairs are measured over the code surface in both appearances, 1.27:1 to 1.53:1 apart, and the control is a pair that differs only in hue |
| The switches' material | a drawn pill: `--ds-control-thumb` filled, `--ds-control-border` stroked | **`NSGlassEffectView`** where the system has it (macOS 26), the drawn pill below it, and **no imitation** of it anywhere | **yes** — asserted as real AppKit, covering the chosen segment and only it, with its title inside the glass. **The material itself is unphotographed on this machine**: `cacheDisplay` renders it as a flat fill exactly as it renders a `WKWebView` as black, and the window-server path needs screen recording and an unoccluded window |
| The trust chips | `parser:`, `confidence:`, `mode:`, always drawn (DEC-017, DEC-058) | **nothing while everything is normal**; one plain sentence when a file is shown as plain text — INV-4 is the floor and does not move | **yes** — the structural arm asserts the *absence* of all three, and the degradation arm asserts the sentence. Every fact is still computed, still on the wire and still checked in `TrustSurfaceChecks` |

The work list, with an acceptance test for each item, is [28-interface-plan.md](28-interface-plan.md).

**Paste your design into `Renderer/src/tokens.css`.** That is the whole answer to "where does it go". The rest of this document is what you get to change, what the interface promises in return, and the two rules the suite enforces so a restyle cannot break the thing the product exists for.

---

## 1. The one rule

> **A design may restyle any mark. It may never hide one.**

Everything below follows from that sentence.

The application's claim is that it never hides a difference. The engine has an apparatus for proving that — five invariants, an independent diff, 943 checks — and **none of it can see the screen**. A stylesheet with `display: none` on a change mark leaves every one of those checks passing and every difference invisible. CSS is the one place where the product can be made to lie without anything noticing.

So it is checked. Twice.

- **In the source** (`DesignChecks.swift`): no rule in the stylesheet hides a class that carries a difference, every mark is distinguishable by something other than colour, and the notice bar is not styled away.
- **In the live document** (`diffscopeStyleAudit`, run by the application selftest): computed style on real elements, because a stylesheet can be read and still be wrong about what the reader gets — a later rule, a cascade, an inherited `opacity`.

Both have negative controls. The selftest injects `display: none` on a mark and requires the audit to catch it; the source checks run against a deliberately hostile stylesheet. A check that has only ever seen a passing input is an assumption wearing a check's clothes.

---

## 2. Where things live

| File | Holds | A design touches it |
|---|---|---|
| `Renderer/src/tokens.css` | Every colour, font, size, spacing, radius and border in **both** webviews, including the terminal's `--ds-term-*` block | **Yes — this is the file** |
| `Renderer/src/index.html` | Structure of the diff, and which token each rule uses | Only to change *which* token a rule reads |
| `Renderer/src/terminal.html` | Structure of the terminal pane, same discipline | Only to change *which* token a rule reads |
| `Sources/diffscope-app/Theme.swift` | The same values for the AppKit chrome: window, both lists, status line, empty state, the pane sizes | Yes, mirroring the token names |
| `Renderer/src/main.js` | Which class goes on which range | No |
| `Renderer/src/terminal.js` | Which token xterm is handed, and where a keystroke goes | No |

**There are three surfaces, not one.** The diff webview, the terminal webview, and the AppKit chrome around both. The chrome is two thirds of the window: a design that stops at the edge of the diff leaves the repository list, the file list and the status line looking like a different application, so `Theme.swift` mirrors the token names rather than inventing its own.

**The terminal is a real surface with real state** (DEC-053 … DEC-056), and it is styled from the same file. xterm.js cannot read CSS variables itself, so `terminal.js` resolves the `--ds-term-*` names and hands xterm the values — which means a token that does not exist becomes a colour xterm silently invents. The grid's probe reports `missingTokens` for exactly that reason, and the selftest fails on a non-empty list.

The sixteen ANSI colours are literal in `tokens.css` rather than derived from the two neutrals, and deliberately so: the palette is what a *program* addresses by index. `ls` asks for "green"; `Canvas` and `CanvasText` cannot express it, and a design that makes green a shade of the background makes some programs' output unreadable rather than merely off-brand.

**The chrome is two thirds of the window.** A design that stops at the edge of the webview leaves the repository list, the file list and the status line looking like a different application, so `Theme.swift` mirrors the token names rather than inventing its own.

The defaults are the system's own (`Canvas`, `CanvasText`), so light and dark mode work with no effort. Replace them with literal colours if you like — the checks care about *where* values are declared, not what they are.

**A design arrives as a table, not as a stylesheet** (DEC-066). Each row is `name · dark · light · mirrored · what it is for`, and the **mirrored** flag is the part a stylesheet cannot carry: it marks the rows `Theme.swift` must also hold, because AppKit draws that surface and CSS never reaches it. Hand-mirroring was the one step in this document with no check behind it; with the flag present, *every row marked mirrored has a counterpart in `Theme.swift`* becomes a third token check beside the two in §4.

---

## 3. Every class the renderer emits

Classes marked **load-bearing** carry a difference. They may be restyled and may not be hidden.

| Class | Means | Load-bearing |
|---|---|---|
| `ds-changed` | Ordinary edited content | **Yes** |
| `ds-fallback` | This region is raw, not structural (INV-4) | **Yes** |
| `ds-moved` | Byte-identical content that appears elsewhere on the other side (DEC-038) | **Yes** |
| `ds-formatting` | A change classified formatting-only — quietened, never hidden (DEC-017) | **Yes** |
| `ds-behaviour` | Reordering: possibly behaviour-affecting, and the tool will not claim otherwise | **Yes** |
| `ds-uncertain` | An alignment the structural layer could not confirm | **Yes** |
| `ds-invisible` | Bytes differ, screen does not (DEC-023) — the case a reader cannot otherwise detect | **Yes** |
| `ds-gutter-changed` | This line carries a difference (`12-…` §5.1) | **Yes** |
| `ds-fold` | Byte-equal content folded away, with its line count | **Yes** — the count must stay visible |
| `ds-fold-formatting` | A group of real formatting differences, with its count | **Yes** — same reason |
| `ds-badge` | Names an invisible difference, and its codepoints in Expanded | **Yes** |
| `ds-note` | **Removed by [DEC-083](04-decision-log.md).** It was a grey word after the line — `formatting`, `uncertain`, `M1`, `inserted` — and this row already called it *annotation only* and forbade it from being the sole carrier of anything, which is why removing it took nothing with it. What says a line changed is the sign column, the gutter edge and the tint; what discloses a group is the count in `#diff-footer`, which is DEC-017's actual requirement | Gone |
| `ds-chip` | One notice in the bar | **Yes** |
| `ds-chip-alert` | A chip that reports the tool catching itself | **Yes** |
| `#file-header`, `#file-path`, `#file-name` | Which file this is, above everything said about it | **Yes.** The path is what tells two files of the same name apart, and DEC-058 has already paid three times for putting a displayed fact in a tooltip |
| `#notices` | The bar carrying every notice — INV-4 made visible | **Yes** |
| `#showing` | What is being compared, which layout is drawing it, and — in unified only — what `+` and `−` mean | **Yes.** The comparison was stated only in the chrome, far from the pane the reader is looking at, and the sign column is the *sole* carrier of direction once there are no panes (DEC-059), so the pane names it. The sentence is composed in the Git layer and pushed in, never assembled here: `comparisonDescription` and `baseSummary` exist so that a sentence the interface makes can be checked |
| `ds-notice` | An inline notice inside the document | **Yes** |
| `#unrenderable` | Shown when the content is not text that can be displayed, and why | **Yes** |
| `ds-hunk` | `@@ −12,4 +12,5 @@` above each change block in unified | No — orientation, not a difference. After a fold, the number columns say where each *line* is and this says where the *change* is |
| `ds-sign` | The `+` / `−` column in unified (DEC-059) | **Yes.** With no panes, this is the only signal of direction that survives greyscale |
| `ds-line-changed` | This line carries a difference, as a tint across its whole width — the two-pane layout's half of DEC-077, where the pane itself says which side the line is on and the tint therefore claims nothing about direction | **Yes.** It is what replaced the underline. It is drawn from the same `changedLines` the gutter edge is drawn from, and the selftest holds the two counts equal — a mark computed and never drawn is the failure this catches |
| `ds-line-add`, `ds-line-del` | Direction as a tint behind the line, in unified | No — they *reinforce* `ds-sign` and may be removed. Removing the sign column is what the rule above forbids. Since DEC-077 a changed byte **inside** one of them takes the same hue at a lower transparency (`--ds-tint-add-strong`, `--ds-tint-del-strong`), so a mark on a tinted line reads as more of the same thing rather than as a second meaning |
| `#unified` | The one-column layout, and the default (DEC-059) | No, as layout |
| `#track` | The one horizontal position the showing layout has (`12-…` §5.4) | **Yes while there is something to scroll, and absent otherwise** (DEC-077, reversing this line). *A control that vanishes teaches a reader it does not exist* was written about a control a reader might need; this one **cannot be used**, and a dead strip of interface is something the reader has to learn to ignore. Both halves are checked in the live document — present with wrapping off and a three-hundred-character line, gone with wrapping on — because a control that is always absent satisfies half the rule. **The span comes from the layout that is showing**: it was read off the left pane whatever was drawn, so unified, the default since DEC-059, reported nothing to scroll however long its lines were |
| `#diff-footer`, `#diff-footer-text`, `#diff-footer-expand` | The bar closing the pane: how many formatting differences and of what kind, how many lines are folded away, and the button that opens them | **Yes, and the count is the reason.** DEC-017 permits grouping *only while the count is shown*, and until this existed the count lived on the fold markers alone — a reader who had scrolled past them saw nothing. The button runs the same `expandAll` command ⌘E runs, so the two cannot disagree. It is hidden only when there is genuinely nothing grouped and nothing folded |
| `ds-gutter-old`, `ds-gutter-new`, `ds-gutter-sign` | The three gutters of the unified layout: the two number columns and the sign column | **The sign gutter is**, for the reason `ds-sign` is. The number columns are how a reader says *where* — restyle freely, do not collapse them into one |
| `#stage`, `#left`, `#right` | The two-pane layout, reached by ⌥⌘→ | No, as layout |
| `#lens` | The Blame and History lenses (DEC-061) | No, as layout |
| `ds-lens-row` | One line of blame, or one commit | **Yes.** A row that is not drawn is a line whose author, or a commit, the reader was told existed |
| `ds-lens-uncommitted` | Work that is not committed yet — **marked by an edge, never tinted** | **Yes**, and the shape is the point: tint and texture belong to the change language, and a second meaning for them is a meaning nobody can read |
| `ds-lens-sha`, `ds-lens-who`, `ds-lens-when`, `ds-lens-line`, `ds-lens-text` | The columns of a blame row | **Yes** — each is one of the questions the lens exists to answer |
| `ds-lens-subject`, `ds-lens-refs` | The columns a commit adds | **Yes** |
| `ds-search-file` | Which file the hits below it are in | **Yes** |
| `ds-search-hit`, `ds-search-current` | One hit, and the one the reader is on | **Yes** |
| `ds-search-before`, `ds-search-match`, `ds-search-after` | The line, split around the hit | **Yes**, and the match carries weight as well as a fill: a highlight that is only a colour is a hit a greyscale screenshot loses |
| `ds-lens-mark`, `ds-lens-picked` | Which commits the reader has picked, and in which order; also the marker on the current search hit | **Yes**, and the order is the point: one commit is *since this*, two is *between these*, and a glyph says which is which without a colour |
| `ds-lens-header` | What the lens says above its list, including that nothing is fetched | **Yes** |
| `cm-*` | CodeMirror's own classes: editor, scroller, gutters, line numbers | No, except the gutter ones |

### The terminal pane

Added after this contract was first written, and missing from it until M8-P — the terminal landed the day after G2 passed, so the document described a window with one webview in it. Every element the pane emits:

| Element | Means | Load-bearing |
|---|---|---|
| `#tabs`, `ds-term-tab` | One tab per shell (DEC-067), saying which shell it is and **where that shell says it is** | **Yes.** The active tab is marked by weight and an edge; a tab whose shell has diverged from the selected repository carries the same dotted underline `#cwd` does — one meaning, one shape |
| `ds-term-grid` | One xterm instance per tab, all present, one visible | **Yes** — hidden by `visibility`, never removed: a background shell is still running and its scrollback is still its own |
| `#grid` | The xterm.js screen — everything the shell prints | **Yes.** Output that cannot be read is output that was not shown |
| `#input-row` | The command line at a prompt (DEC-055) | No, as layout |
| `#mode` | Which mode the keyboard is in: prompt, program, or forced raw | **Yes.** The reader has to know where their keystrokes are going |
| `#mode[data-raw="true"]` | Raw forced by ⌥⌘R — **dashed border and heavier weight, not a colour** | **Yes**, and the shape is the point (DEC-035) |
| `#cwd` | Where the shell says it is (OSC 7) | **Yes** |
| `#cwd[data-diverged="true"]` | The shell is **not** in the selected repository — dotted underline | **Yes.** This is the terminal's own version of the honesty rule: the pane must never imply the shell is where the diff is |
| `#line` | The real text field the macOS motions come from (T0) | **Yes** — hidden by `visibility` when there is no prompt, never removed, so the row keeps its explanation |
| `--ds-term-black` … `--ds-term-bright-white` | The sixteen colours a program addresses by index | **Yes**, as a set: a palette collapsed toward the background makes some programs unreadable |
| `--ds-term-fg`, `--ds-term-bg`, `--ds-term-cursor`, `--ds-term-selection` | The four values xterm.js reads outside the palette | **Yes**, and **as a set**: any one left undeclared is a colour the emulator invents |

### The chrome AppKit draws

Two thirds of the window is not a webview and emits no classes at all, so the table above could never describe it. Every view the chrome draws itself is here instead, and a check requires each `NSView` subclass in `Sources/diffscope-app` to appear in this table — the same discipline as the class list, arrived at the same way: the contract claimed to describe the window and described one webview in it.

| View | Means | Load-bearing |
|---|---|---|
| `ChromeBar` | A band with one hairline edge: the title bar's at the bottom, the status line's at the top, a pane header's at the bottom | No — the surface. The hairline is a seam, not a fact |
| `SelectedRowView` | The selected row, drawn from `--ds-row-selected` **and** `--ds-row-ring` (DEC-066) | **Yes.** The ring is the half that survives greyscale; AppKit's own highlight is a solid accent fill that also repaints the row's text white |
| `PillControl` | The scope, mode, lens and layout switches: a trough with one raised pill in it | **Yes**, and the disabled state above all — an unavailable scope is drawn with a **dashed** outline and its reason, never greyed and silent (`12-…` §3). **The raised pill is `NSGlassEffectView` on macOS 26** (DEC-077): real AppKit, inside an `NSGlassEffectContainerView` whose `spacing` is what merges neighbouring glass, with the chosen segment's title as the glass's `contentView`. Below 26 the drawn pill is the fallback and **nothing imitates the material** — a check refuses `NSVisualEffectView`, a blur filter or a blending mode anywhere in the chrome. Note that `contentView` on both classes is *filled* by the view it is given: handing the container the glass directly makes the thumb the size of the whole control |
| `RimButton` | The adopted design's button, worn by the `+` ([DEC-084](04-decision-log.md)): a **disc** with a fill, a light glyph, and a rim drawn as a **gradient** around the ring — bright along the top, falling away toward the bottom | **Yes as an affordance**, and the gradient is the point: a flat ring of one colour does not read as metal at any width, because what the eye looks for is a specular highlight where light would land. AppKit cannot stroke a path with a gradient, so the ring is clipped and *filled*. `--ds-rim-highlight` and `--ds-rim-shadow` are held **1.30:1 apart in luminance** — a gradient whose two ends match is a flat stroke wearing a gradient's clothes. It subclasses `HandButton`, so the pointing hand and the 24 pt floor come with it. **The values are derived, not transcribed**: the design arrived as a small paste and never as a file, so the rim width (1.5 pt) and the diameter (24 pt) are guesses named as such in DEC-084 |
| `RimHost` | The rim around a control the **system** draws — the search field, and the checkbox ([DEC-085](04-decision-log.md) item 5). The same clipped-and-filled specular ring `RimButton` uses | **Yes as an affordance**, and the containment is the decision: the field keeps its own editing, focus and cancel button, and the checkbox keeps its key equivalent and its state. The owner asked for the material, not a rebuild — the same trade the empty state's buttons made |
| `ChevronButton` | A borderless button that draws the switches' chevron beside its title: `Sources` ([DEC-085](04-decision-log.md) item 6) | **Yes as an affordance.** It typed `⌄` into its own title, which is a *modifier letter* with its own side bearings and baseline — so it read as a `>` and sat wherever the font put it. Drawing the same two strokes `PillControl` draws, in a box of the same width, is what stops one glyph being a string in one place and a path in another |
| `HandTableView` | The repository list and the changed-file list, which say they can be clicked ([DEC-085](04-decision-log.md)) | **Yes as an affordance.** DEC-083 gave the pointing hand to every borderless *control* and left these two on the arrow — and they are the two things a reader clicks most. What decides is whether a click does something, not whether AppKit calls the thing a control. The rect covers the whole table rather than each row: every row is either selectable or a group header the selection steps over (DEC-033), and a header showing the arrow between rows showing the hand would read as a claim about that row |
| `HandButton` | Every **borderless** button the chrome draws: the `+`, the two collapse chevrons, `Sources ⌄` (DEC-083). It sets `pointingHand` and holds a **24 × 24 pt floor** on its own frame | **Yes as an affordance.** AppKit gives a borderless button no cursor and no size of its own, so before this the whole window showed an arrow and the target was the glyph — 11 pt for a chevron, which collapsed is the only thing in the rail. The line is drawn at *borderless*: a standard bordered button keeps the arrow the platform gives it, because the complaint was about controls that do not look like controls. The floor has two costs and both are recorded: the collapsed spine went from 34 pt to 42, and the rail kept its 44 by dropping the `+`, which has two other pointer routes where the chevron has none |
| `SegmentList` | The options a `PillControl` is **not** showing, in the popover its chevron opens (DEC-077): one row each, the chosen one marked by a glyph as well as by weight, and every option that cannot be chosen carrying **the reason beside it** rather than in a tooltip | **Yes**, and the reason is the load-bearing part — `12-…` §3 requires an unavailable scope to state why, which a system control renders as grey and silent. The keyboard never runs through this list: every option here is also a menu item, so ⌘1 selects Structural whether or not the popover has ever been opened |
| `ChipView` | A short fact in a bordered pill: a repository's ahead-count, a file's `raw`/`bin`/`big` note | **Yes**, and `↑ unknown` is drawn **dashed** because an unknown count is a different kind of thing from a small one, not a quieter one |
| `FilePane` | The changed-file list under its header. **Lays its two children out by hand**, because a pane inside `NSSplitView` cannot use Auto Layout for its own contents: the split sets the pane's frame directly and the engine goes on valuing its width at the old number, so a constrained child is laid out against a width its parent no longer has (M9-L) | No as a container — but the placement is load-bearing in the sense that matters: a collapsed pane whose list stays full width is a control that did not do what the reader asked |
| `FactBlock` | A fact the reader can change: a caption, the fact, and the keystroke that changes it. The base ref in the scope row is the first (DEC-072) | **Yes.** Drawn with a **dashed** rim while the fact is not the one on screen — `newest commit 9 weeks old` beside `HEAD ↔ working tree` would otherwise read as a statement about the comparison being drawn |
| `TerminalPane` | The drawer, its tab strip and the web view in each tab (DEC-067) | **Yes** — see the terminal table above for what it emits |
| `Sources ⌄` in the title bar (DEC-071) | The four things a reader does to *which repositories exist*: add a root, add a repository, remove a source, set the base branch | No as a control — **yes as a route.** Its menu is `KeyboardMap.bindings(in: .sources)`, the same array the menu bar is drawn from, so it cannot offer an item the keyboard does not have |
| The status line (DEC-075) | Three fields: `● Watching · refreshed 4s ago` and whatever happened last, the mode switch centred, and at the right the layout, `Wrap long lines` and the keys that move the reader | **Yes for the watcher field.** A window that has stopped following the disk must say so while it is stopped, not in the moment it stopped; the dot is **filled or hollow**, never green or grey. The legend prints what `KeyboardMap` binds — the design's own `⌥↑↓ change` names the key DEC-065 gives to *files* |
| The scope row (DEC-072) | `SCOPE`, the four scopes, what the chosen one compares, and the base block — **across the window**, above the three panes, because changing the scope changes the file list | **Yes.** `12-…` §3 requires an unavailable scope to be disabled *with its reason*, and the row is where that reason is said |
| The file list's group headers (DEC-033, DEC-074) | Which group the rows under them belong to, as the shortest **front-anchored** form that is unique in the list — `PACKAGES/APP-0…`, never `…/components/nested` nine times | **Yes as a separator, and the uniqueness is the rule.** Two groups under one header is a list that lies about where its files are; the full path stays on the row's tooltip |
| The pane headers (DEC-071) | `REPOSITORIES` with the `+` that adds a source, and `CHANGED FILES` with the number of files in scope | **Yes for the count.** DEC-058 has been paid three times for a fact stated far from the thing it is about; the caption may be restyled, and collapsed it is dropped in favour of the count (DEC-060) |

**`--ds-faint` is drawn on the two panel surfaces and nowhere else.** Measured: it is 4.47:1 on `--ds-chrome`, 4.32:1 on `--ds-control-trough`, 4.12:1 on `--ds-row-selected` and 3.47:1 on `--ds-control-thumb` in dark — under the 4.5:1 this design's own review fixed the tertiary ink to (`27-…` §3), which was measured against the paper alone. A check holds **every ink/surface pair the chrome draws** to 4.5:1 in both appearances; the list is hand-maintained and each entry names where it is drawn, so adding a label means adding its pair.

**Chrome copy is composed in `DiffScopeShell/ChromeLabels.swift`**, which holds no AppKit, so the check suite links the file the window draws from. A caption written inline in `main.swift` is a claim only a picture can check — and `fitsCollapsedPane` is the reason the rule is worth a file: whether `REPOSITORIES` fits a 44 pt rail is not a matter of taste.

The `+` button is the first instance of a rule that outlives it: **a pointer affordance may only open a function the keyboard map already has.** Its menu is built from `KeyboardMap.bindings(in: .sources)`, so the titles and key equivalents are the menu bar's own. DEC-016 calls a function reachable only by pointer a defect; a button reaching something the map does not have is the same defect with the surfaces swapped.

### Surfaces that render (DEC-063)

An image or an SVG is compared by being drawn, and the drawing is a surface with its own rules.

| Element | Means | Load-bearing |
|---|---|---|
| `#rendered` | The Before / After, Blend, Split or Pixel-diff stage | **Yes** |
| `ds-render-bar`, `ds-render-mode` | The four modes, and which one is on | **Yes** — a mode that cannot be seen is a comparison the reader cannot ask for |
| `ds-mode-off` | A mode unavailable here, **with its reason beside it** | **Yes** — disabled and stated, never hidden |
| `ds-render-summary` | What the picture cannot say: dimensions, bytes, differing pixels | **Yes.** This is where "renders identically, bytes differ" lives |
| `ds-render-stage`, `ds-render-panel`, `ds-render-overlay` | Layout of the stage | No |
| `ds-render-slider`, `ds-render-divider` | Blend's opacity and Split's position | No — but the slider is how both are reachable from the keyboard, and a divider that only drags is a control DEC-016 does not allow |
| `ds-render-label` | Before / After, and "no counterpart on this side" | **Yes** |
| `ds-checker` | Transparency behind the image | **Yes** — an alpha change that reads as a background change is a hidden difference |
| `ds-pixel-mask` | Where the pixels differ, drawn by the shell | **Yes**, and outlined as well as filled: never hue alone |

**The SVG is drawn through an `<img>`, never inlined.** It is repository content and it can carry script (DEC-063, extending DEC-028). A design therefore cannot style the interior of an SVG: the checkerboard sits behind it, and no rule inside the pane reaches the mark.

---

## 4. What the checks will refuse

1. **A literal colour, font stack or pixel size outside `tokens.css`** — in the stylesheet or set from JavaScript. One file, or the boundary lasts until the next edit.
2. **A `var(--ds-…)` that no token defines.** The property silently disappears and the mark quietly becomes nothing.
3. **A token nobody uses.** A value a designer would change to no effect is worse than one not offered.
4. **`display: none`, `visibility: hidden` or `opacity: 0`** on any load-bearing class, in the source or in the computed style.
5. **A mark reduced to colour alone.** Every mark must carry at least one signal that survives greyscale — texture, outline, edge or weight. DEC-035: colour alone fails in a screenshot, in greyscale, and for a colour-blind reader. **The underline was on that list until DEC-077**, and removing it did not weaken the rule so much as move where it is asked: the tint that replaced it is held to a *luminance* difference, measured over the code surface in both appearances, with a hue-only pair as the control. A tint pair that differs only in hue passes every other rule in this document and disappears in a screenshot.
6. **A notice bar laid out to nothing.**
7. **A font size or colour written inline in the AppKit chrome** rather than read from `Theme.swift`.
8. **A token marked mirrored with no counterpart in `Theme.swift`** (DEC-066). The flag is a promise about a second file; unkept, it leaves two thirds of the window styled by inference.
9. **An animated property with no off switch** (DEC-064). Every animation must be neutralised inside `@media (prefers-reduced-motion: reduce)`, and the check carries two negative controls: an unguarded animation, and a reduce block that switches nothing off. Durations and curves are tokens (`--ds-motion-*`) so the register and the stylesheet cannot drift apart, and the AppKit chrome — which has no media query — must read `accessibilityDisplayShouldReduceMotion` before it animates.
10. **SVG markup inserted into the document** rather than loaded through an `<img>` (DEC-063). This is repository content reaching a place where it can execute.

---

## 5. Rules the checks cannot enforce, and that still hold

- **A disclosed count stays legible wherever grouping quietens something** (DEC-017). Grouping is permitted *because* the count is shown; a design that shrinks it to four grey pixels keeps the letter and loses the point.
- **Quietening is not disappearing.** `ds-formatting` should read as "present and less shouty", never as "absent".
- **The motion register** ([DEC-079](04-decision-log.md)). DEC-064 put it in the adopted design's Motion table, which is behind the owner's login — so *is this transition in the register* was a question nobody here could answer, and the register was a promise about a document rather than a list. It is this table, and a check requires it and the stylesheet to name the same set: **a transition in the code with no row fails, and a row with nothing behind it fails.**

| What moves | Where | Duration | Reduced-motion path |
|---|---|---|---|
| The notice bar arriving | webview, `#notices` | `--ds-motion-quick` | no transition |
| A notice chip's rim | webview, `.ds-chip` | `--ds-motion-quick` | no transition |
| A folded range under the pointer | webview, `.ds-fold` | `--ds-motion-quick` | no transition |
| The footer's Expand/Collapse button under the pointer | webview, `#diff-footer button` | `--ds-motion-quick` | no transition |
| A blame or history row under the pointer | webview, `.ds-lens-row` | `--ds-motion-quick` | no transition |
| A pane collapsing to its rail or spine | chrome, `NSSplitView` | `Theme.motionQuick` | the other width, set outright |
| A switch's options arriving | chrome, `NSPopover` | the system's | `animates = false` |
| The chosen option changing | chrome, the glass thumb | `Theme.motionQuick` | the other title, with nothing in between |

**Nothing that carries meaning moves.** Every row above is furniture: a notice arriving, a control under a pointer, a pane the reader asked to fold. A change mark is where the engine put it the moment the document arrived, and it stays there.

The webview's off switch is `@media (prefers-reduced-motion: reduce)` and it disables `*`, not a list — a list is a thing that can be incomplete, and the one transition missing from it is the one a reader with vestibular sensitivity gets. **The chrome has no media query**, so it reads `accessibilityDisplayShouldReduceMotion` directly, and there is no preference of our own that could disagree with the system's.

- **Nothing animates without an off switch** (DEC-064, amending this line). Until 2026-08-09 the rule was *nothing animates*, and reduced motion was honoured by there being nothing to disable — a guarantee by construction, which is the strongest kind. That is gone by decision: the product owner wants the interface to move. What replaces it is a register and a check — every transition declares duration, curve and its reduced-motion path, and rule 9 above refuses an animation that lacks one. The register is the design's Motion table. **A transition that is not in it does not ship**, and this line is the reason to be strict about a rule that used to be free.
- **The two panes must stay vertically aligned** in the side-by-side mode. Anything that changes line height on one side only breaks the comparison the product exists to show. Unified has one column and is not exposed to this, which is part of why it is the default (DEC-059).

---

## 6. How to paste a design in

```bash
# 1. Replace the values in Renderer/src/tokens.css (or drop your CSS in beside it and
#    have the tokens reference it).
# 2. Rebuild the renderer bundle:
cd Renderer && npm run build
# 3. Check the rules still hold:
swift run diffscope-verify
# 4. Look at every state it draws:
DIFFSCOPE_SELFTEST=1 DIFFSCOPE_SNAPSHOT_DIR=/tmp/shots swift run -c release diffscope-app
```

Step 4 is not optional. The suite proves the model and the rules; only the pictures show whether the result is legible — the lesson M8-D paid for, when both lists rendered blank rows in a window that passed every check.

The snapshots written are `structural`, `expanded`, `disclosure`, `moved`, `navigation`, `refresh`, `anchored`, `degraded`, `gutter` and `unified`: the founding wrapper-removal case, the two modes side by side, an invisible-difference badge, a paired move, folds and jumps, a refreshed view, a restored anchor, a ranked degradation notice, the gutter beside line numbers, and the default one-column layout with its two number columns and its sign column.

`terminal-tabs` is the fourth (DEC-067): two shells in one drawer, the strip above them, and the thing no picture can check asserted beside it — that the second tab's output never turns up in the first one's scrollback, which is exactly what one grid replaying a buffer would produce.

The terminal writes three more — `terminal` (a command's output in the grid), `terminal-input` (the input line at a prompt, with the mode chip) and `terminal-follow` (the pane after following a selection into a directory whose name contains a quote and a space). Look at all three: the terminal is the surface where a design most easily makes program output unreadable.

**One photographs the rendered comparison** — `rendered` (DEC-063), two PNGs that differ in exactly four pixels, so the count in the sentence can be wrong in a way no picture would show. Look at the checkerboard first: its grid is deliberately coarser than every change texture, because a reader who takes an alpha change for a diff mark has been told the wrong thing in the wrong language.

`rendered-svg` is the same stage with the `svg-hostile` fixture in it — an SVG carrying a script, an `onload` handler and two remote references, **drawn and inert**. The arm asks for both halves: two images on the page, and `globalThis.__diffscopeHostile` still undefined. Either half alone would pass while the product failed.

**Two photograph the lenses** — `blame` and `history` (DEC-061), taken against a real repository with a commit behind it and work in front of it, so blame has both committed lines and lines that are not committed yet. The thing to look at is the uncommitted marking: it is an edge, not a tint, because tint and texture belong to the change language and a second meaning for them is a meaning nobody can read.

`empty` is the first screen a stranger meets (G3): no repositories, two buttons, and the one place in the window where a control is the subject rather than a tool. Its rim is drawn **around** a standard `NSButton` rather than replacing it — a hand-drawn button loses the key-equivalent ring, the pressed state and the focus behaviour, and none of those is worth a border.

**One more photographs the chrome collapsed** — `collapsed`, both lists reduced to a rail and a spine with 63 files in the tree (DEC-060). It is the density check: the rail has room for three letters and the spine for a kind glyph and a bar, and whether either is legible at that size is a question only the picture answers. It found two defects that every check had passed: the panes drawing at twice their constrained width, and the file spine drawing nothing at all.

**Those twelve photograph the webviews only.** `keyboard` is the exception and the one to look at for the chrome: since M8-J the selftest snapshots the **whole window** while walking a 63-file working tree, so the repository list, the file list, the group headers, the badges and the status line are all in one picture. Build the tree first:

```bash
./Scripts/keyboard-tree.sh /tmp/kbtree
DIFFSCOPE_SELFTEST=1 DIFFSCOPE_SNAPSHOT_DIR=/tmp/shots DIFFSCOPE_KEYBOARD_TREE=/tmp/kbtree \
  swift run -c release diffscope-app
```

The diff pane comes out black in that one — a `WKWebView` renders out of process and `cacheDisplay` cannot see it — so the two pictures are complementary rather than redundant. Other chrome states are reached by pointing `DIFFSCOPE_CONFIG` at a configuration that produces them.

**Look at them at the size the reader sees.** The uncommitted-count caption under the repository list looked absent in a downscaled crop of `keyboard.png` and was perfectly present at full resolution (M8-K). A snapshot answers *is it drawn*; only full resolution answers *is it legible*.

---

## 7. If a design needs something the tokens do not offer

Add the token, use it in `index.html`, mirror it in `Theme.swift` if the chrome needs it too. The check that every declared token is used will fail on an unused one, which is the prompt to either use it or drop it.

If a design needs a *behaviour* change — a mark that reflows, a group that collapses differently, a notice that moves — that is not a token. It is a decision, and it belongs in `04-decision-log.md` before it belongs in a stylesheet.
