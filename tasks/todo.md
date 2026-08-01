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
