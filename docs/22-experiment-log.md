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

**A caveat that belongs on record:** the default template `/usr/bin/open -a WebStorm {file}` contains no `{line}`, so the default still cannot jump. A template that includes `{line}` now receives a real one.

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
