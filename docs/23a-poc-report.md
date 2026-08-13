# 23a — POC report: how to run it, what every part does, what to look for

**Gate:** G1 of `23-release-gates.md`. **Date:** 2026-07-29, revised 2026-07-31 for root management (DEC-052). **Build:** 884/884 checks pass, 32 fixtures.

This is written for someone who has never seen the code. No internals — only what appears on screen, what it means, and how to tell whether it is lying to you.

---

## 1. Start it

```bash
cd ~/WebstormProjects/diffscope
swift run -c release diffscope-app
```

First run compiles for a minute or two. After that it starts in a few seconds. Quit with **⌘Q**.

**On first launch it asks you to choose a folder** — there is no assumed path. Pick `~/WebstormProjects` and it will find your repositories; the choice is remembered. You can add more folders, or single repositories from anywhere, from the **Sources** menu (⇧⌘O and ⇧⌘R).

Verified before writing this: 23 repositories across two folders are found in 512 ms, a folder that no longer exists is named rather than dropped, and two repositories sharing a name are labelled by their parent folder.

Optional settings, both read once at launch:

| Variable | What it does | Default |
|---|---|---|
| `DIFFSCOPE_ROOT` | Adds a folder for this launch only, without saving it | none |
| `DIFFSCOPE_CONFIG` | Use a different settings file, for trying things out | `~/Library/Application Support/DiffScope/config.json` |
| `DIFFSCOPE_EDITOR` | Command for "Open in Editor". `{file}` and `{line}` get filled in | `/usr/bin/open -a WebStorm {file}` |

If your editor is not WebStorm:

```bash
DIFFSCOPE_EDITOR="/usr/bin/open -a Visual\ Studio\ Code {file}" swift run -c release diffscope-app
```

**It cannot change your repositories.** It only reads. It never fetches, never pushes, never writes to `.git`, and never connects to the internet. You do not need a clean working tree to try it, and you cannot lose work by clicking around.

---

## 2. What is on screen

Three columns and a status line.

**Left — repositories.** Every Git repository found in the folders you added. If two of them share a name, the row shows enough of the parent folder to tell them apart. Each row shows the name, then `3△` = three changed files, then `↑5` = five commits ahead of the base branch. `↑?` means the ahead count could not be worked out — that is deliberate, the app never invents a number. Hover a row for the branch and the base it is comparing against.

**Middle — files.** The changed files in the selected repository, for the selected scope. The prefix is the kind of change: `mod` modified, `add` added, `del` deleted, `ren` renamed, `unt` untracked.

**Right — the diff.** Two panes, old on the left, new on the right, side by side.

**Top of the diff — the notice bar.** Grey pills. This is the part worth reading. It always ends with `mode: …`, and anything before that is the app telling you something about how much it trusts what it is showing.

**Bottom — the status line.** One line describing the last thing that happened: which file is open, how it was analysed, or why something did not work.

---

## 3. The three view modes

Switch with **⌘1 / ⌘2 / ⌘3**, or the control at the top.

| Mode | What it does |
|---|---|
| **Raw** | A plain textual diff. No cleverness at all. This is the control view — if you ever doubt what the other two are showing, come here |
| **Structural** | The point of the product. Understands the code's structure, so a removed wrapper reads as a wrapper change with its children intact, instead of a huge deletion followed by a nearly identical insertion. Formatting changes are grouped, moved code is marked |
| **Expanded** | The same as Structural with nothing quietened. Every formatting change is shown separately, and invisible characters are named |

**The rule that matters: all three show the same differences.** Structural and Expanded never hide anything Raw shows — they only group and label it differently. If you find a change visible in Raw and absent in Structural, that is the most serious bug you can report. Everything else is cosmetic by comparison.

---

## 4. The four scopes

Switch with **⇧⌘1 … ⇧⌘4**. This is *what is being compared with what*.

| Scope | Compares |
|---|---|
| **All local changes vs HEAD** | Everything you have done since the last commit, staged or not. The everyday one |
| **Unstaged vs index** | Only what you have not staged yet |
| **Staged vs HEAD** | Only what you have staged — what would go into the next commit |
| **Branch vs merge-base** | Your whole branch against where it split from the base branch. The "review my whole feature" one |

If a scope cannot work — no commits yet, no base branch found — the file list empties and the status line says why. That is correct behaviour, not a crash.

---

## 5. Keyboard

Everything is also in the menu bar, so you never have to remember these.

| Key | Does |
|---|---|
| **⌘N / ⌘P** | Jump to the next / previous change in the open file |
| **⌘E** | Expand every collapsed block in the open file |
| **⌘] / ⌘[** | Next / previous file |
| **⇧⌘] / ⇧⌘[** | Next / previous repository |
| **⌥⌘1 / ⌥⌘2 / ⌥⌘3** | Move focus to repositories / files / diff |
| **⌘O** | Open the current file in your editor, **at the line you are reading** — the change you jumped to with ⌘N, or the first line on screen |
| **⌘1–3**, **⇧⌘1–4** | Modes and scopes, as above |

---

## 6. How to read the marks in the diff

Nothing here uses colour to carry meaning — deliberately, so it still works in a screenshot, in dark mode, and for a colour-blind reader. Meaning is carried by **texture**.

| What you see | What it means |
|---|---|
| Diagonal hatching + thick underline | **Changed.** Ordinary edited content |
| Thin dotted underline, no hatching | **Formatting-only.** Whitespace, quotes, a trailing comma — grouped and quietened, never hidden |
| Wavy underline | **Possibly changes behaviour.** Reordering — the app will not tell you it is harmless, because it cannot know |
| Dashed outline around a block | **Moved.** The identical text appears somewhere else on the other side |
| Dashed underline instead of solid | **Uncertain.** The alignment here is a best guess, not a confirmed match |
| Dotted outline + a small badge | **An invisible difference.** The two sides look identical on screen and differ in bytes — a non-breaking space, a zero-width character, an invisible control. The badge names it; Expanded mode spells out the codepoint |
| A marked line number, with a solid edge beside it | **This line carries a difference.** The gutter is the quickest way to scan a long file. A line changed on one side only — an insertion, say — is marked on that side only |
| A grey band saying `16 unchanged lines — ⌘E, or click, to expand` | Identical content on both sides, folded away. Click it or press ⌘E |
| A grey band saying `4 formatting-only changes over 4 lines — ⌘E, or click, to expand` | Real changes, grouped because they are only formatting. **The count is always shown** — the app is not allowed to group something without telling you how much it grouped |

---

## 7. What the notice bar is telling you

If it only says `mode: structural`, everything went normally.

| Pill | Plain meaning |
|---|---|
| `Structural analysis unavailable — …` | It could not analyse the structure of this file, and it says why. **It fell back to the plain textual diff, and all differences are still shown.** Common reasons: not a JS/TS file, too big, binary |
| `Structural analysis discarded — it failed its own checks …` | It analysed the file, checked its own work, caught a mistake, threw the result away and showed you the plain diff instead. Rare. Worth telling me about |
| `coverage not verified` | It could not double-check its own output for this file, usually because the two versions are wildly different. **Not verified is not the same as wrong** — the diff is still complete |
| `content is not valid UTF-8 …` | The file is not text it can display. It refuses to guess rather than show you mangled characters |
| `formatting-only: 12 shown` | How much was grouped. This is the disclosure that makes grouping allowed |
| `moved: 1` | How many moved blocks were paired |

Every failure message is supposed to say three things: what was withheld, why, and what you can still trust. **If you find one that leaves you unsure whether the diff is complete, that is a bug — tell me the exact wording.**

---

## 8. Refresh while you work

Leave the app open on a repository and edit a file in your editor. Within a second or two the diff updates by itself.

Two things to watch for:

- **You should not lose your place.** If you were scrolled to a change halfway down a long file, you should still be looking at roughly that change after the refresh, not thrown back to the top.
- **You should never see half-written content.** If the app catches a file mid-save it refuses to show it and the status line says the file is being written; it draws it once the file settles. Seeing a mangled half-old, half-new file would be a serious bug.

---

## 9. What to actually try

An hour, roughly in this order. `mailingi-2025` has 44 changed files, `philips__signify-wiz-euro__preact` has 20, `komputronik-html` has 2 — good places to start. `carrefour-inapp` has no commits at all yet, which is a deliberate edge case.

1. **Open a repository with real changes and read a diff you already understand.** Does it tell you the truth about a change you made yourself?
2. **The founding case.** Find (or make) a change that removes a wrapper element around several children in a `.tsx` file. Structural mode should read as "the wrapper changed, the children are intact". Raw will show a big deletion and a big insertion. That difference is the entire product.
3. **Run a formatter on a file** — Prettier, or reindent it by hand. The changes should be grouped as formatting-only, with a count, and expandable.
4. **Compare the three modes on the same file.** Anything visible in Raw must be visible in Structural. Look specifically for something that disappears.
5. **Walk a long file with ⌘N** from top to bottom. Does it stop at every change? Does it ever skip one?
6. **Switch scopes on a repository with both staged and unstaged work.** Do the file lists make sense against what `git status` tells you?
7. **Open a non-JS file** — a `.css`, a `.md`, an image. Each should explain itself rather than looking broken.
8. **Edit a file in WebStorm while the app is open on it.** Does it refresh? Do you keep your place?
9. **⌘O on a file.** Does it open? If your editor is not WebStorm, set `DIFFSCOPE_EDITOR` and try again — and try a deliberately wrong command to check the failure is reported rather than silently doing nothing.

---

## 10. Known gaps — please do not report these

All of these are already recorded. Reporting them costs you time and tells me nothing new.

> **Audited 2026-08-13.** This section is dated 2026-07-29 and **four of its five interface entries had been fixed** while it still told a stranger not to report them — which is worse than a stale document, because it is an instruction. Each is struck through with what closed it. The one that survives is the editor's default template.

**Interface**

- ~~There is still no per-repository way to override the base branch, so the "vs base" scope is unusable where detection lands on the wrong branch (`carrefour-inapp`).~~ **Closed 2026-07-31** — ⇧⌘B, stored in the configuration (DEC-011), and the base is drawn as a block in the scope row since DEC-072.
- ~~The file list has **no keyboard navigation of its own**.~~ **Closed 2026-08-09** (DEC-057, measured in M8-J): ⌥↑ / ⌥↓ and the bare arrow keys both walk 63 files past nine group headers with no blind stops. **Type-to-find is still absent** and is the half of this entry that stands.
- **The default editor command cannot jump to a line.** `EditorCommand.defaultTemplate` is still `/usr/bin/open -a WebStorm {file}` — no `{line}` — so ⌘⏎ opens the file at the top until you set a template containing `{line}` in Settings. **Still open**, and it is the last surviving interface gap from this report.
- ~~The mode pill can say `mode: structural` next to a notice saying structural analysis was unavailable.~~ **Closed 2026-08-09** (DEC-058): the pill reported the path taken as well as the selection. **And then the pill itself was removed** — DEC-077 takes the three technical chips off the screen entirely.
- ~~There is no picker for arbitrary branches or commits.~~ **Partly closed 2026-08-10** (DEC-061): the History lens picks one commit or two and compares them. A branch picker is still not built.

**Analysis**

- **Code that moved *and* was edited** shows as a deletion plus an addition, not as a move. Deliberate: a move is only claimed when both sides are byte-identical, because a move that swallowed an edit would hide it.
- A moved block whose first line starts with the same word as its neighbour (e.g. both start `export `) is **not detected as a move**. Measured and recorded.
- A reformat that **changes the number of lines** is never grouped as formatting-only — only same-line-count reformats are.
- **Reordered object properties** are marked as possibly-behaviour-affecting, not as formatting. Intentional: property order is observable.
- In files over ~2000 lines, a refresh puts you back within a few lines of where you were, not exactly.

**Not built at all**

- No ambiguity indicator, even though ambiguity is detected internally. Deliberately withdrawn (DEC-045).
- ~~Two failure conditions (partial parse errors, low confidence) are classified internally but never surfaced.~~ **Closed 2026-08-09** — `parseErrorRegions` reports F1, and confidence was surfaced as a chip. **DEC-077 then took the chip off the screen** for a normal file: what remains, and what may never go, is the plain sentence a degraded file draws.

---

## 11. What is worth reporting

In priority order. The first line is worth more than everything below it combined.

1. **The diff told me something untrue.** A change that exists but is not shown; "no changes" on a file that differs; a wrapper change that still reads as a huge delete-and-add in Structural mode; two panes that disagree.
2. **A failure message left me unsure whether the diff was complete.** Quote the exact wording.
3. **It crashed, hung, or went blank.** What you were doing, which repository, which file.
4. **Something was slow enough to be annoying.** Which file, roughly how big.
5. **Something was confusing or ugly.** Welcome, and no longer least urgent: the design landed at G2, the chrome was built against it (DEC-071 … DEC-076), and the owner's second session turned *confusing* into the largest item on the list (DEC-077, [28-interface-plan.md](28-interface-plan.md)). If a word on the screen means nothing to you, that is a defect worth reporting.

**If a diff looks wrong, keep the file.** Do not fix or revert it before telling me — the exact pair of versions is what makes it reproducible. `git stash` is enough.

---

## 12. If it will not start

| Symptom | Cause |
|---|---|
| Window shows only "No folders chosen yet" | Nothing configured yet — that is the normal first run. Choose a folder |
| `error: no such module` or a compiler error | The build is out of date: `swift build` first, then try again |
| Window opens, repository list empty | No Git repositories under `DIFFSCOPE_ROOT`. Check the path |
| Diff pane blank, notice bar empty | The renderer bundle is stale: `cd Renderer && npm run build` |
| Something feels broken and you want to check the build itself | `swift run diffscope-verify` — 855 checks, prints `OK` at the end |
