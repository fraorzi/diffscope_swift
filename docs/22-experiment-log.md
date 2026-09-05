# 22 — Experiment Log (Phase 3.5)

Durable record of spike results. **Spike code is thrown away; only these results survive** (DEC-032).

Budget: ~3 days, four spikes, selected because they **eliminate** options rather than rank them.

| Spike | Question | Box | Status |
|---|---|---|---|
| X-1 | Do candidate parser/binding pairs report the offsets they claim, on non-ASCII? | 3 h | **Complete** |
| X-2 | Can a candidate render this diff at acceptable speed? | 2 d | **Complete** (web only; native unmeasured) |
| X-3 | tree-sitter and oxc on the 4800-truncation corpus | 1 d | **Complete** |
| X-4 | libgit2 measured, to remove the CLI's testing-order advantage | 4 h | **Complete** |

## Summary — what Phase 3.5 eliminated

| Eliminated | Grounds |
|---|---|
| **oxc** as parser | Returns an empty program for 94.77% of truncated TSX while appearing to succeed (X-3) |
| **Babel** as parser | Throws on 91.67% of truncations; `errorRecovery` does not cover the relevant error class |
| **Any UTF-16 offset used directly** as partition coordinates | Silent corruption, invisible to structural self-checks (X-1) |

| Survived | Note |
|---|---|
| tree-sitter, TypeScript | Both never throw; ranking between them unsettled — metrics not yet comparable |
| Monaco, CodeMirror | Both viable on rendering; decision rests on non-performance criteria |
| Git CLI, libgit2 | Genuinely contested after X-4; CLI leads on more criteria |
| Native macOS rendering | **Unmeasured** — a real gap, not a rejection |

---

## X-1 — Coordinate system trap

**Status:** Complete, 2026-07-26. Partial — TypeScript measured directly; tree-sitter and oxc are not installed on this machine and remain to be covered under X-3.

### Question

Do candidate parsers report position offsets in the unit their documentation and type definitions claim? DEC-024 builds a byte partition, so a mismatch corrupts the model.

### Method

A single source file was constructed so that **UTF-8 bytes, UTF-16 code units, and codepoints all diverge by different amounts** before the measured node:

| Character | UTF-8 bytes | UTF-16 units | Codepoints |
|---|---|---|---|
| `ó` U+00F3 | 2 | 1 | 1 |
| `Ż` as U+005A U+0307 (NFD — the real corpus case) | 3 | 2 | 2 |
| `中` U+4E2D | 3 | 1 | 1 |
| `😀` U+1F600 | 4 | 2 | 1 |

The reported start position of a later node was then compared against all three computed offsets. This design means no two units can be confused, and it uses the actual decomposed `Ż` sequence measured in `5bonsai__website__nextjs`.

### Result — TypeScript 6.0.3

```
reported node position   : 81
JS string index (UTF-16) : 81      ← match
UTF-8 byte offset        : 87
codepoint offset         : 80
```

**TypeScript reports UTF-16 code units.** Confirms the finding in `research/parsers-and-tree-matching.md` by independent measurement. Divergence over this short file is already 6 units.

### The finding that matters more than the unit

Applying the reported offset to a byte buffer does not fail. It returns **different, plausible, wrong text**:

```
src.slice(pos, pos+6)   →  "MARKER"    correct, on the JS string
buf.slice(pos, pos+6)   →  "const "    same number, on the byte buffer
```

No exception, no out-of-range, no corrupted encoding — just a different valid identifier. A partition built this way would be **wrong while looking entirely healthy**.

### Consequence for the test plan — load-bearing

Trace this defect through the invariant tests:

| Test | Outcome | Why |
|---|---|---|
| T-0 partition well-formedness | **PASSES** | Offsets stay monotonic, so segments still tile with no gaps or overlaps |
| T-1 reconstruction | **PASSES** | Concatenating the partition still yields the file |
| T-3 coverage (containment) | **FAILS** | Presented ranges do not contain the bytes the canonical byte diff reports as changed |

This is direct empirical justification for a decision taken earlier on general principle: **T-1 and T-3 are retained even though DEC-024 makes them hold by construction, and are implemented independently of the partition code.** Had T-3 been dropped as redundant, this class of defect would ship silently.

It also refines spike design guidance: a coordinate bug is invisible to structural self-checks and visible only to a check that goes back to raw bytes.

### Verdict

- **[Eliminated]** Using any UTF-16-reporting parser's offsets **directly** as partition coordinates. This is not a tuning matter; it is a correctness defect that structural validation cannot see.
- **[Permitted, with cost]** UTF-16-reporting parsers behind an explicit, independently tested conversion layer. The conversion is then itself a correctness surface requiring its own fixtures — including 4-byte characters, where UTF-16 uses surrogate pairs.
- **[Preferred]** Byte-native bindings — tree-sitter's C, Rust, and **Swift** bindings — which remove the conversion surface entirely.
- **Stack impact:** a JavaScript-hosted engine cannot reach tree-sitter's byte-native offsets, since both JS bindings divide by two (`ts_node_start_byte(node) / 2`; `byte_to_code_unit(byte) { return byte >> 1 }`). This is an input to OQ-033, not merely to parser choice.

### Not covered

tree-sitter and oxc were not measured — neither is installed. Rolled into X-3, which must apply this same discriminating-string probe to both, and to any binding under consideration rather than to the parser in the abstract. **The binding is the unit of measurement here, not the parser.**

---

## X-2 — Rendering bake-off

**Status:** Complete for the two web candidates, 2026-07-26. Native macOS rendering **not measured**. Well under box.

Scoped per decision to **rendering only**, fed a pre-computed diff model — the renderers were never asked to diff anything, matching how the real engine would drive them.

### Method

Synthetic TSX-shaped corpus with the diff model generated ahead of time: line-level and character-level decorations plus alignment gaps. Two scenarios:

- **normal** — 5000 lines, 795 decorations, 42 alignment gaps
- **long** — 3000 lines including six 50,000-character lines, 477 decorations, 25 gaps

Monaco driven as **two plain editors** with `createDecorationsCollection` and `changeViewZones` (the public primitives, not the diff editor). CodeMirror driven as **two plain `EditorView`s** with `Decoration.mark`/`Decoration.line` and block widgets. Linked scrolling wired manually in both.

### Methodology correction, recorded because it invalidated a result

The first harness measured frame time via `requestAnimationFrame`. CodeMirror produced a clean-looking 16.7 ms p50 — then Monaco hung. Instrumenting showed **rAF was firing 0 frames in 3.95 s** in this environment, with both editors present in the DOM. The CodeMirror number was therefore not a measurement of CodeMirror; it was a measurement taken before the environment stopped scheduling frames.

Rewritten to measure **synchronous layout cost per scroll step** (set `scrollTop`, force layout by reading geometry) — a proxy for frame cost, not frame cost, applied identically to both. **Both renderers were re-measured from scratch under the new method.**

A second defect surfaced: CodeMirror's `scrollTop` assignment was silently a no-op (`scrollTop` stayed 0) because the harness CSS left CM's internal scroller unsized — so its near-zero scroll cost meant "did nothing", not "did it fast". Fixed with `.cm-editor{height:100%}` and an **in-harness `scrollWorks` assertion** that fails loudly rather than reporting a flattering zero. Monaco lacks the equivalent assertion; its `setScrollTop` is an API call and its non-trivial timings indicate real work, but that asymmetry is noted rather than hidden.

### Results

| Metric | Monaco 0.56.0 | CodeMirror 6.43.6 |
|---|---|---|
| Bundle size (esbuild, ESM) | **9.3 MB** | **667 KB** |
| normal — create both editors | 176.3 ms | **64.3 ms** |
| normal — apply 795 decorations | 18.1 ms | 17.1 ms |
| normal — 42 alignment gaps | **2.8 ms** | 9.3 ms |
| normal — scroll, 120 steps total | 22.6 ms | **11.3 ms** |
| normal — scroll p50 / p95 / max | 0.1 / 0.6 / 1.4 ms | 0.1 / 0.2 / **0.2** ms |
| long — create | 163.6 ms | **39.8 ms** |
| long — decorations | 7.5 ms | 5.5 ms |
| long — gaps | 5.4 ms | 4.1 ms |
| long — scroll total / max | 22.5 ms / 2.5 ms | **11.4 ms / 0.4 ms** |
| Virtualization confirmed | — | 36 of 5000 lines in DOM |

### Findings

**1. Neither candidate is eliminated on performance.** Both handle 5000 lines with ~800 decorations and 42 alignment gaps in well under a frame budget for scrolling, and both create in under 200 ms. The DEC-014 side-by-side choice is not blocked by renderer capability.

**2. 50,000-character lines produced no cliff in either.** Notably, Monaco was configured with `stopRenderingLineAfter: -1`, disabling its 10,000-character truncation default — so this exercised the **un-truncated** path and still held up. Monaco's `long` create was slightly *faster* than its `normal` create, consistent with cost tracking line count rather than bytes.

**3. CodeMirror leads on most measures**, and by a large margin on bundle size (14×) and create time (2.7×). Monaco leads only on view-zone insertion.

**4. Both require building the diff UI from primitives regardless.** Neither offers a usable external-diff path — Monaco's diff editor rejects an external algorithm through public API, and `@codemirror/merge`'s `DiffConfig.override` returns bare ranges with no room for labels or confidence. So the work of gutters, navigation, collapsing, and alignment is the same either way. This equalises the two more than the raw numbers suggest.

### Verdict

- **[Not eliminated] Monaco and CodeMirror** — both viable on rendering performance.
- **[Not measured] Native macOS text rendering.** Requires GUI work beyond the scratchpad harness and is unmeasured. Since DEC-002 makes macOS-native a first-class option, this is a **real gap** in the bake-off and must be stated as such rather than allowed to look like a rejection by omission.
- The decision between the two web candidates does **not** rest on rendering speed. It rests on bundle size, API stability, and stack fit — which belong to Phase 7.
- **Caveat on all numbers:** measured as synchronous layout cost, in an environment where rAF was unavailable. They are comparable to each other and sufficient for elimination decisions. They are **not** frame-rate measurements and should not be quoted as such.

### Cleanup

Server stopped; the temporary `x2-bakeoff` entry added to `.claude/launch.json` was removed, restoring the file to its prior contents. All harness code remains in the scratchpad and is discarded per DEC-032.

---

## X-5 — Native macOS rendering

**Status:** Complete, 2026-07-27. Funded specifically to close the X-2 gap, because it removes the largest unknown from **two** architecture options at once.

**Toolchain finding:** AppKit and TextKit 2 build and run with **Command Line Tools only** — full Xcode is not required for this measurement (`xcrun --sdk macosx swiftc`). This was itself uncertain beforehand.

### Method

Same corpus file as X-2 (`data-normal.json`): 5000 lines, 795 decorations, 42 alignment gaps. Same measurement method — synchronous layout cost, 120 scroll steps — so the numbers sit alongside the web results rather than beside them.

Decorations applied as `.backgroundColor` (line-level) and `.underlineStyle` + `.backgroundColor` (character-level), matching DEC-035's rule that change meaning is carried by texture and underline rather than token colour. Alignment gaps approximated with `paragraphSpacing`.

### A trap worth recording

The first run reported `textKit2: false`. Cause: **touching `NSTextView.layoutManager` silently downgrades the view to TextKit 1 compatibility mode.** The measurement had therefore exercised the legacy path while appearing to test the modern one.

Re-run with an explicitly constructed TextKit 2 stack — `NSTextContentStorage` + `NSTextLayoutManager` + `NSTextContainer`, never touching `.layoutManager`. Both sets are reported below, because the divergence is itself informative.

### Results

| Metric | Monaco | CodeMirror | **TextKit 1** | **TextKit 2** |
|---|---|---|---|---|
| Create both panes | 176.3 ms | 64.3 ms | 74.5 ms | 108.6 ms |
| 795 decorations | 18.1 ms | 17.1 ms | 30.9 ms | 56.5 ms |
| 42 alignment gaps | 2.8 ms | 9.3 ms | 28.0 ms | 46.4 ms |
| Scroll, 120 steps total | 22.6 ms | 11.3 ms | **2.2 ms** | 20.9 ms |
| Scroll p50 / max | 0.1 / 1.4 ms | 0.1 / 0.2 ms | 0.02 / 0.05 ms | 0.17 / 0.34 ms |

**Measurement caveat, stated rather than buried:** the TextKit 2 scroll figure is a **pessimistic upper bound**. The harness enumerates layout fragments from the document start on each step instead of maintaining viewport state through `NSTextViewportLayoutController`, so its cost grows with scroll depth. A real implementation would not work this way. TextKit 1's figure does not have this problem, which is part of why it looks so much better.

### Findings

**1. Native rendering is viable. There is no performance cliff.** All figures are the same order of magnitude as the web candidates. The unknown that blocked options A and C is closed.

**2. TextKit 2 is measurably more expensive than TextKit 1** on every axis here — roughly 1.5× create, 1.8× decoration, 1.7× gaps — and its scroll advantage disappears under the pessimistic harness. TextKit 2 is Apple's direction and the correct target for new work, so the honest reading is that the modern path costs more than the legacy one at this workload, while remaining acceptable.

**3. Decoration is native rendering's relative weak spot** — 56.5 ms versus ~17 ms for both web renderers, roughly 3.3×. Still comfortably within budget for a per-file operation, but it is the axis where the web candidates lead.

### What this does and does not settle

**Settles:** whether native text rendering can carry this diff view at acceptable speed. It can.

**Does not settle:** how much *engineering* the native path costs. This measured text layout with attributes — not virtualised side-by-side panes, real alignment-gap widgets, collapsed regions, a gutter, linked scrolling, or navigation. Those are the substance of option A's work, and X-5 measured their **floor**, not their total.

So the native risk changes character rather than disappearing: it is no longer *"performance might not work"* — it is *"this is weeks of UI construction the web candidates give you for free."*

### Verdict

- **[Closed] The X-2 native gap.** Options A and C are no longer blocked by an unmeasured renderer.
- **[Recorded] Effort, not performance, is now the native path's cost.**
- **[Recorded] Target TextKit 2, not TextKit 1**, despite TextKit 1 measuring better — and note the downgrade trap, which is easy to trigger accidentally and silently.

---

# M0 — Verification gates

Run before any implementation, because gate 1 could invalidate DEC-042.

## M0-1 — `tree-sitter-typescript` range correctness on real multiline JSX

**Status:** Complete, 2026-07-27. **DEC-042 confirmed on this gate.**

### Question

Issue #306 reports incorrect node ranges for multiline JSX. DEC-024 builds the byte partition from those ranges, so wrong ranges would undermine the architecture.

### Method

All `.tsx` files tracked in the 21 repositories, 500 B – 200 KB: **1375 files**. For each, collect tree-sitter leaf nodes, check whether they tile the source, then build the DEC-024 partition (drop zero-width → clamp overlaps → fill gaps from bytes) and verify it.

### Results

```
parsed successfully        : 1370 / 1375
files containing multiline JSX : 1151 / 1370      ← the #306 population

RAW LEAF TILING
  files with a gap or overlap : 1370 / 1370
  total gaps                  : 226,648
  total overlaps              : 0                 ← decisive
  zero-width leaves           : 1

DEC-024 CONSTRUCTION
  partition valid             : 1370 / 1370
  partition failed            : 0
  filler                      : 930,129 / 3,589,253 chars (25.91%)
```

### Findings

**1. #306 does not manifest as bad ranges on this corpus.** **Zero overlaps** across 1370 files, 1151 of which contain multiline JSX. If node ranges were incorrect in the way the issue describes, overlapping or misplaced ranges would appear here. They do not.

**2. The DEC-024 construction is validated on real code at scale** — 1370 of 1370 files produce a valid partition that reconstructs the source exactly. This is the first test of the construction against the real corpus rather than a synthetic case.

**3. tree-sitter leaves never tile — by design, not by defect.** Gaps appear in 100% of files because tree-sitter excludes inter-token whitespace from leaf nodes. This is why the construction's gap-filling step exists.

**4. Filler is 25.9%, not the ~0.01% measured for TypeScript.** A structural consequence worth carrying forward: TypeScript's node ranges *include* trivia, tree-sitter's do not. So under DEC-042 roughly **26% of bytes live in filler segments carrying no structural label**.

Not a correctness problem — the partition is valid and complete. And there is an unplanned benefit: **the filler segments essentially *are* the formatting.** Whitespace and indentation changes land in filler by construction, which gives the `formatting-only` classification (DEC-017) a natural home rather than requiring it to be inferred.

### Verdict

**Gate passed.** #306 is not reproducible as a range defect on this corpus. DEC-042 stands.

Residual caution: this tested the **Node binding's** view of ranges. The Swift/C path should be spot-checked during M4, though both read the same underlying tree.

### Correction — #306 was mischaracterised in the planning documents

The issue was recorded throughout planning as *"incorrect node ranges for multiline JSX"* and treated as the single highest-priority risk to DEC-042. That description came from a research agent's summary and **was never checked against the issue itself.**

Fetched directly:

> **#306 — "bug: JSX captures whitespaces in nested, multiline tags"** · open since 2024-07-23 · 2 comments

That is a different defect. It concerns JSX **text nodes capturing surrounding whitespace**, not node ranges being wrong. For a byte partition that distinction is decisive: whitespace landing *inside* a leaf rather than in a filler segment changes which segment owns those bytes, but **not** whether the partition is valid, complete, or reconstructive.

Tested directly on the product's own headline example — the `<div>` wrapper with `<Header />` and `<Content />` children:

```
22 leaf nodes · all spans correct · 0 overlaps
jsx_text nodes: 0            ← the #306 behaviour does not even appear here
partition reconstructs exactly: true
```

Inter-element whitespace is simply absent from any leaf and becomes filler, which is exactly what the DEC-024 construction expects.

**Revised risk assessment:** #306 is a **cosmetic/highlighting concern, not a correctness risk to the byte partition.** It should not have been carried as the top pre-implementation risk. Corrected across `04-decision-log.md`, `07-`, `09-`, `17-`, `19-`, `20-`, and `21-`.

**Process note, worth more than the finding:** this risk survived six documents and an architecture decision on the strength of a one-line summary nobody opened the source for. The gate caught it only because the gate existed. Verify the primary source before elevating something to a blocking risk.

---

## M0-3 — Swift tree-sitter binding health

**Status:** Complete, 2026-07-27. **Gate passed.**

Fetched from the GitHub API, 2026-07-27:

| Repository | Last push | Last release | Licence | Open issues | Verdict |
|---|---|---|---|---|---|
| `tree-sitter/swift-tree-sitter` | 2026-05-26 | 0.10.0 (2026-03-18) | **BSD-3-Clause** | 3 | **Healthy** |
| `tree-sitter/tree-sitter-typescript` | 2025-08-29 | v0.23.2 (2024-11-11) | MIT | 47 | **Stale** |

**Findings**

**1. The Swift binding is healthy and officially maintained.** Pushed two months ago, released four months ago, three open issues, and it lives in the **tree-sitter organisation itself** rather than being a community side project. BSD-3-Clause is permissive and clean under DEC-020.

**2. ChimeHQ/SwiftTreeSitter — the widely-used community binding — now redirects into the tree-sitter org.** The community implementation was adopted upstream, which consolidates rather than fragments the ecosystem. A positive signal for a dependency this architecture rests on.

**3. `tree-sitter-typescript` staleness is confirmed with dates.** Last release 20 months ago, last push 11 months ago, 47 open issues. The grammar is genuinely under-maintained.

But with #306 corrected, staleness is now a **generic maintenance risk rather than a specific correctness threat**. MIT licensing means forking remains available if a real defect appears.

### Verdict

**Gate passed.** The binding this architecture depends on is in better health than the grammar it parses with — and the grammar's problem is neglect, not a known break.

---

## M0-1a — Node binding hard size limit (incidental finding)

**Status:** Complete. Not a risk for DEC-042; recorded because it is decisive for a rejected option.

5 of 1375 files failed to parse with `Invalid argument`. Binary search located the boundary exactly:

```
parse(32767 chars)  → OK
parse(32768 chars)  → throws        32768 = 0x8000
chunked callback form, 72,000 chars → OK
```

**This is a `node-tree-sitter` binding limitation, not a tree-sitter limitation.** The C API takes an explicit length; the callback form works around it in Node.

**Consequence:** irrelevant to DEC-042, which reaches tree-sitter through the C API from Swift. But it would have been a live defect in **Option B (full web)** — silently failing on every source file above 32 KB, of which this corpus has several. A retroactive point in favour of the architecture chosen, found only because the gate ran against real files rather than synthetic ones.

---

## M0-2 — Engine↔renderer serialisation cost

**Status:** Complete, 2026-07-27. **Gate passed.** This was the last remaining quantitative unknown in DEC-042.

### Method

A realistic partition built from the largest real `.tsx` file under the Node binding's limit — `5bonsai__website__nextjs/src/app/[locale]/page.tsx`, 23,807 bytes → **5149 segments**, with ~15% marked changed and carrying confidence and classification, as the real model would.

Transferred from Swift into a real `WKWebView` via `evaluateJavaScript`, measured end to end including the JS-side parse. Two encodings compared.

### Results

```
source                    :  23,807 bytes
segments                  :   5,149
JSON payload              : 276,026 bytes   (11.6× source)
flat Int32 payload        :  61,788 bytes → 82,384 as base64

JSON.parse, first call    : 4.65 ms
JSON.parse, steady state  : 1.13 ms
flat Int32 + base64       : 7.36 ms
```

Both paths were verified to deliver all 5149 segments to the JS side.

### Findings

**1. Serialisation is not a bottleneck.** 1.13 ms steady state for a 5000-segment model. Against DEC-026's ~400 ms refresh debounce and the measured rendering costs (CodeMirror creates 5000 lines in 64 ms), this is negligible. **The risk flagged in DEC-042 and `09-recommended-architecture.md` §7 is resolved.**

**2. The obvious optimisation is slower.** A flat `Int32` encoding is 4.5× smaller as bytes (61.8 KB vs 276 KB) and still **6.5× slower end to end** (7.36 ms vs 1.13 ms), because base64 decoding in JavaScript costs more than `JSON.parse` saves. Recorded deliberately: shrinking the payload is the natural instinct when someone later decides this needs optimising, and on this evidence it would make things worse. `JSON.parse` is a native fast path.

**3. The model is ~11.6× the size of the source.** Worth knowing for memory budgeting, though it did not translate into a time cost worth acting on.

### Verdict

**Gate passed. JSON is the right encoding and needs no optimisation.** Revisit only if profiling on much larger files contradicts this — and re-measure rather than assuming a smaller payload will help.

## X-3 — Broken-JSX survival, extended

**Status:** Complete, 2026-07-26. Under box (well below 1 day).

Packages installed into the session scratchpad only, per DEC-032: `tree-sitter@0.21.1`, `tree-sitter-typescript@0.23.2`, `oxc-parser@0.141.0`. Nothing was added to any user project.

### Part A — Coordinate probe extended to all three Node parsers

The X-1 probe was rewritten with **all non-ASCII written as escape sequences**, after discovering that the original X-1 and X-3 probe files disagreed: X-1 contained a true NFD sequence (`U+005A U+0307`) while a re-typed version had silently become precomposed `U+017B`. The conclusion was unaffected — the 4-byte emoji discriminates bytes from UTF-16 on its own — but the probes were not identical across parsers, so the test was made source-normalisation-proof and re-run uniformly.

Probe integrity was asserted in the script itself (NFD sequence present: true).

```
reference: utf16=81  bytes=87  codepoints=80

tree-sitter 0.21.1 (node)   position 81  =>  UTF-16 CODE UNITS
oxc-parser 0.141.0 (node)   position 81  =>  UTF-16 CODE UNITS
typescript 6.0.3            position 81  =>  UTF-16 CODE UNITS

byte-buffer slice at that offset, all three:  "const "   (expected "MARKER")
```

**All three Node-hosted parsers report UTF-16 code units, and all three produce the same silent corruption** when their offsets are applied to a byte buffer.

### Part B — Truncation corpus

**Method.** 120 `.tsx` files sampled deterministically from all 21 repositories (size 800 B – 60 KB, listed via `git ls-files`, read-only). Each truncated at 40 evenly spaced points → **4800 truncation points**. Plus a valid-file baseline pass.

| Parser | Threw | Structural outcome |
|---|---|---|
| **tree-sitter 0.21.1** | **0 / 4800 (0.00%)** | 89.79% of trees contain `ERROR`; **mean 38.4% of bytes lie outside ERROR spans** |
| **oxc-parser 0.141.0** | **0 / 4800 (0.00%)** | `panicked: true` **never fired (0.00%)**; but **94.77% returned an EMPTY program body**; 95.29% reported errors |
| TypeScript 6.0.3 | 0 / 4800 *(prior measurement)* | ~76% of tree intact *(different metric — see caveat)* |
| Babel | 4400 / 4800 (91.67%) *(prior measurement)* | n/a — throws |

**Valid-file baseline:** oxc returned an empty program on **0 of 120** valid files. So the empty-program result is specific to broken input, not a general defect.

### Findings

**1. oxc is effectively eliminated for this product.** The research predicted the risk as `panicked: true`; the measured failure mode is different but worse in practice. oxc does not panic and does not throw — it **silently returns a well-formed response containing no program** for 94.77% of truncated TSX. Under DEC-007, where half-typed source is routine, oxc would supply no structural information at all in the common case, while looking like it succeeded.

**2. tree-sitter survives but degrades more than expected.** Never throwing is the strongest possible result for the DEC-007 requirement. However, only **38.4% of bytes** on average fall outside `ERROR` spans — error recovery does not confine damage to the truncated tail. Under DEC-024 this is not a correctness problem (ERROR regions become fallback segments, visibly marked per INV-4) but it does bound achievable alignment quality on partially-typed files.

**3. Metric caveat, stated rather than glossed.** tree-sitter's 38.4% (bytes outside ERROR) and TypeScript's ~76% (tree intact) are **different measurements and are not directly comparable**. Both indicate survival; neither ranks the two against the other. A strictly comparable metric — identical definition applied to both — is required before using these numbers to choose between TypeScript and tree-sitter.

### Verdict

- **[Eliminated] oxc**, on broken-input behavior. Not a tuning matter: silent empty results are the worst available failure mode for this product.
- **[Eliminated] Babel**, on prior measurement (91.67% throw rate).
- **[Surviving] tree-sitter and TypeScript**, both never throwing. Ranking between them is **not settled** and requires the comparable-metric work above.
- **[Unchanged] Coordinate handling** is a binding-level property, not a parser-level one. Every Node binding measured reports UTF-16. Byte-native access requires the C, Rust, or Swift bindings — which is a constraint on the stack (OQ-033), not on the parser.

## X-4 — libgit2 measurement

**Status:** Complete, 2026-07-26. Under box.

Measured via `pygit2 1.15.1` / **libgit2 1.8.1** in a scratchpad virtualenv. Python was used because it was the fastest route to a working libgit2 — the binding language is irrelevant to the questions asked, which concern libgit2's own behavior.

### Result 1 — Read-only: clean

| Operation | Writes to `.git`? |
|---|---|
| `Repository()` open | No |
| `r.status()` | No |
| `r.diff()` (worktree) | No |
| `r.revparse_single("HEAD")` | No |

Snapshot method identical to the CLI audit: SHA-256 of every file under `.git` before and after.

### Result 2 — EOL filter parity: **contradicts the earlier assessment**

Scratch repository with `.gitattributes` containing `*.txt text eol=crlf`, renormalised, worktree forced to CRLF — the DEC-025 case.

```
git diff  : 0 lines
libgit2   : 0 lines
IDENTICAL : True
```

**libgit2 handled the built-in CRLF filter correctly and agreed with `git diff` exactly.**

This **narrows a claim recorded earlier**. The research finding was that libgit2 supports *only* built-in CRLF and IDENT filters, not external clean/smudge drivers — which is accurate. But that was carried forward as though libgit2 would fail the DEC-025 case generally, and it does not. Built-in CRLF is precisely the common case (`core.autocrlf`, `text`/`eol` attributes), and libgit2 gets it right.

**The residual gap is narrower than stated: external filter drivers only** — Git LFS, custom `filter.*.clean` definitions. That gap remains **untested here** and is where the risk actually lies. Note DEC-028 already routes filtered files to raw fallback, which covers this regardless of mechanism.

### Result 3 — Unborn HEAD: libgit2 is *better* than the CLI idiom

The `carrefour-inapp` case, reproduced in a scratch repository:

```
libgit2  head_is_unborn          : True
libgit2  head_is_detached        : False
libgit2  r.head                  : raises GitError "reference 'refs/heads/main' not found"

git      symbolic-ref -q HEAD    : "refs/heads/main"   ← exit 0, and wrong
```

**libgit2 has a first-class, correct API for the exact state the Git CLI idiom reports incorrectly.** This is a substantive point in libgit2's favour, directly relevant to OQ-050. Using the CLI requires knowing to probe with `git rev-parse --verify HEAD` instead; libgit2 answers the question directly.

### Result 4 — Cost: libgit2 is **slower**, contradicting the spawn-overhead assumption

On the real 1.5 GB repository (`mailingi-2025`), read-only:

```
libgit2 status : 264 ms
git CLI status :  46 ms      ← 5.7× faster
```

The assumption that avoiding process spawn would favour libgit2 is **wrong at this scale**. The measured spawn floor is 6.2 ms; libgit2's slower traversal dwarfs it.

### Result 5 — Status semantics differ by default

libgit2 reported **165 entries**; `git status --porcelain` reports **63**. Investigated and explained precisely:

```
git status --porcelain        :  63 lines   (untracked directories collapsed)
git status --porcelain -uall  : 165 lines   (untracked directories expanded)
```

**libgit2 defaults to the expanded semantics.** Not a defect in either — a default difference. But it means **DEC-012's "uncommitted file count" would differ by 2.6× for the same repository depending on mechanism.** Whichever is chosen must be explicit and documented, and the repository-list count must not be assumed to mean the same thing as what `git status` prints.

### Verdict — OQ-010 is now genuinely contested

The asymmetry X-4 existed to remove is removed, and the picture is more balanced than the pre-measurement position suggested.

| Criterion | Winner |
|---|---|
| Read-only safety | Tie (both clean on tested operations) |
| Built-in EOL filter parity | Tie (identical output) |
| External filter drivers | CLI (libgit2 unsupported; mitigated by DEC-028) |
| Unborn HEAD handling | **libgit2** (first-class API; CLI idiom lies) |
| Status performance | **CLI** (5.7× faster on the large repo) |
| Raw-mode output fidelity | CLI (it *is* the reference by definition) |
| Binding health for plausible stacks | CLI (SwiftGit2 2019, nodegit 2020) |
| Licensing under DEC-020 | CLI (libgit2 GPL-2.0 + linking exception) |

**Still not a decision.** The CLI leads on more criteria, and the two decisive ones for this product — Raw mode being defined as `git diff` output, and binding health — are structural rather than incidental. But libgit2's unborn-HEAD superiority is real and should inform the design regardless of mechanism: **the app needs a correct unborn-HEAD probe either way**, and the CLI route requires knowing not to trust `symbolic-ref`.

---

# M1 — Engine skeleton and invariant harness

**Status:** Complete, 2026-07-27. **68/68 checks pass.** First application code in the project.

## What was built

```
Package.swift
Sources/DiffScopeEngine/      Partition · CanonicalDiff · Validation · TrivialPartition   (557 lines)
Sources/diffscope-verify/     headless harness, exit code 1 on failure                    (257 lines)
fixtures/                     9 seed fixtures + MANIFEST.json with recorded hashes
```

Built in the order mandated by `20-implementation-plan.md` §3 — **the checker before the thing checked**. The trivial partition producer was written last, sixth, deliberately.

`DiffScopeEngine` imports only `Foundation`. DEC-002's headless requirement is therefore **structural**, not aspirational: the module cannot reach AppKit or WebKit.

## Toolchain finding

**Neither `Testing` nor `XCTest` is available with Command Line Tools** — both ship with Xcode.app, which is not installed.

Not a blocker. DEC-002 already requires the fixture corpus to run headlessly in CI, so the harness is an **executable returning a non-zero exit code**, with zero external dependencies. A test framework would be convenience, not capability. If IDE-integrated tests are wanted later, that is a reason to install Xcode — not a reason to change the design.

## Verification of the canonical diff

`D` is Myers over bytes, implemented independently of everything on the presentation path (DEC-039). Correctness is not asserted — it is **cross-checked against an independent dynamic-programming LCS**, which is the ground truth for minimality:

```
matched length equals LCS on 600 random pairs   PASS
every reported match is byte-equal              PASS
matches strictly increasing on both sides       PASS
no old byte in both a hunk and a match          PASS
no old byte in neither a hunk nor a match       PASS
```

The last two together prove the hunk/match split is a genuine partition of the old side — the same property the model itself must satisfy, checked here on the validator.

## The validator was tested by breaking things on purpose

A validator that only ever sees valid input proves nothing. Four models were deliberately malformed:

| Injected defect | Caught by |
|---|---|
| "no changes" claimed on differing bytes | INV-3 |
| changes claimed on byte-identical input | INV-3 |
| a changed byte left outside every presented segment | INV-2 |
| a partition whose declared length lies | INV-1 / T-0 |

## Performance, release builds

| Input | Result |
|---|---|
| 24 KB, realistic churn | 0.3 ms |
| 400 KB | 8.9 ms |
| 1 MB | 41 ms |
| 2 MB | 153 ms, exact, 1259 hunks |
| 100 KB **unrelated content** | **>120 s before the budget; ~81 ms after** |

**Debug builds are ~260× slower** (78.5 ms vs 0.3 ms on the same input). Never benchmark this code in debug.

The unrelated-content result invalidated DEC-040's file-size threshold and produced **DEC-043**: validation is bounded by work performed, not input size. See the decision log.

## Fixtures

Nine seeded, written **programmatically with recorded SHA-256 hashes** in `fixtures/MANIFEST.json`, because `15-test-corpus-plan.md` §2 warns that an editor silently repairing CRLF or NFD produces a fixture that passes while testing nothing.

Byte-verified at creation:

```
nfc-vs-nfd/before.ts   ...27 5a cc 87 41 42 4b 41...   Z + combining dot above
nfc-vs-nfd/after.ts    ...27 c5 bb 41 42 4b 41...      precomposed Ż
line-ending-change     ...61 6c 70 68 61 0d 0a...      CRLF
```

The `nfc-vs-nfd` pair is lifted from real source — `5bonsai__website__nextjs/.../case-studies/page.tsx:168`.

## Honest limits of M1

- Every fixture passes **vacuously**. The trivial partition marks the whole file as one fallback segment, so coverage is satisfied by construction. These fixtures become meaningful at M4 and M5.
- INV-5 (mode agreement) is untested — there are no modes yet.
- The `Move` container exists in neither code nor model yet; DEC-038 lands at M6.
- No parser, no Git, no UI.

What M1 does establish is that **the harness catches real defects**, proven by feeding it broken models on purpose.

---

# M2 — Git layer

**Status:** Complete, 2026-07-27. **101/101 checks pass** (68 from M1 plus 33 new). 760 lines in `DiffScopeGit`.

## Design: writes are unexpressible, not merely forbidden

`GitOperation` is a **closed registry of static factory methods**, not free-form arguments. There is no case for `commit`, `fetch`, `add`, or `reset`, so the application cannot express a write — a deny-list would have been weaker, since it protects only against what someone thought to list.

Three further mechanisms:

- `GitRunner` prepends `--no-optional-locks` to **every** invocation. Callers cannot omit it; it is not a parameter.
- The runner also sets `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0`, `GIT_CONFIG_NOSYSTEM=1`.
- The runner **records the label of every operation it executes**. The suite then asserts that the set actually executed is a subset of the set proven read-only — so using a new operation without proving it fails CI, which is what `20-implementation-plan.md` §5 asked for.

## R-8: the read-only proof

Every one of the **16 registered operations** was run against a scratch repository with staged, unstaged and untracked changes, hashing every file under `.git` before and after.

```
all 16 registered operations leave .git byte-identical            PASS
status leaves .git untouched even with a stale stat cache         PASS
every executed operation appears in the proven registry           PASS
the runner always passes --no-optional-locks                      PASS
```

The stale-stat-cache case is the one that matters: it is the condition under which plain `git status` *does* rewrite the index, and it is this application's normal operating mode.

## R-12: the idiom that lies, now tested

```
git symbolic-ref reports a branch that does not exist             PASS
headState uses rev-parse --verify and reports unborn              PASS
all four scopes unavailable with a stated reason on unborn HEAD   PASS
ahead count is unknown, never a fabricated zero                   PASS
```

The first check **asserts the defect**: on an unborn repository `symbolic-ref` exits 0 and returns `main`. Pinning that behaviour in a test means a future refactor toward the "obvious" idiom fails loudly.

## Verification against the real corpus

`diffscope-verify --survey` run read-only over `~/WebstormProjects`:

```
discovered 21 repositories
base resolution: originHead=17  uniqueLocalDefault=3  needsUserChoice=1
```

**Exactly matching the Phase 0 measurement** (17 / 3 / 1) — the cascade in DEC-009 behaves in production as it did in analysis.

Two decisions visibly doing their job:

- `carrefour-inapp` → `no commits yet (main)`, 6 changed, ahead **unknown** — DEC-012's prohibition on a fabricated zero.
- `5bonsai__website__nextjs` → 0 changed, **ahead 2** — the case that killed hiding clean repositories.

## Performance: a correction to an earlier estimate

| Sweep | Elapsed |
|---|---|
| Sequential | **15,478 ms** |
| Parallel (`RepositorySweep`) | **478 ms** |

32× improvement, and within DEC-006's expectation.

**The earlier "well under 100 ms parallelised" estimate was wrong** because it was derived from a `status`-only sweep (326 ms sequential). A full snapshot issues about **seven** Git invocations per repository — head state, status, base cascade, preferred ref, committer date, merge-base, ahead count — so roughly 147 subprocess spawns for 21 repositories. At the measured 6.2 ms spawn floor that is ~900 ms of spawn cost alone before any work.

**478 ms is the honest figure for the full sweep.** If it needs to be lower, the lever is fewer invocations per repository (batching via `for-each-ref`, or deferring ahead-counts), not more threads.

## Also covered

- **R-1…R-3** base cascade: unique local default, ambiguous `main`+`master` → prompt, explicit override wins.
- **R-4** detached HEAD identified; merge-base scope unavailable.
- **R-7** four scopes select the right files from `git status` codes (DEC-041), with `X`/`Y` giving the staged/unstaged split naturally. Pinned pairs carry SHA-256 hashes per side and were verified **byte-exact** against merge-base blob, HEAD blob, and worktree file — including the Polish `żółć` content.
- **R-10, R-11** discovery: depth 2 honoured, deeper excluded, individual repositories accepted at any depth, missing sources and non-repositories reported rather than silently dropped, symlink escaping its root refused, multiple sources merged without duplicates.

## Not yet done

- Filter detection (`check-attr`) is registered as an operation but not yet wired into scope selection — DEC-028's raw fallback lands with the diff pipeline.
- No caching between sweeps; every focus event would currently redo the full 478 ms.
- Rename detection relies on Git's own `-> ` reporting; not stress-tested.

---

# M3 — Raw diff end to end

**Status:** Complete, 2026-07-27. **125/125 checks pass.** First milestone with visible output.

## The conversion function, and why it moved sides

`09-…` §5 specified conversion on the **webview** side. Implementation showed that is the wrong side: JavaScript receives a decoded string and would have to re-encode it to UTF-8 to count bytes — work on data it did not produce. Swift already holds the bytes.

**Moved to Swift; recorded as DEC-044.** The model now crosses carrying **UTF-16 offsets only**; JavaScript never sees a byte offset.

The hazard is confined to `Utf16OffsetMapper` and tested from both directions:

```
probe integrity: the three units genuinely differ                        PASS
byte offset maps to UTF-16, not to the byte or codepoint offset          PASS
slicing the JS-side string at the mapped offset yields MARKER            PASS
applying the UTF-16 offset to the byte buffer yields plausible WRONG text PASS
NFD sequence survived into the probe                                     PASS
```

The fourth check is the **negative control** and matters most: it confirms the X-1 failure is still reachable if the conversion were skipped, so the positive check is not passing for a trivial reason.

**Two test bugs were found and fixed while writing these**, both in the expectation rather than the code: the first computed the offset of the enclosing *line* while asserting the slice would yield `MARKER`; the second applied a byte offset to a byte array — correct by construction, so it could never have failed.

The converter **refuses rather than guesses**: offsets inside a multi-byte sequence, out-of-range offsets, and invalid UTF-8 all throw. Non-UTF-8 content is declared `unrenderable` with a notice, never mangled.

## Contract

`RenderModel` carries pin identity, mode, per-side text and segments, coverage status, and notices. Verified: exact byte round-trip of both sides, UTF-16 offsets shorter than byte length on non-ASCII, last segment ending exactly at the UTF-16 length, JSON round-trip equality, and non-UTF-8 declared unrenderable.

## Renderer

CodeMirror 6 as **two plain `EditorView`s** — no `@codemirror/merge`, no diff model. Bundle **356 KB** minified.

Verified live in the browser with a model produced by the Swift binary:

| Check | Result |
|---|---|
| Old/new text round-trip through the boundary | exact |
| `nfc-vs-nfd` fixture: old has U+0307, new has U+017B | both confirmed |
| The two render identically after NFC | `true` |
| Yet the strings differ | `true` |
| Syntax highlighting active | 8 tokens, 2 distinct colours |
| Change mark carries texture | `repeating-linear-gradient(-45d…` |
| Change mark carries underline | `underline` |
| Classification exposed to the DOM | `formatting-only` |
| Alert notice styled by border, not colour alone | `true` |

**DEC-035 validated visually**: syntax colour is untouched — identifiers stay green under a change mark — while change meaning is carried by underline and background texture.

## Native path

`diffscope-app`: AppKit shell, three-pane split (repositories · files · diff), scope selector, status line, `WKWebView` hosting the renderer.

A `DIFFSCOPE_SELFTEST` mode drives the whole native path headlessly:

```
SELFTEST renderer=index.html
SELFTEST probe=OK {"pin":"pinA:pinB","oldDocLength":20,"newDocLength":19,
                   "oldText":"const a = \"ŻABKA\";\n",
                   "newText":"const a = \"ŻABKA\";\n"}
```

Both sides **render identically** while differing in length by one — the ŻABKA case carried through Swift → `WKWebView` → CodeMirror with pin identity intact.

**A diagnostic error worth recording:** an earlier check reported the renderer resource as missing from the build. It was present; `find` does not follow the `.build/release` symlink. The build was fine and the diagnostic was wrong — which is why the self-test was added rather than inferring health from the absence of a crash.

## Not yet done

- Alignment gaps, collapsed regions, gutter, and change navigation — M6/M7.
- The native window itself was **not visually verified** from this environment; the self-test proves the pipeline, not the layout.
- Every file is still one `fallback` segment: real structural segmentation arrives in M4.

---

# M4 — Parsing and partition construction

**Status:** Complete, 2026-07-27. **151/151 checks pass** (125 from M3 plus 26 new). 232 lines of Swift over vendored C.

## Vendoring rather than depending

tree-sitter core and the TSX grammar are **vendored as C targets** — `Sources/CTreeSitter` (592 KB) and `Sources/CTreeSitterTSX` (8.4 MB, almost all of it the generated `parser.c`). Both MIT; their `LICENSE` files are copied alongside the sources.

This avoids a SwiftPM network dependency and pins the grammar exactly, which matters given M0-3 measured `tree-sitter-typescript` as stale (last release 2024-11-11). If a grammar defect ever bites, the fork is already in the repository.

Two build snags, both recorded because they are non-obvious:

- The TSX `scanner.c` includes `../../common/scanner.h`, a path that only exists in the grammar's own repository layout. Vendored `common/` alongside and rewrote the one include.
- Removing `wasm_store.c` — apparently unnecessary without WASM — **broke linking**, because other translation units reference its symbols unconditionally. The file guards its body behind `#ifdef TREE_SITTER_FEATURE_WASM` and compiles to stubs, so it must be kept.

## The architecture's premise, finally tested directly

This is the check DEC-042 exists for. The same discriminating probe from X-1, now against tree-sitter reached through its **C API from Swift**:

```
probe integrity: byte and UTF-16 offsets differ                          PASS
the MARKER identifier is found as a leaf                                 PASS
its start byte equals the UTF-8 byte offset, NOT the UTF-16 offset       PASS
root end byte equals the byte count, not the UTF-16 length               PASS
```

**Confirmed byte-native.** Every Node-hosted binding measured in X-1 and X-3 reported UTF-16 while typing it as bytes; the C API does not. The partition is built directly from parser offsets with no conversion layer, which is precisely what Option B could not have had.

## DEC-024 construction against 400 real files

```
real .tsx files were found to sweep         PASS   400 files
every partition is well formed              PASS   0 malformed
every partition reconstructs byte for byte  PASS   0 mismatched
filler: 23.3% of 1,360,687 bytes
```

**23.3% filler independently confirms M0-1's 25.9%** — measured through a different binding, a different language, and a different implementation of the same construction. The two agreeing is meaningful; it means the number is a property of tree-sitter's tree shape, not of either implementation.

The construction does what DEC-024 specified: drop zero-width leaves (`MISSING` nodes), clamp overlaps, fill the gaps from bytes. No file needed the raw fallback.

## Error recovery

```
broken source still yields a tree                    PASS
the tree reports error nodes                         PASS
partition of broken source is still well formed      PASS
partition of broken source still reconstructs exactly PASS
```

`ERROR` leaves are labelled `.fallback` with confidence 0, so they are **presented** rather than silently absorbed (INV-4). Half-typed source degrades presentation quality and nothing else.

## Classification (DEC-004)

`.tsx .ts .jsx .js .mts .cts .mjs .cjs` are structural; everything else falls back with a stated reason. Three content-based checks run before parsing:

| Trigger | Outcome |
|---|---|
| NUL byte present | `binary content` |
| Not valid UTF-8 | `not valid UTF-8` |
| Merge conflict marker at line start | `merge conflict marker at byte N` |

The conflict-marker check matters more than it looks: without it, a conflicted file parses as syntactically plausible nonsense and would be aligned against the wrong thing. It is checked at **line starts only**, so a string containing `=======` does not trigger it.

## Not yet done

- No matching. Both sides are partitioned independently; nothing is aligned yet — that is M5, and it is where the product's actual value appears.
- Segments carry leaf type as `classification`, which is diagnostic rather than the DEC-017 vocabulary.
- The grammar's `#306` whitespace-in-jsx_text behaviour was not re-tested here; M0-1 established it does not threaten the partition.

---

# M5 — Matching and alignment

**Status:** Complete, 2026-07-27. **177/177 checks pass** (151 from M4 plus 26 new). The product's distinguishing behaviour now exists.

## The founding case works

```
<div>            →   <>
  <Header />           <Header />
  <Content />          <Content />
</div>           →   </>
```

```
children survive as unchanged on the old side    PASS
children survive as unchanged on the new side    PASS
the wrapper itself is not reported unchanged     PASS
most bytes are preserved rather than rewritten   PASS
```

## Matcher

GumTree-family, **implemented from the papers, no source ported** (DEC-030). Top-down phase pairs isomorphic subtrees by structural hash; bottom-up phase pairs remaining internal nodes by Dice similarity over already-matched descendants.

`minimumHeight` is **1**, not the customary 2. The research finding that a Java-derived default of 2 is hostile to JSX proved concrete: `<Item />` is a height-1–2 subtree that must be matchable.

Output is consumed **only as a node↔node mapping** (DEC-029). No edit script is derived or stored.

## The invariant caught a real defect — the important part of this milestone

Prop reordering failed INV-2 on first run:

```
INV-2 old: byte 8 differs but lies in no presented segment (hunk old[8..<16] new[9..<9])

OLD:  8..16  unchanged "disabled"      ← structural anchor
NEW: 42..50  unchanged "disabled"      ← same bytes, different place
```

The anchor asserted *"these bytes are unchanged"* because the two leaves matched structurally. The canonical byte diff had aligned the file differently and counted those bytes as deleted.

**Diagnosis:** labelling is a claim about *alignment*, and the authority on alignment is the textual layer. The structural matcher had produced a locally-plausible but globally non-optimal anchor set, excluding `size` and `variant` from anchoring; Myers found the better alignment and disagreed.

**Fix, taken verbatim from `14-…` §7.1** — *"where they disagree about whether something differs, the textual layer wins unconditionally"*. Structural labels are now **reconciled against the canonical diff mask** before being emitted. The rule the specification already stated is now the rule the code implements.

This is exactly the class of error the invariant exists to catch, and it was caught on the first run rather than shipped.

## Reconciliation turned out to do two jobs

Applying the mask in **both** directions produced nested refinement for free:

| Direction | Effect |
|---|---|
| `unchanged` ∩ mask | → `moved` (if it was an anchor) or `changed` — the fix above |
| `changed` ∖ mask | → `unchanged` — **character-level refinement** |

The second direction is what the brief asked for in its string example:

```
const t = "Witaj użytkowniku";  →  const t = "Witaj, użytkowniku";

unchanged  " \"Witaj"
changed    ","          ← the comma alone
unchanged  " użytkowniku\""
```

**31 of 32 bytes unchanged.** No separate token or character differ was needed; the canonical diff already knew.

And prop reordering now reads correctly:

```
unchanged  "  size=\"lg\""
moved      "disabled"
```

## Ambiguity is surfaced, not guessed (DEC-031)

Three identical `<Item />` siblings with one edited produce a **recorded ambiguity** naming multiple candidates per side. The matcher pairs them positionally to make progress but keeps the candidate set, and anchoring **refuses to use ambiguous nodes** — so an ambiguous match never becomes a confident "unchanged" claim.

## Corpus

120 real `.tsx` files, each diffed against a copy with `className` renamed throughout:

```
every structural diff satisfies the invariants   PASS   0 failed of 120
mean unchanged: 92.3%   ·   fallbacks: 0
```

A rename-like edit preserves 92.3% of the file rather than rewriting it.

## Not yet done

- **Classification vocabulary.** Segments carry diagnostic labels (`anchor`, `filler`, `refined`, `moved-content`), not the DEC-017 taxonomy (`formatting-only`, `jsx-attr-reorder`, …). Formatting-only grouping is therefore not yet possible.
- **Moves are detected only where reconciliation reveals them** — a byte-identical anchor contradicted by the byte alignment. That satisfies DEC-038 but is narrower than a deliberate move search.
- Anchor selection is greedy by old-side position, not a longest-increasing-subsequence. Reconciliation makes this safe, but a better anchor set would mean fewer bytes reported as changed.
- The renderer still shows only `raw`; wiring the structural model into the app is not done.

---

# M5-B — What the structural layer is actually worth

**Status:** Complete, 2026-07-27. Run because the product owner asked whether recognising repeated identical `<Item />` siblings is useful in review, or merely complexity.

Answering that honestly required measuring something previously assumed: **how much the structural layer adds over a plain byte diff.**

## A defect found by measuring

The first comparison showed structural performing *worse* than bytes on pure insertions (−10 bytes on the comma case, −15 on repeated siblings).

Cause: `reconcile` returned early when the change mask was empty. For a pure insertion the **old side's** mask is empty, so every `changed` segment on that side stayed `changed` even though no old byte had changed. Fixed by narrowing the guard. 177/177 still green.

Worth recording because the bug was invisible to the invariants — a segment wrongly labelled `changed` violates nothing. Only a comparison against an independent baseline exposed it.

## Result: structure adds nothing to alignment

Four perturbations, 120 real `.tsx` files each, measuring old-side bytes preserved and fragmentation (count of contiguous changed runs):

| Perturbation | bytes un% | struct un% | bytes runs | struct runs |
|---|---|---|---|---|
| delete a JSX block | 77.6% | **77.6%** | 1.0 | **1.0** |
| wrap the return | 100.0% | 100.0% | 0.0 | 0.0 |
| duplicate a line | 100.0% | 100.0% | 0.0 | 0.0 |
| move imports to the end | 83.5% | **83.5%** | 2.5 | **2.5** |

Identical to a tenth of a percent.

### This is a consequence of INV-2, not an empirical accident

INV-2 requires every byte the canonical diff calls changed to lie inside a presented segment. So **the set of bytes the model may call "unchanged" can never exceed the byte diff's unchanged set.** Structure cannot beat bytes on that metric — the invariant forbids it. The measurement was destined to return zero.

Two of the four perturbations were also pure insertions, which leave the old side untouched and therefore cannot discriminate at all. There were really two test cases, not four.

## What structure can still contribute

Three things, of which the benchmark measured none:

1. **`moved` labels.** Myers has no move operation, so a byte diff cannot express one. Already implemented.
2. **Classification** (`formatting-only` and the rest of the DEC-017 vocabulary). Grouping, not alignment. That is M6.
3. **Tie-breaking among equally-minimal alignments** — the slider problem. Myers' minimality does not select a unique alignment; where several are equally short it picks arbitrarily. The Phase 2 research recommended exactly this: *"a secondary pass that picks the most legible among equal-cost results."* **Not implemented, and the benchmark could not see it.**

## The slider problem is real here — measured

Probe: duplicate a four-line block after a closing brace, in 150 real files, then check whether the canonical diff's hunk boundaries land on tree-sitter node boundaries.

```
hunk boundaries examined              : 300
landing on a syntax boundary          : 114 (38.0%)
files with at least one misalignment  : 136 of 150 (91%)
```

Sample boundaries, all showing the classic shape — the hunk starts immediately after a closing brace and ends mid-structure:

```
…/div>\n    </div>\n  );\n}\n      </div>\n    </div>\n…
…/div>\n    </div>\n  );\n}\n\nfunction TransactionIte…
```

**62% of hunk boundaries fall somewhere a syntax tree does not consider a boundary**, and 91% of files contain at least one.

**Honest limit of this probe:** misalignment does not by itself prove an equally-minimal aligned alternative exists. For *this* perturbation it does, by construction — inserting a copy of an existing block makes the alignment ambiguous by exactly the length of the repeated content. Generalising beyond that needs a separate check.

## Consequence

The structural layer's justification **moves** rather than disappears. It cannot find more unchanged content than the byte diff. What it can do — and currently does not — is choose *where* a changed region begins and ends among equally valid options, so that a diff does not start mid-expression.

That is now the strongest remaining argument for keeping the matcher, and it is untested work.

---

# M6-A — Does the classification vocabulary fire on real files, and only where it should?

**Status:** Complete, 2026-07-27.

M5-B listed classification as one of three things the structural layer can still contribute. It is the first to be built, and the only one whose failure mode is a **trust defect rather than a quality one**: a segment wrongly labelled `formatting-only` invites the reviewer to skim a real change. The invariants cannot catch it — mislabelling violates none of them, exactly as the `reconcile` bug in M5-B violated none.

So the measurement is two-sided by design: a detector that never fires is useless, and a detector that fires wrongly is worse than useless.

## Method

120 real `.tsx` files (200 B – 60 KB, `node_modules` and `.build` excluded), each diffed twice through `structuralDiff`:

- **whitespace-only edit** — every `"\n  "` becomes `"\n    "`, a reindent that changes no token
- **rename edit** — `className` → `class_Name`, which changes tokens and nothing else

Then every segment labelled `changed` on both sides was counted by classification.

## Result

```
whitespace-only edit : 11920 of 12183 changed segments classified   (97.8%)
rename edit          :     0 of  1111 changed segments claimed formatting-only
```

Zero false claims, and the recall on a genuinely formatting-only edit is 97.8%. The residual 2.2% is reconciliation splitting a gap pair whose two halves are not individually whitespace-equal; those stay unclassified, which is the safe direction.

## Detectors

Cumulative-normaliser equality tests over the aligned gap pair, first match wins:

| Class | Test | Group |
|---|---|---|
| `whitespace` | equal after dropping ASCII whitespace | `formatting-only` |
| `quote-style` | equal after unifying `'`, `` ` `` and `"` | `formatting-only` |
| `trailing-comma` | equal after dropping commas before a closer | `formatting-only` |
| `paren-only` | equal after dropping `(` and `)` | `formatting-only` |
| `reordering` | same multiset of top-level comma-separated items, different order | `potentially-behavior-affecting` |

Reordering is deliberately **not** formatting-only: spread props and object keys can change behaviour (`10-…` §3.8).

## Where classification is computed, and why it matters

On the **gap pair**, before reconciliation. That is the only point in the pipeline where both sides of a change are known to correspond — after reconciliation each side has been split against the canonical mask independently, and the correspondence is gone. Reconciliation then carries the label into each piece it produces.

## Two incidental findings

- **`reconcile` was reading a diagnostic string as data.** Move detection tested `segment.classification == "anchor"`, so replacing the diagnostic vocabulary silently disabled move detection until anchor identity was passed explicitly as a set of start offsets. The diagnostic labels were load-bearing, which is precisely why they had to go.
- **`runBundleFreshnessCheck` was never called.** It was written in M5 and left unregistered in `main.swift`, so a stale renderer bundle would have shipped unnoticed. Now registered — 207 checks, up from 177 plus 27 new ones. A check that is not run is not a check.

---

# M6-B — What outward boundary snapping buys, and what it costs

**Status:** Complete, 2026-07-27. Answers the question M5-B left open: the slider problem is real, so what can be done about it *without* touching INV-2.

## The finding that shaped the design

Sliding a hunk — git's approach, and the natural reading of "tie-breaking among equally-minimal alignments" — moves bytes out of the presented set. INV-2 names *the* canonical diff's hunks as what must be contained, and the validator recomputes them deterministically, so a slid presentation fails validation by construction. Recorded as DEC-047; the alternative is reopening DEC-021, which is not a passing change.

What survives is **outward** snapping: widen each changed range onto the nearest syntax boundary within a budget. Expansion is monotone, so containment holds by construction — the same argument `10-…` §3.6 already makes for grapheme snapping.

## Method

150 real `.tsx` files (400 B – 40 KB), each perturbed into the slider case by construction: **duplicate four consecutive lines in place**, which makes the alignment ambiguous by exactly the length of the repeated block. For each file, the canonical diff's new-side hunk boundaries were snapped at a range of budgets and two things counted — how many boundaries land on a named-node boundary, and how many bytes are presented compared with the minimal change.

Named nodes only. Anonymous tokens (`{`, `)`, `return`) would make nearly every offset a boundary and the measurement meaningless.

## Result

```
budget   on a syntax boundary   bytes presented vs minimal
   0 B                 34.3%                      +0.0%
   4 B                 70.3%                      +1.2%
   8 B                 85.3%                      +2.6%
  16 B                 97.0%                      +4.4%
  32 B                 99.3%                      +5.1%
  64 B                 99.7%                      +5.4%
```

The 0-byte row reproduces M5-B's 38.0% within the difference between the two perturbations, which is the point of including it. **16 bytes takes almost all of the gain**; past that the curve is flat while the cost keeps climbing. Shipped as `boundarySnapBudget = 16`.

## Two things this measurement does not show

- **It is not tie-breaking.** The presented change now begins and ends where the syntax does, but it is a *superset* of the minimal change, not an equally-minimal alternative. The question M5-B actually posed is still open.
- **It does not prove legibility.** It proves boundary alignment and byte overhead. Whether +4.4% reads as noise is a review question, and the revisit trigger in DEC-047 is written against it.

## Where it goes wrong if applied too early

Snapping before `reconcile` rather than after it widens the mask that decides labels — and `reconcile` reads an anchor overlapping the mask as evidence of a **move**. The widened bytes are unchanged, so that would manufacture move claims out of a presentation setting. Applied after labelling, the only effect is that some unchanged bytes are shown inside a change.

The same ordering trap cost the classification pass its recall the first time: snapping split classified changes into a classified core and unclassified flanks, dropping M6-A's 97.8% to 40.9%. Fixed by having a flank inherit the run's classification where every change in that run agrees — and only there. Back to 98.1%.

---

# M6-C — Invisible differences: the detector that nearly could not detect anything

**Status:** Complete, 2026-07-27. Implements DEC-023 and the confidence half of DEC-017.

## The defect this found, which is the reason to read this entry

The normalization-form test was written the obvious way:

```swift
oldText.precomposedStringWithCanonicalMapping == newText.precomposedStringWithCanonicalMapping
```

**Swift's `String` equality is canonical equivalence.** `nfc(text) == text` is therefore *always* true, and `nfc(text) != text` always false. The detector's headline case appeared to pass its unit checks — because canonically equivalent strings compare equal with or without the mapping — while the corpus scan built on the same idiom reported **0 of 6705 files** containing a decomposed sequence. An independent scan in Python found 28 in the same tree, including one real `.tsx`.

Comparing `Array(text.unicodeScalars)` instead reports 28 of 6705. Every comparison in the detector now goes through scalar arrays.

This is DEC-021's hazard — *normalisation hides real byte changes* — reappearing **inside the detector written to disclose it**, one layer down, in the standard library's definition of `==`. A fixture-only suite would not have caught it: the fixtures passed.

## Prevalence in the real corpus

6705 `.ts/.tsx/.js/.jsx` files under the projects root:

```
decomposed sequences        : 28 files
zero-width or bidi controls : 27 files
whitespace lookalikes       : 78 files
```

None of these are exotic. The `ŻABKA` case that forced DEC-021 is one of 28.

## What is disclosed

| Class | Test (all scalar-exact) |
|---|---|
| `normalization-form` | equal after canonical composition |
| `invisible-control` | equal after removing zero-width, bidi and soft-hyphen scalars |
| `whitespace-lookalike` | equal after collapsing every space-like scalar, tab included |

Homoglyphs stay deferred (DEC-023), so half of the Trojan Source surface remains undisclosed — stated here rather than left implicit.

Disclosure rides alongside classification as a separate field, because the two axes genuinely cross: a trailing non-breaking space is both `whitespace` formatting and invisible.

## Confidence

`confidenceFloor = 0.8` lives in the engine, not the renderer, and the contract carries a computed `uncertain` flag. The threshold is a trust-surface decision — a renderer that picks its own would be able to quietly stop showing uncertainty. Ordinary changed segments sit exactly at the floor; reconciliation's guesses sit at 0.6 and are marked.

## Rendering

One badge per *run* of adjacent disclosed segments, not per segment. The first version put one on each, and a single decomposed character produced four badges across two panes — reconciliation and snapping split the edit, and repeating the reason on every piece read as four separate problems.

---

# M6-D — Move detection, and the two redesigns it took

**Status:** Complete, 2026-07-27. Implements DEC-038.

## What was there before, and why it had to go

`reconcile` already produced `moved` labels: an anchor claiming *unchanged* that the byte diff contradicted was relabelled `moved`. That claim was not checkable where it was made. `reconcile` sees **one side at a time**, so it could not compare the two ranges DEC-038 requires to be byte-equal — it inferred a move from a disagreement rather than from evidence.

Removed. Moves are now searched for deliberately, against both sides, after reconciliation, and the pass condition is asked of the finished model: content labelled `moved` must be byte-equal across the linked pair.

## Redesign one: runs → lines

The first search compared whole runs of changed content. On the corpus it fired on **11 of 120** files.

Cause: structural anchors survive *inside* a relocated block — identical tokens still match — so one moved block arrives as several changed runs split by unchanged pieces, and the two sides split **differently**. Whole-run equality almost never holds.

Matching line by line and extending while both sides continue: **120 of 120**. That is the unit `git --color-moved` settled on, presumably after meeting the same wall.

## Redesign two: one record, several ranges

A block move cannot be one byte-equal range pair: the content between two moved lines — indentation, blank lines — need not match. So a `MoveRecord` holds **one range per line**, all sharing a link. The pass condition stays trivially checkable per range, and the interface still shows one move.

## Result

120 real `.tsx` files, imports relocated to the end of the file without modification, against a rename control:

```
floor   files with a move   files where a rename faked one
   4 B             120/120                            0
   8 B             120/120                            0
  12 B             120/120                            0
  24 B             120/120                            0
```

Zero false moves at every floor, and every move in the corpus byte-identical across sides. The floor does not discriminate here because import lines are long; it exists for small relocations, and `12` non-whitespace bytes is what ships.

**The floor is counted, not silent.** DEC-038 records `git --color-moved` applying a 20-alphanumeric-character floor that *silently* drops small moves. `movesBelowFloor` reports what the floor rejected, so a reviewer can tell "no moves" from "moves too small to show".

## A defect the harness could not see

`snapPresentation` merges adjacent segments that agree on label, classification, disclosure and confidence. It did not compare `link`, and the merged segment was rebuilt without it. So a verified move reached the renderer **unpaired**, and the two sides could no longer be shown as one move.

Every harness check still passed: the labels were right, the bytes were right, the invariants were right. It was caught by the application selftest, which asks the *rendered document* whether a pairing exists. Worth remembering when adding a field to `Segment`: every function that rebuilds a segment is a place to drop it.

---

# M7-A — Navigation and folding: two decisions worth stating

**Status:** Complete, 2026-07-27. First slice of M7 (DEC-016 keyboard map, DEC-017 expansion, DEC-034's pairing idea applied to jumps).

## Navigation follows the canonical diff, not the presented segments

"Next change" could have walked the presented runs. It walks the **canonical diff's hunks** instead, converted to UTF-16 in the same pass as everything else (DEC-044).

The reason is that presented ranges are supersets of the canonical hunks — snapping widened them by ~4.4% (M6-B), classification split them, folds have to avoid them. Navigating the superset means "next change" drifts away from the alignment INV-2 is stated against. Navigating the hunks keeps the two definitions of *change* identical, and every stop still lands inside a presented range because containment is exactly what INV-2 guarantees. The suite asserts that last property directly rather than trusting the argument.

## A fold has to be byte-equal on both sides, or it is not offered

Folding is the only presentation act that puts content **out of sight**, so it is the only place where the invariant's "never suppress" has real teeth. The engine offers a fold only when:

- the range lies strictly between two stops, on both sides;
- it starts and ends on line boundaries, keeping `collapseContextLines = 3` around each change;
- it is at least `collapseMinimumLines = 8` long — below that a fold costs a reader more than it saves;
- **the old and new bytes in the folded range are equal.**

The last condition makes the fold pair well-defined on both panes, which is what keeps them aligned while folded. It is the same argument DEC-034 makes for scroll anchoring: an anchor that exists on one side only cannot align two panes.

Both are computed in Swift, not JavaScript, so both are checkable in the headless suite — the renderer receives a list and executes it.

## Verified on screen

The application selftest renders a 42-line file with an edit at each end, folds the middle, and jumps: `{"index":0,"total":2}`, one fold, both panes showing the same marker with three lines of context. `navigation.png`.

---

# M7-B — Refresh: watching, and the pin that certified a blend

**Status:** Complete, 2026-07-27. Implements DEC-026, DEC-027, F15 and the read half of R-9; produces DEC-049.

## The debounce is tested without waiting

`RefreshDebounce` takes the clock as a parameter. A debounce tested by sleeping is a debounce tested once, on one machine, and the two properties worth asserting — trailing edge, and a cap that survives continuous saving — are both statements about *when*, so they are checkable in microseconds against an injected clock.

Replaying the measured save shape (five events inside 11 ms, DEC-026's context) gives one refresh, 400 ms after the last event, not the first. Replaying a save every 100 ms for four seconds gives a refresh at the 2 s cap: without the cap that stream never refreshes at all, which is the failure the cap exists for.

## The drop path had to be forced

FSEvents delivered 40,041 events for 40,000 file creations — zero drops (DEC-027's measurement). So `MustScanSubDirs`, `UserDropped` and `KernelDropped` will not occur in ordinary use, and a path that never runs is a path that ships untested. The callback body is therefore a separate entry point (`deliver(flags:)`) that the suite calls directly with each flag, and a drop is answered with a **full rescan** rather than a debounced refresh: an incomplete event list understates what changed.

The stream itself is proved separately, against a real directory and a real write, because everything above it can be right while the stream is simply not wired to the file system.

**Configuration, as DEC-026 requires it to be recorded:** `FileEvents | NoDefer | WatchRoot`, latency **0.0**, debounce in application code. The alternative — latency 0.4 with `NoDefer` off — coalesces just as well but hides the debounce in a framework parameter that cannot express a maximum-delay cap.

## R-9: the pin certified a version that never existed

The first fix for a torn worktree read was the obvious one: read twice, require the two reads to agree. Against a writer rewriting a 52 KB file in a tight loop, that let **3 blends through in 8,095 reads**.

The reason is that comparing content asks whether two reads happened to match, not whether anything wrote between them. Two torn reads of a writer alternating between two versions can agree.

What ships brackets the read with a `stat` — inode, size, nanosecond `mtime` before and after. If anything wrote during the read, the stamps differ and the read is retried; five attempts 20 ms apart, then the pair is refused outright and **nothing is rendered** (DEC-049). A blend shown with a warning is still a blend.

```
writer                  reads    blends    refused
continuous rewrite          15         0         15
save every 30 ms          4670         0          0
```

The hostile row is the point: it is not a realistic editing pattern, and under it the guard refuses every read rather than showing something plausible — 15 reads in 1.5 s, because each one spends its full ~80 ms retry budget before giving up. The realistic row is the other half of the point: 4,670 reads with a save every 30 ms, none refused, none blended. A guard that refuses everything is an outage, not a guard.

---

# M7-C — Anchoring and formatting groups: two things measurement changed

**Status:** Complete, 2026-07-27. Implements DEC-034; produces DEC-048.

## Anchors cannot come from segments labelled unchanged

DEC-034 says "the nearest segment labeled unchanged above the viewport top", and DEC-024 notes that segments are supplied natively, so the anchor needs no separate index. Implemented literally, it produced **zero anchors in Raw** — Raw is one `fallback` segment over the whole file — so every refresh in Raw would have thrown the reader back to the top, silently.

Anchors are therefore taken from the **canonical diff's matched blocks**, the same source `changeStops` uses: byte-equal on both sides by construction, present in every mode, and identical between Raw and Structural. This is DEC-034's intent, not its letter.

## And they have to be line-granular, not block-granular

The second attempt used one anchor per matched block. It resolved to `nearestSurvivingAbove` on the ordinary case — text inserted above the reader — because a matched block spanning everything above the change *contains* the insertion, so its content, and therefore its identity, changes.

Anchor identity has to be **local** to survive edits elsewhere. What ships is one anchor per matched line, identified by a hash of a 3-line window (`anchorWindowLines`) plus an occurrence index for repeats — `}` alone on a line is not an identity. Files longer than `anchorBudget = 2000` anchored lines are strided, which lands the reader within a few lines rather than exactly; still incomparably closer than the top of the file.

Drift is checked directly: twenty consecutive refreshes with no content change resolve to **one** position, not a creep. That is the failure mode DEC-034 names and the only one that needs an hour of editing to notice.

## A reindent has no old side

Formatting-only grouping was first written over per-side runs of formatting-only segments. It found nothing on the corpus case, because a reindent is an **insertion**: the old side has no changed bytes at all, so the left pane has no run to pair.

Grouping is therefore driven by canonical hunks, which are stated on both sides, and offered only where the two sides span the same number of lines (DEC-048) — with the rejected runs counted. The selftest renders a four-line reindent as `4 formatting-only changes over 4 lines`, on both panes, at the same height, above an ordinary `16 unchanged lines` fold: `refresh.png`.

The whole-line expansion needed a guard of its own. Hiding whole lines means a real edit *on* one of those lines would be hidden with them, so any presented segment that is not formatting-only anywhere in the group's lines disqualifies it. The suite asserts the case directly: reindent four lines, change `const c = 3` to `const c = 33` on one of them, and the group must not swallow it.

---

# M8-A — The two budgets that were still estimates

**Status:** Complete, 2026-07-28. Produces DEC-050; replaces the estimates in `16-performance-and-scaling.md` §3.

`16-…` §2 has said since planning that **the matcher is the risk**, that the budget belongs on node count rather than bytes, and that the two numbers written down — ~50,000 nodes and 500 ms — were estimates that "must be derived during implementation against the fixture corpus". Until this experiment the structural path had **no budget of any kind**: no size limit, no node limit, no deadline. A minified bundle was a hang.

## Method

`diffscope-verify --budget-survey ~/WebstormProjects` walks real `.ts`/`.tsx`/`.js`/`.jsx` files (skipping `node_modules` and `.build`), parses each, and matches it against a rename-shaped perturbation — the same perturbation the M6 corpus measurements use, so the numbers are comparable. It records bytes, node count, parse time, match time, and counted match work. Synthetic dense-JSX and minified ladders extend the curve past what the corpus contains. Read-only throughout.

## The corpus, 400 files

```
                  p50        p95        p99        max
nodes             841     168390     530897    1427856
nodes per KB    186.2      345.2      400.3      573.0
match ms         1.01     557.88    1520.86    1975.67
longest line      447     247943    6409544    9527358
```

The median real file matches in **1 ms**. The tail is entirely build output — `.next` chunks and a 31 MB `react-icons` vendor bundle — and it is the tail that costs seconds.

## The curve is quadratic, and the same bytes cost wildly different amounts

```
shape         bytes    nodes   match ms        work
dense JSX     14068     7839       10.8      352151
dense JSX     28268    15639       35.5     1343951
dense JSX     56668    31239      126.8     5247551
dense JSX    114668    62439      505.8    20734751
minified       7669     4001       18.3      814003
minified      15669     8001       63.8     3228003
minified      33468    16001      255.9    12856003
minified      70268    32001     1091.7    51312003
```

Doubling nodes roughly quadruples cost, in both shapes. And 33 KB of minified code costs **twice** what 57 KB of JSX costs, because it has half the bytes and a comparable node count — which is the whole reason §2 said to budget on nodes.

Work units track time linearly at roughly **40,000 units per millisecond**, across both shapes and three orders of magnitude. That is what makes a counted budget usable as a time budget without being one.

## Why counted work rather than a deadline

A wall-clock deadline makes the *result* depend on machine load: the same file could diff structurally on an idle machine and fall back on a busy one. T-7 requires the same input to produce the same output, and giving up is part of the output. The suite asserts it directly — a budget that bites spends exactly the same work on every run.

## What the gates reject

With `structuralSizeLimit = 2 MB`, `structuralNodeBudget = 30,000`, `matchWorkBudget = 10,000,000`:

```
gates on 400 files: size 15, nodes 47, work 0 — structural 338 (84.5%)
```

Every one of the 62 rejected files is build output. The eight nearest the gate — the ones that would indicate a badly placed budget — are `.next/dev/static/chunks/*` and `.next/server/app/*/page.js`. **No hand-written source file in the corpus comes near any gate**, and the median uses about a thousandth of the work budget.

The work gate rejecting nothing is not redundancy: it is the gate that catches a file the other two admit, and the synthetic ladder shows those exist at 30,000 nodes.

---

# M8-B — forcing the failure paths that cannot occur locally

**Date:** 2026-07-29 · **Method:** scratch repositories and deliberately broken commands built inside `diffscope-verify`, following the pattern already used for R-8. Nothing here is observable in the corpus: `13-…` §3 lists these as the rows that ship untested unless someone forces them.

## The eol-filter fixture reproduces nothing if built in the obvious order

The plan said: repository with `.gitattributes` `text eol=crlf`, commit, rewrite the worktree, observe the discrepancy. Built that way it reproduces **nothing** — `status=[]`, `diff-lines=0`. With the attribute in place before the commit, both sides agree and there is no filter effect to disclose.

Six configurations were measured to find one that reproduces DEC-041's state:

| # | Setup | `git status` | `git diff` lines |
|---|---|---|---|
| f1 | LF blob, attribute added after, worktree LF | *clean* | 0 |
| f2 | CRLF blob, `text eol=lf` added after, worktree CRLF | ` M` | 9 |
| f3 | attribute committed first, worktree LF | *clean* | 0 |
| f4 | LF blob, `core.autocrlf=true`, worktree CRLF | ` M` | **0** |
| f5 | CRLF blob, `*.ts text` added after, worktree CRLF | ` M` | 9 |
| **f6** | **LF blob, `*.ts text eol=crlf` added after, worktree CRLF** | **` M`** | **0** |

f6 is the fixture: the blob was committed **before** the attribute existed, so the attribute now describes a worktree form the object database does not hold. f4 is the same effect through configuration rather than attributes.

The state that matters: `git status` reports the file modified, `git diff` reports nothing, and **the pair this application compares does differ** — the old side is the LF blob, the new side is the CRLF worktree. So all three of git's answers and ours are individually correct and mutually inconsistent, which is precisely why DEC-041 requires the disclosure to explain the *discrepancy* rather than name the filter.

## What the precedence table caught

Constructed inputs satisfying two conditions at once, with the reported code recorded:

| Input | Conditions | Reported | Was |
|---|---|---|---|
| `logo.png` containing NUL | F9 + F7 | **F9** | F7 |
| `notes.md` with invalid UTF-8 | F9 + F7 | **F9** | F7 |
| `a.ts` with conflict markers + NUL | F9 + F2 | **F9** | F9 |
| 2 MB+ `vendor.css` | F16 + F7 | **F7** | F16 |
| 2 MB+ `vendor.js` | F16 | **F16** | F16 |
| `a.ts` under a filter | F8 | **F8** | *not detected at all* |
| `a.ts` under a filter, containing NUL | F9 + F8 | **F9** | *not detected at all* |

Four of seven changed. Each ended in raw before and after — what changed is the sentence, which under INV-4 is the part being promised.

## F13 found a defect that had nothing to do with F13

The check for "the template is filled, not re-parsed" failed on the first run. `EditorCommand` substituted `{file}` into the template string and split the result on spaces, so a path such as `~/My Projects/a.ts` arrived as **three arguments** and the editor opened none of them. Nobody had reported it because the corpus paths contain no spaces.

Fixed by splitting the template first and filling the tokens afterwards: the template decides what the arguments are, the path only decides their contents.

Both arms of F13 now behave: `/nonexistent/editor` reports `notLaunched`, `/usr/bin/false` reports `failed(exitCode: 1)`, and `/bin/echo` still reports success as a negative control.

## Two smaller findings

- **F6 "unverified" is no longer reachable by size.** §2 describes F6 as "structural allowed, checks skipped", but since DEC-050 an oversized file is withheld from structure entirely, so it is raw-and-explained rather than structural-and-unverified. The remaining route is dissimilarity: two unrelated 120 KB buffers exhaust the `D` budget, and the contract carries `coverageVerified: false` with its notice. Recorded in DEC-051 instead of left as a silent divergence between the document and the code.
- **The snapshot writer reported success it had not achieved.** `try? png.write(to:)` printed the path whether or not the directory existed, so a run with a mistyped `DIFFSCOPE_SNAPSHOT_DIR` looked identical to a successful one. Now reported. Same shape as the `runBundleFreshnessCheck` defect: the failure path was written and never exercised.

380/380 checks pass. The application selftest gained an arm for the disclosure, because the harness can prove the ranking but only the webview can prove the sentence reached the screen — `degraded.png` shows it wrapping to three lines and remaining legible.

---

# M8-C — the first structural run over the fixture corpus

**Date:** 2026-07-29 · **Method:** every fixture through both paths, with the T-series asserted by number; corpus grown from 9 to 32 fixtures; `swift run diffscope-verify`, 380 → 855 checks.

## Three things were not being checked at all

- **Every fixture was validated on the raw path only.** The loop built `trivialModel` — the whole-file fallback partition — so `jsx-wrapper-removal`, the founding case of the product, had never had its structural model checked against the invariants by the fixture harness.
- **`MANIFEST.json` was read by nothing**, while `21-agent-handoff.md` §9 stated that fixture bytes are verified against recorded hashes. Third instance of this defect class, after `runBundleFreshnessCheck` (M5) and `checkAttr` (M8-B). The check now also fails on a fixture with *no* entry, which is the silent case.
- **T-8, T-9, T-10 and T-11 had no checks by those names.** T-10's was worth the exercise on its own.

## T-10 was a documented requirement with no implementation

`14-…` §4: *"Presented regions are snapped outward to grapheme-cluster boundaries."* Nothing did it.

`unicode-graphemes` compares `'😀'` with `'😀‍💻'`. The canonical diff is an insertion starting at byte 19 — between the emoji and the zero-width joiner that binds it to the laptop. Correct on bytes and unrenderable on screen: the presented range cut one grapheme cluster in half, so the two panes would mark half a glyph.

`snapToGraphemeBoundaries` runs **after** syntax snapping, and the order is not arbitrary: a syntax boundary is under no obligation to fall on a cluster boundary, and this case is the proof. Both passes only ever widen, so INV-2 survives by the monotonicity argument §4 already gives.

## Constructing a move fixture failed twice, and both failures are findings

`moved-function` was meant to be trivial. It took three attempts.

| Attempt | Fixture | Moves found | Why |
|---|---|---|---|
| 1 | Two near-identical 3-line functions swapped | 0 | **At byte level this is not a move.** The minimal diff touches only the names and literals; everything around them is common substring, so there is no deletion and insertion to pair |
| 2 | A 4-line function and `export const VAT_RATE = 0.23;` swapped | 0 | The relocated line begins with `export `, which the canonical alignment matched against the **function's** `export ` at offset 0. The line is then only partly inside changed content, and the line-based search requires a whole line |
| 3 | Same, with the line starting `const` | **1** | No shared prefix, so the whole line is changed on both sides |

Attempt 2 is the one worth keeping. Measured segments on the new side:

```
new 0..<7    unchanged  "export "
new 7..<31   changed    "const VAT_RATE = 0.23;\n\n"
new 31..<38  changed    "export "
new 38..<148 unchanged  "function formatPrice(...)..."
```

**A relocated line whose leading bytes align with a neighbour's identical prefix is not detected as a move.** This is a genuine limitation of DEC-038 as implemented, not a defect in the fixture, and it is not fixable inside a test-coverage slice: widening the search to lines that are only partly changed would put bytes the canonical diff calls unchanged inside a `moved` range. That is a decision about what a move *is*, and belongs in a reopened DEC-038 rather than in an implementation detail.

It also explains M6-D's 120 of 120: those relocations were whole blocks, where no cross-move byte alignment survives at a line's start.

`moved-function-modified` then earns its place as the negative control — the same relocation with `0.23` → `0.25` produces **zero** moves, so the delta cannot ride along inside one.

## Two checks were written too narrowly and failed correct behaviour

Recorded because in both cases the correction is the interesting part.

- **T-5** asserted that a fallback is marked *per segment*. `binary-file` and `invalid-utf8` have no segments to mark: the payload is `unrenderable` and the notice says so in words (DEC-044). INV-4 asks that a fallback be marked, not that it be marked in one particular place.
- **T-9** asserted the difference appears on the **new** side. `truncated-file` and `invalid-tsx` are pure deletions, so the new side has no changed bytes at all. Asserted on either side now.

## The corpus

9 → 32 fixtures, covering the degenerate, Unicode, formatting, movement and class/token groups of `15-test-corpus-plan.md` §4. The structural path runs on 28; four are skipped with their reason printed (`binary content`, `not valid UTF-8`, `unsupported language`, `merge conflict marker at byte 0`) because a silent skip and a passing check look identical in a green suite.

Per-fixture structural statistics are printed on every run — hunks, anchors, moves, formatting-only, reordered, invisible — since a T-check that never fires is invisible without them. That is how T-11's silence was noticed.

**Coverage map: `26-coverage-audit.md`.** 855/855 pass.

---

# M8-D — root management, and a window that had never been looked at

**Date:** 2026-07-31 · **Method:** implementing `23b-…` §1.1, then running the application against real configurations and **screenshotting the window** rather than the webview.

## The interface had been blank all along

The repository and file lists rendered **empty rows**. Not truncated, not mis-styled — no text at all, in a window that otherwise looked like a working application: the title bar, the scope and mode controls, and a status line correctly reading `23 repositories from 2 sources · swept in 512 ms`.

It survived every previous session because nothing about it fails. No crash, no exception, no failing check — and the check suite cannot see the screen. The selftest snapshots that exist (`structural.png` and the rest) capture **the webview only**, so the AppKit shell around it had never been photographed.

Two causes, found by measuring rather than reading:

1. **The panes had zero width.** `NSSplitView` distributes space by preserving the proportions of the frames its arranged subviews already have. All three started at zero, so all three stayed at zero however wide the window was. The tables were built, populated and correct, at zero width. Setting the divider positions on the next run-loop pass looked like it addressed this and did not — the split's own frame is still zero until layout runs, so the positions clamped to zero.
2. **The cell views were never sized.** A bare `NSTextField` was returned from `tableView(_:viewFor:row:)`; with a middle-truncating line break mode, a zero-width label truncates the whole string away.

Fixed with width constraints inside the split at priority 600 — below `defaultHigh`, so the dividers stay draggable — and an `NSTableCellView` with the label constrained to its edges. Measured after the fix: `ROWVIEW frame=(0, 10, 140, 20)`, `CELL (16, 0, 108, 20)`, and the list reads.

**The lesson is the one this project keeps relearning, in a new place.** Every previous instance was a check that was never run (`runBundleFreshnessCheck`, `checkAttr`, `MANIFEST.json`, the `return` inside the fixture block). This one is a *surface* that was never looked at. `21-agent-handoff.md` said the native window "has now been looked at" — it had been looked at in a session, by eye, and never since, and nothing in the suite would notice it going blank.

## What the configuration work produced

Measured against three configured sources — the real projects folder, a scratch folder holding a repository deliberately named `diffscope`, and a path that does not exist:

```
23 repositories from 2 sources · swept in 512 ms · …/scratchpad/gone-forever missing
```

- Both live roots merged; the missing one is **named in the status line rather than dropped**.
- The two repositories called `diffscope` were labelled `WebstormProjects/…ffscope` and `extra/diffscope` — the shortest parent qualification that separates them, applied only to the colliding pair (DEC-037).
- With no configuration and no `DIFFSCOPE_ROOT`, the empty state appears with its two buttons and no suggested path (DEC-036 as amended).

One further defect the screenshots caught: the empty state was drawn as an **overlay**, so the tables showed through behind it and stayed reachable by keyboard. It now replaces the split rather than covering it.

---

# M8-E — the gutter, and the line the reader is on

**Date:** 2026-07-31 · **Method:** implemented `23b-…` §1.6, checked the line arithmetic headlessly, then photographed the result.

## Where the decision lives

`12-…` §5.1 names three carriers of change meaning: *"gutter, underline, and background texture"*. Two were built. The third is now, and **which lines carry a difference is computed in the engine** and carried on the contract as `changedLines`, for the same reason navigation stops and folds are (M7-A): a fact about the model belongs to the model, and one the renderer works out for itself cannot be checked without a webview.

Lines are counted on **bytes**, splitting on `0x0A` only. That makes a `\r` belong to the line it terminates, so a CRLF-only change marks the line whose ending changed rather than the one after it — asserted directly, since it is the arithmetic most likely to be off by one. The other off-by-one worth naming: a segment ending *exactly* on a newline must not claim the following line.

## What the picture shows that the checks cannot

Twelve lines, one edit on line 7 (`7` → `77`). The snapshot (`gutter.png`) shows numbers in both panes, line 7 marked on the right by a solid edge and a brighter number, and the changed characters underlined.

**The old pane carries no mark, and that is correct.** `7` → `77` is an insertion, so the old side has no changed bytes to attribute to a line. It is the same shape as DEC-048's finding that a reindent has no old side, appearing again in a different place.

## ⌘O now opens where you are looking

`window.diffscopeCurrentLine()` reports the active change stop when there is one — a reader who pressed ⌘N is looking at that change, not at the top of the screen — and otherwise the first line visible in the new pane. In the new side's numbering, because that is the file on disk the editor opens.

It had been a literal `1` since DEC-015 was implemented: correct in the sense that the file opened, useless on the 900-line file whose change is at the bottom.

**A caveat that belonged on record and is now closed:** the default template `/usr/bin/open -a WebStorm {file}` contained no `{line}`, so the default could not jump. [DEC-082](04-decision-log.md) replaced it — see **M10-A** below for what was measured to choose the mechanism.

---

# M8-F — the file list, and a decision the corpus contradicted

**Date:** 2026-07-31 · **Method:** measured the repositories before writing the grouping, then photographed the result.

## The measurement that changed the design

DEC-033 specified **group headers per workspace package**, resting on the planning-time observation that "12 of 21 repositories are pnpm monorepos". Checked before implementing:

```
repositories containing pnpm-workspace.yaml   12
…of those, declaring a packages: key           0
package.json files declaring workspaces        0
```

Every one of those twelve files declares only `onlyBuiltDependencies`. The planning claim came from the *presence of the file*, not from its contents.

Built as specified, the feature would have drawn **one header above the whole list in every repository the product owner has** — a label repeating the repository name. So the rule became: the declared workspace package where one exists, the parent directory otherwise. The workspace mechanism is kept because it is right where it applies; it simply never applies here.

Measured on `philips__signify-wiz-euro__preact`: 20 changed files, **8 directory groups**.

## What the picture changed after the checks passed

The first working version was correct and still hard to read: under the header `src/components/features/Boxes/Expanded`, every row repeated `src/components/…ExpandedSection1.tsx`. Middle elision exists to protect the width of the row, and the header had already spent it.

Grouped rows now show the path **relative to their group**, so the same rows read `ExpandedSection1.tsx`, with the full path on hover. DEC-033's sentence — *"the start identifies the package, the end identifies the file"* — is satisfied by the header and the row together rather than by every row on its own.

Two further rules, stated so a later reader can check them rather than judge them:

- **Headers are suppressed when grouping buys nothing.** One group per file doubles the list length and separates nothing; one group in total says nothing. Both fall back to flat, at a threshold.
- **The list says only what is cheap to know.** `raw` from the extension, `big` from a `stat`, `bin` from a NUL in the first 4 KB — a NUL being the one content test that needs no context and so survives a partial read. Invalid UTF-8 is deliberately absent: ruling it out needs the whole file, and a list that guessed would be worse than one that stays quiet.

## Incidental

The application opened onto three empty panes and waited for a click before saying anything. It now selects the first repository after a scan when nothing is selected.

Also recorded: **GUI automation is unavailable on this machine** — `osascript` has no accessibility permission (`-25211`), so driving the interface to reach a state for a screenshot does not work. Reaching a state has to be done by the application itself, which is why the auto-selection above was worth having twice over.

---

# M8-G — the rest of the interface audit

**Date:** 2026-07-31 · **Method:** implemented `23b-…` §1.2–1.9, extracting each piece of composed text into a function the suite can assert on.

## What the checks caught that reading would not have

`12-…` §3 gives one worked example of the staleness line: `origin/master · 9 weeks old`. Written the obvious way — days, then weeks up to two months, then months — 63 days renders as **"2 months old"**. Correct arithmetic, wrong answer against the specification's own example. Weeks now run to three months.

That check exists because the line was extracted into `baseSummary(ref:chosenByUser:committerDate:)` rather than assembled inside the view. The same move made three more properties assertable: a ref the user chose says `(yours)`, an unreadable date says `age unknown` rather than passing for fresh, and an unresolved base points at the shortcut that fixes it.

## Where the pluraliser earned its keep

The empty-diff sentence first shipped as `no structural changes; 10 formatting differences in 1 groups`. Visible only by reading the rendered notice — the checks asserted the sentence appeared, not that it was grammatical.

## GUI automation is unavailable here

`osascript` has no accessibility permission on this machine (`-25211`), so the interface cannot be driven to reach a state for a screenshot. Two consequences worth carrying forward:

- **States have to be reachable by configuration**, not by clicking. Pointing `DIFFSCOPE_CONFIG` at a repository with an unborn HEAD is how the disabled scopes were photographed — all four greyed on `carrefour-inapp`.
- **Anything that needs a click to reach cannot be photographed at all.** The scope-4 line is one of those, which is why it was extracted and checked rather than trusted.

## Measured

- Unavailable scopes: verified on `carrefour-inapp` (unborn HEAD → all four disabled) and `js-gloves__website__nextjs` (base resolves → all four enabled).
- The empty-diff sentence reaches the DOM: `no structural changes; 10 formatting differences in 1 group — ⌘E to expand`.
- Selftest arms: 10, all OK.

---

# M8-H — gate G2: making a design unable to lie

**Date:** 2026-07-31 · **Method:** extracted every visual value into one file, then built the checks that keep it that way and proved they can fail.

## The regression this gate exists to prevent

The engine has an apparatus for proving no difference is hidden — five invariants, an independent canonical diff, 943 checks — and **none of it can see the screen**. `display: none` on `.ds-changed` leaves every check passing and every change invisible. CSS is the one place where the product can be made to lie without anything noticing, and a design is precisely a large change to the CSS.

So the rule — *a design may restyle any mark and may never hide one* — is enforced in two places, because either alone is insufficient:

- **The source.** No rule hides a load-bearing class, every mark carries a non-colour signal (DEC-035), the notice bar is not styled away, and no literal colour, font or size is declared outside `tokens.css` — in the stylesheet **or set from JavaScript**, since a style assigned in code sits outside the token file just as surely.
- **The live document.** `diffscopeStyleAudit()` reads computed style off real elements. A stylesheet can be read and still be wrong about what the reader gets: a later rule, a cascade, an inherited `opacity`.

## Both have negative controls

The selftest injects `.ds-changed { display: none; }` into the document, re-runs the audit, and **requires it to fail**; the source checks run against a deliberately hostile stylesheet carrying a hex colour, a hidden mark, a colour-only mark and a hidden notice bar.

This is the M6-B lesson applied on purpose rather than after the fact: a check that has only ever seen a passing input is an assumption wearing a check's clothes.

Measured: `audited=13 hidden=[] colour-only=[]` on the real stylesheet, and the control catches the injected rule.

## Two rules that came out of writing the checks rather than the plan

- **A token nobody uses fails the suite.** A value a designer would change to no effect is worse than one not offered at all — they would conclude the token layer does not work.
- **Comments are stripped before scanning for literals.** A hex code inside a comment explaining hex codes is not a declaration, and failing on it would teach the next reader to work around the check rather than obey it.

## The chrome is two thirds of the window

`Theme.swift` mirrors the token names for the AppKit side — window, both lists, status line, empty state. A design that stopped at the edge of the webview would leave most of the window looking like a different application. The check refuses an inline font size or colour in the application source for the same reason it refuses one in the stylesheet.

Rendering after tokenisation is unchanged, confirmed against the snapshot set: the founding wrapper-removal case still reads with its children intact.

## M8-H addendum — R-9 failed under load, and the reason was not the obvious one

While finishing G2 the racing check failed **once**: `6 blended of 20`, with a release build running
concurrently. It then passed six times on an idle machine. The tempting reading is "flaky test".

Measured instead. First hypothesis — coarse timestamp granularity letting two writes share an
`mtime` — is **wrong**: 200 rewrites of a 52 KB file produced 200 distinct modification times, the
smallest gap 114 µs.

The real mechanism is narrower and worse. A single large `write` stamps `mtime` **once, at the
start**, and the copy continues afterwards. Both stats in the bracket then see the same timestamp
while the read between them lands halfway through the copy. The bracket proves no write *started*
during the read; it cannot prove none was *in flight*. Under load the copy takes longer and the
window opens.

Fixed by requiring a second read to agree as well (DEC-049 amendment). The two guards fail in
different places, which is exactly why neither was enough alone:

```
content comparison alone   3 blends / 8,095 reads   (M7-B)
stat bracket alone         6 blends / 20 reads      (M8-H, under load)
both together              0 blends; 16/16 refused under continuous rewrite,
                           realistic saves still produce usable pins
```

**Worth carrying forward:** this failure was visible for about one second in a run that was otherwise
green, during work on an unrelated gate. The instinct to re-run and move on would have buried a real
hole in the guarantee the product's trust model rests on.

---

# M8-I — gate G3: a build for somebody else's machine

**Date:** 2026-07-31 · **Method:** packaged the application, then made the package prove the claims made about it.

## The failure this gate is really about

A macOS application bundle that quietly reads from the checkout works **perfectly on the machine that built it**. It fails only on the tester's, hours later, with an error they cannot interpret and we cannot reproduce.

So `Scripts/package.sh` does not assert independence, it demonstrates it: the assembled bundle is copied to a temporary directory and launched **from `/`, with a configuration path outside the repository**, running the full headless selftest. All 12 arms pass there or the script exits non-zero and produces no zip.

`Bundle.module` resolves against the main bundle's resources first and the executable's directory second, and the two rules can be reached differently depending on how the process was started — so the resource bundle is placed in **both**, rather than picking whichever happened to work today.

## The privacy paragraph is checked, not merely written

The tester packet tells a stranger the application never connects to the internet. That is the one claim in the document they cannot verify for themselves, so the suite verifies it against the source: no `URLSession`, `NWConnection`, `CFNetwork` or `getaddrinfo` in any shipped file, and no `fetch`, `XMLHttpRequest`, `WebSocket` or `sendBeacon` in the renderer — the webview being the one component that could reach the network with no Swift involved.

The packet's other load-bearing sentences are checked too: that it names the single file the application writes, that it tells the tester to **keep** a file that diffs wrongly, and that it explains the right-click-to-open step, which is where an unsigned build loses people who then report "it doesn't open".

## The icon is drawn, not shipped

`Scripts/make-icon.swift` renders it: two panes, and one line hatched. The product's own vocabulary, and no colour carrying meaning (DEC-035) in the icon any more than in the diff. It lives in the repository as something readable and reviewable rather than as an opaque asset.

## One behaviour this gate added

A chosen folder containing no repositories used to produce three empty panes and a status line saying `0 repositories`. For a stranger that is indistinguishable from a broken application. It now says which folders were searched, states the two-folder depth limit — the usual reason a repository is missed — and points at Sources ▸ Add Repository.

Composed by a checked function rather than assembled in the view, for the reason that keeps recurring: **the state cannot be reached by clicking**, so it cannot be photographed, so the sentence has to be assertable somewhere else.

---

# M8-J — F1 wired, F3 and F4 resolved as region-level

**Date:** 2026-07-31 · **Method:** measured what the structural path currently says about a half-parsed file, then made it say the true thing.

## What a broken file looked like before

`invalid-tsx` and `truncated-file` — both in the corpus specifically because a half-typed file is the *normal* state under auto-refresh — produced **12 and 20 anchors and no signal whatsoever** that a region had never been parsed. `anchors()` skips `ERROR` nodes, so their bytes fell into the ordinary gap comparison and the result was presented as a fully understood structural analysis.

Now: `invalid-tsx` reports 1 unparsed region of 7 bytes, `truncated-file` 1 of 72, and both carry an F1 notice. Clean files report nothing.

## The marking rule, and the trap it avoids

Changed bytes inside an unparsed region are relabelled `fallback` — a change shown there has no structural claim behind it, which is what that label means. **Unchanged bytes inside the same region keep their label**, because comparison never depended on parsing (DEC-021): a region tree-sitter failed on is still honestly unchanged if its bytes match. Repainting it would invent a difference in the one place the tool is least able to justify one.

The structural result stands for the rest of the file and `usedFallback` stays **false**: F1 degrades part of a file, not the file. That is the distinction `13-…` §2 draws between F1 and F2.

## The check was wrong before the code was

The first version asserted that the half-typed fixture marks bytes as fallback. It marked none, and the code was right: deleting a `>` leaves the **new** side with no changed bytes at all, and the old side parses cleanly — so there is nothing inside an unparsed region to mark.

The third instance of the same shape in this project: DEC-034 (Raw has no unchanged segments), DEC-048 (a reindent has no old side), and now this. **Asymmetric edits keep producing it**, and the reflex worth keeping is to ask which side an edit actually has bytes on before asserting anything about both.

The case where marking does fire needed an edit *inside* a construct neither side can parse, and is now the fixture for it.

## F3 and F4 are region-level, and that is the answer

Neither is missing a producer:

- **F3** rides on the segment. `reconcile` lowers confidence where the byte diff contradicts an anchor; the contract carries `uncertain`, computed in the engine against `confidenceFloor` so a renderer cannot quietly redefine what counts as certain; the renderer draws a dashed underline.
- **F4** is counted and shown nowhere, by DEC-045. The detection remains as a guard — ambiguous nodes are never used as anchors — and the indicator was withdrawn deliberately.

A file-level notice for either would overstate a local doubt. The vocabulary now records this at the case itself, so the next reader does not wire a notice that DEC-045 already refused. A check asserts no ambiguity indicator reaches the contract, which makes adding one a deliberate act against a recorded decision rather than a drift.

---

# T0-probe — can the application tell when the shell is at a prompt?

**Date:** 2026-07-31 · **Method:** `forkpty` from Swift against this machine's zsh 5.9, driven by writing to the PTY as if typed.

The built-in terminal turns on exactly one question. Warp's input line works because it knows when the shell is sitting at a prompt: only then can a keystroke be safely edited locally instead of passed raw to whatever is running. Measured before planning anything else.

```
prompt mark (OSC 133;A)   seen
command mark (OSC 133;C)  seen
command output            round-trips
the user's own prompt     survived the injection
```

**The first probe was a false negative and worth recording as such.** It used `zsh -i -c "…"`, which runs a command and exits without ever entering the prompt loop, so `precmd` and `preexec` never fire. It reported "no marks" for a shell that emits them perfectly well. Anything measuring this has to drive a genuinely interactive shell.

**The hazard the probe found.** `~/.zshrc:16` defines `precmd() { vcs_info }` as a plain function. An integration that installs its own `precmd` replaces it, and the product owner's prompt silently loses its git information — a terminal that breaks the setup it was meant to live in. `add-zsh-hook` appends, and was verified to leave the existing hook working.

Full plan, cost and gate: `26-terminal-plan.md`.

---

# T0 — the gate: the four unknowns, measured in app-shaped code

**Date:** 2026-08-01 · **Method:** `swift run diffscope-t0` — a throwaway target that spawns `/bin/zsh -i` on a real `forkpty` PTY, ten shells per run, and drives them by writing to the PTY as if typed. Seventeen scenarios, each with its own deadline. The generated shell integration lives in a temporary directory; nothing of the user's is ever written.

`26-terminal-plan.md` §3 named four things. All four hold.

```
S0   an unmodified shell emits no marks at all              0 marks
S1   a prompt mark in five of five fresh shells             335–343 ms to the first mark (median 339)
S2   echo: C, output round-trips, D;0, then another A       exit 0
S3   false → D;1 · unknown command → D;127                  prompt detected after both
S4   clear: screen wiped, prompt still detected             erase sequence seen
S5   resize at the prompt, and while a program runs         COLUMNS follows: 100, then 120
S6   the user's vcs_info still reaches the prompt           prompt contains (main); the B mark rides on it
S6b  the same shell with a naive precmd assignment          marks arrive, the branch is gone
S7   vim enters the alternate screen, :q leaves it          shell usable afterwards
S8   the macOS motions, NSTextView and WKWebView            6/6 and 6/6
S9   ~/.zshrc and ~/.zprofile SHA-256 before and after      identical
```

## The two negative controls are what make the rest mean anything

**S0.** A shell with no integration reaches its prompt and emits **zero** OSC 133 marks. Without this, every result above would hold just as well if something already in the user's setup were emitting them, and nothing here would have measured the integration at all. Same shape as the `display: none` control in G2.

**S6b.** The hazard the first probe *described* is now **demonstrated**: the probe installs the wrong integration on purpose — `precmd() { … }` as a plain assignment — and watches `(main)` disappear from the prompt while the marks arrive perfectly. Both halves matter: the naive version works, which is exactly why it would have shipped.

## What the caret actually does

The same six keystrokes, delivered as real `NSEvent`s with real modifier flags, into `NSTextView` through `interpretKeyEvents` and into a `<textarea>` inside a `WKWebView` through `keyDown`. Sample text is two lines: `git commit -m "fix the thing"` / `git push --force-with-lease`.

| Motion | From | To | AppKit | WebKit |
|---|---|---|---|---|
| Option+← | 29 | 23 (start of `thing`) | ✓ | ✓ |
| Option+← | 23 | 19 (start of `the`) | ✓ | ✓ |
| Option+→ | 0 | 3 | ✓ | ✓ |
| Cmd+← | 35 | 30 (**line** start, not document) | ✓ | ✓ |
| Cmd+→ | 35 | 57 (line end) | ✓ | ✓ |
| Option+Delete | 29 | 23 | ✓ | ✓ |

**A DOM text field reproduces every one of them.** `26-terminal-plan.md` §4 assumed the motions are what an AppKit control buys — they are not; they are what *macOS text input* buys, and WebKit participates in it. That widens T2's options from "AppKit control overlaid on the grid" to "the input line can live in the same webview as the grid", which is a materially simpler window. The choice is T2's to make and is not made here.

**Option+Delete removes `thing"` — the word *and* the trailing quote.** That is native word semantics, and it is *not* what a shell's own `^W` does (whitespace-delimited, so it would stop at the quote). Replacing the line editor means inheriting the platform's definition of a word, and the two will not agree. Worth stating before someone reports it as a bug.

## What vim needed

`DA2` and `DSR-cursor`, answered by hand in the probe. A terminal that answers nothing looks broken to a full-screen program: it asks who it is talking to and waits. xterm.js answers these properly in T1 — this is recorded so that a stall there is recognised rather than re-diagnosed.

## Findings that were not on the list

- **The prompt costs ~340 ms.** `~/.zshrc` runs `nvm`, `compinit` and `ssh-agent` before the first prompt appears, so opening a terminal in the application will never be instant. It must not be on any path that blocks the interface.
- **Every interactive shell leaks an `ssh-agent`.** `~/.zshrc:7-8` does `eval "$(ssh-agent -s)"` and `ssh-add`, and the agent daemonises away from its parent. Ten shells, ten agents — and **363 were already running on this machine** before the probe started. A terminal that opens a shell per repository multiplies this quietly. Not our defect, but our feature makes it worse, and the user should know before it is theirs to notice. The probe reaps exactly the pids its own shells report and nothing else.
- **`local status=$?` must not be written.** In zsh `$status` is a synonym for `$?`; the integration uses `__ds_status`.
- **The B mark must be wrapped in `%{ %}`.** Without it zsh counts the escape as visible width and its own line editing goes wrong on a full line.
- **`.zshenv` must *not* restore the user's `ZDOTDIR`.** zsh re-reads the variable before each startup file, so restoring it there sends zsh to the user's `.zshrc` instead of the generated one and the integration silently does nothing. The restore belongs in `.zshrc`, after ours has loaded.

## Two harness defects, in the project's habit of recording them

**The web caret was seeded before the responder change.** Making the `WKWebView` first responder re-focuses the field and puts the caret at the end, so the first run measured Option+← from position 57 and reported 52 where 23 was expected. Read carelessly, that is "web text fields get the motions wrong" — a false negative about the surface, produced entirely by the measuring code, and the same shape as `zsh -i -c` in the first probe. The probe now reports the position it actually started from, so a seed that fails is visible instead of silent.

**A wait matched the echo of a typed command rather than its output.** The S0 control shell has no integration and so cannot report its agent on the side channel; asked directly with `echo T0-AGENT=$SSH_AGENT_PID`, the wait for `T0-AGENT=` succeeded against the *echoed input*, where the text is still `$SSH_AGENT_PID`. The parse then ran before the answer existed, silently, and that shell leaked exactly one agent per run — found by counting processes afterwards rather than by trusting the probe's own "9 reaped". The wait is now on the parse succeeding.

## What T0 did not prove

zsh 5.9 on this machine only. Bash's `--rcfile` path is designed and untested. No `ssh` password prompt, no `sudo`, no long-running interactive program other than vim. The escape hatch of §4 — forcing raw mode when detection is wrong — is not exercised, because nothing here has an input line yet. Detection being reliable in seventeen scenarios is not detection being reliable, and the escape hatch stays mandatory in T2 for that reason.

---

# T1-A — what the grid costs, and the frame that never came

**Date:** 2026-08-01 · **Method:** `npm run build` for the sizes; a throwaway binary linked against `DiffScopeTerminal` for the delivery counts, `cat`-ing 2,666,670 bytes through a real PTY twice — once counting `read` returns, once counting coalesced deliveries.

## The bundle

| | |
|---|---|
| `renderer.js` (CodeMirror, the diff) | 380 KB |
| `terminal.js` (xterm.js + fit addon, the grid) | 348 KB |
| `terminal.css` | 5 KB |

The grid costs about what the diff editor costs. Worth stating against the number that settled DEC-042: Monaco was rejected at **9.3 MB**, and a hand-written VT parser was rejected at weeks of work. 348 KB for a virtualised, reflowing, attribute-aware grid with scrollback is the same trade the renderer already made once.

## Coalescing output

```
raw reads        2605 deliveries   2,666,670 bytes
coalesced 16 ms     9 deliveries   2,666,670 bytes
```

A PTY hands over about **1 KB per read**, so a 2.7 MB dump is 2,605 crossings into the webview if each read is forwarded on its own — 289× more than the nine a frame-length window produces. Every byte survives both ways; the coalescing buffer concatenates, it does not sample.

The wall clock is 35 ms raw against 351 ms coalesced, and that is the honest cost: delivery is paced at one frame, so a large dump finishes about a third of a second later than the PTY did. Neither number includes `evaluateJavaScript`, which is what the 2,596 avoided crossings would actually have cost.

## The finding that mattered: a grid that draws nothing while every check passes

The first terminal selftest reported **OK on every arm** — output in the buffer, alternate screen entered, the pane sized 798×260, all sixteen palette tokens resolved — and the snapshot was **completely blank**.

xterm's DOM renderer paints inside `requestAnimationFrame`. WebKit stops firing those when the page is not visible, and a `WKWebView` reports `document.visibilityState === "hidden"` whenever its **window is occluded**. A selftest launched from a terminal is behind that terminal, so the buffer filled while the screen stayed empty:

```
occluded=true   pageVisibility=hidden   framesSinceLastProbe=0   renderedText=""
```

Once the window was genuinely brought to the front, the same run painted — `renderedText: "DIFFSCOPE-TERMINAL-OK"`, and later `"ALTERNATE-OK"` with the snapshot showing legible glyphs and a cursor block.

**This is M8-D's defect class arriving through a different door.** There it was two lists at zero width; here it is a grid whose renderer was never asked to run. Both report healthy state from every angle except the one that matters — what the reader would see. The probe now reports `renderedText`, `framesSinceLastProbe` and the pane's pixel size, so the difference between *held* and *drawn* is visible to a check rather than only to an eye.

The selftest's paint arm asserts drawn glyphs when the window is visible and prints **SKIPPED with the reason** when it is not. That is deliberately not a silent pass: an arm that quietly asserted nothing would be the third instance of *a check that is not run is not a check*.

## Two harness defects, recorded as usual

- **The selftest started the user's `$SHELL` instead of its own command.** Showing the pane and starting a shell were one act, so `toggleTerminal()` spawned zsh before the arm's `/bin/sh -c` script could, and the arm then reported on a buffer holding somebody's prompt. G3 runs this selftest from `/` on a stranger's machine, where that would have meant running *their* rc files. Showing and starting are now separate.
- **The frame counter measured nothing after the first suspension.** A self-perpetuating `requestAnimationFrame` chain dies the moment frames stop and never restarts, so it read zero forever afterwards — including while xterm was painting again. It re-arms on each probe, and reports frames *since the last question* rather than a total that cannot recover.

---

# T2-A — the input line, and two checks that were wrong before the code was

**Date:** 2026-08-01 · **Method:** `swift run diffscope-verify` for the routing table and the history; a selftest arm driving the real page with real `keydown` events against `/bin/sh -c 'printf "\033]133;A\007"; cat'` — a fixture that emits a prompt mark and then echoes, so the marks, the round trip and the write to the PTY are all on the path without depending on anybody's `~/.zshrc`.

T2 had little to discover — T0 had already measured the two things that could have sunk it (the motions work in a web text field; prompt marks are reliable). What it produced instead is worth recording as method.

## The arms, and what each one would catch

```
terminal-input         a prompt mark opens the input line, focused, chip reads "prompt"
terminal-submit        a typed line reaches the shell and the field clears
terminal-handover      Tab gives the line to the shell; the chip says the shell has it
terminal-escape-hatch  ⌥⌘R forces raw and the chip admits it
```

The chip is asserted in every one of them. A mode indicator that can be wrong is worse than none: the reader decides where to type by reading it.

## Two checks that passed or failed for the wrong reason

- **A check greps for `.zsh_history` to prove no history file is read — and failed on the comment saying we do not read it.** Third instance of this exact shape after `precmd() {` in T1's integration check: a substring search over source that *documents* a decision finds the documentation. Comments are stripped first now, in both.
- **A check asserted "the shell received the text and the key" by testing `historyCount == 0`** — a condition that had nothing to do with the claim and was true regardless. It was replaced by reading back what `cat` echoed, which is the only evidence that bytes actually crossed. **A check whose name and whose condition disagree is worse than a missing check**, because the name is what the next reader believes.

The sequencing mistake that exposed the second one is itself the behaviour working: after a handover the mode is raw, so `Enter` belongs to the shell and is not remembered locally — the suite now asserts that on purpose.

## What the photograph showed that no check did

The snapshot after the handover showed the input row and its chip drawn correctly — and **the previous session's output still in the grid above it**. Restarting a session had left the old shell's scrollback in place with nothing to mark the boundary, so two shells' output read as one. A new session now resets the grid.

Nothing failed. The buffer was correct, the chip was correct, every arm was green. It is the same lesson as M8-D and T1-A, for the third time: *look at the surface*.

---

# T3-A — what the watcher already sees, and a guard that asked the wrong question

**Date:** 2026-08-01 · **Method:** a throwaway binary linked against `DiffScopeGit`, starting a real `RepositoryWatcher` on a scratch repository and then doing from a shell exactly what a reader does in the terminal. Signals counted, time to the first one measured.

## The premise was wrong

T3 was planned around a sentence that turned out to be false on this machine: *"`git commit` does not touch the working tree, so the file-system watcher will not see it."*

```
write a tracked file    1 signal   first at 418 ms
git add                 1 signal   first at 432 ms
git commit              1 signal   first at 443 ms
git reset --hard        1 signal   first at 433 ms
```

**All three are seen, one debounced signal each.** `.git` lives inside the watched root and DEC-027 excludes only `node_modules`, so a commit's index and ref writes are ordinary file-system events. The ~430 ms is the debounce doing its job (DEC-026: 0.4 s quiet period), not latency in the watcher.

So the file list needs nothing from the terminal. What a finished command *is* still used for is the **repository-level** sweep — the uncommitted count and commits-ahead-of-base shown beside every repository — which no file-system event triggers and which otherwise stays stale until the window regains focus (DEC-006). The refresh after a command was narrowed to exactly that, and debounced against the same quiet period so one command cannot produce a cascade.

Had this not been measured, the terminal would have carried a second, redundant refresh path for the file list, and the first person to notice would have been whoever wondered why one edit refreshed twice.

## The guard was asking what the shell is called

The follow-under-guard rule (DEC-056) first read: *send `cd` only if the shell kind marks prompts* — that is, only if `$SHELL` is named `zsh` or `bash`. Five checks failed at once against a fixture that emits prompt marks by hand from `/bin/sh`.

The fixture was right and the guard was wrong. What matters is whether **marks have actually been seen**, not what the binary is called: a shell this product does not recognise may still be marking its prompts through the reader's own integration. The guard now asks `hasSeenPromptMark`, which is the question the behaviour depends on.

Worth noticing as a pattern: the check failed for a reason that looked like a fixture problem, and the fixture was the honest one.

## The quoting is proved against a shell, not against a belief

`shellSingleQuoted` is checked in two directions. The string side asserts every hostile path comes back as one closed single-quoted string. The **positive control** creates each of those directories for real, runs `cd -- <quoted> && pwd` in `/bin/sh`, and requires the shell to land in it:

```
/tmp/plain   /tmp/with space   /tmp/it's        /tmp/semi;colon
/tmp/$(id)   /tmp/`id`         /tmp/dollar$HOME /tmp/new\nline
/tmp/-leading-dash             /tmp/quote"double
/tmp/ŻABKA   /tmp/back\slash
```

12 of 12. A string check alone would only ever confirm my idea of quoting; a shell confirms the quoting. The `--` is why the leading-dash case works, and the check would fail without it.

---

# M8-J — the keyboard path, walked on a 63-file working tree

**Date:** 2026-08-09 · **Method:** the coverage table of `12-…` §9 transcribed into `KeyboardFunction` and checked against `KeyboardMap`; a 63-file repository built by `Scripts/keyboard-tree.sh`; the application selftest walking it with **real `NSEvent` key equivalents** through the real menu bar and real arrow keys through the table.

## The tree had to be built

`mailingi-2025` had 63 changed files on the day DEC-033 was written. It has **3** today, and no repository in the corpus is near that size. The shape the definition of done is stated against no longer exists to point at, so it is constructed — 52 modified, 4 deleted, 4 added, 3 untracked across nine directories five levels deep, which is the corpus's own shape.

The script writes and the application does not. R-8 is a statement about the Git operations `diffscope-app` itself can issue, and a shell script building a fixture leaves it untouched — the same separation DEC-053 draws between the application acting on its own and the user typing in a shell.

## The walk

```
⌘] through the menu bar    63 of 63 files    62 keystrokes    9 headers passed    0 blind stops
↓  through the table       63 of 63 files                                        0 blind stops
```

62 keystrokes for 63 files is the number that matters: grouping added nine headers and **cost nothing**, which is what DEC-033 promised and what only ⌘] delivered before this milestone.

**The arrow keys did not.** With `shouldSelectRow` removed — run deliberately as the negative control — the same walk reports **8 blind stops**: the selection lands on a header, the handler returns without a word, and the diff pane goes on showing the previous file. Every check in the suite passed in that state, because the suite cannot press a key.

## What the coverage check found immediately

*Show raw for the current region* — the last row of `12-…` §9 — **had no implementation at all**. Not a weak one: no menu item, no action, no renderer command, from M6 through M8. The fourth instance in this project of a written requirement that nothing runs, after `runBundleFreshnessCheck`, `checkAttr`/F8, and T-10's grapheme snapping.

It is now ⌥⌘V (DEC-057), and it is cheap because stops come from the canonical diff: stop *n* is the same region in Raw as in Structural, so the shell records the stop, switches mode on the same pinned pair, and jumps back. Measured in the selftest: `mode=raw stop 0 → 0`, and the second press returns to `structural`.

## The crash the walk found, which no check could have

Holding ⌘] through 63 files **aborted the process**:

```
Assertion failed: ((uint32_t)(version) < (&self->heads)->size),
  function ts_stack_remove_version, file stack.c, line 660.
```

One `TSXParser` is shared by the application and every render ran on the concurrent global queue, so two threads entered `ts_parser_parse_string` at once. Nothing in the suite could see it: **every check in this project parses on one thread**, so the shared parser had never been used the way the application uses it.

Two fixes, because they are two different faults:

- `TSXParser` takes a lock around the parse. The object owns the C resource, so it is the only place that can promise anything about it.
- Renders run on a serial queue, and a result whose file is no longer selected is dropped. The second half is its own defect: before it, a fast walk could push one file's diff under another file's name.

The check that now stands for this — 24 concurrent parses on one shared parser — was run once with the lock taken back out. It does not report a failure; **it aborts the suite**, at `stack.c:464`. That is what the defect does, so that is what the control has to show.

## What the photograph showed

`keyboard.png` is the first snapshot in this project of the **window** rather than of the document — `cacheDisplay` on the content view, which is why the diff pane comes out black (a `WKWebView` renders out of process). That was the point: M8-D's blank rows survived because the one surface nothing photographed was the shell.

It shows the walk landing on `File0.tsx` with the row highlighted, the group headers drawn, the `mod`/`add`/`del`/`unt` badges correct, and the status line reading `file 1/63 · packages/app-0/…`. One cosmetic thing worth recording rather than fixing in a hurry: the repository pane draws empty rounded row backgrounds below its single row, from `usesAlternatingRowBackgroundColors`. With one repository configured it reads as a list still loading.

# M8-K — the four statements the interface was not making about itself

**Date:** 2026-08-09 · **Method:** `23b-spec-vs-app-audit.md` §1.10 and §2 taken as a list and closed one by one; the two engine-side items measured by the check suite, the two shell-side items by the check suite *and* the window snapshot.

The audit had four items left and they are the same kind of thing: **statements the interface makes about its own trustworthiness**, three of them missing and one of them wrong.

## The parser state was inferred, and both inferences are wrong in one direction

`12-…` §5.2 lists seven indicators and calls them *"not optional features — these are how the invariant becomes visible"*. Six were built. **Parser state** — parsed, partially parsed, not parsed — was visible only as the presence or absence of a fallback notice, and that inference fails in both directions:

- a file can parse **completely** and still carry a notice, because an active filter (F8) says nothing whatsoever about the parser;
- a file can be **partially** parsed while the structural result stands, and F1's notice reads like a whole-file failure.

`ParserStateReport.of` decides it from what the run did, and `StructuralStats.parserState` derives it beside the statistics, so the check suite exercises the same derivation the window does. The one case the syntax layer cannot see is a structural result **discarded by validation after parsing** — the parse succeeded and the check afterwards failed, so the shell says `parser: parsed — structural result discarded after parsing`. Reporting "not parsed" there would name the wrong stage of the pipeline, which is precisely why §5.2 lists parser state separately from fallback marking.

## The mode pill reported the reader's selection

Recorded in `23b-…` §2: the pill could read `mode: structural` beside a notice saying structural analysis was unavailable. Both facts are worth having — the selection is what ⌘1–3 will return to, the path is what is on screen — so the pill states both when they disagree: `mode: structural — showing raw`.

**The first version of it invented a disagreement.** Comparing the path against the *mode* made Expanded — a presentation flag over the structural path — read as `mode: expanded — showing structural`. Three modes, two code paths (DEC-013); the comparison is against the path the selection *implies*. Nothing in the harness caught this: the selftest did, in the disclosure arm, which is the one arm that runs in Expanded. A wording defect is still a defect, and the surface that finds it is the one that renders words.

## The branch was in a tooltip

`12-…` §2 lists the branch as displayed. A tooltip is not a display — it is invisible until pointed at, so a reader walking the list from the keyboard, the path M8-J made a definition-of-done item, never sees it. The row now reads `kbtree · main · 63△ ↑0`, and the two unusual head states are the ones that earn the space: `no commits yet (main)` is the sentence that explains why all four scopes are greyed out on `carrefour-inapp`.

## The count did not say what it was counting

`git status --porcelain` collapses an untracked directory to one entry; libgit2's default expands it; X-4 measured the same repository reading **63 or 165**. §2 requires the convention to be stated, and nothing stated it. The sentence lives in `RepositoryReader.uncommittedCountConvention`, next to the operation it describes, so changing `statusPorcelain()` to `statusPorcelainAll()` puts the sentence and the lie in the same diff — and a check asserts the operation actually run matches the words.

## The caption disappeared twice before it was looked at

First it drew at three lines with the third clipped. Shortening the text then removed it **entirely**: an `NSStackView` will give a label zero height beside a scroll view that grows without limit. Both content priorities are now pinned.

Worth recording as a method note rather than a fix: the first crop of `keyboard.png` looked like the caption had vanished a second time, and it had not — `secondaryLabelColor` at 10 pt survives a downscale badly. It took a contrast-enhanced crop at full resolution to see it. **A snapshot answers "is it drawn"; it answers "is it legible" only if you look at it the size the reader does.**

## Numbers

```
1109 → 1143 checks     (34 new: parser state 16, mode pill 7, contract 6, convention 5)
37 selftest arms       structural, disclosure and degradation now assert the chips in the document
```

The two selftest assertions that matter are in the degradation arm, where the reader asked for structural, the file was never parsed, and the interface used to say `mode: structural` without qualification: it now requires `mode: structural — showing raw` **and** `parser: not parsed` to reach the DOM.

# M8-L — T-11's second and third relocation shapes

**Date:** 2026-08-09 · **Method:** two fixtures built and measured through `diffscope-verify`'s per-fixture statistics; the corpus's own T-11 coverage turned into three assertions.

`26-coverage-audit.md` said it plainly: *"T-11 is proven on a single relocation shape, and a second shape would be worth more than any other addition to this table."* There are three now.

| Fixture | Shape | Moves found |
|---|---|---|
| `moved-function` | one statement relocated | 1 |
| `moved-block` | a multi-line function relocated past two declarations | 1 (+1 below floor) |
| `moved-two-blocks` | two independent relocations in one file | 2 (+1 below floor) |

`moved-two-blocks` is the one that makes `link` mean something. With a single move in the corpus, a `link` field that always read `0` would have passed every check ever written; with two, T-11 compares each link's two sides and a cross-paired link fails.

## The failure that came with it, which is the fourth of its kind

The first `moved-two-blocks` swapped two **short single lines** — `let retryLimit = 3;` and `export type Session = { id: string };`. Zero moves, ten hunks. The canonical diff had matched `" = "` and `";"` across the two lines, so on the old side the relocated line was two changed fragments with an unchanged fragment between them, and the line-based search of DEC-038 had no whole changed line to pair.

That is now the fourth construction failure of the same family: two near-identical functions swapped, `export const VAT_RATE` sharing a prefix, and two short lines sharing punctuation. **The generalisation is worth stating once:** the shorter the relocated line, the more likely the canonical diff has already spent its bytes matching fragments elsewhere. Blocks relocate detectably; short statements often do not.

It is a property of DEC-038 as decided rather than a defect — widening the search to partly-changed lines would put bytes the canonical diff calls unchanged inside a `moved` range.

## The coverage assertion was wrong before the corpus was

The new check asks the corpus to prove it exercises T-11 in more than one shape, and its multi-line arm asked whether any **segment** of a move contains a newline. A relocated block arrives as one segment per line, so none does: the check reported **zero multi-line moves on a corpus that has two**, and failed while the fixtures were correct. Measured over the link's whole span now.

Same shape as the two checks M8-C had to correct after they failed correct behaviour. A check written at the same time as the thing it checks tends to encode the same guess.

```
1143 → 1182 checks     34 fixtures, up from 32
```

# M8-M - OQ-046 answered: no read-only operation triggers auto-gc

**Date:** 2026-08-09 - **Method:** two arms. A scratch repository with the thresholds brought down to it (`gc.auto=1`, `gc.autoPackLimit=1`, `gc.autoDetach=false`) so maintenance fires at the first opportunity, in the foreground; and a one-off measurement against the largest repository in the corpus, which turns out to sit at 91% of git's default threshold without any help.

The question has been open since the read-only audit, and the audit said why it could not answer it: it ran below every threshold, so its "no" was a "no" about the wrong repository.

## The mitigation is not available, which is why it had to be measured

`gc.auto=0` in the repository's config is a **write**, forbidden by DEC-003. Passing it per invocation as `-c gc.auto=0` is forbidden too, for an unrelated reason: `-c` is in `GitOperation.forbiddenArguments`, because an operation whose configuration the caller injects is no longer the operation the registry describes. Both doors are closed by decisions taken for other reasons, so a "yes" here would have cost a reopened decision.

## Arm one: thresholds brought down to the repository

| | |
|---|---|
| 15 registered operations, one pass | maintenance state unchanged |
| three full sweeps of the registry | unchanged |
| **positive control** - one `git commit` in the same repository | **fires** |

The positive control is the whole check. Without it, "no gc happened" is equally consistent with "the configuration was not eager after all", which is a check that proves nothing while passing - the shape this project has now hit five times.

**Arming it taught something small.** The first version asserted the repository had more than one pack, and it never did: building the fixture trips auto-gc several times on its own, so by the time anything is measured git has already packed and pruned to one pack. That is the arming working, not failing. The assertion is now that the thresholds are in force and there is loose material to collect.

## Arm two: the largest real repository, measured once

`mailingi-2025`, 1.5 GB of `.git`, no `gc.*` configuration of its own:

```
gc defaults in force: gc.auto=6700, gc.autoPackLimit=50
before:  packs=19  loose=6115  gc.log=no
after 8 read-only operations
after:   packs=19  loose=6115  gc.log=no
```

**6,115 loose objects is 91% of the default threshold.** This is not a repository that happens to be far from the line; it is one sitting just under it, and the read-only operations moved nothing.

## The answer

**No.** Auto-gc is offered by git after commands that *create* objects or refs - commit, merge, am, receive-pack - and none of those is in the registry. The eager-threshold arm is now a permanent check, so an operation added to the registry that does trigger maintenance fails the suite rather than surprising a user with a foreground gc on a 1.5 GB repository.

What remains true, and is not a defect: a `git commit` **typed by the user in the built-in terminal** can trigger auto-gc. That is DEC-053's separation exactly - the application acting on its own writes nothing; the user's shell does what the user says.

# M8-N - the two wall-clock checks re-expressed as ratios

**Date:** 2026-08-09 - **Method:** each cost assertion given a baseline measured on the same machine, in the same build, immediately before the thing it bounds; the whole suite then run with eight CPU spinners saturating the machine.

`21-agent-handoff.md` had carried this as a known weakness since M8-C: `BudgetChecks` asserted an absolute 2.0 s, and with four other processes running the refusal measured 2.3 s and the suite reported 1079/1080 while the code was doing exactly the right thing.

DEC-050 rejected wall-clock deadlines for *behaviour* on that reasoning - a budget must be counted work, because giving up at a deadline makes the output depend on the load. The same shape had survived inside a check *of* DEC-050.

| Assertion | Baseline it is now measured against |
|---|---|
| a pathologically dense file returns rather than hanging | one parse of the same file - parsing is linear and unavoidable, matching is what the budget stops |
| a file above the size limit is refused without parsing it | one pass over the same bytes - the `classify` scan that runs first and cannot be avoided |

Both bounds are small multiples (4x and 12x, each with 0.2 s of slack for the scheduler). Load inflates the baseline and the measurement together, so the ratio survives what the absolute did not.

```
idle:                 1188/1188
8 CPU spinners:       1188/1188, both checks passing
```

The ratio also states the claim better than the second did. *Refused without parsing it* means "costs about what looking at the bytes costs" - a sentence about the work done. "Under two seconds" is a sentence about the machine.

# M8-O - the corpus and the plan can now disagree out loud

**Date:** 2026-08-09 - **Method:** `15-test-corpus-plan.md` §4 transcribed into `FixtureCatalog`, checked against the directory, and the gap closed.

DEC-057's treatment applied to the fixture list. The keyboard map was a Markdown table and a hand-written menu with no link between them, and when they disagreed nothing noticed for three milestones. §4 was the same shape: **sixty named cases in a document, thirty-four directories on disk.** `18-version-one-scope.md`'s definition of done opens with *"every P0 fixture group passes T-0 ... T-11"* - a claim about a list nothing had ever read against the corpus.

## What the check found on its first run

**Thirteen P0 cases named in the plan did not exist**, eight of them in §4.1, *the founding cases* - the group the product is named after:

```
jsx-wrapper-added            jsx-wrapper-type-change    jsx-text-punctuation
identifier-typo              repeated-identifier-change prop-value-change
prop-reordering              spread-prop-reordering     template-literal-expression-change
clsx-expression-change       eslint-autofix             import-item-removal
image-file
```

`prop-reordering` is the one that stings. It is **item 4 of the definition of done** - *"prop reordering with unchanged values never reports no change"* - and it was proven only by an input written inline in `MatchingChecks`. The plan had asked for a fixture since Phase 6.

All thirteen are built. 34 -> 47 fixtures, 1188 -> 1407 checks.

## Evidence that is not a directory is now named as such

Ten cases cannot be file pairs, and each says why in the catalog rather than being quietly absent: `eol-filter-active` needs `.gitattributes` and an index; `huge-file` would put megabytes in every clone; the file-level operations in §4.7 are properties of a repository. **`generated-file` is listed as not proven at all**, because OQ-029 is open and a fixture would freeze an answer nobody has chosen. A gap that is counted is worth more than a gap that is tidy.

## A gap the new fixtures exposed rather than closed

`prop-reordering` and `spread-prop-reordering` are classified as **neither** `reordering` nor `formatting-only`. §4.1 hoped for the first. The detector is an exact-permutation equivalence test over the aligned gap pair (DEC-046), and once the props are reformatted the pairs are fragments rather than whole attribute lists, so the test cannot fire.

Recorded rather than papered over, and the dangerous direction is checked: **a reorder is never presented as formatting-only**, asserted on all four reordering fixtures. Formatting-only is the one classification the interface may quieten (DEC-048), so claiming it about a change that can alter behaviour is the failure that matters. Not claiming `reordering` costs a label; claiming `formatting-only` would cost the invariant.

```
34 -> 47 fixtures      1188 -> 1407 checks
```

# M8-P - the design contract described a window with one webview in it

**Date:** 2026-08-09 - **Method:** `24-design-contract.md` read by a check for the first time; every class, element and snapshot the code emits compared against it; the gap closed and a negative control run.

The product owner asked a question that turned out to be the audit: *the design includes a terminal - does it have a ready view in the app?*

It does. `#grid`, `#input-row`, `#mode`, `#cwd`, `#line`, sixteen ANSI colours, every value from `tokens.css`, checked for literals by `DesignChecks` since T1. **The contract a designer reads did not mention any of it.**

## Why it was missing, which is the interesting part

G2 passed on 2026-07-31. T1 - the terminal's grid, in a second webview - landed on **2026-08-01**. The contract was written the day before the surface it was supposed to describe existed, and nothing re-read it. Its §3 is titled *"Every class the renderer emits"*.

**Nothing had ever read that document.** Not one check opened it. It is the sixth instance in this project of a written promise with nothing running against it, after `runBundleFreshnessCheck`, `checkAttr`, `MANIFEST.json`, T-10's grapheme snapping and §9's missing keyboard row. The pattern is now reliable enough to state as a rule: *a document that makes an exhaustive claim needs a check, or the claim decays at the speed the code moves.*

## What is checked now

| | |
|---|---|
| every `ds-` class `main.js` applies | named in the contract |
| every `id` the two webviews emit | named in the contract |
| every snapshot the selftest writes | listed in §6's walkthrough |
| negative controls | a class the renderer does not emit is absent; the contract names the terminal |

Verified by breaking it: renaming `#cwd` in the contract fails the run with `— cwd`. A `contains` over a five-thousand-word document is exactly the kind of assertion that passes for the wrong reason, so it was worth proving it bites.

**The snapshot check caught its own author first.** The regex matched `named:` anywhere, including `moveFocus(to:named:)`, and demanded the contract list "repositories", "files" and "diff" as pictures. Narrowed to the three real call sites - `snapshot`, `snapshotTerminal`, `windowSnapshot`.

## What the contract now tells a designer that it did not

- **Three surfaces, not one**: the diff webview, the terminal webview, the AppKit chrome.
- **xterm cannot read CSS variables.** `terminal.js` resolves the `--ds-term-*` names and hands over the values, so a token that does not exist becomes a colour xterm invents. That is what the grid probe's `missingTokens` is for.
- **The sixteen ANSI colours are literal on purpose.** The palette is what a *program* addresses by index; `ls` asks for green, and `Canvas`/`CanvasText` cannot express it. A palette collapsed toward the background makes program output unreadable rather than merely off-brand.
- **`keyboard.png` is the chrome picture.** §6 still said there was no automation for photographing the window - M8-J built exactly that, five milestones' worth of interface in one image.
- **Look at the pictures at full resolution.** M8-K's caption looked absent in a downscaled crop and was there all along.

```
1407 -> 1413 checks
```

# M9-C — a check that failed once, could not be reproduced, and taught the harness to name itself

**Date:** 2026-08-11 · **Method:** the suite run five times idle and three times under eight CPU spinners, with the whole output captured rather than tailed.

The first run of this session reported **1597/1598**. Every run since — five idle, three with eight spinners saturating the machine — reported **1598/1598**. The failing check was never named, because the first run's output had been piped through `tail -20` and the `FAIL` line was fifteen hundred lines above the summary.

That is the finding worth recording, and it is about the harness rather than about any check: **a run that fails announces the count and hides the name.** M8-N was found the same way and only because someone kept the output. So `report` now collects failed names and the run reprints them under `what failed:` beside the count. A truncated log still identifies the check.

## Three arms that state a property of the code using a bound on the machine

Not the culprit — the culprit is unidentified and stays that way honestly — but they are the same defect M8-N took out of `BudgetChecks`, and they are provable by reading rather than by waiting for them to bite.

| Arm | Was | Is |
|---|---|---|
| the R-9 race, both shapes | whatever reads fit in 1.5 s | a fixed 200 reads (continuous rewrite) and 100 (saves 30 ms apart), with a 60 s valve |
| the debounce fires once | waited 1.5 s | waits `4 × maximumDelay`, breaking on the signal |
| a real write reaches the application | waited 3 s | waits 10 s, breaking on the signal |

The debounce one is the clearest: DEC-026 allows the refresh to take up to the **2 s cap**, and the arm waited **1.5 s** for it. A machine that delivered at 1.7 s failed a check of a specification it was meeting. Nothing waits longer in the ordinary case — every loop leaves the moment the thing it waits for happens.

Bounding by reads also states the claim better. *No pin certifies a version that never existed on disk* is a property of two hundred observations, not of a second and a half; the second and a half was only ever a way of getting some.

```
idle:            5 runs, 1598/1598
8 spinners:      3 runs, 1598/1598
after the change: 200 reads / 0 blended / 200 refused, and 100 / 0 / 0
```

Both counts are now the same on every run, which is the point: the previous ones moved with the load, and a number that moves cannot be compared with the last one.

# M9-D — what the unified layout costs at fifty thousand lines, and where the cost actually is

**Date:** 2026-08-11 · **Method:** a selftest arm (`scale-*`) that renders three synthetic pairs in **both** layouts on the same model and reports the ratio; composition timed over twenty iterations because this webview clamps `performance.now()` to a millisecond.

DEC-059 made unified the default, and it composes its document in JavaScript from both sides **on every render**. Nobody had run that on a large file. `16-…` §1.3's rendering numbers are from a prototype — five thousand lines, side by side, before this layout existed — and §3 had no row for composition at all.

The expectation going in was that `projectSegments` would be the problem: it is a nested loop over segments × runs, called twice per render. It is the only superlinear term, and it is not the problem.

| Case | Path | split | unified | ratio | compose | project | dispatch |
|---|---|---|---|---|---|---|---|
| 50,000 lines, a change every 200 | raw | 49 ms | 30 ms | **0.61×** | 1.100 ms | 0.050 ms | 28 ms |
| one minified line, ~1 MB | raw | 45 ms | 22 ms | **0.49×** | 0.450 ms | 0.000 ms | 22 ms |
| 3,000 lines, a change every 5 | **structural** | 31 ms | 21 ms | **0.68×** | 0.350 ms | 4.750 ms | 16 ms |

**Unified is cheaper than side-by-side in all three, and the reason is structural rather than lucky:** split populates two editors with the whole of both sides, unified populates one document. The composition it does on top — a 1 MB string and fifty thousand line-meta entries — costs **1.1 ms**, about 4% of what the dispatch costs.

**The cost is the CodeMirror dispatch, in both layouts**, and unified pays it once.

## The quadratic term is real and is bounded by a decision that was not written for it

The structural case is the only one that reaches `projectSegments` with segments in it: 3,633 segments against 1,800 runs is ~6.5 M inner iterations, and it measures **4.75 ms** — 22% of that render. The two raw cases carry **two** segments between them, because a raw fallback is one segment per side, so they would have let the loop pass untested. That is why the third case exists and why every line reports `path=`.

What keeps it safe is **DEC-050's 30,000-node budget**: a file dense enough to produce many more segments than this does not take the structural path at all. The budget was chosen to stop the matcher, and it happens to bound the projection too.

**So this is recorded as a known weakness rather than optimised.** A merge join over two offset-sorted arrays would make it linear, and there is no measurement today that asks for it. **Re-measure this if DEC-050's node budget is ever raised** — the term grows with the product, so tripling the budget is roughly nine times this cost.

## The arm can fail, and was made to

A bound that has only ever seen the fast path is not a bound. `diffscopeInjectSlowProjection` makes the projection a hundred times its own work, in the shape `diffscopeInjectHostileStyle` established for the style audit: the ratio goes to **90.9×** against a 2.0× bound, and the arm exits non-zero.

## Two things the measurement had to be built around

- **`diffscopeProbe` returns `oldText`, `newText` and `unifiedText` in full.** At fifty thousand lines that is megabytes of JSON across the bridge, which would have been most of what any timing arm measured. `diffscopeTimings` returns numbers only.
- **Frame time is not measured and cannot be here.** `requestAnimationFrame` is suspended whenever the window is occluded, which a selftest launched from a terminal always is — T1-A, which cost a terminal grid that passed every arm while drawing nothing. These are synchronous composition numbers, which is the question DEC-059 left open, and they say nothing about paint.

# M9-E — the pin guard certified an empty file, and the check that should have caught it sampled fifteen reads

**Date:** 2026-08-11 · **Method:** the R-9 race bounded by reads instead of by a clock (M9-C), the blend arm made to report the **shape** of what it let through, then the same race run before and after DEC-068's change.

## What M9-C's bound exposed the moment it was applied

The R-9 arm ran for **1.5 seconds**. On this machine that buys **15 reads**, and on those fifteen it asserted *no pin certifies a version that never existed on disk*. Bounding it by reads instead took it to 200, and blends appeared on the third run.

```
before, time-bounded (8 runs):    15, 15, 16, 16, 15, 16, 15, 16 reads — 0 blended
after, read-bounded (6 runs):     200 reads each — 0, 0, 0, 0, 1, 4 blended
```

**Five blends in 1,200 reads, ~0.4%, and clustered** — four in one run and none in four others, which is what phase-locking between a reader and a writer looks like rather than an independent per-read probability.

M8-H had measured this guard's two halves leaking at **6 in 20** and **3 in 8,095**. Fifteen observations could not have detected anything in that range. **The arm was not weak, it was under-sampled**, and the count was invisible because it was never printed — only the elapsed window was chosen, and the reads it bought were whatever the machine managed.

## The shape is what identified it, and it took one line to get

`1 blended of 200` sends the next reader back to re-run the suite. So the arm now says what it saw:

```
4 blended of 200 — 0/52000 bytes, 0 A-lines + 0 B-lines · (×3)
```

**Every blend was a zero-length file.** Not a torn mix of the two versions — the whole file, empty.

The mechanism follows immediately. A non-atomic in-place save truncates and then writes; in the window between, the file is genuinely zero bytes **and genuinely quiescent**. Three stats agree the size is 0, both reads return nothing, every term of DEC-049's guard is satisfied. The guard asks *did anything change while I looked*, and nothing did — the file was empty for the whole of a very short look.

Two things hid it further. Both fixture versions are exactly **52,000 bytes**, so `FileStamp`'s size term could never discriminate between them and only `mtime` was doing any work. And the defect's presentation is the loudest one available: a file caught mid-save renders as **the whole file deleted**.

## After DEC-068

The confirming read is separated from the first by `settleRetryDelay` — 20 ms, already in the type, already sized against a measured 11 ms atomic save. A transient state now has to persist across a window to be certified; a real one does.

| | before | after |
|---|---|---|
| continuous rewrite, blended | 5 in 1,200 reads | **0 in 1,600** |
| continuous rewrite, refused | ~199 of 200 | 200 of 200 |
| saves 30 ms apart, refused | 0 of 100 | **~30 of 100** |
| whole suite | not timed | 113 s |

**The cost is in the third row and it is the honest trade.** A 20 ms window is one a write can land in, so a burst of saves refuses about three pins in ten where it previously refused none. The arm that exists to object to this — *a normal burst of saves still yields usable pins* — passes with ~70% settling against its >50% floor. A guard that refused everything would be an outage, and this is not that.

**The suite was not timed before the change, so no delta is claimed.** 113 s is what it costs now.

## What stands as the negative control

The pre-change measurement is the control, in the form M8-H used: **remove the separation and the blends return at 0.4%**, measured over 1,200 reads rather than argued. No new arm was added for it, because a recorded rate from the same harness is the stronger evidence and the code to produce it is one line away in either direction.

**0 in 1,600 reads is good evidence, not proof.** At the pre-change rate, 1,600 reads would have been expected to produce about six. Clustering makes the arithmetic softer than that — the failures are bursty rather than independent — so the honest statement is that the shape that produced every observed blend is now impossible, and the rate is consistent with that.

# M9-F — OQ-054 was wrong about the mechanism and wrong about the remedy

**Date:** 2026-08-11 · **Method:** the filesystem probed directly for case and normalisation behaviour, Swift's string comparison probed in a standalone binary, then the discovery path measured through a check written to fail.

OQ-054 asked for **case-folded and NFC-normalized** path matching and named the consequence: a mismatch means *auto-refresh silently stops updating that file*. It had been open since Phase 3.5 and the audit earlier the same day confirmed nothing implemented it. Everything in that sentence turned out to need correcting.

## The stated failure mode cannot happen

`RepositoryWatcher.deliver` ORs the event flags and signals `.changed` for the **whole repository**. No FSEvents path is ever compared with a Git path. The entry was written against a per-file watching design; DEC-007 and DEC-027 built a per-repository one, and nobody went back to the question.

## The filesystem, asked rather than assumed

```
created "Foo"          → "foo" resolves            → case-INSENSITIVE
created NFC "żabka"    → listing returns NFC        → normalization-PRESERVING
looked up by NFD form  → found                      → normalization-INSENSITIVE
created NFD alongside  → collides with the NFC one  → one directory, not two
```

So **reading a file never fails for either reason** — the kernel resolves the name. Only comparison in Swift can break.

## Swift's comparison, which is half the entry answered by the language

| | |
|---|---|
| `nfc == nfd` | **true** |
| `(nfc + "/pkg").hasPrefix(nfd)` | **true** |
| `Set([nfc]).contains(nfd)` | **true** |
| `Array(nfc.utf8) != Array(nfd.utf8)` | **true** — the bytes really do differ |
| `"Projects" == "projects"` | **false** |

`String ==` is canonical equivalence, so **the NFC half of OQ-054 needs no code at all.** This is M6-C read backwards: there, canonical equivalence meant an NFC detector could never fire and detected nothing while its fixtures passed. Here the same semantics do the work for free. It is now **asserted in the suite** rather than relied on quietly, with the differing bytes as the control — the second time this project has depended on these semantics, and the first was a defect.

## Root scanning was never broken either

```
passed in : /var/folders/…/caseroot
entry back: /private/var/folders/…/CaseRoot/web
resolvingSymlinksInPath: /var/folders/…/CaseRoot
```

**`contentsOfDirectory` returns the filesystem's own spelling** — canonical case, and `/private/var` rather than `/var`. `resolvingSymlinksInPath` canonicalises case too. So a repository found by scanning always carries the canonical path, and the first check written for this — two case-differing roots — **passed on the unfixed code**. That is the measurement contradicting the plan that preceded it, which is the habit this project keeps.

## What was actually broken

An **individually added** repository is taken verbatim from the configuration and never goes through either of those. DEC-037 put roots and individual repositories in one list, so the same working tree reached both ways arrives spelled twice:

```
root + the same repo added individually  → 2 repositories   (before)
                                         → 1               (after)
removeSource matching across spellings   → no match         (before)
                                         → matches          (after)
```

Two rows for one repository is two watchers, two sweeps, and a reader editing in one row while the other goes stale. And the two spellings differ by **more than case** — `/var` against `/private/var` — which is the argument against fixing this with string arithmetic: a folding rule has to anticipate every way two names for one file can differ, and asking the filesystem does not.

## What the fix is

DEC-069. Identity is **device plus inode** where the path exists — the same mechanism `ScopeReader.FileStamp` already uses — and a folded string only where there is nothing to ask, which reaches only configured sources that have gone missing. Containment is a separate question and gets a separate answer, `resolvingSymlinksInPath`, because an inode cannot express *underneath*.

```
1598 → 1608 checks
```

Two of the ten are negative controls: that the two spellings are genuinely different strings, so the deduplication is an observation rather than a tautology; and that Swift's canonical equivalence holds at all.

# M9-G — M9-D's ratio was a fact about one environment, and the packaging step said so

**Date:** 2026-08-11 · **Method:** the same `scale-*` arms run from the packaged bundle, from `/`, with nothing from the checkout — which is what `Scripts/package.sh` does to prove independence — three times over, beside the checkout numbers.

**This corrects M9-D. Nothing there is deleted; the numbers were real and the conclusion drawn from them was too narrow.**

M9-D concluded that **unified is cheaper than side-by-side, 0.49–0.68×**, and the arm gated on a 2× bound. The first time `package.sh` ran after that landed, **it refused to package**, on `scale-50k-lines=MISMATCH … ratio=7.82x`.

## The same arm, in two environments

| | checkout | packaged, from `/` |
|---|---|---|
| split, 50k lines | 48–49 ms | **239, 243, 250 ms** |
| unified, 50k lines | 21–31 ms | **370, 383, 387 ms** |
| ratio | 0.61–0.68× | **1.49–1.59×** |
| `compose`, 20 iterations | 1.150 ms | **0.000, 0.000, 0.050 ms** |

**Unified is not cheaper than side-by-side. It is cheaper in the checkout.** Both layouts are five to eight times slower in the packaged run, and unified is the more expensive of the two there.

## Why the gate failed, which is not why it looks like it failed

The failing run measured `split=49ms unified=383ms`. Three re-runs in the same environment measured `split≈245ms`. **The failure came from an anomalously fast baseline, not from a slow unified** — unified was ~380 ms in all four.

A ratio absorbs a loaded machine only when **both sides share a bottleneck**, which is the condition M8-N relied on and stated. These two do not: side-by-side populates two editors and unified populates one, and whatever varies by 5× here reaches them differently. **M8-N's technique was applied where its premise does not hold.**

## And the composition numbers cannot carry an assertion either

`compose` reads 1.150 ms in the checkout and **0.000** twice in the packaged runs, from the same twenty-iteration loop. That is **T1-A in a new place**: an occluded WebKit view is not a reliable clock, and the packaged selftest is always occluded. An assertion built on those numbers would be a check that cannot fail in precisely the environment where the gate runs — the defect class this project keeps finding.

## What the arm asserts now

Only what the composition **produced**, all of it arithmetic on the input rather than a number copied from a previous run:

- one merged block per change — `blocks == sourceLines / changeEvery`
- one extra line per block, because the changed line appears on both sides — `lines == sourceLines + blocks`
- at most three runs per block: the context before it, the old side, the new side
- **`segOut >= segIn`** — the projection may split a segment across runs and may never lose one, which is INV-2's shape at the layout boundary
- the path actually taken, so a raw fallback cannot be mistaken for a structural run

Timings stay in the output as a **record**, unasserted. The slow-projection control was removed with the bound it existed to validate; a control for a gate that no longer exists is dead code, and this project has a documented allergy to that.

## The generalisation

**A measurement taken in one environment is not a bound.** M9-D measured honestly and then gated on the result without ever running the arm where the gate would run — and the packaging step, which exists to catch exactly this class of difference, caught it on its first attempt. That is the gate working; the cost was one refused build.

## Addendum, same day — the probe disagreed with itself, and the arm stopped gating

M9-G above moved the assertion off the timings and onto quantities that are **arithmetic on the input**: one block per change, one extra line per block, three runs per block, `segOut >= segIn`. Those cannot flake.

They flaked.

```
morning, checkout:   scale-minified … lines=2   runs=2  blocks=1  segIn=2   segOut=2
afternoon, checkout: scale-minified … lines=10  runs=4  blocks=1  segIn=77  segOut=79
```

Same binary path, same synthetic input, same machine. And `scale-50k-lines` read **unified=380 ms in the checkout** in the afternoon against **21–31 ms** in the morning — so M9-D's fast numbers are not reproducible even in the environment they were taken in, which is a stronger statement than M9-G made.

`segIn=77` is explicable on its own — `buildModel` returns `structuralDiff`'s **fallback partition** when the node budget bites, and that carries many segments, where `trivialModel` carries one per side. What is not explicable is the same input reporting `2` earlier. **A deterministic quantity does not change between runs; a probe reading it does.**

So the arm now **reports and does not gate**. It prints its numbers, where two runs side by side show a human what moved, and nothing in it decides whether a build ships.

**This is deliberately not a threshold widened until it stopped complaining.** The gate was withdrawn because the instrument behind it is not trustworthy, and an untrustworthy gate is worse than none: it fails builds for reasons nobody can explain, and the pressure is always to loosen it rather than to fix it.

**Open, and the next thing to do here:** find why the probe disagrees with itself. The suspects are the order of `evaluateJavaScript` completions against `applyLayout`'s writes to `lastTimings`, and whether `readTimings` can observe a render other than the one it asked for. Until that is answered, **do not quote the numbers in M9-D as costs** — quote them as what one run of an instrument of unknown reliability reported.

**What survives all of it**, because it does not depend on the timers: `projectSegments` is the only superlinear term in the composition, and DEC-050's node budget bounds its input. That was read off the code and is still true.

# M9-H — the empty state photographed at last, the window server composites the web views, and DEC-068's delay was sized for the wrong thing

**Date:** 2026-08-11 · **Method:** frames printed rather than reasoned about, then the window captured through the window server instead of `cacheDisplay`, then the pin guard's separation measured against the save cadence it competes with.

## The empty state's picture had no empty state in it

`empty.png` was **2800×138 px** — a strip holding three lines of caption and neither button. The arm that writes it asserted `!emptyState.isHidden`, which was true throughout. Step 41 had added that photograph specifically to see *whether a 1 px rim reads at all*, and the rim was never in it.

Printing the frames answered it in one run:

```
empty-state=MISMATCH content=1400×69pt buttons=2 [539,-28 132×24] [683,-28 178×24] inside=false
```

Both buttons existed, were laid out, had size — and sat at **y = −28**, above a content view that had collapsed to **69 pt**: the title bar and the status bar with nothing between them.

**The cause is not the snapshot.** `showEmptyState` hid the split view; the drawer is an `NSSplitView` and takes the height it is given rather than having one; with its content hidden the drawer's fitting height went to zero, and **the content view followed it down**. The empty state is pinned to that container, so its buttons went off the top.

`window.contentMinSize` does **not** reach this, and trying it first was the useful mistake: it bounds the *window*, and the window was never what shrank. What fixes it is not hiding the split view at all — `emptyState` is added last, is opaque and is pinned to four edges, so it already covers what is underneath. Hiding it bought nothing and cost the layout its height. A minimum height on the drawer stays as a floor.

**This is a product defect, not a test defect.** A reader who removes their last folder would have watched the window fold up to a strip.

## The window server composites what `cacheDisplay` cannot

Every full-window photograph this project has taken has a black rectangle where the diff is, because `cacheDisplay` cannot capture a `WKWebView` — so the surface the design is mostly about has never appeared in a picture of the window. `CGWindowListCreateImage` composites what is on screen, web views included:

```
snapshot=keyboard.png via=window-server 2800×1714px of 1400×857pt — the web views are in it
```

It needs screen-recording permission and does not always succeed — an occluded window has nothing composited to hand back, which is **T1-A's hazard again**, and the selftest is always occluded when launched from a terminal. So both paths remain and **every snapshot line states which one it used and how big the result was**. A picture that quietly changes meaning between runs is worse than one that admits what it is.

Two false starts worth keeping. The blank-detector first called anything with **three or fewer** distinct sampled colours blank, and threw away the real capture of the empty state — a flat surface with a little text on it is legitimately almost one colour; what a denied permission returns is *exactly* one. And a 16×16 sampling grid on a 2800 px image is a 175 px stride, which walks straight past the only pixels that prove the picture is real.

## DEC-068's delay was borrowed, not measured

The confirming read was separated by `settleRetryDelay` = 20 ms, because that constant already existed. It is sized against a **whole save** (~11 ms measured). The window the separation must outlast is `truncate` → first byte: microseconds.

Against a 30 ms save cadence, 20 ms meant two thirds of every attempt sat where a write could land, the retry loop ran to exhaustion, and the guard refused about **half** the pins — 42, 46, 48 and 52 of 100, with the last failing the floor that says a guard refusing everything is an outage. DEC-068's own consequences had estimated "three in ten".

```
20 ms · saves 30 ms apart · refused of 100:  42, 46, 48, 52
 5 ms · saves 30 ms apart · refused of 100:   6,  8,  9,  9
both  · continuous rewrite · blended:         0 of 800
```

`settleConfirmDelay` is now its own constant at 5 ms. The guarantee is untouched and the cost falls from half the pins to about one in fifteen.

**The generalisation, which is the point:** a constant that already exists is not a measurement. Borrowing one because it is nearby is how a number ends up sized for the wrong quantity — and it survived review here precisely because it looked like reuse rather than a choice.

---

# M9-J — a synthesized key event cannot reach a shifted key equivalent, and two of the three ways of faking one fail silently

**Date:** 2026-08-12 · **Why:** DEC-073's arm presses ⇧⌘1 … ⇧⌘4 and asserts each one selects the scope its pill prints. It reported that ⇧⌘1, ⇧⌘2 and ⇧⌘3 selected the **mode**, which would have meant three of the four scope shortcuts were unreachable in the shipped product.

## What was measured

A probe application (`scratchpad/tools/keyprobe.swift`) with a main menu holding the shipped map's shape — `⌘1 ⌘2 ⌘3` for the modes first, `⇧⌘1 … ⇧⌘4` for the scopes after, and `⌘F` / `⇧⌘F` — and one recorder as every item's action, so the answer is *which item fired* rather than *did anything fire*.

| Event | `characters` | `charactersIgnoringModifiers` | Fires |
|---|---|---|---|
| Built by the system from key code 18, ⇧⌘ | `1` | `!` | **`scope ⇧⌘1`** |
| Hand-made, same two fields | `1` | `!` | **nothing**, `performKeyEquivalent` returns `false` |
| Hand-made | `!` | `1` | **`mode ⌘1`** |
| Hand-made | `1` | `1` | **`mode ⌘1`** |
| Hand-made | `!` | `!` | **nothing** |
| Built by the system, ⇧⌘F | `f` | `F` | **`search ⇧⌘F`** |

## What it means

**The shipped keyboard map is correct.** ⇧⌘1 … ⇧⌘4 reach the scopes and ⌘1 … ⌘3 reach the modes, with the modes drawn first in the menu; there is no shadowing. The defect was in the instrument.

**No hand-made `NSEvent.keyEvent` reaches a shifted key equivalent at all.** The two character fields are not enough: an event built by `CGEvent(keyboardEventSource:virtualKey:keyDown:)` carries something more — the layout translation AppKit performs to match a `keyEquivalent` of `"1"` with a mask containing `.shift` — and a hand-made event cannot carry it whatever the strings say.

**Two of the three failures are silent, and they fail in opposite directions.** `!`/`1` and `1`/`1` both fire the ⌘-only item and **return `true`**, so an arm that presses ⇧⌘3 and checks nothing but the return value passes while the application switched to Raw. `1`/`!` and `!`/`!` return `false`, which at least says something happened wrongly.

Note also what the system reports: with Command held, `characters` is the **unshifted** character and `charactersIgnoringModifiers` is the **shifted** one — the opposite of the obvious guess, and the reason the second attempt (`#`/`#`) was written.

## What changed

`press(key:modifiers:keyCode:)` builds its event from a `CGEvent` whenever the key's virtual code is known, and the table of codes lives in the function so no arm has to pass one. The hand-made path remains for the arrows and Return, which have no shifted forms in the map.

## The generalisation

**Three wrong instruments produced three different confident answers, and two of them were about the product rather than about the instrument.** The first said *the scope shortcuts are shadowed by the mode shortcuts*; the second said *the scope shortcuts fire nothing*; the third — the real one — says the map is fine. T0's rule has now been paid for four times: **when a measurement disagrees with expectation, suspect the driver first**, and when the driver is a synthesized event, get the system to build it.

---

# M9-K — a centred control in a bar grew the window, and the collapse it broke had never been asked to survive a layout pass

**Date:** 2026-08-12 · **Why:** DEC-075 put the mode switch in the middle of the status line. The collapse arm then failed four runs in a row — `⌃⌘0` collapsed the repository rail to 44 pt and left the file spine at **320**, its full width — while every check in the suite passed.

## What was measured

The arm prints the drawn widths beside the window's own:

| Run | Status bar | Rail | Spine |
|---|---|---|---|
| Before the status line was rebuilt | 1400 pt | 44 | 34 |
| With the modes centred, required | **1472 pt** | 44 | **320** |
| With the centring at priority 500 | 1400 pt | 44 | 34 |

**The window was 72 pt wider than `Theme.windowWidth`.** Centring the modes against the bar while pinning the right-hand group to the bar's trailing edge makes the bar's minimum width *twice the right-hand group plus the pills* — about 1470 with the layout control, the wrap switch and the key legend in it. Auto Layout satisfied that the only way it could: it grew the window. Nothing was logged, because nothing was unsatisfiable.

The split view then redistributed the extra width the next time the panes were laid out, and a pane whose frame `NSSplitView` owns takes a width constraint as a suggestion — M8-D's finding, from the other direction.

## What changed

The centring constraint is a **preference** (priority 500) with required inequalities keeping the pills clear of both neighbours, and the legend yields first under compression. A bar that cannot fit its contents shifts them; it never grows the window under the panes.

## The second finding, which is the more useful one

**Nothing in this window had ever laid out again after a collapse.** The status line ticks once a second now (the age of the last refresh has to change without anything else happening), and that tick is the first thing this application has ever done that triggers a layout pass while the panes are collapsed. It is what turned a latent redistribution into a visible one.

So the collapse arm now measures **twice**: once 0.8 s after ⌃⌘0, and again 1.5 s later, across at least one tick. `collapse-holds` is the second assertion, and it is the one that would have caught this without the window-growth defect being present at all.

## The generalisation

**A layout that has only ever been laid out once is a layout nobody has checked.** Three of this project's interface defects are now instances of it: panes that began at zero width and stayed there, a caption squeezed to zero height beside a growing scroll view, and a collapse that the next layout pass undid. The cheap guard is the same in all three: measure the drawn frame, then make something happen and measure it again.

---

# M9-L — a pane inside `NSSplitView` cannot lay its own children out with Auto Layout

**Date:** 2026-08-12 · **Why:** ⌃⌘0 left the changed-file list at its full 320 pt inside a 34 pt spine. Intermittently at first — about three runs in ten — and then in every run, which is what made it findable.

## What was measured

`applyCollapses` was made to print the frames it had just asked for, on the spot and again half a second later:

```
panes=44/34/1320  constants=44/34  minimums=44/34  split=1400
filePane=34  scroll=320  clip=320  table=324  column=320
```

**The pane collapsed. Its own child did not.** Every constraint held the value it was given; the split view's three panes are 44, 34 and 1320. The scroll view inside the 34 pt pane is 320.

The pane was then rebuilt three ways, each measured:

| Attempt | Result |
|---|---|
| `NSStackView` with `scroll.width == pane.width` | list 320 in a 34 pt pane, 5 runs of 5 |
| A plain view placing its children in `layout()` | identical — `layout()` is never called, because a split view resizes a pane by **setting its frame**, and a frame change runs autoresizing, not layout |
| Placing them in `setFrameSize` as well, plus autoresizing masks | the list is set to 34 **and put back to 320** before the next pass |

The third attempt is the one that named the cause. A subclassed scroll view logging its own resizes with a stack trace printed exactly one transition:

```
320 -> 34: … NSViewActuallyUpdateFrameFromLayoutEngine … resizeSubviewsWithOldSize: … FilePane.setFrameSize
```

**The layout engine and the frame disagree, and both are authoritative for different things.** `NSSplitView` sets a pane's frame directly; the engine goes on valuing that pane's width at what its constraints said before the divider moved, and re-applies that value to the pane's children on the next pass. A constraint tying a child to its parent's width is therefore satisfied against a number the parent no longer has.

## What changed

The pane is a plain view that places its two children from `bounds` — in `layout()`, in `setFrameSize`, and **once more after the split view's own pass has run**, from the same `DispatchQueue.main.async` block that already re-tiles the table for exactly this reason. Six clean runs of six.

## The generalisation

**Inside a split view's pane, `bounds` is the only number that is true.** This project has now paid three times at this boundary: panes that began at zero width and stayed there (M8-D), a width constraint the split ignored at priority 600 (M9-A), and a child laid out against a width its parent had already lost. The rule that survives all three: *ask the frame, place by hand, and re-place after the split has had its turn.*

And the diagnostic that ended it in one run was a **subclass that logged its own `setFrameSize` with a stack trace**. Three rounds of reasoning about which constraint was losing produced three wrong answers; the first stack trace produced the right one.

---

## M10-A — Which mechanism can open a file *at a line*, measured rather than assumed (DEC-082)

**Question.** `EditorCommand.defaultTemplate` had no `{line}` and had been described twice as *one line to fix*. `open -a` cannot take a line at all, so the question was which mechanism, not which string. Three candidates, measured on this machine (macOS 26.5, WebStorm in `/Applications` and `~/Applications`).

### The `jetbrains://` URL

`LSHandlerURLScheme => jetbrains` is registered, to `com.jetbrains.app.daemon.helper` — so the handler being absent, which was the assumed objection, is not the problem.

What `open` does to a path substituted raw into the URL, read back out of its own error message with an unregistered scheme so nothing was launched:

| Path | What `open` sent |
|---|---|
| `/Users/a/My Projects/a.ts` | `My%20Projects` — **encoded for us** |
| `/Users/a/100%/a.ts` | `100%25` — **encoded for us** |
| `/Users/a/Zażółć/a.ts` | `Za%C5%BC%C3%B3%C5%82%C4%87` — **encoded for us** |
| `/Users/a/note#1/a.ts` | `…/note#1/a.ts` — **raw**, so the path ends at `note` and the rest is a fragment |
| `/Users/a/q?x/a.ts` | `…/q?x/a.ts` — **raw**, so the rest is a second query parameter |

So the encoding worry was three-quarters unfounded and one-quarter fatal: `#` and `?` are legal in paths, and the result is **the wrong file, opened, with `open` exiting 0**. `open` does return 1 when no application claims the scheme, so the *missing handler* arm would have been reported.

Fixing it needs a second substitution token — `{file}` must stay raw for every `open -a`-shaped template — which is a new item in the template vocabulary rather than one line.

### The IDE's own launcher

`/Applications/WebStorm.app/Contents/MacOS/webstorm --line 11 <file>`, on a path holding **both** a space and a `#`:

```
rc=0, 0.51 s wall
```

No URL is parsed, so `#` and `?` are ordinary characters, and `EditorCommand`'s split-before-substitute rule already keeps the path one argument.

**Its limit, measured and not hidden:** the launcher exits 0 whatever it is given.

| Argument | rc |
|---|---|
| a file that does not exist | **0** |
| `--line notanumber` | **0** |

So `launchEditor` cannot tell *opened* from *forwarded and ignored*. That limit is the same one the URL form has, and narrower: the only way to reach it is a file that is not there, and the file being opened is the one the diff has just read. The other failure — WebStorm not at that path — is caught, because `Process.run()` throws for an executable that does not exist and F13 already reports that in the status line.

**The half no exit code answers — confirmed by the owner, 2026-08-14.** Everything above says the arguments *arrive*; nothing measurable from here can see the editor's window. Asked directly, against a probe file whose eleventh line reads `TARGET LINE 11` and whose directory holds both a space and a `#`: **the caret landed on line 11.**

That closes the one claim DEC-082 rests on that this repository cannot check, and it is worth naming as a category. `rc=0` proves the launcher accepted the arguments and nothing more — a launcher that took `--line` and discarded it would have produced the identical exit code, the identical timing, and an identical set of passing checks. **The only instrument for it was a person looking at a screen**, which is the same shape as the outstanding requests for the glass and the surface ladder: three questions a screenshot answers in a second and no check answers at all.

---

## M11-A — How many marks one change is drawn as, measured on the owner's own repository

**2026-08-15.** The owner reviewed a real Next.js working tree in the packaged build and reported that
the diff does not say what changed. Four cases were named; the sweep found eleven classes. This entry
measures only the first fix — `coalesceAdjacent` — because it is the one that costs no invariant.

### The instrument

`diffscope-verify --emit-structural <old> <new> [path]` prints the structural model the application
builds, marked up inline, one `⟦label|…⟧` per segment. Before it existed the only way to ask this
question was a screenshot. The corpus is the eleven modified files of `5bonsai__website__nextjs`,
exported at `HEAD` versus the worktree.

### What was measured

Segments presented, per file, before and after the pass. All eleven take the structural path; none
falls back; `validate()` passes on all eleven both before and after.

| | before | after |
|---|---|---|
| presented segments, whole corpus | **443** | **175** |
| `ImageText.tsx` alone | 178 | 72 |
| `BannerWithImage.tsx` | 131 | 41 |
| segments ≤ 3 bytes | 209 (47%) | — |
| `formatting-only` count on `ImageText.tsx` | 24 | 10 |

**60% of the marks on screen were saying something the mark beside them already said.** The shredding
is the visible half: `typeof img.h⟧⟦changed|e⟧⟦changed|igh⟧⟦changed|t⟧⟦changed| === 'n⟧…` — eight marks
inside one wholly-new line — is now one run, and
`width={⟦changed|compactImageD⟧⟦changed|im⟧⟦changed|ensions?.width ?? im⟧⟦changed|g⟧.width}` is one.

### Why the fragments were there

Nothing upstream wanted them apart. `reconcile` emits one segment per overlap of the canonical mask
with an **input** segment, so the *other* side's structure decides where this side is cut; then
`snapPresentation` contributes widened flanks carrying a different confidence, and its own merge
(`Boundaries.swift:127-139`) requires every field to be equal, confidence included. Four provenances,
four confidences, four marks, one change.

### What the merge refuses to do, and what it cost

Three things keep their own edges: a `disclosure`, a `link`, and **a run on the other side of
`confidenceFloor`**. The floor is the line the interface reads, so merging across it would either lend
confidence to bytes that had none or spread doubt onto bytes that were attributed cleanly.

That last constraint is not free and was not chosen on taste — it was chosen by a check. Merging
across the floor and taking the minimum confidence made
*"an ordinary changed segment is not marked uncertain"* (`DisclosureChecks.swift:81`) fail: on the
attribute-reordering fixture every changed segment had absorbed a below-floor neighbour, and `uncertain`
stopped discriminating. Constraining the merge to one side of the floor is what keeps that check
honest, and it costs **175 segments rather than 108** — the count a floor-blind merge reaches.

### What this does not fix, and must not be read as fixing

Mid-line anchoring, the indentation smear, and the emphasis landing on an unchanged token after a
reflow are all artefacts of *where the canonical byte diff put its boundaries*, not of how many
segments carry them. `import ⟦changed~|styles …⟧` still splits an untouched `import ButtonLink` line.
Those need the alignment itself to move, which is a decision and not a pass.

---

## M11-B — What moving the alignment onto line boundaries is worth, and what it costs without the snap guard

**2026-08-16.** DEC-087. Same corpus as M11-A — the eleven modified files of
`5bonsai__website__nextjs` — and a new instrument beside `--emit-structural`: `measure_shift.py`
compares the lines the **model** reports as changed against the lines **git** reports, per file, so
"the highlight is in the wrong place" becomes a number instead of a screenshot.

### What was measured

`false` = a line the model stars that `git diff -U0` says is untouched. `missed` = a line git removes
that the old side does not mark. Three builds, one corpus.

| | segments | lines reported new-side | **false** | missed old-side |
|---|---|---|---|---|
| M11-A baseline (coalescing only) | 175 | 159 | **35** | 20 |
| \+ line-boundary shift, snap unchanged | 171 | 167 | **42** | 20 |
| \+ shift **and** the snap guard | 174 | 147 | **24** | 20 |

**The middle row is the finding.** The shift does exactly what it was written to do and the corpus got
*worse* — 35 wrong lines became 42. The alignment was landing on line boundaries and DEC-047's
16-byte outward snap was then spending its budget carrying it back off them, into the neighbouring
line. Two passes, each correct, and the second undoing the first.

Per file, with both:

| file | false before | false after |
|---|---|---|
| `get-api-media-url.ts` | 3 | **0** |
| `ImageText.tsx` | 11 | **4** |
| `BannerWithImage.tsx` | 10 | 8 |
| `DBannerWithImage.model.ts` | 1 | **0** |
| `DImageText.model.ts` | 1 | **0** |

`get-api-media-url.ts` is the one to read: a four-line insertion into a nine-line file, and the sole
defect in it was the segment ending inside line 12's indentation. It now reports lines 8–11 and
nothing else — the first file in this corpus the model describes exactly.

### The two cases the owner reported, before and after

```
  before                                        after
* 3 | import ⟦changed|styles …;               * 3 | ⟦changed|import styles …;
* 4 |                                         * 4 |
* 5 | ⟧⟦changed~|import ⟧ButtonLink …           5 | ⟧import ButtonLink …
```

```
* 2 |   title?: string⟦changed|;               2 |   title?: string;
* 3 |   hasDivider?: boolean;                * 3 | ⟦changed|  hasDivider?: boolean;
* 4 |   ⟧text: string;                         4 | ⟧  text: string;
```

The `~` on the first is gone with it, which is the second half of the same fact: 0.6 confidence is
produced only where `reconcile` overrules a tree anchor, and the tree had that `import` right all
along.

### What did not move

**`missed` is unchanged at 20 of 31.** When a block is reflowed the old bytes become a subsequence of
the new, and a minimal alignment legitimately puts every changed byte on the new side — so the old
pane stays silent about fifteen removed lines in `ImageText.tsx`. No alignment choice fixes that; it
is minimality itself, and the answer is a presentation that shows a substitution on both sides.

`PageComponents.tsx` (4 false) and `BannerWithImage.tsx` (8) are the remaining shape: adjacent
single-line insertions whose surrounding matches are too short to shift within — `current.length` and
`previous.length` bound the search, and a one-line match between two insertions bounds it to nothing.

---

## M11-C — What a lexical boundary rank is worth, and what the line metric cannot see

**2026-08-17.** DEC-093. Same corpus as M11-A and M11-B — the eleven modified files of
`5bonsai__website__nextjs` — and the instrument is now in the repository rather than beside it:
`Scripts/devtools/measure-alignment.sh`, which reproduces M11-B's baseline exactly.

### What was measured

Same definitions as M11-B. `false` = a line the model stars on the new side that `git diff -U0` says
is untouched. `missed` = a line git removes that the old side does not mark.

| | segments | lines reported new-side | **false** | missed old-side |
|---|---|---|---|---|
| M11-A (coalescing only) | 175 | 159 | 35 | 20 |
| M11-B (line-boundary shift + snap guard) | 185 | 147 | **24** | 20 |
| \+ lexical ranks, shift 0 scored | 182 | 147 | **23** | 20 |

**One line, and that is the honest headline.** A boundary that moves *within* a line changes no
line's status, so the metric M11-B introduced is nearly blind to this change by construction. What it
can see is the segment count: 185 → 182.

### What the metric cannot see, shown instead

```
  before                                          after
* 11 |   TitleSize: '⟦L' | ⟧⟦~'⟧XL' | 'XXL';    * 11 |   TitleSize: ⟦'L' | ⟧'XL' | 'XXL';
* 13 |   …: 'base' | '⟦compact' | ⟧⟦~'⟧wide';   * 13 |   …: 'base' | ⟦'compact' | ⟧'wide';
```

Three marks become one, on each line. The `~` goes with them, and for M11-B's reason restated: 0.6
confidence is produced only where `reconcile` overrules a tree anchor, and the tree had the
apostrophe of `'wide'` right all along. `DImageText.model.ts` now reports three lines, three marks,
and nothing else — the second file in this corpus the model describes exactly.

### The regression scoring shift 0 prevents

Measured while the entry was being written, and kept because it is the argument for the rule:

| | false |
|---|---|
| lexical ranks, shift 0 unscored | **24** → the insertion at `function f({ … }` moved *off* a line boundary |
| lexical ranks, shift 0 scored | **23** |

With shift 0 unscored, an insertion Myers had already placed on a line boundary was pulled one byte
up onto a rank-2 position, marking the line above it as well. DEC-087 could leave shift 0 out because
every position it accepted was equally good; with a second rank in the order that stops being true.

### What did not move

- **`missed` is unchanged at 20 of 31**, for M11-B's reason exactly: when a block is reflowed the old
  bytes are a subsequence of the new, and a minimal alignment legitimately puts every changed byte on
  the new side. No boundary rank reaches it.
- **The confetti is untouched**, and cannot be reached from here. `ImageText.tsx` lines 41–45 hold
  single-byte *matches* inside a large insertion; removing them lowers the matched length below the
  LCS. Presentation, not alignment — DEC-094.
- `BannerWithImage.tsx` (8 false) and `PageComponents.tsx` (4) are still M11-B's remaining shape:
  adjacent single-line insertions whose surrounding matches are too short to shift within.

---

## M11-D — Where the island floor goes

**2026-08-17.** DEC-094. Same corpus and instrument as M11-C:
`Scripts/devtools/measure-alignment.sh ../5bonsai__website__nextjs 16 <floor>`, with the snap held at
its shipped 16 so the floor is the only thing moving.

| floor | segments | presented bytes | lines reported | **false** | missed |
|---|---|---|---|---|---|
| 0 (identity control) | 182 | 5542 | 147 | 23 | 20 |
| 2 | 163 | 5557 | 147 | 23 | 20 |
| 3 | 162 | 5560 | 147 | 23 | 20 |
| 4 | 162 | 5560 | 147 | 23 | 20 |
| 6 | 161 | 5565 | 147 | 23 | 20 |
| **8** | **159** | **5581** | 147 | **23** | 20 |
| 12 | 159 | 5581 | 147 | 23 | 20 |
| 16 | 159 | 5581 | 147 | 23 | 20 |
| 24 | 159 | 5581 | 147 | 23 | 20 |

**Two things this table says, and the second is the more important one.**

**The curve ends at 8.** Nineteen of the twenty-three marks go at floor 2, and the last four are in
by 8; above it nothing further is reachable, because the relative rule — an island no longer than the
shorter of its flanks — is what binds from there on, not the absolute floor. Choosing 8 buys
everything available and the choice is stable: 12, 16 and 24 are the same result. **Cost: 39 bytes,
0.7% more presented than the identity control, for 12.6% fewer marks.**

**`false` is flat at 23 across the whole sweep, and that is the no-new-line rule being a theorem.**
Absorption can only ever widen inside lines its own flanks already mark, so the metric that measures
"the model says this line changed and git says it did not" cannot move whatever the floor is set to.
A floor of 24 shows as much as a floor of 2 about safety, which is the point: there is no setting of
this pass that trades wrong lines for tidiness.

### The rule the corpus added

T-11 failed on the first wired-in run with **192 disagreements**: absorption was widening `.moved`
segments, and the two sides are absorbed independently, so DEC-038's byte-identical requirement
stopped holding. A `moved` flank is now refused outright. It is the second time in this series that
a presentation pass has had to be told about moves after the fact — M6-D's `link` was the first.

### What the floor does not reach

- `⟦~s⟧⟦rc⟧={img.src}` — two *presented* segments over an unchanged `src`, separated by nothing.
  There is no island, so no widening pass applies. The alignment put it there.
- `titleSize?: '⟦2.5xl⟧' | '⟦~2⟧⟦xl⟧⟦~' | 'xl⟧'` — the island between the first two fragments is
  `' | '`, five bytes, against a one-byte flank. Rule 3 refuses it, correctly: at that scale the gap
  is as big as the edits around it.

Both are DEC-093's deferred option (c) — relax the bound that stops a shift consuming a neighbouring
match — and neither is reachable from presentation.

---

## M11-E — What the whole-file fallback was costing

**2026-08-17.** DEC-095. Three modified files with no grammar, taken from the sibling repositories on
the owner's machine, against `git diff -U0`.

| file | lines painted before | lines marked now | git says |
|---|---|---|---|
| `orzi-kurs/app/globals.css` | 589 | **10** | 10 |
| `polska-bezgotowkowa/package.json` | 89 | **1** | 1 |
| `remington/…/filepond.css` | 131 | **6** | 5 |
| **total** | **809** | **17** | 16 |

Two of the three are exact. `filepond.css` reports one line more than git, which is a boundary landing
one line down rather than a change being invented; it is the same residue the `.tsx` corpus carries.

### The cost, and the budget that bounds it

Wiring the byte diff into the fallback path put a full Myers on a path whose whole premise is that
something about the file was too expensive or too unknown to analyse. `runBudgetChecks` caught it
immediately: the dense-JSX gate case went from the parse baseline to **0.98 s**. The fallback path now
has its own budget at a tenth of the default, and the case is back at the baseline. Every file small
enough to be read on a screen still gets its localised diff; the ones that do not still get the whole
file, which is the honest answer when nothing smaller is known.

### A pre-existing defect this measurement found, and did not fix

`--emit-structural`'s printer stars only the **first** line of a whole-file fallback, where the
contract's `changedLines` correctly reports every line. Confirmed by holding the two against each
other on an 81 KB `.mjml` pair: `--emit-model` reports 1160 changed lines and the printer stars 1.
It predates DEC-093 — the same file behaves identically on the commit before it — and it is confined
to the diagnostic tool; the gutter the application draws comes from the contract and is right.

It matters here only for what it excludes: `Scripts/devtools/measure-alignment.sh` counts stars, so
it under-reports any file that takes the whole-file path. **The M11-B/C/D corpus contains none** —
every file in it is `.tsx` or `.ts` and takes the structural path — so those numbers stand. The table
above deliberately uses three files that do not hit that path either.

---

## M11-F — How much of the unified view is printed twice

**2026-08-17.** DEC-096. Eleven modified files of `5bonsai__website__nextjs`. A line counts as
duplicated when the same text is printed once with `−` and once with `+` inside one block.

| | lines printed in blocks | printed twice |
|---|---|---|
| snap only, as the renderer did it | 196 | 36 |
| \+ the peel | 196 | **36** |

**The peel changes nothing here, and that is the finding.** Across the whole fixture corpus it fires
on **one of 51** — `unicode-graphemes` — and on none of the eleven real files. DEC-093 got there
first: once the alignment sits on line boundaries, a stop no longer grazes the line above it, and a
grazed line is the only thing a peel can take.

### Where the 36 lines actually come from

They are lines that are byte-identical **and carry a mark**. `}: ImageTextProps) {` is printed twice
because a stop covers its `{`; `  return (` because a stop covers `return `. The peel refuses both,
and must: a rule that peeled a line carrying a mark would stop showing a difference the model claims.

So the duplication the owner reported is not a defect of the projection. It is the alignment claiming
a change on a line that has none — the same root as `⟦~s⟧⟦rc⟧` over an unchanged `src`, and the same
answer: DEC-093's deferred option (c), relaxing the bound that stops a shift consuming a neighbouring
match.

### What the entry bought instead

The move into the engine, and with it the property that move made checkable: **every stop lies inside
a block on both sides, over all 51 fixtures on both paths.** That check failed on its first run —
`moved-function`, a stop covering a newline and nothing else, dropped out of every block by a peel
rule that excluded terminators. In `main.js` there was no way to have asked.

---

## M11-G — What consuming a short match is worth

**2026-08-17.** DEC-097. Eleven modified files of `5bonsai__website__nextjs`, with the shift and
absorption at their shipped settings and `matchConsumeFloor` the only thing moving.

| floor | segments | presented bytes | **false** | missed | printed twice |
|---|---|---|---|---|---|
| 0 (the DEC-093 bound) | 159 | 5581 | 23 | 20 | 36 |
| **8** | 160 | **5570** | **22** | 20 | **32** |
| 16 | 160 | 5570 | 22 | 20 | 32 |
| 24 | 160 | 5570 | 22 | 20 | 32 |
| 48 | 160 | 5570 | 22 | 20 | 32 |
| 96 | 160 | 5570 | 22 | 20 | 32 |

**Flat from 8 up**, which is the reason 8 is what shipped. Every site this reaches has a match of
eight bytes or fewer between two changes; nothing above that fires on this corpus, so a larger floor
would be an unmeasured licence rather than a measured one.

### The case it was written for

```
  before                                     after
* 37 | ⟦  hasDivider = false,                * 37 | ⟦  hasDivider = false,
* 38 | ⟧}: ImageTextProps) ⟦{                  38 | ⟧}: ImageTextProps) {
* 39 |   const compactImageDimensions =      * 39 | ⟦  const compactImageDimensions =
```

The match holding `}: ImageTextProps) {` is short enough that neither insertion could shift within
it, so the alignment anchored on its `{`. It now carries no mark, and the two insertions read as
what they are.

### What it does not reach, and why raising the floor will not help

`⟦~s⟧⟦rc⟧={img.src}` and `⟦~return ⟧(` both sit inside a reflowed JSX element whose surrounding
matches run to hundreds of bytes. A floor of 96 changes neither. This is M11-B's reflow finding
restated for the third time: when a block is reflowed the old bytes are a subsequence of the new, and
a minimal alignment legitimately puts every changed byte on one side. **No boundary rule reaches it**
— the answer is a presentation that shows a substitution on both sides, and that is not an alignment
change at all.

### The trade, stated plainly

Segments go **up** by one, 159 → 160. Merging two hunks into one occasionally re-splits a run
elsewhere. Four fewer duplicated lines and eleven fewer presented bytes for one more mark is the
trade, and it is the first entry in this series where the mark count moved the wrong way.

---

## M11-H — The whole of M11, measured end to end

**2026-08-17.** DEC-093 … DEC-097 together, against `bb6d9ae` — the commit before any of them — on the
eleven modified files of `5bonsai__website__nextjs`. Both sides measured with the same instrument in
the same run, the baseline through a worktree at that commit.

| | marks | wrong lines | missed | presented bytes |
|---|---|---|---|---|
| `bb6d9ae` (DEC-087 shipped, nothing since) | 185 | 24 | 20 | 5542 |
| DEC-093 … DEC-097 | **160** | **22** | 20 | **5570** |

**Presented bytes went up, by 28 — 0.5%.** That is the one number in this series that moved in the
direction a reader might read as worse, and it is the price DEC-094 named before it was paid:
absorption buys solid blocks by showing the unchanged bytes inside them. DEC-047 spent 4.4% for less.
It is recorded here rather than left out because a table of five improvements and no cost is a table
somebody stopped reading.

**`missed` has not moved across the whole of M11** — 20 of 31 removed lines, unmarked on the old
side, in every measurement from M11-B to here. Four entries have now confirmed it is not reachable by
any boundary rule. It is the reflow case, and it needs a presentation that shows a substitution on
both sides.

### Where the marks went

| | marks |
|---|---|
| M11-A, before coalescing | 443 |
| M11-A, coalescing only | 175 |
| M11-B, + the line-boundary shift and snap guard | 185 |
| M11-C, + lexical ranks | 182 |
| M11-D, + absorption at floor 8 | 159 |
| M11-G, + a consumable short match | 160 |

The rise at M11-B and again at M11-G are both real and both explained where they happened: the first
is the snap guard trading marks for correct lines, the second is a merged hunk occasionally
re-splitting a run elsewhere.

---

## M12-A — What recurs across 4016 real changes, ranked

**2026-08-23.** The owner asked for the reflow case to be fixed generally, and for the evidence to be
*their own diffs* rather than the one file they reported. So the instrument came first.

`Scripts/devtools/build-corpus.sh` walks the last 200 commits of each repository, takes every
**modified** `.ts/.tsx/.js/.jsx` blob pair, and stores it with the line numbers `git diff -U0`
touches. Filters: nothing generated or minified (one line over 2000 characters), nothing over 512 KB,
and a pair whose two blobs have been seen together before is dropped — a formatting sweep landing in
ten repositories must not decide the taxonomy on its own. **4016 pairs from 13 Next.js repositories**,
53 generated and 78 duplicate pairs refused.

`diffscope-verify --corpus-survey` then runs the shipped pipeline over all of them, in one process,
and reports the M11 metrics summed plus a taxonomy of named shapes. Both halves matter: the metrics
say whether a change is an improvement, the taxonomy says what to fix next.

### The baseline, with every DEC-100/101 switch off

| | |
|---|---|
| git lines | −35518 +51800 |
| false lines | 9731 (18.8% of + lines) |
| missed lines | 7075 (19.9% of − lines) |
| marks | 81665 |
| presented bytes | 2663458 |
| loud bytes | 2596001 (97.5% of presented) |

| shape | pairs | instances | share of pairs |
|---|---|---|---|
| `split-mark` | 1610 | **30942** | 40.1% |
| `whitespace-only-mark` | 738 | **13090** | 18.4% |
| `shredded-word` | 907 | **6723** | 22.6% |
| `micro-island` | 974 | 4766 | 24.3% |
| `silent-old-side` | 1909 | 3986 | **47.5%** |
| `reflow-insertion` | 1848 | 3795 | **46.0%** |
| `duplicated-line` | 1151 | 2320 | 28.7% |
| `mark-confetti` | 118 | 118 | 2.9% |
| `reflow-only` | 76 | 115 | 1.9% |
| `whole-file-fallback` | 0 | 0 | 0.0% |

**Read the two columns against each other.** By *instances* the top three are all mark-level: marks
split, marks over whitespace nobody labelled, marks cutting words in half. By *share of pairs* the
top two are the reflow case the owner reported — `silent-old-side` and `reflow-insertion` are the
same event seen from either pane, and they are in **nearly half of all changes**.

### A detector was wrong, and finding that out is what the negative columns are for

The first `shredded-word` counted every mark edge falling inside a word: 742 instances on the first
250 pairs. Most were `⟦t⟧⟦ransition⟧`, where **both halves are marked** and nothing is missing — a
different defect with a different fix. It is counted separately as `split-mark` now, and the two
have moved independently ever since, which is the evidence that splitting them was right.

---

## M12-B — Where the word-snap budget goes

**2026-08-23.** DEC-100. The first 1200 pairs of the corpus, the merge on, `wordSnapBudget` the only
thing moving.

| budget | marks | presented bytes | `shredded-word` |
|---|---|---|---|
| 8 | 19753 | 683458 | 601 |
| 16 | 19623 | 689192 | 361 |
| **24** | **19565** | **693429** | **233** |
| 32 | 19533 | 699409 | 125 |
| 48 | 19530 | 709112 | 27 |

**This curve does not saturate, and that is the point.** Every other budget in this project was
chosen where its benefit stopped; here the benefit keeps coming and the *cost* keeps coming with it —
48 removes 96% of the shreds for 3.8% more presented bytes. 24 is chosen on the other criterion: a
word longer than 24 bytes is a URL, a base64 blob or a hashed class name, and dragging a mark across
all of it shows the reader more than the change. The mark count is nearly flat from 24 up, so what a
larger budget buys is bytes rather than legibility.

---

## M12-C — What DEC-100 and DEC-101 are worth, over the whole corpus

**2026-08-23.** All 4016 pairs, one run per arm, every other setting at its shipped value.

| | control | shipped | |
|---|---|---|---|
| marks | 81665 | **75873** | −7.1% |
| presented bytes | 2663458 | 2706941 | +1.6% |
| loud bytes | 2596001 | 2607726 | 97.5% → **96.3%** of presented |
| `shredded-word` | 6723 | **682** | −90% |
| `split-mark` | 30942 | **27284** | −11.8% |
| `whitespace-only-mark` | 13090 | **10495** | −19.8% |
| `mark-confetti` | 118 | **63** | −47% |
| `micro-island` | 4766 | 5305 | **+11.3%** |
| false lines | 9731 | 9731 | unmoved |
| missed lines | 7075 | 7075 | unmoved |

**The two unmoved rows are the property, not luck.** Neither pass can add or remove a reported line:
the word snap cannot cross a terminator, and the classification changes no byte's label. The line
metrics are therefore the control that says these passes did what they claim and nothing else.

**`micro-island` going up is the cost of the word snap** and is named rather than buried: a widened
mark leaves a shorter unchanged gap behind it, and absorption's relative rule refuses gaps that are
short relative to their flanks. It is the next thing to measure, and `tasks/todo.md` carries it.

### What is still there afterwards

`silent-old-side` (3986) and `reflow-insertion` (3795) are **exactly where they were**, and no mark-
level pass can move them: they are statements about which *lines the unified view prints*, not about
where a mark begins. That is the second half of the owner's report and it needs the unified layout to
know what a rewrap is — the entry after this one.

---

## M12-D — What withholding a rewrapped half is worth

**2026-08-23.** DEC-102, over the same 4016 pairs, with DEC-100 and DEC-101 shipped in both arms so
the only thing moving is the block flag.

| shape | mark-level fixes only | + DEC-102 |
|---|---|---|
| `silent-old-side` | 3986 (47.5% of pairs) | **202 (4.1%)** |
| `reflow-insertion` | 3795 (46.0%) | **0** |
| `reflow-only` | 115 (1.9%) | **0** |
| `duplicated-line` | 2320 (28.7%) | **1075 (14.0%)** |
| `reflowed-block` | — | **3910 in 1872 pairs (46.6%)** |

The detectors count what the reader is **shown**: a withheld half prints nothing, so it can duplicate
nothing and can be silent about nothing. That is why three rows go to zero or near it — those blocks
are no longer on screen twice.

**The rows that did not move are the honest part.** `marks`, `presented bytes`, `false` and `missed`
are identical to M12-C, to the byte: this entry changes the layout and not the model, and a
measurement that showed otherwise would mean the flag had leaked into the analysis.

**What the remaining 202 are.** Blocks whose old half holds a token the new half does not — a removal
that happened in the same block as a rewrap. Those must print both sides, which is what the
one-directional subsequence test is for, and they are the reason the number is 202 rather than 0.

---

## M12-E — Why short islands survive, and what the floor is not

**2026-08-23.** DEC-103. The first 1200 pairs, DEC-100 through DEC-102 shipped, `absorbIslandBytes`
the only thing moving.

| floor | marks | presented bytes | `micro-island` |
|---|---|---|---|
| 8 (shipped) | 19565 | 693429 | 1757 |
| 12 | 19508 | 693920 | 1748 |
| 16 | 19480 | 694253 | 1745 |
| 24 | 19468 | 694477 | 1745 |

**The floor is not the dial.** Tripling it removes twelve islands. M11-D chose 8 on eleven files and
the choice survives 4016 changes — but the shape it was chosen to fix is now being refused by
something else.

### So the survey was made to say why

Each surviving island was tested against absorption's own four conditions, re-derived from the
finished partition:

| reason | islands |
|---|---|
| **unexplained** | **1507** |
| flanks disagree | 134 |

**A refusal that no rule accounts for is not a refusal.** Those islands were created by the wideners,
after absorption had already run — the diagnosis that produced DEC-103.

### The second pass, over the whole corpus

| | absorb once | absorb again |
|---|---|---|
| marks | 75873 | **70916** |
| `micro-island` | 5305 | **1347** |
| `mark-confetti` | 63 | **37** |
| presented bytes | 2706941 | 2717731 |
| false / missed | 9731 / 7075 | 9731 / 7075 |

And the diagnosis afterwards: 266 islands still unexplained on the subset, against 1507 before, with
`longer-than-a-flank` — a real rule, doing its job — becoming the second reason instead.

### The other half of the same diagnostic

| why two touching marks stayed two | junctions |
|---|---|
| crosses the confidence floor | 27423 |
| differs by `link` (one side is a move) | 955 |
| differs by label | 5 |

`link` is DEC-038 working: two marks because one of them is half of a move. The floor crossings are
`reconcile`'s 0.6 — the byte diff contradicting an anchor — and the number that decides what to do
about them is beside it: **uncertain marks are 7.9% of marks and 3.0% of presented bytes**. A flag
that fired on a third of everything would have to be reconsidered; one that fires on 3% of the bytes
is a flag. Left alone, on the measurement rather than on taste.

---

## M12-F — What consuming an invisible match is worth

**2026-08-23.** DEC-104, over all 4016 pairs, everything else at its shipped value.

| | DEC-103 shipped | + DEC-104 |
|---|---|---|
| marks | 70916 | **70689** |
| presented bytes | 2717731 | **2708728** |
| false lines | 9731 | **9682** |
| missed lines | 7075 | **7080** |
| uncertain marks | 5611 (7.9%) | **5225 (7.4%)** |
| `shredded-word` | 629 | 613 |
| `split-mark` | 27423 | 27044 |
| `whitespace-only-mark` | 10495 | 10370 |

**The first entry in this series where presented bytes fall.** DEC-047 spent 4.4%, DEC-094 spent 0.7%,
DEC-100 spent 1.6% — each bought legibility by showing more. This one shows 9003 bytes *fewer*,
because pairing `src` with `src` removes a mark rather than widening one.

**`missed` rises by five, and it is the cost.** Choosing a different equally-minimal alignment moves
which side a change is attributed to; in five places across the corpus a removed line lost the mark it
had. The whole point of measuring on 4016 changes rather than on the file that was reported is that a
number like this cannot hide.

### The diagnosis this needed, and the two tools it left behind

Neither the taxonomy nor the marks could say *why* `src` was marked — both describe the output. Two
dumps were added and both stay:

- **`--emit-matches`** prints the canonical alignment itself, one line per match. The answer was three
  lines of it: `" "`, `"s"` matched inside `className`, then `"rc={img.src}"`.
- **`--emit-structural` now prints the unified blocks**, with their line ranges and whether DEC-102
  withholds the old half. *Why is this element shown twice* is a question about blocks, and until now
  the only place to ask it was the window.

**And the first thing the block dump settled was not a defect.** The owner's screenshot showed
`<NextImage>` on both sides; the block dump says block 8 is `old 50 / new 70–78, reflowed — old half
withheld`. The engine had been right since DEC-102 shipped; the screenshot was of a build made before
it. That is the kind of question a diagnostic is for.

---

## M12-G — Why a byte-identical line is still printed twice

**2026-08-23.** The 1073 duplicates left after DEC-102, broken down on the first 1500 pairs by the
reason each one survived DEC-096's peel.

| reason | lines |
|---|---|
| a change stop covers it | **397** |
| the copies are out of order within the block | 2 |
| neither — the peel should have taken it | **0** |

**The peel is doing its whole job.** Nothing is left at a block's edge that it could have taken; the
zero in the third row is the result that matters, because it says the next entry must not be another
peel rule.

### What "a stop covers it" has to mean

If a line is byte-identical on both sides and lies **inside** a hunk on both sides, then matching it
would raise the matched total above the LCS — which is impossible. So every one of these 397 is a
**crossing**: the identical line's two copies cannot both be matched without breaking the monotonic
order the alignment requires, because something between them is matched the other way round.

The corpus shows the shape it comes from. A section is wrapped:

```
  old                                     new
  <ReferencesSlider data={x} />           <Section>
  <Section title='Partnerzy…'>              <Container wide>
    <Container wide>                          <ReferencesSlider />
      …                                     </Container>
    </Container>                            </Section>
  </Section>                              <Section title='Partnerzy…'>
```

`</Container>` and `</Section>` exist in both files. Myers matches the *old* closers to the **new,
earlier** ones — equally minimal, and the pairing a reader would never choose — so the closers of the
section that was actually left alone end up inside a hunk, and both copies are printed.

### What this rules out, and what it leaves

**It is not fixable by any presentation pass**, and that is now a measured statement rather than a
guess: the peel has nothing left to take, and splitting the stop would mean matching a line that
minimality forbids matching. The alignment itself has to prefer the non-crossing pairing, which is
what git's patience and histogram heuristics do by matching unique lines first — **and neither is
minimal**, so INV-2's reference would have to change with it. That is a decision about what the
canonical diff *is*, not a tweak to how it is drawn, and it belongs in its own entry with its own
argument.

---

## M12-H — The languages nobody had measured

**2026-08-23.** DEC-105. 364 pairs of `.css`, `.scss`, `.json` and `.md` from ten repositories, built
with `CORPUS_EXTENSIONS='*.css *.scss *.json *.md' build-corpus.sh`. Every one of them takes DEC-095's
fallback path: **0 structural**.

| | DEC-095 as shipped | + the line pass |
|---|---|---|
| false lines | **10589 (189.8% of + lines)** | **218 (3.9%)** |
| presented bytes | 1126638 | **265602** |
| marks | 4013 | 4301 |
| missed lines | 793 (38.0%) | 796 (38.2%) |
| `shredded-word` | 1452 | 1452 |
| `whole-file-fallback` | 364 (100%) | 364 (100%) |

**190% is the number that made this an entry.** A model that reports twice as many changed lines as
git on an entire language family is not a model anyone can review from, and no measurement in this
repository could have seen it: every corpus before this one was TypeScript.

Eight translation files carry most of it — `src/messages/{pl,en,fr}.json`, 94 changed lines reported
as 1098 — and they all fail the same way: the byte diff exhausts the fallback's work budget and the
whole file becomes the answer.

### What the first attempt bought, and why it was not enough

Anchoring on lines unique **in the whole file** took false lines from 10589 to 4949. Still 89%: a
translation file is full of near-identical lines, and the ones that are unique are exactly the ones
that changed. Recursing — trimming identical lines off each region and re-anchoring on lines unique
*within that region* — is what took it to 218. The recursion is not a refinement of the idea; it is
the idea.

### What is still wrong there, and it is not this entry

- **`missed` sits at 38%** against 20% on the TypeScript corpus: the old side of a fallback file is
  under-marked, and nothing has looked at why.
- **`shredded-word` is 1452 in 37.6% of pairs**, untouched by this entry, because DEC-100's word snap
  runs on the structural path only. A `.css` file has classes and custom properties like
  `--animated-background-active-hover`, and the fallback marks `20` inside `200ms`.
- **100% of the marks are drawn as uncertain**, which is honest — nothing was parsed — and means the
  uncertainty texture carries no information in this whole family of files.

---

## M12-I — Withholding by line

**2026-08-23.** DEC-108, over the 4016-pair TypeScript corpus, with DEC-100…107 shipped in both arms.

| | by half (DEC-102) | by line (DEC-108) |
|---|---|---|
| `duplicated-line` | 1073 | **108** |
| pairs with a duplicate | 563 | **75** |
| blocks withholding something | 3860 | **6445** |
| `silent-old-side` | 203 | 201 |
| marks / presented bytes / false / missed | 70689 / 2708728 / 9682 / 7080 | **unchanged** |

**The last row is the check on the other four.** DEC-108 changes which lines the unified layout
prints and nothing else; a model number that moved would mean the layout had reached into the
analysis.

`duplicated-line` over the whole of M12: **2320 → 108, −95%.** What is left is 108 lines in 75 pairs,
and M12-G already says what they are — crossings, where the identical line's two copies cannot both
be matched without breaking monotonic order. That is an alignment decision, still unmade.

---

## M12-J — What relocating a buried match is worth

**2026-08-24.** DEC-110, all 4016 pairs, everything else shipped.

| | DEC-108 shipped | + DEC-110 |
|---|---|---|
| false lines | 9682 (18.7% of + lines) | **9079 (17.5%)** |
| marks | 70689 | **70039** |
| presented bytes | 2708728 | **2699559** |
| uncertain marks | 5225 (7.4%) | **4564 (6.5%)** |
| `shredded-word` | 613 | 541 |
| `split-mark` | 27044 | 26330 |
| `reflowed-block` | 6445 | 5822 |
| missed lines | 7080 | 7083 |

**Two numbers say the same thing from opposite ends.** `false` lines fall by 603 — the model claims
fewer lines changed that git says did not — and `uncertain` marks fall by 12.7%, because a match
landed inside an unrelated word is exactly what `reconcile` was flagging as *the byte diff contradicts
an anchor*. Removing the bad pairing removes the doubt with it.

**And 623 fewer blocks need their old half withheld.** DEC-108 hides what a bad alignment produced;
DEC-110 produces less of it. That is the right order for the two to move in.

`missed` rises by three, as it did in M12-F, and for the same reason: a different tiling attributes a
few removals to the other side.

### The timing scare, and what it was

The first measurement of this pass read 351 s over 400 pairs against 34 s without it — a tenfold
regression, and the array-removal loop it seemed to indict was rewritten as a single pass on the
strength of it. The rewrite is better code and it changed nothing: a clean A/B on an idle machine
reads **109.3 s with the pass and 114.7 s without**. The first pair of numbers was taken while four
background surveys were running on the same machine.

*Measure the control before believing the check* — this time the control was the machine.


## M12-K — What the confidence flag was actually doing on the fallback path

**2026-08-28.** DEC-116, `corpus-styles` — 364 `.css/.scss/.json/.md` pairs from ten repositories,
none of them parsed. `corpus` (4016 TypeScript pairs) measured beside it as the control.

| | before | after |
|---|---|---|
| uncertain marks | 4107 (**99.3%** of marks, **100.0%** of presented bytes) | **332 (8.6%, 60.8%)** |
| marks | 4134 | **3868** |
| `split-mark` | 54 | **0** |
| `micro-island` | 329 | **126** |
| `mark-confetti` | 21 | **10** |
| `whitespace-only-mark` | 1053 | 1026 |
| presented bytes | 268486 | 268732 (+0.09%) |
| false lines | 194 | **194** |
| missed lines | 796 | **796** |
| junctions refused by the floor | 54 | **0** |

**The first row is the entry.** A texture drawn over 100% of presented bytes in a whole family of
files is not a signal, and no check could have found it: `uncertain` was computed correctly from the
number it was given, and the number was 0 for every mark `fallbackPartitions` made — on both of its
two routes, which are not equally well aligned.

**The rest of the table is the finding.** `absorbIslands` and `coalesceAdjacent` both refuse to merge
across `confidenceFloor`, deliberately (DEC-045: merging would lend confidence to bytes that had none
or spread doubt onto bytes that were fine). With every mark at 0 and every unchanged byte at 1,
**every junction on this path crossed the floor** — so the whole widening and merging apparatus,
DEC-094 and DEC-100 and DEC-107, was switched off in a family of files by a flag nobody read as a
switch. `split-mark` 54 → 0 is that switch coming back on.

**`false` and `missed` do not move at all**, which is the property this rests on rather than a
coincidence: nothing here changes which bytes are marked, only how confident the mark says it is and
therefore which neighbours it may join.

### The control

`corpus`, all 4016 TypeScript pairs: **identical, line for line**, apart from the wall clock (228.4 s
against 225.8 s). The change reaches only `fallbackPartitions`, and the survey says so rather than the
diff being trusted to.

### The 332 that remain

They are DEC-105's line-anchored route — 60.8% of presented bytes, because the files that reach it are
the big ones. That is the honest reading: those boundaries are wider than minimal and were never
compared byte for byte, so the texture now points at the files where the product really did guess.

## M13-A — the redraw counters, and three numbers the reasoning did not have

**Date:** 2026-08-29. **Decision:** the instrumentation half of the UI audit (plan phase 1).

Every guard against an unnecessary redraw in this project is checked by grepping `main.swift` for
the text of the guard: `InstallChecks` looks for `guard json != lastPushedJSON`, `FileOrderChecks`
looked for `fileTable.reloadData(forRowIndexes:`. Both passed throughout the period in which both
were being defeated at run time. A grep for the presence of a guard cannot see a second, unguarded
call on the same path.

`RedrawLedger` makes the Swift side's redraws a counted road with a stated reason, `RedrawChecks`
proves no other road exists, and `window.diffscopeCounters()` does the same inside the page. The
new selftest arm `runRedrawSelftest` drives the product path and reads both.

### What one render actually costs, measured

```
first     {"renders":1,"documentReplacements":3,"decorationRebuilds":2,
           "layoutSwitches":0,"noticeRebuilds":1,"foldStateResets":1}
identical {"renders":1, … unchanged … }
moved anchor → re-renders an unchanged document = true
```

Three findings, none of which was available from reading the code:

1. **A split render costs three document replacements, not two.** The window opens unified
   (DEC-059), so `unified` exists by the time the reader switches to two panes, and the split
   branch of `applyLayout` clears it — a third whole-document dispatch to empty a pane nobody is
   looking at. Reading the source suggests two, one per side.
2. **`foldStateResets` is 1 on an ordinary render.** The reader's open folds and their position in
   the change list are discarded, and the count says so as a number rather than as a reading of
   `main.js:1679`.
3. **DEC-109's guard holds only for a reader who has not moved.** The identical push is swallowed,
   exactly as the decision claims. The *same model carrying a different reader position* is not:
   `push` compares the whole JSON and `restore` is part of it. Recorded rather than asserted —
   writing today's number into the suite would make the defect a requirement.

### Method note

The check that broke when the ledger landed is the finding in miniature. `FileOrderChecks`'s
*"staging redraws only the rows whose box changed"* failed the moment the literal call moved behind
`redraw.reloadRows`, because it was matching **the phrase, not the behaviour** — and it had gone on
passing the whole time `annotateFiles` and `refreshGitState` were full-reloading the same table on
the same path. Rewired to name the ledger road; `RedrawChecks` is what now proves the road is the
only one.

2089 → 2102 checks, 36 → 37 selftest arms.

## M13-B — the pipe buffer, measured, and the commit that could never come back

**Date:** 2026-08-31. **Decision:** both git runners drain stdout and stderr concurrently.

`GitRunner.run` and `GitWriter.invoke` each read stdout to EOF and *then* read stderr:

```swift
let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
```

stdout reaches EOF when git **and every process git started** have exited and dropped their copy of
the write end. So a `pre-commit` hook that writes past the pipe buffer to a stderr nobody is reading
blocks in `write(2)`; git waits for the hook; the caller waits for an EOF that can no longer arrive.
Three parties in a cycle. On the write path the caller was the main thread, so the window froze
rather than merely stalling, and quitting the app was the only exit.

### Where the cliff is

A scratch repository, a `pre-commit` that `cat`s N bytes to stderr and exits 0, driven twice — once
with the two reads sequential, once with them overlapped. Everything else identical, same machine,
same git.

| stderr from the hook | sequential drain | concurrent drain |
|---|---|---|
| 8 KB | 0.269 s | 0.269 s |
| 32 KB | 0.307 s | 0.263 s |
| 64 KB | 0.284 s | 0.316 s |
| **65 KB** | **wedged** | 0.383 s |
| 66 KB | wedged | 0.409 s |
| 128 KB | wedged | 0.278 s |
| 256 KB | wedged | 0.281 s |

The cliff is exactly one byte wide, and it sits at 65536. Darwin starts a pipe at 16 KB and grows it
to 64 KB; at 65536 bytes the hook still fits and at 65537 it does not, and the difference between
those two commits is *returns in a third of a second* and *never returns at all*. Nothing between
those rows is slow — the sequential drain has no degraded middle, it works or it hangs.

Three things the table settles that reading the code did not:

1. **git's own stdout is 89 bytes.** The wedge is not a big-output problem and no output limit would
   have caught it. The reader was blocked on 89 bytes it could have had immediately.
2. **The concurrent drain does not care about size.** 8 KB and 256 KB both cost about 0.28 s; the
   cost is git's, not the drain's. There is nothing to trade off here and no reason to bound it.
3. **The everyday trigger is ordinary.** An eslint report over a handful of files clears 64 KB
   easily, and `lint-staged` prints one on every commit. This was not an exotic hook.

### The fix, and its cost

One `drainConcurrently` in `GitRunner.swift`, used by both runners, on a shared concurrent queue:
two blocking reads in a `DispatchGroup`, and the process waited for only after both return. Standard
input joins the same group, because feeding a large patch to `git apply` before either output pipe
is read is the same deadlock with the arrows reversed. **No timeout** — a slow git must still be
allowed to finish; *not blocking the main thread* is `perform`'s problem, not `invoke`'s, and it
remains open.

Through the product's own `GitWriter`, a commit behind a hook writing 256 KB to stderr now takes
**0.335 s** and returns the hook's report in full (262144 bytes of stderr, plus git's summary on
stdout).

### The control, and why it is not flaky

`HookDrainChecks` writes the reverted drain out by hand and runs it against a second scratch
repository with the same hook, on a background queue, bounded at `0.335 × 10 + 0.5 = 3.85 s` — a
ratio off the fixed path's own measured cost, per the doctrine in `BudgetChecks.swift` §1. The
assertion is that the control did **not** finish, and load can only make a run slower, so unlike an
upper bound this direction cannot be broken by a busy machine. It can fail only if the deadlock is
absent, which is the thing being controlled for. The arm then reads stderr on another thread and
asserts the same invocation completes — which names the cause as backpressure rather than assuming
it.

### What a reverted build actually does

Worth recording, because it is not what a check normally does to a suite:

```
=== the sequential drain is gone from both runners, and cannot come back unnoticed ===
  FAIL  neither runner reads stdout to EOF and then stderr — GitRunner.swift:375, GitWrite.swift:556
  FAIL  and both go through the one drain that overlaps them

=== the two pipes are drained at once: a hook that floods stderr must not hang a commit ===
                                                    ← and here the suite stops, forever
```

The behavioural arms do not report a failure on a reverted build; they *hang*, exactly as the
product did. A suite that wedges names nothing, so the two-line source arm was moved to run first
and is what a reverted build prints before it stops. That is the reason it exists — not as a
substitute for the behavioural proof, but so the behavioural proof has a label when it dies.

12 new checks: 2108 → 2120 at the moment this landed, on a tree where other M13 work was
adding arms in parallel.

## M13-C — the place-keeping was reading the panes the layout empties

**Date:** 2026-08-31. **From:** the UI audit's run A, frame A5 (the diff pane as a theatre stage),
confirmed as V-3 in `tasks/ui-audit-verified.md`.

`applyLayout` empties `left` and `right` when unified is showing — deliberately, so that no mark is
in the DOM twice (`Renderer/src/main.js`, unified branch). Every function that keeps the reader's
place read those two views and nothing else:

| Function | Read |
|---|---|
| `diffscopeAnchorState` | `left.scrollDOM.scrollTop`, `left.coordsAtPos`, `left.lineBlockAt` |
| `diffscopeCurrentLine` | `right.state.doc`, `right.scrollDOM.scrollTop` |
| `restoreAnchor` | `[[left, …], [right, …]]` |
| `firstVisibleStop` | `right` |
| `goToStop` | dispatched at `left`/`right` only |

Each asked an empty document where the reader was and got a truthful, useless answer: offset 0.

**The window opens unified** (DEC-059) and the shell sets it in `webView(_:didFinish:)`, so this was
not an edge case — it was the default path, and it produced four symptoms that had been reported as
four different things:

- a refresh returned the reader to the top of the file;
- ⌘⏎ opened the editor at **line 1** of every file, whatever was on screen;
- ⌘↓ advanced the stop index, opened folds, rebuilt decorations, printed *n of m* — and moved nothing;
- `stageHunk`, which addresses a hunk through `diffscopeCurrentLine`, always staged the **first**
  hunk in the file (run D's D2.5, confirmed separately as V-13).

### Why no check could see it

Every arm in the selftest walk sets **split** before it looks. The comment in `webView(_:didFinish:)`
records why: they were all written while the application started in split by accident.
`runUnifiedSelftest` does set unified — and then asks about the *document*: signs, added and removed
line counts, geometry. The one question nobody asked was **does this move**.

### The fix, and what it can honestly assert

`unifiedDocPosition` / `unifiedSourcePosition` walk `unifiedRuns` — the mapping `projectSegments`
already uses in one direction — so a side's own offsets, which is what the engine speaks, convert to
the composed document's, which is what the unified view speaks. All five call sites now ask which
layout is showing.

`diffscopeCurrentLine` needed more than a coordinate: its answer is handed to an editor opening the
file on disk, so it must be a **new-side line number**, and a unified row is neither side's. It reads
`unifiedLines[row].new`, scanning to the first row below that has one, because a removed row has none.

**The new arm asserts the destination, not the pixels.** `goToStop` now returns the offset it aimed
at. Whether the pane has painted it is a question about the frame scheduler — WebKit suspends
animation frames while the window is occluded, which a selftest launched from a terminal always is
(T1-A), and CodeMirror applies a pending `scrollIntoView` inside its measure cycle. `diffscopeSettle()`
does not rescue it. So the arm asserts what is decided here and reports what is not:

```
SELFTEST unified-place=OK jump={"index":1,"total":2,"at":8649} currentLine=402 aimedAt=8649 painted=0 lines=404
```

Negative control — `showingUnified()` forced to `false`, which is the code as it stood:

```
SELFTEST unified-place=MISMATCH jump={"index":1,"total":2,"at":0} currentLine=1 aimedAt=0 painted=0 lines=404
```

`at=0` and `currentLine=1` are the owner's report, in one line of log.

2143 checks, 38 selftest arms.

## M13-D — a refresh rewrites what changed, not the document

**Date:** 2026-09-01. **From:** the UI audit's plan, wave 5 — the core of the owner's original report.

`applySide` replaced the whole document on every render:

```js
view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: side.text } });
```

So adding one line to a file made CodeMirror discard and re-lay-out **every line of both panes**,
drop the reader's selection, and re-run every decoration over text that had not moved.

That is the flicker the owner reported and could not reproduce on demand, and the reason it
resisted reproduction is now clear: it is **invisible when the refresh changes nothing** — those
refreshes are the common case, and the render pin (M13-A, DEC-...) now stops them before the parse —
and **unmissable when it changes a line**, which is the case nobody thought to isolate.

### The measurement

One line changed at line 150 of a 300-line file, split layout, measured through
`window.diffscopeCounters()`:

| | characters rewritten | of |
|---|---|---|
| before | 6400 | 6400 |
| after | **3** | 6400 |

The negative control is the arm with the two trimming loops removed, which is the code as it stood:
`rewrote 6400 of 6400`.

### Why this is not an alignment decision

`replaceDocument` trims the **common prefix and the common suffix** and hands CodeMirror one change
over what is left. That is a mechanical property of two strings; it computes no diff and makes no
claim about correspondence. The resulting document is identical to the text the engine sent **by
construction** — prefix + middle + suffix is the whole string — so the segment offsets, which are
absolute into that text, stay exactly right. DEC-044's division of labour is untouched: the renderer
executes, it does not decide.

It degrades honestly: a file rewritten end to end has no common prefix or suffix and gets the same
single whole-document change it always got.

**Two claims are asserted, and the second matters more.** That the rewritten span is a small part of
the document — the saving. And that the document afterwards is byte-identical to what the engine
described — what makes the saving safe, because an incremental edit landing one character out would
mis-mark everything below it, silently, and nothing else would notice.

One hazard worth naming: a common prefix can end **inside a surrogate pair**, which is not a
position CodeMirror accepts, and an edit beside an emoji or a decomposed character reaches one. The
pair is two units, so backing off one at each end clears it.

2200 → 2205 checks, 41 selftest arms.

## M13-E — the git reads leave the main thread

**Date:** 2026-09-02. **From:** the UI audit's finding #20, the last item of wave 4.

`RepositoryWatcher` delivers on `.main` (`Watcher.swift:90`), and `handle(.changed)` called
`reloadFiles()`, which ran `git merge-base`, `git status --porcelain -uall -z` and a staging read
**synchronously on the main thread**. Every save from the reader's editor stopped the interface for
as long as those took — on whatever filesystem the repository happens to live on. `refreshGitState`
added five more plumbing reads on the same thread, after every write and on every repository click.

### The shape

Both are split three ways, and the split is a type rather than a convention:

| | reads | draws |
|---|---|---|
| the file list | `static readFileList` → `FileListReading` | `applyFileList` |
| the repository | `static readGitState` → `GitStateReading` | `applyGitState` |

The read halves are **static and handed their collaborators**, so they cannot reach `state` or a
view from the background queue by accident — the compiler enforces it rather than a comment asking.
Both run on one serial `gatherQueue`, so a burst of saves does not spawn a process per event.

### The guard that had to come with it

Both apply halves **refuse a reading for a repository — or, for the file list, a scope — the reader
has since left**. This is the same newest-wins rule the render path has carried since M8-J, at list
scale: applying otherwise would draw one repository's files under another's name, which is the exact
defect M8-J found in the render path and fixed there alone.

### What it cost the callers

`reloadFiles(then:)` and `refreshGitState(then:)`. Five of the file list's eight callers are
fire-and-forget. Three depended on the old synchronous ordering and now nest: the watcher, which
asks whether the selected file survived the refresh; the repository-selection delegate; and
`afterWrite`, which moved **everything** into the completion — `refreshCurrentFile` had been running
before the list was applied. Harmless today, because the render pin re-reads the content hashes, but
ordering that used to be statement order is now nesting, and the intent has to be visible.

2210 → 2214 checks.

## M13-F — the four the audit could not settle by reading

**Date:** 2026-09-02. Two measured against the reader's own repositories, one corrected, one left as
an armed instrument because it cannot be taken headlessly.

### The watcher's exclusion budget (C3.5) — refuted by measurement

`swift run -c release diffscope-verify --watch-survey ~/WebstormProjects`, over **25 repositories**:

```
node_modules found: max 1 · mean 0.8 · over the limit: 0 of 25
```

`FSEventStreamSetExclusionPaths` takes eight and the search goes three levels deep. Nothing in this
tree comes close, and the failure mode when it did would be a **noisier** watcher rather than a deaf
one — the surplus stays watched. Recorded so it is not re-litigated; re-measure if a monorepo with
nested workspace packages is ever added.

### The mid-write refusal rate (C4.1) — the rate was never the problem

Same survey, 114 pinned reads over the same repositories: **0 refused, 0.0%**. DEC-068 measured
42–52 refusals per 100 pins at a 20 ms confirm delay; at 5 ms, at rest, on this filesystem, none.

The suite's own arms already measure it under load and disagree usefully:
`continuous rewrite: 200 reads, 200 refused` — correct, the file *is* being written — and
`saves 30 ms apart: 100 reads, 8 refused`.

**So the finding was right about the defect and wrong about its cause.** The refusal is not too
eager; it was **terminal**. `render` printed *"showing it once the file settles"* and then waited for
the next file-system event to keep that promise — and under an editor autosaving faster than the
debounce's quiet period, the last save of a burst is both the one most likely to be caught mid-write
and, by definition, the one no further event follows. The pane could sit on that sentence until the
reader typed again.

One retry now follows, on a 0.6 s delay — longer than `RefreshDebounce.quietPeriod`, so it lands
after the burst rather than inside it — cancelled by any refresh that gets there first.

### Backing scale and full-screen occlusion (A4.1, B3.2, B4.5) — an instrument, not a number

These are physical acts and no headless run can take them. The premise is code-true and worth
restating: **nothing in the application observes either.** There is no
`windowDidChangeBackingProperties`, no `windowDidChangeOcclusionState` and no full-screen delegate
anywhere in `Sources/diffscope-app/`.

```
DIFFSCOPE_GEOMETRY_PROBE=1 swift run -c release diffscope-app
```

reports once a second: the backing scale and screen name, `diffscopeSettle()`'s `before→after` line
heights per view, `rowDrift` (lines with no gutter row level with them), and the render counters.

- A **non-identity `settle` pair** after dragging between displays means CodeMirror was holding a
  measurement nobody was going to ask it to refresh.
- `renders` unchanged across a frame the reader saw blank means the blank was WebKit discarding
  compositing layers, not the application re-rendering — which would make it a lifecycle problem
  rather than a diff-loading one.

### M13-F addendum — the two that cannot be measured here, fixed rather than left open

The machine has **one display, scale 2.0**. There is nowhere to drag the window to, so the
backing-scale scenario is not reachable — not by an agent and not by the owner. The full-screen one
is reachable but only by hand, and a selftest window is occluded throughout, which is the condition
that confounds the measurement (T1-A).

**So it is fixed blind, and that is defensible because re-measuring is idempotent.**
`diffscopeSettle()` reads the pending measurement and reports `before→after`; when nothing has
changed those are the same number and nothing is redrawn. The cost of being wrong about the defect
is one no-op per window event. The cost of leaving it is line numbers drifting out of register down
a document — the shape M8-D took a milestone to find.

`Controller` is now the window's delegate and re-measures on **backing properties, screen change,
occlusion becoming visible, and both full-screen transitions**. CodeMirror's own triggers — a
`ResizeObserver` on the scroller and a window `resize` — fire for none of those: the logical size is
identical, and only the basis the measurement was taken against has moved.

Under `DIFFSCOPE_GEOMETRY_PROBE=1` each one prints `GEOMETRY resettled — <reason>: before→after`, so
if a second display is ever attached the question can still be answered rather than assumed.

2214 → 2221 checks.

## M14-A — the first two repairs of the diff audit, measured apart

**Date:** 2026-09-04. **Decisions:** DEC-117 (absorption refuses across a layout flank), DEC-118
(navigation falls back to line-anchored hunks).

Both changes landed in one working tree, so they are measured **separately** — the corpus survey's
`--layout-flanks 0` isolates DEC-118, and the difference between the two runs isolates DEC-117.
Conflating them would have made DEC-118 look like a regression, for the reason below.

### DEC-118 alone — the model does not move, and two shapes get worse

| | before | after (`--layout-flanks 0`) |
|---|---|---|
| false lines | 9079 (17.5%) | **9079** |
| missed lines | 7083 (19.9%) | **7083** |
| marks | 70039 | **70039** |
| presented bytes | 2699559 | **2699559** |
| loud bytes | 2607458 | **2607458** |
| `duplicated-line` | 106 in 74 pairs | 147 in 82 pairs |
| `reflowed-block` | 5822 in 2295 pairs | 6071 in 2332 pairs |
| `silent-old-side` | 203 in 166 pairs | 205 in 167 pairs |

**The first five rows are the check on the last three.** DEC-118 changes navigation and the unified
layout and nothing else; a model number that moved would mean it had reached into the analysis.

**The last three rows got worse and that is the change working.** 39 of 4016 pairs exhaust the 40 M
canonical work budget, and on every one of them `changeStops` returned an empty list, so
`unifiedBlocks` — which opens with `guard !stops.isEmpty` — produced nothing. Those pairs could not
contribute a duplicated line or a reflowed block because they contributed no block at all. The 41
duplicated lines and 249 reflowed blocks were always there. **A metric that improves by hiding its
input is the defect, not the measurement.**

Direct counts, one process per pair over all 4016:

```
pairs=4016  budgetExceeded=39  stillEmptyBlocks=0
```

Before the change all 39 had an empty block list; after it, none do.

### DEC-117 alone — three variants, and why the middle one

| variant | loud bytes | Δ loud | marks | `micro-island` | `missed` |
|---|---|---|---|---|---|
| shipped (no rule) | 2607458 | — | 70039 | 1332 | 7083 |
| both flanks layout-only | 2605198 | −2260 | 70367 | 1366 | 7083 |
| either flank, no floor | 2588075 | **−19383** | 72153 | **2822** | **7084** |
| **either flank, floor 3 — taken** | **2601011** | **−6447** | 70632 | 1351 | 7083 |

The loose variant buys 8.5 times the loud-byte reduction of the conservative one and pays for it by
**doubling `micro-island`** — the metric M11-D tuned `absorbIslandBytes` against — and by moving
`missed lines` one in the wrong direction. The floor of three bytes takes 2.9 times the conservative
variant's win at 1/78th of the confetti cost: `micro-island` 1332 → 1351.

`false lines`, `split-mark` and `duplicated-line` do not move under any variant, which is the
property the rule rests on: it changes which *unchanged* bytes are drawn inside a mark and nothing
about which bytes differ.

### The reproduction, before and after

`corpus/5bonsai__website__nextjs/013cb0699eb9__src_app__locale__career_page.tsx`, new side:

```
before   *  143 | description: formatSierotki⟦changed|(
         *  144 |                   locale,
         *  145 |                   t('Homepage.⟧Support.Slider.SlideOne.description')…

after    *  143 | description: formatSierotki⟦changed/whitespace|(
         *  144 |                   ⟧locale⟦changed/whitespace|,
         *  145 |                   ⟧t('⟦changed|Homepage.⟧Support.Slider.SlideOne.description')…
```

`locale` and `t('` leave the mark, the indentation is labelled as the rewrap it is, and the only
loud mark left is the nine bytes that were actually inserted.

### Method note — the negative control was watched, and it failed for the wrong reason first

The DEC-117 check's control asserts that with the rule off the word *is* swallowed. It failed on the
first run: the synthetic case used a three-byte indent, so DEC-094's *no longer than the shorter
flank* rule had already refused the island and the new rule was never reached. The case was rebuilt
with an eighteen-space indent — what a real rewrap produces — and the control then failed and passed
in the right order. **A negative control that cannot reach the code it is controlling for passes for
the wrong reason and proves nothing**; this one was caught because it was run rather than reasoned
about.

2221 → 2231 checks.

## M14-B — the window the withholding question is asked over

**Date:** 2026-09-04. **Decision:** DEC-119.

### The sweep

| `reflowLookaheadLines` | `reflowed-block` | `duplicated-line` | `silent-old-side` |
|---|---|---|---|
| 0 (DEC-108, shipped) | 6071 | 147 | 205 |
| **1 — taken** | **6206** | **144** | **171** |
| 2 | 6242 | 148 | 171 |
| 3 | 6262 | 146 | 171 |

The first line is worth 135 blocks; the second 36 and the third 20. `silent-old-side` takes its whole
improvement — 205 → 171 — from the first line and does not move again. That is the shape saying what
it is: the formatter's closing token sits exactly one line past the block, and nothing else does.

`false lines` 9079, `missed lines` 7083, `marks` 70632, `presented bytes` 2696245 and `loud bytes`
2601011 are **identical at every setting including 0**, which is the check on the rest of the table:
DEC-119 changes which old lines are printed and nothing about which bytes differ.

### Why `duplicated-line` never saw this family

`duplicatedLineBreakdown` in `CorpusSurvey.swift` counts an old line as duplicated only when a
**byte-identical** new line exists in the same block:

```swift
guard let newIndex = newLines.indices.first(where: {
    !taken.contains($0) && Array(new[newLines[$0].start..<newLines[$0].end]) == text
}) else { continue }
```

A rewrapped line has no byte-identical partner by construction. So the shape the owner reported —
one old line printed beside the four new lines it became — scored **zero** on the metric named after
it, throughout. `reflowed-block` is the number that moves, and it moves because a block that
withholds is a block that stopped printing twice.

### The two properties that had to move, and why that is not loosening them

`over every fixture, a withheld half is on screen in the half that stays` and `over every fixture,
what is withheld is on the new side in order` both failed on `prettier-formatting` the moment the
lookahead landed. Both asserted the subsequence against `fixture.new[block.newStart..<block.newEnd]`.

The claim is *on screen*, and the context line is on screen — it is printed directly below the block.
The block was a proxy for the claim and stopped being an accurate one. Both now ask
`withheldWindowEnd`, and the bound they used to carry implicitly is asserted explicitly instead:
over every fixture the window crosses at most `reflowLookaheadLines` terminators, and a unit case
pins that a stop-touched line is refused.

### Method note — the negative control, watched twice

`reflowLookaheadLines` was set to 0 and the suite re-run: *and its old half is withheld rather than
printed beside its own rewrap* failed, and the inline control *with no lookahead the old half is
kept* passed. Restored, both hold the other way. The restore is also what surfaced the two fixture
properties above — they were green with the rule reverted and red with it in place, which is the only
reason they were found before the commit rather than after it.

2231 → 2238 checks.

## M14-C — merging by group instead of by string

**Date:** 2026-09-05. **Decision:** DEC-120. All 4016 pairs.

| | before | after |
|---|---|---|
| loud bytes | 2601011 | **2600684** |
| presented bytes | 2696245 | 2696245 |
| marks | 70632 | 70632 |
| false / missed lines | 9079 / 7083 | 9079 / 7083 |
| every survey shape | — | **unchanged** |

−327 bytes. The entry is worth keeping for what the number rules out rather than for what it buys:
**the classification leak at the merge is real and it is not where the 96.6% goes.**

The reason it is small is structural. A disagreement can only happen between two *classified*
neighbours, and there are few of those: `classifyLayoutMarks` labels only marks made entirely of
whitespace, and `changeClassification` labels only whole gap pairs before `reconcile` cuts them. The
pipeline does not produce many adjacent classified segments carrying different strings, so fixing
what happens when it does moves 0.01% of the presented bytes.

**What this leaves standing**, and what M14-D has to answer: of 2696245 presented bytes, 95595 are
in the formatting-only group and 2600684 are not — while 58.8% of pairs contain a block that is the
same content laid out differently. The quietening is not being lost at the merge. It is either never
computed, or it is computed and has nowhere to go.

2238 → 2241 checks.

## M14-D — the correction to M14-B, and the arm that found it

**Date:** 2026-09-05. **Decision:** DEC-119a.

| | DEC-119 as shipped | corrected |
|---|---|---|
| `reflowed-block` | 6206 | **6142** |
| `duplicated-line` | 144 | **137** |
| `silent-old-side` | 171 | 174 |
| false / missed lines | 9079 / 7083 | 9079 / 7083 |
| marks / presented / loud | 70632 / 2696245 / 2600684 | **unchanged** |

Sixty-four blocks stop withholding. They were being withheld because a token the old line still
needed was found somewhere in the middle of the following context line — the `1` of
`const value1 = 1;` standing in for the `1` of `const first = 1;`.

### How it was found, and how it was not

`diffscope-verify` was green through the whole of M14-B: 2238/2238. Nothing in it drives the
window, and nothing in it asks whether a block that withholds *should*.

`DIFFSCOPE_SELFTEST=1 swift run diffscope-app` failed on `expand-toggle`, an arm about a keystroke
round trip:

```
SELFTEST expand-before folds=2
SELFTEST expand-expanded folds=0
SELFTEST expand-collapsed folds=3
SELFTEST expand-toggle=MISMATCH 2→0→3 folds
```

Bisected across the three commits of this milestone, it landed on 941276c — DEC-119. The navigation
model, `const first = 1;` against `const first = 111;` with forty filler lines, had gained a reflow
fold it should not have. **An arm about ⌘E caught a losslessness defect in the withholding rule**,
because a fold appearing where none belongs is the same event seen from the other end.

### A second control that passed for the wrong reason

While checking whether DEC-048's formatting group reaches the unified layout, a new arm was written
and it passed — and it passed with the fix reverted as well. `diffscopeProbe`'s `foldMarks` counts
`.ds-fold` across the whole page, and the test model carried other folds; the arm was measuring
them. Rewritten to count `.ds-fold-formatting`, the marker the group is actually drawn with, it
reports `split=2 unified=2` — **with and without the change**.

So the claim *formatting groups are offered in split and absent in unified* is **not demonstrated**
and the change was reverted. For the model used, the group's old range overlaps a context run and
the existing projection finds it. What would settle it is a model whose formatting group lies wholly
inside blocks on the old side; the corpus has one
(`js-gloves__website__nextjs/1edef025e8d6__…ProductHeroSection.tsx`, group `old 4947..<5226`) and the
selftest cannot carry a corpus file. Recorded as open rather than fixed.

The arm stays, because *the group's marker exists in both layouts* is worth pinning either way.

2241 → 2242 checks, 41 → 42 selftest arms.

## M14-E — one percent of the corpus was two thirds of its error

**Date:** 2026-09-05. **Decision:** DEC-122. All 4016 pairs, `--line-mask 0` as the control.

| | control (`--line-mask 0`) | shipped |
|---|---|---|
| **false lines** | 9079 (17.5% of `+`) | **2993 (5.8%)** |
| missed lines | 7083 (19.9%) | 7110 (20.0%) |
| marks | 70632 | **52279** |
| presented bytes | 2696245 | **2429828** |
| loud bytes | 2600684 (96.5%) | **2320896 (95.5%)** |
| uncertain marks | 4565 (6.5%) | 4956 (9.5%) |

The control reproduces the previous run to the digit, so the knob is an honest one.

**Thirty-nine pairs moved and nothing else did.** Six of them:

```
src/app/[locale]/synerise/page.tsx           false 16→2   presented 10816→10802
src/app/[locale]/page.tsx                    false 10→0   presented 10040→10074
…/LinkedinBlockSlider.tsx                    false 15→1   presented 11133→12477
src/app/[locale]/case-studies/page.tsx       false 15→2   presented 14585→14559
src/components/layout/Footer/Footer.tsx      false 26→9   presented 13439→13471
src/app/[locale]/salesforce/page.tsx         false 25→5   presented 14065→14037
```

Presented bytes go **up** on three of the six while false lines go down, which is the clipping doing
two things at once: it removes the anchors' over-wide gaps and it promotes bytes inside the line
hunks that the anchors had called unchanged.

### A correction to M-A2, and to what was reported from it

M-A2 measured the alignment's share of the error as **2373 canonical false lines against 9079
shipped**, and that difference — 6706 — was reported as *the widening passes' contribution* and named
as the largest unaddressed lever in the audit. **That attribution was wrong.**

The 39 budget-exhausted pairs contribute **zero** canonical hunk lines, because they have no
canonical hunks, while contributing heavily to the shipped 9079. So most of the 6706 was never the
widening passes. It was `reconcile` not running at all.

With DEC-122 in place the shipped figure is 2993. The widening passes' true contribution has to be
re-derived against that; it is smaller than 6706 by most of the gap, and the next milestone should
measure it rather than inherit the old number.

*The lesson is the one M12-J already recorded from the other side:* a difference between two
measurements is only an attribution if both were taken over the same population, and these were not.

2242 → 2244 checks.
