# 23b — Specification versus application: what is written down and not built

**Date:** 2026-07-29. **Method:** every requirement in `12-desktop-ux-specification.md` and `18-version-one-scope.md` checked against the code that would have to implement it. Read-only audit; the two defects in §4 were fixed while writing it.

The suite is not the measure here. 855 checks pass and every item in §1 below is missing anyway, because the checks test the engine and the gaps are in the shell.

---

## 1. Specified, accepted, and not built

Ordered by what it costs the user, not by effort.

### 1.1 ~~There is no way to choose what to look at~~ — **built 2026-07-31, DEC-052**

`12-…` §2 says repositories come from *"any number of user-added root directories … plus individually added repositories located anywhere"*, and §7.5 requires a **picker screen** when no root is configured or a configured root is missing.

Was: one root, from `DIFFSCOPE_ROOT` or a hardcoded `~/WebstormProjects` default, with no picker and no persistence.

Now: sources are stored in a JSON file the user can read (DEC-052), any number of roots plus individual repositories, an empty state with a picker and **no suggested path**, missing sources named rather than dropped, and colliding repository names qualified by parent. The hardcoded default is gone; `DIFFSCOPE_ROOT` survives only as a testing hook that adds a root for one launch.

Implementing it exposed a defect nothing else could have: **every row of both lists had been rendering blank**. See `22-experiment-log.md` → M8-D.

### 1.2 The base branch cannot be overridden (DEC-009)

`12-…` §3: *"The detected base branch is shown and is overridable per repository."*

Built: `resolveBaseBranch(in:override:)` accepts an override and **nothing ever passes one**. There is no UI and no configuration file. When detection lands on the wrong branch — or on `PROMPT`, as it does for `carrefour-inapp` — scope 4 is simply unusable for that repository.

### 1.3 Scope 4 does not show how stale it is (DEC-010, DEC-011)

`12-…` §3 calls this *"a correctness requirement, not decoration: it is the sole staleness signal, because the application never fetches"*. The specified form is `origin/master · 9 weeks old`.

Built: the status line shows the base ref and the tip **date** (`base origin/master tip 2026-05-21`). The information is present; the thing that makes it a signal — the age, in words, next to the scope — is not. A date requires the reader to do the subtraction, which is exactly the work a staleness signal exists to remove.

### 1.4 Unavailable scopes are not disabled (`12-…` §3)

Specified: *"disabled with a stated reason, never hidden. Hiding them would make the interface silently disagree with itself between repositories."*

Built: the scope control stays fully enabled; selecting an impossible scope empties the file list and writes the reason in the status line. The reason is stated, so the trust rule holds — but you can still click into a dead end, and the control lies about what is available.

### 1.5 The file list is missing three of its four specified features (DEC-033)

`12-…` §4 asks for group headers per workspace package, middle-elided paths, per-file change kind, and per-file degradation state.

| Asked for | Built |
|---|---|
| Group headers per workspace package | **No.** Flat list, no grouping |
| Middle-elided paths | Yes |
| Change kind per file | Yes (`mod`, `add`, `del`, `ren`, `unt`) |
| Degradation state per file | **No.** You learn a file is binary or unsupported only after opening it |

In a monorepo with 44 changed files across packages — `mailingi-2025` — the flat list is the difference between scanning and hunting.

### 1.6 ~~No gutter, no line numbers~~ — **built 2026-07-31**

Was: two of the three carriers built, no gutter and no line numbers in either pane, and ⌘O always opening at line 1.

Now: line numbers in both panes and a gutter marking every line that carries a difference, computed in the engine and carried on the contract so it is checkable headlessly. ⌘O asks the renderer which line the reader is on — the active change stop, or the first visible line. See `22-experiment-log.md` → M8-E.

**Still open:** the default editor template has no `{line}`, so the default cannot jump to a line. A template that includes one now receives a real line.

### 1.7 The empty-diff state does not use its specified wording (`12-…` §5.3)

Specified: *"no structural changes; N formatting differences (expand)"* — never a bare "no changes" unless the sides are byte-equal.

Built: nothing at all. A file whose changes are entirely formatting shows a grouped band; a file with no changes shows two identical panes and no statement either way. The invariant is not violated — nothing false is displayed — but the sentence the spec wrote to make the distinction visible was never written into the renderer.

### 1.8 No refresh on window focus (DEC-006)

`12-…` §2: the repository list is *"refreshed on window focus"*. Built: the FSEvents watcher covers the **open** repository only. Switch to WebStorm, commit in a different repository, come back — the counts for that other repository are stale until you reselect it.

### 1.9 Wrapping is forced, not offered (`12-…` §5.4)

Specified: *"Horizontal scrolling is linked between panes; wrapping is available."* Built: `EditorView.lineWrapping` is always on, with no toggle. Long lines therefore never scroll horizontally — they wrap, which makes the two panes drift out of vertical alignment on exactly the minified files §5.4 was written about. Vertical scroll linking is bidirectional and correct.

### 1.10 Two required indicators are not surfaced (`12-…` §5.2)

Of the seven indicators the spec calls *"not optional features — these are how the invariant becomes visible"*: confidence, fallback, unverified, invisible difference and filter-active are all built. **Ambiguity** was withdrawn deliberately (DEC-045, recorded). **Parser state** — parsed, partially parsed, not parsed — is only visible indirectly, as the presence or absence of a fallback notice.

---

## 2. Built, but shallower than specified

- **Repository rows** show name, changed count and ahead count. The branch is in a tooltip; `12-…` §2 lists it as displayed. Row identity is correctly the path, not the name.
- **The uncommitted-count convention is not stated on screen.** §2 requires it, because `git status --porcelain` and libgit2 disagree by a factor of two on the same repository (X-4).
- **The mode pill reports your selection, not the path taken** — so it can read `mode: structural` beside a notice saying structural analysis was unavailable.

---

## 3. Correctly built, worth knowing

Checked and sound: the read-only proof over every Git operation; the four scopes; unborn-HEAD handling (`carrefour-inapp` renders); ahead-count showing `↑?` rather than a fabricated zero; bidirectional scroll linking; the full keyboard map in the menu bar; the degradation notices; light and dark themes; the invisible-difference disclosure.

---

## 4. Defects found and fixed during this audit

- **`reconcile` returned a `moved` counter that nothing incremented and nothing read** — residue of the label removed in M6-D. A counter permanently at zero is worse than no counter: it reads as a measurement. Removed, and the compiler warning it was emitting with it.
- **A malformed `MANIFEST.json` would have skipped every fixture check.** The manifest block `return`ed out of the whole function on a parse failure, so a corrupted manifest would have produced a green suite over a corpus nobody looked at. The manifest failing is now a manifest failure and nothing more. Fourth instance of this defect class in the project; it is worth treating `return` inside a check block as a smell.

---

## 5. Out of scope, asked for anyway

**A built-in terminal.** Not in any document — the only mentions of "terminal" in the planning set are about the user's *external* terminal. `00-index.md` states the product is not a Git client, and `18-version-one-scope.md` admits no command execution of any kind.

Recorded here rather than dismissed, with what it would actually mean, in `05-open-questions.md` as OQ-055.

---

## 6. Suggested order

1. ~~Root management~~ — **done**, 2026-07-31.
2. ~~Gutter and line numbers~~ — **done**, 2026-07-31.
3. **File-list depth** (§1.5) — grouping and per-file degradation, worth most on the repositories with the most files.
4. **Base override and staleness wording** (§1.2, §1.3) — small, and they make scope 4 trustworthy.
5. **Scope disabling, focus refresh, wrap toggle, empty-diff wording** (§1.4, §1.7–1.9) — an afternoon between them.
6. Parser-state indicator (§1.10) — after the design gate, since it is one more thing on screen.
