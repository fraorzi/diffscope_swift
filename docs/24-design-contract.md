# 24 — Design contract

**Status:** Accepted 2026-07-31, gate G2 of `23-release-gates.md`. Authoritative for what a design may change and what it may not.

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
| `Renderer/src/tokens.css` | Every colour, font, size, spacing, radius and border in the diff | **Yes — this is the file** |
| `Renderer/src/index.html` | Structure and which token each rule uses | Only to change *which* token a rule reads |
| `Sources/diffscope-app/Theme.swift` | The same values for the AppKit chrome: window, both lists, status line, empty state | Yes, mirroring the token names |
| `Renderer/src/main.js` | Which class goes on which range | No |

**The chrome is two thirds of the window.** A design that stops at the edge of the webview leaves the repository list, the file list and the status line looking like a different application, so `Theme.swift` mirrors the token names rather than inventing its own.

The defaults are the system's own (`Canvas`, `CanvasText`), so light and dark mode work with no effort. Replace them with literal colours if you like — the checks care about *where* values are declared, not what they are.

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
| `#stage`, `#left`, `#right` | Layout of the two panes | No |
| `#unrenderable` | Shown when the content is not text that can be displayed | **Yes** |
| `cm-*` | CodeMirror's own classes: editor, scroller, gutters, line numbers | No, except the gutter ones |

---

## 4. What the checks will refuse

1. **A literal colour, font stack or pixel size outside `tokens.css`** — in the stylesheet or set from JavaScript. One file, or the boundary lasts until the next edit.
2. **A `var(--ds-…)` that no token defines.** The property silently disappears and the mark quietly becomes nothing.
3. **A token nobody uses.** A value a designer would change to no effect is worse than one not offered.
4. **`display: none`, `visibility: hidden` or `opacity: 0`** on any load-bearing class, in the source or in the computed style.
5. **A mark reduced to colour alone.** Every mark must carry at least one signal that survives greyscale — texture, underline, outline, edge or weight. DEC-035: colour alone fails in a screenshot, in greyscale, and for a colour-blind reader.
6. **A notice bar laid out to nothing.**
7. **A font size or colour written inline in the AppKit chrome** rather than read from `Theme.swift`.

---

## 5. Rules the checks cannot enforce, and that still hold

- **A disclosed count stays legible wherever grouping quietens something** (DEC-017). Grouping is permitted *because* the count is shown; a design that shrinks it to four grey pixels keeps the letter and loses the point.
- **Quietening is not disappearing.** `ds-formatting` should read as "present and less shouty", never as "absent".
- **Nothing animates.** DEC-016 commits to reduced motion by construction — there are no transitions to disable, and adding one would need that decision reopened.
- **The two panes must stay vertically aligned.** Anything that changes line height on one side only breaks the comparison the product exists to show.

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

The snapshots written are `structural`, `expanded`, `disclosure`, `moved`, `navigation`, `refresh`, `anchored`, `degraded` and `gutter`: the founding wrapper-removal case, the two modes side by side, an invisible-difference badge, a paired move, folds and jumps, a refreshed view, a restored anchor, a ranked degradation notice, and the gutter beside line numbers.

**They photograph the webview only.** The AppKit chrome — both lists, the status line, the empty state — has to be looked at by running the application and taking a screenshot of the window, and there is no automation for it on this machine (`osascript` has no accessibility permission). States are reached by pointing `DIFFSCOPE_CONFIG` at a configuration that produces them.

---

## 7. If a design needs something the tokens do not offer

Add the token, use it in `index.html`, mirror it in `Theme.swift` if the chrome needs it too. The check that every declared token is used will fail on an unused one, which is the prompt to either use it or drop it.

If a design needs a *behaviour* change — a mark that reflows, a group that collapses differently, a notice that moves — that is not a token. It is a decision, and it belongs in `04-decision-log.md` before it belongs in a stylesheet.
