# Diff-engine audit — candidate defects (divergent phase)

Produced 2026-09-03 by 25 isolated generators, five per area, under `/adhd` cognitive frames.
**No generator had access to the repository**, no tools, and every one was forbidden to cite a
`file:line` — a guessed line number is worse than none. Each was given only: the pipeline described
in prose, the invariants, the owner's three observations, and the corpus measurements.

**The set is not pruned.** The skill prunes to three by default; that is switched off here, because
the pruned ones are exactly the awkward edge cases an audit is for. 200 candidates, of which many
are near-duplicates within and across areas — collapsing them is the verifier's job, not the
generator's.

Labels are assigned in `diff-audit-verified.md`, one per candidate: CONFIRMED / NEEDS-MEASUREMENT /
REFUTED / DUPLICATE.

## Seeds — already reproduced before the divergent phase ran

- **S-1** `absorbIslands` swallows unchanged code between two flanks made only of whitespace.
  Reproduced on `corpus/5bonsai__website__nextjs/013cb0699eb9__src_app__locale__career_page.tsx`;
  `--island 0` shows the correct `changed/whitespace` marks and an unmarked `locale`.
- **S-2** `coalesceAdjacent` / `absorbIslands` launder a `whitespace` classification to `nil`, i.e.
  to full weight, whenever two merged neighbours disagree.
- **S-3** `ds-formatting` is drawn with the same tint as `ds-changed`; `main.js` claims a quietening
  the stylesheet does not implement, and no check compares the two.

## Baseline the candidates are measured against

4016 pairs, all structural. false lines 9079 (17.5% of `+`), missed lines 7083 (19.9% of `−`),
marks 70039, presented bytes 2699559, **loud bytes 2607458 = 96.6%**, uncertain marks 4564 (6.5%),
`reflowed-block` 5822 in 2295 pairs (57.1%), `split-mark` 26330, `whitespace-only-mark` 10405,
`micro-island` 1332, `duplicated-line` 106 in 74 pairs, `silent-old-side` 203 in 166 pairs.
Junction refusals: `link` 21703 (concentrated in 76 data-file pairs), `crosses-the-floor` 4622 in
1198 pairs.

---

# Area A — alignment

Myers over bytes, `shiftToReadableBoundaries` and its three ranks, `relocateBuriedMatches`, the
`matchConsumeFloor` = 8 consume rule, the work budget, determinism.

## A/inversion

**A1 · Slide rank ignores which side reads best.** The rank of a landing is judged per side and the
two are combined by `max`, so a hunk can slide to a position that is a whole line on one side and
mid-expression on the other. *Check:* record the old-side and new-side rank of each chosen landing
separately; count hunks where they differ by more than one step.

**A2 · Equal-minimality is local, so slides chain.** Each hunk slides independently and may consume
a match; the merged hunk is then eligible to slide again, so displacement composes without bound.
*Check:* log per-hunk pre/post offsets and consume counts; plot total displacement against hunk
length.

**A3 · The 8-byte consume floor is a constant against an indentation-scaled input.** At two-space
indent the inter-hunk run at depth 3+ is under 8 bytes; at four-space or tabs it is not, so the same
edit aligns differently in two repos that differ only in formatter config. *Check:* bucket the
corpus by indent unit and nesting depth, compare consume rate and mean mark length; or re-indent
both sides by two spaces and diff the segment sets.

**A4 · Noise-match consumption waives the landing-quality requirement.** The noise branch permits a
consume purely because the consumed match had a ragged edge, with no constraint on where the merged
hunk lands. *Check:* record which branch authorised each consume and the rank of the resulting
landing; count noise-branch consumes landing at rank 3 or at no rank at all.

**A5 · Buried-match relocation preserves total length, not locality.** Nothing bounds how far a
relocated match travels, so a correspondence can be asserted between two unrelated occurrences of a
common token. *Check:* record relocation deltas; inspect the tail beyond ~40 bytes.

**A6 · Work-budget exhaustion degrades alignment without tripping INV-4.** A budget-degraded
canonical diff is presented exactly like a solved one; INV-4 covers the structural/fallback path
decision, not `D`'s own budget. *Check:* count exhaustions over the corpus; re-run exhausted pairs
with a 10× budget and compare presented bytes.

**A7 · Reconcile trusts a byte diff already slid away from the anchors.** The confidence penalty is
applied against post-shift hunks, so the disagreement is manufactured by the shift rather than found.
*Check:* reconcile twice per pair, once against raw Myers hunks and once against shifted ones; count
segments whose label or confidence differs.

**A8 · Repeated siblings make the alignment order-arbitrary but deterministic.** Inserting sibling k
versus k+1 is equally minimal and the tie is broken by scan order, so the change is attributed to the
first or the last sibling systematically. *Check:* delete one sibling from repeated-list regions in
real files and see which sibling is marked; mirror the sibling order and confirm the bias flips.

## A/competitor

**A9 · Hunk sliding lands on the wrong line of a repeated block.** Many equally-minimal positions all
sit at whole-line boundaries; the tie goes to traversal order, not to proximity to the semantic edit.
*Check:* histogram displacement; cross-check the post-slide hunk against the anchor gap it came from.
(≈ A1, A8)

**A10 · The consume floor is calibrated for prose, not TSX punctuation.** `}> `, `" />`, `),`,
`});`, `: "`, `</` are all under 8 bytes and all consumable, so a line of props collapses into one
hunk. *Check:* log consumed-match content; bucket by pure-punctuation; measure consume-chain length
per line.

**A11 · The noise escape hatch fires on every identifier fragment.** In camelCase-heavy TSX a short
match almost always begins or ends inside a word, so the escape hatch is the common path rather than
the exception. *Check:* count consumes by branch; if noise dominates, the rank guard is decorative.

**A12 · Indentation-only reflow makes every line boundary equally alignable.** Every line gains a
leading-whitespace change, so every line boundary is a rank-1 landing and the block is aligned by
indentation coincidence rather than by content. *Check:* synthesise pairs by re-indenting a block by
two spaces; the ideal answer is one mark per line covering only the indent — measure the actual
presented total.

**A13 · The work budget silently degrades alignment without changing the label.** Exhaustion
truncates mid-file, producing a precise first half and a degenerate second half. *Check:* counter per
pair against file size and presented ratio. (≈ A6)

**A14 · Alignment is asymmetric under argument order.** `relocateBuriedMatches` tests whether "the
neighbour's other side has room", a one-sided condition; the shift ranks a position against a file
rather than against the pair. *Check:* run the corpus forward and with old/new swapped, mirror, and
diff the segment sets.

**A15 · Trailing-comma and dangling-punctuation edits are attributed to the neighbouring line.** For
"append one item", the whole-line landing wins and pulls in the untouched previous entry. *Check:*
filter for pure single-element appends and count pairs presenting more than the appended line plus
the comma.

**A16 · Reconcile lets a slid byte diff override correct anchors, and the confidence signal is
invisible.** Every alignment defect becomes presented change the structural layer disagreed with, and
the only trace is a number the renderer may not read. *Check:* count presented bytes existing only
because of reconcile promotion; then check whether the renderer encodes confidence at all.

## A/3am

**A17 · Budget exhaustion is invisible and size-dependent.** Same as A6 from the on-call side: the
reader cannot tell an exhaustive answer from a rationed one. *Check:* exhaustion rate; 10×/100×
re-run diff.

**A18 · Budget is spent on the prefix, so the tail of a file is systematically coarser.** One global
budget spent in recursion order means alignment quality is a function of how much unrelated churn
precedes an edit. *Check:* prepend increasing churn before a fixed small edit and plot presented
bytes.

**A19 · Hunk sliding has no total order, so ties break by traversal accident.** Three rank buckets
over a slide range that in reflowed code is saturated at the top bucket. *Check:* count positions
sharing the winning rank per slide; flip the comparison from `>` to `>=` and diff the corpus.

**A20 · The 8-byte floor reads nesting depth, not edit relatedness.** *Check:* histogram consumed
match lengths against 8; re-indent uniformly and count pairs whose mark count changes. (≈ A3)

**A21 · The noise escape hatch bypasses the landing-quality guard.** *Check:* log the authorising
disjunct and the final landing rank; look for chains of consecutive noise-authorised consumes. (≈ A4)

**A22 · Relocation preserves total length but not location, and reconcile makes it binding.** *Check:*
count bytes anchors called unchanged that reconcile flipped, bucketed by whether relocation touched
the containing match; disable relocation and see whether the flip count drops.

**A23 · Nothing bounds how far a hunk may slide.** No absolute displacement cap; in repeated content
the equal-minimality range spans many lines. *Check:* displacement tail; count pairs where the slid
hunk ends outside the region the matched nodes cover.

**A24 · Reconcile launders a bad alignment into high-confidence presentation.** Confidence is lowered
only at reconcile and only for flipped bytes; the snaps then extend edges into ordinary-confidence
bytes and the merge only refuses across the floor, not across a difference. *Check:* trace confidence
through snap/absorb/merge; measure the distribution at reconcile time and again at render time.

## A/remove-the-assumption

**A25 · Slid hunks land on lines the author never touched.** *Check:* fraction of pairs where the
post-slide presented range does not contain the pre-slide range; read the top 50 by distance; test
whether disabling the shift removes the owner's observation 1. (≈ A1, A9)

**A26 · Indentation-only reflow produces a minimal alignment that is not the semantic one.** Myers may
find it cheaper to match new indentation whitespace against unrelated old whitespace than to match
identifiers, so the layout classification then fires on the wrong segments. *Check:* build a
provably layout-only subset by re-running prettier at a narrower print width; any non-whitespace
segment on that subset is the defect.

**A27 · The consume floor swallows the tokens TSX is made of.** *Check:* histogram surviving-match
lengths; re-run with the floor at 2/4/8/16 and measure presented bytes and pairs changed.

**A28 · "Begins or ends inside a word" is nearly always true in camelCase code.** *Check:* count
consumes by branch; isolate pairs whose only change is a class-string edit or an identifier suffix
and measure presented/true ratio.

**A29 · Three ranks cannot separate candidates; the tie-break is positional.** *Check:* reverse the
candidate enumeration and diff the segment sets; log how many positions share the winning rank.

**A30 · Relocation conserves length globally, not locally.** *Check:* displacement distribution;
whether long-displacement relocations are over-represented in the owner's reported cases.

**A31 · Budget exhaustion degrades silently, against the spirit of INV-4.** *Check:* exhaustion rate
against size and reflow degree; recompute unbounded offline and measure the gap.

**A32 · One alignment serves both the validator and the reader, and the invariant wins every
conflict.** INV-2 forbids contraction, so an alignment error can only ever be inflated by the
downstream passes. *Check:* instrument presented-byte totals after each stage; identify pairs where
the post-diff total is near the true edit and the final total is an order of magnitude larger; check
whether any stage ever reduces presented bytes.

## A/ant-colony

**A33 · The consume floor turns indentation runs into consumable filler, and consumes chain.**
*Check:* log every consume with the consumed bytes; count chains of ≥2 on one hunk; compare presented
totals against raw Myers, bucketed by median indent depth.

**A34 · Rank 1 is a gravity well that drags hunks off the real edit.** Whole-line strictly outranks
whitespace-adjacent, so a hunk is pulled to column zero even when a whitespace-adjacent boundary sits
exactly on the changed token. *Check:* fraction of hunks ending exactly at a line start; bytes newly
covered by the shift that a token-level oracle calls unchanged.

**A35 · Relocation and the shift are not confluent — order decides.** Relocation changes individual
match lengths, and the consume rule is a threshold on individual match length, so relocation
reshuffles what is consumable. *Check:* run both orders and diff the segment sets; log matches whose
length crosses 8 as a result of relocation.

**A36 · Repeated JSX boilerplate lets Myers pick an equally minimal but semantically wrong pairing.**
The middle snake is not unique when short byte sequences repeat. *Check:* compare the byte diff's
implied correspondence against the node mapping's; test stability by prepending one newline to both
files.

**A37 · The budget degrades alignment without crossing the fallback boundary.** *Check:* exhaustion
per pair correlated with presented ratio and mark count. (≈ A6, A13, A17)

**A38 · Reflow saturates the top rank, so the shift picks by tie-break.** *Check:* count top-rank
landing candidates in the slide window per hunk; record whether the chosen landing's line contains
any byte a token-level oracle calls changed.

**A39 · The noise predicate protects punctuation-only matches and discards identifier fragments.**
`">\n` is not "inside a word" and must clear the rank bar; `assN` inside `className` is noise and is
consumed freely — exactly backwards. *Check:* log noise-classified matches with their bytes and the
character classes on both flanks; tabulate the top 100 by frequency.

**A40 · The shift optimises a position that the later passes then move by up to 48 bytes.** The
syntax snap exempts an edge already at a line start — precisely the outcome the shift strives for —
while an edge the shift deliberately placed at rank 2 is free to be widened. *Check:* record each
hunk's range after the shift and again after the last pass; bucket drift by whether the post-shift
edge was rank 1 or rank 2.

---

# Area B — widening and mark shaping

`absorbIslands` (both passes), `snapPresentation` (16), `snapToWordBoundaries` (24),
`snapToGraphemeBoundaries`, `coalesceAcrossWords`, `coalesceAdjacent`, `widenPresented`, and the
inheritance rules for classification / confidence / label / link that all of them carry.

## B/logistics

**B1 · Double consolidation: the second absorption feeds on the first pass's swelling.** A 30-byte
gap the first pass correctly refused is trimmed under 8 by the snaps eating it from both ends, and
the second pass swallows the remainder — the 8-byte promise bounds nothing observable. *Check:*
record island length at pass 1 and at pass 2 for the same range; count ranges pass 1 refused and
pass 2 accepted.

**B2 · An absorbed island inherits a classification never measured on it.** Classification is
computed only on the gap pair; absorption inherits from flanks by agreement, so two `quote-style`
flanks stamp `quote-style` onto an intervening byte-identical identifier. *Check:* for each absorbed
island, test whether its own bytes satisfy the predicate its inherited classification asserts.

**B3 · The syntax snap widens to the boundary of a node the change never entered.** A one-character
change inside `className="foo"` is within 16 bytes of both ends of the attribute, so both edges snap
and the whole attribute becomes one mark — the owner's observation 1 in mechanism form. *Check:* log
each widening with the node kind and the widened/changed byte ratio; bucket by kind.

**B4 · Asymmetric last mile: a snap that succeeds on one side and fails on the other.** The two sides
are widened independently against their own trees; a linked pair no longer covers corresponding text.
*Check:* record per-side widening deltas per linked pair; count pairs where one widened and the other
did not.

**B5 · The in-word merge launders low confidence into a confident-looking mark.** The general merge
refuses across the floor; the in-word rule waives it, and the word snap has just made
"meets inside a word" common rather than exceptional. *Check:* count in-word merges whose two inputs
straddled the floor; measure how many marks change side of the floor with and without the exception.

**B6 · Nothing ever re-splits, so a merged mark can have a long unchanged interior.** Merge unions two
widened marks that overlap only in their widened flanks; no pass narrows. *Check:* for every final
mark compute the longest contiguous run of bytes covered by no canonical hunk; histogram.

**B7 · The line-start exemption is one-sided, so marks lean right on wrapped code.** The left edge at
a line start is exempted while the right edge widens up to 16 bytes. *Check:* measure left- and
right-widening separately; restrict to marks whose left edge is at a line start and compare.

**B8 · The string-literal word rule over-packs: whitespace-to-whitespace ships a sentence for one
letter.** In `/api/v2/users` or a long `className` there is no whitespace within 24 bytes, so the
full budget is spent both ways. *Check:* compare widening for literals with and without internal
whitespace; bucket by literal shape.

## B/regulator

**B9 · The 8-byte rule is a length test standing in for a semantic test.** `!`, `?.`, `=== `, `null`,
`true`, `Bearer ` are all under 8 bytes and all absorbable, and the output carries no residue of the
fact that a byte was absorbed rather than diffed. *Check:* rank absorbed island texts by frequency;
count the share that are operators, keywords or literals.

**B10 · The line condition is satisfied by a flank far off-screen.** "Every line the island touches
already carries a presented byte" is a line predicate, and Next.js `className` lines run 200–400
columns. *Check:* record the column distance from each absorbed island to the nearest presented byte
of each flank; count absorptions over 120 columns away.

**B11 · Two disagreeing flanks launder their disagreement into "unclassified".** `nil` is the same
state as "never classified", so a provably mixed mark is indistinguishable from an unanalysed one.
*Check:* add a provenance bit distinguishing never-classified from classification-lost; count both
over the corpus.

**B12 · Lower-confidence-wins is a ratchet with no floor and no audit trail.** Three stages lower and
none raises; a long accreted run carries the confidence of its single weakest byte and nothing
records which. *Check:* per final mark, log the minimum-contributing offset, the number of lowering
events, and the delta from the maximum contributor.

**B13 · Snapping to a syntax boundary asserts an edit at node granularity that never happened.**
*Check:* count widenings that fully cover a JSX attribute name or object property key whose bytes did
not change. (≈ B3)

**B14 · The word snap's two definitions of "word" collide at string boundaries.** One mark's two edges
can be widened under two incompatible rules. *Check:* count marks where the two edges used different
definitions, and widenings that consumed the full 24-byte budget.

**B15 · Two absorption passes compose into a widening the single-pass conditions would refuse.** The
"no longer than the shorter flank" test is evaluated against current flank length, and the snaps grew
the flanks. *Check:* snapshot island verdicts at both passes keyed by byte range; for each range
refused-then-absorbed, compute how much of the deciding flank length came from the snaps.

**B16 · The in-word merge dissolves the barrier it is excepted from.** Inside a string a "word" is a
whole Tailwind class or URL segment, so the exception's premise that a word is atomic does not hold.
*Check:* split in-word merges by identifier vs string-literal token; record whether one side was below
the floor.

## B/extreme-budget

**B17 · The relative-length clause is inverted for the case the pass exists for.** A 1-byte flank can
never absorb even a 2-byte island, so the smallest edits — the ones that fragment worst — are exactly
the ones absorption declines to repair, while two large rewrites separated by `, ` sail through.
*Check:* count absorptions blocked solely by the shorter-flank clause where the island was ≤2 bytes;
tabulate the top absorbed island strings.

**B18 · Every conflict resolves to "no classification", and absence renders as the loud answer.**
Three passes, one policy: conflict collapses to absence, and absence is not neutral. *Check:* count
segments unclassified at render whose contributing pre-merge segments were all classified, grouped by
which pass erased it.

**B19 · Grapheme snapping is a no-op on the corpus.** Steps 11 and 12 have already landed on ASCII
boundaries; the one real case, non-ASCII inside a string, is already swallowed by the word snap.
*Check:* count segments modified and bytes added by the grapheme snap over all 4016 pairs; delete the
stage and diff.

**B20 · The 16-byte budget is a node-kind filter with a number written on it.** Too small ever to
reach a JSX attribute boundary, too large ever to fail on an identifier. *Check:* log the distance to
the nearest enclosing node boundary and the node kind per snap attempt; bucket by kind and see whether
JSX kinds cluster above 16 and identifier kinds below 4.

**B21 · The string-literal word rule eats whole class lists.** *Check:* compare marked bytes inside
`className` strings against canonical hunk bytes inside the same strings. (≈ B8)

**B22 · The widening passes are provenance-blind and dress up fallback guesswork.** A fallback mark's
byte boundaries are the only thing known about it, and they are grown by up to 40 bytes. *Check:*
force the fallback path on a structural sample and compare bytes added per pass in both modes; check
whether any pass is guarded on provenance.

**B23 · The in-word merge's dominant real input is reconcile-demoted material.** A rename where the
anchor matched a prefix is exactly the in-word geometry. *Check:* log in-word merges with both input
confidences and whether either was demoted by reconcile.

**B24 · Budgets are stated per pass; the composition is unbounded.** 16 + 24 + a grapheme adjustment,
then an island that only became eligible because of that growth, then a merge that only became
possible because both grew. *Check:* per canonical hunk, record hunk length and the final presented
range containing it; plot the amplification ratio and re-run with each pass disabled to attribute it.

## B/inversion

**B25 · Only line starts are exempt from the syntax snap, so a trailing edge bleeds onto the next
line.** A trailing edge just before a newline finds its nearest outward boundary at the start of the
following line's first token, and one stolen indent byte tints a whole untouched line. *Check:* log
edge moves that cross a newline; count marks whose final range ends on a different line than the
pre-snap range while no canonical hunk touches that line.

**B26 · The word snap has no stopping rule inside punctuation runs.** An edge inside `})}`, `?.`,
`=>`, `))]`, `/>` has no boundary at its position, so the search walks the whole run and then the
whole neighbouring identifier. *Check:* bucket marks by the character class at each pre-snap edge and
plot bytes added per bucket.

**B27 · The budgets compose into a ~56-byte blind span between two one-character changes.** *Check:*
for marks containing ≥2 disjoint hunks, histogram the largest unchanged interior run. (≈ B6, B24)

**B28 · The second absorption measures islands against inflated flanks, so the guard stops rejecting.**
*Check:* count pass-2 absorptions that would have been rejected under pre-snap flank lengths; run
absorption to a fixpoint and count absorptions beyond pass 2. (≈ B1, B15)

**B29 · "Every change in the run agrees" is vacuous for a single-change run.** Which is the common
case, so widened flanks are routinely stamped with a classification that was never about them.
*Check:* per classified segment, measure the fraction of its bytes inside a canonical hunk;
cross-tabulate by run size.

**B30 · Adding one Tailwind class marks its two neighbours.** *Check:* filter pairs whose only hunk is
inside a JSX string attribute and matches a class-token-plus-space shape; check whether the final mark
extends past the hunk into a neighbouring token.

**B31 · The confidence floor turns the noisiest regions into confetti.** Reconcile lowers confidence
exactly on reformatted regions; the merge then refuses to join across the floor, and the in-word rule
is the only crossing — never available across the whitespace and punctuation that dominate reformatted
code. *Check:* correlate reconcile-lowered bytes against final marks per changed line; count merge
refusals with reason `crosses-the-floor` (baseline: 4622 in 1198 pairs).

**B32 · Each side widens independently, so linked marks stop corresponding.** INV-5 constrains the two
modes against each other, not the two sides. *Check:* per surviving link, compare endpoint lengths and
mark counts per side; confirm no existing check asserts cross-side link agreement.

## B/biology

**B33 · Chronic inflammation: the widening loop has no fixed point relative to the original diff.**
*Check:* measure each absorbed island's length against pre-snap flank extents. (≈ B1, B15, B28)

**B34 · Scar tissue is stiffer than the wound: widening and absorption erase the classification that
would have excused them.** Monotone downward — every step can only erase, never recover. *Check:*
count marks unclassified at the end whose every pre-widening constituent was classified;
cross-tabulate against the region's layout verdict.

**B35 · Failed apoptosis: a segment reconcile downgraded is never retired and gets recruited into a
large mark.** *Check:* count presented bytes lying outside every canonical hunk, bucketed by the stage
that introduced them; then check whether the renderer reads confidence at all.

**B36 · Clear margins: the word snap excises a whole import path or class string for one character.**
*Check:* restrict to hunks inside string-literal ranges and compare presented/hunk ratio for strings
with and without internal spaces. (≈ B8, B21)

**B37 · Signal cascade: absorption's line predicate is free on the long lines prettier produces.** A
per-line predicate cannot constrain a per-byte decision. *Check:* log whether island and both flanks
lie on one line; measure edits-per-mark before and after absorption on pairs with lines over 100 bytes.

**B38 · Lost regulatory copy: the in-word merge crosses the floor that every other merge respects.**
*Check:* find merges whose two confidences straddle the floor and inspect the extent against the
canonical hunk. (≈ B5, B16, B23)

**B39 · Plasticity overwrites the memory: label and link inheritance is unspecified for absorption.**
A move mark that has been snapped outward is no longer a move, because the added bytes were never part
of the byte-identity comparison DEC-038 requires. *Check:* after the full pipeline, re-verify every
`moved` mark against its linked counterpart's bytes and count mismatches; dump absorbed islands whose
flanks carry different labels or links.

**B40 · Autoimmune: the line-start exemption is one-sided, so a reindent marks whitespace on one side
and not the other.** *Check:* for layout-only and reflowed pairs, compare per-mark whitespace-only
prefix and suffix byte counts on old versus new. (≈ B7, B25, B32)

---

# Area C — classification and quietening

`changeClassification`, `WhitespaceHunks` / DEC-101, confidence and the 0.8 floor,
`invisibleDifference`, the inheritance and destruction of classification, and whether any of it
reaches the reader's eye.

## C/regulator

**C1 · Classification is computed on gap pairs but marks are cut, absorbed, widened and merged
afterwards, and nothing re-derives the label.** The claim "these bytes are quote-style" is only ever
proven about a superset or subset of the bytes that end up carrying it. *Check:* record the byte range
each classification was computed over; at render time count marks whose drawn range is not a subset of
its provenance range.

**C2 · The reflowed-region whitespace-only restriction cannot fire on prettier wrapping.** Reconcile
cuts marks at byte-diff boundaries, which fall where content and whitespace differ jointly, so the
whitespace is rarely isolated into its own mark — the rule is inert exactly in the 57% of pairs it was
built for. *Check:* count regions judged `reflowed`, then count marks inside them passing the
whole-whitespace test; report the ratio.

**C3 · Reconcile's 0.6 marks the most reliable finding as the least trustworthy and blocks merging.**
0.6 encodes "the anchor and the byte diff disagreed", not "we are unsure this changed" — the byte diff
is canonical, so the change is certain — yet 0.6 < 0.8 makes it uncertain on screen and unmergeable.
*Check:* count marks at exactly 0.6; count merges refused solely by the floor; read what 0.6 means at
its write site.

**C4 · Merging destroys classification on disagreement, so quietening loses ground at every merge.**
Absorption, widening and merging can each only preserve or delete a label; nothing after stage 8 can
add one. *Check:* log classification at end of classify-layout and at end of merge; compute
classified-byte survival rate; check whether a distinct "lost by merge" state exists at all.

**C5 · "Reordered regions are classified nothing" collapses the safe answer and the ignorant answer
into one rendering.** Deliberate refusal, substantive, merge-erasure and never-visited all share one
representation. *Check:* attribute every unclassified presented byte to one of the four causes; if the
attribution needs new instrumentation, the distinction does not exist in the product.

**C6 · Disclosure blocks merging and thereby fragments the region it explains.** Disclosure is present
only on the sub-portion carrying the invisible difference, so adjacent marks in one edit
systematically disagree on it. *Check:* count merge refusals attributable to disclosure alone; compare
mark counts with and without that clause on pairs where any disclosure fires.

**C7 · Disclosure is computed only on gap pairs, so invisible differences inside reconcile-promoted,
moved and fallback regions are never detected.** The absence of a badge is an unfalsifiable
non-claim. *Check:* measure what share of presented bytes lie outside any gap pair; construct pairs
placing a zero-width character in each of the three bypassing routes.

**C8 · The formatting-only group's disclosed count counts a nearly empty set, so INV-5 passes
vacuously.** Two modes that differ only in quietening an empty group render identically, and no test
over real diffs can distinguish a correct implementation from one that silently drops labels. *Check:*
render both modes per pair and count segments whose presentation differs; report the median.

## C/competitor

**C9 · The reflow whitespace-only rule misses the token prettier actually moved.** `foo(a, b)` →
`foo(\n  a,\n  b,\n)` moves a comma and a paren; the mark is not pure whitespace and is skipped.
*Check:* dump per reflowed region the marks visited, the marks passing the predicate, and bytes in
each bucket; re-run with the predicate relaxed to "the mark's non-whitespace bytes are a contiguous
token run on the other side".

**C10 · Classification computed at the gap stage is destroyed by merging into NONE.** A rewrap
produces `quote-style` next to `trailing-comma` next to `jsx-whitespace` — all formatting-only, all
pairwise different, all collapsed to nothing. *Check:* log every merge with both input
classifications; count merges where both mapped to the formatting-only group but differed as strings.

**C11 · A genuine behaviour-changing reorder is indistinguishable from prettier noise.**
`object-key-reorder`, `jsx-attr-reorder` are in the vocabulary but unreachable for a reorder spanning
anchors, and the reordered verdict then denies a label deliberately. *Check:* mine pairs where two
adjacent spread attributes or object properties swap; assert the verdict is `reordered` and the
classification `nil`; then check whether any renderer affordance distinguishes them.

**C12 · Absorption launders a behaviour-affecting change into a formatting one.** An island flanked by
two formatting marks becomes formatting though its bytes were never judged. *Check:* per absorption,
record the inherited classification and whether the island's bytes are all whitespace; report count and
byte volume of formatting-inheriting islands containing non-whitespace.

**C13 · 0.6 against a 0.8 floor manufactures the shredded-element look.** Rewrapping is precisely the
case that generates dense anchor/byte-diff disagreement, and the floor then forbids recombination.
*Check:* histogram marks per canonical hunk split by whether any mark carries 0.6; count merge
refusals by reason in reflowed regions.

**C14 · Disclosure is scoped to gap pairs, so an invisible character in a reconcile-produced region
gets no badge.** *Check:* inject ZWJ and RTL overrides at positions falling inside a gap pair and
inside a reconcile-only region and compare; grep the corpus for existing zero-width and bidi
codepoints and measure badge coverage. (≈ C7)

**C15 · Layout-only judgement ignoring whitespace is behaviour-blind inside template literals and JSX
text.** `` `p-4 ${x}` `` → `` `p-4${x}` `` passes whitespace-insensitive equality, and in a layout-only
region *every* mark is classified formatting unconditionally. *Check:* find regions judged layout-only
whose span intersects a `template_string`, `jsx_text` or `string` node and count them.

**C16 · The preserved-gap rule partially routes around the reorder guard.** The guard is per region;
the finer rule is per token pair, and in a reordered import list or class string most adjacencies
survive, so their separators get quietened. *Check:* assert the finer rule never applies inside a
region judged reordered; count violations, inspecting Tailwind and import cases.

## C/game-design

**C17 · Confidence is computed but never becomes a visible gradient.** Its only consumers are the
merge predicate and the absorption minimum; the renderer keys on label. *Check:* grep the renderer for
any read of confidence; histogram confidence over presented segments and count distinct visual
treatments.

**C18 · Reordered regions are the silent majority and the deliberate silence reads as substantive.**
*Check:* count regions by verdict; cross-reference how many reordered regions carry any of the four
reorder classification names. (≈ C5, C11)

**C19 · The whitespace-only restriction inverts the case it was written for, because widening runs
after classification.** A mark that qualified as whitespace-only at classification time can grow
non-whitespace afterwards; a mark that was already mixed never qualified. *Check:* run the
whole-whitespace test before and after the widening passes and compare.

**C20 · Widening manufactures unclassified bytes at the edge of every classified run.** The inheritance
rule is unanimity over the run, and reordered regions are deliberately unclassified, so mixed runs are
common. *Check:* count bytes that were formatting before widening and none after, as a fraction of
formatting bytes before.

**C21 · Merging's disagreement rule is a one-way ratchet, and it is the last stage before display.**
*Check:* plot classification counts at the entry and exit of absorb / re-absorb / merge. (≈ C4)

**C22 · The second absorption inherits labels that came from widening's unanimity rule rather than
from any judgement of those bytes.** Agreement at pass 2 is agreement about inherited labels.
*Check:* find segments classified formatting at pass 2 whose bytes were never inside a layout-only or
reflowed region; count the bytes.

**C23 · The one non-colour channel is spent on the rarest case.** The disclosure badge is proven to
work and is allocated to a case met once a month, while reflow — 57% of pairs — gets nothing but a
tint. *Check:* count badge emissions against the count of pairs containing a reflowed region; check
whether any classification other than disclosure reaches a non-colour channel.

**C24 · The mode toggle is a false affordance.** *Check:* render both modes and compute the per-byte
weight difference; report the fraction of pairs where it is zero. (≈ C8)

## C/inversion

**C25 · The "already carries a classification keeps it" rule makes a stale gap-stage label immune to
the layout judgement.** *Check:* count segments whose post-reconcile range is a strict subset of the
range that was classified, then how many skip the layout judgement via the keeps-it rule. (≈ C1)

**C26 · Widening guarantees the whitespace-only test fails.** Stages 11–13 pull non-whitespace into any
mark that was whitespace-only. *Check:* measure the whole-whitespace pass count before stage 11 and
after stage 13; the gap is the widening's contribution. (≈ C19)

**C27 · Prettier's trailing comma pushes an attribute-list rewrap out of `reflowed` into `reordered` or
`substantive`.** The multiline form adds a token the single-line form lacks, so neither token sequence
is a subsequence of the other. *Check:* histogram the four verdicts; for each region whose two sides
are equal after stripping whitespace **and trailing commas**, record which verdict it actually got.

**C28 · Confidence is a monotonically decaying scalar that reaches the reader as one boolean.** A
single 0.6 byte drags an arbitrarily large mark under the floor. *Check:* per below-floor mark, the
ratio of below-floor input bytes to mark length; check whether absorption has already homogenised
confidence before merge sees it.

**C29 · Merge's same-claim condition does not include classification, so disagreement is a downgrade
rather than a refusal.** *Check:* snapshot the classification histogram either side of merge; test the
counterfactual where differing classification refuses. (≈ C4, C10)

**C30 · Absorption propagates a classification outward twice, once before and once after widening.**
*Check:* per formatting-classified final mark, the fraction of bytes classified directly versus
acquired by inheritance; sample the high-inheritance tail by hand.

**C31 · The two structural modes differ only in a grouping that is empty.** *Check:* render both modes
corpus-wide and report the fraction of identical renderings. (≈ C8, C24)

**C32 · Disclosure is evaluated over the final presented region, so widening both manufactures false
badges and lets absorption swallow the true ones.** *Check:* build synthetic pairs with a single ZWJ,
an NFC/NFD swap and a bidi override in otherwise-unchanged TSX; count real-corpus badges whose region
is not render-identical after stripping widened flanks.

## C/ten-year-old

**C33 · The unsure number nobody ever sees.** *Check:* search everything that draws a mark for any use
of confidence; count marks under 0.8 and confirm none looks different. (≈ C17)

**C34 · Gluing makes the program forget.** *Check:* count marks with a kind before merging and after,
and how many of the lost ones were formatting. (≈ C4, C21, C29)

**C35 · Reordering is banned from being quiet on purpose, and nobody wrote down why that survives a
reflow that also reorders.** *Check:* record which of the four verdicts each region got, and how often
`reordered` is chosen for pairs that are the same content laid out differently.

**C36 · The kind is decided for a whole region but the colour is per mark, so the biggest thing wins in
both directions.** A real change inside a re-laid-out block gets called layout; one real word inside it
makes the whole block loud. *Check:* take layout-only regions and check by hand whether any mark inside
is a real word change; take substantive regions and count the marks inside made only of whitespace.

**C37 · The reflowed test is much harsher than the layout-only test, and stretching happens afterwards.**
*Check:* run the whole-whitespace test before and after the stretching passes. (≈ C19, C26)

**C38 · The order is backwards: judge, then change the shape.** *Check:* look for any second call of
the layout judgement after the widening passes; if none, measure how many marks changed size while
keeping their old kind.

**C39 · The invisible-character labels have nowhere to go after gluing.** *Check:* find corpus pairs
containing an invisible character and check whether a badge survives and sits on the right characters.

**C40 · The quiet mode is a lie because there is nothing to quieten.** *Check:* render both modes and
count mark-identical results; count marks carrying the formatting kind at draw time. (≈ C8, C24, C31)

---

# Area D — the structural layer

`TSXParser`, `matchTrees`, ambiguity, `anchors` with its five filters and greedy monotone selection,
the gap pairing that classification depends on, `findMoves`, the degradation gates.

## D/remove-the-assumption

**D1 · Reindentation kills every gap on a wrapped subtree.** Adding a wrapper re-indents the body; the
leaf anchors still fire because leaf text is unchanged, but every inter-anchor gap now differs by the
indentation and the all-or-nothing comparison condemns it. *Check:* take the corpus subset where the
two sides are identical after stripping per-line leading whitespace and measure the fraction of bytes
the anchor/gap stage labels changed before reconciliation.

**D2 · The leaf-only filter throws away the node that names the change.** A mapped internal node whose
old and new text are byte-identical is the strongest correspondence evidence there is, and it is
discarded. *Check:* find mapped internal nodes with byte-identical text and no ambiguity; count pairs
where at least one is currently partially marked changed; compare changed bytes with and without
allowing internal endpoints.

**D3 · Monotone greed drops the larger anchor to keep the earlier one.** Selection is first-fit by
offset with no weight, so a one-token anchor can block every genuine anchor behind it. *Check:*
replace greedy selection with a weighted longest-increasing-subsequence over the candidates (weight =
anchor byte length) and diff the presented segments corpus-wide.

**D4 · Byte-identity has no weaker tier, so a renamed identifier de-anchors its neighbourhood.**
`userId` → `userID` is confidently mapped and refused as an anchor, and the two neighbouring gaps
merge. *Check:* count mapped leaf pairs that are non-identical but highly similar and measure the
changed span around each; then admit them as reduced-confidence *boundaries* that bound gaps without
asserting equality.

**D5 · Attribute reorder is unanchorable by construction and shows as delete-plus-add.** A swap
produces two candidates whose old and new orders disagree; the second is dropped unconditionally, and
`findMoves`' content floor will not rescue a short attribute. *Check:* filter for elements whose
attribute-text multiset is unchanged but whose sequence differs; count anchor candidates dropped for
monotonicity alone and their byte weight.

**D6 · Anchor density inflates precision and starves recall at once.** ~4 anchors per line means gaps
narrower than a token, so a whitespace shift condemns them individually — while whole removed regions
with no matched leaf produce no gap pair on the new side at all. *Check:* histogram gap and anchor byte
lengths by node kind; re-run with a minimum anchor length or excluding punctuation-only leaves and see
whether 17.5% and 19.9% move together or in opposite directions.

**D7 · The gap pair is compared as one block when it decomposes into a common prefix and suffix, and
reconcile can never take it back.** Reconcile is one-directional: it promotes unchanged→changed and
never demotes. *Check:* per unequal gap pair, compute the common prefix and suffix and sum the
over-claimed bytes; compare against 17.5%; confirm there is no demotion path in the code.

**D8 · Gate three's justification is untested while the ambiguity filter produces the same degradation
continuously and unmarked.** Fewer anchors means more apparent change — that is gate three's stated
reason for falling back, and the ambiguity filter does exactly that on 76% of commits with no gate and
no disclosure. *Check:* count anchor candidates rejected by the ambiguity filter per pair and correlate
with changed-byte fraction; confirm gate three's counter is zero on the corpus.

## D/hardware

**D9 · No clock-domain crossing between tree offsets and byte offsets.** If anchor text is fetched
through the tree's own slicing, the byte-identity filter is self-consistent even when the offsets no
longer address the same bytes the gap comparison uses. *Check:* assert for every kept anchor that
`bytes[oldStart..<oldEnd]` equals the node text obtained from the tree, on all 4016 pairs; then prepend
a BOM and convert to CRLF and diff the emitted offsets.

**D10 · The monotone commit rule is a stall-and-flush pipeline with no re-queue.** One long-running
commit raises the new-side watermark and the anchors behind it are dropped, not reconsidered. *Check:*
count candidates that passed all five filters and were rejected by monotonicity, with the resulting gap
length; correlate rejected-count-per-gap against gap length and against 17.5%.

**D11 · 710 anchors on 175 lines is a saturation symptom, not a health metric.** The anchor set is
dominated by one-byte punctuation, which is the highest-frequency lowest-information leaf there is.
*Check:* histogram kept anchors by text length and kind; report the one-byte fraction and the fraction
of gaps under four bytes.

**D12 · The ambiguity filter is applied at the wrong stage and rejects the anchors that would resolve
the ambiguity.** Ambiguity is computed before any positional evidence from the committed anchor chain
exists, and it is a hard gate evaluated once. *Check:* count leaves rejected solely by ambiguity and
the gap they sit inside; run a variant admitting ambiguous leaves bracketed by two committed anchors.

**D13 · The gap comparison is a fixed-width all-or-nothing bus transaction.** Mark width is set by
where the nearest anchors landed, not by the extent of the change. *Check:* per changed gap, sum the
bytes tinted despite being in the common prefix/suffix; express as a fraction of all tinted bytes.
(≈ D7)

**D14 · The reconciliation throttle is one-directional and hides the opposite error class.**
Containment is a lower bound on the marked set and says nothing about its upper bound, so marks can
only grow. *Check:* add the mirror measurement — segments the anchor stage called changed that lie
entirely outside every canonical hunk — and report it next to 17.5%.

**D15 · Gate zero and gate two are untested silicon.** Gate zero's most-conservative-wins resolution
only differs from first-match when two conditions fire at once, which the corpus has never produced.
*Check:* synthesise inputs just over each threshold, plus one hitting two gate-zero conditions with
different conservatism, and assert the fallback flag, the segment set and reconstruction on each; log
observed maxima as a fraction of each budget.

**D16 · The matcher's work budget is spent producing a rejection mask.** The top-down phase's only
downstream effect on anchors is to delete candidates, so budget spent enlarging the ambiguous set is
budget spent narrowing the anchor set. *Check:* profile the two phases and attribute budget units;
measure how many kept anchors each phase produces and how many candidates each removes.

## D/3am

**D17 · Anchor density is a function of file size, so identical edits classify differently in a big
file.** *Check:* plot anchors-per-KB and max gap width against file size; inject a fixed single-token
edit into 50/200/1000-line hosts and compare changed bytes.

**D18 · Gate three has never fired, so its fallback path is dead code.** A mid-way abort leaves
partially populated mapping state the fallback must discard, and that discard has never executed.
*Check:* force the budget to a tiny value and re-run the whole corpus, asserting INV-1 and INV-4 on
every result; any hang, throw or unmarked structural segment is the defect.

**D19 · Ambiguity-lowered and reconcile-lowered confidence write into the same channel with no
provenance.** The two demand opposite responses. *Check:* audit every write site of confidence for a
discriminant; bucket below-full segments by cause and see whether the rendering distinguishes them.

**D20 · The byte-identity filter is defeated by prettier reflow, which is the dominant edit shape.**
Whether leaf text spans include surrounding trivia decides this. *Check:* find corpus pairs where
`git diff -w` is empty or near-empty but large spans are marked; for one, dump every candidate that
passed the four non-text filters and failed only byte-identity and see what fraction differ solely in
leading whitespace.

**D21 · Gap pairing assumes gap N on the left corresponds to gap N on the right, and asymmetric
insertion breaks it silently.** When a wrapper is added, the surviving anchor pair straddles the
boundary and the new-side gap holds both the wrapper and the original content. *Check:* construct
wrapper-add pairs and dump the kept anchor list with gap boundaries; measure how often a changed old
gap is a byte substring of the corresponding new gap.

**D22 · 19.9% of removed lines carry no mark, and no invariant catches it.** INV-3 is file-level and
INV-2 is containment of `D`'s hunks — there is no assertion that the union of marked spans covers the
byte diff's changed set per line. *Check:* assert containment of git's removed-line set in the tool's
marked-removed set for all 4016 pairs; establish whether that assertion exists anywhere in the verify
run or is only counted.

**D23 · Half-typed input reaches the structural path because no gate measures syntactic validity.**
Every gate is content-blind; the partial-parse rule keeps the structural result, and anchors are
computed over leaves outside `ERROR` ranges even when the tree's shape is wrong. *Check:* correlate
`ERROR`-covered byte fraction with the false-positive rate; truncate real files inside a JSX attribute
and check whether the ERROR fraction is exposed anywhere.

**D24 · Determinism is claimed across iteration orders but the greedy scan and the ambiguous partition
are both order-exposed.** A leaf can be byte-identical to several leaves at distinct positions; which
pairing the matcher produced decides which anchors monotonicity kills. *Check:* run the corpus with the
mapping container's iteration order reversed and diff the segment sets byte for byte; audit for any
Dictionary/Set iteration between matcher output and the anchor sort.

## D/competitor

**D25 · Byte-identical anchors pair the wrong repeated sibling, and the off-by-one never recovers.**
*Check:* per kept anchor, log the occurrence index of its text on each side; a healthy run has equal
indices, and the defect is a step function that diverges by one and never returns.

**D26 · The ambiguity set is empty exactly where ambiguity is worst.** A pairing established outside
the top-down partition carries no ambiguity flag even when its text occurs a dozen times. *Check:* per
kept anchor, count occurrences of its exact text on each side and cross-tabulate against the ambiguity
flag; then establish the 76% figure's denominator.

**D27 · One early bad anchor starves the whole file, with no backtracking and no cost function.**
*Check:* record per file the number of candidates rejected by monotonicity and the largest new-side
jump between consecutive kept anchors; report the left tail of the anchor-count distribution, not the
mean. (≈ D3, D10)

**D28 · Prettier rewrapping damages one gap per attribute, so the tint is uniform across the element
rather than pointing at the attribute that moved.** *Check:* run prettier at two print widths over
unchanged corpus files and measure marked bytes as a function of attribute count per rewrapped element;
a linear relationship confirms the per-gap mechanism. Also establish whether whitespace and `jsx_text`
tokens are eligible anchor candidates at all.

**D29 · JSX text nodes defeat the leaf and non-empty filters.** A `jsx_text` leaf can span hundreds of
bytes including indentation; kept, it forbids every anchor inside its span, and dropped, it merges two
gaps. *Check:* histogram anchor candidate lengths by node type; compare mark granularity between
copy-heavy and code-dense components.

**D30 · i18n keys and barrel imports produce anchors that pair semantically different occurrences.**
None of the five filters tests structural context. *Check:* per kept anchor, compare the ancestor node
type chain on both sides and report the divergent fraction; check barrel files and i18n-heavy modules
specifically.

**D31 · ERROR-region relabelling launders a badly recovered parse into a confident verdict, and only
*changed* segments are relabelled.** A segment the anchor stage called unchanged inside an ERROR range
stays unmarked — the dangerous direction. *Check:* inject damage tree-sitter recovers from without an
ERROR node (unclosed generic, stray `<` in a type position, unbalanced fragment) and see whether any
ERROR node is produced; count files with a `MISSING` node but no ERROR node.

**D32 · The gates measure the wrong quantity: size, not density.** The files that are hard for this
matcher are not the files that are large. *Check:* rank the 4016 pairs by the two error rates and
inspect the worst decile's size, node count and matcher work against each threshold; then test a
post-hoc gate — anchors per node, or marked bytes over byte-diff bytes — and see whether it separates
the worst decile.

## D/speedrunner

**D33 · One early accepted anchor whose partner sits late eats the rest of the region.** *Check:*
record every candidate that passed the five filters and was rejected by monotonicity together with
whether the byte diff calls that region unchanged; correlate against 17.5%. (≈ D3, D10, D27)

**D34 · The leaf-only filter is a skip that discards the whole reflow case.** The interior nodes that
would have anchored the element as a unit are excluded, and the Java-derived thresholds already refuse
the height-1–2 self-closing subtree. *Check:* build a subset where old and new differ only in
whitespace plus one attribute; dump the anchors inside the element range and see whether they were
dropped by the leaf-only filter or by monotonicity; compare against a build allowing height-1 and
height-2 subtrees with byte-identical text.

**D35 · Ambiguity exclusion is silently a tint-widening policy.** *Check:* segment the corpus by
ambiguous nodes per file and plot mean gap length and the false-changed rate against it. (≈ D12)

**D36 · 710 anchors on 175 lines means anchors are landing on punctuation, and there is no content
floor — unlike move search, which has one.** *Check:* histogram kept anchors by text length and kind;
re-run with a minimum-length or minimum-entropy floor mirroring the move floor and re-measure both
error rates. (≈ D11)

**D37 · Empty gaps on one side may produce unmarked deletions.** A zero-length new gap against a
non-empty old gap is trivially unequal and should mark the old side — but only if degenerate gap pairs
are emitted rather than skipped. *Check:* enumerate consecutive anchor pairs where one gap is
zero-length and the other is not, and check whether a segment is emitted; cross-reference against the
19.9%.

**D38 · Reconciliation is one-directional and cannot repair over-marking, which is the dominant error
mode.** *Check:* per pair, compute bytes marked by the structural result minus bytes marked by the byte
diff, and the reverse; sum both over the corpus and compare against 17.5%. (≈ D7, D14)

**D39 · Move search runs after the labels are already coarse and therefore finds almost nothing.** A
moved element that was also reflowed is inside a changed span that is not byte-identical to anything.
*Check:* count moves per file over the subset where a wrapper was added or removed, and compare against
a byte-level longest-common-substring search at shifted offsets.

**D40 · Zero fallbacks over 4016 pairs means the gates are inert and there is no visible signal
distinguishing success from garbage.** *Check:* log the actual measured value at each gate for all 4016
pairs against the configured threshold; if the observed maximum is orders of magnitude below, the gate
protects nothing. (≈ D15, D18, D32)

---

# Area E — block-level presentation

`changeStops`, `unifiedBlocks` (line snapping, block merging, the peel), `withheldOldRanges`, folds
and their markers, `changedLines` and its newline convention, split versus unified.

## E/game-design

**E1 · The counter counts stops, the keystroke walks blocks.** Snapping and merging happen after the
stop list is derived, so `m` overstates the destinations the reader can reach. *Check:* report stop
count and post-merge block count per pair; assert consecutive keystrokes from the top produce exactly
`m` distinct destinations and that the last contains the last presented byte.

**E2 · Split and unified do not share a navigation index.** Only unified applies snap-and-merge, and
INV-5 constrains segment sets, not stop indices. *Check:* walk both layouts stop by stop and compare
the byte offset of the first presented byte at each index.

**E3 · The peel can remove the line a stop points at.** A point stop covers no bytes, so it does not
veto the peel; a pure insertion at the start of a byte-identical line pair lets that pair peel away
while the stop's anchor still points at it. *Check:* find stops empty on one side lying at a block
boundary and check whether the adjacent pair peeled; assert every stop's anchor byte lies inside some
rendered block after peeling.

**E4 · The reflowed expander is a door the reader cannot see is a door.** Three marker styles for one
concept, and the reflowed case is the modal experience at 57% of pairs. *Check:* count reflowed blocks
and check whether the reflowed header renders any affordance stronger than an ordinary block header —
same glyph, same weight, same hit target; check whether expander state is exposed to the navigator.

**E5 · The forward cursor withholds lines that moved backwards.** The match need not be contiguous, the
matched new tokens are not checked against having been claimed as changed, and the forward scan is
unbounded. *Check:* for every withheld old line, test whether its tokens appear in the new side under a
strict contiguous match; cross-reference against the 19.9%.

**E6 · Token-free old lines ride along with their neighbours.** A zero-token line matches vacuously,
never breaks a withheld run, and bridges two islands into one merged range and one count. *Check:*
classify every withheld line as evidenced or vacuous; report the vacuous fraction and how many vacuous
lines are non-whitespace; grep withheld lines for `//`, `/*`, `eslint-disable`.

**E7 · The newline convention splits the gutter edge from the block boundary.** `changedLines` applies
"a range ending on a newline does not claim the next line", while the snap widens to whole lines
terminator included — two conventions over the same bytes. *Check:* for the 203 silent-old-side blocks,
check whether the terminal stop ends exactly on a newline; re-derive `changedLines` without the
no-claim rule and recount.

**E8 · Opening a fold renumbers the level under the reader.** Stops are derived before folding decides
what is out of sight, so revealed old lines have no stop to land on and `m` never changes. *Check:*
expand every fold and expander and diff the stop list; assert navigation after expansion visits at
least one position inside each newly revealed range.

## E/logistics

**E9 · The consignment count is computed at a different depot than the one that packs the box.**
*Check:* distribution of (stops − merged blocks) per pair; compare against split's stop count. (≈ E1)

**E10 · The peel refuses to repack when a point stop sits on the pallet.** If coverage is implemented
as a range intersection or a containing-line lookup, an empty range at offset k touches the line
containing k — and the newline convention says nothing about zero-length ranges. *Check:* of the 105
duplicated lines attributed to "a stop covers it", count how many covering stops are empty on one side
and have zero length.

**E11 · Goods held at the depot with no note on the door.** Withheld lines need not be contiguous with
the block's edges; only the full-half case is named `reflowed` and given an expander. *Check:* emit the
withheld line index set before and after merging and the marker style chosen; count blocks with more
than one withheld island, and partial withholdings whose header text matches the full-reflow case.

**E12 · The cursor never goes back far enough after a failed match.** One unmatchable line pins the
cursor before content the later old lines need, and every subsequent line is KEPT. *Check:* for every
block with at least one KEPT line, re-run the matcher on the suffix after the first KEPT line with a
fresh cursor and count the additional lines that would have been withheld.

**E13 · Empty crates ride along and get counted as freight.** *Check:* per withheld range, total lines
versus lines carrying at least one token; count ranges that would not have merged if token-free lines
had to match. (≈ E6)

**E14 · Snapping OUT can add an edge line that has no counterpart, and the peel only fires on a pair.**
The surplus edge line on the longer side has no partner to compare against, so the peel test is not
applicable and there is no return path. *Check:* record per block the old- and new-side snapped line
counts and how many edge lines rounding added on each side; cross-reference with the 203 silent blocks
and the 19.9%.

**E15 · Two depots, two pack lists, one invariant that only checks the segments.** `changedLines` is
computed in file coordinates; unified re-lines the content. *Check:* per pair, compare the set of
original-file line numbers marked in split against those reachable from unified's signed lines;
classify differences by stage; recompute 17.5% and 19.9% per layout.

**E16 · A package marked delivered that was left at a neighbour's — the withholding size budget.**
Above the budget the block takes the default path as if withholding had been asked and refused, and a
question never asked produces no count to state. *Check:* log per block whether withholding was
attempted or skipped by budget; lift the budget and measure how many skipped blocks would have been
fully or substantially withheld.

## E/regulator

**E17 · The withheld count is a count of lines, not of what the reader lost.** The marker cannot
distinguish a byte-identical hide from a token-subsequence hide. *Check:* per withheld line, record
whether its bytes equal any single new line's bytes versus matching only as a scattered subsequence;
confirm the marker text is identical for both classes.

**E18 · The forward cursor lets one new line absorb many old lines.** The rule does not require the
cursor to have advanced past a line boundary, nor that a new line be consumed by at most one old line.
*Check:* count blocks where more than one old line was withheld against one new line's token span, and
whether any of those old lines contain tokens git reports as removed.

**E19 · Punctuation-only and comment-only lines are withheld cheaply.** The tokenizer has no grammar,
so comment prose is indistinguishable from identifiers and a whitespace-only line has no tokens at all.
*Check:* extract withheld lines that are comment-only or carry no identifier token and check whether
the same text exists anywhere in the new file.

**E20 · The size budget is a silent policy switch, and an unrelated nearby edit can merge two blocks
across it.** *Check:* find the constant; re-run with it raised to infinity and count blocks that flip;
count blocks whose size crossed the budget only because of the merge step. (≈ E16)

**E21 · Merging touching blocks inflates `m` and desynchronises the two layouts' stop counts.**
*Check:* stop counts per layout corpus-wide; assert equality as a test. (≈ E1, E2, E9)

**E22 · The peel and `changedLines` disagree about the same boundary line.** The peel asks about byte
coverage including the terminator; `changedLines` says a range ending on a newline does not claim the
next line. *Check:* for each of the 106 duplicated lines, record which peel clause failed and whether
the covering stop is empty on one side; find lines the two rules classify differently. (≈ E7, E10)

**E23 · Silent-old-side blocks satisfy INV-2's letter and not its spirit.** INV-2 says nothing about a
printed old line containing a presented byte, and the peel only reaches leading and trailing pairs.
*Check:* classify each of the 203 blocks by why its unmarked old lines survived; add an assertion that
every printed old line either carries a mark or is peelable, and count violations.

**E24 · Folding and withholding are held to a promise the code cannot enforce.** There is no INV-1
analogue for the rendered document: a rendering that drops lines without a marker would satisfy every
listed invariant. *Check:* render each pair, programmatically expand every fold, formatting group and
reflow expander, concatenate the visible lines and compare byte for byte against the pinned sources;
assert each marker's stated count equals the lines it reveals.

## E/inversion

**E25 · The peel's stop-coverage test is asymmetric to the insertion-inside-a-line rule.** *Check:* log
every refused byte-equal boundary pair with the stop that refused it and whether that stop was empty on
either side; the 105 "stop covers it" cases should be dominated by point stops. (≈ E3, E10, E22)

**E26 · Merged blocks make the counter and the keystroke disagree.** *Check:* stops, blocks and actual
distinct scroll targets per pair. (≈ E1, E9, E21)

**E27 · Snapping OUT is unified-only, so the two layouts disagree about which lines are changed.**
*Check:* symmetric-difference size per pair between split's marked lines and unified's block lines;
verify the INV-5 check compares segment sets and not rendered line sets. (≈ E2, E15)

**E28 · The single forward cursor withholds an old line whose tokens are a scattered subsequence.** A
short old line of common TSX tokens will almost always match somewhere ahead. *Check:* per withheld
line, record token count and whether the matching new tokens were contiguous or scattered; then ask
whether git calls that line deleted. Any withheld line git calls deleted is a confirmed hidden removal.

**E29 · Reflowed blocks explain the silent old side and the unmarked removals.** The kept old lines are
the residue of the cursor walk, not lines the engine has anything to say about. *Check:* for each of
the 203 blocks record whether withholding ran, whether it was over budget, and how many lines it
withheld; join the unmarked removed lines against the kept-but-unwithheld set.

**E30 · The size budget flips presentation on a byte threshold, and the worst cases get the worst
treatment.** *Check:* bucket the 5822 reflow-candidate blocks by size and plot the fraction where
withholding ran; for blocks just over the budget run withholding offline and measure how many would
have been fully withheld. (≈ E16, E20)

**E31 · The insertion-inside-a-line rule manufactures whole-element removals.** An empty-on-one-side
range inside a line makes that line print as removed; snapping widens it to whole lines and merging
chains it through the adjacent prop lines of a multi-line element. *Check:* find pairs where the
canonical diff touches exactly one line inside a JSX element but the rendered block spans the element;
log the merge chain length and whether any joined range originated as an inside-a-line insertion.

**E32 · Nested and adjacent markers can double-count or under-count hidden lines.** Nothing establishes
single ownership of a line by exactly one marker, yet the count requirement assumes it. *Check:* build
the multiset of hidden line numbers per side and assert it is a set and that its size equals the sum of
the stated counts; check that printed plus hidden equals the file's line count.

## E/markets

**E33 · A netted index, rebalanced without telling its holders.** If `m` is fixed at derivation time
rather than recomputed after merge, the merge silently changes the denominator. *Check:* log raw stop
count pre-merge against block count post-merge; find pairs where one keystroke's landing spans more
than one original stop and check which count is displayed.

**E34 · Terminator arbitrage that never settles.** A leading or trailing pair whose visible text is
identical but whose line endings differ never peels, because the peel is exact-byte including the
terminator. *Check:* find blocks whose first/last old-new pair is textually identical but fails to
peel, and diff the raw terminator bytes.

**E35 · The forward-only cursor sells short on reordered content.** Once the cursor passes token X to
satisfy an earlier old line, no later old line can claim X even if X is its rightful match. *Check:*
on the reflow-shaped pairs, isolate blocks with intra-block line reordering and check whether some old
lines are KEPT solely because an earlier line's match consumed tokens out of order. (≈ E12)

**E36 · Empty shells inflate the withheld count.** *Check:* recompute the count excluding zero-token
lines and compare to the displayed count; measure how often it would drop and by how much. (≈ E6, E13)

**E37 · A reserve price cliff at the size budget.** The computation is skipped entirely past the
threshold rather than degrading gracefully — no sampling, no cap. *Check:* bucket blocks by size around
the threshold and compare withholding rate and printed old-line count immediately below and above.
(≈ E16, E20, E30)

**E38 · A bundled marker hides mixed composition.** If classification is per line but the marker is per
merged run, a mixed run collapses to one label. *Check:* classify each line inside a fold region
independently against the engine's own partition; count regions whose contained lines are not
homogeneous and check which marker style each got.

**E39 · Split and unified quote different mids at the newline boundary.** INV-5 is about segments, not
about which lines a layout decorates; snapping OUT and the newline convention are two different
roundings of the same fact. *Check:* find stops whose snapped boundary lands exactly at a newline and
diff the set of lines each layout marks. (≈ E7, E15, E27)

**E40 · Tranche bundling in the withheld-range merge.** Ranges are merged wherever they touch even when
the underlying lines were withheld for unrelated reasons, and opening the marker does not say which
piece is the one that matters. *Check:* find blocks whose withheld range spans more than one contiguous
match-run of the cursor walk, and check whether those runs sit at non-adjacent cursor positions on the
new side despite being merged into one range and one expander.

---

**200 candidates. Next: `tasks/diff-audit-verified.md`.**
