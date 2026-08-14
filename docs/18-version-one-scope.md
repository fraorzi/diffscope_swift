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
- **Several terminal sessions in tabs, in a drawer across the window** (DEC-067, amending DEC-053). One shell and one emulator per tab; each tab says where *its own* shell is
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

**Audited 2026-08-14.** Seven of the eight were backed by passing checks and nobody's signature, which is not the same as being done: a check proves what it asserts, and the sentence above it can claim more. Each item below now names **what backs it** and **what a signature would be claiming beyond that**, so the signature is on facts rather than on an impression. The audit changed two of the sentences and found one real gap; it is recorded under item 2.

Three verdicts are used. **Met** — the evidence covers the sentence. **Met, sentence corrected** — the evidence was always there and the sentence over-claimed. **Not met** — something is missing, and it says what.

---

**1. Every P0 fixture group passes T-0 … T-11, on every path each fixture can reach.** — **Met, sentence corrected 2026-08-14**

*Backed by:* 55 fixtures, each run through **both** paths with T-0 … T-11 asserted by number — **835 assertions**. `MANIFEST.json` is read by a check, so a fixture whose bytes changed fails. The corpus is checked against §4 of `15-test-corpus-plan.md` in both directions: every P0 case named there exists in the corpus or names where it is proven instead (ten do), and every fixture on disk is either named in the plan or deliberately unlisted.

*What the sentence was claiming beyond that:* **13 fixtures do not reach the structural path**, each for a stated reason — not valid UTF-8, unsupported language, a merge-conflict marker, binary content. They pass T-0 … T-11 on the raw path, which is the only path they have; "every fixture passes on both paths" would have been false. The skips are printed by name and reason on every run.

*Also outstanding when this was audited, and closed the same day:* the two **P1** cases §4.5 named and never had — `moved-jsx-subtree` and `multiple-similar-siblings` — are built. **Every P0 and P1 case in the plan now exists**; what remains is six P2 cases for languages version one does not parse.

**2. The read-only proof (R-8) covers every Git operation the application can issue.** — **Met 2026-08-14, and it was not before the audit**

*Backed by:* all **18 registered operations** leave `.git` byte-identical, `status` included with a stale stat cache; the runner always passes `--no-optional-locks`; and `GitOperation` is a **closed enum** that `GitRunner.run` takes nothing outside of, so the registry cannot be widened through the runner.

*The gap the audit found.* The closing check — *every operation executed during this run appears in the proven registry* — is **dynamic and bounded by the run**, and it runs inside `diffscope-verify`, a different binary from the one that ships. It could never observe a path in the *application* that spawns git for itself. And there is one: `emptyScopeSelftest` runs `init`, `config`, `add` and `commit` through a raw `Process`, because the empty-scope state cannot be reached any other honest way. It is compiled into the shipped binary and gated at runtime by `DIFFSCOPE_SELFTEST=1`.

*What closed it:* a static check that the application shell spawns git **from exactly one place**, that the place is that arm, and that it writes into a directory it creates under `NSTemporaryDirectory()` — never into a repository the reader chose. The exemption is named the way the `@chrome` token block is named: a redirect rather than a hole, and a second call site fails.

**3. The JSX wrapper-removal case preserves its children, and the wrapper itself is marked.** — **Met, sentence corrected 2026-08-14**

*Backed by:* five checks on the founding case — the invariants hold, the children survive as unchanged on **both** sides, the wrapper is not reported unchanged, and most bytes are preserved rather than rewritten — plus the `wrapper-removal` fixture through T-0 … T-11 on both paths, and `structural.png`, which is the picture this product was started for.

*What the sentence was claiming beyond that:* *"reads as a wrapper change"* promises a **reading**, and the interface deliberately does not draw one. `24-…` records *wrapper removed* as one of two phrases left undrawn on purpose: `label`, `classification`, `group`, `disclosure` and `link` are the engine's whole vocabulary, and a renderer saying more than the engine said is what the design contract forbids. The corrected sentence says what is proven — children preserved, wrapper marked — and nothing about words on a screen.

**4. Prop reordering with unchanged values never reports "no change".** — **Met**

*Backed by:* three checks on the case itself, the `prop-reorder` fixture on both paths, and the reordering detectors in the classification suite. **The strongest of the eight**, because it does not rest on the one fixture: **T-4 — *no-change is shown exactly when the sides are byte-equal* — is asserted on all 55 fixtures on every path they reach.** A model that reported "no change" for any non-identical pair fails 55 times over, not once.

*What a signature claims beyond that:* nothing. The sentence and the evidence are the same size.

**5. Parser failure produces visible raw fallback, never a missing change.** — **Met**

*Backed by*, and this is the invariant with the most independent evidence in the suite: fallback is reachable through the structural path and its segments are presented; an unsupported language falls back **with a reason**; merge-conflict markers force fallback rather than being parsed; INV-4 reaches the interface **as a notice**, and its segments are labelled fallback rather than unchanged; the reason survives the crossing into the interface; **T-5 — *fallback ranges arrive marked* — and T-3 — *every changed byte is contained in a presented range* — are asserted on every fixture on every path.** The application selftest then asserts it in the live document, in the degraded arm.

*And since DEC-077 the sentence has a second half worth naming:* the fallback is the **one** technical statement the interface keeps, in plain words — *This file is shown as plain text — <why>. Every difference in it is still shown.* Everything else the pane said about its own machinery is gone; this stays because *silent and right* and *silent and wrong* look identical.

**6. A 63-file working tree is reviewable entirely from the keyboard.** — **Met 2026-08-09** (DEC-057), and measured rather than argued: `Scripts/keyboard-tree.sh` builds a tree of that size and the application selftest walks it with real key events — 63 files in 62 keystrokes past nine group headers, none of which takes the selection, on both the menu route (⌥↓ since DEC-065 re-cut the map; ⌘] when it was measured) and the bare arrow keys. `22-experiment-log.md` → **M8-J**.

**7. Structural and Expanded produce identical segment sets for every fixture that reaches the structural path (INV-5).** — **Met, sentence corrected 2026-08-14**

*Backed by:* T-6 — *Structural and Expanded agree on what changed* — asserted per fixture on every path, the dedicated INV-5 check (*the modes differ only in the declared mode*, and *Raw stays available on the same pinned pair*), and the application selftest's mode-agreement arm, which asks the **live document** rather than the model.

*What the sentence was claiming beyond that:* the same 13 fixtures as item 1. On the raw path both modes fall back identically, so T-6 holds there trivially — which is worth stating rather than counting as coverage of the structural claim.

**8. The application is incapable of modifying a repository on any path of its own (R-8), and the terminal's one composed command — `cd` under DEC-056's guard — changes no repository state.** — **Met 2026-08-14**

*First half:* item 2, including the static check the audit added. Before it, this sentence rested on a dynamic check running in a different binary.

*Second half, and it is thoroughly backed:* the composed `cd` comes back as one closed single-quoted string for every hostile path, **a real shell lands in every hostile directory the quoting names**, and an unquoted path would not have worked — so the quoting is doing the work rather than being decorative. The command names one directory with `--` before it. The guard is asserted in both directions: nothing is sent while the reader has something typed, nothing while somebody else owns the keyboard, and at an empty prompt the quoted command — not an interpolated string — is what actually reaches the shell. An unrecognised shell is never sent a `cd` it could not have been asked for. Separately, `R-8`'s own pattern is pointed at `$HOME`: **no rc file in the home directory changed.**

*What a signature claims beyond that:* the terminal runs whatever the reader types, and that is in scope by DEC-053. This item is about the commands the **application** composes, of which there is one.

---

**What is left, and none of it is a signature.** Three questions need the owner's eye rather than a check: the glass material, which cannot be photographed on the build machine; [DEC-080](04-decision-log.md)'s surface ladder; and [DEC-081](04-decision-log.md)'s four kind hues. All three are in `21-agent-handoff.md` §0. Six **P2** fixtures remain unbuilt, for CSS, JSON, Markdown and HTML — languages version one does not parse (DEC-004), so they are deferred scope rather than missing coverage.
