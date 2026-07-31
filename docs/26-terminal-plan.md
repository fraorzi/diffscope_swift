# 26 — Built-in terminal, Warp-style

**Status:** Accepted as scope by the product owner, 2026-07-31. Resolves OQ-055 in favour of building it. **Not started** — gate T0 below comes first.

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

---

## 3. Gate T0 — before building anything

The project's own habit: M0 gated DEC-042 by settling what could invalidate it. This does the same.

1. **Prompt-mark detection is reliable in the real application**, not only in a probe — across new shells, window resizes, `clear`, and a command that fails.
2. **The macOS text motions work in the chosen input surface**: Option+←/→ by word, Cmd+←/→ to line ends, Option+Delete by word. Measured, because this *is* the feature being asked for.
3. **A full-screen program works**: `vim`, then `:q`. Alternate screen buffer, raw passthrough, clean return to the prompt.
4. **Shell integration touches nothing permanent** — hash `~/.zshrc` and `~/.zprofile` before and after a session and require them identical, in the spirit of R-8.

**If (1) proves unreliable, the Warp-style input line is not deliverable.** The honest outcome is then a plain terminal with the reason recorded. Stated now so it is not a disappointment later.

---

## 4. Architecture

**The output grid: xterm.js in a second `WKWebView`.** Consistent with DEC-042's reasoning — a virtualised, scrollbacked, attribute-aware grid with reflow is weeks of native work that a mature MIT-licensed component already does, and the webview plumbing plus a renderer build step already exist here. Alternatives considered: SwiftTerm (MIT, Swift-native, less battle-tested for reflow) and a hand-written VT parser (weeks, and a solved problem).

**The input line is the part no library provides**, because it means *replacing* the shell's line editor rather than decorating it:

- **At a prompt** → keystrokes go to a real editable text control, which is where the macOS word and line motions come from for free.
- **While a program runs** → raw passthrough to the PTY, byte for byte.
- **An explicit escape hatch** to force raw mode. Detection will be wrong sometimes, and being unable to type into an ssh password prompt would be worse than never having the feature at all.

**Shell integration without modifying anything:** launch zsh with `ZDOTDIR` pointing at a generated directory whose `.zshrc` sources the user's real one and then adds hooks with `add-zsh-hook`. Bash gets `--rcfile`. Nothing of theirs is ever written to.

---

## 5. Milestones

| | |
|---|---|
| **T0** | The gate above. Throwaway code; results to `22-experiment-log.md` |
| **T1** | PTY lifecycle and output grid: spawn, resize (`TIOCSWINSZ`), read loop, scrollback, alternate screen, clean teardown |
| **T2** | The input line: mode switching on prompt marks, the editable control, the escape hatch, history |
| **T3** | Belonging to this product: opens in the selected repository's directory, follows the selection, and the existing watcher refreshes the diff when a command changes the working tree |
| **T4** | The decision entry, the tests, and the documents that currently say this cannot happen |

## 6. Verification

Headless checks in `diffscope-verify` wherever the logic allows — mark parsing, mode switching, argv construction, rc-file untouchedness — and a selftest arm where it does not: a command run end to end through a real PTY, with its output reaching the DOM.

The rc-file proof is R-8's pattern pointed at the user's home directory: hash before, hash after, assert identical.
