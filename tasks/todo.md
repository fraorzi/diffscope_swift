# M6 — classification and trust surface

Chosen over boundary tie-breaking: nothing structural is visible in the application yet
(`diffscope-app` still calls `trivialModel`), so segment-boundary polish would refine
output no human can look at. Classification and the app wiring are the two M6 items that
turn the measured structural layer into something reviewable — and boundary tie-breaking
becomes testable *against real files on screen* afterwards.

## Step 1 — classification pass (spec §3.8, DEC-017 mandatory grouping)

- [x] `ChangeClass` vocabulary + group mapping in `DiffScopeEngine`
- [x] Byte-level detectors in `DiffScopeSyntax` (whitespace, quote-style, trailing-comma, paren-only, reordering)
- [x] Attach classification to changed gap pairs in `structuralDiff`; drop the diagnostic
      strings (`anchor`, `filler`, `refined`, `moved-content`)
- [x] Carry `group` across the render contract
- [x] Renderer: formatting-only texture + disclosed count chip — grouping, never a filter
- [x] Verify checks, including the false-positive guard (a real edit must not read as formatting-only)
- [x] Corpus measurement → `22-experiment-log.md` M6-A

## Step 2 — wire the structural model into the application

- [x] `diffscope-app` calls `structuralDiff` for TS/TSX/JS/JSX, raw otherwise
- [x] Mode control: Raw · Structural · Expanded (DEC-013), presentation flags over one renderer
- [x] Invariant failure falls back to raw and says so (INV-4)
- [x] INV-5 check: Structural and Expanded produce identical segment sets

## Step 3 — boundary snapping

- [x] `SyntaxBoundaries` over named nodes; outward snap with a byte budget
- [x] Applied as a presentation pass after labelling, never to the mask `reconcile` reads
- [x] Budget chosen by measurement → `22-experiment-log.md` M6-B, `boundarySnapBudget = 16`
- [x] Negative control in the suite: budget 0 must leave the change starting mid-identifier
- [x] DEC-047, including why sliding is not implementable under INV-2 as recorded

## Step 4 — trust surface: disclosure and confidence

- [x] `invisibleDifference` detector: normalization form, invisible controls, whitespace lookalikes
- [x] Disclosure as a second axis beside classification (the axes cross)
- [x] `confidenceFloor` in the engine; contract carries a computed `uncertain` flag
- [x] Renderer: dotted outline, dashed underline for uncertain, one badge per run, codepoints in Expanded
- [x] Corpus prevalence + the Swift `String ==` defect → `22-experiment-log.md` M6-C

## Step 5 — deliberate move search (DEC-038)

- [x] Line-matched byte-identical search over reconciled changed content
- [x] `MoveRecord` holds one range per line; both sides share a `link`
- [x] Reconciliation no longer invents `moved` labels it cannot verify
- [x] Rejection floor counted, not silent (`movesBelowFloor`)
- [x] Corpus + false-positive control → `22-experiment-log.md` M6-D
- [x] Application selftest renders a relocation and checks the pairing survives

## Review

### Step 1 — done

Classification is computed on the aligned gap pair *before* reconciliation, which is the
only place both sides of a change are known to correspond. Reconciliation then splits
those segments against the canonical mask and carries the label into each piece.

Detectors are cumulative-normaliser equality tests, first match wins. A false
`formatting-only` is a trust defect, so the suite asserts the negative case (`1` → `2`,
`===` → `==`, identifier rename) as well as the positive ones.

Anchor identity moved out of the `classification` string into an explicit
`anchorStarts` set passed to `reconcile` — the diagnostic string was load-bearing.
*(Step 5 then removed that path entirely: the label it fed could not be verified.)*

### Step 2 — done

`diffscope-app` runs the structural path for TS/TSX/JS/JSX and raw for everything else,
falls back to raw on invariant failure with the reason shown, and exposes Raw ·
Structural · Expanded as presentation flags over one model. INV-5 is enforced by
construction (both modes render the same `RenderModel` payload) and checked.

### Step 3 — done, but narrower than the name suggests

The plan said "tie-breaking". What is implemented is **snapping**, and the difference
matters: tie-breaking picks a different equally-minimal alignment, which moves bytes out
of the presented set and fails INV-2 as recorded. Snapping only widens, so containment
survives by construction. 34.3% → 97.0% of boundaries land on syntax, for +4.4% bytes.

Two ordering traps found by measuring rather than reasoning: snapping before `reconcile`
manufactures `moved` claims from a presentation setting, and snapping without inheriting
the run's classification dropped M6-A's recall from 97.8% to 40.9%.

### Step 4 — done, and it found a defect in itself

The detector for "normalisation hides real byte changes" was itself written on an idiom
that normalises: Swift's `String ==` is canonical equivalence, so `nfc(text) != text` is
always false. Fixtures passed; the corpus scan reported 0 decomposed files in a tree that
contains 28. Every comparison now goes through scalar arrays.

Confidence threshold lives in the engine, not the renderer — a renderer that owns the
threshold can quietly stop showing uncertainty.

### Step 5 — done, after two redesigns

Whole-run matching fired on 11 of 120 corpus files: anchors survive inside a moved block,
so the two sides split into runs differently. Line matching, extended while both sides
continue, gives 120 of 120 with zero false moves.

A block move is one record with one range *per line*, because the ranges must be byte-equal
and the whitespace between moved lines need not be.

`snapPresentation` merged neighbouring segments without comparing `link` and rebuilt them
without it, so a verified move reached the renderer unpaired while every harness check
passed. Caught by the application selftest, which asks the rendered document instead of
the model.

## Step 6 — M7 part one: navigation, folding, keyboard

- [x] `changeStops` from the canonical diff; `collapseRanges` between them
- [x] A fold is offered only where both sides are byte-equal, on line boundaries, with context
- [x] Both carried on the render contract in UTF-16 → checkable headlessly
- [x] Renderer: block fold widget with a disclosed count, click or ⌘E to expand; paired jumps
- [x] Menu-bar keyboard map covering every function DEC-016 lists
- [x] Editor integration with a `{file}`/`{line}` template, failure shown not swallowed
- [x] Application selftest renders folds and jumps → `navigation.png`

### Step 6 — done

Navigation walks the canonical hunks rather than the presented segments: presented ranges are
supersets after snapping, and navigating the superset drifts from the alignment INV-2 is
stated against. Every stop still lands inside a presented range — asserted, not assumed.

Folding is the only act that hides content, so the engine refuses to offer a fold unless the
old and new bytes in it are equal. That also makes the fold well-defined on both panes, which
is what keeps them aligned while folded.

## Step 7 — M7 part two: watching and debounce (DEC-026, DEC-027, F15)

- [x] `RefreshDebounce` with an injected clock: trailing edge, max-delay cap
- [x] `RepositoryWatcher` — one stream on the open repository, `FileEvents | NoDefer | WatchRoot`,
      latency 0.0, `node_modules` excluded, exclusion overflow reported not truncated silently
- [x] Drop and root-changed arms behind `deliver(flags:)` so F15 can be forced
- [x] Application wiring: watcher per selected repository, selection preserved across refresh
- [x] Checks: debounce shape, forced drop, a real file write reaching the application

## Step 8 — R-9: no blended pin (DEC-049)

- [x] Worktree reads bracketed by a `stat`, five attempts, 20 ms apart
- [x] `PinnedSourcePair.stable`; the application refuses to render an unsettled pair
- [x] Racing check against a writer rewriting in place, hostile and realistic

## Step 9 — scroll anchoring (DEC-034)

- [x] `RefreshAnchor` from the canonical diff's matched blocks, one per line, 3-line hash identity
- [x] `resolveAnchor` implementing the fallback chain literally, with the reason carried
- [x] Contract carries `anchors` and `restore` in UTF-16; renderer reports and executes, never decides
- [x] Drift check: twenty refreshes, one position

## Step 10 — formatting-only collapse (DEC-048)

- [x] `formattingCollapses` driven by canonical hunks, merged across ≤2-line gaps
- [x] Offered only where both sides span the same number of lines; rejections counted
- [x] Whole-line guard: a real edit on a grouped line disqualifies the group
- [x] Empty in Expanded; INV-5 unaffected
- [x] Renderer group widget sharing the fold expansion path
- [x] Application selftest → `refresh.png`, `anchored.png`

### Steps 7–10 — done, after two measurements contradicted the plan

**R-9 was fixed twice.** The obvious guard — read the worktree file twice, require the reads to
agree — let 3 blends through in 8,095 reads against a writer rewriting in place. Comparing content
asks whether two reads matched, not whether anything wrote between them. The read is now bracketed
by a `stat`; a pair that will not settle is not rendered at all, because a blend shown with a
warning is still a blend.

**DEC-034 could not be implemented as written.** "The nearest segment labeled unchanged" gives Raw
zero anchors — Raw is one `fallback` segment over the whole file — so every Raw refresh would have
jumped to the top, silently. Anchors come from the canonical diff's matched blocks instead, which
is where `changeStops` already gets its stops. Block-granular anchors then failed the ordinary
case, because a block spanning everything above the reader changes whenever anything above them is
edited; identity has to be local, so it is one anchor per line over a 3-line window.

**A reindent has no old side.** Formatting runs computed per side found nothing on the corpus case,
because reindentation is an insertion. Grouping is driven by hunks, which are stated on both sides,
and the pairing condition is equal line counts — the argument byte-equality makes for ordinary
folds, applied to content that is allowed to differ.

330/330 checks pass. The application selftest renders the group and the restored anchor across the
webview, since the harness cannot see either.

## Step 11 — M8 slice one: the budgets that were still estimates (DEC-050)

- [x] `--budget-survey` measuring nodes, parse time, match time and counted work over real files
- [x] Synthetic dense-JSX and minified ladders to extend the curve past the corpus
- [x] `MatchBudget` inside `matchTrees`, charged where the superlinearity is
- [x] Three gates in `structuralDiff`: 2 MB, 30,000 nodes, 10M comparisons — each raw with a reason
- [x] A partial mapping is discarded, never used
- [x] `fallbackNotice` / `discardedNotice`: what was withheld, why, what remains trustworthy
- [x] Checks: pathological input returns, negative control stays structural, giving up is deterministic
- [x] DEC-050, M8-A, and `16-performance-and-scaling.md` §3 with the estimates kept beside the results

### Step 11 — done

The structural path had **no budget of any kind** before this: no size limit, no node limit, no
deadline. A 900 KB build chunk took ~2 s to match and a 31 MB vendor bundle took ~3 s including
parsing, on the main path, while the reader waited.

Two things the planning estimates had wrong, both found by measuring rather than reasoning.
Matching cost is roughly **quadratic** in node count, not linear — doubling nodes quadruples the
cost in both shapes tested. And the budget cannot be a wall-clock deadline: that makes the diff
depend on machine load, so the same file would diff structurally on an idle machine and fall back
on a busy one, which T-7 forbids because giving up is part of the output. Counted work tracks time
at ~40,000 units per millisecond across three orders of magnitude, so a counted budget buys the
time bound without buying the nondeterminism.

The number worth keeping is what sits **nearest the gate**: all eight are `.next` build output. A
budget is only a budget if it rejects the right things, and that is the line that says so.

345/345 checks pass.

## Step 12 — M8 slice two: degradation precedence, F8, F13 (DEC-051)

- [x] `Degradation` in the engine: F-code, rank transcribing `13-…` §5, `mostConservative`
- [x] `classify` gathers every condition that holds; `structuralDiff` takes an `external:` seam
- [x] F16 added to the taxonomy — §2 predates DEC-050's budgets and a row is needed to hold a rank
- [x] `FilterCheck` over `check-attr -z filter text eol`, registered so R-8 covers it
- [x] Disclosure explains the *discrepancy* (DEC-041), and applies to byte-equal sides too
- [x] `cat-file --textconv` removed; `forbiddenArguments` guards its return
- [x] `EditorCommand` + `launchEditor`: both F13 arms, template tokenised before filling
- [x] Forced fixtures: `eol-filter-active`, unverified by dissimilarity, broken editor, precedence table
- [x] Selftest arm + `degraded.png` — the harness ranks, only the webview shows
- [x] DEC-051, M8-B, `13-…` §2/§3/§5, handoff §0

### Step 12 — done, and three of the findings were not in the plan

**The eol fixture built the obvious way reproduces nothing.** Attribute, commit, rewrite worktree → clean, zero diff lines. Six configurations were measured to find the one that produces DEC-041's state: the blob has to be committed **before** the attribute exists, so the attribute describes a worktree form the object database does not hold. The result is that git's own two tools disagree and our compared pair differs from both — which is why the disclosure has to explain the discrepancy rather than name the filter.

**F13's fixture found a defect that has nothing to do with F13.** The editor template was substituted and *then* split on spaces, so `~/My Projects/a.ts` became three arguments. Nobody had reported it because no corpus path contains a space. Tokenise first, fill after: the template decides what the arguments are, the path only decides their contents.

**The snapshot writer reported success it had not achieved** — `try? png.write` printed the path whether or not the directory existed. Same shape as `runBundleFreshnessCheck`: a failure path written and never exercised.

Four of seven multi-condition inputs changed which reason they report. Every one of them ended in raw before and after; what changed is the sentence, which under INV-4 is the part being promised.

380/380 checks pass.

## Step 13 — three handover gates added to the plan (not yet executed)

Requested by the product owner: milestones after which the application is handed to
*somebody*, rather than milestones after which a measurement holds. Written to
`docs/23-release-gates.md`, referenced from the roadmap, handoff §0 and the index.

- [x] **G1 POC** — walkthrough on the owner's real repositories, no new features, gaps list
      written to `23a-poc-report.md`. Signal: **POC READY**.
- [x] **G2 design intake** — one token file, mirrored AppKit constants, `24-design-contract.md`
      naming every emitted class, and checks that a `ds-` class carrying a difference can be
      restyled but never hidden. Signal: **DESIGN INTAKE READY**.
- [x] **G3 tester build** — `Scripts/package.sh` → unsigned `DiffScope.app` in a zip with a
      checksum, proven to run with the source tree moved away, plus `25-tester-packet.md`.
      Signal: **TESTER BUILD READY**.

Order G1 → G2 → G3: the gaps list feeds every later decision, a design applied before the
app has been used is a design for an imagined product, and a stranger's first impression is
the one thing that cannot be asked for twice.

**The rule attached to all three:** no gate is announced from checks alone. Each requires
running the application and looking at what it drew — M6-D is the precedent, where a verified
move reached the renderer unpaired while every harness check passed.

Boxes above mark the gates as *planned and specified*. None has been executed.

## Step 14 — M8 slice three: the T-0…T-11 coverage audit (M8-C)

- [x] `MANIFEST.json` read by a check: hash, length, missing entry, deleted fixture; `--write-manifest` regenerates deliberately and is idempotent
- [x] `FixtureChecks.swift` — every fixture through raw **and** structural, T-series asserted by number
- [x] T-8, T-9, T-10, T-11 given checks by those names, each with an input that can fail it
- [x] `snapToGraphemeBoundaries` — the missing implementation of `14-…` §4
- [x] Corpus 9 → 32 fixtures across the degenerate, Unicode, formatting, movement and token groups
- [x] Per-fixture structural statistics printed, since a check that never fires is invisible
- [x] `26-coverage-audit.md`, M8-C, handoff §0, index, `15-…` §6.5

### Step 14 — done, and the audit paid for itself three times

**Nothing had ever checked a fixture on the structural path.** The loop built `trivialModel` — the
whole-file fallback — so the founding case of the product, `jsx-wrapper-removal`, had been passing
invariant checks against a partition with one segment in it.

**T-10 was a documented requirement with no implementation.** `14-…` §4 mandates outward
grapheme-cluster snapping; nothing did it, so an emoji-ZWJ insertion cut a cluster in half.

**Building a move fixture failed twice**, and both failures are recorded in M8-C rather than
worked around: swapping two similar functions is a rename at byte level, not a move; and a
relocated line sharing a prefix with its neighbour is not detected, because the line-based search
needs the whole line inside changed content. The second is a real limitation of DEC-038 as
implemented, and fixing it is a decision about what a move *is* — not something to slip into a
test-coverage slice.

Two of my own checks were written too narrowly and failed correct behaviour: an unrenderable file
marks its fallback whole rather than per segment, and a pure deletion has no changed bytes on the
new side. Both corrections are in M8-C.

855/855 checks pass over 32 fixtures.

## Step 15 — root management (DEC-052, audit §1.1)

- [x] `Configuration` + `ConfigurationStore`: JSON, injectable path, `DIFFSCOPE_CONFIG` override
- [x] Missing file is first run; a corrupt file is reported and left on disk untouched
- [x] Sources inspected, not filtered — a moved root is reported missing
- [x] Discovery over every configured source; depth per root; individual repos bypass scanning
- [x] Colliding repository names qualified by the shortest parent that separates them
- [x] Empty state with a picker, no suggested path, no auto-detection; replaces the split rather than overlaying it
- [x] Sources menu: add root, add repository, remove source
- [x] `~/WebstormProjects` default removed; `DIFFSCOPE_ROOT` demoted to a testing hook
- [x] Checks: round trip, corrupt preserved, per-root depth, individual repo, collisions, missing source
- [x] DEC-052, M8-D, audit §1.1 closed, handoff, POC report

### Step 15 — done, and the window had never been looked at

The feature itself went in as planned. What it exposed did not: **both lists had been rendering
completely blank rows**, in a window that otherwise looked healthy — correct title, correct
controls, and a status line reading `23 repositories from 2 sources · swept in 512 ms`.

Two causes. `NSSplitView` distributes space by preserving the proportions of the frames its panes
already have, and all three started at zero, so all three stayed at zero; setting divider positions
on the next run-loop pass looks like it fixes that and does not, because the split's own frame is
still zero until layout runs. And a bare `NSTextField` returned from `viewFor` was never sized, so a
middle-truncating label truncated the entire string away.

Every previous instance of this defect class in the project was a **check that was never run**. This
one is a **surface that was never looked at** — the selftest snapshots photograph the webview only,
so nothing in the suite would notice the shell going blank. Fixed with width constraints at priority
600 inside the split and an `NSTableCellView` with the label constrained to its edges; verified by
screenshotting the window, which is the only thing that could have verified it.

872/872 checks pass.

## Step 16 — the gutter and line numbers (audit §1.6)

- [x] `changedLines` computed in the engine, carried per side on the contract
- [x] Counted on bytes, splitting on 0x0A only, so a `\r` belongs to the line it terminates
- [x] `lineNumbers()` in both panes; `gutterLineClass` marking changed lines by shape, not colour
- [x] `diffscopeCurrentLine()` — active change stop, else first visible line, in the new side's numbering
- [x] ⌘O substitutes it into `{line}` instead of a literal 1
- [x] Checks: single-line, spanning, ending on a newline, last line, empty segment, CRLF, INV-5
- [x] Selftest arm + `gutter.png`

### Step 16 — done

The two off-by-ones worth naming are both checked: a segment ending exactly on a newline must not
claim the next line, and a `\r` belongs to the line it terminates rather than the one after.

The snapshot showed something the checks could not: on `7` → `77` only the **new** pane is marked,
because an insertion has no old-side bytes to attribute. Correct, and the same shape as DEC-048's
finding that a reindent has no old side.

Still open, and now recorded in the POC report rather than discovered by the reader: the default
`open -a WebStorm {file}` template has no `{line}`, so the default cannot jump even though the line
is now known.

884/884 checks pass.

## Step 17 — the grouped file list (audit §1.5, DEC-033 amended)

- [x] Measured first: 12 repositories with `pnpm-workspace.yaml`, **zero** declaring `packages:`
- [x] Groups: declared workspace package, else parent directory
- [x] Headers suppressed when grouping buys nothing (one group, or one group per file)
- [x] Headers are labels — ⌘] / ⌘[ step past them
- [x] Grouped rows show the path relative to their group; full path on hover
- [x] Per-file badges `raw` / `bin` / `big` from extension, `stat` and a 4 KB probe
- [x] Selection restore after refresh indexes the drawn rows, not the flat file array
- [x] Checks incl. the real philips shape, the corpus's actual pnpm file, and the annotation rules
- [x] DEC-033 amendment, M8-F, audit §1.5 closed, handoff

### Step 17 — done, after the corpus contradicted the decision

The specified grouping would have produced one meaningless header per repository, because no
repository here declares workspace packages. Measured before writing any of it, amended in the
decision log rather than worked around in code.

The first correct version was still unreadable: every row repeated the directory its header had
just stated. Relative display fixed it — visible only by looking at the window, not from the checks,
which passed either way.

903/903 checks pass.

## Step 18 — the rest of the interface audit (23b §1.2–1.9)

- [x] §1.2 base-branch override, ⇧⌘B, stored in configuration, never in the repository
- [x] §1.3 staleness in words beside scope 4, via a checked function
- [x] §1.4 unavailable scopes disabled, reason in the tooltip
- [x] §1.7 empty-diff sentence, and "no changes" only when byte-equal
- [x] §1.8 refresh on window focus (DEC-006)
- [x] §1.9 wrap toggle, ⌥⌘W, default on
- [x] Configuration decodes files written before `baseOverrides` existed
- [x] Auto-selection moved after the sweep summary so a scope reason is not overwritten

### Step 18 — done

The specification's own example caught a boundary: 63 days is "9 weeks old" in `12-…` §3, and the
obvious banding renders it "2 months old". Only assertable because the line was extracted out of the
view into a function.

The pluraliser was caught by reading the rendered notice, not by a check — "in 1 groups".

§1.10 (parser-state indicator) is the only §1 item left, deliberately after the design gate.

921/921 checks pass.

## Step 19 — gate G2: design intake

- [x] `Renderer/src/tokens.css` holds every colour, font, size, spacing, radius and border
- [x] `index.html` declares none of its own; the build copies tokens into the app bundle
- [x] `Theme.swift` mirrors the token names for the AppKit chrome
- [x] Source checks: no literals outside tokens, no dangling `var()`, no unused token,
      no hidden load-bearing class, no colour-only mark, notice bar intact
- [x] Live-document audit via computed style, run by the application selftest
- [x] Negative controls for both: an injected `display: none`, and a hostile stylesheet
- [x] `24-design-contract.md` — every emitted class, what is load-bearing, the paste-in procedure
- [x] Snapshot set regenerated and compared; rendering unchanged

### Step 19 — done

The gate is not the token file, it is the two checks around it. The engine cannot see the screen, so
a stylesheet is the one way to make this product lie while everything stays green — which is exactly
what a design is.

Both checks have negative controls, because a check that has only ever seen a passing input proves
nothing. The selftest hides a mark on purpose and requires the audit to notice.

**DESIGN INTAKE READY** — paste into `Renderer/src/tokens.css`.

943/943 checks pass.

## Step 20 — gate G3: tester build

- [x] `Scripts/package.sh`: release build, Info.plist, drawn icon, resource bundle in both lookup
      locations, zip with a recorded SHA-256
- [x] The script **proves** the bundle runs from a temporary directory with cwd `/`
- [x] A folder with no repositories explains itself instead of showing three empty panes
- [x] `25-tester-packet.md` — install, Gatekeeper, what to try, known missing, how to report, privacy
- [x] The privacy claims checked against the source, not just written
- [x] The packet's load-bearing sentences checked: the settings file, "keep the file", right-click ▸ Open

### Step 20 — done

**TESTER BUILD READY.** `dist/DiffScope-<rev>.zip` plus `docs/25-tester-packet.md`.

The gate is the proof, not the zip: a bundle reading from the checkout works on the machine that
built it and nowhere else, so the script copies it away and runs the whole selftest from `/` before
it will produce an archive.

958/958 checks pass.

## Step 21 — F1, F3 and F4: the ranked rows with no producer

- [x] `parseErrorRegions` over top-most `ERROR`/missing nodes
- [x] F1 reported with region and byte counts; the structural result still stands (`usedFallback` false)
- [x] Changed bytes inside an unparsed region relabelled `fallback` with `parse-error`
- [x] Unchanged bytes inside the same region keep their label — comparison never needed the parser
- [x] Negative control: a clean file reports nothing; a more conservative row still outranks F1
- [x] F3/F4 recorded as region-level in the vocabulary, with a check that no ambiguity
      indicator reaches the contract (DEC-045 stays a decision, not a drift)

### Step 21 — done

Before this, `invalid-tsx` and `truncated-file` produced twelve and twenty anchors and **no hint**
that part of the file was never parsed.

The check was wrong before the code was: the half-typed fixture marks nothing, and correctly so —
deleting a `>` leaves the new side with no changed bytes and the old side parsing cleanly. Third
instance of the asymmetric-edit shape, after DEC-034 and DEC-048.

973/973 checks pass.

## Step 22 — gate T0: the terminal's four unknowns, before any terminal

- [x] `Sources/diffscope-t0`, a throwaway target outside the check suite: `forkpty`, an incremental
      OSC 133 / `?1049` scanner, a generated `ZDOTDIR`, answers to the queries vim asks
- [x] S1–S5 prompt-mark reliability: five fresh shells, `echo`, `false`, an unknown command,
      `clear`, a resize at the prompt and a resize while a program runs
- [x] S6 the user's `vcs_info` survives the integration — and S6b the naive `precmd` assignment
      shown destroying it, rather than warned about
- [x] S0 the control: an unmodified shell emits zero marks, so the marks are demonstrably ours
- [x] S7 vim in and out of the alternate screen, shell usable afterwards
- [x] S8 the six macOS motions measured with real key events in `NSTextView` **and** in a
      `WKWebView` text field
- [x] S9 `~/.zshrc` and `~/.zprofile` hashed before and after, verified independently of the probe
- [x] `22-experiment-log.md` → T0, `26-terminal-plan.md` §3 marked passed, DEC-053, handoff §0

### Step 22 — done

17/17 scenarios, 973/973 checks unchanged — T0 adds no checks and removes none.

The two negative controls are the entry: without S0 every other result would hold just as well if
something in the user's setup were already emitting OSC 133.

Two harness defects found by disbelieving a clean run: the web caret was seeded before the responder
change, so the first reading said "web fields get the motions wrong" when the probe had simply
measured from the wrong position; and a wait matched the echo of a typed command rather than its
output, which leaked exactly one `ssh-agent` per run until the process count was checked by hand.

T0 also killed an assumption in the plan: the macOS motions are not an AppKit property. A DOM text
field gets all six, so T2's input line need not be overlaid on the grid.

## Step 23 — T1: the PTY lifecycle and the output grid

- [x] `DiffScopeTerminal`: `PtyProcess`, `TerminalScanner`, `ShellIntegration` (zsh + bash),
      `TerminalSession` (shell from `$SHELL`, coalesced output, prompt state), `PtyRecorder`
- [x] Gate T0 repointed at the module, so it measures the shipping code rather than a copy
- [x] xterm.js 6.0.0 + addon-fit 0.11.0, pinned exactly, second esbuild entry, colours from tokens
- [x] ⌥⌘T opens a pane under the diff; the shell starts on first open, not at launch
- [x] Output crosses as base64 of raw bytes; keystrokes cross back through one handler
- [x] `TerminalChecks`: scanner (torn marks, ST termination, exit codes, alternate screen, a
      negative control), integration files, PTY round trip with multi-byte UTF-8, resize, teardown,
      rc files unchanged, the count of places that may write to a PTY, pinned versions
- [x] Selftest arms: output reaches the grid, the alternate screen, drawn glyphs, `terminal.png`
- [x] DEC-054, the licence table, T1-A in the experiment log, handoff §0

### Step 23 — done

1031/1031 checks (973 + 58), 17/17 T0 scenarios, `package.sh` green.

The first version of the selftest passed every arm with a **completely blank** grid: xterm paints
inside `requestAnimationFrame`, and WebKit suspends those while the window is occluded. M8-D again,
through a different door — so the probe now reports what was *drawn*, not only what the buffer holds,
and the paint arm says SKIPPED with its reason rather than passing quietly.

Two harness defects on the way: showing the pane also started the user's `$SHELL`, so the arm
reported on somebody's prompt instead of its own command; and the frame counter, being a
self-perpetuating rAF chain, died at the first suspension and read zero forever after.

## Step 24 — T2: the input line

- [x] `InputRouter`: eight intercepted keys, one pure routing function, `SessionHistory`
- [x] The page is told the key list by Swift instead of carrying its own copy
- [x] A real `<textarea>` at a prompt; xterm keeps the keyboard in every raw mode
- [x] Tab and ⌃R hand the line to the shell — text first, then the key — until the next prompt
- [x] ⌥⌘R and a clickable chip force raw; Escape releases it; the chip names the mode in force
- [x] ⌃C clears the line, ⌃D only on an empty one, ↑/↓ walk this session's history
- [x] Checks: the full routing table in both modes, history boundaries and duplicates, the mode
      machine over a real PTY, and a negative control that ordinary keys are not intercepted
- [x] Selftest arms: prompt → input line → submit → handover → escape hatch, plus `terminal-input.png`
- [x] DEC-055, T2-A, plan §5, handoff §0

### Step 24 — done

1063/1063 checks (1031 + 32), 17/17 T0 scenarios, `package.sh` green with 18 selftest arms.

Two checks were wrong before the code was: one grepped for `.zsh_history` and failed on the comment
saying we do not read it (third instance of that shape), and one claimed "the shell received the
text" while testing an unrelated counter — it now reads back what `cat` echoed.

The snapshot showed what no check did: a restarted session left the previous shell's output in the
grid with nothing marking the boundary. A new session now resets it.

## Step 25 — T3: the terminal belongs to this product

- [x] OSC 7 in both integrations; the scanner reads `file://host/path` and percent-decoding
- [x] `TerminalSession.follow` under a three-term guard, with named refusals
- [x] `ShellQuoting`: one function, `cd -- '<path>'`, proved against a real shell on 12 hostile names
- [x] ⌥⌘K for when the guard refuses; the pane says when the directories disagree
- [x] A finished command refreshes the repository sweep, debounced — measured, not assumed
- [x] Checks: quoting both directions, the guard's three refusals, OSC 7 parsing and splitting,
      an unrecognised shell never claiming to know where it is
- [x] Selftest arms: the reported directory, the divergence, the quoted cd arriving; `terminal-follow.png`
- [x] DEC-056, T3-A, plan §5, handoff §0

### Step 25 — done

1080/1080 checks (1063 + 17) when the machine is idle; 1079/1080 under load, because one budget
check is wall-clock and four other processes were saturating the CPU. Recorded in the handoff rather
than fixed by raising the bound.

Two things measurement changed. The plan said FSEvents would not see `git commit` — it does, one
signal at ~440 ms, so the command mark now refreshes only the repository sweep. And the follow guard
first asked whether the shell was *named* zsh; five checks failed against a fixture emitting marks
from `/bin/sh`, and the fixture was right: the guard asks whether marks have been seen.

## Step 26 — T4: the documents that still said this cannot happen

- [x] `25-tester-packet.md` rewritten: what the app does on its own, what the terminal does, and that
      the tester's shell startup files are never edited — before the install instructions
- [x] Terminal added to "what to try" and to "known missing", including the escape hatch
- [x] `01`, `11`, `15`, `17`, `18`, `23`, `00`, `21`, `05` amended with the same distinction
- [x] DEC-003 carries its own pointer to DEC-053; its original text left as written
- [x] Checks: the retired sentences as a table over current-state documents, every one of them
      required to mention the terminal, DEC-003's pointer, and a negative control

### Step 26 — done

1088/1088 checks (1080 + 8). `26-terminal-plan.md` is closed: T0 through T4 all landed on 2026-08-01.

The sentence that had to go was *"It cannot commit, stage, push, pull, or change anything in your
repositories"* — in the one document that goes to a stranger with the zip. What replaced it is two
sentences, not one: the app changes nothing by itself, and the terminal does exactly what you type.
The test applied to every paragraph was whether a tester who commits from the pane would feel warned
or outsmarted.

**Correction to step 26.** After the checks were green, a plain `grep` over `docs/` found a retired
sentence the check had missed — §12 of the handoff still read *"demonstrably incapable of modifying a
repository"*. The check's file list was the defect: it named six current-state documents and the
handoff was not one of them, though its §4 and §6 had been amended by hand. Sentence fixed, and three
more files added to the list. A list of documents is itself a thing that can be incomplete.

## Step 27 — M8-J: the keyboard path, and the map behind it (DEC-057)

- [x] `DiffScopeShell/KeyboardMap.swift` — `12-…` §9's coverage table as an enum, the bindings as
      data, AppKit-free so `diffscope-verify` links the same file the menu is built from
- [x] `buildMenu` iterates the map; `selector(for:)` is the one place an identifier becomes a method
- [x] `RowNavigation` beside `FileListRow`, so a 63-file list can be walked without a window
- [x] `shouldSelectRow` refuses header rows — arrows, clicks and ⌘] finally agree with DEC-033
- [x] ⌥⌘V *raw for the current region*: the stop recorded, mode switched on the same pinned pair,
      the stop restored, the second press returning to the mode it left
- [x] Renderer `currentStop` / `goToStopIndex:`, and a current region for a reader who has not
      navigated yet (the first change at or below the top of the viewport)
- [x] Status line says where the reader is — `file 12/63` — and which pane has the keyboard
- [x] `KeyboardChecks`: coverage, collisions, the 63-row walk both ways, three negative controls
- [x] `Scripts/keyboard-tree.sh`, and `package.sh` refusing to package a build whose walk was skipped
- [x] Selftest arms pressing **real key events** through the real menu bar; `keyboard.png` is the
      first snapshot of the window rather than of the document
- [x] DEC-057, M8-J, OQ-023 resolved, `12-…` §9 and §12, `18-…` definition of done 6, handoff §0,
      `23b-…` §3 corrected, tester packet

### Step 27 — done, and the walk found two things the checks could not

**A specified function had never been built.** *Show raw for the current region* is a row of
`12-…` §9 and had no menu item, no action and no renderer command — through M6, M7 and M8. Fourth
instance of the shape after `runBundleFreshnessCheck`, `checkAttr` and T-10. The map being data is
the fix; the feature is a consequence of it.

**Arrow keys stopped on group headers.** DEC-033 has called headers labels since M8-F, and only
⌘] obeyed. Every check passed in that state, because the suite cannot press a key. With the refusal
removed as a negative control, the same walk reports 8 blind stops.

**Walking fast crashed the application.** One shared `TSXParser`, renders on the concurrent queue,
two threads inside `ts_parser_parse_string`, process aborted. Nothing in the suite parses on more
than one thread, so nothing could have seen it. The parser locks now, renders are serialised, and a
render whose file is no longer selected is dropped — the second half being its own defect, one
file's diff under another file's name.

1109/1109 checks (1088 + 21), 24 selftest arms, `package.sh` green with the 63-file walk in it.

## Step 28 — M8-K: the four statements the interface was not making about itself (DEC-058)

- [x] `ParserStateReport` in the engine — three states, the words composed once, carried as text
- [x] `StructuralStats.parserState`, so the suite exercises the derivation the window uses
- [x] `RenderModel.pathTaken` and `modeChip`; `impliedPath(ofMode:)` states DEC-013's 3-to-2 mapping
- [x] The branch out of the tooltip and into the repository row
- [x] `RepositoryReader.uncommittedCountConvention`, on screen under the list, beside the operation
- [x] `TrustSurfaceChecks`: state derivation, chip wording, the pill both ways, the contract's
      round trip, the convention's *truth* (`--porcelain`, no `-uall`), the three head states
- [x] Selftest arms assert the chips in the **document**: `parser: parsed` in the structural arm,
      `mode: structural — showing raw` and `parser: not parsed` in the degradation arm
- [x] DEC-058, M8-K, `23b-…` closed, handoff §0, `00-index.md`

### Step 28 — done

1143/1143 checks (1109 + 34), 37 selftest arms, the 63-file walk still clean.

**The pill invented a disagreement before it reported a real one.** Comparing the path against the
*mode* made Expanded — a presentation flag over the structural path — read as
`mode: expanded — showing structural`. Three modes, two code paths. No harness check saw it; the
selftest did, in the one arm that renders in Expanded.

**The caption vanished twice.** Three lines with the third clipped, then gone entirely when the text
got shorter — an `NSStackView` will give a label zero height beside a scroll view that grows without
limit. And then it *looked* gone a third time in a downscaled crop of `keyboard.png` while being
perfectly present at full resolution. A snapshot answers "is it drawn"; only looking at it the size
the reader does answers "is it legible".

## Step 29 - M8-L: T-11's second and third relocation shapes

- [x] `moved-block` - a multi-line function relocated past two declarations
- [x] `moved-two-blocks` - two independent relocations, so `link` pairs rather than counts
- [x] The corpus asserts its own T-11 coverage: a move exists, one spans several lines, one file
      produces two
- [x] `MANIFEST.json` re-recorded deliberately (34 fixtures)
- [x] M8-L, `26-coverage-audit.md`, `15-...`, handoff section 0, notes.md in both fixtures

### Step 29 - done

1182/1182 checks (1143 + 39), 34 fixtures.

**A fourth construction failure of the same family.** Two short single lines swapped produced zero
moves: the canonical diff had matched the shared ` = ` and `;` across them, so neither was a whole
changed line for DEC-038's search to pair. The generalisation, finally written down: the shorter the
relocated line, the more likely the byte diff has already spent its bytes matching fragments
elsewhere.

**The coverage check was wrong before the corpus was.** Its multi-line arm asked whether any
*segment* of a move contains a newline - a relocated block arrives as one segment per line, so it
reported zero multi-line moves on a corpus with two. A check written at the same time as the thing
it checks tends to encode the same guess.

## Step 30 - M8-M: OQ-046 answered by measurement

- [x] `AutoGcChecks`: a scratch repository with `gc.auto=1`, `gc.autoPackLimit=1`, `autoDetach=false`
- [x] All 15 registered operations, then three full sweeps, leave maintenance state unchanged
- [x] **Positive control**: one `git commit` in the same repository does fire
- [x] Two checks stating that neither mitigation is available - `gc.auto=0` is a write, `-c` is in
      `forbiddenArguments` - so the reasoning cannot rot into "we could always turn it off"
- [x] One-off measurement on the corpus's largest repository: 6,115 loose objects, 91% of git's
      default threshold, unchanged
- [x] M8-M, OQ-046 resolved, handoff section 0 and the risk table, `00-index.md`

### Step 30 - done

1188/1188 checks (1182 + 6).

**Arming the fixture taught the small thing.** The first version asserted more than one pack and
never got one: building the repository trips auto-gc several times on its own, so by measurement
time git has already packed and pruned. That is the arming working, not failing.

## Step 31 - M8-N: the wall-clock checks become ratios

- [x] `measure` helper in `BudgetChecks`, with the reasoning written where the next reader hits it
- [x] The dense-JSX run bounded by the cost of one parse; the oversize refusal by one byte scan
- [x] Verified under eight CPU spinners: 1188/1188, both checks passing
- [x] M8-N, handoff section 0's known-weakness paragraph struck

### Step 31 - done

The known weakness that had stood since M8-C is closed, and the fix is the one DEC-050 already
argued for in a different place: bound the work, not the wall clock.

## Step 32 - M8-O: the corpus and the plan can disagree out loud

- [x] `FixtureCatalog` - `15-...` section 4's sixty named cases as data, with priority and evidence
- [x] Evidence that is not a directory names where it *is* proven, and why it cannot be a pair
- [x] Thirteen missing P0 cases built, eight of them in section 4.1, the founding cases
- [x] Four reordering fixtures asserted never to be presented as formatting-only
- [x] `MANIFEST.json` re-recorded (47 fixtures)
- [x] M8-O, `15-...` section 8, handoff section 0, `00-index.md`, notes.md in every new fixture

### Step 32 - done

1407/1407 checks (1188 + 219), 47 fixtures.

**`prop-reordering` did not exist.** It is item 4 of the definition of done - *prop reordering with
unchanged values never reports "no change"* - and it was proven only by an input written inline in
`MatchingChecks`. The plan had asked for the fixture since Phase 6.

**A gap the new fixtures exposed rather than closed.** Neither reordering fixture is classified as
`reordering`: the detector is an exact-permutation test over the aligned gap pair, and a reformat
turns the pairs into fragments. Recorded, and the dangerous direction checked instead - a reorder is
never presented as formatting-only, which is the one classification the interface may quieten.

## Step 33 - M8-P: the design contract describes the window that exists

- [x] Section 2: three surfaces, not one; `terminal.html` and `terminal.js` listed
- [x] Section 3: the terminal pane's seven elements and the sixteen-colour palette, with which are
      load-bearing and why
- [x] Section 6: the three terminal snapshots, `keyboard.png` as the chrome picture with the command
      that produces it, and the instruction to look at full resolution
- [x] `DesignChecks` reads the contract for the first time: classes, element ids, snapshot names,
      two negative controls
- [x] Proved it bites - renaming `#cwd` in the contract fails the run
- [x] M8-P, handoff section 0, `00-index.md`

### Step 33 - done

1413/1413 checks (1407 + 6).

**The contract was written the day before the surface it describes existed.** G2 passed
2026-07-31; the terminal's grid landed 2026-08-01. Nothing re-read it, because **nothing had ever
read it** - sixth instance of a written promise with no check behind it.

**The snapshot check caught its own author first.** Its regex matched `moveFocus(to:named:)` and
demanded the contract list "repositories", "files" and "diff" as pictures.

## Step 34 — the design review becomes decisions, before any interface code

- [x] Read the adopted Claude Design project against the specification: `DiffScope.dc.html`,
      `ReviewScreen.dc.html`, `ChangeLanguage.dc.html`, `ImageCompare.dc.html`
- [x] Two rounds of correction sent back to the design — scope gaps, four DEC-035 breaches
      (add/remove by hue in unified, spine kind by hue, 2.7:1 tertiary text, search hit by fill),
      thirteen missing tokens including the four xterm.js reads as a set
- [x] DEC-059 … DEC-066 written
- [x] Amendment pointers on DEC-014, DEC-008, DEC-017, DEC-016; supersession pointer on DEC-057
- [x] `18-version-one-scope.md` — five items out of the deferred table, seven into scope
- [x] `12-…` §1 collapses, §3 base-age copy, §5 layouts and lenses, §5.5 files that render,
      §6 two rows, §9 the transcription rule, §11a motion, §12 minimum width settled at 1180
- [x] `24-design-contract.md` — the sign column and the rendered surfaces as load-bearing,
      three new refusals, and *nothing animates* replaced by *nothing animates without an off switch*
- [x] `13-error-and-fallback-model.md` — F17, F18, F19
- [x] `15-test-corpus-plan.md` §4.7a — eight fixtures, `svg-hostile` as the boundary's control
- [x] `27-design-adoption.md` — where the design lives, what its review had to fix, the work order
- [x] `00-index.md`, handoff §0, and `27` added to the retired-sentence document list

### Step 34 — done

**The design was a different product before the review.** Four features outside version one, four
colour-alone breaches, nine of eleven keyboard rows disagreeing with the shipped map, and four
load-bearing terminal elements missing. None of that is a criticism of the design — it is what a
design contract is for, and the reason `24-…` exists at all.

**The one thing the review could not fix by asking:** the age shown beside a base ref. The design
wanted "last fetched"; `11-…` §Scope-4 already records that the last fetch is not reliably
recoverable. The copy is now the committer date of the ref tip, said in those words.

**No key was rebound in this step, deliberately.** `12-…` §9's key column is a transcription of
`KeyboardMap.bindings`; writing DEC-065's map into it before the code has it would be the exact
drift DEC-057 exists to prevent. The rebinding is step 2 of `27-…` §4 and moves the tester packet
and its check in the same commit.

## Step 35 — the design lands: tokens, keys, unified, collapses

- [x] `tokens.css` is the adopted design's table: literal values in both appearances, the syntax
      theme as classes (`tok-*`) so CodeMirror's own colours leave the bundle, `--ds-term-fg/-bg/
      -cursor/-selection` renamed to the set xterm reads
- [x] `@chrome` block + third token check: every chrome token named in `Theme.swift`, negative
      control included. `Theme.swift` carries the colours as dynamic light/dark pairs
- [x] DEC-065's map, in code; `⌃`` in the tester packet and its check; the 63-file walk on ⌥↓
- [x] DEC-059 unified: composed in the renderer from the two sides, sign column, two number
      columns, tints as reinforcement; `⌥⌘→` for the two panes; selftest arm + `unified.png`
- [x] DEC-060 three collapses: rail, spine, both; kind glyph on every spine bar; `collapsed.png`

### Step 35 — done, with two defects the pictures found and one still open

**The gutters had been drawing light on a black window.** `.cm-gutters { background: #f5f5f5 }`
from CodeMirror's own StyleModule was beating the token rule, in both panes, and no check could
see it — the audit probes a synthetic span, not the real gutter. Found by sampling
`structural.png` pixel by pixel. Fixed by specificity.

**A 44 px rail drew at 87 px.** The width constraint said 44, the constant read 44, and the
scroll view's own content width was the pane's real floor. The file spine drew *nothing* until the
scroller stopped reserving its width. Both were invisible to every check and obvious in one
photograph — M8-D's lesson, third instance. The arm now reports the **drawn** widths.

**The rail's clipped label — closed, and it was the table's *style*.** `NSTableView`'s automatic
style is `.inset` on modern macOS: a 16 pt margin each side and 17 pt of intercell spacing. With
one column that is 16 pt of padding before the only cell, which in a 44 px rail is half the row —
`kbt•` set, `kb` drawn. Four guesses missed it (column width, horizontal scroll offset, scroller
reservation, document-view width); the fifth measurement found it, by printing the cell's frame in
window coordinates beside the clip view's. `.plain` plus a 4 pt intercell spacing fixes it, and
the arm now **asserts the indent** — the row must start within 8 pt of the pane, so a style change
that re-insets the table fails rather than merely looking wrong.

## Step 36 — the states that had engine support and no words

- [x] Base-ref age: `newest commit 9 weeks old`, `newest-commit age unknown`. The old wording could
      be read as a fetch time, which is the one thing it is not
- [x] Unavailable scopes state their reason on the status line, not only in a tooltip, with a check
      on both halves
- [x] The collapsed rail's clipped label — closed, see step 35's note

### Step 36 — what is left of `27-…` §4

Step 5 is part-done: still to build are `#unrenderable` saying *what* the file is, the missing-root
and base-branch-prompt screens as drawn, the preferences window for the editor command, and the
watcher's three status-line states. Then motion (6), search (7), the two lenses (7), and the
rendered comparison (8) with its eight new fixtures.

## Step 37 — settings, the unrenderable sentence, motion, search

- [x] `editorTemplate` in the configuration file; Settings (⌘,) edits it; `DIFFSCOPE_EDITOR` stays as
      the override F13 needs; the last attempt is kept where a reader will look for it
- [x] `#unrenderable` answers *what this file is* and *why nothing is compared*, with the byte
      counts, instead of `String(describing: error)`
- [x] Motion (DEC-064): tokens for duration and curve, transitions on the interface's own
      furniture, a `prefers-reduced-motion` block that switches everything off, and the chrome
      reading `accessibilityDisplayShouldReduceMotion` before it animates
- [x] Search (DEC-062): the engine half as a pure function with thirteen checks; ⌘F over the
      changed set, ⇧⌘F over the worktree

### Step 37 — three checks that had been agreeing with the wrong number

**The collapse arm asserted a constraint's constant.** The file pane was ignoring its width
constraint at priority 600 — the rail collapsed, the spine stayed at 320 — and the arm called that
a pass, because a constant is what was asked for rather than what the window did. Priority 999, and
the arm asserts drawn widths now.

**The collapse animation animated the constant.** An animation that does not run to completion
leaves it where it was, so the pane never moved at all under the selftest. Animating the layout
pass instead keeps the constant authoritative.

**The search count was wrong in the check before it was wrong in the code** — three expected, four
correct, because the import line carries both the symbol and the module path. Worth writing down:
the check earned its place by disagreeing with the person who wrote it.

### What is left of `27-…` §4

The two lenses (Blame, History) and the rendered comparison with its eight fixtures. Step 5's
remaining screens — missing root, base-branch prompt, the watcher's three states — turned out to be
built already; what was missing was the wording, and that is now in.

## Step 38 — the two lenses and the rendered comparison

- [x] `blame` and `log` in the closed operation registry, so R-8 covers them from the first call
- [x] Parsers as pure functions over text — fourteen checks, including a block's second line
      inheriting the author it did not repeat, an all-zero sha as the mark of uncommitted work, and
      a commit subject carrying a pipe and a tab
- [x] `#lens` rows: uncommitted work marked by an edge, never tinted
- [x] `renderableKind` reads bytes as well as names: a `.png` that is not a PNG is undisplayable
      rather than an empty frame
- [x] The pixel pass in Swift, with the mask drawn there too, because a canvas that has drawn an
      SVG cannot be read back
- [x] Four modes, each offered or refused **with a reason**; fifteen checks over the copy
- [x] Selftest arms and snapshots: `blame`, `history`, `rendered`

### Step 38 — the collapse, for the third time

`NSSplitView` ignored a width constraint at 600, ignored it at 999, and ignored `setPosition` as
well. What it does not ignore is a layout pass from **the window's content view** — the split view
is not the constraint owner, and laying out its own subtree left the second divider exactly where
it had been. The rail obeyed all along, which is what made it look like a spine problem for three
sittings.

Worth keeping: the arm that caught this asserts **drawn** widths. Every version of it that asserted
the constraint's constant passed while the window showed something else.

### Left

The eight image fixtures of `15-…` §4.7a are specified and not built; the classification and the
copy are checked, and `svg-hostile` is the one that matters — it is the control for the `<img>`
boundary rather than a nicety. A small image also draws at its natural size in the stage, which is
right for an asset and mean to a 16-pixel icon.

## Step 39 — the eight fixtures of §4.7a

- [x] `Scripts/image-fixtures.sh` writes all eight byte by byte: PNGs assembled from IHDR/IDAT with
      an explicit compression level, SVGs as text, a structurally real zip
- [x] `notes.md` for each, saying what would go wrong without it
- [x] Registered in `FixtureCatalog` as §4.7a P1, so the plan and the corpus can disagree out loud
- [x] `MANIFEST.json` rewritten — 47 fixtures to 55, and every one now under T-0 … T-11
- [x] Twelve checks over the fixture *bytes*: classification, an empty left side, the resize really
      resizing, the identical pair really differing, and the hostile file really carrying a script,
      an event handler and a remote reference
- [x] Two selftest arms: the pixel claims (0 and 128) and the `<img>` boundary

### Step 39 — the two that needed a fixture rather than an assertion

**`raster-identical-bytes-differ` reports 0.** That number is the whole of F18: if a pixel pass ever
returns non-zero here, the sentence *"the two files render identically"* is replaced by a count and
the reader is told the opposite of the truth. It could not be tested with a constructed pair,
because the interesting part is that a real re-encode changes every byte and no pixel.

**`svg-hostile` is asked both questions.** Drawn — two images on the page — *and* inert, with
`globalThis.__diffscopeHostile` still undefined. A control that only asked whether the marker was
absent would pass on a pane that drew nothing at all, which is the failure mode a boundary check
most easily hides behind.

The over-budget frame's size is read from its IHDR rather than from its note. A fixture that claims
to exceed the budget and does not would make the refusal untestable while looking tested.

## Step 40 — M9-A: the chrome catches up with the design

- [x] `diff --numstat` in the registry; `ChangeCount` with `binary` as a state, not a zero; eight
      checks including the rename path expression git writes instead of a path
- [x] Both lists drawn as columns; repository rows two lines; counts right-aligned
- [x] Selection drawn from `--ds-row-selected` and `--ds-row-ring` — the system highlight carried it
      in colour alone and repainted the row's text white
- [x] The base row under the scope control: what *this* scope compares, or the base ref and the age
      of its newest commit
- [x] The mode control reordered to Structural / Expanded / Raw, so it agrees with ⌘1 / ⌘2 / ⌘3
- [x] The file header in the diff pane — dim path, emphasised name
- [x] The lens control beside scope and mode
- [x] Search as a field in the window, with the scope in its placeholder

### Step 40 — what is left before the window matches the design

Substantial:
- **Terminal drawer**: full window width with a tab strip and a cwd per tab. Today it is one session
  under the diff pane.
- **History → comparison**: selecting one commit to diff against the working tree, two against each
  other. Today the lens lists commits and does not act on a selection.
- **Search results**: grouped by file with the hit's line context, as drawn. Today they replace the
  file list as plain rows.

Cosmetic, and each an hour or two:
- Blend's opacity slider and Split's draggable divider (both fixed at 50%).
- Hunk headers (`@@ 12–25 · wrapper removed, children preserved`).
- The linked horizontal scroll track under the pane.
- Preferences as a window rather than an alert.
- `--ds-focus-ring` on the focused region: the token is mirrored and nothing draws it.
- The empty state's two buttons are plain; the design gives them a rim.

## Step 41 — M9-B: the drobiazgi, and two of the three grube

- [x] Hunk headers `@@ −12,4 +12,5 @@` above each merged block in unified
- [x] Blend and Split get a slider each, ends labelled, value in words — 50% was the one setting
      that hides a small difference under both images at once
- [x] **Horizontal scrolling is linked**, which `12-…` §5.4 asked for and only the vertical half of
      which had ever been wired, plus the one track the two panes share
- [x] `--ds-focus-ring` drawn on the focused region — the token had been mirrored and used by
      nothing since the chrome landed
- [x] Settings as a window rather than an alert
- [x] History: one picked commit compares against the working tree, two compare each other; the
      page can post messages now, and what arrives is validated as input
- [x] Search results in the pane, grouped by file, ⌘G / ⇧⌘G on the marker, ⌘⏎ on the hit

### Step 41 — what was found rather than built

**Linked horizontal scrolling was a specification line with nothing behind it.** §5.4 says the
panes' horizontal scrolling is linked; `link()` synced `scrollTop` and nothing else, and had since
M3. On a minified file — the case that section was written about — the panes drifted apart and the
reader was comparing column 200 of one side with column 40 of the other, with nothing on screen
saying so. Three milestones of "the spec says we do this".

**The focus ring was a token nobody drew.** `--ds-focus-ring` passed the mirror check the day it
was added, because that check asks whether `Theme.swift` *names* the token — which it did. Naming
is not drawing. The chrome is where the token checks cannot see.

### Not done, and why

~~**The empty state's buttons keep the system bezel.**~~ **Done, 2026-08-10** — and the objection
that deferred it was right about the *method*, not the outcome. The rim goes **around** a standard
`NSButton` rather than replacing it: `bezelColor` tints the bezel the cell still draws and the
layer adds the border, so the key-equivalent ring, the pressed state and the focus behaviour all
survive. Three checks hold that shape, and the empty state is now photographed (`empty`) — the
only way to see whether a 1 px rim reads at all.

**The terminal drawer is still one session under the diff pane.** Tabs and a full-width drawer need
DEC-053 reopened — it says one session — so it belongs in the decision log before it belongs in
`TerminalPane`.

## Step 42 — DEC-067: the terminal drawer grows tabs, and a window's width

- [x] DEC-067 written; DEC-053 carries its amendment pointer
- [x] The drawer moves below the three-pane split — the grid went from 104 columns to 202
- [x] One `TerminalSession` **and one xterm instance** per tab; scrollback, cursor and the
      alternate screen stay the emulator's business
- [x] Every message carries its tab, in both directions
- [x] The strip says which shell and where *that* shell is, with DEC-056's dotted underline per tab
- [x] ⌥⌘T, ⌃⌘] / ⌃⌘[, ⌃⌘W; eight source checks and two selftest arms

### Step 42 — three ways the page and the pane disagreed

**`evaluateJavaScript` on an unloaded page is dropped in silence.** A tab opened before the page
finished loading existed in Swift and not in the page, and the first selection afterwards created a
*third* grid for it. The pane's list is the truth and the page is told it again on `didFinish`.

**`stop()` cleared the list and left the grids.** The page then held tabs with no session behind
them, and a later selection landed on one — a drawer showing a shell that had been dead for two
arms.

**Buffered output had no address.** Bytes that arrive before the page is ready were replayed into
"the current tab", which invented a grid and put the first shell's output in it. The buffer carries
the tab now.

**And the arm's first assertion was wrong rather than the code.** It asked whether the first tab
still held a particular string; by then its shell had been restarted twice by earlier arms. What
the design actually claims is that the two scrollbacks stay **apart** — that the second tab's
output never appears in the first — which is exactly what one grid replaying a buffer would break.

## Step 43 — nothing in the design is outstanding

The rim was the last item. What the window draws now matches the adopted design in every part that
was ever written down: the token table in both halves, the keyboard map, unified with its sign
column, three collapses, the lenses, search, the rendered comparison, motion with its off switch,
the terminal's tabs, and the empty state.

Two things are worth writing down for whoever picks this up next, because neither is a defect:

- **The design's window chrome is not reproduced.** It draws a custom title bar carrying the
  repository name and path; the window uses the system title bar and puts both in the repository
  row instead. A custom title bar is a decision about window management, not about the diff.
- **Nothing here has been used in anger for a day.** Every claim in this repository is checked or
  photographed, and neither is the same as a reader reviewing their own work with it for a week.
  The next thing worth doing is `25-tester-packet.md`'s job, not another feature.

## Step 44 — the check that flaked, and the layout nobody had measured

- [x] `diffscope-verify` reprints the failed check names under `what failed:` beside the count —
      the first run of this session reported 1597/1598 and the name was fifteen hundred lines above
      the summary, in output that had been tailed
- [x] Eight runs to reproduce it (five idle, three under eight CPU spinners): **it never came back**,
      and the failing check is therefore unidentified rather than fixed
- [x] Three arms in `RefreshChecks` re-expressed as bounds on work rather than on the machine —
      the R-9 race by reads (200 and 100), the debounce wait as a multiple of DEC-026's own cap,
      the live FSEvents wait at 10 s
- [x] `scale-*` selftest arms: three inputs, both layouts, the ratio between them, with
      `diffscopeInjectSlowProjection` as the control
- [x] `22-experiment-log.md` → M9-C and M9-D; `16-…` §2, §3 and §8

### Step 44 — what the measurement found, which was not what it went looking for

**Unified is cheaper than side-by-side, everywhere** — 0.49× to 0.68×. It populates one editor
where side-by-side populates two, and the composition it does on top of that costs 1.1 ms on a
fifty-thousand-line file against a 28 ms dispatch. The suspicion that took the measurement there,
that `projectSegments`' nested loop would dominate, was wrong about the magnitude: it is the only
superlinear term and it measures 4.75 ms on the one case that reaches it with segments in it.

**That case had to be built deliberately.** A 50,000-line file and a minified one both fall back to
raw under DEC-050, and a raw fallback carries **one segment per side** — so both would have walked
past the loop and reported it free. Every line of the arm prints `path=` for that reason.

**The budget that keeps it safe was not written for this.** DEC-050's 30,000-node gate exists to
stop the matcher; it also bounds how many segments can ever reach the projection. Recorded as a
known weakness rather than optimised, with the trigger stated: re-measure if that budget is raised.

### Step 44 — the check that got away

Not a defect found and fixed; a defect **observed and lost**. One run in eight failed, and the
harness could not say which check. The durable fix is that the run now names its failures, so the
next occurrence identifies itself. The three arms hardened alongside it are provably load-dependent
by reading — they may or may not be the one.

## Step 45 — the open-questions audit

- [x] `05-open-questions.md` audited against `04-decision-log.md` and the code
- [x] **24 entries struck through** with what closed them — OQ-003, 004, 005, 008, 010, 017, 026,
      028, 031, 033, 036, 037, 038, 039, 040, 042, 043, 044, 045, 048, 049, 050, 051, 052
- [x] OQ-049's **duplicate** resolved: it was Open under Git behaviour and struck through under
      diff-engine specifics, in the same document
- [x] Five part-answered entries now say which part is left (OQ-012, 014, 025, 029, 030)
- [x] A header table: eight genuinely open, five part-answered, each with its reason
- [x] `21-…` §0 and its file map updated

### Step 45 — what the audit found beyond the bookkeeping

**OQ-054 is the one that matters, and it is untouched.** Case-folding and NFC in path matching: the
only `lowercased()` in the Git layer is `FileGrouping`'s extension test, which is not path matching.
The measured hazard stands — FSEvents reports the **on-disk** case, so a write via `src/foo.ts` to a
disk holding `src/Foo.TS` stops reaching the watcher, and **auto-refresh silently stops updating
that file**. It is the only entry left open whose failure mode is silence rather than absence.

**Two entries were closed by implementation rather than by a decision**, and are marked that way
rather than given a retrospective DEC: OQ-008 and OQ-050, both built against DEC-012's rule that an
unknown is stated rather than fabricated, both asserted by name in the suite.

**OQ-001 was closed by nobody and adopted by everybody.** Phase 8 arrived, `package.sh` ships
`DiffScope.app`, and the tester packet calls the product DiffScope to a stranger. The placeholder is
now in the bundle identifier, the icon, the packet and the repository name. Left open, with that
said out loud, so a rename is a decision rather than a discovery.

**`FixtureCatalog` is why OQ-029 stays half open.** `generated-file` is a P0 case recorded as *not
proven — OQ-029 is open*. The catalog and this document agree, which is the mechanism working:
closing the entry is what lets the fixture exist.

## Step 46 — DEC-068: the pin guard was certifying an empty file

- [x] Measured: **5 blends in 1,200 reads** once M9-C's read bound replaced the 1.5 s window
- [x] The blend arm reports the **shape**, which named the cause in one run — every blend was
      `0/52000 bytes`, a zero-length file
- [x] DEC-068 written; DEC-049 carries its amendment pointer and nothing in it was rewritten
- [x] `settledRead` sleeps `settleRetryDelay` between the read and its confirmation
- [x] **0 blends in 1,600 reads** since; the *usable pins* arm settles ~70% against its >50% floor
- [x] `22-…` → M9-E, `26-coverage-audit.md`, `15-…` §5.2, `21-…` §0

### Step 46 — the check was not weak, it was under-sampled

M8-H measured this guard's two halves leaking at **6 in 20** and **3 in 8,095**, and then the arm
that guards the combination sampled **fifteen reads**. Nothing was wrong with what it asserted. What
was wrong is that it chose an *elapsed window* and accepted whatever reads the machine managed
inside it — and never printed how many that was. `hostile.reads > 10` was the only thing standing
between fifteen observations and zero, and it passed.

**The window and the sample size are different quantities, and only one of them is the evidence.**

### Step 46 — three things that generalise

- **A blend includes a short or empty read.** An arm looking for interleaved content would have
  called every one of these clean. The guard's own claim is *a version that never existed on disk*,
  and an empty file caught between `truncate` and its rewrite is exactly that.
- **A fixture whose two sides are the same length disables the size term of any stat guard.** Both
  versions here are 52,000 bytes, so `FileStamp` was running on `mtime` alone and nobody had noticed.
- **Report the shape, not the count.** `1 blended of 200` costs the next reader a re-run.
  `0/52000 bytes, 0 A-lines + 0 B-lines` costs them nothing.

## Step 47 — DEC-069: OQ-054, and what it turned out to be

- [x] Checks written first and seen to fail: three of four failed on the unfixed code
- [x] DEC-069 written before the code
- [x] `PathIdentity.of` — device plus inode where the path exists, folded string where it does not;
      `PathIdentity.resolved` for containment, because an inode cannot express *underneath*
- [x] Applied at `DiscoveredRepository.identity`, `ConfiguredSource.contains`, the add-source
      dedupe and `removeSource`; `sortKey` added, since the rail cannot be ordered by an inode
- [x] Swift's canonical equivalence asserted with the differing bytes as its control
- [x] `22-…` → M9-F; OQ-054 closed with the correction visible; `21-…` §0
- [x] 1598 → 1608 checks

### Step 47 — the entry was wrong twice and right once

**The failure mode it named cannot happen.** OQ-054 said a case mismatch means auto-refresh silently
stops following a file. The watcher does not match paths at all — it ORs the event flags and signals
`.changed` for the whole repository. The entry was written against a per-file watching design;
DEC-007 and DEC-027 built a per-repository one, and nobody went back to the question.

**Half the remedy was already free.** It asked for case-folded *and* NFC-normalized comparison.
Swift's `String ==`, `hasPrefix` and `Set` membership are canonical equivalence, so NFC and NFD
already compare and hash equal. **This is M6-C read backwards** — there the same semantics made an
NFC detector incapable of firing, and the fixtures passed anyway. Asserted now, with the differing
bytes as the control, because it is load-bearing in the opposite direction.

**And the first check written for it passed on the unfixed code.** `contentsOfDirectory` returns the
filesystem's own spelling and `resolvingSymlinksInPath` canonicalises case, so root scanning was
never affected. The defect was one source kind: an individually added repository, taken verbatim
from the configuration. Under DEC-037 — roots *and* individual repositories in one list — the same
working tree reached both ways produced two rows.

### Step 47 — why identity is not a string

The two spellings differ by more than case: `NSTemporaryDirectory()` gives `/var/folders/…` and
`contentsOfDirectory` gives `/private/var/folders/…` for the same file, and `standardizedFileURL`
resolves neither. A folding rule has to anticipate every way two names for one file can differ.
A `stat` does not — and it stays right on a case-**sensitive** volume, where folding would merge two
directories that really are different.

The cost of that choice, stated: `identity` is no longer readable as a path, so `sortKey` exists for
the rail's ordering and the checks print both.

## Step 48 — the tester packet catches up, and stops being a hand copy of the keyboard map

- [x] `⌘O` → `⌘⏎` for open-in-editor: DEC-065 moved it and the packet said `⌘O` for two milestones
- [x] `⌘2 Structural with ⌘1 Raw` → `⌘1` and `⌘3`; the packet contradicted its own mode list
- [x] Three "known missing" items removed because they are no longer missing — the mode pill
      reporting only the selection (fixed by DEC-058), *no search* (DEC-062), *it looks plain*
      (the whole adopted design, DEC-059…067)
- [x] *No branch or commit picker* narrowed: the History lens compares commits, ⇧⌘B sets the base
- [x] Added: what a reader sees when a file is mid-save (DEC-068), the two kinds of pill, motion
      and its reduced-motion switch, and screen readers as a stated gap rather than an omission
- [x] **A check that every keystroke the packet prints is one `KeyboardMap` binds**, with an
      unbound shortcut as its control. 1608 → 1610

### Step 48 — the packet was a third transcription, and it drifted

DEC-057 made the keyboard map data because `12-…` §9's table and the menu bar were two copies of
one thing and disagreed for three milestones. The tester packet is a **third** copy, written by
hand, and it drifted the same way the moment DEC-065 re-cut the map: `⌘O` for open-in-editor
survived in the document that goes to a **stranger who is about to press it**.

Nothing could have caught it. `runTesterPacketChecks` asserted that certain sentences were present —
the config path, the Gatekeeper step, `git commit`, `~/.zshrc` — and nothing about the keystrokes.
Now every modifier run in the packet has to be a shortcut `KeyboardMap` actually composes.

**The check caught its own first version.** The key position started as *any character except
whitespace and punctuation*, to avoid Markdown link syntax — and `⌃⌘]` is a real binding, so it
failed immediately. Excluding `,` would have broken `⌘,` in the same way. The key position is now
any character at all, and whether a token is a shortcut is decided by the map rather than by a guess
about punctuation.

## Step 49 — the first screen is photographed, the window server composites, and a borrowed constant is repaid

- [x] `empty.png` was **2800×138** — a strip with the caption and neither button. Frames printed:
      `content=1400×69pt buttons=2 [539,-28 …] [683,-28 …] inside=false`
- [x] Cause: `showEmptyState` hid the split view, the drawer lost its height, and the **content view
      followed it down**. Fixed by covering rather than hiding, with a drawer floor behind it
- [x] The empty-state arm asserts the buttons are **drawn, non-empty and inside the picture**,
      not merely `!isHidden`
- [x] `windowSnapshot` asks the **window server** first, so the web views are in the picture, and
      every snapshot line states its method and size
- [x] DEC-068's separation moved from the borrowed 20 ms to a measured 5 ms — refusals during a
      burst of saves fall from ~50% to ~7%, blends stay 0 in 800 reads

### Step 49 — three ways this was the same mistake

**A check that asserted the wrong noun.** `!emptyState.isHidden` was true the whole time the
photograph was empty. Not hidden is not on screen, and the rim it was taken for is a 1 px border
that no assertion can reach — only a picture can.

**A fix aimed at the wrong object.** `window.contentMinSize` was the first attempt and did nothing,
because it bounds the *window* and the window never shrank. The content view did, following its own
children. Worth keeping in the record: the mistake named the real mechanism.

**A constant borrowed instead of measured.** `settleRetryDelay` existed and was 20 ms, so DEC-068
used it — but it is sized against a whole save, and what the separation must outlast is a truncate
window of microseconds. It survived review because it looked like reuse rather than a choice.

### Step 49 — what is still not true

The window-server capture **does not always succeed**: an occluded window has nothing composited,
and a selftest launched from a terminal is always occluded. Both paths remain and each picture says
which one it used. So there is now a way to get chrome and diff into one image, but not a guarantee
of one on every run.

## Step 50 — the default layout was never sent, and unified was missing two things because of it

- [x] `didFinish` now tells the page which layout to use, so DEC-059's unified default actually
      reaches the reader. Nothing had ever sent it: the renderer's own default is `split`, the
      shell's `sideBySide` was `false`, and the two never spoke
- [x] The **first** probe asserts the layout before anything sets it — the only moment a *default*
      can be observed
- [x] Folds are drawn in unified. `decorationsForUnified` built marks and direction lines and
      nothing else, so a collapsed range did not exist in that layout at all
- [x] The rest of the walk sets `split` explicitly, because those arms read the two-pane DOM

### Step 50 — reported by the product owner, and every check had passed

The window opened side by side while the menu said unified, DEC-059 said unified, and
`27-…` §4a said the layout was built and outstanding nothing.

**The unified arm could not have caught it.** It calls `diffscopeSetLayout("unified")` and then asks
what the layout is — a check that sets the thing it is about to read is asking what it asked for.
The same shape as the constraint constants in M9-A and the mode pill in M8-K, and the third time
this project has found it.

**And the defect hid two more behind it.** With unified never reached, nobody noticed that it draws
no folds and no changed-line gutter marks. Folds are now projected through the old-side runs — the
regions a fold covers are byte-equal, and unified emits exactly those as context from the old side,
so the mapping is exact. The gutter marks stay a split feature: in unified the sign column carries
per-line direction, which is the stronger indicator and is already asserted.

**A default nobody sends is not a default.** Worth checking the others: anything the shell holds as
initial state and the page holds independently is the same trap.

## Step 51 — DEC-070: the focus ring stops being permanent

- [x] `navigatingByKeyboard`, false at launch; a keystroke lights the ring, a click puts it out
- [x] Set at the action in `moveFocus` **and** at the event by a `.keyDown` monitor — a key
      equivalent through the menu does not reach a local monitor, so neither alone is enough
- [x] `focus-ring` arm: lit after ⌥⌘2, dark after a click. `keyboard=0/2/0 after a click=0/0/0`
- [x] DEC-070 clarifies DEC-016 rather than weakening it

### Step 51 — the first version of the check could not see the mechanism

It set the flag through a synthesized key event and read `0/0/0`: the keyboard walk drives
`performKeyEquivalent` directly, and **a local event monitor never sees that**. So the check was
watching a path the application does not take under test. Fixed by marking keyboard navigation at
the *action* — which is also the honest place, since ⌥⌘1–3 arriving in `moveFocus` **is** keyboard
navigation regardless of how the event was delivered.

What remains uncovered, and is written down rather than implied: a synthesized click cannot traverse
the monitor either, so the mouse half of the arm asserts the drawing rather than the trigger.
