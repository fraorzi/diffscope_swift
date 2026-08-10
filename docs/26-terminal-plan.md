# 26 — Built-in terminal, Warp-style

**Status:** Accepted as scope by the product owner, 2026-07-31 (**DEC-053**), **extended 2026-08-10 by DEC-067** — several sessions in tabs, and the drawer across the window rather than under the diff. One session was the smallest thing that could answer T0's question, never the point. Resolves OQ-055 in favour of building it. **Complete.** Gate T0 passed and T1–T4 are built (DEC-053 … DEC-056): the terminal runs, at a prompt the keyboard belongs to a real text field, it follows the repository the reader is looking at, and every document that promised the product could not change a repository now says what is true instead.

This document exists because the terminal was deferred twice on my recommendation, and the product owner has now put it at the front of the queue. That is their call; the ordering until then was the audit's framing, not theirs.

---

## 1. What was already settled by measurement

The feature turns on one question: **can the application know when the shell is sitting at a prompt?** Without that it cannot decide whether a keystroke belongs to a local editor or to a running program, and the whole Warp-like input line is impossible.

Probed on 2026-07-31 against this machine's zsh 5.9 through a real `forkpty` PTY:

| Probe | Result |
|---|---|
| Prompt mark `OSC 133;A` after `add-zsh-hook precmd` | **seen** |
| Command mark `OSC 133;C` after `add-zsh-hook preexec` | **seen** |
| Command output round-trips through the PTY | **seen** |
| The user's own prompt survives the injection | **survived** |

Two findings that shape the implementation, both from that probe:

- **`~/.zshrc:16` defines `precmd() { vcs_info }` as a plain function.** Injecting our own `precmd` would silently replace it and strip the git information out of the product owner's prompt. `add-zsh-hook` appends, and was verified not to clobber it. This is the difference between a terminal that feels like theirs and one that quietly breaks their setup.
- **`zsh -i -c "…"` never reaches the prompt loop**, so the hooks never fire. The first probe used it and produced a false negative. Anything measuring this must drive a genuinely interactive shell.

---

## 2. What this costs, recorded before it is built

**The product stops being able to say "it cannot change your repositories."** A terminal runs whatever the user types, including `git commit`. That is the point of the feature, not a defect — but three consequences are part of the work rather than discoveries for later:

- **`25-tester-packet.md` must be rewritten.** Its privacy and read-only paragraphs currently promise something that will stop being true.
- **DEC-028 survives intact.** Never execute anything derived from *repository content*: no running repo scripts, no command lines prefilled from repository files, no auto-execution of anything. The terminal runs **what the user types** and nothing else. Once a shell exists inside the application, this distinction is the entire safety story.
- **R-8 still applies to the application's own Git usage.** The terminal is the user's. No document may conflate the two.

A decision entry records all of this **before the first line of terminal code**, because DEC-003 and `18-version-one-scope.md` both say the opposite today.

**Settled in T4 (2026-08-01).** All three held. `25-tester-packet.md` was rewritten and now tells a tester, before they install anything, that a shell lives in the window and will commit if they tell it to. DEC-028 survived intact and became the safety story it was promised to be — the places that can write to a PTY are counted by a check. R-8 still means the application's own Git usage, and `15-test-corpus-plan.md` §5.1 now says so in the same breath as the claim, so the two cannot be quoted as one.

---

## 3. Gate T0 — **PASSED 2026-08-01**

The project's own habit: M0 gated DEC-042 by settling what could invalidate it. This did the same.

`swift run diffscope-t0`, seventeen scenarios over ten real interactive shells. Method, numbers and every correction the measuring forced: `22-experiment-log.md` → **T0**.

| | Required | Result |
|---|---|---|
| 1 | Prompt-mark detection reliable across new shells, resizes, `clear`, a failing command | **holds** — five of five fresh shells, both resize cases, `D;1` and `D;127` both reported |
| 2 | The macOS text motions in the chosen input surface | **holds** — 6/6 in `NSTextView`, and 6/6 in a `WKWebView` text field |
| 3 | A full-screen program: `vim`, then `:q` | **holds** — alternate screen entered and left, shell usable after |
| 4 | Shell integration touches nothing permanent | **holds** — `~/.zshrc` and `~/.zprofile` byte-identical, verified independently of the probe |

Two negative controls carry the weight: an unmodified shell emits **zero** marks (so the marks are ours), and the naive `precmd` assignment is shown **destroying** the user's `vcs_info` rather than merely warned about.

**If (1) had proved unreliable, the Warp-style input line would not have been deliverable** and the honest outcome would have been a plain terminal with the reason recorded. It did not, so T1 proceeds. Nothing here promises detection is reliable *in general* — seventeen scenarios on one zsh 5.9 is what it is, which is why §4's escape hatch stays mandatory.

Two results change the work below rather than merely clearing it:

- **The motions are not an AppKit property.** A DOM text field gets all six, so §4's input line may live in the same webview as the grid. T2 decides; T0 only removed the assumption.
- **The prompt costs ~340 ms** on this machine (nvm, `compinit`, `ssh-agent` in the user's rc), and each interactive shell leaks an `ssh-agent` — 363 were already running before the probe. Spawning must be off the interface's critical path, and the multiplication is worth telling the user about before they find it.

---

## 4. Architecture

**The output grid: xterm.js in a second `WKWebView`.** Consistent with DEC-042's reasoning — a virtualised, scrollbacked, attribute-aware grid with reflow is weeks of native work that a mature MIT-licensed component already does, and the webview plumbing plus a renderer build step already exist here. Alternatives considered: SwiftTerm (MIT, Swift-native, less battle-tested for reflow) and a hand-written VT parser (weeks, and a solved problem).

**The input line is the part no library provides**, because it means *replacing* the shell's line editor rather than decorating it:

- **At a prompt** → keystrokes go to a real editable text control, which is where the macOS word and line motions come from for free. **Measured in T0: "real editable text control" does not mean "AppKit".** A `<textarea>` in a `WKWebView` performs all six motions identically to `NSTextView`, so the control may sit in the same webview as the grid instead of being overlaid on it. T2 chooses; T0 only established that both are open.
- **While a program runs** → raw passthrough to the PTY, byte for byte.
- **An explicit escape hatch** to force raw mode. Detection will be wrong sometimes, and being unable to type into an ssh password prompt would be worse than never having the feature at all.

**Shell integration without modifying anything:** launch zsh with `ZDOTDIR` pointing at a generated directory whose `.zshrc` sources the user's real one and then adds hooks with `add-zsh-hook`. Bash gets `--rcfile`. Nothing of theirs is ever written to.

---

## 5. Milestones

| | |
|---|---|
| ~~**T0**~~ | **Done 2026-08-01.** `Sources/diffscope-t0`, results in `22-experiment-log.md` → T0. Throwaway: T1 replaces it |
| ~~**T1**~~ | **Done 2026-08-01.** `Sources/DiffScopeTerminal` (PTY, scanner, integration, session) and the grid in a second `WKWebView`; ⌥⌘T opens a pane under the diff. DEC-054, measured in `22-experiment-log.md` → T1-A |
| ~~**T2**~~ | **Done 2026-08-01.** `InputRouter` decides where a keystroke goes, the field is a real `<textarea>`, Tab and ⌃R hand the line to the shell, ⌥⌘R forces raw. DEC-055, measured in `22-experiment-log.md` → T2-A |
| ~~**T3**~~ | **Done 2026-08-01.** OSC 7 tells the pane where the shell is, the selection is followed under a three-term guard, and a finished command refreshes the repository sweep. DEC-056, measured in `22-experiment-log.md` → T3-A |
| ~~**T4**~~ | **Done 2026-08-01.** `25-tester-packet.md` rewritten for a stranger who is about to point this at their own repositories; ten further documents now distinguish the application acting on its own from the user typing in a shell; DEC-003 carries its amendment pointer; a check with a negative control holds the retired sentences out |

## 6. Verification

Headless checks in `diffscope-verify` wherever the logic allows — mark parsing, mode switching, argv construction, rc-file untouchedness — and a selftest arm where it does not: a command run end to end through a real PTY, with its output reaching the DOM.

The rc-file proof is R-8's pattern pointed at the user's home directory: hash before, hash after, assert identical.
