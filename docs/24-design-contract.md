# 24 — Design contract

**Status:** Accepted 2026-07-31, gate G2 of `23-release-gates.md`. Authoritative for what a design may change and what it may not. **Amended 2026-08-09** by DEC-059 (a sign column), DEC-063 (surfaces that render), DEC-064 (motion) and DEC-066 (the token table as the delivery format).

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
| `ds-chip` | One notice in the bar | **Yes** |
| `ds-chip-alert` | A chip that reports the tool catching itself | **Yes** |
| `#notices` | The bar carrying every notice — INV-4 made visible | **Yes** |
| `ds-notice` | An inline notice inside the document | **Yes** |
| `#unrenderable` | Shown when the content is not text that can be displayed, and why | **Yes** |
| `ds-sign` | The `+` / `−` column in unified (DEC-059) | **Yes.** With no panes, this is the only signal of direction that survives greyscale |
| `ds-line-add`, `ds-line-del` | Direction as a tint behind the line | No — they *reinforce* `ds-sign` and may be removed. Removing the sign column is what the rule above forbids |
| `#unified` | The one-column layout, and the default (DEC-059) | No, as layout |
| `ds-gutter-old`, `ds-gutter-new`, `ds-gutter-sign` | The three gutters of the unified layout: the two number columns and the sign column | **The sign gutter is**, for the reason `ds-sign` is. The number columns are how a reader says *where* — restyle freely, do not collapse them into one |
| `#stage`, `#left`, `#right` | The two-pane layout, reached by ⌥⌘→ | No, as layout |
| `#lens` | The Blame and History lenses (DEC-061) | No, as layout |
| `ds-lens-row` | One line of blame, or one commit | **Yes.** A row that is not drawn is a line whose author, or a commit, the reader was told existed |
| `ds-lens-uncommitted` | Work that is not committed yet — **marked by an edge, never tinted** | **Yes**, and the shape is the point: tint and texture belong to the change language, and a second meaning for them is a meaning nobody can read |
| `ds-lens-sha`, `ds-lens-who`, `ds-lens-when`, `ds-lens-line`, `ds-lens-text` | The columns of a blame row | **Yes** — each is one of the questions the lens exists to answer |
| `ds-lens-subject`, `ds-lens-refs` | The columns a commit adds | **Yes** |
| `ds-lens-header` | What the lens says above its list, including that nothing is fetched | **Yes** |
| `cm-*` | CodeMirror's own classes: editor, scroller, gutters, line numbers | No, except the gutter ones |

### The terminal pane

Added after this contract was first written, and missing from it until M8-P — the terminal landed the day after G2 passed, so the document described a window with one webview in it. Every element the pane emits:

| Element | Means | Load-bearing |
|---|---|---|
| `#grid` | The xterm.js screen — everything the shell prints | **Yes.** Output that cannot be read is output that was not shown |
| `#input-row` | The command line at a prompt (DEC-055) | No, as layout |
| `#mode` | Which mode the keyboard is in: prompt, program, or forced raw | **Yes.** The reader has to know where their keystrokes are going |
| `#mode[data-raw="true"]` | Raw forced by ⌥⌘R — **dashed border and heavier weight, not a colour** | **Yes**, and the shape is the point (DEC-035) |
| `#cwd` | Where the shell says it is (OSC 7) | **Yes** |
| `#cwd[data-diverged="true"]` | The shell is **not** in the selected repository — dotted underline | **Yes.** This is the terminal's own version of the honesty rule: the pane must never imply the shell is where the diff is |
| `#line` | The real text field the macOS motions come from (T0) | **Yes** — hidden by `visibility` when there is no prompt, never removed, so the row keeps its explanation |
| `--ds-term-black` … `--ds-term-bright-white` | The sixteen colours a program addresses by index | **Yes**, as a set: a palette collapsed toward the background makes some programs unreadable |
| `--ds-term-fg`, `--ds-term-bg`, `--ds-term-cursor`, `--ds-term-selection` | The four values xterm.js reads outside the palette | **Yes**, and **as a set**: any one left undeclared is a colour the emulator invents |

### Surfaces that render (DEC-063)

An image or an SVG is compared by being drawn, and the drawing is a surface with its own rules.

| Element | Means | Load-bearing |
|---|---|---|
| `#rendered` | The Before / After, Blend, Split or Pixel-diff stage | **Yes** |
| `ds-render-bar`, `ds-render-mode` | The four modes, and which one is on | **Yes** — a mode that cannot be seen is a comparison the reader cannot ask for |
| `ds-mode-off` | A mode unavailable here, **with its reason beside it** | **Yes** — disabled and stated, never hidden |
| `ds-render-summary` | What the picture cannot say: dimensions, bytes, differing pixels | **Yes.** This is where "renders identically, bytes differ" lives |
| `ds-render-stage`, `ds-render-panel`, `ds-render-overlay` | Layout of the stage | No |
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
5. **A mark reduced to colour alone.** Every mark must carry at least one signal that survives greyscale — texture, underline, outline, edge or weight. DEC-035: colour alone fails in a screenshot, in greyscale, and for a colour-blind reader.
6. **A notice bar laid out to nothing.**
7. **A font size or colour written inline in the AppKit chrome** rather than read from `Theme.swift`.
8. **A token marked mirrored with no counterpart in `Theme.swift`** (DEC-066). The flag is a promise about a second file; unkept, it leaves two thirds of the window styled by inference.
9. **An animated property with no off switch** (DEC-064). Every animation must be neutralised inside `@media (prefers-reduced-motion: reduce)`, and the check carries two negative controls: an unguarded animation, and a reduce block that switches nothing off. Durations and curves are tokens (`--ds-motion-*`) so the register and the stylesheet cannot drift apart, and the AppKit chrome — which has no media query — must read `accessibilityDisplayShouldReduceMotion` before it animates.
10. **SVG markup inserted into the document** rather than loaded through an `<img>` (DEC-063). This is repository content reaching a place where it can execute.

---

## 5. Rules the checks cannot enforce, and that still hold

- **A disclosed count stays legible wherever grouping quietens something** (DEC-017). Grouping is permitted *because* the count is shown; a design that shrinks it to four grey pixels keeps the letter and loses the point.
- **Quietening is not disappearing.** `ds-formatting` should read as "present and less shouty", never as "absent".
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

The terminal writes three more — `terminal` (a command's output in the grid), `terminal-input` (the input line at a prompt, with the mode chip) and `terminal-follow` (the pane after following a selection into a directory whose name contains a quote and a space). Look at all three: the terminal is the surface where a design most easily makes program output unreadable.

**One photographs the rendered comparison** — `rendered` (DEC-063), two PNGs that differ in exactly four pixels, so the count in the sentence can be wrong in a way no picture would show. Look at the checkerboard first: its grid is deliberately coarser than every change texture, because a reader who takes an alpha change for a diff mark has been told the wrong thing in the wrong language.

**Two photograph the lenses** — `blame` and `history` (DEC-061), taken against a real repository with a commit behind it and work in front of it, so blame has both committed lines and lines that are not committed yet. The thing to look at is the uncommitted marking: it is an edge, not a tint, because tint and texture belong to the change language and a second meaning for them is a meaning nobody can read.

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
