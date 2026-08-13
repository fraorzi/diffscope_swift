# 27 — The adopted design, and how it maps onto the build

**Status:** Accepted 2026-08-09. Entry point for the interface work. Authoritative for *where the design lives and what it is allowed to decide*; the decisions it produced are in [04-decision-log.md](04-decision-log.md), which wins wherever this document and it disagree.

---

## 1. Where it lives

The design is a Claude Design project, not a file in this repository:

`https://claude.ai/design/p/3ba70f60-9233-448d-a9f0-43c4bb152d82`

| File | Holds |
|---|---|
| `DiffScope.dc.html` | The specification document: every screen, the change language in three appearances, the states, the trust cards, the motion register, the token table, the keyboard map, the rationale |
| `ReviewScreen.dc.html` | The window itself, as one component with props for every state — appearance, mode, layout, lens, scope, availability, base age, collapses, terminal mode, watcher state |
| `ImageCompare.dc.html` | The rendered comparison (DEC-063): four modes, three file classes, four states |
| `ChangeLanguage.dc.html` | The two legends — file status and region marks — in dark, light and **greyscale**, which is the column that proves DEC-035 rather than asserting it |
| `AppIcon.dc.html` | One vector in units of the tile, drawn at 1024, 128, 32 and 16 |

**The design is read, not linked.** Nothing in the build fetches it; it is transcribed into `tokens.css`, `Theme.swift`, `index.html` and `terminal.html`, and from that moment the repository is the source of truth for what ships.

## 2. What the review of it settled

Eight decisions, all dated 2026-08-09:

| | |
|---|---|
| [DEC-059](04-decision-log.md) | Unified is the default layout; side-by-side is a mode; direction is carried by a `+` / `−` sign column |
| DEC-060 | Three independent collapses, not one focus mode |
| DEC-061 | History and Blame enter version one as lenses over the selected file |
| DEC-062 | Search within the diff enters version one |
| DEC-063 | Rendered comparison for images and SVG, and the `<img>` boundary |
| DEC-064 | Motion enters the product; reduced motion becomes a checked path rather than an absent one |
| DEC-065 | The keyboard map is re-cut around arrows and modifier tiers |
| DEC-066 | The design is delivered as a token table, and the table says which tokens the chrome mirrors |

Four of them amend earlier decisions (DEC-014, DEC-008, DEC-017, DEC-016) and one supersedes the contents — not the mechanism — of DEC-057. Each amended entry carries a pointer; none was edited to hide what it used to say.

## 3. What the design is not allowed to decide

The contract's rule is unchanged: **a design may restyle any mark, it may never hide one** ([24-design-contract.md](24-design-contract.md) §1). Three things in the adopted design were changed during review because they broke it, and they are recorded here so a later revision does not reintroduce them:

- **Added and removed lines carried the same glyph and the same texture**, separated by hue and by which pane they sat in. In unified there are no panes, so the distinction was hue alone. Fixed by the sign column, which is why that column is load-bearing.
- **The collapsed file list carried change kind by colour alone.** Fixed by putting the kind glyph on each bar.
- **The tertiary text colour failed contrast** at 2.7:1 in light and 3.8:1 in dark, at 10–11 px. Fixed by measurement, not by eye; the current pair is 5.1:1 and 5.8:1.

The general form: **anything the design carries in hue must also be carried by shape**, and the greyscale column of `ChangeLanguage.dc.html` is where that gets checked before any code is written.

## 4. Order of work

The dependencies are real; this order avoids doing anything twice.

1. **The token table → `tokens.css` + `Theme.swift`.** Eighty rows, both appearances, and the mirrored rows into the chrome. Add the third token check from DEC-066 — *every mirrored row has a `Theme.swift` counterpart* — with a hostile input as its control. Nothing else can be styled until this exists.
2. **The keyboard map (DEC-065).** `KeyboardModifiers` gains `.control`; the shell translates it; the bindings are re-cut; `25-tester-packet.md` and the `⌥⌘T` assertion in `DesignChecks` move to `⌃\`` in the same commit. Doing this early means every later feature is bound as it lands rather than retrofitted.
3. **Unified layout and the sign column (DEC-059).** The default view. Side-by-side becomes the mode, and the alignment rule follows it.
4. **The three collapses (DEC-060)**, with the four combinations photographed.
5. **The states that already have engine support but no screen**: scope bar with reasons, base-ref age copy, Expanded and Raw as drawn, `#unrenderable`, missing root, base-branch prompt, preferences and the editor-failure state, the watcher states.
6. **Motion (DEC-064)**, with its register and its reduced-motion check, once there are transitions to guard.
7. **Search (DEC-062)**, then **the lenses (DEC-061)**, each adding its Git operations to the closed registry so R-8 keeps covering everything the application can issue.
8. **The rendered comparison (DEC-063)**, last, because it is the only item that needs new fixtures — `15-test-corpus-plan.md` §4.7a — and its security boundary wants its own check with the `svg-hostile` fixture as the control.

## 4a. Where the work stands, 2026-08-09

All eight steps above are built. The three that cost the most were not the ones this document expected: the token table went in cleanly, and the time went on `NSTableView`'s inset style clipping a rail to two characters, on `NSSplitView` ignoring a pane's width at two priorities and through `setPosition`, and on a selftest that had been reading the developer's own configuration and losing a race with it. Each was found by a picture or a printed frame, never by a check — and each check that had "passed" was asserting what had been *asked for* rather than what the window did.

The eight image fixtures of `15-…` §4.7a were built the next day and are the last item of §4 step 8. Nothing in this document is now outstanding.

## 4b. That sentence has been wrong twice, and this is the correction

**2026-08-12.** Put beside a screenshot of `DiffScope.dc.html`, the window was missing the whole of its chrome: no column headers, the scope control inside the diff pane, the base as prose, no key hints, full paths as group headers, a status line carrying one message and nothing else. Six items, built as **DEC-071 … DEC-075**, and the sentence above should have read *nothing in the diff pane is outstanding*.

**2026-08-13.** The owner used the finished chrome and asked for a large part of it to be taken back off: the focus rings, the printed keystrokes, the technical chips, the underlines in the diff. Not a reversal of the design — a reversal of **who the window is drawn for**, and it is [DEC-077](04-decision-log.md), with its work list in [28-interface-plan.md](28-interface-plan.md).

**The lesson is about this document rather than about the design.** *Nothing is outstanding* is a claim no document can carry, because the thing it is measured against is a picture nobody in this repository can open. Written twice, wrong twice. What this file can honestly say is **which decisions the design produced**; what is left to build lives in `28-…`, which is a list with acceptance tests rather than an adjective.

## 5. What is drawn and deliberately not built yet

`12-desktop-ux-specification.md` §9 lists only functions that exist, because DEC-057's check fails a listed row nothing binds. The lenses, the collapses, search and the image-comparison modes are bound and listed **as they land**, one row per landing. A drawing is not a binding, and the coverage table is not a wish list.
