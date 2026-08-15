# 28 — The interface plan: what the owner asked for, and how to know it is done

**Status:** Accepted 2026-08-13. The work list for [DEC-077](04-decision-log.md). Authoritative for **what is left to build in the interface** and for what counts as finished; the decision log still wins on *why*.

This document exists because the owner's second session produced fourteen items in one message, four are built, and ten are not. A list in a chat message is not a plan: it has no order, no acceptance test, and no record of which recorded decision each item reverses.

---

## 0. The sentence the whole list comes from

> *"wyobraź sobie że tworzysz UI dla juniora ale frontenda a nie experta od algorytmów, diffów, gita … jeśli coś nie wiadomo czy mi się przyda jako info czy nie, to usuń, najwyżej jak będę miał chęć dodania to osobno poproszę."*

Read every item below against that. This project spent eight milestones building for a reader auditing a diff engine. The reader it is for opens a repository, looks at what changed, and commits.

**The apparatus is not the display.** The invariants, the validator and the checks are what make the product's claim true. The chips, the rings, the printed keystrokes were one way of *saying* it, and the loudest one available. Removing the saying does not remove the proving — and one sentence stays for exactly that reason (§2, item 5).

---

## 1. What is already built (2026-08-13, `930e621`)

| Asked | Landed |
|---|---|
| remove the blue focus rings | gone; the arm asserts **nothing** draws one, on the keyboard and after a click |
| take the keystrokes off the controls | gone from the pills, the status line and the base block; a check refuses a hand-written modifier run in any string the chrome shows, and found one that had been there since M8 |
| the sidebars would not collapse by dragging | fixed — the pane-width constraints were restoring themselves after every drag; `splitViewDidResizeSubviews` writes the drawn widths back |
| add a control to collapse/expand | a chevron in each pane header |
| the open repository is not marked in the list | it had **no selected row at all** after any refresh; fixed, and marked with a bar at its leading edge |

---

## 2. What is left, in order

The order is by *what a reader hits first*, not by effort. Each item names the decision that governs it, what will refuse it, and **how to prove it is done** — a claim with no way to check it is a claim this project does not accept.

### Tranche 2 — the diff pane reads badly (do this first)

**1. Underlines out, tint in** (DEC-077, amends DEC-035) — **landed**
A changed line gets a tint across the **whole line**; the bytes that actually changed get the same hue at a **lower transparency**. No underlines — they are what makes the line hard to read.
*What will refuse it:* `DesignChecks` requires every mark to carry a signal that survives greyscale, and the underline was that signal. The rule is restated, not dropped: **the two tints must differ in luminance**, and the sign column (`ds-sign`) and the gutter edge stay. Add the luminance assertion to the check in the same commit.
*Done when:* the two tints differ measurably in luminance, both survive a greyscale conversion, and `structural.png` / `unified.png` are looked at full-size.

*How it landed.* `ds-line-changed` is a **line** decoration in the two-pane layout, so it reaches the whole line box rather than stopping at the text, and it is built from the same `changedLines` the gutter edge is built from — the selftest holds the two counts equal, which is how a decoration that is computed and never drawn gets caught. Unified keeps `ds-line-add` / `ds-line-del` and gains `--ds-tint-add-strong` / `--ds-tint-del-strong` for the bytes, so the byte tint is the same hue as the line it sits on in every layout. Three pairs are measured over `--ds-code` in both appearances — **1.27:1 to 1.53:1 apart**, against a floor of 1.20 — and the line tint is held 1.05:1 off the paper as well, because a line tint the surface swallows is a changed line nobody sees and a distinct byte tint would not repair it.

**The negative control failed first, and it was right to.** The obvious control — the design's own green and red at their shipped alphas — measures **1.289:1** apart and would have *passed* the check it exists to fail. The red's alpha is solved for instead, so green at .20 and red at .15 land on the same relative luminance over paper and the control measures 1.00:1. `--ds-underline-thickness` and its quiet twin are gone from the token file; `--ds-underline-offset` stays, because the terminal still draws a dotted underline for a shell that has wandered out of the selected repository.

**2. The line background reaches the right edge** — **landed**
Reported with a screenshot: the tint stops where the text stops.
*Cause to check first:* CodeMirror lines are as wide as their content unless the content element is stretched; look at `.cm-line` width against the scroller, not at the tint's rule.
*Done when:* a line with three characters and a line with two hundred are tinted to the same right edge, at two window widths.

*How it landed, and the cause was one word.* `applyLayout` shows the unified host with `display: flex`, which made it a **row** container holding one item — and a flex item with no `flex-grow` is as wide as its content. So the editor was as wide as its longest line, every line box ended there, and the pane went black to the right of it. `flex-direction: column` is the whole fix; nothing was wrong with the tint's rule, which is why the acceptance test measures the line box rather than photographing the colour. `diffscopeWidths` reports it, the arm asserts `minLine == maxLine == available` **and `scrollerWidth == hostWidth`** at two window widths — the second is taken by resizing the window 220 pt, because a layout laid out once is a layout nobody has checked (M9-K).

**The first control passed, for the second time in two items.** Injecting the missing `flex-direction` back shrinks the scroller *and* the lines together, so every relation inside the editor still agreed while the pane sat half empty — the editor has to be measured against the pane it is in, not only against itself.

*And the instrument was lying in every picture.* The same probe reported eleven of fourteen lines with no gutter row level with them, and a photograph appeared to confirm it. It is not real: **CodeMirror re-measures inside an animation frame, and `requestAnimationFrame` is suspended while the window is occluded**, which a terminal-launched selftest always is (T1-A). The views keep their construction-time line height — 14 or 16.87 px against the 15 the stylesheet lays lines out at — and the *gutter rows* are sized from it. Forcing the pending measurement to be read (`diffscopeSettle`, called before every snapshot now) puts the rows back on their lines. Every unified snapshot this project has taken before today has a drifted number column in it that no reader has ever seen.

**3. The horizontal scrollbar appears when there is nothing to scroll** (DEC-077, reverses `24-…` §3) — **landed**
The old rule was *quietened, never removed — a control that vanishes teaches a reader it does not exist*. That rule was written about a control a reader might need. This one **cannot be used**.
*Done when:* `#track` is absent while the content fits, present the moment it does not, and the contract's line is rewritten in the same commit. *(The plan said §5; the rule is in §3's class table.)*

*How it landed.* `updateTrack` sets `hidden` beside `disabled`, `#track[hidden]` is `display: none`, and `--ds-track-idle` is gone from the token file — a token nobody references is a value a designer would change to no effect. **Both halves are asserted**, in the live document, on a two-line file of three characters and three hundred: wrapping off, the track is there and the span is 1661; wrapping on, it is gone and the span is 0. A control that is always absent satisfies half this rule, which is why the two states are each other's control.

**And it found a second defect that dimming had been hiding.** `updateTrack` took its span from `left.scrollDOM` whatever layout was drawn — so **unified, the default since DEC-059, reported nothing to scroll however long its lines were**, and the one column had no keyboard-reachable way to move sideways at all (`12-…` §5.4). The track reads the showing layout now, the unified scroller drives it, and toggling wrap updates it — that toggle is the one act that creates something to scroll to without changing the document.

The same arm carries item 2's stated acceptance test in the case that actually exercises it: with wrapping off, a three-character line and a three-hundred-character line measure **2411 px each** — the same right edge, which is the long line's rather than the pane's.

**4. Expand cannot be undone** ([DEC-078](04-decision-log.md), amends DEC-017) — **landed**
`⌘E` expands every collapsed range and there is no way back.
*Done when:* the same command collapses again — one key, one button, and the button's label says which way it will go.

*How it landed.* One command, both directions: expand everything **unless every fold is already open**, in which case collapse everything. Deliberately *everything* rather than *anything* — a reader who has clicked one fold open, or who has jumped into one (`goToStop` opens whatever covers its target), presses ⌘E to open the rest, which is the reading of the key they already have. The button reads `Expand` or `Collapse` and is recomputed with the footer; the menu item is renamed to name the toggle rather than one of its directions.

The arm asks for the **round trip**, not for either direction: `2 → 0 → 2` folds and `Expand → Collapse → Expand`, because the defect reported was not *collapse is missing* but *there is no way back*.

*And it closed DEC-077 in the one place that had been missed.* The button's label was `Expand ⌘E`. The keystroke rule was written about the AppKit chrome and `ChromeLabels`, so nothing was looking at the webview's own markup; a check now refuses a modifier run in it, with that label as its control.

**5. The jargon goes** (DEC-077, narrows DEC-017 and DEC-058) — **landed**
`parser: parsed — tree-sitter tsx`, `confidence: high`, `mode: structural` leave the pane. **Nothing replaces them while everything is normal.**
*The floor, and it does not move:* when a file could not be parsed and is being shown as plain text, the pane says so **in plain words** — *shown as plain text*, not *fallback (F1)*. That is INV-4, the core invariant made visible, and it is the difference between *silent and right* and *silent and wrong*, which look identical.
*Done when:* a normal TSX file draws no chip at all; the `unsupported` and `oversize` fixtures each draw one plain sentence; and `TrustSurfaceChecks` asserts the sentence rather than the chip.

*How it landed.* The three chips are not drawn. **Everything behind them is untouched** — `chipText`, `modeChip`, the parser state, the grammar name and the confidence count are all still computed, still encoded and still asserted where they were; what changed is who they are shown to. The structural selftest arm is **inverted**: it used to require `parser: parsed` and `mode: structural` in the document and now requires their absence, which is the harder of the two to keep.

*The floor, and it is now said once.* A file that could not be read as code drew a fallback notice **and** a parser chip **and** a disagreeing mode pill — three overlapping wordings of one fact, in the vocabulary of the thing that produced it. What it draws now is one sentence: *This file is shown as plain text — <why>. Every difference in it is still shown.* The three parts `13-…` §6 requires are all still there; the subject is the file rather than the machinery. `ParserStateReport.plainSentence` covers the one case with no notice behind it — a **partial** parse, where the structural result stands and part of the file sits inside it without a structural claim, and nothing else on screen would say so.

*Silent while normal, in the reader's words when not.* `confidence: high` is gone; below the floor it reads *N parts of this file could not be matched confidently — they are marked in the diff*. The mode pill is gone outright: the case where the selection and the path disagree is exactly the case the fallback sentence describes.

**The controls are the old wordings.** A check that accepted *Structural analysis unavailable* would be a check about nothing, so two of them assert it is absent.

### Tranche 3 — the controls (the owner's word: *liquid glass*)

**6. Real glass, not an imitation** (DEC-077) — **built, and one half of its acceptance test cannot be met on this machine**
`NSGlassEffectView` is real AppKit on macOS 26: `contentView`, `cornerRadius`, `tintColor`, `style` (`.regular` / `.clear`), and **`NSGlassEffectContainerView` with `spacing`, which merges neighbouring glass views as they approach** — that is the morph the owner is asking for, and the system does it.
The package targets `.macOS(.v13)`, so this goes behind `if #available(macOS 26, *)` with the drawn pill as the fallback. **Do not draw a fake blur on older systems** — the owner asked for the real thing or nothing.
*Done when:* the three switches are glass on this machine, the fallback still draws on 13, and a picture of each is in the walkthrough.

*How it landed.* **Four** switches, not three — scope, mode, lens and layout are all `PillControl`. The raised pill is an `NSGlassEffectView` with `style = .regular` and the chosen segment's title as its `contentView`, inside an `NSGlassEffectContainerView` whose `spacing` comes from `Theme.glassMergeSpacing`. Everything is behind `guard #available(macOS 26, *)`, the drawn pill is still the branch that runs below it, and a check refuses `NSVisualEffectView`, a blur filter or a blending mode anywhere in the chrome — the owner asked for the real thing or nothing.

**`contentView` is *filled* by the view it is given, on both classes.** Handing the container the glass directly made the thumb the size of the whole control: one solid pill across all four scopes with the labels behind it. The container's `contentView` is a plain transparent host and the thumb is placed inside it by frame.

**The picture cannot be taken here, and this is the gap to close with the owner.** `cacheDisplay` renders an `NSGlassEffectView` as a flat fill exactly as it renders a `WKWebView` as black, and the window-server path needs screen-recording permission and an unoccluded window, which a terminal-launched selftest is not. So the arm asserts what a photograph could not settle anyway — that the view is **real AppKit** (`NSGlassEffectView`, by class name), that it covers the chosen segment and only it, that it is not raised when that segment is unavailable, and that the title is inside the glass with the right words and a non-zero frame, which is the one failure a flat capture could be hiding. **Ask the owner for a screenshot of the scope row in both appearances.**

**7. A switch shows one option, not all of them** (DEC-077) — **landed**
Clicking opens a popover with the rest. Applies to scope, mode, lens and layout.
*Watch:* every one of these is also a menu item (`12-…` §9), and the keyboard path must not run through the popover. ⌘1 selects Structural whether or not the popover has ever been opened.
*Done when:* each control shows the chosen option only, the popover lists the others with their states (an unavailable scope still says why), and the keyboard arm still walks all four scopes.

*How it landed.* The control is the chosen option, the glass thumb, and a chevron — **a control showing one of several with nothing to say so reads as a label**. Clicking opens an `NSPopover` holding `SegmentList`: one row per option, the chosen one marked by a **glyph as well as by weight** (a mark that is only a weight is a mark greyscale keeps and a hurried reader does not), and every option that cannot be chosen carrying a dashed rim and **the reason underneath it** rather than in a tooltip — which is `12-…` §3, and the thing a system control renders as grey and silent.

**The control is sized to the widest option, not to the chosen one.** A switch that changes width when the reader chooses something moves every neighbour in the row, and both the scope row and the status line are rows of neighbours (M9-K: a control that grows takes the window with it). The scope switch went from 268 pt to 92.

*The keyboard does not go near it.* ⌘1 is a menu item calling `selectMode(_:)`, and the arm drives that selector **while the scope popover is open** — if the popover were on the path, that would either do nothing or need the list open on the right control. Two routes to one command is DEC-071's rule, not an exception to it.

**8. The whole application has no motion** (DEC-064 already admits it; [DEC-079](04-decision-log.md) makes the register real) — **landed, with one half of its acceptance test recorded as unphotographable**
The register exists and almost nothing uses it. Popovers, the collapse, a scope change, a file selection.
*Watch:* every animation must be neutralised under `prefers-reduced-motion`, the chrome must read `accessibilityDisplayShouldReduceMotion`, durations come from `--ds-motion-*`, and the check already refuses an unguarded one.
*Done when:* the register in the design and the transitions in the code list the same set, and the reduced-motion path is photographed.

*How it landed, and the first half of that test could not be run as written.* **The register was in a document nobody here can open.** DEC-064 put it in the adopted design's Motion table, so *is this transition registered* had no answer — [DEC-079](04-decision-log.md) moves it into `24-…` §5 and a check requires the table and the stylesheet to name the same set, in both directions. A transition added to the code with no row fails; a row with nothing behind it fails. Ask the owner to **review** the table against theirs rather than to supply it.

Eight rows ship: three that already existed (the notice bar, a chip's rim, a fold under the pointer) and five that did not — the footer's button and a lens row under the pointer, the pane collapse (which was built but unregistered), **a switch's options arriving**, and **the chosen option changing**, which is the one a reader can otherwise miss: the control shows one option, so the change of that option is the whole answer to what they pressed.

**The guard check had been satisfied by one file.** It asked whether the chrome reads `accessibilityDisplayShouldReduceMotion` *anywhere*, which is exactly DEC-064's named failure mode — remembered for the first five transitions, forgotten for the sixth. It counts now: as many guards as animated sites, with an unguarded site as its control.

*The reduced-motion path is not photographed, and it is not photographable here.* It is a **system setting**, and the contract forbids a preference of our own that could disagree with it — so a selftest cannot turn it on, and adding a switch to make the picture possible would break the rule the picture exists to prove. What the path produces is in every case a *static state that is already photographed*: the pane at the other width (`collapsed.png`), the list simply present, the other title with nothing in between. The guarantee is carried by the two checks instead: every animated property neutralised under `prefers-reduced-motion` with two negative controls, and every chrome site reading the system setting.

### Tranche 4 — the window has no hierarchy

**9. Sections are not visually separated** ([DEC-080](04-decision-log.md)) — **landed**
*"nie widać przejrzyście gdzie zaczyna się miejsce z diffem, gdzie z plikiem, gdzie wyboru opcji — pewnie przez to że 99% wyglądu to czarny i biały."*
The four surfaces already have four tokens (`--ds-chrome`, `--ds-panel-repos`, `--ds-panel-files`, `--ds-code`) and they are within a few percent of each other. This is a token change plus, probably, a border and an elevation — and it is the one item where the design's own light/dark table is the starting point rather than the constraint.
*Done when:* a greyscale screenshot shows four distinguishable regions, and the contrast check still passes for every ink/surface pair.

*How it landed.* A **ladder**, from the content outward, with a floor of **1.10:1 per step** — DEC-076's floor, for DEC-076's reason. Light: `#ffffff` → `#f2f2f6` → `#e6e6ed` → `#d9d9e1`. Dark: `#000000` → `#131317` → `#1e1e25` → `#26262d`. No border and no elevation were needed; the values were the whole of it.

**Every colour check this project has was about ink on a surface. Nothing had ever asked whether two surfaces differ.** In light they spanned nineteen values out of 255; in dark the ladder **was not monotone** — the repository pane sat darker than the file pane with the chrome above both lighter than either — so the window had no consistent sense of front and back at all. The check is now two claims: every adjacent step clears 1.10:1, and the ladder runs *one way*, with two controls — the shipped table (widest step 1.09:1) and the dark inversion, which large steps alone would have passed.

**Two inks moved with the surfaces.** Darker panels take `--ds-faint` under 4.5:1, so DEC-076's arithmetic was redone rather than inherited: light's second and third inks are `#42424a` and `#57575f`, and every ink/surface pair now clears **4.91:1** in light and **4.72:1** in dark.

*Measured off the picture, not looked at:* the modal colour of a box in each region, in both appearances, agrees with the token to the last channel — `#d9d9e0`, `#e6e6ec`, `#f2f2f6`, `#ffffff` in light at 93–100% of their boxes.

**This is the first time a transcribed value has moved,** which is why it is [DEC-080](04-decision-log.md) rather than a token edit. Ask the owner whether the ladder should be steeper or shallower; a screenshot would settle it in a second.

**10. The file-kind glyphs carry no colour** ([DEC-081](04-decision-log.md)) — **landed**
*"nie widzę żeby te ikonki miały kolor np żółty gdy było coś zmieniane w pliku."*
Added / modified / deleted / renamed. Colour **and** the glyph, never colour alone (DEC-035), and the new chrome tokens must be mirrored in `Theme.swift` and clear 4.5:1 (DEC-076's check will refuse them otherwise).
*Done when:* four kinds are distinguishable in colour and in shape, and in a greyscale screenshot.

*How it landed.* Four tokens — `--ds-kind-added` `#16602a`/`#5cd67d`, `-modified` `#7a5300`/`#e8bd45`, `-deleted` `#9e1420`/`#ff8b84`, `-renamed` `#1a4f9c`/`#7fb8ff` — mirrored in `Theme.swift`, on the glyph in the list **and** on the collapsed spine's bar, so the rail and the full list say the same thing the same way. Untracked, type-changed and unmerged keep the ordinary ink: a kind with no colour is still a kind with a glyph, and three more hues invented to fill the table would weaken the four that mean something.

**Twelve new pairs in the contrast list**, because a row is drawn on three surfaces — the file pane, the repository pane and a selected row — and they pass at 4.51:1 to 7.44:1. That list is hand-maintained for exactly this: DEC-076 built it after the tertiary ink was found failing on four surfaces nobody had measured, so adding a colour to the window means adding its rows.

*Greyscale is unchanged, and that is the point.* The glyph vocabulary is untouched, so every kind survives a screenshot exactly as it did before — the check asserts that the seven glyphs are still seven different characters, with two kinds sharing one as its control. `24-…` records the adopted design getting this backwards once already, drawing the spine's bars by hue alone.

The keyboard-tree fixture holds modified and deleted files only, so the picture shows two of the four; the other two are held by the check rather than by a photograph.

---

## 3. Two things that are not on the list and are not forgotten

- **The default editor template had no `{line}`** — **closed 2026-08-14 by [DEC-082](04-decision-log.md)**, and calling it *one line to fix* was wrong twice over. It is one line, but `open -a` cannot take a line at all, so the question was which mechanism rather than which string. Measured: the `jetbrains://` URL leaves `#` and `?` raw in a path, so `…/note#1/a.ts` arrives as a URL fragment and the editor opens **the wrong file, silently**. The default is `/Applications/WebStorm.app/Contents/MacOS/webstorm --line {line} {file}` — no URL is parsed, so those are ordinary characters, and a WebStorm that is not at that path fails **visibly** as `notLaunched` rather than opening the wrong line quietly.
- **The definition of done has eight items and only the sixth is marked met.** The other seven are backed by checks that pass and by nobody's signature. Either sign them or say what is missing.

---

## 4. How to know you have not broken the thing the product is for

Every item above is presentation. None of them may change what is compared, aligned or validated. The suite is the guard: **1659 checks**, and the ones that matter here are the invariants (INV-1 … INV-5), R-8, and the design contract's two rules — *a design may restyle any mark, it may never hide one*, and *every mark survives greyscale*.

If an item seems to require breaking one of those, it is a decision, not an implementation detail. Write the entry first.

---

## 5. The third session ([DEC-083](04-decision-log.md)), on the packaged build `03d963e`

The owner used it against five real repositories. Seven reports, in the order a reader hits them, each with what will refuse it and how to prove it is done.

**1. The selected file is not marked** — a defect, not a styling gap
The repository list marks the open repository with a fill and a leading bar; the file list marks nothing. `fileTable.selectRowIndexes` is called in **three places and all three are in the selftest** — the product path was never written. This is DEC-077's repository fix, on the second list, never carried across.
*Done when:* the row for the file being shown is selected after a sweep and after a refresh, not only after a click, and an arm asserts the selected row's path equals the shown file's.

**2. The three surfaces do not start at the same height**
Measured: the pane headers are `Theme.paneHeaderHeight` = **22 pt**, and the diff pane's control band is `space4 + 24 + space4` = **40 pt**. The code's background begins 18 pt below the lists'.
*Done when:* the tops of the three panes' content agree to the pixel, asserted from the drawn frames rather than from the constraints, at two window widths.

**3. Nothing says it can be clicked, and some of it is hard to hit**
`cursor: pointer` appears twice in `index.html` and **nowhere in the chrome** — no `NSCursor`, no `resetCursorRects` in `Sources/diffscope-app`. The `+` and the two chevrons are unbordered buttons with no size of their own, so the target is the glyph at 11 pt; collapsed, that chevron is the only thing in a 44 pt rail.
*Done when:* every pointer affordance in both webviews declares `cursor: pointer`, every control the chrome draws sets `pointingHand`, and the `+` and both chevrons measure at least **24 × 24 pt**, asserted from their frames.

**4. The change textures go** (amends DEC-035)
Seven `--ds-tex-*` gradients, whose only job is to tell one *kind* of mark from another.
*What will refuse it:* the greyscale rule — and it is restated rather than dropped for the second time in two days: **the tint pair is the signal**, and it already differs in luminance by measurement. `ds-moved` keeps its dashed outline, `ds-invisible` its dotted one.
*Done when:* no `--ds-tex-*` token remains, every mark still passes the greyscale check on its tint pair, and `structural.png` is looked at full-size in both appearances.

**5. The line notes go, and the legend with them** (narrows DEC-017, DEC-058)
`ds-note` — `formatting`, `uncertain`, `reordered`, `M1`, `inserted` — and `#showing`'s *"+ added, − removed in the sign column"*.
*The floor:* `#showing` keeps **what is being compared**, and `#diff-footer` keeps the grouped count DEC-017 permits grouping *because of*. INV-4's sentence is untouched.
*Done when:* no `.ds-note` is emitted, `#showing` names the comparison and nothing else, the footer's count still draws, and `ds-note` leaves the contract's class table in the same commit.

**6. The metal-rimmed buttons of the adopted design** — **blocked, and not on effort**
The design is behind the owner's login. This is the fourth thing that cannot be read from here, after the glass, DEC-080's ladder and DEC-081's hues.
*Done when:* the owner sends a screenshot of the `+` button, its values are transcribed the way the token table was, and `Theme.swift` and the contract carry them.
