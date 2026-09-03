# Area C — classification and quietening: verified

Verified by the lead agent rather than a subagent, after three subagent attempts died to transient
server errors. Instrumentation that would need a rebuild was not added, because two sibling verifiers
were reading the same tree; where a verdict depends on such a number the label is
NEEDS-MEASUREMENT and the exact instrumentation is stated.

---

## The headline: what DEC-083 did to this whole area

**Since DEC-083 (2026-08-14) the `formatting-only` group has no visual expression on a mark.**

`docs/04-decision-log.md:3541`:

> **The change textures go** (`--ds-tex-*`, all seven). This touches DEC-035, so the rule is restated
> rather than dropped: **the mark's greyscale signal is the tint pair** … `ds-moved` keeps its dashed
> outline and `ds-invisible` its dotted one — those two are shapes rather than textures, and both
> mark something a reader cannot otherwise detect.

`Renderer/src/index.html:215-221` implements exactly that: `ds-changed`, `ds-formatting`,
`ds-behaviour` and `ds-uncertain` all take `background-color: var(--ds-tint-seg)` and nothing else.
`markItems` adds `ds-formatting` *alongside* `ds-changed`, so `.ds-line-add .ds-changed`
(`index.html:324-327`) applies the strong tint regardless.

So the 96.6% figure is **not** a defect in the classifier. It is a measurement of a quantity that,
by decision, does not change a single pixel of a mark. The classification's only surviving consumers
are the footer's disclosed count, the formatting-only fold grouping, and `data-classification` for
the probes.

**DEC-083's own revisit trigger has fired.** It reads:

> Reopen the first point if a reader ever asks *why is this line marked* — the textures and the notes
> were the answer to that question, and what replaces them is the footer's count plus Expanded.

The owner's observation 1 — *an attribute that did not change is drawn with the stronger tint, as if
it had been added* — **is** that question. This is the single most consequential thing in area C and
no candidate found it, because no candidate could read the decision log.

### S-3, settled

**Deliberate, not a regression.** The stylesheet is right and the checks are right to test only
visibility. What is wrong is one sentence: `Renderer/src/main.js:13-15` still claims

> A group is a presentation grouping, never a filter: the segment keeps its label and its
> bytes stay on screen. Structural mode quietens formatting-only marks; Expanded drops the
> quietening. Both modes render the same segment set (INV-5).

*"Structural mode quietens formatting-only marks"* has been false since DEC-083. A comment asserting
a rule the body does not have is the exact failure shape the UI audit named. **CONFIRMED as a stale
claim; REFUTED as a rendering defect.**

## Where the 96.6% goes — measured

| | presented bytes | loud bytes | loud share |
|---|---|---|---|
| shipped | 2699559 | 2607458 | 96.6% |
| `--ws-class 0` (layout classifier off) | 2699741 | 2634245 | 97.6% |

So of the 92101 bytes that are quiet at all, **DEC-101's whole layout apparatus contributes 26787**
(1.0 percentage point) and `changeClassification` on the gap pair contributes the other ~65300.

The residue that the layout classifier *should* have reached and did not is measurable directly:
**`whitespace-only-mark` = 10405 marks in 469 pairs** — presented segments whose bytes are entirely
whitespace and whose `classification` is nil. `classifyLayoutMarks` is the pass that exists to
classify exactly those, and it does not reach them.

Why it does not reach them requires the verdict distribution of `hunkLayout` over
`layoutRegions`, which is not instrumented. **That is the one measurement this area most needs.**

## Reproductions

A pure prettier wrap classifies correctly — so the coarse claim that the rule never fires is wrong:

```
const x = foo(alpha, beta);              →  const x = foo(\n  alpha,\n  beta,\n);
*  1 | const x = foo⟦changed/whitespace|(
*  2 |   ⟧alpha⟦changed/whitespace|,
*  3 |   ⟧beta⟦changed/trailing-comma|,
   4 | ⟧);
formatting-only=3
```

A wrap **with an insertion** leaves the insertion's flanking whitespace inside the same mark, which
is then unclassified and loud:

```
<Img src={a.src} alt="" />   →   <Img\n  src={a.src}\n  loading="lazy"\n  alt=""\n/>
*  1 | <Img⟦changed/whitespace|
*  2 |   ⟧src={a.src}⟦changed|
*  3 |   loading="lazy"
*  4 |   ⟧alt=""⟦changed/whitespace|
   5 | ⟧/>
formatting-only=3
```

The middle mark spans `\n  loading="lazy"\n  ` — the inserted prop plus the line break before it and
the indent after it. It is correct in extent and unclassifiable by the current rule, because it is
not made **entirely** of whitespace.

---

## Verdicts

**C1 · classification never re-derived after the marks are re-cut — CONFIRMED (code-true, low
consequence).** `StructuralDiff.swift` `emitGap` is the only writer of `classification` besides
`classifyLayoutMarks`; `reconcile` copies the field onto every sub-slice it produces
(`StructuralDiff.swift`, the `.changed` branch), `widenPresented` grants it to widened flanks under
the agreement rule (`Widening.swift:23`), and nothing recomputes it. So a label proven about a gap
does end up on a range it was not proven about. Consequence is bounded by DEC-083: the label changes
no pixel of the mark. It does change the footer count and fold grouping.

**C2 · the reflowed whitespace-only restriction is inert — NEEDS-MEASUREMENT.** Refuted in the strong
form: the pure-wrap reproduction above classifies three marks, so the path is live. But it buys only
1.0 percentage point corpus-wide and leaves 10405 whitespace-only marks unclassified. *Run:*
instrument `hunkLayout` to emit its verdict per region into the survey JSON, then report region counts
by verdict and, within `reflowed` regions, marks visited versus marks passing `allWhitespace`.

**C3 · 0.6 against a 0.8 floor marks a certainty as a doubt and blocks merging — CONFIRMED.**
`Contract.swift:18` `confidenceFloor = 0.8`; `StructuralDiff.swift` `reconcile` assigns `confidence:
0.6` to bytes an anchor called unchanged and the canonical mask calls changed. That is a statement
about a disagreement, not about doubt — the canonical diff is authoritative by DEC-021, so the change
is certain. Corpus: `crosses-the-floor` refuses 4622 junctions in 1198 pairs, and uncertain marks are
4564 (6.5%). Both numbers are this rule.

**C4 · classification is monotonically destroyed and never recreated — CONFIRMED.** Three sites, one
policy: `Coalesce.swift:51`, `AbsorbIslands.swift:106`, `WordSnap.swift:183`, all
`last.classification == segment.classification ? last.classification : nil`, plus `Widening.swift:14`
`agreed(...)` returning nil on disagreement. `classifyLayoutMarks` runs before all of them and only
writes where `classification == nil`, so nothing after it can add a label. DUPLICATE of S-2 in
mechanism, but the "never recreated" half is its own claim and it holds.

**C5 · "reordered", "substantive", merge-erasure and never-visited share one representation —
CONFIRMED.** `Segment.classification` is `String?`; there is no case distinguishing *judged and
deliberately unlabelled* from *lost* from *never asked*. `hunkLayout`'s `.reordered` and
`.substantive` both fall to `continue` in `StructuralDiff.swift`, writing nothing.

**C6 · disclosure blocks merging and fragments the region it explains — CONFIRMED (code-true),
NEEDS-MEASUREMENT for the count.** `Coalesce.swift` refuses on `last.disclosure == segment.disclosure`.
The survey's junction reasons report `disclosure` at **0** across the corpus, so the fragmentation is
real in code and does not fire on this corpus. *Run:* a corpus containing invisible differences; the
current one has effectively none.

**C7 · disclosure is computed only on gap pairs — CONFIRMED.** `invisibleDifference(old:new:)` is
called in exactly one place, `emitGap`, and only when `!equal`. Bytes promoted by `reconcile`, bytes
relabelled by `applyMoves`, and every byte on the fallback path never reach it. The absence of a badge
is therefore not evidence of absence.

**C8 · the formatting-only group's count is a count of a nearly empty set, so INV-5 passes
vacuously — CONFIRMED, and reframed by DEC-083.** True, but the reason is not a broken classifier: the
two modes differ only in quietening, and DEC-083 removed the quietening. The mode switch is a no-op
for marks by decision; what still differs is the fold offer (`Contract.swift:151` — Expanded offers no
formatting group) and codepoint revelation.

**C9 · the reflow rule misses the token prettier moved — CONFIRMED.** The `<Img>` reproduction above
is the case, stated exactly: the mark containing the inserted prop also contains the line break before
it and the indent after it, and `allWhitespace` fails. `WhitespaceHunks.swift` `classifyLayoutMarks`
requires `allWhitespace(segment)` for the `reflowed` branch.

**C10 · merging collapses three agreeing formatting classes into NONE — CONFIRMED.** DUPLICATE of S-2
in mechanism, but the specific claim is sharper and right: `whitespace`, `quote-style` and
`trailing-comma` all map to `ClassificationGroup.formattingOnly` (`Classification.swift:16-19`), yet
`Coalesce.swift:51` compares the **strings**, not the groups, so three formatting neighbours merge to
`nil`. **This is a concrete, cheap repair: compare groups where the strings disagree.**

**C11 · a behaviour-changing reorder is indistinguishable from prettier noise — CONFIRMED.** Two
independent reasons. First, `ChangeClass` has five cases (`Classification.swift:9-14`) against the
eleven `docs/10-diff-engine-specification.md` §3.8 names, and `object-key-reorder`, `jsx-attr-reorder`,
`import-reorder`, `tailwind-class-reorder` are all absent. Second, since DEC-083 `ds-behaviour` renders
identically to `ds-changed` anyway.

**C12 · absorption launders a behaviour-affecting change into a formatting one — REFUTED as stated,
CONFIRMED in reverse.** `qualifies` (`AbsorbIslands.swift:116`) absorbs only `.unchanged` islands, so
no *change* is laundered into formatting; what is laundered is unchanged bytes acquiring a formatting
label they were never judged for. The dangerous direction the candidate names does not exist.

**C13 · 0.6 versus 0.8 manufactures the shredded look — DUPLICATE of C3.**

**C14 · an invisible character in a reconcile-produced region gets no badge — DUPLICATE of C7.**

**C15 · layout-only judgement is behaviour-blind inside template literals and JSX text — CONFIRMED
(code-true), NEEDS-MEASUREMENT for occurrence.** `equalIgnoringWhitespace` (`WhitespaceHunks.swift:8`)
drops layout bytes with no knowledge of syntactic context, and in a `layoutOnly` region
`classifyLayoutMarks` classifies **every** mark unconditionally (`inLayoutHunk`). Inside a template
literal or a `jsx_text` node whitespace is significant, so a real behaviour change can be labelled
formatting. Consequence is bounded by DEC-083 today, but it is a false claim in the model and it
reaches the footer count and the fold. *Run:* intersect `layoutOnly` region spans with
`template_string` / `jsx_text` / `string` node ranges from `stringRegions`-style extraction and count.

**C16 · the preserved-gap rule routes around the reorder guard — REFUTED.** `StructuralDiff.swift`
guards it: the preserved-gap computation sits inside `if layout != .reordered`, so a region judged
`reordered` contributes no preserved gaps at all. The candidate assumed the two rules were
independent; they are nested.

**C17 · confidence never becomes a visible gradient — CONFIRMED.** `markItems` sets
`classes.push("ds-uncertain")` when `seg.uncertain`, and `index.html:217-221` gives `ds-uncertain` the
same `--ds-tint-seg` as `ds-changed` with no outline — unlike `ds-moved` (dashed), `ds-invisible`
(dotted) and `ds-parse-error` (solid). So a below-floor mark is pixel-identical to a certain one.
Deliberate per DEC-083 for the texture; the consequence for confidence specifically is not recorded
anywhere and is worth an entry.

**C18 · reordered regions are the silent majority — DUPLICATE of C5 and C11.**

**C19 · the whitespace-only restriction is inverted because widening runs after classification —
REFUTED.** The order is the other way for the part that matters. `StructuralDiff.swift`:
`layoutClassified(reconcile(...))` runs **before** `absorbIslands`, `snapPresentation`,
`snapToWordBoundaries` and `snapToGraphemeBoundaries`. So a mark that is whitespace-only when the
classifier sees it *is* classified, and later growth keeps the label through `widenPresented`'s
inheritance. What the candidate describes cannot happen in that direction.

**C20 · widening manufactures unclassified bytes at the edge of every classified run — CONFIRMED
(code-true), NEEDS-MEASUREMENT for volume.** `Widening.swift:14-23` grants a widened flank the run's
classification only where every presented segment overlapping the range agrees, and returns nil
otherwise. *Run:* count bytes classified before the widening passes and unclassified after.

**C21 · the disagreement rule is a one-way ratchet and merging is the last stage before display —
DUPLICATE of C4.**

**C22 · the second absorption inherits labels that came from widening rather than from judgement —
CONFIRMED (code-true).** `absorbedAgain` runs after all three snaps (`StructuralDiff.swift`), and
`qualifies` compares `left.classification == right.classification` on flanks whose classification may
itself have been inherited by `widenPresented`. The transitivity is real. Volume unmeasured.

**C23 · the one non-colour channel is spent on the rarest case — CONFIRMED as a design fact.** The
disclosure badge is a text widget (`DisclosureWidget`); `ds-moved`, `ds-invisible` and
`ds-parse-error` are the only shape carriers. Reflow, at 57.1% of pairs, has no channel. This is
DEC-083's revisit trigger restated from the other side and it is the strongest reason to reopen it.

**C24 · the mode toggle is a false affordance — DUPLICATE of C8.**

**C25 · the keeps-it rule makes a stale gap-stage label immune to the layout judgement — CONFIRMED.**
`classifyLayoutMarks` guards on `segment.classification == nil`, and the doc comment states the intent:
*"A segment that already carries a classification keeps it: this pass adds a claim where there was
none, and never overrules one made with more information than it has."* The intent is defensible; the
consequence the candidate names is real, because after `reconcile` the earlier claim may no longer be
about these bytes (see C1).

**C26 · widening guarantees the whitespace-only test fails — REFUTED, same as C19.**

**C27 · prettier's trailing comma pushes a rewrap out of `reflowed` — REFUTED by construction.** The
first reproduction above is exactly this input and it classifies as a reflow: old tokens
`foo ( alpha , beta ) ;` are a subsequence of new tokens `foo ( alpha , beta , ) ;`, so
`isTokenSubsequence` holds and `hunkLayout` returns `.reflowed`. `formatting-only=3`.

**C28 · confidence is a decaying scalar that reaches the reader as one boolean — CONFIRMED.**
`Contract.swift:257` `uncertain: (segment.confidence ?? 1) < confidenceFloor`; the raw number also
crosses as `confidence`, but `markItems` uses it only for a `data-` attribute. Every propagation site
takes `min` (`Coalesce.swift`, `AbsorbIslands.swift:107`, `WordSnap.swift:184`); no site raises.

**C29 · merge's same-claim condition omits classification, so disagreement downgrades rather than
refuses — DUPLICATE of C10**, which states the same thing with the group-versus-string detail that
makes it fixable.

**C30 · absorption propagates a classification outward twice — DUPLICATE of C22.**

**C31 · the two modes differ only in an empty grouping — DUPLICATE of C8.**

**C32 · disclosure is evaluated over the final presented region — REFUTED.** It is evaluated on the
gap pair in `emitGap`, before absorption, widening and merging, on the two corresponding byte slices.
The candidate inverted the order. What is true is C7: regions that never pass through `emitGap` are
never asked.

**C33 · the unsure number nobody sees — DUPLICATE of C17.**

**C34 · gluing makes the program forget — DUPLICATE of C4 / S-2.**

**C35 · reordering is banned from being quiet, and nobody wrote down why that survives a reflow that
also reorders — CONFIRMED as a gap in the record.** `classifyLayoutMarks`'s doc comment explains why
`reordered` must not be quietened and names the fixture that forced it. What is not written down is
what happens when one change is both a reflow and a reorder; the code answers `reordered` and says
nothing. *Run:* the verdict distribution from C2.

**C36 · the verdict is per region but the colour is per mark, so the biggest thing wins both ways —
CONFIRMED.** In a `layoutOnly` region `inLayoutHunk` classifies every mark unconditionally; in a
`substantive` region nothing is classified however whitespace-only a mark is. Both halves are visible
in `classifyLayoutMarks`'s guard. This is C15 and the 10405 unclassified whitespace-only marks stated
as one rule.

**C37 · the reflowed test is harsher than the layout-only test — CONFIRMED**, and that is the whole of
C36's second half. The asymmetry is deliberate per the doc comment (a wider rule was drafted and
refused because `prop-reordering` came out formatting-only), so the repair is not to widen it back but
to give the reflow case a *mark-splitting* answer rather than a labelling one.

**C38 · judge, then change the shape — REFUTED in the direction claimed (see C19), CONFIRMED as the
absence of a second pass.** There is no re-judgement after the widening passes, and nothing asserts
that a mark's classification still describes its bytes.

**C39 · the invisible-character labels have nowhere to go after gluing — NEEDS-MEASUREMENT.** The
badge is emitted per disclosure run in `markItems` and merging refuses across a differing disclosure,
so the run should survive. The corpus reports zero disclosure junctions, so this cannot be settled
here. *Run:* a fixture pair carrying a zero-width character adjacent to an ordinary change.

**C40 · the quiet mode is a lie because there is nothing to quieten — DUPLICATE of C8**, and settled
by DEC-083: it is a lie because the quietening was deliberately removed, not because the group is
empty.

---

## What the candidates missed

1. **DEC-083 removed the quietening, and its revisit trigger has fired.** Every candidate that reasons
   about "the formatting group is empty so the mode toggle does nothing" is chasing a symptom of a
   decision none of them could see. The finding is not *the classifier is broken*; it is *the owner is
   now asking the question DEC-083 said would justify reopening it*.

2. **`Coalesce.swift:51` compares classification strings where it could compare groups.** Three
   different formatting classes merging to `nil` is a one-line repair with a real corpus effect, and
   no candidate named the string-versus-group distinction.

3. **The classification vocabulary is five of the eleven names the specification records.**
   `Classification.swift:9-14` against `docs/10-diff-engine-specification.md` §3.8. Six named classes
   — including every reorder class — have no producer at all.

4. **`main.js:13-15` states a rule the code has not had since DEC-083.** Same failure shape the UI
   audit recorded: a comment describing a rule the body does not implement.

5. **A finding from area E that surfaced here and that no candidate states.** Reproduced:

   ```
   old: <Img src={a.src} alt="" />
   new: <Img\n  src={a.src}\n  loading="lazy"\n  alt=""\n/>
   →  block  old 1–1  new 1–4          (old half printed in full)

   control, same edit, closing tag on the last changed line:
   new: <Img\n  src={a.src}\n  loading="lazy"\n  alt="" />
   →  block  old 1–1  new 1–4  reflowed — the whole old half is withheld
   ```

   `withheldOldRanges` asks whether the old line's tokens appear in `new[block.newStart..<block.newEnd]`.
   The block's new half stops at the last hunk's line, and prettier puts the element's closing `/>` on
   its own **unchanged** line — outside every hunk, therefore outside the block. The old line fails on
   `/` and `>`, tokens that are present on the new side one line past the window, and the whole element
   is printed twice. **This is the owner's observation 2, root-caused.** It belongs to `Unified.swift`
   and is handed to area E.
