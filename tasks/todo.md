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

## Step 3 — boundary tie-breaking (deferred, next session)

Shift hunk boundaries onto syntax boundaries among equally-minimal alignments.
Measured baseline: 38% of canonical hunk boundaries land on a node boundary.

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
