# Research — The Losslessness Invariant

**Phase:** 3 (inline, not delegated). Feeds `14-losslessness-and-trust-model.md` and resolves the core of OQ-003.
**Status:** Recommendation ready for decision. Measurements verified locally 2026-07-26.

---

## 1. The question

The brief asked whether "every changed byte" is the correct invariant, or whether Unicode, encodings, line endings, and normalization require a more precise definition.

Answer: **a more precise definition is required**, and the corpus proves it rather than merely suggesting it.

## 2. Measured properties of the actual corpus

Scan of all 21 repositories, tracked files with extensions `.ts .tsx .js .jsx .css .scss .md .json .html`, excluding `node_modules` and files over 2 MB. Read-only; nothing modified.

| Property | Count | Share |
|---|---|---|
| Files scanned | 6105 | — |
| Contain non-ASCII | 3126 | **51%** |
| Contain CRLF | 34 | 0.6% |
| Mixed CRLF/LF within one file | 0 | — |
| Byte-order mark | 0 | — |
| Invalid UTF-8 | 0 | — |
| **Not NFC-normalized** | **4** | 0.07% |

Non-ASCII content is the majority case, not an edge case. Half of this corpus is affected by any decision about character handling.

CRLF files are all HTML packages under `mailingi-2025/paczki/`. No file mixes line endings internally, which is convenient but must not be assumed to persist.

### 2.1 The decisive case

Four files are not NFC-normalized, and two of them are ordinary source:

```
5bonsai__website__nextjs/src/app/[locale]/case-studies/page.tsx:168
    company: 'ŻABKA',
    Ż  =  U+005A U+0307   (LATIN CAPITAL LETTER Z + COMBINING DOT ABOVE)
    NFC would be U+017B   (LATIN CAPITAL LETTER Z WITH DOT ABOVE)

5bonsai__website__nextjs/src/messages/pl.json:1357
    ą  =  U+0061 U+0328   (a + COMBINING OGONEK)
    NFC would be U+0105
```

These two encodings are **canonically equivalent** under Unicode. A conforming text renderer displays them identically. There is no visual difference whatsoever.

Now consider the edit that will eventually happen: someone retypes that string with a Polish keyboard, producing the precomposed form. The file changes. The rendered text does not.

This one case discriminates between every candidate invariant:

| Comparison basis | Result for this edit | Verdict |
|---|---|---|
| Normalized text (NFC before compare) | **No difference detected** | **Violates the core invariant.** Disqualified. |
| Grapheme clusters | One grapheme "changed" — but old and new render identically | Detects it, cannot show it |
| Unicode scalars | 2 scalars → 1 scalar | Detects it |
| Bytes | 3 bytes → 2 bytes | Detects it |

## 3. Conclusions that follow

### 3.1 Normalization must never be applied before comparison

Not as a preprocessing step, not as an option, not "just for structural matching". Applying NFC to the `ŻABKA` line before comparison makes a genuine textual change vanish, which is precisely the failure the product exists to prevent.

This has a corollary that is easy to get wrong: **the structural layer must not normalize either.** A parser or matcher that internally normalizes identifiers or string literals for comparison purposes will report "unchanged" for a changed string. Since the structural layer is advisory and the textual layer is authoritative, this would be caught by coverage checking — but only if coverage checking exists. It is a strong argument for making coverage a runtime check rather than a test-time-only one.

### 3.2 Comparison granularity: bytes. Display granularity: graphemes.

Recommended split, because it makes the invariant both strong and cheap:

- **Compare on bytes.** Total (works for invalid UTF-8, binary, unknown encodings), unambiguous, and requires no decoding step that could itself be lossy.
- **Snap presented regions outward to grapheme-cluster boundaries for display.** Never split a combining sequence or an emoji ZWJ sequence mid-cluster when highlighting.

The key property making this sound: **outward expansion is monotone**. Growing a presented region can never cause a changed byte to fall outside it. So display-level grapheme snapping cannot break byte-level coverage. Correctness is defined on bytes; readability is achieved on graphemes; the two do not conflict.

### 3.3 A new requirement: invisible-difference disclosure

This is the requirement the `ŻABKA` case actually forces, and it was not in the original brief.

When a presented region's old and new content differ in bytes but render identically or near-identically, highlighting alone communicates nothing. The user sees a region marked "changed" with no visible change — which reads as a bug in the tool and directly damages trust, ironically because the tool was being *more* correct than expected.

The application must therefore detect and explicitly disclose differences that are not visually apparent, minimally:

- Canonically equivalent sequences that differ in normalization form (measured: present in this corpus).
- Whitespace differences that survive into a rendered region — non-breaking space vs space, tab vs spaces, various Unicode spaces.
- Zero-width characters — ZWJ, ZWNJ, zero-width space, soft hyphen.
- Bidirectional control characters.
- Homoglyphs — visually confusable characters from different scripts, e.g. Cyrillic `а` U+0430 vs Latin `a` U+0061.
- Line-terminator differences where relevant.

Suggested treatment: mark the region with a distinct non-color indicator (consistent with DEC-016) and make codepoint-level inspection available. Expanded mode is the natural home for always-on codepoint revelation, which fits its DEC-013 definition as "everything expanded" without needing a fourth mode.

**Security note, in scope by accident rather than design:** bidi control characters and homoglyphs are the mechanism behind the "Trojan Source" class of attacks (CVE-2021-42574), in which source code renders differently from how it compiles. Diff tools that render such changes invisibly are the delivery vector. A tool built to this invariant defends against that class as a side effect — provided invisible-difference disclosure is implemented. This is worth stating explicitly so the requirement is never optimized away as cosmetic.

### 3.4 Line endings and encoding are Git-layer concerns, not diff-layer concerns

The diff engine should receive exact bytes and never perform EOL or encoding transformation itself. Whether Git applies `core.autocrlf` or `.gitattributes` filters when producing blob content is a separate correctness hazard, delegated to the Git integration research. The engine's contract is: *bytes in, bytes out, unmodified.*

The 34 CRLF files mean this is not theoretical here.

## 4. Recommended invariant, stated formally

Let `O` and `N` be the exact byte sequences of the old and new sides of a pinned source pair. Let `M` be the presentation model the engine produces. Let `R = {r₁ … rₙ}` be the set of byte ranges `M` presents as changed — including edits, moves, formatting-classified changes, and fallback regions.

**INV-1 — Reconstruction.**
`reconstruct_old(M) = O` and `reconstruct_new(M) = N`, byte-for-byte, for both sides.

**INV-2 — Coverage.**
Let `D` be the canonical minimal diff of `O` and `N` computed over **bytes** by a fixed, deterministic algorithm with no structural input. Then every byte belonging to any hunk of `D` lies **within** some range in `R`.

Note this is containment, not intersection. Intersection would permit presenting a one-byte marker for a five-hundred-byte change and still passing.

**INV-3 — Equality honesty.**
`M` presents "no changes" if and only if `O = N` as byte sequences.

**INV-4 — Fallback visibility.**
Every range in `R` produced by fallback rather than structural analysis is marked as such in the presentation.

**INV-5 — Mode agreement.**
For a given pinned source pair, Structural and Expanded modes produce identical `R`. They differ only in presentation flags. (Follows from DEC-013; stated here because it is machine-checkable and belongs with the other invariants.)

### 4.1 Why this formulation

- INV-1 is cheap, total, and catches gross model defects. Any model that loses content fails it immediately.
- INV-2 is the one that catches the specific failure this product fears: the structural matcher confidently pairing two nodes and silently dropping the delta between them. INV-1 alone does **not** catch this — a model can reconstruct both sides perfectly while presenting a region as unchanged, because reconstruction data and presentation data are different parts of the model.
- INV-3 makes the most user-visible failure trivially checkable.
- Defining `D` over bytes avoids a decoding step that could itself lose information, and works uniformly for text, binary, and invalid-UTF-8 content.

### 4.2 Cost

Both checks are linear in file size with sorted intervals. `D` costs a character-level diff, which is the expensive part on large files.

Recommendation: run INV-1 through INV-3 **at runtime for every file below a size threshold**, and in tests unconditionally for all fixtures. Runtime checking converts the invariant from a claim into an enforced property, and gives a defined failure action: on violation, discard the structural presentation for that file and fall back to raw, marked visibly. The performance threshold is a Phase 5 number, pending budgets (OQ-031).

## 5. Open questions this raises

- **OQ-042 — Which canonical diff algorithm defines `D`?** It must be fixed and deterministic, since the invariant is stated relative to it. Myers over bytes is the obvious candidate. It need not be the algorithm used for *presentation* — only for *validation*.
- **OQ-043 — Runtime coverage-check size threshold**, and behavior above it. Options: skip the check and mark the file as unverified, or force raw mode above the threshold. Marking as unverified is more honest than silently skipping.
- **OQ-044 — Which invisible-difference classes ship in v1.** Normalization and zero-width are measured or cheap; homoglyph detection needs a confusables table (Unicode provides one) and is a larger commitment.
- **OQ-045 — Does the structural layer ever see normalized text?** Recommended answer: no, never. Needs stating as an explicit engine rule so no future agent adds normalization as an optimization.

## 6. Sources

- Unicode Standard Annex #15, Unicode Normalization Forms — https://unicode.org/reports/tr15/
- Unicode Standard Annex #29, Text Segmentation (grapheme cluster boundaries) — https://unicode.org/reports/tr29/
- Unicode Technical Standard #39, Security Mechanisms (confusables) — https://unicode.org/reports/tr39/
- Trojan Source, CVE-2021-42574 — https://nvd.nist.gov/vuln/detail/CVE-2021-42574 and https://trojansource.codes/
- Corpus measurements: performed locally on 21 repositories, 2026-07-26. Script retained in the session scratchpad; results reproduced in §2 above.
