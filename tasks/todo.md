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
