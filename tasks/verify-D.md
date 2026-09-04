# Verification report — Area D (the structural layer)

Verifier pass over candidates D1…D40 of `tasks/diff-audit-candidates.md`. Read-only: no source file
was modified, nothing was built, nothing was committed. All runs use the shipped release binary
`.build/release/diffscope-verify`.

---

## Evidence gathered before the sweep

Written first, and deliberately in full, because every verdict below leans on it.

### E-A · `reconcile` demotes. It is **not** one-directional.

`Sources/DiffScopeSyntax/StructuralDiff.swift:437-503`. The function has two arms. The
**second** arm (line 471 onward) is the one the candidates describe: an `unchanged` segment
overlapping the canonical changed mask is promoted to `changed` at confidence `0.6`. The **first**
arm (lines 446-468) is the one every candidate missed:

```swift
for segment in segments {
    if segment.label == .changed {
        var cursor = segment.start
        for range in sorted {                       // `sorted` = the canonical changed mask
            …
            if overlapStart > cursor {
                out.append(Segment(start: cursor, end: overlapStart, label: .unchanged,
                                   confidence: 1))          // ← demotion
            }
            out.append(Segment(start: overlapStart, end: overlapEnd, label: .changed, …))
            cursor = overlapEnd
        }
        if cursor < segment.end {
            out.append(Segment(start: cursor, end: segment.end, label: .unchanged,
                               confidence: 1))              // ← demotion
        }
        continue
    }
```

Every part of an anchor-derived `changed` segment that lies outside the canonical mask is rewritten
to `.unchanged, confidence: 1`. Combined with the second arm, the identity is exact:

> **When `coverageKnown` is true, the set of bytes `reconcile` leaves presented is _exactly_ the
> canonical byte diff's changed mask.** The anchors, the five filters, the greedy monotone scan and
> the gap comparison decide **not one presented byte**. They decide only the *subdivision* of that
> mask, the `classification`/`disclosure` strings carried into it, and the confidence (`0.8` where a
> gap explains the mark, `0.6` where no anchor does — i.e. the `~` uncertain flag).

`reconcile` is the **only** site in the pipeline that turns `.changed` into `.unchanged`
(`grep -rn "label: .unchanged" Sources/` returns four other sites: two in `TrivialPartition.swift`,
two in `Widening.swift:69,79`, and both Widening sites are inside `guard segment.label == .unchanged
else { append(segment); continue }` — they split unchanged runs, they never demote).

**Reproduction of the demotion, minimal:**

```
$ printf 'const a = 1;\n' > /tmp/d1.tsx ; printf 'const  a = 1;\n' > /tmp/d2.tsx
$ .build/release/diffscope-verify --emit-structural /tmp/d1.tsx /tmp/d2.tsx t.tsx 0 0
path: structural  anchors=5  ambiguities=0  moved=0  formatting-only=1
=== OLD ===
     1 | const a = 1;
=== NEW ===
*    1 | const ⟦changed/whitespace| ⟧a = 1;
```

The five anchors are the five leaves `const`, `a`, `=`, `1`, `;` — all byte-identical, all
non-ambiguous, all monotone. The gap between anchor `const` (old `0..<5`) and anchor `a`
(old `6..<7`, new `7..<8`) is old `" "` versus new `"  "`. `emitGap` (line 190-214) therefore
emitted **old `5..<6` labelled `.changed`**. The old side of the finished partition carries no mark
at all. Nothing between `emitGap` and the renderer can erase a mark except `reconcile`, and the
old-side canonical mask here is empty because Myers matches every old byte into the new file.
Demotion of an anchor-derived `changed` byte: **proven**.

### E-B · Corpus measurement of the identity, and of what does over-mark

60 corpus pairs (seed 7), marks recovered from `--emit-structural` and compared byte-for-byte
against the complement of `--emit-matches` (which is literally what `canonicalDiff` returns —
`CanonicalDiff.swift:489-519` builds hunks from `canonicalMatches`):

| setting | presented bytes | canonical mask | marked **outside** mask | mask **not** marked |
|---|---|---|---|---|
| shipped (`snap=16 island=8`) | 32637 | 29166 | **4516** | 1045 |
| `snap=0 island=0` | 31221 | 29166 | **3100** | 1045 |

* Not one byte of the excess is the anchor stage's. All 4516 over-marked bytes are produced by the
  wideners downstream of `reconcile` (`snapPresentation`, `snapToWordBoundaries`,
  `snapToGraphemeBoundaries`, `absorbIslands` — `StructuralDiff.swift:348-397`). Turning the syntax
  snap and island absorption off removes 1416 of them; the residue is the word snap and the grapheme
  snap, which `--emit-structural` cannot switch off.
* The 1045 under-marked bytes are **one pair**,
  `corpus/js-gloves__website__nextjs/0dba7fc6a982__src_app__locale__o-nas_page.tsx` — see E-F.

### E-C · What `anchors()` admits (question 1)

`StructuralDiff.swift:72-104`. Five filters, in order: both leaves (`:80`), neither in an `ERROR`
(`:81`), neither in `mapping.ambiguousOldNodes`/`ambiguousNewNodes` (`:82`), both non-empty (`:83`),
**and the texts byte-identical** (`:84`). No length floor, no kind filter, no content floor — unlike
`MoveSearch`, which has `moveContentFloor`.

No instrumentation exists and a build is out of scope, so the histogram is bounded rather than
tabulated. On `/tmp/wrap/before.tsx` (the 1673-byte, 52-line real corpus file used in E-E)
`--emit-structural` reports **`anchors=306`**. A crude tokeniser (identifiers, numbers, quoted
strings, otherwise one character per token) finds **286 tokens, of which 164 — 57.3% — are one-byte
punctuation**, led by `{`×18, `}`×18, `>`×16, `;`×15, `<`×15, `:`×14, `=`×14. tree-sitter's leaf set
can only be a *refinement* of that tokenisation (it splits `'…'` into quote + fragment + quote,
adding more one-byte leaves, and adds `jsx_text`), which is consistent with 306 ≥ 286. The
non-punctuation leaves are bounded above by roughly 122 + a handful of `jsx_text` nodes, so **kept
one-byte-punctuation anchors are at least ~53% of the anchor set** and the true figure is higher.
Mean bytes per anchor on that file: 1673/306 = 5.5, i.e. an anchor roughly every half-token
including the gaps between them.

So: "710 anchors on 175 lines" is the token count of the file, not a health metric. The candidates
that say so are right about the fact. They are wrong about the consequence, because of E-A.

### E-D · The greedy monotone scan (question 3)

```swift
candidates.sort { $0.oldStart != $1.oldStart ? $0.oldStart < $1.oldStart : $0.newStart < $1.newStart }
var kept: [Anchor] = []; var oldCursor = 0; var newCursor = 0
for anchor in candidates where anchor.oldStart >= oldCursor && anchor.newStart >= newCursor {
    kept.append(anchor); oldCursor = anchor.oldEnd; newCursor = anchor.newEnd
}
```
(`StructuralDiff.swift:91-103`)

Two facts follow from the code alone:

1. **The old-side half of the guard can never reject anything.** Candidates are one per `oldID`
   (`mapping.oldToNew` is a dictionary), leaves do not nest and do not overlap, zero-width leaves
   are already filtered at `:83`, and the list is sorted by `oldStart`. So the next candidate's
   `oldStart` is always ≥ the previous kept candidate's `oldEnd` = `oldCursor`. The scan is
   effectively **one-sided**: it drops exactly the candidates whose *new*-side partner sits at or
   before the previous kept anchor's new end — i.e. crossings in the mapping (a move, a reorder, or
   a repeated-sibling mis-pairing).
2. **The sort is a total order and therefore deterministic** despite `mapping.oldToNew` being a
   `Dictionary` with per-process seeded hashing: `oldStart` is unique across candidates, so the
   comparator never sees a tie and the unstable sort has nothing to be unstable about.

Drop counts cannot be read out without instrumentation; the closest available proxy is that
`anchors=306` on a 286-crude-token file and `anchors=1581` on the 1581-anchor
`ProductHeroSection.tsx` pair mean drops are a small minority on ordinary edits.

### E-E · The gates (question 4) — observed maxima

`.build/release/diffscope-verify --budget-survey corpus`, 400 structural files:

| gate | budget | observed max | headroom |
|---|---|---|---|
| gate 1 — `structuralSizeLimit` | 2 097 152 B | 20 816 B | ×100 |
| gate 2 — `structuralNodeBudget` | 30 000 nodes | 3 762 nodes | ×8 |
| gate 3 — `matchWorkBudget` | 10 000 000 units | 118 130 units | ×85 |

`gates on 400 files: size 0, nodes 0, work 0 — structural 400 (100.0%)`. The synthetic block of the
same survey shows where gate 2 and gate 3 *would* fire: a 62 439-node dense-JSX file (gate 2 at
30 000 catches it) and a 32 001-node minified file at 51 312 003 work units. Both gates are
correctly placed relative to the pathological shape; neither is reachable by the corpus.

### E-F · The gate nobody wrote down: `coverageKnown`

`StructuralDiff.swift:239-247`:

```swift
var coverageKnown = false
if case let .exact(hunks) = canonicalDiff(old: oldBytes, new: newBytes) { coverageKnown = true; … }
```

and `reconcile(_:against:applied:)` opens with `guard applied else { return segments }`
(`:442`). When the **canonical diff's own** 40 M work budget is exceeded, `canonicalDiff` returns
`.budgetExceeded` (`CanonicalDiff.swift:495`), `coverageKnown` stays `false`, and:

* `reconcile` becomes the identity — the raw anchor/gap marks are shipped, unclipped;
* `validate()` sets `coverageChecked = false` and **skips the INV-2 containment check entirely**
  (`Validation.swift:133-151`);
* `--emit-structural` still prints `validation: passed`;
* `StructuralStats.degradation` stays `nil` and `usedFallback` stays `false`. Nothing is said.

It fires on the corpus. `corpus/js-gloves__website__nextjs/0dba7fc6a982__src_app__locale__o-nas_page.tsx`
(730 B old, 14 761 B new):

```
$ .build/release/diffscope-verify --emit-matches …/before.tsx …/after.tsx
  old     0  new     0  len    9  "import { "
```

One nine-byte match for a pair that shares seven whole import lines: `canonicalMatches` aborted and
returned its partial `matches` array (`CanonicalDiff.swift:63-74` — on `budget.exceeded` the shift
is skipped and whatever `divide` accumulated is returned). The presented old side of that pair
leaves 527 bytes unmarked that the (partial) mask claims, including four whole runs such as
`"export function generateStaticParams() {\n  return availableLocales.map…"`. This is the only
under-marking in the 60-pair sample and it is the *silent* half of the answer: on these pairs the
structural layer is unsupervised **and** unvalidated, and nothing on screen says so.

### E-G · The constructed wrapper pair (observation 3)

Base file: `corpus/5bonsai__website__nextjs/013cb0699eb9__src_components_features_counter-bar_CounterBar.tsx/after.tsx`,
copied to `/tmp/wrap/before.tsx` (1673 B, 52 lines). `/tmp/wrap/after.tsx` (1742 B) wraps old lines
36–46 in `<div className="x">…</div>` and reindents that body by two spaces:

```diff
@@ -33,16 +33,18 @@
         >
           {hasBg ? <NextImage fill src='/images/homepage/bg_counter.png' alt='' /> : null}
 
-          <div className='relative'>
-            <Heading className='font-bold uppercase text-primary xl:text-6xl' level={1}>
-              {el.prefix ? <span className='font-normal'>{el.prefix}</span> : null}
-              <Counter value={el.head} />
-              {el.suffix ? <span className='font-normal md:text-5xl'>{el.suffix}</span> : null}
-            </Heading>
-            <Paragraph
-              className={clsx('font-semibold tracking-wider', !hasBg && 'text-dark')}
-              dangerouslySetInnerHTML={{ __html: el.text }}
-            />
+          <div className="x">
+            <div className='relative'>
+              <Heading className='font-bold uppercase text-primary xl:text-6xl' level={1}>
+                {el.prefix ? <span className='font-normal'>{el.prefix}</span> : null}
+                <Counter value={el.head} />
+                {el.suffix ? <span className='font-normal md:text-5xl'>{el.suffix}</span> : null}
+              </Heading>
+              <Paragraph
+                className={clsx('font-semibold tracking-wider', !hasBg && 'text-dark')}
+                dangerouslySetInnerHTML={{ __html: el.text }}
+              />
+            </div>
           </div>
         </div>
       ))}
```

`--emit-structural /tmp/wrap/before.tsx /tmp/wrap/after.tsx CounterBar.tsx`:

```
path: structural  anchors=306  ambiguities=5  moved=0  formatting-only=9
validation: passed

=== OLD ===        (no `*`, no ⟦…⟧ anywhere: the old side is entirely silent)
    36 |           <div className='relative'>
    …
    46 |           </div>

=== NEW ===
*   36 |           <div ⟦changed|className="x">
*   37 |             ⟧⟦changed~|<div ⟧className='relative'>⟦changed/whitespace|
*   38 |               ⟧<Heading className='font-bold uppercase text-primary xl:text-6xl' level={1}>⟦changed/whitespace|
*   39 |                 ⟧{el.prefix ? <span className='font-normal'>{el.prefix}</span> : null}
*   40 | ⟦changed/whitespace|                ⟧<Counter value={el.head} />
*   41 | ⟦changed/whitespace|                ⟧{el.suffix ? <span className='font-normal md:text-5xl'>{el.suffix}</span> : null}⟦changed/whitespace|
*   42 |               ⟧</Heading>
*   43 | ⟦changed/whitespace|              ⟧<Paragraph⟦changed/whitespace|
*   44 |                 ⟧className={clsx('font-semibold tracking-wider', !hasBg && 'text-dark')}
*   45 | ⟦changed/whitespace|                ⟧dangerouslySetInnerHTML={{ __html: el.text }}⟦changed|
*   46 |               ⟧⟦changed~|/>⟧⟦changed/whitespace|
*   47 | ⟧            ⟦changed~|</div⟧>
    48 |           </div>

=== UNIFIED BLOCKS ===
   0  old 36–38 new 36–40 reflowed — the whole old half is withheld
   1  old —     new 41–41
   2  old 41–41 new 42–43 reflowed — the whole old half is withheld
   3  old 43–43 new 44–45 reflowed — the whole old half is withheld
   4  old 45–45 new 46–47 reflowed — the whole old half is withheld
```

**Twelve consecutive new lines flagged changed, zero old lines flagged, and four of five unified
blocks withhold the whole old half.** That is observation 3 verbatim.

The marked byte ranges with widening off (`snap=0 island=0`):

```
1073.. 1100  27  changed             'className="x">\n            '
1100.. 1105   5  changed~            '<div '
1127.. 1128   1  changed/whitespace  ' '
1140.. 1141   1  changed/whitespace  ' '
1218.. 1219   1  changed/whitespace  ' '
1233.. 1234   1  changed/whitespace  ' '
1304.. 1306   2  changed/whitespace  '  '
1348.. 1350   2  changed/whitespace  '  '
1458.. 1460   2  changed/whitespace  '  '
1471.. 1473   2  changed/whitespace  '  '
1510.. 1512   2  changed/whitespace  '  '
1584.. 1586   2  changed/whitespace  '  '
1646.. 1660  14  changed/whitespace  '              '
1660.. 1662   2  changed~            '/>'
1662.. 1663   1  changed/whitespace  '\n'
1675.. 1676   1  changed~            '<'
1677.. 1680   3  changed~            'div'
```

and the canonical alignment that produced them, `--emit-matches`:

```
old     0  new     0  len 1073   "…\n          <div "
old  1073  new  1105  len   22   "className='relative'>\n"
old  1095  new  1128  len   12   "            "
old  1107  new  1141  len   77   "<Heading className='font-bold …' level={1}>\n"
old  1184  new  1219  len   14   "              "
old  1198  new  1234  len   70   "{el.prefix ? … : null}\n"
old  1268  new  1306  len   42   "              <Counter value={el.head} />\n"
old  1310  new  1350  len  108   "              {el.suffix ? … : null}\n            "
old  1418  new  1460  len   11   "</Heading>\n"
old  1429  new  1473  len   37   "            <Paragraph\n              "
old  1466  new  1512  len   72   "className={clsx(…)}\n"
old  1538  new  1586  len   60   "              dangerouslySetInnerHTML={{ __html: el.text }}\n"
old  1598  new  1663  len   12   "            "
old  1610  new  1676  len    1   "/"
old  1611  new  1680  len   62   ">\n          </div>\n        </div>\n      ))}\n    </div>\n  );\n}\n"
```

**The old side is tiled by matches end to end — 0→1073→1095→1107→1184→…→1673 with no gap.** The
old-side changed mask is *empty*, so after `reconcile` no old byte can be presented, whatever the
anchors said. The 17 marks above are precisely the 14 new-side gaps of that tiling, subdivided by
the anchor stage.

The same shape on a **real** corpus pair,
`corpus/js-gloves__website__nextjs/1edef025e8d6__src_components_features_product-detail_ProductHeroSection.tsx`
(a genuine `<div className='sticky top-40'>` wrapper added around six lines):

```
path: structural  anchors=1581  ambiguities=1  moved=0  formatting-only=6
=== OLD ===   (lines 138–143: no `*`, no marks — git counts 6 removed lines here)
=== NEW ===
*  138 |             ⟦changed|<div className='sticky top-40'>
*  139 |               ⟧{MaterialLogo && (
*  140 | ⟦changed/whitespace|                ⟧<div className='absolute top-4 left-4 z-10 h-14 md:h-18'>
*  141 |                 ⟦changed/whitespace|  ⟧<MaterialLogo className='h-full w-auto' aria-hidden='true' />⟦changed/whitespace|
*  142 |                 ⟧</div>⟦changed/whitespace|
*  143 |               )}
*  144 |               ⟧<ProductImageSlider key={activeVariantIndex ?? 'base'} images={currentImages} />
*  145 | ⟦changed/whitespace|            ⟧⟦changed~|</div>⟧⟦changed/whitespace|
=== UNIFIED BLOCKS ===
   0  old 138–138 new 138–140 reflowed — the whole old half is withheld
   1  old 140–143 new 141–145 reflowed — the whole old half is withheld
```

Four other wrapper-add pairs exist in the corpus (`cafeb1244d82 …portfolios_ccc_page.tsx`,
`ff8300e3f831 …layout.tsx`, `26169bbcdbf6 …layout.tsx`, `0cd4519b33b9 …offers__slug__page.tsx`).
There are **zero** pairs whose two sides are equal after stripping per-line leading whitespace, so
the "pure reindentation" subset several candidates propose is empty and must be constructed.

---
