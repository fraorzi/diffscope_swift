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

## Step 52 — the black gap that was not there, and the frames that now say so

- [x] Every snapshot line prints the pane frames: drawer, both drawer panes, the three-pane split,
      the diff pane and its web view
- [x] `diffscopeHeights()` returns **rectangles** for every child of `body`, so the page can be
      asked what occupies a band rather than only how tall things are

### Step 52 — I was wrong, and the measurements are why

Reported from a screenshot: the lower half of the window is black, the panes stop half way down.
Three independent measurements say otherwise and they sum to the window exactly:

```
drawer=1400×789@24  panes=1400×788@0  drawerPanes=1400×788@0, 1400×0@789
diffPane=798×788@0  diffWeb=798×731@0
page: file-header 0→28  notices 28→60  stage 60→715  track 715→731   of 731
```

The terminal host is **zero** high, the panes take the whole drawer, the web view fills the pane and
the document fills the web view. There is no gap to find.

**The mistake was reading a crop whose coordinate mapping I never checked.** M8-K's lesson is *look
at the picture at full resolution*; this was the same error one door along — full resolution, wrong
region. A frame printed beside the picture would have settled it in one run, which is why every
snapshot now prints one.

**What is actually there** is a ten-line file in a pane 731 pt tall, so six hundred points of empty
editor. The adopted design never looks like that because its file fills the pane **and** the pane is
closed by a bottom bar — `4 formatting differences — indentation only` with `Expand ⌘E`. That bar
does not exist here, and it is on the gap list rather than being a defect of its own.

**One diagnostic earned its place twice:** logging `terminal.webView.frame` reported `1400×0` and
looked like proof the drawer was shut, while saying nothing about the pane holding it. The host is
what takes the space, so the host is what is printed.

## Step 53 — the right margin and the bar that closes the pane

- [x] `ds-note` after each line: `M1` and its pair on the other side, the disclosure name,
      `formatting`, `reordered`, `uncertain`, and `inserted` / `removed` on a one-sided block
- [x] `#diff-footer`: how many formatting differences and of what kind, how many lines are folded,
      and an `Expand ⌘E` button that runs the **same** command the keystroke runs
- [x] Both described in `24-design-contract.md` in the same commit that adds them — the contract
      check refused the build until they were
- [x] The formatting-collapse arm asserts the bar's text and the note, not only the fold markers

### Step 53 — what the design asks for that the engine cannot say

The adopted design writes **`wrapper removed`** in this margin. The engine has no such notion:
`label`, `classification`, `group`, `disclosure` and `link` are the entire vocabulary (DEC-046,
DEC-038). A margin that said *wrapper removed* would be the renderer making a claim the engine never
made, which `24-…` §1 forbids outright — so it is **not** drawn, and the contract entry says why.

`inserted` / `removed` **is** drawn, because it is derivable: a merged block whose old side is empty
added lines and took none away.

### Step 53 — the note is not at the right edge, and that was measured

The design right-aligns these against the pane. That needs `position: relative` on `.cm-line`, and
that rule **breaks CodeMirror's line measurement**: the gutter drifts out of step with the code —
line 2's number eighteen pixels below line 2, gutter rows 33–56 px apart against a steady 30 px of
content. Found by looking at the picture, confirmed by removing the rule and watching the numbers
snap back.

Alignment of the two number columns is how a reader says *where*; the note's exact position is not.
So the note sits after the code, in the shape `ds-badge` already uses.

### Step 53 — DEC-017's count now stays put

Until this bar existed the grouped count lived on the **fold markers alone**, so a reader who had
scrolled past them had no statement of how much had been grouped — while DEC-017 permits grouping
*only while the count is shown*. The bar says it in one place that does not move, and the button
calls `expandAll`, the same command ⌘E calls, so the two cannot come to disagree.

## Step 54 — the SHOWING row, facts on the hunk headers, and a measurement that fooled me three times

- [x] `#showing`: what is being compared, which layout is drawing it, and — in unified only — what
      `+` and `−` mean. The sentence is composed in the Git layer and pushed in
- [x] Hunk headers carry the facts of their block: `M1`, `formatting only — whitespace`,
      `reordering — may change behaviour`, the disclosure names, `one alignment left ambiguous`
- [x] `diffscopeHeights().rows` reports where the gutter rows and the lines actually are
- [x] The geometry is asked **after a turn of the run loop**, and only then is it stable

### Step 54 — what the design says that the engine cannot

The header the design draws is `@@ 12–25 · wrapper removed, children preserved`. *Wrapper removed*
is not available and is not invented. What **is** available turned out to include one of the
design's own phrases: *one alignment left ambiguous* is `uncertain`, counted.

The numeric form stays rather than becoming the design's single range, because `−12,4 +12,5` says
which side each count belongs to and `12–25` cannot.

### Step 54 — three readings, all wrong, all mine

The gutter looked misaligned in a screenshot. It was not.

1. **Read from a downscaled image**, where 15 px and 17 px rows are indistinguishable from
   antialiasing. M8-K's rule is *look at full resolution*; I had already broken it once today by
   looking at full resolution at the **wrong region**.
2. **Measured before the layout settled.** Asked immediately after `setLayout`, the numbers flip
   between runs on identical input — 61,89,106… one run and 65,80,95… the next. Every conclusion
   drawn from them was a conclusion about timing.
3. **Two "fixes" credited to the wrong cause.** A shared `line-height` appeared to repair it and a
   `line-height` on the hunk widget appeared to undo the repair; neither did anything. Asked after
   a turn of the run loop, the rows agree to the pixel and agree **identically across runs**.

The shared line-height token stays as a guard — two things that must match should not be able to
take different defaults — and the comment beside it says outright that it repaired nothing
observable. **A number taken before the thing settles is a number about the timing.** That is the
same lesson as M9-G, in a second place, on the same day.

## Step 55 — the trust pills say more, in the words the decisions allow

- [x] `parser: parsed — tree-sitter tsx` — the chip names the grammar that read the file
- [x] `confidence: high`, or `confidence: N of M alignments below the floor`
- [x] `ParserStateReport` gains `grammar`, encoded and decoded; the check that pinned the old
      wording is updated with its intent restated rather than loosened

### Step 55 — naming the grammar is a disclosure, not a detail

Every supported extension — `.ts`, `.tsx`, `.js`, `.jsx` — is read by the **TSX** grammar. A reader
looking at plain JavaScript is now told, correctly, that it was parsed as TSX. That is worth saying
out loud rather than leaving as an implementation fact.

### Step 55 — where the design's wording could not be used

The adopted design writes **`1 ambiguous alignment — both readings kept`**. That is precisely the
indicator **DEC-045 withdrew**: ambiguity detection stays as a guard on anchoring, and no ambiguity
indicator is built, because the safety rationale lapsed once structural labels were reconciled
against the canonical byte diff.

But the same entry says, in its consequences, *"Confidence display (a separate DEC-017 item) is
untouched by this."* So the fact is shown in the language of **confidence**, which DEC-017 lists
among the mandatory trust indicators, and not in the language of ambiguity, which DEC-045 retired.
Same underlying number, and the decision log decides which sentence it may become.

`uncertain` remains `confidence < confidenceFloor`, decided in the engine at 0.8 — a renderer that
chose its own threshold would be redefining what counts as certain, which is why the flag rides on
the contract rather than the number.

## Step 56 — the two lists say what they are, and the `+` opens the map

- [x] `REPOSITORIES` over the repository list, with the `+` that adds a source
- [x] `CHANGED FILES` over the file list, with the number of files in scope beside it
- [x] Both captions composed by `ChromeLabels` in `DiffScopeShell`, so the check suite links the
      file the window draws from
- [x] Collapsed (DEC-060): the word goes, the count stays — and `fitsCollapsedPane` says so in
      characters while the collapse arm says it in points
- [x] DEC-071 written before the code; `24-design-contract.md` gained the chrome's own view table
      in the same commit, with a check requiring every `NSView` subclass in the app to be in it
- [x] 1610 → **1628 checks**, three of them negative controls

### Step 56 — the `+` is the first instance of a rule, not a button

Adding a source already had bindings: `⇧⌘O` and `⇧⌘R`, drawn in the Sources menu from
`KeyboardMap.bindings` since DEC-057. A button is a **third** surface for the same function, and the
tester packet is the record of what a third hand-written copy of the keyboard map does — it told a
stranger to press `⌘O` for two milestones after DEC-065 moved that key.

So the menu the button pops up is built from `KeyboardMap.bindings(in: .sources)` and names nothing
itself. Generalised in DEC-071: **a pointer affordance may only open a function the keyboard map
already has.** DEC-016 calls a function reachable only by pointer a defect; a control reaching
something the map does not have is that defect with the surfaces swapped. A check reads the method's
body and refuses an `NSMenuItem(title:` in it, with a hand-titled item as the control.

### Step 56 — what the pane says when it is 44 points wide

`REPOSITORIES` does not fit a collapsed rail, and a header that draws `REPOS` says nothing about
what it counts. `···` was the other candidate and is worse: it announces that a header is here.

So the rule is **the word goes and the count stays**, and it is a function rather than a taste —
`fitsCollapsedPane` is asserted over every count from 0 to 10,000, with a header that kept its word
as the negative control. Above 999 the count reads `999+` rather than being clipped, because a
clipped number lies about its own magnitude while `999+` states exactly what is known.

### Step 56 — the count in the header is not the count in the status line, and both are right

The status line says `63 files · Unstaged`; the header says `63`. That repetition is deliberate and
is DEC-058's shape: the header answers *how many of these*, beside the list it counts, and the status
line answers *what just happened*, at the edge a reader glances at. The trap it walks past is the row
count — the tree has 63 changed files under nine group headers, so a header counting **rows** would
have said 72. The arm asserts against `state.files`, not against the drawn list.

## Step 57 — the scope row spans the window, and the base becomes a block

- [x] `SCOPE`, the four pills, and what the chosen scope compares, in a `ChromeBar` across the
      window between the title bar and the three panes
- [x] `Base | main · newest commit today ⇧⌘B` as a `FactBlock` at the right end, clickable, running
      the same command ⇧⌘B runs
- [x] `baseDetail` split out of `baseSummary` in the Git layer, so the block and the status line are
      one composition rather than two voices
- [x] The block is **dashed** unless the base is what is being compared
- [x] DEC-072 before the code; `24-…` gained the row and `FactBlock` in the same commit
- [x] 1628 → **1637 checks**; the `scope-row` arm asserts the frames, not the constraints

### Step 57 — why the row is where it is

Changing the scope changes the **file list**, and only then what the diff pane draws. The control sat
inside the diff pane, on the far side of the list it governs. A row across the window puts it above
the thing it changes, which is the same argument DEC-058 made four times about facts and the things
they are about.

The mode and lens switches stay in the diff pane's band. They *are* about that pane.

### Step 57 — the dashed rim is the decision, not the styling

`newest commit today` sitting in the same row as `HEAD ↔ working tree` reads as a statement about
what is on screen. It is not one: it is a fact about a ref nothing on screen is being compared
against. So the block is drawn **dashed** whenever the scope is not `vs base` — and whenever a
History selection has named its own two sides, which is the same condition read honestly.

Dashed already means *this is a different kind of thing* twice in this window: `PillControl` dashes a
scope that cannot be chosen, `ChipView` dashes an ahead-count that is unknown. Both for DEC-035's
reason — it survives greyscale. This is the third, and `ChromeLabels.baseBlock` decides it, so
whether the rim is dashed is a claim the suite asks about rather than a branch inside `draw`.

### Step 57 — reading a picture, again

The crop tool used to look at step 56's window measures its offsets **from the centre**, so
`--cropOffset 0 0` returned the middle of the window while looking exactly like a top-left crop. That
is M9-G's lesson in its third costume: not a downscaled picture this time, and not the wrong moment,
but the wrong *region*, arrived at by trusting a flag's name. `Scripts`-adjacent throwaway: a six-line
Swift cropper that takes pixels from the top-left and prints what it cut, in the scratch directory.
**A tool that can silently return a different rectangle than you asked for is a measurement
instrument, and it needs the same suspicion as the numbers.**

## Step 58 — every pill prints its key, an empty scope says so, and the keyboard driver was wrong

- [x] `⇧⌘1` … `⇧⌘4` on the scope pills, `⌘1` … `⌘3` on the modes, `⌃⌘D/B/H` on the lenses — all from
      `KeyboardMap`, none typed beside the control
- [x] `Staged — nothing staged`: the third scope state, in the same `title — reason` shape the
      unavailable state already uses, worded per scope in the Git layer
- [x] The four scope words come from `ComparisonScope.shortTitle` — they were literals beside the
      control until the empty sentence needed the same word
- [x] DEC-073 before the code; 1637 → **1646 checks**, two of them negative controls
- [x] Two live arms: every printed key selects **its own** scope, and a repository with nothing
      changed since its one commit draws `All local — no local changes` with `0` in the header

### Step 58 — the arm reported a defect that was not there, twice, in opposite directions

The first version of the arm pressed ⇧⌘3 and landed on **Raw**. Read literally, that says three of
the four scope shortcuts are shadowed by the mode shortcuts and DEC-065's map has a collision
`KeyboardMap.collisions()` cannot see, because it compares shortcut strings and `⌘3 ≠ ⇧⌘3`.

It was the instrument. `NSEvent.keyEvent` was being handed `characters: "3"` while holding shift —
an event no keyboard produces — and AppKit matched it against the **⌘3** item while
`performKeyEquivalent` returned `true`. Correcting it to `#`/`#` produced the opposite false
conclusion: nothing fires at all.

Measured against a probe menu holding both items (`22-experiment-log.md` → **M9-J**): an event the
**system** builds from a virtual key code fires the right item every time, and *no* combination of
the two character fields does it by hand. With Command held, macOS reports the **unshifted**
character in `characters` and the **shifted** one in `charactersIgnoringModifiers` — the opposite of
the obvious guess, and still not enough on its own. So `press` builds its events with `CGEvent` where
the key code is known, and the codes live in the function rather than in its callers.

**Three instruments, three confident answers, two of them about the product.** T0's rule paid for a
fourth time: when a measurement disagrees with expectation, suspect the driver first — and when the
driver is a synthesized event, make the system build it.

### Step 58 — where the empty scope had to be proved

No scope of the 63-file fixture tree is empty: 63 local changes, 56 unstaged, 4 staged. Rather than
assert the sentence only in the suite, the arm builds a repository with one commit and nothing
changed since, and reads the row: `All local — no local changes`, with `0` in the changed-files
header. **The header's count and the row's sentence are two halves of one statement**, so the arm
asserts both — a `0` with no sentence is a list a reader cannot distinguish from a broken scan.

Nothing is claimed about the scopes that are *not* selected. Asking each of them costs three more Git
invocations per refresh for an answer that is stale as soon as the reader saves a file, and DEC-073
records the trigger that would reopen it: the moment a sweep computes those counts for another
reason, the design's own form — a state on every pill — is free.

## Step 59 — `Sources ⌄` in the title bar

- [x] The button beside the search field, opening the **whole** Sources menu: add a root, add a
      repository, remove a source, set the base branch
- [x] One builder for both pointer routes — the `+` on the repositories header asks it for the
      additions, the title bar asks it for everything
- [x] No new decision: DEC-071 wrote the rule and named this button as its second instance
- [x] 1646 → **1648 checks**; the live arm counts the menu's items against the map's bindings

### Step 59 — a button that opens an empty menu photographs as a button

The arm asserts the item **count** against `KeyboardMap.bindings(in: .sources)` and the item titles
against the map's titles, rather than asserting that a button exists. A pop-up whose menu came out
empty would look identical in every picture ever taken of this window — the M8-D lesson pointed at a
control instead of a list.

## Step 60 — group headers say where, in two words

- [x] `PACKAGES/APP-0…` rather than `packages/app-0/src/components/nested`: the first *n*
      components, upper-cased, lengthened for the whole list until no two headers are equal
- [x] `(repository root)` passed through; two groups differing only in case keep their paths
- [x] DEC-074 amends DEC-033; the rule lives in `FileGrouping.swift`, beside the grouping it labels
- [x] 1648 → **1655 checks**, including the uniqueness property over 200 generated lists

### Step 60 — the truncation was removing the answer

The header was the group key verbatim, and a 320 pt pane truncates from the head — so nine groups of
the fixture tree drew `…/components/nested`, nine times, and the component that tells them apart was
the one cut off. Shortening from the **tail** is the obvious fix and is the same defect written
deliberately: the negative control asserts that the last two components collapse all nine groups into
one header.

Front-anchored is right because that is where identity lives: in a monorepo the package is the first
component or two, and `src/components/…` is every group's tail. The file rows underneath show their
paths **relative to the group**, so between the two ends the reader has the whole path — and the
row's tooltip still carries it in full.

### Step 60 — uniqueness is what makes shortening safe

Any shortening can merge two groups into one header, and a merged header is a list that lies about
where its files are. So the depth is raised until every header in the list is distinct, and the
property is asserted over generated lists rather than over the four examples that motivated it —
`Set(titles.values).count == keys.count`, 200 times.

The one case the rule cannot fix is two keys differing only in case: `a/Web` and `a/web` are the same
word upper-cased at every depth. There the whole list keeps its paths, which is ugly and true.

## Step 61 — the status line says what the watcher is doing, and prints the keys the map binds

- [x] `● Watching · refreshed 4s ago` at the left, with whatever happened last beside it
- [x] The mode switch centred; the layout, `Wrap long lines` and the key legend at the right
- [x] The legend is composed from `KeyboardMap` and **disagrees with the design on purpose**
- [x] DEC-075 before the code; 1655 → **1666 checks**, three of them negative controls
- [x] Two live arms and one new guard: the bar's three fields, and `collapse-holds`

### Step 61 — the design's legend names a key that does something else

The design writes `⌥↑↓ change`. DEC-065 gives `⌥↑↓` to **files** and `⌘↑↓` to changes. A legend is a
promise about a keystroke, and one printed from a picture rather than from the map is exactly the
defect M8-P found in the tester packet — on a surface every reader sees rather than in a document a
tester reads once. So the legend is `⌘↑↓ change · ⌥↑↓ file · ⌘⏎ open in editor`, composed from the
bindings, and a check requires every modifier run in it to be a shortcut the map composes.

The layout pill carries **no** key, and that is the same rule read the other way: `⌥⌘→` is a toggle
between the two segments, not two bindings, and printing one keystroke on both reads as two keys that
happen to be equal.

### Step 61 — the watcher was only ever visible while failing

DEC-027 has watched the open repository since M7 and the reader was told about it only when it broke
— transiently, in a line the next message overwrote. *Nothing is happening* and *watching, nothing
has changed* looked identical, and every count in the window is as old as the last refresh with
nothing saying when that was.

`refreshed Ns ago` is stamped where the window actually re-reads the repository, not where an event
arrives: an event the debounce swallowed changed nothing on screen and must not reset the clock
(DEC-026). Before the first refresh the clause is absent rather than `0s`, because a window that has
never refreshed saying *refreshed 0s ago* is a false sentence about the thing the field exists to
make honest.

### Step 61 — the bar grew the window, and the collapse it broke had never been laid out twice

Centring the modes with a **required** constraint, against a right-hand group pinned to the bar's
trailing edge, makes the bar's minimum width twice that group plus the pills. Auto Layout satisfied
it the only way it could: the window opened **1472 pt wide** against `Theme.windowWidth = 1400`, and
nothing was logged because nothing was unsatisfiable. The split view redistributed the extra width,
and ⌃⌘0 then collapsed the rail and left the file spine at 320.

The centring is a preference now (priority 500) with required inequalities keeping the pills clear of
both neighbours. But the second finding is the one worth keeping: **nothing in this window had ever
laid out again after a collapse**, so a collapse that a later layout pass undoes was a defect no
check could have seen. The ticking status line is the first thing that lays out while the panes are
collapsed. `collapse-holds` now re-measures 1.5 s later, across at least one tick.
`22-experiment-log.md` → **M9-K**.

### Step 61 — and the legend has to be drawn in full

`⌘⏎ open in…` is a keystroke with its purpose cut off, which is worse than no legend. The arm asks
what the label *needs* against what it *got* — the only form of the question a picture cannot
disagree with — and the first answer was 253 pt needed against 214 given, which is how the duplicate
key on the layout pill came to be removed.

## Step 62 — light mode was photographed for the first time, and the faint ink does not clear contrast on half the chrome

- [x] The whole selftest run in **light appearance** (`-NSRequiresAquaSystemAppearance YES`, a launch
      argument — no code, no system setting touched)
- [x] Every neutral surface measured against the token table rather than looked at: title bar
      `#ececed`, repository pane `#f6f6f8`, file pane `#fbfbfd`, selected row `#e3e3e8`, trough
      `#e8e8ec`, thumb and code `#ffffff` — all exactly the declared light values
- [x] **Defect found and fixed:** `--ds-faint` is under 4.5:1 on four of the surfaces it was drawn on
- [x] A check now holds every ink/surface pair the chrome draws to 4.5:1 **in both appearances**,
      with the design's own first draft (2.7:1) as one control and the pair that prompted it as the
      other

### Step 62 — the contrast correction had only ever been measured against the paper

`27-…` §3 records the adopted design's tertiary text failing at 2.7:1 and being *fixed by measurement,
not by eye*. The corrected pair was measured against `--ds-bg`. The chrome has four other surfaces,
and nothing had ever measured those:

| Pair | Light | Dark |
|---|---|---|
| faint on `--ds-chrome` — the SCOPE caption, the key legend, the base block, the title-bar path | **4.47** | 5.01 |
| faint on `--ds-control-trough` — every key hint, every pill not chosen, every unavailable scope | **4.32** | 4.81 |
| faint on `--ds-row-selected` — a selected repository's path | **4.12** | 4.66 |
| faint on `--ds-control-thumb` — a hint on the chosen pill | 5.28 | **3.47** |
| faint on `--ds-panel-repos` / `--ds-panel-files` — the two column captions | 4.89 / 5.10 | 5.45 / 5.34 |

Three of those four are labels **step 58 and step 61 added**, which is the honest way to put it: the
key hints and the legend went onto a surface the ink had never been measured against.

**The palette is not changed** — that is the design's own table and the product owner's to alter. The
labels move to `--ds-dim` (6.3–7.7:1 everywhere it is drawn), and `--ds-faint` is now drawn on the two
panel surfaces and nowhere else. The alternative — darkening the token so the third step is usable
everywhere — is a one-line change to the table and is a question for the owner rather than an answer.

### Step 62 — a single pixel is not a measurement either

The first sample of the selected row returned `#ececed`, which is the chrome's colour and not the
row's: the box straddled the pane boundary, 1180 px into a file pane that ends at 1200. Same family
as the crop tool that measures its offsets from the centre (step 57). The probe now reports **the
modal colour of a box and its share** — `#f6f6f8 100% of 300×60 px` is a statement about a surface;
one pixel is a statement about wherever that pixel happened to land.

## Step 63 — the tertiary ink is re-sized against every surface, and a pane inside a split view stops using constraints

- [x] `--ds-faint` → `#62626b` light, `#9e9ea7` dark (DEC-076), mirrored in `Theme.swift`, bundle rebuilt
- [x] Step 62's substitutions reverted: the key hints, the legend, the `SCOPE` caption, the base
      block's keystroke and a repository's path are tertiary again, as the design draws them
- [x] The contrast check covers the restored pairs and the diff pane's three surfaces; its control is
      now the **previous value as a literal**, so the fix cannot satisfy the check that caught it
- [x] A second assertion holds the third ink a step away from the second — 1.34:1 light, 1.13:1 dark
- [x] **Second defect found and fixed:** the changed-file list stayed 320 pt wide inside a 34 pt
      collapsed pane. `22-experiment-log.md` → **M9-L**
- [x] 1670 → **1673 checks**; six clean runs of six

### Step 63 — why 4.7 and not 5.0

The binding surfaces are the extremes, not the paper: `--ds-row-selected` in light and
`--ds-control-thumb` in dark — the raised thumb is a *light* surface inside a dark window, so an ink
that clears it must be nearly as bright as `--ds-dim`. At a 5.0 target the dark value lands at
`#a3a3ac`, **1.06:1 from `--ds-dim`**: three inks that read as two. At 4.7 every surface clears
4.72:1 and the step survives. Both numbers are in DEC-076, and the check asserts the second one so
the trade-off cannot be lost by someone tightening the first.

### Step 63 — three wrong answers, then one stack trace

The collapse defect was reasoned about three times and each answer was wrong: a holding priority
(changed nothing), a stack view with a width constraint (320 in a 34 pt pane, five runs of five), a
hand layout in `layout()` (never called — a split view resizes by **frame**, which runs autoresizing,
not layout). A scroll-view subclass logging its own `setFrameSize` with a stack trace answered it in
one run:

```
320 -> 34: … NSViewActuallyUpdateFrameFromLayoutEngine … resizeSubviewsWithOldSize: … FilePane.setFrameSize
```

`NSSplitView` sets a pane's frame directly and the **layout engine goes on valuing that pane's width
at the number its constraints last agreed on**, then re-applies it to the pane's children. A child
constrained to its parent's width is laid out against a width the parent no longer has.

**Inside a split view's pane, `bounds` is the only number that is true.** Third payment at this
boundary — after panes that began at zero width (M8-D) and a width constraint ignored at priority 600
(M9-A) — and the rule that survives all three is: ask the frame, place by hand, and place again after
the split has had its turn.

### Step 63 — and the contract check earned its keep

`FilePane` was a new `NSView` subclass, and the suite refused the build until it was in
`24-…` §3's chrome table. That check was written in step 56 against a table I had just filled in by
hand; this is the first time it caught something I had not thought about.

## Step 64 — the first tranche of DEC-077: the window says less, and three things that did not work now do

- [x] **The focus ring is gone** — DEC-070's option 2, offered then and chosen now. The arm is
      inverted: it asserts that *nothing* draws a ring, on the keyboard and after a click
- [x] **Keystrokes are off the screen** — the pill hints, the status line's legend, the base block's
      `⇧⌘B`, and one that had been there since M8: `no search results — ⌘F to search`
- [x] **The dividers drag again**, and each pane header carries a chevron that folds it
- [x] **The open repository is the selected row**, with a bar at its leading edge
- [x] DEC-077 written first; 1673 → **1659 checks** (the hint and legend checks are gone; three new
      ones took their place)

### Step 64 — why the count went *down*, and what replaced it

Fourteen checks went with the features they described. What replaced them keeps the intent:

**A keystroke may still be composed — a tooltip, the menu bar — and it must still come from
`KeyboardMap`. What may not happen is a modifier run written by hand.** The check reads every string
in the five files that compose chrome copy and refuses one containing `⌃⌥⇧⌘`, with the selftest's own
log lines and the arm's character set exempted by name rather than by a pattern nobody can read.

It found one on its first run: `"no search results — ⌘F to search"`, sitting in the status line since
M8. The features were removed by hand; the check found the one the hand missed.

### Step 64 — the divider refused to move because the collapse made it obey

The two pane widths are constraints at priority 999 so that ⌃⌘0 cannot be ignored — and that is
exactly what refused a drag: the split moves the divider, the next layout pass restores the constant,
and the pane snaps back. The owner saw the resize cursor and nothing else.

`splitViewDidResizeSubviews` now writes the drawn widths **back into the constants**, guarded by a
flag while a collapse is animating — otherwise the collapse writes its own intermediate widths back
and fights itself. And because a divider is a thing you have to know to drag, each header carries a
chevron pointing the way its pane will go.

### Step 64 — `repoSelected=-1`

The repository list had **no selected row at all** while a repository was open: the selection was set
only when nothing was open, and every sweep replaces the snapshots with new objects. So after the
first refresh the window was showing a repository's diff with nothing in the list saying which one —
the owner's *"nie jest zaznaczone repo z którego aktualnie korzystam"*, and it is a defect rather
than a styling gap. The sweep re-selects by path now, the arm asserts a selected row, and the row is
marked by a **bar at its leading edge** as well as by a fill one step of grey from the panel.

## Step 65 — the documents catch up, and one of them had been lying to a stranger

- [x] **New:** `28-interface-plan.md` — the ten items DEC-077 leaves, each with what it reverses,
      what will refuse it, and **how to prove it is done**
- [x] `23a-poc-report.md` §10 audited: **four of its five interface gaps were closed** while the
      section still told a tester not to report them
- [x] `27-…` gains §4b: *nothing is outstanding* has now been written twice and been wrong twice
- [x] `24-…` carries a table of what DEC-077 changes and how much of it has landed
- [x] `23-…` G1 says the owner's two sessions happened, and why its boxes are still unticked
- [x] `21-…` §0 and both file maps; `00-index.md`

### Step 65 — the worst of the four was an instruction, not a description

`23a-…` §10 is headed *"please do not report these"*. It listed the base-branch override (built as
⇧⌘B on 2026-07-31), the missing keyboard navigation of the file list (built 2026-08-09 and measured
over 63 files), and the mode pill disagreeing with the path taken (DEC-058, and since removed
outright by DEC-077). A stale description wastes a reader's minute; a stale instruction spends a
tester's session on silence about things that work.

The one that survived the audit is real and small: `EditorCommand.defaultTemplate` is still
`/usr/bin/open -a WebStorm {file}` — **no `{line}`** — so ⌘⏎ opens the file at the top until the
reader configures a template.

### Step 65 — and *nothing is outstanding* is a sentence no document here can carry

`27-…` §4a wrote it on 2026-08-09; the owner's first session disproved it on the 12th. §0 corrected
that, and the second session disproved the correction on the 13th. The thing both were measured
against is a design behind a login that nobody in this repository can open.

So `27-…` now says what it can honestly say — **which decisions the design produced** — and what is
left to build lives in `28-…`, which is a list with acceptance tests rather than an adjective.

## Step 66 — `28-…` item 1: the underlines come out of the diff and a tint pair goes in

- [x] `--ds-tint-line` / `--ds-tint-seg` (neutral, two-pane) and `--ds-tint-add-strong` /
      `--ds-tint-del-strong` (unified) declared in both appearances
- [x] `ds-line-changed`, a **line** decoration, so the tint reaches the whole line box
- [x] every `text-decoration` gone from the seven change classes; `--ds-underline-thickness` and
      its quiet twin gone from the token file
- [x] `DesignChecks` measures all three pairs over `--ds-code` in both appearances, with two
      negative controls; `background-image: var(--ds-tex…)` added to the shape list
- [x] the selftest holds `tintedLines == gutterChanged` — two carriers of one fact, one source
- [x] `24-…`, `12-…` §5.1 and `28-…` item 1 record it

### Step 66 — the control that would have passed

The first negative control paired the design's own green and red at the alphas they ship at, and
measured **1.289:1** apart — above the 1.20 floor, so it would have *passed the check it exists to
fail*. The red's alpha is solved for instead: green at .20 and red at .15 land on the same relative
luminance over paper, and the control now reads 1.00:1. **A control is only a control once it has
been shown to fail**, and this one had to be measured before it did.

The shipped pairs measure 1.27:1 (neutral, light), 1.37:1 (neutral, dark), 1.34:1 and 1.53:1 (added,
light and dark), 1.46:1 and 1.31:1 (removed) — and each line tint is held 1.05:1 off the paper as
well, because a line tint the surface swallows is a changed line nobody sees, which a distinct byte
tint would not repair.

### Step 66 — where the shape rule actually lived

`DesignChecks`'s greyscale list had `text-decoration` and `background: repeating-linear-gradient` in
it, and the textures are declared as `background-image: var(--ds-tex-…)` — so **every mark had been
passing on its underline**, and the texture that was supposed to be the other carrier had never once
satisfied the check. Removing the underlines failed six marks at a stroke and said so. The list now
names the form the textures are actually written in, and the underline's own rule moves to the
luminance measurement rather than disappearing with it.

## Step 67 — `28-…` item 2: the tint reaches the right edge, and the pictures stop lying

- [x] `#unified` gains `flex-direction: column` — the layout switch sets `display: flex`, which had
      made it a row container whose single item was as wide as its content
- [x] `diffscopeWidths` reports host, scroller, gutters, every line box and the gutter/line pairing
- [x] a selftest arm asserting `minLine == maxLine == available` **and `scroller == host`**, at two
      window widths, with the missing `flex-direction` injected back as the control
- [x] `diffscopeSettle` forces CodeMirror's pending measurement before every snapshot
- [x] `28-…` item 2 records both the fix and the artifact

### Step 67 — the control passed, again

Injecting `flex-direction: row` back shrinks the scroller **and** the lines together, so `minLine ==
maxLine == available` still held while the pane sat half empty. Two items in a row the first control
has been satisfied by the defect it was written to catch. The rule that comes out of it: **measure
the thing against what it is supposed to fill, not against itself.** The editor is now compared with
its host as well.

### Step 67 — eleven of fourteen lines had no gutter row, and it was the instrument

The width probe also reported a vertical drift between the number columns and the code, and a
full-resolution crop appeared to confirm it — rows 17 px apart against lines at 15. It is not real.
**CodeMirror re-measures inside an animation frame and `requestAnimationFrame` is suspended while
the window is occluded**, which a terminal-launched selftest always is (T1-A, for the third time in
this project). Each view keeps whatever line height it was constructed with — 14 px for the two
panes, 16.87 for unified — and the *gutter rows* are sized from that number while the lines are laid
out by CSS. Reading a coordinate forces the pending measurement: rows go to 15 px and
`lines-with-no-row` goes to 0.

So **every unified snapshot taken before today has a number column in it that drifts a whole line by
the sixth row, and no reader has ever seen it.** `snapshot(named:)` settles the views first now.

Two changes made while chasing the wrong cause were kept and are recorded as having fixed nothing
observable: the unified view is built after its host is shown rather than inside a `display: none`
element, and `.cm-content` joins the two elements that already share `--ds-line-height`. Both are
right; neither was the bug.

## Step 68 — `28-…` item 3: the horizontal track goes away when it cannot be used

- [x] `updateTrack` sets `hidden` beside `disabled`; `#track[hidden] { display: none }`
- [x] `--ds-track-idle` removed — nothing references it any more
- [x] `diffscopeTrackState`, and an arm that asserts **both** halves on a two-line file of three
      characters and three hundred: present with wrapping off, absent with wrapping on
- [x] the span is read from the layout that is showing, and the unified scroller drives the track
- [x] `24-…`'s DEC-077 table and its `#track` row rewritten in the same commit

### Step 68 — dimming had been hiding a missing control

`updateTrack` took its span from `left.scrollDOM` whatever layout was drawn. **Unified — the default
since DEC-059 — therefore reported nothing to scroll however long its lines were**, so the one
column had no keyboard-reachable horizontal control at all, which is the whole reason `12-…` §5.4
asks for a range input instead of a scrollbar. While the track merely dimmed, that looked like a
quiet control; the moment it disappears it is a missing one.

Toggling wrap is the only act that creates something to scroll to without changing the document, so
it updates the track — and settles the views first, because the widths it decides from are only
right once the pending measurement has been read (step 67).

## Step 69 — `28-…` item 4: ⌘E goes both ways (DEC-078)

- [x] **DEC-078 written before the code**, amending DEC-017: one command, both directions
- [x] `expandAll` collapses when every fold is already open, expands otherwise
- [x] the footer button reads `Expand` or `Collapse`, recomputed with the footer, and is dropped
      entirely when there is nothing folded
- [x] the menu item is `Expand or Collapse All Ranges`, naming the toggle rather than one direction
- [x] a live arm asserting the **round trip** — `2 → 0 → 2` folds, `Expand → Collapse → Expand`
- [x] three source checks with two negative controls

### Step 69 — *everything is open*, not *anything is open*

The rule that decides which way ⌘E goes is that **every** fold is already expanded. `goToStop` opens
whatever fold covers the line it jumps to, and a reader can click one open — under an *anything*
rule either of those would turn the next ⌘E into a collapse, which is not the reading of the key
they have. Under the *everything* rule it opens the rest, and the second press closes them all.

### Step 69 — the keystroke rule had a hole the size of the diff pane

The button's label was `Expand ⌘E`. DEC-077 took keystrokes off the interface and the check written
for it reads `ChromeLabels` and the AppKit chrome — **nothing was looking at the webview's own
markup**, which is where the one remaining printed keystroke was. A check now refuses a modifier run
in `index.html`, with comments stripped first and that label as its negative control.

1666 → 1672 checks.

## Step 70 — `28-…` item 5: the jargon goes, and INV-4 keeps its one sentence

- [x] `parser:`, `confidence:` and `mode:` are not drawn — every one of them still computed, still
      encoded, still asserted in `TrustSurfaceChecks`
- [x] `fallbackNotice` / `discardedNotice` reworded: *This file is shown as plain text — <why>.
      Every difference in it is still shown.* — `13-…` §6's three parts, DEC-077's words
- [x] `ParserStateReport.plainSentence` for the one case with no notice behind it: a partial parse
- [x] confidence speaks only below the floor, in the reader's words
- [x] the structural selftest arm is **inverted** — it now asserts the chips are absent
- [x] `12-…` §5.2, `13-…` §6, `25-…`, `24-…` and `28-…` item 5

### Step 70 — the fallback was saying one thing three times

A file that could not be read as code drew the fallback notice, **and** `parser: not parsed — …`,
**and** `mode: structural — showing raw`. Three overlapping wordings of one fact, each in the
vocabulary of the part of the machine that produced it. It is one sentence now, and `23b-…` §2's
defect — the mode pill reporting the selection alone — cannot recur, because the pill is not drawn.

### Step 70 — and the new sentence immediately duplicated an old chip

`2 parts of this file could not be matched confidently` landed beside `uncertain: 2 shown`, which is
the same fact in the matcher's words. The chip is gone: DEC-017's disclosed count is about
**grouping**, which hides something, and an uncertain alignment hides nothing — it is marked on the
line it is on. Found by looking at the picture, which is the only place the two appeared together.

1673 → 1680 checks.

## Step 71 — `28-…` item 6: the switches are made of the system's glass

- [x] the raised pill is `NSGlassEffectView` (`style = .regular`, `cornerRadius` from the pill
      tokens) with the chosen segment's title as its `contentView`
- [x] inside `NSGlassEffectContainerView`, `spacing` from `Theme.glassMergeSpacing` — the merge is
      the system's, and it is the seam items 7 and 8 will need
- [x] all of it behind `guard #available(macOS 26, *)`; the drawn pill still runs below that
- [x] a check refuses `NSVisualEffectView`, a blur filter or a blending mode anywhere in the chrome
- [x] a live arm: real AppKit by class name, covering the chosen segment and only it, not raised
      when that segment is unavailable, title inside the glass with the right words

### Step 71 — `contentView` is filled by what you give it

Handing `NSGlassEffectContainerView.contentView` the glass view directly makes the glass the size of
the container — the picture showed **one solid pill across all four scopes with the labels behind
it**. The container's `contentView` is the *host* of the glass, not the glass: a plain transparent
view goes there and the thumb is placed inside it by frame.

### Step 71 — the material cannot be photographed on this machine

`cacheDisplay` renders an `NSGlassEffectView` as a flat fill, exactly as it renders a `WKWebView` as
black; the window-server path needs screen-recording permission **and** an unoccluded window, and a
terminal-launched selftest is neither. So half of item 6's acceptance test cannot be met here and it
is written down as unmet rather than declared done.

What the arm asserts instead is what a photograph could not have settled: the class is AppKit's own,
the thumb covers the chosen segment and nothing more, it is not raised when that segment is
unavailable — and **the title is inside the glass, with the right words and a non-zero frame**,
which is the one failure a flat capture could have been hiding. **Ask the owner for a screenshot of
the scope row in both appearances.**

### Step 71 — and the keyboard walk's own arm had been red

`status-bar` was failing before any of this work — pre-existing on `410bc41`, and not mentioned in
the handoff. It compares the watcher's sentence against `ChromeLabels.watcherStatus` for the current
age **within a second either side**, and the keyboard walk holds the run loop for 63 files, so no
tick fires while it runs and the label read straight afterwards is three seconds behind the clock.
The window is now every age from zero to the elapsed time, which keeps what the arm is for — the
sentence comes from `ChromeLabels` and not from a string written by hand — and stops it being a
check about the scheduler. Its log line also printed three of `ok`'s six terms; it prints all six.

1680 → 1688 checks.

## Step 72 — `28-…` item 7: a switch shows one option and keeps the rest in a popover

- [x] `PillControl` draws the chosen option, the glass thumb and a chevron
- [x] `SegmentList` in an `NSPopover`: every option, the chosen one marked by a glyph **and** a
      weight, an unavailable one dashed with its reason underneath
- [x] sized to the **widest** option so choosing never moves the row (scope: 268 pt → 92 pt)
- [x] `optionsReport`, and an arm that drives `selectMode(_:)` — the selector ⌘1 drives — **while
      the scope popover is open**
- [x] `SegmentList` added to `24-…` in the same commit; four source checks with a control

### Step 72 — the reason had nowhere to go until now

`12-…` §3 requires an unavailable scope to be disabled *with its reason*. In a four-segment control
that reason could only be a tooltip and a status-line message, because there was no room for it. A
row in a popover has a second line, so the reason is drawn where the option is: `vs base` sits above
`no upstream branch is configured`, dashed, and the arm reads that string out of the open list.

1688 → 1692 checks.

## Step 73 — `28-…` item 8: the motion register becomes a list (DEC-079)

- [x] **DEC-079 before the code**: the register moves from the adopted design's Motion table — which
      is behind the owner's login — into `24-…` §5, where a check can read it
- [x] a check in both directions: a transition with no row fails, a row with nothing behind it fails
- [x] five rows added to the three that existed: the footer button and a lens row under the pointer,
      the pane collapse (built but unregistered), a switch's options arriving, the chosen option
      changing
- [x] the chrome's guard check **counts** now — as many `accessibilityDisplayShouldReduceMotion`
      reads as animated sites, with an unguarded site as its control

### Step 73 — the register was a promise about a document

DEC-064 replaced a guarantee by construction with a guarantee by check, and the check had two halves.
The reduced-motion half was built and carries two negative controls. **The register half was never
enforceable**: it lived in a table nobody in this repository can open, so *is this transition
registered* was a question with no answer, and three transitions shipped against a list of none.

### Step 73 — and the guard check was satisfied by one file

*Does the chrome read `accessibilityDisplayShouldReduceMotion`* was answered by a single `contains`
over `main.swift`, and it stayed true while a second and a third animated site were added elsewhere.
That is DEC-064's own named failure mode — remembered for the first five transitions, forgotten for
the sixth — written into the check that exists to prevent it.

### Step 73 — the reduced-motion path cannot be photographed here

It is a system setting, and the contract forbids a preference of our own that could disagree with it,
so a selftest cannot turn it on — and adding a switch to make the picture possible would break the
rule the picture exists to prove. What the path produces is in every case a static state that is
already photographed: the pane at the other width, the list simply present, the other title with
nothing in between. Recorded as unmet rather than worked around.

The first negative control for the register check was `!registered.contains(".ds-invented…")`, which
proves the array and not the check. It runs the extraction over a hostile stylesheet now — the third
time in this session a control had to be made to fail before it was worth having.

1692 → 1698 checks.

## Step 74 — `28-…` item 9: the four surfaces become a ladder (DEC-080)

- [x] **DEC-080 before the code** — the first change to a value transcribed from the design
- [x] light `#ffffff → #f2f2f6 → #e6e6ed → #d9d9e1`, dark `#000000 → #131317 → #1e1e25 → #26262d`
- [x] `--ds-row-selected`, `--ds-row-ring`, `--ds-bg`, `--ds-fold`, `--ds-control-trough` and
      `--ds-empty-bg` move with them; `Theme.swift` mirrors all of it
- [x] DEC-076's arithmetic redone: light's second and third inks are `#42424a` and `#57575f`, and
      every ink/surface pair clears 4.91:1 light / 4.72:1 dark
- [x] a check with two claims — every step ≥ 1.10:1, and the ladder runs one way — and two controls
- [x] greyscale screenshots in both appearances, and the modal colour of a box per region measured

### Step 74 — nothing had ever asked whether two surfaces differ

Every colour check here is about **ink on a surface**: twenty-one pairs held to 4.5:1, three inks
held a step apart. No check, and no sentence in any document, had ever compared one surface with
another — so the four regions could sit nineteen values apart out of 255 and every gate stayed green.

The dark half was worse than flat: **the ladder was not monotone.** The repository pane was darker
than the file pane, with the chrome above both lighter than either, so the window had no consistent
sense of front and back. A step-size check alone would have passed that, which is why the direction
is asserted separately and has the old ordering as its control.

## Step 75 — `28-…` item 10: the file-kind glyphs get colour (DEC-081)

- [x] **DEC-081 before the code**: colour is the second carrier, the glyph stays the first
- [x] four tokens in both appearances, mirrored in `Theme.swift`, on the glyph **and** on the
      collapsed spine's bar
- [x] untracked, type-changed and unmerged keep the ordinary ink rather than being given a hue to
      fill the table
- [x] twelve new pairs in the contrast list — a row is drawn on three surfaces — passing 4.51:1 to
      7.44:1
- [x] a check that the seven glyphs are still seven different characters, with a shared glyph as its
      control; greyscale screenshots in both appearances

### Step 75 — the mirror check reads token names literally

`Theme.swift`'s doc comment wrote the four tokens as `--ds-kind-added` / `-modified` / `-deleted` /
`-renamed`, and the `@chrome` mirror check — which looks for each token's **full name** in that file
— reported three of the four as unmirrored. The shorthand was for a human reader; the check is the
other reader of that comment.

1704 → 1707 checks.

## Step 76 — `28-…` §3: ⌘⏎ opens the line (DEC-082)

- [x] the mechanism **measured before the decision** — `22-…` → M10-A
- [x] `EditorCommand.defaultTemplate` is `/Applications/WebStorm.app/Contents/MacOS/webstorm
      --line {line} {file}`
- [x] three checks: the default carries both tokens, it produces the right argv over a path holding
      `#`, `?` and a space, and the template it replaced is the negative control
- [x] `23a-…` §10 and `23b-…` §1.6 closed — the last open item of both
- [x] `25-…` corrected on both sides: the line *is* opened, and the silence when it cannot be

### Step 76 — *one line to fix* was written twice and was wrong twice

It is one line. But `open -a` cannot take a line number at all, so the string was never the question —
the mechanism was, and the mechanism is a fact about what is installed.

The `jetbrains://` URL was the obvious answer and it is the wrong one, for a reason no amount of
reading would have produced: **`open` percent-encodes a space, a `%` and non-ASCII for you and
leaves `#` and `?` raw.** Both are legal in a path, and the result is the wrong file opened with a
zero exit code — *silent and wrong*, which is the failure this whole product is built against.

### Step 76 — and the chosen mechanism's limit is on record

The launcher returns 0 for a file that does not exist and for `--line notanumber`. So `launchEditor`
cannot tell *opened* from *forwarded and ignored*. That limit is written into DEC-082 and into the
tester packet rather than left for a tester to discover, and it is narrower than the URL's: the only
way to reach it is a file that is not there, and the file being opened is the one the diff has just
read. The failure that can really happen — WebStorm somewhere else — throws in `Process.run()` and
reaches the status line.

**The half no exit code answers** is whether the caret lands on the line. Only the owner can see that.

1707 → 1710 checks.

## Step 77 — `18-…`'s definition of done audited, item by item

- [x] all eight items given **what backs them** and **what a signature would claim beyond that**
- [x] three sentences corrected where the evidence was always there and the wording over-claimed
      (items 1, 3, 7)
- [x] one real gap found and closed (item 2), with a new static check and a negative control
- [x] items 4, 5, 8 signed as written; item 6 unchanged

### Step 77 — the gap: R-8's closing check runs in the wrong binary

*Every operation executed during this run appears in the proven registry* is **dynamic** — bounded by
what the verify run happens to exercise — and it runs inside `diffscope-verify`, which is not the
binary that ships. It could never observe a path in the **application** that spawns git for itself.

There is one. `emptyScopeSelftest` runs `init`, `config`, `add` and `commit` through a raw `Process`,
because the empty-scope state cannot be reached any other honest way; it is compiled into the shipped
binary and gated at runtime by an environment variable. It writes only into a directory it creates
under `NSTemporaryDirectory()`, so item 8's claim was **true** — and **unproven**, which is the
distinction this audit exists to make.

Closed by a static check: the application shell spawns git from exactly one place, that place is the
named arm, and it writes under the temporary path. A second call site fails. The exemption is named
the way the `@chrome` token block is named — a redirect, not a hole.

### Step 77 — three sentences claimed more than their checks

- **1 and 7** said *every fixture*. Thirteen fixtures never reach the structural path — not valid
  UTF-8, unsupported language, a merge-conflict marker, binary content — and pass on the only path
  they have. The skips are printed by name and reason on every run; the sentences now say so.
- **3** said the wrapper case *reads as a wrapper change*. That promises a reading the interface
  **deliberately does not draw**: `24-…` records *wrapper removed* as prose with nothing behind it,
  because `label`, `classification`, `group`, `disclosure` and `link` are the engine's whole
  vocabulary. The sentence now says what is proven — children preserved, wrapper marked.

**Item 4 is the model the other seven should be read against.** It does not rest on its own fixture:
T-4 — *no-change is shown exactly when the sides are byte-equal* — is asserted on all 55 fixtures on
every path they reach, so a model that reported "no change" for a non-identical pair fails 55 times.
A definition-of-done item is strongest when the fixture that names it is not the thing proving it.

1710 → 1713 checks.

## Step 78 — the two P1 fixtures §4.5 had named and never had

- [x] `moved-jsx-subtree` — a `<Legend>` subtree relocated above the `<table>` it followed
- [x] `multiple-similar-siblings` — a near-identical `<Item />` inserted among three others
- [x] both recorded in `MANIFEST.json`, both through T-0…T-11 on both paths
- [x] T-11's three shape lists are **printed** now, not only asserted
- [x] `15-…` and `18-…` updated: every P0 **and** P1 case in the plan exists

1713 → **1748 checks**. Every P0 and P1 case named in the plan is now built; the six that remain
are P2, for languages version one does not parse.

### Step 78 — the first `moved-jsx-subtree` produced no move at all

It swapped a nine-line `<table>` with a ten-line `<aside>`, both full of `{xs.map((x) => (` and
`key={x.id}`, and measured **62 hunks / 272B and zero moves**. Two blocks of the same shape share
so much line-internal text that the canonical diff interleaves them instead of deleting one and
inserting it elsewhere — so no line is wholly inside a changed run and there is nothing to pair.

The rebuilt fixture moves a subtree that is *lexically unlike* what it moves past, and produces
`2 hunks/192B, 1 move` spanning several lines.

### Step 78 — and it pairs only the text lines, which is the finding

```
old 272..<296 changed "\n      <Legend>\n        "
old 296..<317 moved   "Reported by DiffScope"
old 326..<352 moved   "Warsaw office, third floor"
old 352..<367 changed "\n      </Legend"
```

`<Legend>` and `</Legend>` are **changed, not moved**: DEC-038 pairs a line only when its trimmed
content lies entirely inside a changed run, and a tag's `<` is matched as unchanged against the
`<table>`/`<tbody>`/`<tr>` it moved past. **One byte of common prefix disqualifies the line.**

This is `moved-function`'s trap reproduced in JSX, and JSX makes it the normal case rather than the
unlucky one — every line begins with `<` or `{`. Nothing is lost when it happens: the unpaired
lines are still presented as changed (T-3), and a move regroups what is presented rather than
removing it.

### Step 78 — the siblings fixture changes nothing on the old side

The whole difference is two segments, **both on the new side**. No existing sibling is claimed to
have been edited. And the boundary is not where a reader would draw it: the minimal edit aligns the
new row's `<Item icon="` with the *first* row's prefix, so the change is charged to the tail of the
new row plus the head of the row after it. Recorded rather than "fixed" — snapping to node
boundaries for tidiness is a claim the engine cannot make (DEC-024, INV-1).

### Step 78 — and T-11's three lists were passing without saying on what

*the corpus contains a fixture that produces a move* / *one whose move spans several lines* / *one
that produces two independent moves* each passed on one fixture and the output never named it. A
fixture added **for** T-11 could stop producing a move and the section would still read green,
carried by an older one. The names are printed now: moves on four fixtures, multi-line on three,
two-or-more on one.

## Step 79 — `28-…` §5 items 1 and 2: the selected file, and three surfaces on one line

- [x] `restoreFileSelection()` on every path that rebuilds `state.fileRows`, matched **by path**
- [x] `Theme.paneHeaderHeight` sized to the control it holds (`pillHeight + 2·space2` = 32 pt) and
      the diff pane's band built from that one number instead of three
- [x] `setCustomSpacing(0, after: repoHeader)` — the third pane was 4 pt lower than the other two
- [x] two arms: `file-selected` with a control that clears the row first, and `pane-headers`
      extended to compare the three panes' **drawn tops** in window coordinates

### Step 79 — the file list's selection had no product path at all

`fileTable.selectRowIndexes` appeared three times and **all three were in the selftest**. So every
walk set the selection it then measured — a check asking what it had just asked for, the shape
`23b-…` §2 records for the unified layout. The new arm asks the other way round: the pane is told
which file to show, the list is rebuilt from Git, and only then is the row read. Its control drops
the selection first and requires the arm to see it gone.

Matched by **path**, not by index: a sweep reorders and regroups, so the row a file was on is not
the row it is on now, and restoring the old index would mark the wrong file.

### Step 79 — 18 pt, then 4 pt

The diff pane's band was `space4 + pill + space4` = 40 pt against two 22 pt headers, so the code's
background began 18 pt below the lists'. One number for all three fixes that — and the number had to
grow to 32, because a 24 pt pill does not fit in 22 and the third pane's header holds a control.

Aligning two of them then exposed the third: the repository pane is an `NSStackView` whose 4 pt
spacing applied between the header and the list, where the file pane's hand layout has no gap. Two
surfaces agreeing from one constant is not evidence that a third agrees with them — which is why the
arm measures **drawn tops in window coordinates** rather than the constant it set.

## Step 80 — `28-…` §5 item 3: things that can be clicked say so, and can be hit

- [x] `cursor: pointer` on every clickable element in both webviews; `#track` gets `grab`/`grabbing`
- [x] `HandButton` — `pointingHand` and a **24 × 24 pt floor** — on the `+`, both chevrons and
      `Sources ⌄`; `resetCursorRects` on `PillControl` and on `SegmentList`
- [x] the `pane-headers` arm measures the three targets from their **drawn frames**
- [x] six source checks with two controls; `HandButton` added to `24-…` in the same commit

### Step 80 — two elements advertised themselves as **not** clickable

`.ds-term-tab` and `#mode` in the terminal both said `cursor: default` while both carried a click
handler — a tab that switches shells and a chip that forces raw mode. That is worse than a missing
declaration: it is the interface saying *this does nothing*, in the one pane where a wrong keystroke
goes to a shell. The check asserts both directions now — every clickable selector declares
`pointer`, and none of them declares `default`.

### Step 80 — the floor cost eight points, and the rail paid differently

A 24 pt target beside a 12 pt count does not fit in a 34 pt spine, so **`spineWidth` is 42**. The
rail beside it holds *two* targets and would have gone to 66 — a third of the width the collapse
exists to give back — so there the `+` leaves the rail instead and the chevron stays: adding a
source has two other pointer routes (`Sources ⌄`, the menu bar) and the chevron, which is the way
back, has none.

Both numbers are in the token file with the reason beside them. A floor with no stated cost is a
floor somebody quietly lowers later.

### Step 80 — and the subclass check had a hole I walked straight through

*Every view the chrome draws is described in the contract* was matching the literal string
`NSView`, so `HandButton: NSButton` passed without a contract row. The pattern takes `NSButton` and
`NSControl` now. **The check that exists to catch a new view missed the first new view added after
it was written**, which is the same shape as the greyscale list that had never seen a texture.

### Step 80 — the options arm was gated on something AppKit owns

`NSPopover.show` refuses on a window that is not visible, and a terminal-launched selftest cannot
promise one — so the arm reported an empty list and failed for that reason alone. What the popover
*contains* is this project's claim and is true whether or not a window is in front of anybody;
whether it is presented is AppKit's. The content is gated and the presentation is reported, which is
the division the composition timings settled on when an occluded WebKit view stopped being a clock.

1748 → 1756 checks.

## Step 81 — `28-…` §5 items 4 and 5: the textures and the notes leave the pane

- [x] all seven `--ds-tex-*` tokens gone; `.ds-note` and `#showing`'s legend gone
- [x] `background-color: var(--ds-tint` joins the shape list, **because** the tint pair is measured
      1.20:1 apart in luminance with a hue-only control behind it
- [x] `ds-fallback` gains a **solid outline** — it had only a texture, and it is INV-4 in the one
      case the notice cannot reach
- [x] the live audit counts a tint as a signal; `ds-note` retired from the contract

### Step 81 — the shape check failed closed for the wrong reason

Four marks share one rule now, and the check was anchored on `\.name\s*\{` — so it reported **no
rule at all** for `ds-changed`, `ds-formatting`, `ds-behaviour` and `ds-uncertain`. Failing closed is
the right direction and the message pointed nowhere. It matches a grouped selector now.

### Step 81 — and an arm was asserting the annotation rather than the rule

`formatting-collapse` required the word `formatting` to appear **after the code**. DEC-017's
requirement is the *disclosed count*, which the footer and the fold marker carry and which the arm
already asserted in three other places. The fourth assertion was about a thing the contract itself
called annotation only and forbade from being anything's sole carrier — so it asserts `notes: []`
now, which is the opposite claim and the one DEC-083 makes.

## Step 82 — `28-…` §5 item 6: the `+` becomes the design's rimmed disc (DEC-084)

- [x] **DEC-084 before the code**, and it names which values were read and which were guessed
- [x] `RimButton: HandButton` — a disc, a clipped-and-filled gradient ring, the glyph inside
- [x] `--ds-rim-highlight`, `--ds-rim-shadow`, `--ds-rim-fill`, mirrored in `Theme.swift`
- [x] the pair is held **1.30:1 apart in luminance**, with a flat rim as the control; the glyph joins
      the contrast list against its fill
- [x] `RimButton` in `24-…` in the same commit — the widened subclass check demanded it

### Step 82 — the gradient ran the wrong way, and squinting got it backwards

`NSButton` draws in a **flipped** space, so 90° points at increasing y — visually downward — and the
highlight landed at the bottom: a disc that reads as *pressed* rather than raised.

Looking at the two pictures suggested light was wrong and dark was right. **Both readings were
wrong**: the brightest pixel on the disc's centre line is the `+` glyph, not the ring, so the probe
that ranked by brightness was measuring the text. Sampling the ring's *crossings* — the first and
last y that departs from the surface — settled it: both appearances had the highlight at the bottom.

`isFlipped` is false now, and the same probe reads **+94 in dark, +27 in light**.

### Step 82 — and the light rim is much subtler than the dark one

+27 against +94. A white highlight on an already-light surface has less room to work in. It clears
the 1.30:1 floor at 2.72:1, so no check objects — this is a question for the owner's eye, and it is
in `28-…` §5 rather than left for them to notice.

1756 → 1759 checks.

## Step 83 — the packaging gate failed once in four, and the log said nothing

`./Scripts/package.sh` refused to package on the first attempt of this session — **27 arms, then
nothing**. Three further runs passed at 49, 50 and 49. The log ends after `terminal-follow=OK` with
no `MISMATCH`, no trace and no exit code: **an `exit` with no message**, which is a failure that
cannot be read.

- [x] the one silent `exit` on that path — `guard let first = terminal.tabs.first else { exit(54) }`
      — says what happened first
- [x] `package.sh` prints the **exit status** and the **last arm to report** on failure, and names
      where the whole log is kept

### Step 83 — and I threw the evidence away myself

The script already `cat`s the whole log and leaves `$PROOF` on disk. The first run's output was lost
because I piped it through `tail -20` — **M9-C's lesson pointed at the person running the command
rather than at the instrument.** The log was recoverable from the temporary directory, which is how
the cause was narrowed at all.

**The intermittent is not closed.** One failure in four, in the second-shell arm, on a path untouched
by this session's work. What has changed is that the next occurrence will name itself: the exit code
maps to an arm through the `exit(N)` constants, and the gate prints both.

The arm count itself varies between runs — 49, 50, 49 — so *N arms passed* is not a number to assert
on either.

## M11 — the diff says what changed (the owner's fourth session)

The owner reviewed a real Next.js tree and reported that the diff misrepresents it: an untouched
import reads as removed-and-re-added, an inserted interface member puts its highlight on the *next*
line's indentation, and a reflowed JSX attribute list emphasises the one attribute that did not
change. Four analyses ran; they are in the session scratchpad, and the findings that matter are in
`22-experiment-log.md` → M11-A and in the decision to be written for the alignment fix.

### Step 84 — an instrument, before any fix

- [x] `diffscope-verify --emit-structural <old> <new> [path]` — the structural model marked up
      inline, one `⟦label|…⟧` per segment, `*` on lines the model calls changed
- [x] the eleven modified files of the owner's repository exported as old/new pairs and swept

The four reported cases were symptoms of five mechanisms and eleven classes. Without a way to print
the model, every one of them was a screenshot and an opinion.

### Step 85 — one change is one mark (`coalesceAdjacent`)

- [x] `coalesceAdjacent` in `DiffScopeEngine`, applied last in `structuralDiff` so it catches
      fragmentation from `reconcile`, the boundary snap **and** `markUnparsed`
- [x] `disclosure`, `link` and crossing `confidenceFloor` keep their own edges; a disagreeing
      classification leaves the run unclassified; confidence takes the lower of the two
- [x] `CoalesceChecks.swift` — mechanics, six negative controls, idempotence, and the assertion that
      no two segments in a shipping result still say the same thing side by side
- [x] measured: **443 → 175 segments** over the corpus, `ImageText.tsx` 178 → 72 (M11-A)

**The floor constraint was found by a check, not by taste.** Merging across `confidenceFloor` and
taking the minimum made *"an ordinary changed segment is not marked uncertain"* fail — every changed
segment in the reordering fixture had absorbed a below-floor neighbour and `uncertain` stopped
discriminating. Keeping runs separated at the floor costs 175 segments where 108 were available, and
keeps the check true.

**Nothing about what is presented changed**, which is the whole reason this step could go first:
merged segments are adjacent and share a label, so the presented byte set, the coverage and the total
length are identical. INV-1 through INV-5 are untouched by construction; 1776/1776 checks pass.

### Still open, in the order the analyses recommend

- [ ] **the alignment itself** — a deterministic line-boundary shift of the canonical `MatchBlock`s.
      Needs a DEC first: it is not DEC-047's forbidden sliding, because `D` moves and the validator
      recomputes it, so INV-2 holds verbatim. The boundary set must be `0x0A` and not the lexer, or
      "no structural input" stops being true.
- [ ] minimum-run absorption of unchanged gaps shorter than a token (phantom retention)
- [ ] `-uall` for the file list **and** the count, together, plus `-z` parsing and the `AM` glyph
- [ ] the empty comparison when a row is a directory — it draws nothing and says nothing (INV-4)
- [ ] a clause in DEC-083 for `ds-formatting`, `ds-behaviour` and `ds-uncertain`: removing the
      textures leaves them with no declaration at all

## Step 84 — `28-…` §6 item 1: a dragged divider stays dragged (DEC-085)

- [x] an arm that **drags** — `setPosition`, a layout pass, then read the width *after* it
- [x] the pinning `equalToConstant` is inactive outside a collapse, and 999 during one
- [x] the repository caption gives way horizontally
- [x] both dividers asserted, because the two panes hold different priorities

### Step 84 — the write-back was writing 280 to 280

DEC-077 recorded this fixed and the owner reported it twice more. Instrumenting the delegate settled
it in one run: `splitViewDidResizeSubviews` **did** fire, and the widths it received were already
back at the constant. An `equalToConstant` on a split view's pane is restored by the layout engine on
every pass, so `setPosition` moved the frame and the next pass moved it back — and the delegate then
wrote the restored width into the constant and called that a drag.

**It survived a session that fixed it because nothing had ever dragged a divider.** Every pane
assertion in this suite is about a state a *command* produces, ⌃⌘0 and back. The entire middle ground
was untested, and that is where two of this session's six defects were.

### Step 84 — and three things were pinning it, not one

Removing the constraint fixed the **second** divider only. The first still would not move: the
repository pane's caption resists horizontal compression at the default 750, so **the label's own
text was the pane's floor**. Lowering that let it move.

Then the collapse broke — 54.5 pt where 44 was wanted, the split redistributing proportionally
because the constraint was only priority 500 when it mattered. It is 999 **while collapsed** and off
otherwise: strong for the one instruction that needs it, absent for the interaction it was breaking.

Priority alone was never the answer; the first attempt lowered it to 500 and changed nothing at all.

## Step 85 — `28-…` §6 items 2, 3 and 4

- [x] the lens switch joins the scope row; the diff pane loses its band entirely
- [x] the webview starts at the pane's top — all three tops at **777**, both switches at **795**
- [x] `HandTableView` — the pointing hand over both lists
- [x] the arm asserts the **headers'** tops rather than the lists', and that the two switches share
      a centre line

### Step 85 — the fix for item 1 took the starting width with it

With the pinning constraint gone, nothing held 280 and the split distributed by holding priority:
the window opened with a **150 pt** repository pane. The starting widths are set once through
`setPosition` after the window is shown — **a starting point a drag can move, where a constraint was
a floor it could not**. Caught by the same arm that measures the headers, because it prints the pane
width beside the caption.

## Step 86 — `28-…` §6 items 5–6 and §7 items 1–4 (DEC-085, DEC-086)

- [x] the rim is five stops with the highlight at **.88**, built once in `Theme.rimGradient`
- [x] `RimHost` wraps the search field and the checkbox — a rim around a system control, not a
      rebuild
- [x] `Theme.drawChevron` — two mitred strokes centred by arithmetic; `ChevronButton` for `Sources`
- [x] the convention caption moves to the count's tooltip; `#track` removed outright
- [x] the title row matches the traffic lights' centre line, measured from the button
- [x] the watcher's age steps instead of ticking

### Step 86 — the flicker check asserts a property, not a string

*refreshed 4s ago* redrew once a second. The fix could have been checked by asserting the new
wording, which would pass on any wording at all. What is asserted instead: **over a full minute of
ticks the sentence takes two forms, not sixty** — with a per-second wording as the control. That is
the property the owner asked for; the strings are an implementation of it.

### Step 86 — three checks had to follow their subjects rather than be deleted

The convention check now looks for the sentence on the row's tooltip; the track checks became *no
slider is drawn* plus *the panes still share a position*; the age checks became the two-forms
property. **A requirement that moves is not a requirement that goes** — each check kept its subject
and changed its address.

### Step 86 — one item is decided and not built

DEC-086's transparent, blurred title band is **not landed**. It needs DEC-083's ban on
`NSVisualEffectView` re-expressed first: that ban is right where it was aimed — vibrancy standing in
for glass *on a control* — and too wide as written, because a window band is not a control and the
system's blur is not an imitation of the system's blur. Recorded as unmet rather than half-built.

1776 → 1779 checks.

## Step 87 — `28-…` §7 item 5: the title band is the system's material (DEC-086)

- [x] `NSVisualEffectView`, `.headerView`, `.behindWindow`, behind a transparent titlebar
- [x] `window.isOpaque = false` so what is behind the window comes through
- [x] `ChromeBar` accepts a `nil` surface — *draw the seam and nothing else*
- [x] DEC-083's ban **narrowed rather than dropped**, and re-expressed as a rule about surfaces

### Step 87 — my own check was the obstacle, and the wording was the fault

*Nothing imitates the material where the system has none* banned `NSVisualEffectView` anywhere in
the chrome. The rule is right where it was aimed — **vibrancy standing in for glass on a control**,
on a system that does not have glass, which is the thing the owner asked not to get. It was too wide
as written: a window band is not a control, and **the system's blur cannot be an imitation of the
system's blur**.

The check names the surface now. No control file may reach for it; the window file may, **once**,
and the check asserts the count, the material, the blending mode and the transparent titlebar — so
the exemption is a named line rather than an open door.
### Step 86 — the alignment moves onto line boundaries (DEC-086)

Written in a worktree, because a second session was working in the checkout at the same time.

- [x] DEC-086 written before the code, including why this is not the sliding DEC-047 refused: `D`
      itself moves, inside the one function the model and the validator both call
- [x] `shiftToLineBoundaries` in `CanonicalDiff.swift`, applied inside `canonicalMatches`
- [x] the boundary set is `0x0A` and nothing else — tokens would make `D` depend on a parse
- [x] `AlignmentChecks.swift`: both owner cases, a negative control that a mid-line edit stays
      mid-line, tiling over 200 random pairs, and the snap guard's positive and negative arms
- [x] measured, three builds over the same corpus → `22-experiment-log.md` M11-B

**The shift alone made the corpus worse**, and only measurement caught it: 35 wrong lines → 42. The
alignment was landing on line boundaries and DEC-047's outward snap was carrying it back off them.
With the snap taught not to widen what is already whole-line: **24**. Both cases the owner reported
are exact now, and `get-api-media-url.ts` is the first file in this corpus the model describes with no
error at all.

- [x] `findMoves` no longer extends a move across an unchanged line. `moved-two-blocks` had started
      producing one record for two blocks that land in different places, which is `link` counting
      instead of pairing — T-11's third assertion caught it.

**Two checks fail in the worktree and pass in the checkout**: the slider corpus and the relocatable
imports corpus both walk the *parent directory* for real `.tsx` files, and a worktree's parent is
`.claude/worktrees/`. Re-run from the checkout before merging — that is where 1776 becomes the number
that counts.

## Step 88 — the owner's fifth session: six reports (DEC-088)

- [x] DEC-088 written before the code, and it **reverses DEC-080** eleven days after it
- [x] the search field's cell: the interior moves a `space3` right, and the **field editor** is put
      on the cell's own text rectangle instead of on the whole frame
- [x] `RimHost.wrapping(_:padding:verticalPadding:)` — the vertical room goes around the field
- [x] `--ds-chrome` = `--ds-panel-repos` = `--ds-panel-files`; the ladder check becomes an equality
- [x] `#showing` removed, element and rule both; `#notices` collapses when empty
- [x] `ChangeKind.untracked` wears `+` in the added hue
- [x] `SlimScroller` + `OverlayScrollView`: an overlay scroller whatever the system preference says,
      a narrower knob, and no slot behind it
- [x] `--ds-pane-header-height`, and a check that does the arithmetic on both sides
- [x] `--ds-status-bar` — the owner's same-day amendment: that one band stays darker than the panels
- [x] 1793 → **1802 checks**, 50 → **51 selftest arms**

### Step 88 — the status line is the one band that reports on the window

Item 2 collapsed `--ds-chrome` into the panels, and the status line was drawn from `--ds-chrome`.
The owner asked for it back, and the line the exception is drawn along is worth keeping: every
other band **holds** part of what is being read; the status line **reports on** it.

The check is an **ordering, not a ratio**, and that is measurement rather than taste — below
`--ds-panel-*` in dark there is almost nothing left before the code's black. 1.26:1 in light,
**1.08:1 in dark**, printed rather than asserted, with the hairline at the bar's top edge doing the
separating.

### Step 88 — the field was right in every picture and wrong the moment anyone typed

The magnifier overlapped the text, and three things about it are worth keeping.

**The resting field had never been wrong.** `searchButtonRect` is x=2, `searchTextRect` is x=26, and
both draw exactly there. `select(withFrame:)` and `edit(withFrame:)` are handed the cell's **whole
frame** when the field is unbezeled — which it is, because DEC-085 put the design's rim around it —
so the string was laid out from x=0 as soon as the reader clicked in. Every static check and every
snapshot of that field says it is fine. **The arm therefore focuses the field and measures the field
editor**; the cell's own rectangles pass identically before and after the fix.

**The obvious repair renders the text twice.** Overriding `searchTextRect(forBounds:)` moves the
rectangle the cell asks for and not the one it draws — photographed, two `Widget`s a few points
apart. Four probe builds outside the project settled this before a line of it went into the app.

**And the vertical padding had to go around the field, not inside it.** The first version inset the
editor by `searchTextPadding` top and bottom; the field's `intrinsicContentSize` is **14**, so an
eleven-point line got seven points to live in. The arm measures the gap the *rim* holds, which is
what a reader sees.

### Step 88 — an empty bar is a bar reporting that there is nothing to report

`#notices` kept its padding and its seam on every normal file, which is every file the reader opens.
Collapsing it broke the live style audit, and the break was the useful part: the audit had been
reading an **empty** bar and calling `:empty` a hidden notice bar. It puts a chip in before it
measures now — INV-4 is a promise about a notice that exists, and that is the stronger question.

### Step 88 — three headers, one line, two layouts

`REPOSITORIES` and `CHANGED FILES` are `ChromeBar`s of `Theme.paneHeaderHeight`; the file path above
the diff is a `<div>` that was `space3 + text + space3` = 27. Five points of drift on a line that
crosses the whole window. The check reads `--ds-pane-header-height` from the token file, recomputes
`pillHeight + 2 * space2` from `Theme.swift`, and compares the **numbers** — a check on the token's
*name* is what let two sides of one boundary hold different values in the first place.


## Step 89 — the terminal becomes one input surface (DEC-089)

- [x] DEC-089 written before the code, through DEC-055's own revisit trigger
- [x] `TerminalScanner.onEventRange` — where a mark was, not only that it happened
- [x] `PromptCapture` — last-line split, the refusal rule, SGR to segments
- [x] `TerminalSession` withholds the prompt and releases it **in order**, at two doors only
- [x] `#prompt` in the row; the row loses its border and its surface and becomes the grid's last line
- [x] `cursorInactiveStyle: "none"` — one caret on screen
- [x] `--ds-term-input-surface` removed: that boundary was the thing being reported
- [x] 1802 -> **1823 checks**, 51 -> **53 selftest arms**, and a `terminal-prompt` snapshot

### Step 89 — the ordering is the design, and everything else follows from it

**Nothing is removed from the grid's stream; a span of it is held back and released in order.** ZLE's
redraw arithmetic is relative to where it believes the cursor is, so a design that *drops* the prompt
or re-renders it leaves xterm and zsh disagreeing by one prompt width and every later redraw lands in
the wrong column. Delaying bytes cannot do that. The release therefore has exactly two doors —
`appendLocked` and `send` — because the alternatives are four and a fifth would be added one day.

### Step 89 — three defects, and two of them were found by controls rather than by looking

**A start mark with no end mark swallowed the grid**, and the suite's own `printf ';A'; cat` fixture
found it on the first run. It is not a test artefact: the integration appends `;B` to `PROMPT`, so any
shell whose `PROMPT` is replaced after the rc file runs emits one mark and never the other. A capture
that outlives two flushes is given up now — released in order, like every other path out.

**An empty slice was being treated as a write.** The split calls `appendLocked` with whatever follows
the last mark, and after `OSC 133;B` at the end of a read that is nothing at all — so the prompt was
released the instant it was withheld. The arm said `inRow=true notInGrid=false`, which is the
arrangement the owner reported, reproduced by the fix meant to remove it.

**And the obvious repair renders the prompt twice.** Overriding `searchTextRect`'s equivalent here —
`PromptCapture` moving the rectangle the cell asks for rather than the one it draws — is the same
shape of mistake as DEC-088 item 1. The rule that came out of both: **when a control has a layout
question and a drawing question, answer them in the same place or not at all.**

### Step 89 — the control that mattered

`OSC 7` is emitted **inside** the prompt span by this product's own integration. A refusal rule of
"SGR only" would have refused every prompt DiffScope installs, on every machine, and the fallback is
quiet by design — the row would simply have looked the way it looked before. The negative control
asserting that an OSC is *not* a refusal is the only thing between that and shipping.


## Step 90 — the terminal drawer gets a button (DEC-090)

- [x] `TerminalButton` in the status line, drawing `>_`; action from `selector(for: "terminal")`
- [x] `Theme.drawPrompt` — two strokes and a rule, not a glyph typed into a title
- [x] state by shape: the raised surface open, the bare mark shut
- [x] `windowSnapshot` draws, displays and **commits** before it photographs
- [x] 1823 -> **1828 checks**, 53 -> **54 selftest arms**

### Step 90 — the button was right and the picture was three turns old

`keyboard.png` showed the drawer's button **raised with the drawer shut**. The state was right, the
arm that asked said `closed=true`, the invalidation was right — and `CGWindowListCreateImage` asks
the *window server* what it has, which is whatever was last committed to it. Nothing here had ever
forced that commit before taking a picture. Fourth instance of the class, after CodeMirror's
occluded re-measure: **a picture of a pass that has not run is a picture of something that was never
on screen.**

**Two repairs were written before the right one, and both were measured and removed.** A
`wantsUpdateLayer` override on the button (plausible: `NSButton` answers `true`, so an invalidation
can be satisfied by `updateLayer()` and leave the drawn contents cached) and a `displayIfNeeded()` in
`setTerminalVisible`'s hidden branch. Each was taken away again and the pixel sampled: neither
changed anything. *Measure the control before believing the check* — applied to a repair.

The arm renders the button in **both** states now and requires the two pictures to differ. No
assertion about state could have caught this; that one can.


## Step 91 — every icon in the chrome becomes a path (DEC-091)

- [x] `MarkButton` — the picture is a closure, the title is only the name
- [x] `RimButton.mark` — the `+` is two strokes, not a proportional font's plus sign
- [x] `«` `»` → `Theme.drawDoubleChevron`; they were **guillemets** used as arrows
- [x] `>_`'s chevron re-proportioned 4 × 8 — it was 7 × 7, which is the shape of a `>`
- [x] one construction (`drawChevronArm`) for every chevron in the window
- [x] 1828 -> **1832 checks**

### Step 91 — DEC-085 drew one chevron and left three characters behind

The mechanism was already written down: a mark set in a font carries that font's stroke weight, its
optical centre and its side bearings, and none of the three belongs to the control. What DEC-085
did not do was **sweep for the rest**, so `«`, `»` and `+` sat beside a drawn chevron for six days,
and DEC-090's own `>_` was drawn from a square.

The proportion is the checkable part: **a chevron's arms are about twice as long as they are far
apart**. The control is the square this replaced — and it is a control worth having, because a check
on the width alone, or on the height alone, would have passed the shape being removed.

### Step 91 — what stays a character

Not everything shaped like a glyph is an icon, and the sweep had to stop somewhere defensible. The
file-kind marks and the sign column are **content** — DEC-035 asks for a character that survives
greyscale, and they are set in the same face as the paths beside them. `▍` is a bar chart. `···` is
an ellipsis. `●` / `○` is a bullet **inside a sentence** `ChromeLabels` composes, where filled
against hollow is the shape carrier. Each is named in DEC-091 with its reason, so the next sweep
does not have to re-derive them.


## Step 92 — version two writes: M11, M12, and most of what came after (DEC-092, DEC-098)

**1832 → 1912 checks; a new selftest arm (`staging`) that stages a file and commits it through the
controls a reader would use.** Four commits: the write path and INV-6; the window's half; hunks and
history rewriting; conflicts, the reflog and custom commands.

- **The registry split.** `GitWriteOperation` + `GitWriter`, risk classes, `index.lock` handled
  rather than hoped over, no editor and no prompt reachable from any invocation.
- **`StagingPatch.swift`.** A line walk, a unified patch for a selection, and — along a path the
  patch has no hand in — the bytes that selection should produce. That second path is what makes
  **INV-6** an assertion rather than a comparison of a thing with itself.
- **The window.** The three-state box beside every path, the commit box under the list, the branch
  and sync controls in the status line, the banner with its verbs, and the panel that shows every
  command this application ran.
- **Ahead of their milestones:** branches, stashes, conflicts, tags, worktrees, reflog, bisect,
  revert, cherry-pick, reset, the remote, rewriting (reword/squash/fixup/drop/move/amend-old) and
  custom commands typed into the drawer.

**Three findings.** A hidden `NSView` keeps its constraints — 26 pt of nothing over the status line.
A button's title became the file pane's minimum width, and `dragSelftest` caught it rather than
anything looking at the button. `fixup! <sha>` is not the subject `--autosquash` matches, so *amend
an old commit* left its fixup on the branch until `commit --fixup=<sha>` replaced it — with
`rebase --root` beside it, because otherwise the oldest commit is the one that cannot be amended.

**Not built:** the graph column in History and click-to-select lines in the diff. Both need a
renderer bundle rebuild, and the install landed in the same session: History draws its lanes,
a click on a commit picks it — the shell had that handler since M9 and the page had never sent the
message — and a click on a sign stages or unstages that line.


## Step 93 — the changed-file list becomes a tree (DEC-099)

**1912 → 1990 checks.** The owner asked with a screenshot; OQ-041 had been open since Phase 4 and
this answers it. `fileTreeRows` replaces `fileListRows`: directories nest, a chain of single-child
directories folds into one row, directories come before files at every level, and a folded
directory takes its subtree with it. `IndentGuides` draws one hairline per level. ⌥← / ⌥→ fold and
unfold; folder rows stay labels, so the 63-file walk is still 62 keystrokes.

**Retired with it:** DEC-074's shortest-unique header titles, and the workspace-package machinery
(`declaredWorkspacePackages`, `groupKey`) that fed DEC-033's grouping. A tree puts `packages/app-2`
on a row because it is a directory.

**Three findings, all from the first photograph of it.** The guides were drawn in `hairline` and
were invisible: that rule separates two surfaces and borrows contrast from both, and a guide runs
down one. File names still truncated from the head — `…hImage.adapter.tsx` — which removes exactly
the half that tells siblings apart; middle elision is what DEC-033 asked for in the first place.
And `raw` drew as `ra`, because `ChipView` held a required compression resistance while the label
inside it did not, so the chip shrank anyway.


### Still open

- [ ] minimum-run absorption of unchanged gaps shorter than a token (phantom retention). `alpha` →
      `gamma` still shreds into two hunks around a coincidental `a`.
- [ ] the old pane's silence on a reflow — 20 of 31 removed lines carry no mark, and no alignment
      fixes it. Needs substitutions presented on both sides.
- [ ] insertions separated by a single unchanged line cannot shift: the search is bounded by the
      neighbouring match lengths. `PageComponents.tsx` and `BannerWithImage.tsx` are what is left.

## Step — the alignment reads below the line as well as on it (DEC-093, M11-C)

- [x] `shiftToLineBoundaries` → `shiftToReadableBoundaries` in `CanonicalDiff.swift`: two lexical
      ranks below the whole-line rank, and **shift 0 scored as a candidate**, without which an
      insertion already on a line boundary is pulled off it (measured: 24 false lines, not 23)
- [x] `applyShift` on `canonicalMatches` / `canonicalDiff` — the negative control, so a check can
      tell a shift that fired from one that was never needed
- [x] nine checks in `AlignmentChecks.swift`, including the two union cases with their controls,
      "the shift leaves the total matched length exactly where it was", and the CRLF and
      multi-byte-character guards on the new byte classes
- [x] `Scripts/devtools/measure-alignment.sh` — M11-B's instrument, now in the repository, and it
      reproduces M11-B's baseline exactly (147 reported, 24 false, 20 missed)

The stray apostrophe is gone: `'base' | '⟦compact' | ⟧⟦~'⟧wide'` is now `'base' | ⟦'compact' | ⟧'wide'`,
three marks to one. The line metric barely moves — 24 → 23 — because a boundary that travels inside a
line changes no line's status. Segments over the corpus: 185 → 182.

## Step — confetti is absorbed into the change around it (DEC-094, M11-D)

- [x] `Sources/DiffScopeEngine/AbsorbIslands.swift` — four conditions, the fourth of which is a
      theorem: absorption never changes `changedLines`, at any floor
- [x] floor **8** from the M11-D curve, which ends there; `absorbIslandBytes` on `MatcherSettings`
      and a sixth argument to `--emit-structural`, so the pass can be turned off on its own
- [x] wired first in the pipeline, before `snapPresentation` — otherwise the budget-0 control would
      exercise a different absorption from the shipped one
- [x] twenty-two checks in `AbsorptionChecks.swift`, including the monotonicity property over all 58
      fixtures and 300 random partitions, and the identity control at floor 0
- [x] **a `moved` flank is refused outright** — T-11 failed on 192 disagreements first, because the
      two sides are absorbed independently and DEC-038 wants them byte-identical
- [x] no per-run allowance: the relative rule already bounds the total strictly below the run's own
      changed bytes, so a cap would be a knob that can never turn

182 segments → 159, for 0.7% more presented bytes. `false` unmoved at 23, which is rule 4 holding.

## Step — a language with no grammar gets a real diff (DEC-095, M11-E)

- [x] `fallbackPartitions` in `TrivialPartition.swift` — segments from `canonicalDiff`, labelled
      `.fallback` so INV-4 holds, then absorption, grapheme snapping and coalescing. No
      `snapPresentation`: it is the only one that needs a tree.
- [x] `fallbackResult` and `trivialModel` both go through it, so Raw mode and the F-rows cannot drift
- [x] `fallbackDiffWorkBudget` at a tenth of the default — `runBudgetChecks` caught the dense-JSX
      gate case going from the parse baseline to 0.98 s, and this puts it back
- [x] the hairline moves from `ds-fallback` to `ds-parse-error`, which only `markUnparsed` sets;
      `ds-fallback` keeps the tint, and `24-design-contract.md` gains the row
- [x] the status line says `plain text — …`; `pathTaken` keeps `raw`, which is the contract's word
- [x] nine F7 checks in `DegradationChecks.swift` with the budget-exceeded negative control, and
      `css-property-change` / `json-value-change` fixtures in a new §4.8

809 lines painted becomes 17, against git's 16.

## Step — the unified blocks move into the engine (DEC-096, M11-F)

- [x] `Sources/DiffScopeEngine/Unified.swift`, `RenderModel.unifiedBlocks` in UTF-16, `main.js`
      reads them instead of deriving them — the last part of that layout deciding *what is shown*
      that the renderer worked out for itself
- [x] the peel: byte-equal line pairs no stop covers come off the block as context
- [x] `UnifiedChecks.swift` — the containment property **failed on its first run**, `moved-function`,
      because the peel excluded line terminators and a stop covering only a newline fell out of every
      block. In `main.js` there was no way to have asked.

**The peel fires on one fixture of 51 and on none of the eleven real files.** DEC-093 got there
first. The 36 duplicated lines that remain are lines that are byte-identical *and carry a mark*, and
the peel must refuse those — the answer is the alignment, below.

## Step — a shift may consume a short match (DEC-097, M11-G)

- [x] the walk may reach `current.length` / `previous.length` when the match is ≤ 8 bytes, and only
      a rank-1 landing may take it; consumed matches are dropped rather than kept at zero width
- [x] DEC-087's "a match shrinking to nothing is a different edit script" is the half that was
      wrong — it is the same script, partitioned into hunks differently, and the matched total is
      invariant either way. Asserted over 300 random pairs against `applyShift: false`.
- [x] five checks in `AlignmentChecks.swift`, including the negative control that a match longer
      than the floor is left alone

`}: ImageTextProps) {` carries no mark now. false 23 → 22, presented bytes 5581 → 5570, lines printed
twice 36 → 32, segments 159 → 160 — the first entry in the series where the mark count moved the
wrong way, and the trade is stated in DEC-097 rather than hidden.

### Still open
- [ ] **`--emit-structural`'s printer stars only the first line of a whole-file fallback**, where the
      contract's `changedLines` correctly reports every one. Held against each other on an 81 KB
      `.mjml` pair: `--emit-model` says 1160 lines, the printer stars 1. Predates DEC-093 — the same
      file behaves identically on the commit before it — and it is confined to the diagnostic tool.
      But `Scripts/devtools/measure-alignment.sh` counts stars, so it under-reports any file taking
      that path. The M11 corpus contains none, so those numbers stand.
- [ ] `canonicalDiff` is computed three times per model — `trivialModel`, `validate`, `changeStops`.
      It was twice before DEC-095. A threading opportunity, not a blocker.
- [ ] the unified view prints byte-identical lines twice wherever a mark leaks onto one; the peel
      belongs in the engine, because `unifiedBlocks` is the one part of that layout deciding *what is
      shown* that the renderer works out for itself.
- [ ] **the reflow case, now the single largest open item, with four findings pointing at it.** When
      a block is reflowed the old bytes are a subsequence of the new, and a minimal alignment
      legitimately puts every changed byte on one side. That is: the old pane silent on 20 of 31
      removed lines (M11-B); `⟦~s⟧⟦rc⟧` over an unchanged `src` and `titleSize` keeping five marks
      (M11-D); 32 lines still printed twice in the unified view (M11-F); and the sites DEC-097's
      floor cannot reach at any setting (M11-G). **No boundary rule reaches any of it** — absorption
      and the peel are as far as monotone widening goes, and the alignment is already minimal. The
      answer is a presentation that shows a substitution on *both* sides, which is not an alignment
      change at all.
- [x] ~~insertions separated by a short match cannot shift~~ — **DEC-097**. What it did not reach
      is below, and it is all one thing.
- [ ] `-uall` for the file list **and** the count, `-z` parsing, the `AM` glyph
- [ ] the empty comparison when a row is a directory (INV-4)
- [ ] a clause in DEC-083 for `ds-formatting`, `ds-behaviour`, `ds-uncertain`

## Step — the corpus is 4016 of the owner's own changes, and it ranks what is wrong (M12-A)

- [x] `Scripts/devtools/build-corpus.sh` — modified `.ts/.tsx/.js/.jsx` pairs from the last 200
      commits of 13 Next.js repositories, with `git diff -U0`'s line numbers stored beside each pair.
      Generated, oversized and duplicate pairs refused and counted.
- [x] `diffscope-verify --corpus-survey <dir> [json] [--limit N] [--only s] [--word-snap N]
      [--word-merge 0|1] [--ws-class 0|1] [--snap N] [--island N]` — the M11 metrics summed over the
      corpus plus a taxonomy of nine named shapes, and a JSON dump so two runs are comparable
- [x] `corpus/` is git-ignored; the manifest is regenerated by the script, so a measurement is
      reproducible without carrying client code in this repository
- [x] the first `shredded-word` detector counted two different defects as one — split into
      `shredded-word` and `split-mark` before any fix was written against it

## Step — a mark finishes the word it cut (DEC-100, M12-B, M12-C)

- [x] `Sources/DiffScopeSyntax/WordSnap.swift`: `snapToWordBoundaries` with the string rule and the
      identifier rule, and `coalesceAcrossWords` for the junction inside a word
- [x] `widenPresented` extracted from `snapPresentation` in `Boundaries.swift` — both wideners now
      answer "what do the widened bytes say" in one place
- [x] `wordSnapBudget = 24` from the M12-B curve, and `mergeSplitMarksInWords` as a **separate**
      switch so each half is measurable against the other's absence
- [x] wired between the syntax snap and the grapheme snap, which must stay last
- [x] `WordSnapChecks.swift`: the class-name case, the hyphen case, the merge as a unit with its
      `coalesceAdjacent` control, and the property that the word snap reports the same lines as its
      absence over every fixture
- [x] DEC-047's budget-0 control now turns off both wideners — a control that turned off one would be
      asserting the other's absence

`shredded-word` 6723 → 682, marks 81665 → 75873, presented bytes +1.6%, false and missed unmoved.

## Step — a rewrap says it is a rewrap (DEC-101)

- [x] `Sources/DiffScopeEngine/WhitespaceHunks.swift`: `hunkLayout` over the **region** the hunks
      jointly cover — `layoutOnly`, `reflowed`, `reordered`, `substantive` — and `preservedGapRanges`
      for the gap between two tokens that are still neighbours on the other side
- [x] `classifyLayoutMarks` says `whitespace` where one of the three rules holds and the mark carries
      no classification of its own
- [x] `reordered` refuses everything, because DEC-048 may collapse a `formatting-only` run
- [x] `classifyWhitespaceHunks` switch, and the checks for the reported shape, the re-indent and the
      reorder

Unclassified whitespace-only marks 13090 → 10495; quiet bytes 67457 → 99215.

### Still open

- [ ] **the unified view still prints a rewrapped element twice.** `silent-old-side` (3986 instances,
      47.5% of pairs) and `reflow-insertion` (3795, 46.0%) did not move and cannot be moved by any
      mark-level pass: they are about which *lines* the unified layout prints. The engine now has the
      vocabulary — `hunkLayout` already names a region `reflowed` — so the next step is a
      `UnifiedBlock` that carries it, an old half withheld behind an expander, and the losslessness
      clause that permits it.
- [ ] `micro-island` 4766 → 5305, the word snap's own cost: a widened mark leaves a shorter unchanged
      gap, and absorption's relative rule refuses it. Measure the floor against the corpus rather than
      against eleven files.
- [ ] `split-mark` is still 27284. What remains is junctions **between** words, refused on purpose:
      the confidence floor is the line the interface reads. Worth a second look at where those
      confidences come from rather than at the refusal.
- [ ] `BudgetChecks`' *a file above the size limit is refused without parsing it* is intermittent on
      this machine: the fallback path takes 1.6 s and the threshold is twelve times a scan baseline
      that measures 0.11–0.13 s. It fails and passes on the same binary, and it passes on a clean
      tree at the same absolute time. Not a regression from these entries; the threshold is the
      flake.

## Step — a rewrapped old half is withheld rather than printed twice (DEC-102, M12-D)

- [x] `UnifiedBlock.reflowed`, decided in `Unified.swift` by `isReflowedBlock` — old tokens a
      subsequence of new ones, **one direction only**, both halves non-empty
- [x] `Codable` with `decodeIfPresent`, so a payload written before this decodes as `false`
- [x] `main.js` withholds the old half of a reflowed block, states the line count in the hunk header,
      and `expandReflow` rebuilds the document with it back; `expandedReflows` clears when the
      comparison changes
- [x] `.ds-hunk-reflowed` in `index.html` and its row in `24-design-contract.md` — the class audit
      failed until the row existed, which is the audit working
- [x] `UnifiedChecks`: the reported shape, and four negative controls — a removal, a pure insertion,
      a reorder, and the property over every fixture that a withheld half really is on screen in the
      half that stays
- [x] two renderer-source checks rather than one, because a withheld half with no way back is the
      failure that a single `contains` would miss (DEC-064's named failure mode)

`silent-old-side` 3986 → 202, `reflow-insertion` 3795 → 0, `duplicated-line` 2320 → 1075, and the
model's own numbers unchanged to the byte.

## Step — absorption runs again after the wideners (DEC-103, M12-E)

- [x] the island floor swept over the corpus first: 8 → 24 moves the marks by 0.5%, so **the floor is
      not the dial** and M11-D's choice survives 4016 changes
- [x] the survey made to say *why* each island survived, by re-deriving absorption's four conditions
      from the finished partition — 1507 of 1757 refused by no condition at all
- [x] `absorbIslands` runs a second time after the three wideners, behind `absorbAfterWidening`
- [x] checks: the island a widener creates is absorbed, the negative control without the second pass,
      the presented set grows rather than moves, and DEC-094's theorem re-asserted over every fixture
      against the control

`micro-island` 5305 → 1347, marks 75873 → 70916, presented bytes +0.4%, reported lines unchanged.

### Still open

- [ ] 27423 junctions crossing the confidence floor. The diagnostic now names them, and the same run
      says uncertain marks are 7.9% of marks and 3.0% of presented bytes — rare enough that the flag
      still means something, so this is **left alone on the evidence** rather than tuned.
- [ ] 1075 byte-identical lines still printed twice inside blocks that are not rewraps. DEC-096's
      peel refuses them because a stop covers them; the answer is a finer stop, not a wider peel.
- [ ] `--emit-structural`'s printer still stars only the first line of a whole-file fallback
      (predates DEC-093, confined to the diagnostic tool).

## Step — the size-limit check measures the work the path must do

- [x] `BudgetChecks`' *a file above the size limit is refused without parsing it* was intermittent for
      eight days, and it was right to be: its baseline was **one pass over the bytes**, a model of the
      cost that DEC-095 invalidated when `trivialModel` gained a real byte diff. The threshold sat a
      hair above the truth and flipped on how the scan happened to time.
- [x] the baseline is now the work this path is supposed to do — two `sourceDegradations` scans, which
      `13-…` §5's precedence requires before the size gate can answer, plus the fallback model — and
      the assertion is that refusing costs no more than 1.3× it
- [x] **a positive control beside it**: parsing the same bytes is measured and shown to break the
      threshold, so the margin is known to be crossable rather than assumed to be

2019/2019. Three runs in a row, on the machine where the old form failed two in three.
