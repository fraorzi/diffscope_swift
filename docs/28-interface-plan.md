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

**2. The line background reaches the right edge**
Reported with a screenshot: the tint stops where the text stops.
*Cause to check first:* CodeMirror lines are as wide as their content unless the content element is stretched; look at `.cm-line` width against the scroller, not at the tint's rule.
*Done when:* a line with three characters and a line with two hundred are tinted to the same right edge, at two window widths.

**3. The horizontal scrollbar appears when there is nothing to scroll** (DEC-077, reverses `24-…` §5)
The old rule was *quietened, never removed — a control that vanishes teaches a reader it does not exist*. That rule was written about a control a reader might need. This one **cannot be used**.
*Done when:* `#track` is absent while the content fits, present the moment it does not, and the contract's §5 line is rewritten in the same commit.

**4. Expand cannot be undone**
`⌘E` expands every collapsed range and there is no way back.
*Done when:* the same command collapses again — one key, one button, and the button's label says which way it will go.

**5. The jargon goes** (DEC-077, narrows DEC-017 and DEC-058)
`parser: parsed — tree-sitter tsx`, `confidence: high`, `mode: structural` leave the pane. **Nothing replaces them while everything is normal.**
*The floor, and it does not move:* when a file could not be parsed and is being shown as plain text, the pane says so **in plain words** — *shown as plain text*, not *fallback (F1)*. That is INV-4, the core invariant made visible, and it is the difference between *silent and right* and *silent and wrong*, which look identical.
*Done when:* a normal TSX file draws no chip at all; the `unsupported` and `oversize` fixtures each draw one plain sentence; and `TrustSurfaceChecks` asserts the sentence rather than the chip.

### Tranche 3 — the controls (the owner's word: *liquid glass*)

**6. Real glass, not an imitation** (DEC-077)
`NSGlassEffectView` is real AppKit on macOS 26: `contentView`, `cornerRadius`, `tintColor`, `style` (`.regular` / `.clear`), and **`NSGlassEffectContainerView` with `spacing`, which merges neighbouring glass views as they approach** — that is the morph the owner is asking for, and the system does it.
The package targets `.macOS(.v13)`, so this goes behind `if #available(macOS 26, *)` with the drawn pill as the fallback. **Do not draw a fake blur on older systems** — the owner asked for the real thing or nothing.
*Done when:* the three switches are glass on this machine, the fallback still draws on 13, and a picture of each is in the walkthrough.

**7. A switch shows one option, not all of them** (DEC-077)
Clicking opens a popover with the rest. Applies to scope, mode, lens and layout.
*Watch:* every one of these is also a menu item (`12-…` §9), and the keyboard path must not run through the popover. ⌘1 selects Structural whether or not the popover has ever been opened.
*Done when:* each control shows the chosen option only, the popover lists the others with their states (an unavailable scope still says why), and the keyboard arm still walks all four scopes.

**8. The whole application has no motion** (DEC-064 already admits it)
The register exists and almost nothing uses it. Popovers, the collapse, a scope change, a file selection.
*Watch:* every animation must be neutralised under `prefers-reduced-motion`, the chrome must read `accessibilityDisplayShouldReduceMotion`, durations come from `--ds-motion-*`, and the check already refuses an unguarded one.
*Done when:* the register in the design and the transitions in the code list the same set, and the reduced-motion path is photographed.

### Tranche 4 — the window has no hierarchy

**9. Sections are not visually separated**
*"nie widać przejrzyście gdzie zaczyna się miejsce z diffem, gdzie z plikiem, gdzie wyboru opcji — pewnie przez to że 99% wyglądu to czarny i biały."*
The four surfaces already have four tokens (`--ds-chrome`, `--ds-panel-repos`, `--ds-panel-files`, `--ds-code`) and they are within a few percent of each other. This is a token change plus, probably, a border and an elevation — and it is the one item where the design's own light/dark table is the starting point rather than the constraint.
*Done when:* a greyscale screenshot shows four distinguishable regions, and the contrast check still passes for every ink/surface pair.

**10. The file-kind glyphs carry no colour**
*"nie widzę żeby te ikonki miały kolor np żółty gdy było coś zmieniane w pliku."*
Added / modified / deleted / renamed. Colour **and** the glyph, never colour alone (DEC-035), and the new chrome tokens must be mirrored in `Theme.swift` and clear 4.5:1 (DEC-076's check will refuse them otherwise).
*Done when:* four kinds are distinguishable in colour and in shape, and in a greyscale screenshot.

---

## 3. Two things that are not on the list and are not forgotten

- **The default editor template has no `{line}`.** `⌘⏎` opens the file at the top until the reader configures one. One line to fix; it is the last real gap from the POC session's list.
- **The definition of done has eight items and only the sixth is marked met.** The other seven are backed by checks that pass and by nobody's signature. Either sign them or say what is missing.

---

## 4. How to know you have not broken the thing the product is for

Every item above is presentation. None of them may change what is compared, aligned or validated. The suite is the guard: **1659 checks**, and the ones that matter here are the invariants (INV-1 … INV-5), R-8, and the design contract's two rules — *a design may restyle any mark, it may never hide one*, and *every mark survives greyscale*.

If an item seems to require breaking one of those, it is a decision, not an implementation detail. Write the entry first.
