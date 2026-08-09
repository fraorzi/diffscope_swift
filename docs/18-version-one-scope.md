# 18 — Version One Scope

**Status:** Phase 8. Authoritative for what v1 is and is not.
Derived from the decision log; where this document and [04-decision-log.md](04-decision-log.md) differ, the log wins.

---

## In scope

### Platform and shell
- macOS only, permanently (DEC-002)
- Single window: repository sidebar + diff pane; last repository remembered (DEC-005)
- System light/dark theming, live switching (DEC-019)
- Swift shell and engine, CodeMirror 6 in `WKWebView`, Git CLI (DEC-042)

### Repository discovery
- Any number of user-chosen roots, **no default path, no auto-detection** (DEC-036, DEC-037)
- Individually added repositories anywhere (DEC-037)
- Depth 2 per root, descent stops at the first repository found (DEC-018)
- Eager parallel status sweep at launch, refresh on window focus (DEC-006)
- All repositories shown, with two independent signals: uncommitted count and commits-ahead-of-base (DEC-012)

### Git
- The application's own Git usage is strictly read-only; `--no-optional-locks` on every invocation (DEC-003). **A built-in terminal is in scope since DEC-053** and runs what the user types, including commands that write — see `26-terminal-plan.md`
- Never fetches (DEC-011)
- Four scopes: all-local vs `HEAD`, unstaged vs index, staged vs `HEAD`, branch vs merge-base (DEC-008)
- Base detection cascade with per-repository override (DEC-009)
- Remote-tracking base preferred, ref and age always displayed (DEC-010)
- Unborn HEAD handled correctly, without the lying `symbolic-ref` idiom (DEC-042)

### Diff engine
- Byte partition as model primitive (DEC-024)
- Structural diffing for **TS / TSX / JS / JSX only**; everything else raw and labelled (DEC-004)
- tree-sitter via C API, byte-native offsets (DEC-042)
- Matcher from publications, consumed as node mapping only (DEC-029, DEC-030)
- Ambiguity surfaced as confidence, never resolved silently (DEC-031)
- **Byte-identical moves only** (DEC-038)
- Wrapper add/remove visualisation (DEC-017)
- Nested token / word / character refinement
- Classification: formatting-only, reordering, potentially-behavior-affecting
- Invariants INV-1 … INV-5; partition assertions always, `D` check below 2 MB (DEC-021, DEC-022, DEC-040)
- Invisible-difference disclosure: normalisation forms, zero-width and bidi, whitespace lookalikes (DEC-023)

### Presentation
- **Unified by default, side-by-side as a mode** over the same pinned pair (DEC-059, amending DEC-014). In unified, direction is carried by a `+` / `−` sign column, not by hue
- Three modes over two code paths: Structural / Expanded / Raw (DEC-013)
- **Three lenses over the selected file: Diff, Blame, History** (DEC-061, amending DEC-008). History's two-commit selection is a commit-vs-commit comparison; both lenses are read-only and go through the closed operation registry
- **Search within the diff** (DEC-062, amending DEC-017), scoped to the changed set by default (⌘F), whole worktree on request (⇧⌘F). Matched as literal text, never as a pattern compiled from repository content
- **Rendered comparison for images and SVG** — Side by side, Blend, Split, Pixel diff, with a 16-megapixel budget on the last (DEC-063). SVG carries both readings, rendered and source, and is rendered through an `<img>` so repository content never executes
- **Three independent collapses** — repositories, changed files, terminal — each with a keyboard binding; collapsed is reduced, never hidden (DEC-060)
- **Motion, with a registered reduced-motion path for every transition** (DEC-064, amending DEC-016)
- Syntax highlighting, with change meaning carried **outside token colour** (DEC-017, DEC-035)
- Navigation: previous/next change, collapsed unchanged ranges, changed-file list (DEC-017)
- Flat file list grouped by workspace package, middle-elided paths (DEC-033)
- All mandatory trust indicators (DEC-017)
- Auto-refresh, trailing-edge debounce with cap, anchored to nearest unchanged segment (DEC-007, DEC-026, DEC-034)

### Integration and accessibility
- Configurable editor command, WebStorm default (DEC-015), with a visible failure state
- No colour-alone meaning; full keyboard operation; system contrast respected (DEC-016)
- Reduced motion respected by a checked off switch rather than by the absence of motion (DEC-064)
- The keyboard map of DEC-065; the token table of DEC-066. The adopted design and how it maps onto the build: [27-design-adoption.md](27-design-adoption.md)

## Out of scope — deferred

| Item | Ref |
|---|---|
| Any write operation: staging, commit, discard, branch | DEC-003 |
| Manual fetch button | DEC-011 |
| Branch-vs-branch, and a picker that is a second place to be rather than a lens | DEC-008, DEC-061 |
| Structural diffing for CSS, JSON, Markdown, HTML | DEC-004 |
| Moved-and-modified detection with `innerDiff` | DEC-038 |
| Filter by change type | DEC-017 |
| Change minimap; personal annotations | DEC-017 |
| Screen-reader support | DEC-016 |
| Homoglyph detection | DEC-023 |
| Internal CRLF filter implementation | DEC-028 |
| Five-level contextual tie-break for ambiguity | DEC-031 |
| Nested repositories, submodules, worktrees as separate entries | OQ-014, OQ-015 |

## Out of scope — rejected

| Item | Why |
|---|---|
| Cross-platform support | DEC-002 — permanently |
| Repository tabs; multiple windows | DEC-005 |
| Continuous watching of all repositories | DEC-006 |
| Hiding clean repositories | DEC-012 |
| Hardcoded or suggested default root path | DEC-036 — editor-specific |
| Auto-detection of candidate roots | DEC-036 — predictability over convenience |
| Creating the root directory automatically | DEC-036 — trust model |
| Executing repository-configured filter commands | DEC-028 — RCE surface |
| Tailwind-specific subsystem | DEC-004 |
| Normalisation anywhere in the pipeline | DEC-021 |
| Edit scripts as matcher output | DEC-029 |
| Network, telemetry, cloud, runtime AI | Brief, DEC-011, DEC-020 |
| Automatic `git fetch` | Brief, DEC-011 |

## Definition of done for v1

1. Every P0 fixture group passes T-0 … T-11.
2. The read-only proof (R-8) covers every Git operation the application can issue.
3. The JSX wrapper-removal case reads as a wrapper change with children preserved.
4. Prop reordering with unchanged values never reports "no change".
5. Parser failure produces visible raw fallback, never a missing change.
6. A 63-file working tree is reviewable entirely from the keyboard. **Met 2026-08-09** (DEC-057), and measured rather than argued: `Scripts/keyboard-tree.sh` builds a tree of that size and the application selftest walks it with real key events — 63 files in 62 keystrokes past nine group headers, none of which takes the selection, on both ⌘] and the arrow keys. `22-experiment-log.md` → **M8-J**.
7. Structural and Expanded produce identical segment sets for every fixture (INV-5).
8. The application is demonstrably incapable of modifying a repository on any path of its own (R-8), and the terminal's one composed command — `cd` under DEC-056's guard — changes no repository state.
