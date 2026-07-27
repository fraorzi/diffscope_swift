# Glossary

Authoritative definitions for terms used across this documentation set. These terms are used **precisely** and several of them differ from casual industry usage. Where another document uses one of these words, it means what is written here.

Terms marked **(provisional)** are expected to be refined during Phase 5 and may change; changes must be recorded in the decision log.

---

## Source and identity

**Source pair**
The two byte sequences being compared: the *old side* and the *new side*. A diff is always computed for exactly one source pair. Everything the application displays for a file must be derived from a single source pair.

**Side**
Either `old` or `new`. Used to disambiguate ranges, which are always relative to one specific side.

**Blob**
An exact byte sequence for one side of one file, as obtained from Git or from the working tree. A blob is bytes, not text — decoding to text is a separate, potentially lossy step that must be tracked explicitly.

**Pinned source pair**
A source pair captured together with a content hash for each side. All analysis, rendering, and user interaction refer to the pinned pair. If the underlying file changes on disk, the pin becomes **stale** and the application must either re-pin (recompute) or clearly indicate staleness. A pinned pair prevents a *mixed-version diff*.

**Mixed-version diff**
A defect in which parts of a displayed diff are derived from different versions of a file, typically because the file changed on disk mid-analysis. Classified as a **correctness** failure, not a refresh nuisance.

---

## Ranges and edits

**Range**
A contiguous interval within one side, identified by byte offsets. A range is meaningless without its side. Ranges — not line numbers — are the primitive unit of the internal model, because line numbers cannot express intra-line edits or line-ending changes.

**Edit**
An assertion that a specific range on the old side corresponds to a specific range on the new side, and that they differ. An edit may be nested inside another edit (see *nesting*). Edits are the unit that the coverage check operates on.

**Unchanged region**
A range pair asserted to be byte-identical between the two sides. An unchanged region is a **claim** that the validator can and must check; it is not an absence of information.

**Nesting**
The property that an edit may contain child edits describing the difference at a finer granularity — for example a changed JSX element containing a changed attribute containing a changed string literal containing a single changed character. Nesting is how the application shows precise edits without presenting a whole enclosing node as replaced.

**Move**
An assertion that content present on both sides appears at a materially different position. A move is **not** a claim of equality: a move may carry its own nested edits when the moved content also changed. A move that discards its internal delta is a losslessness violation and is a known trap.

**Fallback region**
A range pair for which structural analysis was not attempted, failed, or was rejected for low confidence, and which is therefore presented using a plain textual diff. Fallback regions are always **visible to the user** as such. Silent fallback is prohibited.

---

## Diff engine concepts

**Alignment**
The chosen correspondence between old-side and new-side content. Alignment determines what is presented as "the same thing, changed" versus "removed and separately added". Improving alignment is the core value of the product. Alignment **may not** determine whether a difference exists — only how it is presented.

**Structural layer**
The analysis layer that parses source into a syntax or structural representation and proposes alignments. It is **advisory**. It may re-order, re-anchor, re-group, and re-label edits. It may not create or destroy the fact of a difference.

**Textual layer**
The authoritative layer operating on exact bytes. It determines what differs. Where the structural layer and the textual layer disagree about whether something differs, the textual layer wins, unconditionally.

**Canonical minimal diff (provisional)**
A deterministic, character-or-grapheme-level difference computed directly from the source pair with no structural input. Its purpose is to serve as the **reference against which presentation coverage is checked**, not to be displayed. See *coverage*.

**Coverage (provisional)**
The property that every hunk of the canonical minimal diff intersects at least one presented edit, move, or fallback region. Coverage is the machine-checkable half of the core invariant; it is what catches "the structural matcher silently swallowed something".

**Reconstruction (provisional)**
The property that the old side and the new side can each be reproduced byte-for-byte from the internal model alone. Cheap, total, and the other half of the core invariant.

**Confidence**
An honest, presentable measure of how certain the structural layer is about an alignment. Low confidence must lead to visible degradation (fallback, or an explicit indicator), never to a confidently-wrong pairing presented as fact. Ambiguity — for example among repeated identical sibling nodes — must reduce confidence rather than be resolved arbitrarily.

**Classification**
A label attached to an edit describing its nature, for example *formatting-only*, *reordering*, *potentially behavior-affecting*. A classification affects grouping and presentation only.

**Formatting-only**
A classification asserting that an edit changes whitespace, line breaks, indentation, quoting, or similar without changing non-formatting content. **It never means hidden.** If formatting-only edits are collapsed by default, their count must be disclosed and expansion must be immediate. Formatting-only is a statement about the *kind* of change, not about its *importance*.

**Potentially behavior-affecting**
A classification for reorderings that cannot be assumed safe — most notably spread-prop ordering and object-property ordering, where order can change the result. Such changes are never normalized away.

---

## Git concepts

**Comparison scope** (short: **scope**)
The pair of Git states being compared, for example *unstaged working tree vs index*, *staged vs `HEAD`*, *current branch vs merge-base of a base branch*, *commit vs its parent*. The scope determines how each side's blob is obtained.

**Base branch**
The branch a feature branch is compared against, typically via merge-base. Its name cannot be assumed to be `main` or `master`; the workspace population splits roughly evenly between the two.

**Merge base**
The common ancestor commit used as the old side when comparing a branch against a base branch, so that changes made on the base branch since divergence are not attributed to the feature branch.

**Staleness**
The condition where remote-tracking data no longer reflects the remote. The application does not silently run `git fetch`; therefore staleness is a state that must be **communicated**, not hidden or automatically resolved.

---

## Presentation

**View mode**
One of the diff presentation modes. Working names are *Smart*, *Exact*, and *Raw Git*; these names and their exact definitions are **not final** and are an open question.

**Raw view**
A presentation of an ordinary textual Git diff, always available, serving as the trusted control view. Its availability is a trust commitment, not a convenience feature.

**Control view**
A view whose purpose is to let the user verify that a more sophisticated view did not lie to them.

---

## Process terms

**Decision status values** — used in `04-decision-log.md`:

| Status | Meaning |
|---|---|
| Accepted | Decided as recommended; treat as settled. |
| Accepted with modification | Decided, but differing from the recommendation. The deviation and its consequences are recorded. |
| Rejected | Considered and declined. Recorded so it is not silently revisited. |
| Deferred | Deliberately postponed to a named later phase or version. |
| Open | Raised, not yet decided. |
| Research required | Cannot be decided without evidence from Phase 3 or 3.5. |
| Provisional assumption | Being worked under as an assumption, without confirmation. Carries elevated risk and must be flagged for confirmation. |

**Spike**
A timeboxed experiment whose purpose is to answer one specific question with evidence. Spike code is **thrown away**; only the recorded result survives, in `22-experiment-log.md`.

**Revisit trigger**
A named, concrete condition that would justify reopening an accepted decision. Written at decision time so that later reopening is principled rather than arbitrary.
