# 14 — Losslessness and Trust Model

**Status:** Authoritative for the invariant. Settled by DEC-021, DEC-022, DEC-023.
**Justification and corpus measurements:** [research/losslessness-invariant.md](research/losslessness-invariant.md)
**Terminology:** [glossary.md](glossary.md)

This document defines what the application guarantees, how the guarantee is enforced, and what happens when enforcement fails. It is binding on the diff engine and on the presentation layer. An agent implementing either must treat this document as a specification, not as guidance.

---

## 1. The guarantee, in one sentence

> Structural analysis may change how edits are aligned, grouped, labeled, and presented. It must never suppress or discard any textual difference. The exact source text is the source of truth.

## 2. Definitions

For a single file under a single comparison scope:

- `O` — the exact byte sequence of the **old** side.
- `N` — the exact byte sequence of the **new** side.
- `(O, N)` together with a content hash for each constitute the **pinned source pair**. All analysis and presentation refer to one pin.
- `M` — the **presentation model** the engine produces for `(O, N)`.
- `R = {r₁ … rₙ}` — the set of byte ranges that `M` presents as changed. This includes edits, moves, formatting-classified changes, and fallback regions. Each range carries its side.
- `D` — the **canonical minimal diff** of `O` and `N`, computed over bytes by a fixed, deterministic algorithm taking no structural input. `D` exists solely to validate `M`; it is never displayed. The choice of algorithm is OQ-042.

## 2.5 The model is a byte partition (DEC-024)

`M` is not an arbitrary structure that happens to carry positions. **It is a total ordered partition over the bytes of each side**, with structural labels attached to segments:

```
no gaps · no overlaps · Σ segment lengths == file length
```

for the old side and independently for the new side.

This is the single most important structural decision in the engine, and it exists because of a documented root cause: tools that model a **tree whose nodes happen to have positions** cannot represent what the tree omits — inter-token whitespace, blank lines, trivia — and that loss is irreversible. Building the partition as the primitive inverts this. No existing structural diff tool does it, which is both the risk and the opportunity.

Consequences for the invariants below:

- **INV-1 holds by construction.** Concatenating the partition in order *is* the file. Reconstruction is an identity, not a check.
- **INV-2 holds by construction.** Every byte is in exactly one segment; every segment is either labeled unchanged or presented. A byte that is neither is not expressible.
- **The structural layer attaches labels to segments; it never replaces them.** A move regroups segments — it may not substitute for the segments it contains. This makes the move trap (OQ-026) structurally impossible rather than merely prohibited.
- **Zero-width parser artifacts break the partition** and must be excluded from it, represented as annotations instead. tree-sitter `MISSING` nodes are the known instance.

Because coverage is now structural, the expensive part of runtime validation — computing a canonical diff `D` purely for comparison — is no longer required for it. Cheap assertions on the partition replace it. `D` remains defined below because the invariant is still *stated* in terms of it, and because an independent check retains value in testing.

## 3. The invariants

### INV-1 — Reconstruction

```
reconstruct_old(M) = O    and    reconstruct_new(M) = N
```

Byte-for-byte, both sides, from `M` alone.

### INV-2 — Coverage

Every byte belonging to any hunk of `D` lies **within** some range in `R`.

This is **containment, not intersection**. Intersection would allow `M` to present a one-byte marker for a five-hundred-byte change and still pass.

INV-1 does not subsume INV-2. A model can reconstruct both sides perfectly while presenting a region as unchanged, because reconstruction data and presentation data are different parts of `M`. Both checks are required.

### INV-3 — Equality honesty

`M` presents "no changes" **if and only if** `O = N` as byte sequences.

### INV-4 — Fallback visibility

Every range in `R` produced by fallback rather than by structural analysis is marked as such in the presentation. There is no silent fallback.

### INV-5 — Mode agreement

For a given pinned source pair, Structural and Expanded modes produce **identical** `R`. They differ only in presentation flags (DEC-013). Any divergence is a bug by construction.

## 4. Comparison and display granularity

| Concern | Granularity | Rationale |
|---|---|---|
| Comparison and validation | **Bytes** | Total. Works for text, binary, invalid UTF-8, and unknown encodings. No decode step that could itself lose information. |
| Display and highlighting | **Grapheme clusters** | Never split a combining sequence or emoji ZWJ sequence mid-cluster. |

Presented regions are snapped **outward** to grapheme-cluster boundaries. This is safe because outward expansion is **monotone**: growing a region can never push a changed byte outside it, so display snapping cannot break INV-2.

### 4.1 Normalization is prohibited

Unicode normalization is never applied. Not as preprocessing, not as a user option, and **not inside the structural layer**.

Rationale, measured rather than theoretical: this corpus contains `company: 'ŻABKA'` where `Ż` is `U+005A U+0307` rather than the precomposed `U+017B`. The two are canonically equivalent and render identically. Comparing normalized text reports **no difference** for a real byte change — a direct violation of the guarantee.

The prohibition extends to the structural layer specifically because a parser or matcher that normalizes identifiers or string literals for comparison purposes would report a changed string as unchanged. DEC-022 runtime enforcement provides defense in depth here, but the rule stands independently.

### 4.2 The engine does not transform bytes

The diff engine performs no EOL conversion, no encoding conversion, and no normalization. Its contract is **bytes in, bytes out, unmodified**.

**Filter handling belongs to the Git layer (DEC-025).** Measured: `git cat-file` and `git show` return raw object-database bytes; smudge/EOL filters are applied on checkout into the working tree. So for scopes comparing a committed side against the working tree, the two sides come from different filter regimes, and where a filter is active they differ on every line.

The Git layer therefore produces **the byte pair that `git diff` itself would use** — filters applied consistently to both sides — and **discloses** when a filter was applied. The engine contract is unchanged; the responsibility boundary moves, the invariant does not weaken.

Rationale for matching `git diff` rather than comparing raw bytes: Raw mode is the control view (DEC-013), and a Raw mode that contradicts `git diff` destroys the property it exists to provide.

Current exposure is **latent, not active**: 0 of 21 repositories set `core.autocrlf` or `core.eol`, and no `.gitattributes` carries `text`/`eol`/`crlf` directives. The 34 CRLF files are CRLF in the object database too. This means the behavior **cannot be validated against the current corpus** and requires a dedicated fixture.

## 5. Enforcement

Per DEC-022:

| Context | Enforcement |
|---|---|
| Tests | INV-1 … INV-5 checked unconditionally on every fixture |
| Runtime, file below size threshold | INV-1, INV-2, INV-3 checked live |
| Runtime, file above size threshold | Checks skipped; file marked **explicitly unverified** in the UI |

Threshold value is a Phase 5 number pending performance budgets (OQ-031, OQ-043).

### 5.1 Failure action

On any runtime invariant violation:

1. **Discard** the structural presentation for that file.
2. **Fall back** to raw textual diff for the whole file.
3. **Mark the fallback visibly**, per INV-4.

Failure degrades visual quality. It never degrades correctness, and it is never silent.

### 5.2 "Unverified" is a visible state

Skipping validation above the threshold without saying so would itself be a trust violation of the same family the invariant forbids. Unverified files must be identifiable as unverified.

## 6. Invisible-difference disclosure

Per DEC-023. When a presented region's old and new content differ in bytes but render identically or near-identically, highlighting alone communicates nothing — the user sees a region marked changed with no visible change, which reads as a tool bug.

Version one detects and discloses:

| Class | Examples | Status |
|---|---|---|
| Normalization forms | `U+005A U+0307` vs `U+017B` | In v1 — measured present |
| Zero-width and bidi controls | ZWJ, ZWNJ, ZWSP, soft hyphen, bidi overrides | In v1 |
| Whitespace lookalikes | NBSP vs space, tab vs spaces, Unicode spaces | In v1 |
| Homoglyphs | Cyrillic `а` vs Latin `a` | **Deferred** — needs UTS #39 confusables |

Requirements:

- Disclosure uses a **non-color** indicator (DEC-016).
- Expanded mode provides always-on codepoint revelation, consistent with its definition as the everything-expanded preset. No fourth mode is added.
- These checks operate on presented regions only, so cost scales with change size, not file size.

**Security note.** Bidi controls and homoglyphs are the mechanism behind the Trojan Source attack class (CVE-2021-42574), in which source renders differently from how it compiles; diff tools that render such changes invisibly are the delivery vector. Two of the three accepted classes defend against this. Deferring homoglyph detection leaves that half undisclosed, and that limitation must be stated plainly in user documentation rather than left implicit.

## 7. Derived rules for implementers

Binding consequences, stated so they are not rediscovered or quietly reversed:

1. The **textual layer is authoritative**; the structural layer is **advisory**. Where they disagree about whether something differs, the textual layer wins unconditionally.
2. The structural layer may re-order, re-anchor, re-group, and re-label. It may not create or destroy the fact of a difference.
3. **Moves must carry their internal delta.** A move asserts content appears in two places; if the moved content also changed and the move discards that delta, a difference vanishes and INV-2 fails. See OQ-026.
4. **Ambiguity lowers confidence; it never resolves arbitrarily.** Repeated identical nodes admit multiple valid matchings. See OQ-027.
5. **"Formatting-only" is a label and a collapsed group with a disclosed count.** It is never a filter. Expansion must be immediate.
6. **Raw mode is always available**, on the same pinned source pair, so any structural claim can be checked against plain text.
7. **Parser failure is a normal state**, not an exception. Auto-refresh on save means half-typed source is routine. It must produce visible fallback, never a missing change.
8. All three modes operate on the **same pinned source pair**, so switching modes can never change which versions are compared.

## 8. What this model does not guarantee

Stated honestly, so no reader over-reads the guarantee:

- It does **not** guarantee that structural alignment is optimal, or even good. It guarantees that alignment quality can never cost correctness.
- It does **not** guarantee that classifications (formatting-only, potentially behavior-affecting) are correct. It guarantees they never remove anything from view.
- It does **not** guarantee that move detection finds every move, or that detected moves are the ones a human would identify.
- It does **not** guarantee anything about files above the runtime validation threshold beyond what tests cover — hence the explicit unverified marking.
- It says nothing about whether a change is *important*. That judgment is out of scope by design.

## 9. Open questions owned by this document

- OQ-003 — resolved by DEC-021; retained for history.
- OQ-042 — which algorithm defines `D`.
- OQ-043 — runtime threshold value and above-threshold behavior.
- OQ-044 — invisible-difference classes (partially resolved by DEC-023; homoglyphs deferred).
- OQ-045 — explicit engine rule that the structural layer never sees normalized text.
- OQ-026 — move detection and its internal-delta trap.
- OQ-027 — repeated-node ambiguity policy.
