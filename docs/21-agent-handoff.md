# 21 — Agent Handoff

**Start here if you are new to this project.** This document is kept current; everything below reflects the state as of the last completed milestone.

Reading order: this document → `glossary.md` → `04-decision-log.md` → `19-roadmap.md`.

---

## 0. Where the project stands right now

**DEC-069, 2026-08-11 — OQ-054 is closed, and it was wrong about the mechanism and wrong about the remedy.** It had asked for case-folded **and** NFC-normalized path matching, and said a mismatch meant *auto-refresh silently stops updating that file*. Measured (M9-F): **the watcher never matches paths** — it ORs the event flags and signals `.changed` for the whole repository, so that failure mode cannot occur; and **Swift's `String ==`, `hasPrefix` and `Set` membership are canonical equivalence**, so the normalisation half needed no code at all. This is **M6-C read backwards** — there, canonical equivalence made an NFC detector silently detect nothing; here it does the work for free. It is asserted in the suite now rather than relied on quietly. The filesystem is also case- and normalization-insensitive for lookup, so *reading* a file never fails for these reasons.

**Root scanning was never broken either**: `contentsOfDirectory` returns the filesystem's own spelling and `resolvingSymlinksInPath` canonicalises case, so the first check written for this **passed on the unfixed code** — the measurement contradicting the plan, again. What was actually broken is narrow: an **individually added** repository is taken verbatim from the configuration and goes through neither, so under DEC-037 the same working tree reached by a root *and* added directly produced **two rows** — two watchers, two sweeps, one going stale. The spellings differ by more than case (`/var` against `/private/var`), which is the argument against fixing it with string arithmetic. **DEC-069 stops computing identity and asks the filesystem**: device plus inode where the path exists, a folded string only where there is nothing to ask. 1598 → **1608 checks**, two of them negative controls.

**DEC-068, 2026-08-11 — the pin guard was certifying an empty file, and the check that should have caught it was sampling fifteen reads.** This is the one to read if you read nothing else here. R-9's race arm ran for **1.5 seconds**, which on this machine buys **15 reads**, and on those fifteen it asserted *no pin certifies a version that never existed on disk*. Bounding it by **reads** instead (200) produced blends immediately: **5 in 1,200 reads, clustered**. M8-H had already measured this guard's two halves leaking at 6-in-20 and 3-in-8,095 — **rates fifteen observations could not possibly detect.** The arm was not weak, it was under-sampled, and nothing printed the sample size because only the window was chosen.

Making the arm report the **shape** of what it let through identified the cause in one run: `0/52000 bytes, 0 A-lines + 0 B-lines` — **every blend was a zero-length file.** A non-atomic save truncates and then writes, and in that window the file is genuinely empty *and genuinely quiescent*: three stats agree the size is 0, both reads return nothing, every term of DEC-049's guard is satisfied. It asks *did anything change while I looked*, and nothing did. In the product it renders as **the whole file deleted**. **DEC-068** separates the confirming read from the first by the 20 ms the type already owned; **0 blends in 1,600 reads** since, and the cost is that a burst of saves now refuses about three pins in ten where it refused none — the *usable pins* arm passes at ~70% against its >50% floor. Method and both rates in `22-experiment-log.md` → **M9-E**.

Three generalisations worth carrying: **a blend includes a short or empty read**, not only interleaved content; **bound a race by observations, never by a clock**, and print the count; and **a fixture whose two sides are the same length disables the size term of any stat guard** — these were 52,000 bytes each, so only `mtime` was working.

**`05-open-questions.md` was audited on 2026-08-11, and it had been lying by omission.** **Twenty-four entries were marked Open while a decision, a measurement or shipped code had already answered them** — OQ-003, 004, 005, 008, 010, 017, 026, 028, 031, 033, 036, 037, 038, 039, 040, 042, 043, 044, 045, 048, 049, 050, 051, 052 — and one (OQ-049) appeared **twice**, Open in one section and struck through in another. Each is now closed with what closed it. The document's header carries the short answer: **eight genuinely open, five part-answered**, each with its remainder stated. **The one to look at is OQ-054** — case-folding and NFC in path matching, confirmed unaddressed by the audit, and the only one still open whose failure mode is silent: FSEvents reports the on-disk case, so auto-refresh stops following a file and nothing on screen says so. Everything else still open is a deferral, a shipping question, or a naming question.

**M9-C and M9-D, 2026-08-11 — the unified layout was measured at scale, and a check failed once and got away.** The layout question is answered and the answer is the opposite of the suspicion that prompted it: **unified is cheaper than side-by-side** — 0.49× on a minified megabyte, 0.61× at fifty thousand lines, 0.68× on a densely changed structural file — because it populates one editor where side-by-side populates two. The composition it does on top costs **1.1 ms** against a **28 ms** dispatch. `projectSegments`, the nested loop the measurement went looking for, is the only superlinear term and measures 4.75 ms on the one case that reaches it with segments in it; **DEC-050's 30,000-node budget bounds it in practice**, which is a load-bearing consequence that budget was not written for. Recorded as a known weakness rather than optimised: **re-measure if the node budget is raised.** The `scale-*` arms assert a 2× ratio bound and `diffscopeInjectSlowProjection` is their control, taking it to 90.9×. Three cases, and the third exists because the first two fall back to raw — **a raw fallback carries one segment per side, so both would have reported the loop free**. Numbers and method in `22-experiment-log.md` → **M9-D**; `16-…` §2, §3 and §8 are updated.

**The other half is a defect observed and lost.** The first run of the session reported **1597/1598**; five idle runs and three under eight CPU spinners all reported 1598/1598, and **the failing check was never identified** — the first run's output had been tailed and the `FAIL` line sat fifteen hundred lines above the summary. So the harness now reprints failed names under `what failed:` beside the count, and the next occurrence identifies itself. Three arms in `RefreshChecks` were re-expressed alongside it because they are provably load-dependent by reading, not because they are known to be the culprit: the R-9 race is bounded by **reads** (200 and 100) rather than by 1.5 seconds, and two waits became multiples of the thing they wait for — the debounce arm had been waiting **1.5 s for a refresh DEC-026 allows 2 s to deliver**. `22-experiment-log.md` → **M9-C**. **If a check ever fails once, keep the whole output.**


**M8-Q, 2026-08-09 — the design was reviewed against the specification, eight decisions came out of it (DEC-059 … DEC-066), and the first four steps of `27-…` §4 are built.** Landed: the token table in both halves of the window with the chrome mirror finally checked, DEC-065's keyboard map, the unified layout with its sign column, and the three independent collapses. Steps 5, 6 and the search half of 7 are done: the base-ref age says *newest commit* rather than anything a reader could hear as a fetch time, unavailable scopes state their reason on the line, the editor command is configuration with a Settings window, `#unrenderable` says what the file is and why nothing is compared, motion is in with a reduced-motion check carrying two negative controls, and search runs over the changed set (⌘F) or the whole worktree (⇧⌘F). **M9-A, 2026-08-10 — the chrome caught up with the design**: line counts behind the file list (`diff --numstat`, with `binary` as a state rather than a zero), both lists drawn as columns, selection drawn from the design's own two tokens, the base row under the scope control, the mode control in the order the keyboard numbers it, the file header in the diff pane, the lens control beside the other two, and search as a field rather than a modal. **M9-B the same day** closed all six cosmetic items and two of the three substantial ones: hunk headers, sliders for Blend and Split, **linked horizontal scrolling** (a §5.4 line that had never been wired), the focus ring (a mirrored token nothing drew), Settings as a window, History's commit picking as a real comparison, and search results in the pane with ⌘G / ⇧⌘G. **DEC-067 the same day** reopened DEC-053 and built the last of it: the drawer spans the window (the grid went from 104 columns to 202) and holds several shells in tabs, one `TerminalSession` and one xterm instance each. The empty state's button rim followed the same day, drawn *around* the system button so it keeps the key-equivalent ring and the pressed state, and the empty state is photographed for the first time. **Nothing in the adopted design is now outstanding** — `tasks/todo.md` steps 41–43.

The two lenses and the rendered comparison landed on the same day: `blame` and `log` are in the closed operation registry so R-8 covers them, their parsers are pure functions with fourteen checks, and an image or SVG is now compared by being drawn — classification from bytes as well as names, the pixel pass and its mask computed in Swift because a canvas that has drawn an SVG cannot be read back, and every mode offered or refused with a reason. **All eight steps of `27-…` §4 are built, and so are the eight fixtures behind the last one** (2026-08-10): 55 fixtures under T-0 … T-11, 1561 checks, and two arms asking what only a real fixture can — that a re-encoded PNG reports 0 differing pixels, and that an SVG carrying a script is drawn and inert. The short version: **unified becomes the default layout**, the two sidebars collapse independently, **History, Blame, search and a rendered comparison for images and SVG enter version one**, **motion is admitted** and reduced motion becomes a checked off switch instead of an absent one, the keyboard map is re-cut around arrows and modifier tiers, and the design is delivered as an eighty-row token table whose *mirrored* column finally makes the `Theme.swift` hand-copy checkable. Start at [27-design-adoption.md](27-design-adoption.md) — it says where the design lives, what the review had to fix in it, and the order the work goes in. The four amended entries (DEC-014, DEC-008, DEC-017, DEC-016) carry pointers and were not rewritten.

**Last completed milestone: M7 — refresh, watching and navigation, complete. M8 hardening is under way: structural budgets, the degradation precedence, the T-series coverage audit, root management, the gutter, the grouped file list, the built-in terminal (T0–T4), the keyboard path (M8-J) and the last four items of the interface audit (M8-K) have all landed, and **all three handover gates have passed**. `23b-spec-vs-app-audit.md` is now closed — every requirement it found written down and not built is built. 1413/1413 checks pass over 47 fixtures.**

| Milestone | State |
|---|---|
| M0 verification gates | Complete — DEC-042 confirmed |
| M1 engine skeleton, invariant harness | Complete |
| M2 Git layer | Complete |
| M3 raw diff end to end | Complete |
| M4 parsing and partition construction | Complete |
| M5 matching and alignment | Complete |
| **M6 classification, moves, trust surface** | Complete |
| **M7 refresh, watching, navigation** | **Complete** — navigation, folding, keyboard map, FSEvents watching, debounce, scroll anchoring, formatting-only collapse |
| M8 hardening and beta | **Started** — DEC-050 budgets, DEC-051 degradation precedence, the M8-C coverage audit, DEC-052 root management, the terminal (DEC-053…056), the keyboard map (DEC-057) and the closing of the interface audit (DEC-058) landed; the rest of §"What to do next" remains |

Run everything:

```
swift run diffscope-verify          # 1413 checks over 47 fixtures, exit 1 on failure
./Scripts/package.sh                # DiffScope.app + zip + SHA-256 for a tester
swift run diffscope-verify --write-manifest   # re-record fixture hashes, deliberately
swift run -c release diffscope-verify --survey ~/YourProjects
swift run -c release diffscope-verify --budget-survey ~/YourProjects
swift run -c release diffscope-app  # the application
swift run diffscope-t0              # gate T0 of the terminal plan, 17 scenarios over real PTYs
```

`DIFFSCOPE_SELFTEST=1 swift run -c release diffscope-app` proves the whole native pipeline headlessly and exits: raw ŻABKA probe → structural render with a formatting-only label → INV-5 mode agreement across the webview → invisible-difference disclosure naming `U+0307` → a relocated block reported as one move → navigation and folds → a formatting-only group with its disclosed count → an anchor surviving an insertion above it → a ranked degradation notice reaching the document. Adding `DIFFSCOPE_SNAPSHOT_DIR=/some/dir` writes `structural.png`, `expanded.png`, `disclosure.png`, `moved.png`, `navigation.png`, `refresh.png`, `anchored.png`, `degraded.png` and `gutter.png` of what the webview actually drew — the only way to check legibility, which the probe cannot see. Since T1 it also runs a command through a real PTY into the terminal grid and writes `terminal.png`; since T2 it types into the input line, submits, hands over on Tab and forces raw, writing `terminal-input.png`; since T3 it follows a selection into a directory whose name contains a quote and a space, writing `terminal-follow.png`. Since M8-J, `DIFFSCOPE_KEYBOARD_TREE=<dir built by Scripts/keyboard-tree.sh>` adds the keyboard walk — 63 files pressed through with real key events — and writes `keyboard.png`, the **first snapshot of the window rather than of the document**. Without that variable the arm says SKIPPED with the reason; `./Scripts/package.sh` builds the tree itself and refuses to package a build whose walk was skipped.

### What exists in code

| Module | Contains |
|---|---|
| `DiffScopeEngine` | Byte partition, canonical Myers diff, invariant validation, UTF-16 mapping, render contract. Imports only `Foundation`. |
| `DiffScopeGit` | Read-only Git layer: closed operation registry, four scopes, base cascade, discovery, parallel sweep, FSEvents watcher and refresh debounce |
| `DiffScopeSyntax` | tree-sitter parsing, partition construction, matcher, structural diff |
| `CTreeSitter`, `CTreeSitterTSX` | Vendored C, MIT |
| `diffscope-verify` | The whole check suite, headless |
| `diffscope-app` | AppKit shell + `WKWebView` |
| `DiffScopeShell` | The keyboard map (DEC-057): `12-…` §9's coverage table as an enum, the bindings as data, AppKit-free so the check suite links the same file the menu bar is built from |
| `DiffScopeTerminal` | The terminal: `PtyProcess` (forkpty, resize, teardown), `TerminalScanner` (OSC 133, OSC 7, the alternate screen), `ShellIntegration` (generated `ZDOTDIR` / `--rcfile`), `TerminalSession` (shell choice, coalesced output, prompt state, mode, following the selection), `InputRouter` (where a keystroke goes, and this session's history), `ShellQuoting` (**the only place the application composes a command**) |
| `diffscope-t0` | Gate T0 of the terminal plan: `forkpty`, an OSC 133 scanner, a generated `ZDOTDIR`, and the macOS motions measured in both surfaces. Now imports `DiffScopeTerminal`, so the gate measures the shipping code rather than a copy. Deliberately outside the check suite: it drives ten real interactive shells and depends on this machine's `~/.zshrc` |
| `Renderer/src` | Two surfaces: the CodeMirror diff (`main.js`) and the xterm.js terminal grid (`terminal.js`); build both with `npm run build` in `Renderer/` |

### What M6 landed

- **Classification** (DEC-046). Byte-level equivalence tests over the aligned gap pair, computed before reconciliation because that is the only point where both sides of a change are known to correspond. Vocabulary: `whitespace`, `quote-style`, `trailing-comma`, `paren-only` → `formatting-only`; `reordering` → `potentially-behavior-affecting`. Measured on 120 real files: 97.8% recall on a whitespace-only edit, **0 false formatting-only claims of 1111** on a rename (M6-A).
- **The diagnostic labels are gone.** `anchor`, `filler`, `refined` and `moved-content` no longer exist; the suite asserts nothing outside the typed vocabulary reaches presentation. Note the trap this sprang: `reconcile` identified anchors by testing `classification == "anchor"`, so removing the strings silently changed its behaviour until anchor identity was passed explicitly — and that mechanism has since been replaced entirely by the move search.
- **The application shows structure.** `diffscope-app` runs `structuralDiff` for the structural modes and raw otherwise; a structural result that fails validation is discarded whole and replaced by raw with the reason shown (INV-4). Status line reports anchors, moves, formatting-only and ambiguity counts.
- **Raw · Structural · Expanded** as presentation flags over one model (DEC-013). Expanded simply drops the quietening of grouped marks, so INV-5 holds by construction and is checked both in the harness and across the webview.
- **Boundary snapping** (DEC-047, measured in M6-B). Changed ranges widen outward onto named-node boundaries within a 16-byte budget: **34.3% → 97.0%** of boundaries land on a syntax boundary, costing **+4.4%** bytes presented. Applied *after* labelling — widening the mask `reconcile` consumes would manufacture `moved` claims out of a presentation setting.
- **Invisible-difference disclosure** (DEC-023, measured in M6-C). `normalization-form`, `invisible-control` and `whitespace-lookalike` ride as a second axis beside classification, because the axes cross — a trailing non-breaking space is both formatting and invisible. Expanded names the codepoints. **Read M6-C before touching it:** Swift's `String ==` is canonical equivalence, so the obvious NFC test is always false and the detector silently detected nothing while its fixtures passed.
- **Confidence is indicated, not merely computed.** `confidenceFloor = 0.8` lives in the engine and the contract carries a computed `uncertain` flag, so a renderer cannot quietly redefine what counts as certain.
- **Deliberate move search** (DEC-038, measured in M6-D). Line-matched, byte-identical, linked pair by pair; 120 of 120 corpus files recognise a relocation with **0 false moves**. The old reconciliation-derived `moved` label is gone — it claimed a move while seeing one side only, so it could not check the condition DEC-038 names. The rejection floor is *counted* (`movesBelowFloor`), because DEC-038 records git's silent floor as the thing to avoid.
- **`runBundleFreshnessCheck` is now actually registered.** It was written in M5 and never called, so a stale renderer bundle would have shipped silently. Worth remembering as a class of defect: a check that is not run is not a check.

### Read this before planning M7

A benchmark after M5 (`22-experiment-log.md` → M5-B) established that **the structural layer contributes nothing to alignment quality** — and cannot, because INV-2 caps the "unchanged" set at whatever the canonical byte diff already found. Measured identical to a tenth of a percent across four perturbations on 120 real files each.

Its remaining value is three things: `moved` labels (bytes cannot express moves), classification, and **where a change is shown to begin and end**. The third is the slider problem: only 38% of canonical-diff hunk boundaries land on a tree-sitter node boundary, and 91% of files contain at least one misalignment.

**Boundary snapping now addresses the presentation half of that** (DEC-047) — 97.0% of boundaries land on a syntax boundary for +4.4% bytes shown. **Tie-breaking proper is still not done and cannot be under INV-2 as recorded**, because choosing a different equally-minimal alignment moves bytes out of the presented set while the validator recomputes one specific alignment and demands containment. Reopen DEC-021 first if you want it; do not attempt it as an implementation detail.

**Do not add work to the matcher on the assumption that better matching means better alignment. It does not.**

### What M7 landed

- **Change stops and folds are computed in the engine**, carried on the render contract in UTF-16, and merely executed by the renderer — so both are checkable headlessly (M7-A). Navigation follows the **canonical diff**, not the presented segments, because presented ranges are supersets after snapping and walking the superset drifts from the alignment INV-2 is stated against.
- **A fold is offered only where both sides are byte-equal.** Folding is the one presentation act that hides content, so it is the one place the "never suppress" invariant has teeth. Byte-equality also keeps the two panes aligned while folded.
- **The keyboard map lives in the menu bar** (DEC-016): modes ⌘1–3, scopes ⇧⌘1–4, ⌘N/⌘P next and previous change, ⌘E expand, ⌘[ ⌘] files, ⇧⌘[ ⇧⌘] repositories, ⌥⌘1–3 focus, ⌘O open in editor.
- **Editor integration** (DEC-015): a `{file}`/`{line}` template defaulting to WebStorm, overridable through `DIFFSCOPE_EDITOR`, never populated from repository content, with failure shown in the status line.
- **FSEvents watching** (DEC-027) on the open repository only, `node_modules` excluded, with DEC-026's trailing-edge debounce and 2 s cap in application code — the configuration is `FileEvents | NoDefer | WatchRoot`, latency 0.0, and the reason is in M7-B. F15's drop path is forced through `deliver(flags:)` because it will never fire on its own.
- **A pin is refused rather than blended** (DEC-049, R-9). Re-reading and comparing content let 3 blends through in 8,095 reads; the read is now bracketed by a `stat`, and a file still being written is not rendered at all.
- **Scroll anchoring** (DEC-034, measured in M7-C). Anchors come from the canonical diff's matched blocks, one per line, identified by a 3-line content hash plus an occurrence index. Twenty refreshes with no change resolve to one position — the drift clause, checked rather than argued.
- **Formatting-only collapse** (DEC-048, measured in M7-C). Driven by canonical hunks, because a reindent is an insertion and has no old side; offered only where both sides span the same number of lines, with rejections counted.

### What M8 has landed so far

- **The structural path has budgets** (DEC-050, measured in M8-A): 2 MB before parsing, 30,000 nodes before matching, 10,000,000 counted comparisons during it. Before this there were **none** — a minified bundle was a hang, and a hang takes the interface with it. Matching cost is roughly **quadratic** in node count, and the budget is counted work rather than a deadline because T-7 makes giving up part of the output.
- `--budget-survey` reports the distribution the values came from, including what sits **nearest each gate**. On the corpus that is `.next` build output every time; no hand-written file comes close.
- **Failure copy has one source** (`fallbackNotice`, `discardedNotice`): what was withheld, why, and what remains trustworthy — the third part being the one `13-…` §6 says is usually omitted and matters most.
- **Degradation precedence is data** (DEC-051, forced in M8-B). `Degradation` in the engine carries an F-code and a rank transcribing `13-…` §5; `classify` gathers every condition that holds instead of returning on the first. Four of seven multi-condition inputs changed which reason they report — a binary `.png` said *"unsupported language"* before, which is true and the milder of two true statements. **Evaluation order and precedence are different things**: gates still fire where they are cheapest, precedence only picks the sentence.
- **F8 is implemented at all, for the first time.** `checkAttr` had existed since M2 and was never called, so DEC-028 and DEC-041 were unenforced — the `runBundleFreshnessCheck` defect again. One `git check-attr` per file the reader *opens*, not per file listed. A filter is disclosed even when the two sides are byte-equal, because that is the DEC-041 case exactly.
- **`cat-file --textconv` is out of the read-only registry**, with `GitOperation.forbiddenArguments` standing guard. R-8 proved it does not *write*; `--textconv` runs a command the *repository* configures, and those are different properties.
- **F13 reports both its arms**, and building the fixture found an unrelated defect: the editor template was substituted before being split, so a path containing a space became three arguments.

- **The T-series is applied by number to every fixture, on both paths** (M8-C). Before this, every fixture was validated on the **raw** path only — `jsx-wrapper-removal`, the founding case, had never had its structural model checked by the harness. The corpus grew 9 → 32 fixtures; `MANIFEST.json` is now read by a check rather than being dead data (third instance of that defect class); the map is `26-coverage-audit.md`.
- **T-10 was a documented requirement with no implementation.** `14-…` §4 mandates outward grapheme-cluster snapping and nothing did it, so an emoji-ZWJ insertion cut a cluster in half. `snapToGraphemeBoundaries` runs after syntax snapping — a syntax boundary need not fall on a cluster boundary.

### What to do next

**The product owner has put the built-in terminal first** (2026-07-31, resolving OQ-055). Everything below it in this list was the audit's ordering, not theirs. The plan is [`26-terminal-plan.md`](26-terminal-plan.md).

**T4 landed on 2026-08-01, and the terminal is complete** (`26-terminal-plan.md` is closed). Eleven documents promised that this product could not change a repository; each now separates **the application acting on its own** — which still writes nothing, proven by R-8 — from **the user typing in a shell it hosts**. `25-tester-packet.md` was rewritten for the person who gets the zip: they are told a shell lives in the window, that it commits if they tell it to, and that their own `~/.zshrc` is never edited, all before the install instructions. DEC-003 now carries its amendment pointer on the entry itself, because that is where a reader lands first. **A check holds this in place** (`DesignChecks`): the retired sentences are a table, every current-state document must also *mention* the terminal — removing a false claim without stating the true one is the worse defect — and a negative control puts the old wording back and requires it to be caught.

**What to do next is no longer the terminal.** The list further down this section — OQ-046, a second move shape — is the audit's ordering and is untouched by any of this.

**M8-K landed on 2026-08-09, and `23b-spec-vs-app-audit.md` is closed.** The four items it still listed were one kind of thing — statements the interface makes about how far to trust what it is showing — and they are settled by **DEC-058**, measured in `22-experiment-log.md` → **M8-K**:

- **The parser state is stated rather than inferred** (`12-…` §5.2's seventh and last indicator). A reader used to conclude "this parsed" from the absence of a notice, and that inference is wrong in both directions: a filter (F8) is a notice about something else entirely, and a partial parse (F1) leaves the structural result standing behind a notice that reads like a whole-file failure. `ParserStateReport` is computed beside the statistics, so the suite exercises the derivation the window uses.
- **The mode pill reports the path taken as well as the selection** — `mode: structural — showing raw`. Its first version invented a disagreement for Expanded, which is a presentation flag over the structural path: **three modes, two code paths**, and `impliedPath(ofMode:)` now states that mapping once. The selftest caught it, not the harness, because only one arm renders in Expanded.
- **The branch is in the row** and no longer only in a tooltip. A tooltip is not a display — it is invisible until pointed at, so the keyboard reader M8-J measured never saw it.
- **The uncommitted count says what it counts**, from `RepositoryReader.uncommittedCountConvention`, and a check asserts the operation actually run makes the sentence true. X-4's 63-versus-165 is why this is correctness rather than a caption.

Two method notes from it. **A caption can vanish twice and pass every check both times**: an `NSStackView` gives a label zero height beside a scroll view that grows without limit. And a snapshot answers *is it drawn*; it answers *is it legible* only when you look at it at the size the reader does — the caption looked absent in a downscaled crop and was there at full resolution.

**M8-J landed on 2026-08-09, and the definition of done §6 is met** — a 63-file working tree reviewable entirely from the keyboard, measured rather than asserted. **DEC-057**, measured in `22-experiment-log.md` → **M8-J**. Three things in it are worth more than the feature:

- **The keyboard map is data** (`DiffScopeShell/KeyboardMap.swift`), the menu bar is generated from it, and `12-…` §9's coverage table is transcribed into an enum the check suite links. The first thing that check found: *show raw for the current region* — a row of the specification — **had no implementation at all** and had not been noticed for three milestones. It is now ⌘R (⌥⌘V until DEC-065 re-cut the map), which switches to Raw on the same pinned pair and back, keeping the change stop, because stops come from the canonical diff and are the same in every mode.
- **Headers took the selection under the arrow keys.** DEC-033 has said since M8-F that headers are labels, and only ⌘] / ⌘[ obeyed it; ↓ landed on a header, the handler returned in silence, and the diff pane went on showing the previous file. Refused at the source now (`shouldSelectRow`), so all three routes agree. The negative control is in M8-J: with the refusal removed, the same walk reports 8 blind stops while every check still passes.
- **Walking fast crashed the application**, and nothing in the suite could have seen it: one shared `TSXParser`, renders on the concurrent queue, two threads inside `ts_parser_parse_string`, process aborted. **Every check in this project parses on one thread.** The parser now locks, renders are serialised, and a render whose file is no longer selected is dropped — that second half was its own defect, one file's diff under another file's name.

**If you are adding a keyboard function, add it to `KeyboardMap.bindings`.** There is nowhere else: `buildMenu` iterates the map, and `selector(for:)` is the single place an identifier becomes a method.

**T3 landed on 2026-08-01** — the terminal belongs to the product. It reports where it is (OSC 7) rather than assuming, follows the reader's selection under a three-term guard (a prompt mark actually seen · the input line owns the keyboard · nothing typed), and offers ⌥⌘K when the guard refuses. The path is quoted by one function and proved against a real shell over twelve hostile directory names. **DEC-056**, measured in `22-experiment-log.md` → **T3-A**, where the plan's own premise was measured false: FSEvents *does* see `git commit`, so the command mark refreshes only the repository sweep the watcher cannot know about. **T4 is the last step** — rewriting `25-tester-packet.md` and the documents that still say this product cannot change a repository.

**T2 landed on 2026-08-01** — the terminal now does the thing OQ-055 asked for. At a prompt the keyboard belongs to a real text field, so Option+←/→ and Cmd+←/→ work in a command line; **Tab and ⌃R hand the line to the shell** so zsh's own completion and reverse search behave normally; ↑/↓ walk this session's history; **⌥⌘R forces raw mode** for the cases where prompt detection is wrong, and a chip always says which mode is in force. `InputRouter` in `DiffScopeTerminal` owns every routing decision, so the rules are checked headlessly rather than looked at. **DEC-055**, and `22-experiment-log.md` → **T2-A**. **Next is T3** — the terminal belonging to this product: opening in the selected repository, following the selection, and the watcher refreshing the diff when a command changes the working tree.

**T1 landed on 2026-08-01.** `DiffScopeTerminal` holds the PTY, the OSC 133 scanner, the generated shell integration and the session; the grid is xterm.js in a second `WKWebView` (**DEC-054**); ⌃` opens a pane under the diff (⌥⌘T until DEC-065), and the shell starts on first open rather than at launch. **Next is T2** — the Warp-style input line — in `26-terminal-plan.md` §5. Sizes and the coalescing measurement are in `22-experiment-log.md` → **T1-A**.

**Read T1-A before touching the grid.** The first terminal selftest passed every arm while the snapshot was **completely blank**: xterm paints inside `requestAnimationFrame`, and WebKit suspends those whenever the window is occluded, which a selftest launched from a terminal always is. The buffer filled, the screen stayed empty, and nothing else looked wrong. M8-D's defect class through a different door. The grid's probe now reports `renderedText` and `framesSinceLastProbe` beside the buffer contents, and the paint arm says **SKIPPED with the reason** rather than passing quietly.

**Gate T0 passed on 2026-08-01** — all four unknowns hold: prompt-mark detection across fresh shells, resizes, `clear` and failing commands; the macOS text motions; `vim` in and out of the alternate screen; and the user's rc files byte-identical afterwards. `Sources/diffscope-t0` is the throwaway target that measured it, `swift run diffscope-t0` runs it, and `22-experiment-log.md` → **T0** carries the numbers. **DEC-053** records the terminal entering scope and what it costs the read-only sentence. **Next is T1** — PTY lifecycle and the output grid — in `26-terminal-plan.md` §5.

Three things from T0 that change the work rather than merely clearing it:

- **The macOS motions are not an AppKit property.** A `<textarea>` in a `WKWebView` performs all six identically to `NSTextView`, so T2's input line may live in the same webview as the grid. §4 of the plan assumed otherwise.
- **A shell costs ~340 ms and one `ssh-agent`.** The user's rc runs nvm, `compinit` and `ssh-agent -s`; 363 agents were already running when T0 measured. Spawning must stay off the interface's critical path.
- **Two harness defects, both false negatives about the thing being measured** — a caret seeded before the responder change, and a wait that matched the echo of a typed command rather than its output. Same family as `zsh -i -c` in the first probe. When a terminal measurement disagrees with expectation, suspect the driver first.


1. ~~**Definition of done §6**~~ — **done 2026-08-09**, DEC-057 and M8-J above.
2. ~~**OQ-046** auto-gc on large repositories~~ - **answered 2026-08-09**, M8-M: no. Measured on a repository with the thresholds brought down to it, and on the corpus's largest, which sits at **91% of git's default threshold** and did not move. Both obvious mitigations were forbidden - `gc.auto=0` is a write, `-c gc.auto=0` is in `forbiddenArguments` - so it had to be measured.
3. ~~F1, F3, F4 with no producer~~ — **done**: `parseErrorRegions` reports F1 with region and byte counts, and F3/F4 are recorded as region-level with a check that no ambiguity indicator reaches the contract (DEC-045 stays a decision rather than drift).
4. ~~**T-11 is proven on one relocation shape only.**~~ — **done 2026-08-09**, M8-L. Three shapes now: one statement, a multi-line block, and two independent moves in one file so that `link` pairs rather than counts. Constructing them failed a **fourth** time in the same family, and the generalisation is in M8-L: the shorter the relocated line, the more likely the canonical diff has already spent its bytes matching fragments elsewhere.
5. ~~The parser-state indicator and the three §2 items~~ — **done 2026-08-09**, DEC-058 and M8-K above. `23b-…` is closed.

**G3 passed** (M8-I). `Scripts/package.sh` builds an unsigned `DiffScope.app` with a drawn icon, and **proves independence rather than assuming it**: it copies the bundle to a temporary directory and runs the full selftest from `/`, so a build that quietly read from the checkout fails here rather than on the tester's machine. The privacy claims in the packet are checked against the source — no network API in any shipped file, no request in the renderer.

**R-9's guard was strengthened** (DEC-049 amendment, M8-H addendum). The stat bracket alone let **6 blended pins through in 20 reads under load** — a single large `write` stamps `mtime` once at its start, so both stats agree while the read lands mid-copy. The read is now bracketed **and** repeated, both must agree, and the two guards close each other's holes (content alone: 3 in 8,095; bracket alone: 6 in 20). Found because a check failed once and was measured instead of re-run.

**G2 passed** (M8-H), **and the contract was brought up to date with the terminal in M8-P.** It described a window with one webview in it: G2 passed on 2026-07-31 and the terminal's grid landed on 2026-08-01, and **nothing had ever read the document**. It is now checked against what the code emits — every `ds-` class, every element id in both webviews, every snapshot the selftest writes — with a negative control that renaming an entry fails the run. **Read `24-design-contract.md` before touching anything visual, and add to it in the same commit that adds a mark.**

 Every visual value lives in `Renderer/src/tokens.css`, mirrored for the AppKit chrome in `Theme.swift`. The rule *a design may restyle any mark and may never hide one* is enforced in two places — the source, and the **computed style of the live document** — because a stylesheet can be read and still be wrong about what the reader gets. Both have negative controls: the selftest injects `display: none` on a mark and requires the audit to catch it. Read `24-design-contract.md` before touching anything visual.

**`23b-spec-vs-app-audit.md` is closed** (§1 and §2 both, as of M8-K). Base-branch override (⇧⌘B, stored in the configuration), staleness in words beside scope 4, unavailable scopes disabled with their reason, refresh on window focus, a wrap toggle (⌥⌘W), and the empty-diff sentence all landed on 2026-07-31. The parser-state indicator (§1.10) and the three §2 items followed on 2026-08-09 under DEC-058.

**The file list groups** (DEC-033 amended). Measured first: 12 repositories contain a `pnpm-workspace.yaml` and **none declares `packages:`**, so the specified per-package grouping would have put one meaningless header above every list. Groups are declared packages where they exist and parent directories otherwise; headers are suppressed when grouping buys nothing; grouped rows show the path relative to their group. Per-file badges (`raw`, `bin`, `big`) come from the extension, a `stat` and a 4 KB probe — **the list says only what is cheap to know**, and anything needing a full read stays in the diff view.

**The gutter landed** (M8-E): line numbers in both panes, a mark on every line carrying a difference, `changedLines` computed in the engine and carried on the contract, and ⌘O opening at the line the reader is on rather than at a literal 1.

**Root management landed** (DEC-052, M8-D): configuration is a JSON file the user can read, any number of roots plus individual repositories, an empty-state picker with no suggested path, missing sources named rather than dropped. **The `~/WebstormProjects` default is gone.**

**Read M8-D before touching the AppKit shell.** Both lists had been rendering **completely blank rows** — panes at zero width because `NSSplitView` preserves the proportions of frames that all started at zero, and cell views never sized because a bare `NSTextField` was returned from `viewFor`. Nothing failed: no crash, no exception, and the status line was correct throughout. Every earlier instance of this defect class in the project was *a check that was never run*; this one is **a surface that was never looked at**, and the selftest snapshots photograph the webview only, so nothing would catch it going blank again.

**A spec-versus-application audit exists** (`23b-spec-vs-app-audit.md`, 2026-07-29). Ten accepted requirements are written down and not built, all of them in the shell rather than the engine — root management with its picker (DEC-036/037, which **blocks G3** and leaves the WebStorm-specific default the project decided against), the gutter and line numbers, file-list grouping and per-file degradation state, base-branch override, scope-4 staleness wording, scope disabling, focus refresh, the wrap toggle, and the empty-diff sentence. Suggested order is in §6 of that document.

**Then the three handover gates** (`23-release-gates.md`, added 2026-07-29 at the product owner's request). These are not M-series milestones: each ends when a *person* can do something they could not before, which is a different acceptance test from "the checks pass".

| Gate | Ends when | Announced as |
|---|---|---|
| **G1 POC** | the owner has reviewed a real change in their own repositories, and has a written gaps list | **POC READY** — `23a-poc-report.md` written 2026-07-29; awaiting the owner's session |
| ~~**G2 design intake**~~ | **PASSED 2026-07-31.** `Renderer/src/tokens.css` is the file; `24-design-contract.md` is the contract | **DESIGN INTAKE READY** |
| ~~**G3 tester build**~~ | **PASSED 2026-07-31.** `Scripts/package.sh` → `dist/DiffScope-<rev>.zip`; packet in `25-tester-packet.md` | **TESTER BUILD READY** |

Order is G1 → G2 → G3 and the reasoning is in that document. **No gate may be announced from checks alone** — each requires running the application and looking at what it drew, which is the lesson M6-D paid for.

**Ambiguity display was withdrawn by DEC-045** — detection stays as a guard against ambiguous anchors, but no indicator is built.

~~**One check is wall-clock and therefore load-sensitive.**~~ **Fixed 2026-08-09 (M8-N).** Two checks in `BudgetChecks` asserted an absolute 2.0 s, and under load the refusal measured 2.3 s and failed while the code did exactly the right thing. Both now measure a **baseline on this machine, in this build, under whatever load is present** and assert a ratio against it: the dense-JSX run against the cost of one parse, the oversize refusal against the cost of one pass over the same bytes. Load inflates both numbers, so the ratio holds — verified by running the whole suite with eight CPU spinners saturating the machine: **1188/1188, both checks passing.** The ratio is also the better statement of the claim: *refused without parsing it* means "costs about what looking at the bytes costs", not "costs under a second".

Known weaknesses recorded rather than hidden: **a relocated line whose leading bytes align with a neighbour's identical prefix, or which shares punctuation with the line replacing it, is not detected as a move** (measured in M8-C, generalised in M8-L — widening the search would put bytes the canonical diff calls unchanged inside a `moved` range, which is a reopening of DEC-038, not an implementation detail); anchor selection is greedy by old-side position rather than a longest-increasing-subsequence; moved-and-modified content presents as delete plus add (accepted in DEC-038); a reformat that changes line counts is never grouped (DEC-048, the conservative direction); files over 2000 anchored lines are strided, so a refresh lands the reader within a few lines rather than exactly.

**Two things measurement changed in M7 that reasoning had settled the other way.** DEC-034 says "the nearest segment labeled unchanged" — implemented literally, it gives Raw *zero* anchors, because Raw is one fallback segment over the whole file. And per-side formatting runs find nothing for the ordinary reindent, because a reindent is an insertion and the old side has no changed bytes. Both now derive from the canonical diff instead. If you are about to build something on "the unchanged segments", check what Raw actually contains first.

**When adding a field to `Segment`, grep for every place that rebuilds one.** `snapPresentation` merges neighbouring segments and silently dropped the move `link`, so a verified move reached the renderer unpaired while every harness check passed. The application selftest caught it — see M6-D.

The native window layout **has** now been looked at — repository list, file list, scope and mode controls, and the founding case rendering with children preserved. Everything below that in the interface (gutter, navigation, collapsed ranges) is still absent rather than unverified.

---

## 1. What this is

A macOS desktop application for reviewing diffs in local Git repositories. It aligns edits **structurally** rather than line-by-line, so a removed JSX wrapper reads as a wrapper change with its children preserved, instead of a large deletion followed by a nearly identical insertion.

It is not a website, not a Git client, not an AI review tool, and not a semantic diff. It never decides a change is unimportant.

## 2. The core invariant — the thing you must not break

> Structural analysis may change how edits are aligned, grouped, labeled, and presented. It must never suppress or discard any textual difference. The exact source text is the source of truth.

Formally (DEC-021, specified in `14-losslessness-and-trust-model.md`):

- **INV-1** both sides reconstruct byte-for-byte from the model
- **INV-2** every byte of the canonical diff's hunks lies **within** a presented range (containment, not intersection)
- **INV-3** "no changes" shown **iff** the sides are byte-equal
- **INV-4** every fallback is marked as a fallback
- **INV-5** Structural and Expanded produce identical segment sets

Comparison is on **bytes**. **Normalisation is never applied anywhere**, including inside the structural layer. This was settled by measurement: the corpus contains `'ŻABKA'` where `Ż` is `U+005A U+0307`, canonically equivalent to `U+017B` and **rendering identically**. Normalised comparison reports no difference for a real byte change.

## 3. Architecture (DEC-042)

**Swift shell and engine · tree-sitter via C API · CodeMirror 6 in `WKWebView` · Git CLI.**

| Layer | Choice | Why |
|---|---|---|
| Engine host | Swift | Byte-native tree-sitter offsets; every Node binding reports UTF-16 while typing it as bytes |
| Model | Total ordered **byte partition** | Makes INV-1 and INV-2 hold by construction |
| Renderer | CodeMirror 6 | Measured; 667 KB vs Monaco's 9.3 MB; neither offers external-diff APIs anyway |
| Git | CLI, `--no-optional-locks` always | Plain `git status` rewrites the index when the stat cache is stale |
| Matcher | From publications, node mapping only | Edit scripts cannot project onto a byte partition without reviving the move-swallows-delta bug |

## 4. Accepted scope

`18-version-one-scope.md` is authoritative. Headlines: macOS only; the application's own Git usage strictly read-only, with a built-in terminal the user drives (DEC-053); never fetches; four comparison scopes; TS/TSX/JS/JSX structural, everything else raw and labelled; side-by-side only; three modes over two code paths; byte-identical moves only; multiple user-chosen roots with no default path.

## 5. Important rejected alternatives, and why

| Rejected | Reason |
|---|---|
| Normalising before comparison | Hides real byte changes — measured in this corpus |
| Edit scripts from the matcher | Cannot project onto a byte partition without losing move deltas |
| difftastic as an engine | Binary-only crate, no `src/lib.rs`; its JSON cannot reconstruct either file |
| GumTree source | LGPL-3.0 — implement from papers instead |
| libgit2 | CLI faster (46 ms vs 264 ms), healthier bindings, simpler licence, and Raw mode must match `git diff` by definition |
| oxc parser | Returns an **empty program** for 94.77% of truncated TSX while appearing to succeed |
| Babel parser | Throws on 91.67% of truncations; `errorRecovery` does not cover that error class |
| Executing repo-configured filters | Repository content would decide what executes — an RCE surface |
| Full-web architecture | Would require a permanent UTF-16→byte conversion surface whose failure mode is silent |
| Hiding clean repositories | A clean repository can be commits ahead of base |
| Default `~/WebstormProjects` path | WebStorm-specific; nothing in the product depends on WebStorm |

## 6. Questions that must not be silently re-decided

Each has a recorded rationale. Reopen explicitly against its revisit trigger, or not at all.

1. **Normalisation** — never, anywhere. Not reopenable; disqualified by measurement.
2. **Read-only for the application itself** — no writes, no fetch, no exceptions, `--no-optional-locks` everywhere. Amended once, deliberately: DEC-053 admits a terminal the *user* drives. The application still writes nothing on its own, and the one command it composes is `cd` under DEC-056's guard. Do not let these two collapse into each other in any document.
3. **Byte partition as primitive** — the invariants depend on it structurally.
4. **Matcher output as mapping, not script.**
5. **Formatting-only is a label, never a filter.**
6. **Raw mode always available**, on the same pinned pair.
7. **Ambiguity surfaced, never resolved arbitrarily.**
8. **No executing repository-defined commands.**
9. **No network, no telemetry, no runtime AI.**
10. **No editor-specific defaults** — the root-path lesson generalises.

## 7. Known risks

| Risk | Status |
|---|---|
| ~~`tree-sitter-typescript` #306~~ | **Resolved in M0-1.** Mischaracterised in planning: it is "JSX captures whitespaces in nested, multiline tags", not a range defect. Grammar remains stale (last release 2024-11-11) — a generic maintenance risk |
| ~~Engine↔renderer serialisation cost~~ | **Cleared in M0-2** — 5149 segments cross in 1.13 ms. Do not "optimise" with a smaller binary encoding; measured 6.5× slower |
| Byte↔UTF-16 conversion in the webview | The one place X-1's hazard survives. One function, independently tested |
| Matcher cost on dense JSX | The performance risk everywhere. Budget on **node count**, not bytes |
| tree-sitter error recovery | ~38.4% of bytes outside `ERROR` on truncated files — a quality ceiling, accepted |
| ~~Auto-gc on large repositories~~ | **Cleared in M8-M.** No registered operation triggers maintenance, measured where it would fire; a permanent check now holds it |

## 8. Required experiments before implementation

M0 in `19-roadmap.md`: verify #306, measure serialisation, assess Swift binding health. **M0 can invalidate DEC-042** — that is why it is first.

## 9. Testing expectations

- Invariant tests apply to **every** fixture automatically; no per-case expectation file.
- T-1 and T-3 implemented **independently of the partition code**. X-1 found a defect that passes T-0 and T-1 and fails only T-3.
- R-8, the read-only proof, is a **snapshot** of `.git` before and after every Git operation. New Git call without a proof fails CI.
- Fixture bytes verified against recorded hashes — editors silently repair CRLF and NFD.
- Several fixtures cannot occur locally and must be constructed deliberately (`20-implementation-plan.md` §6).

## 10. File map

| Document | Role |
|---|---|
| `00-index.md` | Status, authority, reading order |
| `glossary.md` | **Terminology — read before the rest** |
| `04-decision-log.md` | **Authoritative for all decisions** (DEC-001 … 042) |
| `05-open-questions.md` | What is undecided (OQ-001 … 056). **Audited 2026-08-11** — its header table is the short answer: eight genuinely open, five part-answered |
| `09-recommended-architecture.md` | The chosen architecture |
| `10-diff-engine-specification.md` | Engine behaviour |
| `11-git-behavior-specification.md` | Git interaction |
| `12-desktop-ux-specification.md` | Interface behaviour |
| `13-error-and-fallback-model.md` | Failure behaviour |
| `14-losslessness-and-trust-model.md` | **The invariant** |
| `15-test-corpus-plan.md` | Fixtures and invariant tests |
| `16-performance-and-scaling.md` | Budgets — estimates marked as such |
| `17-security-privacy-and-licensing.md` | Threat model, licences |
| `18-version-one-scope.md` | In, deferred, rejected |
| `19-roadmap.md` | Milestones M0 … M8 |
| `20-implementation-plan.md` | How to start |
| `22-experiment-log.md` | Spike results with methods |
| `23-release-gates.md` | **The three handover gates** — POC, design intake, tester build |
| `24-design-contract.md` | **What a design may change, and the two rules it may not break** |
| `25-tester-packet.md` | **Hand to a third-party tester with the zip. Nothing else needed** |
| `26-terminal-plan.md` | **The terminal: what was measured, what it costs, and gate T0** |
| `26-coverage-audit.md` | Where each T- and R- test is proven, and what could fail it |
| `research/` | Raw research with citations |

## 11. Milestone order

M0 verification gates → M1 engine skeleton and invariant harness → M2 Git layer → M3 raw diff end to end → M4 parsing and partition → M5 matching → M6 classification and trust surface → M7 refresh and navigation → M8 hardening.

**M3 is the first milestone with visible output.** M1 and M2 produce no interface. This is intentional: the trust machinery precedes what it protects, because retrofitting it means re-deriving every result already produced.

## 12. Definition of done

`18-version-one-scope.md` §"Definition of done". In short: every P0 fixture passes T-0…T-11; R-8 covers every Git operation; wrapper removal reads correctly; prop reordering never reports "no change"; parser failure degrades visibly; a 63-file working tree is reviewable from the keyboard (met and measured in M8-J); the application is demonstrably incapable of modifying a repository on any path of its own, the terminal being the user's (DEC-053).

## 13. Keeping this synchronised

**§0 of this document is the entry point and must be updated at every milestone boundary** — last milestone, check count, what the next milestone should do, and any new known weakness. If §0 is stale, a fresh agent starts from a false picture, which is worse than starting from none.

A decision changed in code but not in `04-decision-log.md` is a **defect**. New decisions get the full format including rejected options and a revisit trigger. Measurements go in `22-experiment-log.md` with method. When research invalidates a decision, reopen it explicitly rather than working around it.

## 14. One habit worth copying

Several findings in this planning set **contradicted the reasoning that preceded them** — `.git` size does not predict status cost; libgit2 handles built-in CRLF correctly; `carrefour-inapp` is unborn-HEAD, not detached; a rendering measurement was void because `scrollTop` silently stayed 0.

Each was found by checking rather than assuming, and each is recorded **with the correction visible** rather than quietly edited out. Keep doing that. The corrections are more useful to you than the conclusions.
