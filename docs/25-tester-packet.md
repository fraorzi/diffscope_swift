# 25 — Tester packet

**Give this document and the zip to the person testing. Nothing else is needed.**

Written for someone who has never seen this project. No jargon, no setup, no build tools.

---

## What this is

A macOS app for looking at what you changed in a Git repository before you commit it.

Every diff tool does that. The reason this one exists is one specific case it does better: when you delete a wrapper around a block of code — a `<div>` around ten lines of JSX, an `if` around a function body — an ordinary diff shows a big deletion followed by a nearly identical big insertion, and you have to read both halves to work out that almost nothing changed. This one shows it as what it is: the wrapper changed, the contents did not.

## What it can and cannot do to your repositories

Two different things, and the difference matters:

- **The app itself never changes anything.** Looking at a diff, switching branches in the list, refreshing — none of it writes to your files, your staging area, or your Git settings. It does not even fetch. This is not a promise about intent; every Git command the app can issue is snapshot-tested to leave the repository byte-identical.
- **There is a terminal in it, and a terminal runs what you type.** Press ⌃` and a shell opens at the bottom of the window, in the repository you are looking at. If you type `git commit` in it, you commit — the same as in any terminal. That is the point of it, and it is the newest part of the app, so it is the part most worth trying.

So: the app will not touch your work behind your back, and the terminal will do exactly what you tell it to.

**Your shell setup is not modified.** The terminal starts your own shell with your own configuration, but it never edits `~/.zshrc`, `~/.zprofile` or anything else in your home folder. It adds what it needs in a temporary folder that goes away when the app closes, and the app's own tests hash those files before and after a session to prove they are untouched.

If you would rather not have a shell inside the app while you test, just do not open it — nothing starts it for you.

---

## Installing it

1. Unzip `DiffScope-<version>.zip`. You get `DiffScope.app`.
2. Move it to your Applications folder, or leave it wherever — it does not matter.
3. **The first launch needs one extra step**, because the app is not signed with an Apple developer certificate:
   - **Right-click** (or Control-click) the app, choose **Open**.
   - A dialog says macOS cannot verify the developer. Click **Open**.
   - That is once. After that it opens normally by double-clicking.

Double-clicking it the first time instead of right-clicking gives you a dialog with no Open button. That is macOS being careful about an unsigned app, not the app being broken. Right-click ▸ Open is the way through.

**Why unsigned:** signing requires a paid Apple developer account. For a test build we would rather spend the effort on the application.

---

## First run

The window opens empty and asks you to choose a folder. There is no default and it does not go looking on its own — it only ever reads folders you point it at.

Choose a folder that contains your projects. It looks two folders deep and stops at the first Git repository it finds in each branch, so `~/Projects` works if your repositories are `~/Projects/something`. If a repository is buried deeper, use **Sources ▸ Add Repository…** to add it directly.

If it finds nothing it says so, and says why.

---

## What you are looking at

Three columns, a bar of grey pills at the top of the diff, and a status line.

- **Left:** your repositories. `3△` means three changed files; `↑5` means five commits ahead of the base branch. **`↑?` means it could not work the number out** — it says unknown rather than showing a zero it does not believe.
- **Middle:** the changed files, grouped by folder. The glyph says what happened — `+` added, `−` deleted, `→` renamed, a pencil modified — and the numbers on the right are lines gained and lost, or the word `binary` where a line count would mean nothing. A `raw`, `bin` or `big` tag means that file will not get the clever treatment — unsupported file type, binary, or too large.
- **Right:** the diff, in one column. Removed and added lines carry `−` and `+` in their own narrow column between the two line numbers; the colours only reinforce that. **⌥⌘→ switches to two columns** — old on the left, new on the right — which is the better shape for a large restructure.
- **The grey pills** are the app telling you how much it trusts what it is showing. Worth reading; see below.

**Three view modes** — ⌘1 Structural, ⌘2 Expanded, ⌘3 Raw. Raw is a plain textual diff with no cleverness, and it is the control: if you doubt what Structural shows you, switch to Raw and compare. **All three show the same differences.** Structural groups and labels them; it never removes any.

**Four scopes** — ⇧⌘1 to ⇧⌘4: everything since your last commit, only unstaged, only staged, or your whole branch against where it split off. Scopes that cannot work for a repository are greyed out, and hovering one says why.

**Three lenses** — ⌃⌘D the diff, ⌃⌘B blame, ⌃⌘H history. Same file, same window: what changes is the question. In History, **clicking a commit compares it with your working tree**, and clicking a second compares the two with each other; clicking a scope pill puts you back.

**Search** — ⌘F over the changed files, ⇧⌘F over the whole worktree. The results appear in the pane grouped by file; ⌘G and ⇧⌘G move between them and ⌘⏎ opens the one you are on.

**Collapsing** — ⌃⌘1 shrinks the repository list to a rail, ⌃⌘2 the file list to a spine, ⌃⌘0 both. Neither disappears: the rail keeps three letters and a dot, the spine keeps a glyph and a bar.

**Keyboard:** the modifier says what you are moving through — ⌘↑ / ⌘↓ between changes, ⌥↑ / ⌥↓ between files, ⇧⌘↑ / ⇧⌘↓ between repositories. ⌘E expands anything collapsed, ↑ and ↓ also move in a list once it has focus (⌥⌘2), ⌘⏎ opens the current file in your editor, and **⌘R shows the region you are standing on in Raw and brings you back to it**. Everything is in the menu bar too; nothing in the app needs the mouse.

---

## How to read the marks

Nothing uses colour to carry meaning — deliberately, so it still works in a screenshot, in dark mode, and if you are colour-blind. Meaning is carried by texture.

| What you see | Means |
|---|---|
| Diagonal hatching, thick underline | Changed |
| Thin dotted underline | Formatting only — spacing, quotes, a trailing comma |
| Wavy underline | Might change behaviour — reordering. It will not tell you it is harmless, because it cannot know |
| Dashed box around a block | This exact text appears somewhere else on the other side — it moved |
| Dashed underline | The app is not certain it lined these two up correctly |
| Dotted outline with a small tag | **The two sides look identical and are not.** A non-breaking space, a zero-width character, an invisible control. The tag names it |
| A marked line number with a solid edge | This line contains a change — the quickest way to scan a long file |
| A grey band saying `16 unchanged lines` | Identical on both sides, folded away. Click it or press ⌘E |

---

## What the grey pills mean

If the only pill says `mode: structural`, everything went normally.

| Pill | Means |
|---|---|
| `Structural analysis unavailable — …` | It could not do the clever version for this file and says why. **It fell back to a plain diff and all differences are still shown** |
| `Structural analysis discarded — it failed its own checks` | It did the clever version, checked its own work, found a mistake, threw it away and showed you the plain diff. Rare — worth reporting |
| `coverage not verified` | It could not double-check its own output, usually because the two versions are wildly different. **Not verified is not the same as wrong** |
| `no structural changes; N formatting differences` | Everything that changed here is formatting |
| `formatting-only: 12 shown` | How much was grouped — grouping is only allowed because the count is shown |

---

## What to try

An hour, roughly in this order.

1. **Open a repository where you know what you changed.** Does the diff tell you the truth?
2. **The case the app exists for:** find or make a change that removes a wrapper element around several lines. Compare ⌘2 Structural with ⌘1 Raw. That difference is the whole product.
3. **Run a formatter on a file** — Prettier, or reindent it. Those changes should be grouped as formatting, with a count, and expandable.
4. **Compare the three modes on the same file.** Look specifically for something visible in Raw and missing in Structural.
5. **Walk a long file with ⌘↓.** Does it stop at every change, or skip one? On a big working tree, walk the whole file list from the keyboard and tell us if anything makes you reach for the mouse — that is a claim we make and would like broken.
6. **Open a non-code file** — a `.css`, a `.md`, an image, an SVG. Each should explain itself rather than looking broken. An image or an SVG is **compared by being drawn**: Before / After, Blend, Split and a pixel comparison, with the modes that cannot work here disabled and saying why. The one worth checking is an image you re-exported without changing: it should say *the two files render identically — 0 pixels differ, the bytes differ* rather than showing you two identical pictures and leaving you to wonder.
7. **Edit a file in your editor while the app is open on it.** It should update within a second or two, and you should not lose your scroll position.
8. **Open the terminal with ⌃`** — this is the newest part and the least tested. Things worth trying, roughly in order of how much they would annoy you if they were wrong:
   - Type a command with a long path or a quoted string and **edit it with the keys you actually use**: Option+←/→ by word, Cmd+←/→ to the ends of the line, Option+Delete to rub out a word. That is the reason the terminal exists.
   - Press **Tab** in the middle of a path. The shell takes the line back and completes it the way it does in your own terminal; the pill on the left says so while that lasts.
   - Run something long — `npm install`, a test suite — and check that ⌃C stops it.
   - Run `vim` or `top`, and leave again.
   - Change a file from the terminal and watch whether the diff beside it notices.
   - If a prompt appears that the input line handles badly — an `ssh` password, a `sudo` prompt — **⌥⌘R** hands every key straight to the shell. If you need that, say so: it means we guessed wrong about where the prompt was.
   - **⌥⌘T opens a second shell** in the same drawer, ⌃⌘] and ⌃⌘[ move between them and ⌃⌘W closes one. Each tab says where *its own* shell is; a dotted underline on a tab means that shell is not in the repository you are looking at. Run something long in one and keep working in the other — the two scrollbacks should never mix.
9. **Point it at your own editor** — ⌘, opens Settings, where the command is a template with `{file}` and `{line}`. Break it on purpose: the failure must be visible rather than nothing happening, and Settings remembers the last attempt.

**Using a different editor?** ⌘O defaults to WebStorm. To use another, launch the app from Terminal with your own command:

```bash
DIFFSCOPE_EDITOR="/usr/bin/open -a Visual\ Studio\ Code {file}" /Applications/DiffScope.app/Contents/MacOS/DiffScope
```

`{file}` and `{line}` are filled in. If the command fails, the status line says so rather than doing nothing.

---

## Known missing — please do not report these

Already recorded. Reporting them costs you time and tells us nothing new.

- **No type-to-find in the file list.** Arrow keys and ⌘[ / ⌘] walk it; there is no filter field and no search.
- **No branch or commit picker.** The four scopes are all there is.
- Code that **moved and was also edited** shows as a deletion plus an addition, not as a move. Deliberate: a move is only claimed when both sides are identical, because a move that swallowed an edit would hide it.
- A reformat that **changes the number of lines** is never grouped as formatting.
- **Reordered object properties** are marked as possibly-behaviour-affecting, not formatting. Intentional — property order is observable.
- The mode pill can say `mode: structural` next to a notice saying structural analysis was unavailable. It reports what you selected, not which path ran.
- In files over about 2000 lines, a refresh puts you back within a few lines of where you were, not exactly.
- ⌘O opens the file but not at the right line unless you set `DIFFSCOPE_EDITOR` to a command containing `{line}`.
- It looks plain. The visual design is a separate piece of work that has not happened yet.
- **In the terminal:** ↑ and ↓ walk only the commands you typed in *this* session, not your shell's own history — ⌃R gets you that, from the shell itself. There are no Warp-style command blocks and no completion of our own; Tab hands the line to your shell instead.
- Opening the terminal takes about a third of a second, because it runs your real shell startup files. Each shell also leaves an `ssh-agent` behind if your configuration starts one — that is your setup doing what it always does, not the app.

---

## What is worth reporting

In order. The first line is worth more than everything below it put together.

1. **The diff told me something untrue.** A change that exists but is not shown; "no changes" on a file that differs; a wrapper change that still reads as a huge delete-and-add in Structural; the two panes disagreeing.
2. **A message left me unsure whether the diff was complete.** Quote the exact wording.
3. **It crashed, hung, or went blank.** What you were doing, which repository, which file.
4. **It was slow enough to annoy me.** Which file, roughly how big.
5. **It was confusing or ugly.** Welcome, and least urgent.

**If a diff looks wrong, keep the file.** Do not fix it or revert it before telling us — the exact pair of versions is what makes it reproducible. `git stash` is enough to park it safely.

---

## Privacy, and what it does to your machine

- **On its own, it only reads.** Nothing the app does by itself stages, commits, pushes, pulls or fetches. Every Git command it can run is listed in the source, and each one is tested before every release by fingerprinting the repository's internals before and after and requiring them to be identical.
- **The terminal is yours.** It runs what you type in it, including commands that change your repository. Nothing types into it for you, with one exception worth knowing: when you switch to a different repository and the terminal is sitting at an empty prompt, the app sends a `cd` so the shell follows you. If you have a command half-typed, or something is running, it sends nothing and tells you the directory no longer matches.
- **It does not touch your shell configuration.** Your `~/.zshrc` and the rest are read, never written; the app's own additions live in a temporary folder. This is tested by hashing those files around a real session.
- It **never connects to the internet**. There is no network code in it and it asks for no network permission.
- It sends **no telemetry, no analytics, no crash reports**. Nothing leaves your machine.
- It uses **no AI** while running.
- The only thing it writes anywhere is its own settings file — which folders you added — at `~/Library/Application Support/DiffScope/config.json`. Delete that and it forgets everything.
- To uninstall: drag the app to the trash, and delete that settings file.

---

## If something goes wrong

| What you see | What it is |
|---|---|
| "cannot be opened because the developer cannot be verified" with no Open button | You double-clicked on the first launch. Right-click ▸ Open instead |
| The window opens with nothing in it | No folder chosen yet — the buttons in the middle are the way in |
| "No Git repositories were found" | The folder has none within two levels. Use Sources ▸ Add Repository… for one deeper down |
| The diff area is blank but the app responds | Worth reporting: which file, which repository, which mode |

Quit with ⌘Q. There is nothing running in the background afterwards.
