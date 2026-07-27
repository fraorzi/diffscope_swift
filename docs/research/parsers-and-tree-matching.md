# Research — Parsers and Tree Matching

**Status: COMPLETE for Phase 3 scope.** Supersedes the earlier PARTIAL version. All verified
content from that version is preserved, with its sources, and is marked where it has been
**qualified** by later evidence.

**Date of research:** 2026-07-26. **Machine:** macOS 26.5.2 arm64, Apple silicon.

**Method.** Primary sources only: official docs, source code, issue trackers, maintainer
statements, package registries. Plus **direct measurement** on this machine using parsers
already present in the user's own `node_modules` (nothing was installed). Every claim marked
`[Fact]` has a source URL or is a reproducible measurement whose script is named. Inference is
marked `[Interpretation]`. Where I could not verify something, it is in **Open questions**, not
asserted.

**This document does not name a winner.** It presents trade-offs, including for options I find
unattractive. The architecture decision (Phase 7 / OQ-033) takes other inputs.

---

## 1. Why the parser requirement is unusual here

Under **DEC-021** the parser is **advisory**. It is used to propose alignment, never to decide
whether something differs. Under **DEC-024** the internal model is a **total ordered byte
partition** of each file. Together these invert the normal parser-selection criteria:

- Semantic richness of the AST barely matters. Scope analysis, symbol tables, and type
  information are all irrelevant.
- **Exact ranges matter enormously**, because presented regions are ranges and the invariant is
  checked on bytes.
- **The coordinate system matters more than the ranges themselves.** A parser reporting UTF-16
  code units against a byte-partition model needs a conversion layer, and that layer is a
  correctness risk in its own right. 51% of the target corpus is non-ASCII, so this is not a
  tail case.
- **Error recovery matters more than correctness on valid input**, because DEC-007 auto-refresh
  on save makes half-typed source a routine state rather than an exceptional one.
- **Zero-width nodes must be identifiable**, so they can be excluded from the partition without
  breaking no-gaps/no-overlaps.
- Losslessness of the tree is valuable but not strictly required: we always hold the original
  bytes and can slice them ourselves. What is required is that ranges are exact and in the
  coordinate system we compare in.
- **A parser or matcher that normalizes identifiers or string literals internally is
  disqualified for that use** (DEC-021 §4.1). No candidate below was found to do this at the
  parse level; see Open question OQ-P8.

### 1.1 The one structural test that actually matters

DEC-024 does not need the parser to tile the file. It needs to be able to *build* a tiling from
what the parser gives. The realistic construction is:

1. Take all leaf ranges.
2. Drop zero-width ones.
3. Clamp any overlaps.
4. Fill residual gaps and the tail directly from the source bytes as unlabeled filler.

Spike **P-2** below tests exactly this, per candidate. §3.2.3 reports the result of running it
against the TypeScript compiler on this corpus, as a worked example of what the test catches.

---

## 2. What was measured versus what was only read

| Candidate | How assessed |
|---|---|
| **TypeScript compiler API** | **Measured.** `typescript@6.0.3` from `Portfolio/node_modules`. 4,800 truncation points across 120 real `.tsx` files. |
| **@babel/parser** | **Measured.** `@babel/parser@7.29.3` from the same tree. Same 4,800 truncation points. |
| tree-sitter | Read only: C API, both JS bindings' source, Swift package, issue tracker, registries. Not run — no grammar binary present and nothing may be installed. |
| SWC | Read only. `@swc/core` is **not** present locally (only `@swc/helpers`, `@swc/counter`). |
| oxc | Read only. `oxc-parser` not present locally (only `@oxc-project/types`). |
| Biome | Read only. Rust is **not installed** on this machine. |

**[Interpretation]** The asymmetry is real and should be corrected before the decision, not
papered over. The two candidates I could run are the two that came out looking most and least
survivable respectively, and that is at least partly an artifact of *being runnable*. P-1 and
P-2 exist to close this gap; both require installing toolchains, which is why they are spikes
and not part of this document.

---

## 3. Candidates

### 3.1 tree-sitter

**[Fact]** Each node carries a text range defined by **byte offsets** and point positions
(row/column). Nodes map precisely back to source. Each node has a numeric ID; unchanged nodes
retain IDs across incremental updates.
<https://tree-sitter.github.io/tree-sitter/>

**[Fact]** Stated design goals, verbatim: "General enough to parse any programming language",
"Fast enough to parse on every keystroke in a text editor", "Robust enough to provide useful
results even in the presence of syntax errors", "Dependency-free so that the runtime library
(which is written in pure C11) can be embedded in any application".
<https://tree-sitter.github.io/tree-sitter/>

**[Fact]** On invalid input the parser inserts `ERROR` nodes spanning unrecognized text, and
zero-width `MISSING` nodes for anticipated-but-absent tokens (e.g. a required semicolon). It
performs error recovery and returns a usable tree. `ts_node_is_missing` documents: "Missing
nodes are inserted by the parser in order to recover from certain kinds of syntax errors."
<https://github.com/tree-sitter/tree-sitter/blob/master/lib/include/tree_sitter/api.h>

**[Fact, from the domain research]** `MISSING` nodes are zero-width and must be **excluded from
any byte partition**, or they break the no-gaps/no-overlaps property.
See `domain-existing-tools.md` §5.7.

**[Fact]** Whitespace is not in the tree. `extras` in a grammar is "an array of tokens that may
appear anywhere in the language ... often used for whitespace and comments"; whitespace is
skipped, not represented.
<https://tree-sitter.github.io/tree-sitter/creating-parsers/2-the-grammar-dsl.html>
→ leaves do **not** tile the file; gaps must be filled from bytes.

**[Fact — important defect]** Incremental parsing can produce trees containing error nodes where
a **fresh parse of the identical content does not**. Tracked as tree-sitter issue #4001.
<https://github.com/tree-sitter/tree-sitter/issues/4001>

**[Interpretation]** That defect interacts directly with our design. Under DEC-007 we re-parse
on every save; if we use incremental parsing, a spurious `ERROR` node would trigger fallback and
visibly degrade alignment quality for content that is actually fine. It cannot produce
*incorrect* output — fallback is safe by construction — but it would make the tool look
unreliable. Mitigations: parse fresh rather than incrementally, or parse incrementally and
re-parse fresh when errors appear. Both are cheap enough to be worth measuring.

#### 3.1.1 QUALIFICATION of the earlier "native byte offsets" interpretation

The PARTIAL version stated: *"Byte offsets being native is a strong fit: it is the same
coordinate system as INV-2, so no conversion layer is needed."*

**That is true of the C, Rust and Swift bindings. It is false of both JavaScript bindings**, and
the JavaScript bindings are the ones an Electron/Node stack would use. This is a qualification,
not a contradiction: the underlying C API is still byte-based.

**[Fact]** `node-tree-sitter` (the native Node addon) feeds the parser `TSInputEncodingUTF16LE`
and divides every reported offset by two:

```c
// src/parser.cc
result.encoding = TSInputEncodingUTF16LE;
```
```c
// src/node.cc, StartIndex()
auto result = static_cast<int32_t>(ts_node_start_byte(node) / 2);
```
<https://github.com/tree-sitter/node-tree-sitter/blob/master/src/parser.cc> ·
<https://github.com/tree-sitter/node-tree-sitter/blob/master/src/node.cc>

**[Fact]** `web-tree-sitter` (the WASM binding) does the same thing:

```c
// lib/binding_web/lib/tree-sitter.c
static uint32_t code_unit_to_byte(uint32_t unit) { return unit << 1; }
static uint32_t byte_to_code_unit(uint32_t byte) { return byte >> 1; }
...
uint32_t ts_node_start_index_wasm(const TSTree *tree) {
  TSNode node = unmarshal_node(tree);
  return byte_to_code_unit(ts_node_start_byte(node));
}
```
and sets `TSInputEncodingUTF16LE` on the `TSInput`. `marshal_point` applies the same shift to
`Point.column`.
<https://github.com/tree-sitter/tree-sitter/blob/master/lib/binding_web/lib/tree-sitter.c>

**[Fact — documentation defect]** Both bindings *document* these values as byte offsets. The
`node-tree-sitter` type declarations say "The byte offset of the start of the range", and
`web-tree-sitter`'s `Node.startIndex` says "The byte index where this node starts."
<https://github.com/tree-sitter/node-tree-sitter/blob/master/tree-sitter.d.ts> ·
<https://github.com/tree-sitter/tree-sitter/blob/master/lib/binding_web/src/node.ts>

**[Interpretation]** This is precisely the failure shape DEC-024 is exposed to, and the
documentation actively misleads. On an all-ASCII test corpus the two coordinate systems
coincide and every test passes; on the real corpus (51% non-ASCII, Polish diacritics, and at
least one decomposed `Ż` per `14-losslessness-and-trust-model.md` §4.1) they diverge silently.
Anyone choosing tree-sitter *and* a Node stack must treat offset conversion as a first-class,
tested component, not an incidental detail. Choosing tree-sitter *and* Swift avoids the problem
entirely, since `SwiftTreeSitter` exposes `Node.byteRange` from the C API directly.

#### 3.1.2 Swift bindings

**[Fact]** `tree-sitter/swift-tree-sitter` (formerly `ChimeHQ/SwiftTreeSitter`) is now under the
**tree-sitter GitHub organisation**. License **BSD-3-Clause**. 408 stars, 3 open issues. Latest
release **0.10.0, 2026-03-18**; previous release 0.9.0, 2024-11-19 (a 16-month gap). Last commits
2026-05-26. It is split into `SwiftTreeSitter` (a close match to the C runtime API) and
`SwiftTreeSitterLayer` (nested languages, cross-nesting queries). `Node.byteRange` returns
`Range<UInt32>`.
<https://github.com/tree-sitter/swift-tree-sitter>

**[Fact]** Both `tree-sitter` core and `tree-sitter-typescript` ship first-party Swift Package
Manager manifests. `tree-sitter-typescript`'s `Package.swift` declares **two** library targets,
`TreeSitterTypeScript` and `TreeSitterTSX`, compiling `parser.c` + `scanner.c` for each.
<https://github.com/tree-sitter/tree-sitter/blob/master/Package.swift> ·
<https://github.com/tree-sitter/tree-sitter-typescript/blob/master/Package.swift>

**[Fact]** No Swift package manifest exists at the repository root of oxc, swc, biome, or babel
(HTTP 404 on `Package.swift` for all four, checked 2026-07-26).

**[Interpretation]** tree-sitter is the only candidate with a *no-glue-code* Swift path. For any
Rust candidate a Swift consumer would need a hand-written C-ABI shim (cbindgen / swift-bridge /
UniFFI) plus a Rust toolchain that is not currently installed. That is not disqualifying, but it
is a whole subsystem, and it is a subsystem that sits directly on the correctness-critical
range data.

#### 3.1.3 Maintenance — a split picture

**[Fact]** Core runtime `tree-sitter/tree-sitter`: MIT, 26,430 stars, last push 2026-07-25,
132 open issues. Releases roughly monthly: v0.26.11 (2026-07-12), v0.26.10 (2026-06-28),
v0.26.9 (2026-05-19), v0.26.8 (2026-03-31), v0.26.7 (2026-03-14).

**[Fact — the risk]** The **grammar** we would actually depend on is much less active.
`tree-sitter/tree-sitter-typescript`: MIT, 526 stars, **47 open issues**, last release
**v0.23.2 on 2024-11-11**, last commit on the default branch `master` **2025-01-30**. (The
repository's `pushed_at` of 2025-08-29 is activity on a side branch, not `master`; there are
20 stale branches.) npm `tree-sitter-typescript` is at 0.23.2, published 2024-11-11.
<https://github.com/tree-sitter/tree-sitter-typescript>

**[Fact]** Open grammar issue **#306**, "bug: JSX captures whitespaces in nested, multiline
tags" (open since 2024-07-23). The reporter's words: "The Parse Tree is correct in both cases,
but tree elements' ranges are not." A nested `jsx_opening_element` on its own line is reported
with the preceding whitespace inside its range.
<https://github.com/tree-sitter/tree-sitter-typescript/issues/306>
Also open: #320 (fails to parse a JSX string attribute containing a URL, 2024-12-05),
#340 (jsx_attribute `=` not its own node, 2025-08-07).

**[Fact]** Node bindings also lag: `tree-sitter/node-tree-sitter` last release **v0.22.4,
2024-12-30**, while npm `tree-sitter` is at 0.25.0 (2025-06-02) and core is at 0.26.11.
`web-tree-sitter` (published from the core repo) tracks core exactly: 0.26.11, 2026-07-12.

**[Interpretation]** "tree-sitter is well maintained" is true of the runtime and misleading
about the thing we need. DiffScope needs exactly one grammar, and that grammar has been quiet
for ~18 months with an open, directly relevant range-fidelity bug about JSX whitespace. That
does not make the grammar wrong — a frozen grammar for a slowly-moving language may simply be
done — but it means we would own any TS/TSX syntax gap ourselves. The `web-tree-sitter` path is
better maintained than the `node-tree-sitter` path.

**License:** MIT (core, grammar, web binding, node binding); BSD-3-Clause (Swift binding). No
copyleft. Safe for closed-source commercial distribution.

---

### 3.2 TypeScript compiler API — MEASURED

Reference implementation for TS/TSX semantics, since it *is* the language.

#### 3.2.1 Position model and trivia

**[Fact]** The public `Node` interface extends `ReadonlyTextRange { readonly pos: number;
readonly end: number }` and separately declares the accessors:

```ts
getStart(sourceFile?: SourceFile, includeJsDocComment?: boolean): number;
getFullStart(): number;
getEnd(): number;
getWidth(sourceFile?: SourceFileLike): number;
getFullWidth(): number;
getLeadingTriviaWidth(sourceFile?: SourceFile): number;
getFullText(sourceFile?: SourceFile): string;
getText(sourceFile?: SourceFile): string;
```
(`typescript@6.0.3`, `lib/typescript.d.ts` lines 3673–3679 and 4310–4322; identical shape in
`src/compiler/types.ts` upstream.)
<https://github.com/microsoft/TypeScript/blob/main/src/compiler/types.ts>

**[Fact — measured]** `node.pos` is the **full start**, i.e. it includes leading trivia;
`getStart()` skips it; `getLeadingTriviaWidth()` is the difference. On a real file:

```
stmt[1] kind: FunctionDeclaration
pos(fullStart)= 26   getStart()= 47   getLeadingTriviaWidth()= 21   end= 233
getFullText() starts with: "\n// komentarz: Żabka\nexport function Skl"
```
(script `scratchpad/ts-probe.mjs`)

**[Interpretation]** This is the strongest trivia story of any candidate other than Biome's CST.
Trivia is not "attached" as a side-channel; it is *inside* the node's own range by default, and
the token-start is the derived value. Under DEC-024 that means whitespace and comments are
already inside the partition for free rather than needing gap-filling.

#### 3.2.2 Coordinate system — UTF-16 code units

**[Fact — measured]** `sourceFile.text` is a JavaScript string and all positions index it, i.e.
they are **UTF-16 code units**. On `const s = "🏪"; const t = "Ż";\n`:

```
JS string length (UTF-16 code units): 32
Buffer.byteLength UTF-8:              35
[...U].length (code points):          31
sourceFile.end:                       32      ← matches UTF-16, not UTF-8
getLineAndCharacterOfPosition(...):   {"line":0,"character":10}   ← also UTF-16
```
(script `scratchpad/ts-probe.mjs`)

**[Interpretation]** A UTF-8↔UTF-16 conversion table is mandatory. It is cheap (one pass, one
`Uint32Array`) and it is testable, but it is a correctness-critical component that must be
fuzzed on non-BMP characters and on decomposed sequences, not just on Polish diacritics.

#### 3.2.3 Byte-partition behaviour — measured, and it does **not** tile naively

Method: for 120 real `.tsx` files from the user's own projects, truncate at 40 evenly-spaced
points each (**4,800 truncation points**), parse each with
`ts.createSourceFile(..., ScriptKind.TSX)`, collect all `getChildren()` leaves, and check
whether concatenating `text.slice(pos, end)` reproduces the input exactly.
(scripts `scratchpad/sweep.mjs`, `sweep2.mjs`, `sweep3.mjs`, `diag.mjs`, `diag2.mjs`)

| Construction | Non-exact reconstruction |
|---|---|
| Naive: every `getChildren()` leaf | **131 / 4,800 (2.73%)** — and **4 / 120 valid, untruncated files** also fail |
| Skip `JSDoc*` subtrees | 18 / 4,800 (0.38%) |
| DEC-024 construction: drop zero-width, clamp overlaps, fill gaps + tail from bytes | **0 / 4,800** |

**[Fact — root cause 1, JSDoc]** `getChildren()` exposes `JSDocComment` nodes whose ranges
**alias** the leading trivia of the following token. The result is simultaneously a gap and an
overlap:

```
FILE FileInput.tsx  cut 1422
  gaps:     [[1210,1213,"JSDocComment"]]
  overlaps: [[1210,1231,"Identifier"]]
  overlap text: "\n  /** Input label */"
```

**[Fact — root cause 2, unterminated block comment]** All 18 residual failures are truncations
*inside* an unterminated `/** … ` comment (`'*/' expected.`), where the trailing bytes end up
inside a JSDoc node and are dropped once JSDoc subtrees are skipped.

**[Fact]** With the DEC-024 construction, gap-filler segments account for **0.01% of all bytes**
across the sweep. The parser tiles essentially everything; the filler is a safety net, not a
workhorse.

**[Interpretation]** This is the single most transferable engineering result in this document,
and it is not TypeScript-specific. **Do not trust any parser to tile the file. Build the
partition by construction and assert it.** DEC-024 is not paranoia; it caught a real 2.73%
failure rate in the most mature parser in the set, including on *valid* input. Note also that
the naive construction fails on valid files, which means a spike that only tests broken input
would have missed it.

#### 3.2.4 Zero-width nodes

**[Fact — measured]** `getChildren()` leaves include zero-width nodes at **95.0% of the 4,800
truncation points**. Their kinds:

| Kind | When | Flagged? |
|---|---|---|
| `SyntaxList` | empty list (e.g. no modifiers) — present on **valid** input too | no |
| `EndOfFileToken` | always, at end of file | no |
| `Identifier` | synthesized by error recovery for a missing name | **yes** — `NodeFlags.ThisNodeHasError` is set |

(script `scratchpad/ts-zero.mjs`)

**[Interpretation]** Structurally identical to tree-sitter's `MISSING` problem, with one
advantage: TypeScript's recovery-synthesized nodes carry an error flag, so they are
distinguishable from genuine empty lists. In practice the kind-agnostic rule `pos === end →
drop` is sufficient and was verified safe across all 4,800 points.

#### 3.2.5 Error recovery — measured, and it is total

**[Fact]** `createSourceFile` does not throw on syntax errors. Errors accumulate in
`sourceFile.parseDiagnostics` (`DiagnosticWithDetachedLocation[]`), populated by
`parseErrorAtCurrentToken` / `parseErrorAtPosition` / `parseErrorAt`; missing tokens are
synthesized by `createMissingNode`.
<https://github.com/microsoft/TypeScript/blob/main/src/compiler/parser.ts>

**[Fact — measured]** Across **4,800 truncation points on 120 real `.tsx` files**,
`ts.createSourceFile` threw **0 times** and always returned a tree from which a valid total
partition could be built.

**[Fact — measured]** Cut immediately after `<span>` in a nested JSX return, TypeScript emits
four precise, located diagnostics and keeps both statements:

```
JSX element 'span' has no corresponding closing tag.   start=169 len=4
'</' expected.                                          start=174 len=0
JSX element 'div' has no corresponding closing tag.     start=139 len=3
'</' expected.                                          start=174 len=0
AST nodes: truncated = 41   full = 54     (76% of the tree survives)
```
(script `scratchpad/ts-probe.mjs`)

**[Interpretation]** For the DEC-007 half-typed-JSX case this is exactly the desired behaviour:
localized diagnostics with real ranges, an intact partition, and most of the tree still usable.
It also gives us a free quality signal — the diagnostics have byte (well, UTF-16) ranges, so we
can degrade *regionally* rather than falling back for the whole file.

#### 3.2.6 Performance and memory — measured on this machine

Corpus: 159 `.tsx` files, 561 KiB total, from the user's own projects (21 of them, 13%, contain
non-ASCII). (script `scratchpad/bench.mjs`)

| Operation | Time (whole corpus) | Throughput |
|---|---|---|
| `createSourceFile`, `setParentNodes: false` | 13.8 ms | 39.6 MiB/s |
| `createSourceFile`, `setParentNodes: true` | 13.2 ms | 41.6 MiB/s |
| `@babel/parser` (ts+jsx, ranges, tokens) | 18.9 ms | 29.0 MiB/s |

Largest single file (51.3 KiB): **0.3 ms** warm.
Retained heap for 159 ASTs with parent pointers: **4.5 MiB for 0.55 MiB of source ≈ 8.2×**.

**[Interpretation]** For a per-save re-parse of one file this is far inside any interactive
budget — a 50 KiB TSX file is sub-millisecond. The 8.2× memory multiplier matters only if we
cache many ASTs; for a two-sides-of-one-file model it is negligible. Note this is the *JS*
TypeScript; see the next section.

#### 3.2.7 The TypeScript 7 discontinuity — a first-order longevity risk

**[Fact]** npm `typescript` latest is **7.0.2, published 2026-07-08**. TypeScript 7 is the
**Go** native port (`microsoft/typescript-go`, Apache-2.0, 26,065 stars).
<https://github.com/microsoft/typescript-go>

**[Fact]** The typescript-go README's own status table says, verbatim:

| Feature | Status |
|---|---|
| Parsing/scanning | done — "Exact same syntax errors as TS 6.0" |
| JSX | done |
| Language service (LSP) | in progress |
| **API** | **not ready** |

with "not ready" defined in the same README as "either haven't even started yet, or far enough
from ready that you shouldn't bother messing with it yet."

**[Fact]** The npm package shape confirms the break. `typescript@7.0.2` has **no `main` and no
`types`**; it declares 20 platform-specific native binary optional dependencies
(`@typescript/typescript-darwin-arm64` etc.); and its `exports` map is:

```
"."                        → ./lib/version.cjs        ← the version string, nothing else
"./unstable/ast"           → ./dist/ast/index.js
"./unstable/ast/scanner"   → ./dist/ast/scanner.js
"./unstable/ast/visitor"   → ./dist/ast/visitor.js
"./unstable/sync"          → ./dist/api/sync/api.js
"./unstable/async"         → ./dist/api/async/api.js
"./unstable/proto"         → ./dist/api/proto.js
"./unstable/fs"            → ./dist/api/fs.js
```
(npm registry metadata for `typescript@7.0.2`, fetched 2026-07-26)

**[Fact]** The typescript-go repo contains `internal/api/` with `conn.go`, `transport.go`,
`protocol_jsonrpc.go`, `protocol_msgpack.go`, `server.go` and an `encoder/` directory — i.e. the
TS 7 API is an **out-of-process JSON-RPC / msgpack API server**, not an in-process library.
<https://github.com/microsoft/typescript-go/tree/main/internal/api>

**[Interpretation]** Two readings, both worth stating.

- *Against:* the classic `import ts from "typescript"; ts.createSourceFile(...)` API — the thing
  §3.2.1–3.2.6 measured — is a **TypeScript 5/6 API**. Everything on the TS 7 line is behind an
  `unstable/` subpath and officially "not ready". Building on it means either pinning to
  TypeScript 6 indefinitely or planning a migration to an API that does not yet exist.
- *For:* an out-of-process, msgpack/JSON-RPC API is **language-agnostic**. If DiffScope ends up
  in Swift, a TS 7 API server is a far more plausible integration route than FFI into a Rust
  parser — the same route the VS Code extension already uses. The `unstable/ast/scanner` export
  suggests token-level access is intended to survive.

Either way this is a **timing** risk, not a capability risk, and it should be re-checked
immediately before the Phase 7 decision rather than trusted from this document.

**License:** Apache-2.0 (both `microsoft/TypeScript` and `microsoft/typescript-go`). Permissive,
patent grant, safe for commercial distribution.

---

### 3.3 Babel (`@babel/parser`) — MEASURED

**[Fact]** Options and defaults, from the official docs:
`sourceType` (`"script"`), `strictMode` (false), `attachComment` (**true**), `locations`
(**true**), `ranges` (**false**), `tokens` (**false**), `errorRecovery` (**false**),
`createParenthesizedExpressions` (false), `createImportExpressions` (false), `annexB` (true),
`startLine` (1), `startColumn` (0), `startIndex` (0).
<https://babeljs.io/docs/babel-parser>

**[Fact]** Node position fields: `start` / `end` (0-based indices), `loc.{start,end}.{line,
column,index}`, and `range: [start, end]` when `ranges: true`. `tokens: true` adds a flat token
array. Comments land in `ast.comments` and, with `attachComment: true`, as
`leadingComments` / `trailingComments` on nodes.
<https://babeljs.io/docs/babel-parser>

**[Fact — measured]** Positions are **UTF-16 code units**. On the same probe string:
UTF-16 length 31, UTF-8 bytes 34, code points 30, `program.end` = **31**. `loc.start.column`
also tracks the UTF-16 index (`10` for a literal at index 10).
(script `scratchpad/babel-probe.mjs`)

**[Fact — measured]** **Tokens do not tile the file.** On a 234-char TSX file with
`tokens: true`: 66 tokens, **25 gaps totalling 35 characters**, 0 overlaps, 1 zero-width token
(EOF), ending exactly at 234. The gaps are inter-token whitespace. Comments are in a separate
array, not in the token stream at their positions.

**[Fact — measured, the decisive result] `errorRecovery` does not recover from half-typed JSX.**
Across the same **4,800 truncation points on 120 real `.tsx` files**, `@babel/parser` with
`errorRecovery: true` **threw on 4,400 of them (91.67%)**. On a single 234-char file swept at 29
points, `errorRecovery: true` threw 26 times and `errorRecovery: false` also threw 26 times —
identical.

**[Fact — measured] What `errorRecovery` actually covers.** It recovers *early/semantic* errors
and not *tokenizer or structural* errors:

| Input | `errorRecovery: true` | `errorRecovery: false` |
|---|---|---|
| `({ __proto__: 1, __proto__: 2 });` | ok, `errors=[DuplicateProto]` | throws |
| `1 = 2;` | ok, `errors=[InvalidLhs]` | throws |
| `function f(){ await x; }` | ok, `errors=[AwaitNotInAsyncContext]` | throws |
| `return 1;` (top level) | ok, `errors=[IllegalReturn]` | throws |
| `"use strict"; var x; delete x;` | ok, `errors=[StrictDelete]` | throws |
| `const a = <div className="x">` | **throws** `UnexpectedToken` | throws |
| `const a = <div classN` | **throws** `UnexpectedToken` | throws |
| `function f() {` | **throws** `UnexpectedToken` | throws |
| `interface I { a: string` | **throws** `UnexpectedToken` | throws |
| `const a = ;` | **throws** `UnexpectedToken` | throws |

(script `scratchpad/babel-recover.mjs`)

This matches the documentation's own hedge: even with the option enabled, "`@babel/parser` could
throw for unrecoverable errors." The measurement makes concrete what "unrecoverable" covers —
in practice, every shape of half-typed code.

**[Fact — measured]** On the *valid* corpus Babel parses all 159 files with 0 failures at
29.0 MiB/s (vs TypeScript's 39.6–41.6 MiB/s).

**[Interpretation]** Babel is a strong parser for complete files and a **non-candidate for the
DEC-007 routine-invalid-source case**. A 91.67% throw rate on truncated real files means the
structural layer would be unavailable for most of the time the user is actually typing, which is
exactly when they are looking at the diff. Its `errorRecovery` option is genuinely useful, but
it targets a different problem (lint-style tolerance of semantically invalid but
*syntactically complete* code). The token-stream gaps are a lesser issue — gap-filling handles
them — and the UTF-16 coordinate system is the same conversion burden as TypeScript's.

**Maintenance:** `babel/babel` MIT, 43,958 stars, last push 2026-07-24, 764 open issues.
npm `@babel/parser` latest **8.0.4, 2026-07-09**. Extremely active, very large contributor base,
no bus-factor concern.
**License:** MIT. Safe for commercial distribution.

---

### 3.4 SWC

**[Fact]** License **Apache-2.0**. `swc-project/swc`, 34,144 stars, last push 2026-07-26,
408 open issues. npm `@swc/core` latest **1.15.46, 2026-07-19**; releases are frequent (weekly
stable plus nightlies).
<https://github.com/swc-project/swc/blob/main/LICENSE>

**[Fact — the span gotcha, confirmed and it is by design]** Issue **#1366, "parseFileSync span
bug"**, opened 2021-01-28, **still open** as of 2026-07-26, 42 comments.
<https://github.com/swc-project/swc/issues/1366>

- The reporter parses two one-line files and gets `span.start = 0` for the first and
  `span.start = 12` for the second.
- Maintainer **kdy1**: *"It's not a bug. If you want span to start with 0, you can create new
  instance of Compiler, which have same apis."* A follow-up comment demonstrates that **even
  separate `Compiler` instances do not reset the offset**.
- kdy1, later: *"Currently, there's no workaround."*
- Root cause identified in-thread by `vjpr`: every `transform_sync`/`parse` calls
  `SourceMap::new_source_file`, which assigns a monotonically increasing `start_pos`.
- Community workarounds, all fragile: subtract `program.span.start`; parse an empty string
  first and use its `span.end` as the offset; run each parse in a **separate child process**
  (published as `@knighted/reparse`).
- Comment from `mmis1000` (2024-09-15): the offset workaround has **since broken**, because the
  `Module` span now excludes comments before the first statement and after the last.
- Comment from `rizrmd` (2023-11-20): parsing repeatedly in one process will eventually exhaust
  the offset space.

This confirms the premise in the brief. Spans are global across a session, not per file, by
design, and there is no maintainer-endorsed fix.

**[Fact]** SWC spans are **UTF-8 byte positions**, not character positions — confirmed by user
`joarfish` in the same thread, who works around it by encoding the source to a `Uint8Array` and
slicing by byte index. This is corroborated by `swc_common::BytePos`, whose docs state positions
are "absolute positions from the beginning of the source_map, not positions relative to
SourceFiles", and warn that "you cannot assume that the length of the span = hi - lo; there may
be space in the BytePos range between files."
<https://rustdoc.swc.rs/swc_common/struct.BytePos.html> ·
<https://rustdoc.swc.rs/swc_common/source_map/struct.SourceMap.html>

**[Fact — error recovery]** `swc_ecma_parser`'s own crate documentation is modest and specific:
"The parser can recover from **some** parsing errors. For example, parser returns `Ok(Module)`
for the code below, while emitting error to handler" — the example being a missing comma in a
`const enum` where a newline permits recovery. `Parser::take_errors() -> Vec<Error>` retrieves
accumulated errors.
<https://github.com/swc-project/swc/blob/main/crates/swc_ecma_parser/src/lib.rs> ·
<https://rustdoc.swc.rs/swc_ecma_parser/struct.Parser.html>

**[Fact]** Recent and historical error-handling work: PR **#11479** "feat(es/parser): Add error
recovery for recoverable syntax errors" (merged 2026-01-22); issue **#10681** "Regression of ES
parser error recovery" (2025-06-22); issue **#10192** "[Enhance]: Improving SWC's Error Recovery
for more friendly experience" (2025-03-14); issue **#1170** "panic: Parser panics on malformed
TypeScript code".

**[Fact — performance]** From oxc's published cross-parser benchmark on a MacBook Pro M3 Max:
`cal.com.tsx` — swc **13.4 ms**; `typescript.js` — swc **84.1 ms**. Memory: 16.6 MB and 92.0 MB
respectively.
<https://github.com/oxc-project/bench-javascript-parser-written-in-rust>

**[Interpretation]** SWC is the weakest fit of the Rust candidates *for this specific product*.
Byte-native spans are the right coordinate system, but the global-span design turns every
`span.start` into a value that is only meaningful relative to an offset you must recover
yourself, and the maintainer's position is that this will not change (and that the JS-exposed
AST is not a supported long-term surface: *"I want to remove `parse` and `print` with v2 of
swc"*). Combined with error recovery that is documented as covering only "some" errors and no
published statement about JSX/TSX recovery, SWC would carry two independent risks on the two
axes we care about most. It is not disqualified — a Rust-side integration that parses one file
per fresh `SourceMap` sidesteps the span issue entirely — but the Node path is hazardous.

**License:** Apache-2.0. Safe for commercial distribution.

---

### 3.5 oxc

**[Fact]** License **MIT**. `oxc-project/oxc`, 22,119 stars, last push 2026-07-26, 703 open
issues. Rust crates released ~weekly (`crates_v0.141.0`, 2026-07-21). npm `oxc-parser` latest
**0.141.0, 2026-07-21**, MIT, first published 2023-11-10.

**[Fact — maturity]** Self-reported conformance: "100% pass rate on ECMAScript conformance
tests" (Test262), "99.62% compatibility with Babel parser tests", "99.86% compatibility with
TypeScript compiler tests".
<https://oxc.rs/docs/learn/architecture/parser>

**[Fact — position model]** All positions in the Rust core are **UTF-8 byte offsets**. `Span`
uses `u32` for `start`/`end`, which the crate docs flag explicitly: "Because `oxc_span::Span`
uses `u32` instead of `usize`, Oxc can only parse files up to 4 GiB in size."
<https://github.com/oxc-project/oxc/blob/main/crates/oxc_parser/src/lib.rs>

**[Fact — the JS-binding conversion, and it is on by default]** `oxc-parser` (napi) converts
spans to **UTF-16 code units**. PR **#9291**, "feat(napi/parser)!: remove magic string; enable
utf16 span converter by default" (merged 2025-02-22) — note the `!` breaking-change marker. The
PR body benchmarks the cost at ~1.09× (`checker.ts`: 31.9 ms with conversion vs 29.3 ms
without).
<https://github.com/oxc-project/oxc/pull/9291>

**[Fact — the conversion layer has produced bugs]** A trail of fixes around it:
#9093 "fix(napi/parser): utf16 span for module record" (2025-02-14),
#9112 "fix(napi/parser): utf16 span for errors" (2025-02-14),
#9376 "feat(wasm): return estree with utf16 span offsets" (2025-02-26),
#12436 "Linter JS plugins: Convert `Span` offsets to/from UTF16" (2025-07-21),
#13236/#13237/#13241/#13340/#13344 (Aug 2025, UTF-8↔UTF-16 converter refactors),
**#14768 "fix(linter/plugins): handle utf16 characters within comment spans" (2025-10-19)** —
whose description reads "Corrects start and end offsets to accommodate two byte characters."
Separately, #959 ("feat(parser): utf16 spans", asking for native UTF-16) was **closed as not
planned**, and #9110 records that "formatter reports utf-8 index while eslint reports in
utf-16".
<https://github.com/oxc-project/oxc/issues>

**[Fact — error recovery]** The `ParserReturn` doc comment states the contract precisely:

> When [recovery] happens, 1. `diagnostics` will be non-empty, 2. `program` will contain a full
> AST, 3. `panicked` will be false.
> When the parser cannot recover, it will abort and terminate parsing early. `program` will be
> empty and `panicked` will be `true`.

<https://github.com/oxc-project/oxc/blob/main/crates/oxc_parser/src/lib.rs>

**[Fact]** oxc has explicitly *removed* recoverability from some errors — e.g. #5285
"fix(parser): change unterminated regex error to be non-recoverable" (2024-08-28), #1870
"EmptyParenthesizedExpression should generate non-recoverable error". Recovery is a curated
per-error property, not a general property of the parser.

**[Fact — performance, the best figures in the set]** oxc's own benchmark, MacBook Pro M3 Max:

| File | oxc | swc | Biome |
|---|---|---|---|
| `cal.com.tsx` | **3.4 ms** | 13.4 ms (3.99×) | 16.7 ms (4.97×) |
| `typescript.js` | **26.3 ms** | 84.1 ms (3.20×) | 130.1 ms (4.94×) |
| memory, `cal.com.tsx` | **11.5 MB** | 16.6 MB (1.44×) | 22.5 MB (1.95×) |
| memory, `typescript.js` | **68.8 MB** | 92.0 MB (1.34×) | 117.4 MB (1.70×) |

<https://github.com/oxc-project/bench-javascript-parser-written-in-rust>
(Self-published by the winner; treat the ranking as directional and the magnitudes as
plausible-but-unaudited.)

**[Interpretation]** oxc has the cleanest core position model of any candidate — UTF-8 byte
offsets, `u32`, no global source map, arena-allocated. If DiffScope's engine is Rust, oxc is the
only candidate whose native coordinate system *is* DEC-024's coordinate system with no
conversion at all. If DiffScope's engine is Node, that advantage is thrown away by default: the
napi binding converts to UTF-16, and the issue trail shows that converter has been a repeated
source of off-by-N bugs on exactly the multi-byte characters this corpus is full of. The
error-recovery contract is honest but binary — a `panicked: true` gives an *empty* program, not
a partial one, which is materially worse than tree-sitter's partial tree or TypeScript's
diagnostics-plus-tree for the half-typed case. **How often `panicked` is true for truncated TSX
is the single most important unknown in this document** (spike P-1).

**License:** MIT. Safe for commercial distribution.

---

### 3.6 Biome

**[Fact]** Biome parses JS/TS/JSX into a **lossless concrete syntax tree** using an internal
fork of `rowan`, implementing the green/red tree pattern. The green tree contains every
character of the original source, whitespace and comments included, and is immutable with
structural sharing between identical subtrees.
<https://biomejs.dev/internals/architecture/> ·
<https://deepwiki.com/biomejs/biome/6.1-parser-architecture> ·
<https://github.com/domenicquirl/cstree>

**[Fact]** Trivia is attached to nodes as leading and trailing trivia rather than being
discarded. "The CST ... keeps track of all the information of a program, trivia included."
<https://biomejs.dev/internals/architecture/>

**[Fact — NEW, resolves the earlier `[Unverified]` on error tolerance]** The `biome_js_parser`
crate-level documentation, verbatim:

> Extremely fast, lossless, and error tolerant JavaScript Parser.
> …
> The parser is able to produce a valid AST from **any** source code.
> Erroneous productions are wrapped into `ERROR` syntax nodes, the original source code
> is completely represented in the final syntax nodes.

and among the listed features: "Completely error tolerant, able to produce an AST from any
source code", "Ability to do Lossy or Lossless parsing on demand without explicit whitespace
handling", "Cheap incremental reparsing of changed text".
<https://github.com/biomejs/biome/blob/main/crates/biome_js_parser/src/lib.rs>

**[Fact]** The architecture page distinguishes *resilient* ("able to resume parsing after
encountering syntax errors") from *recoverable* ("able to **understand** where an error occurred
and … resume the parsing by creating **correct** information"), and adds: "The parser also uses
'Bogus' nodes to protect the consumers from consuming incorrect syntax. These nodes are used to
decorate the broken code caused by a syntax error."
<https://biomejs.dev/internals/architecture/>

**[Fact — NEW, position model]** `biome_rowan::TextSize` documents itself as "a UTF-8 bytes
offset stored as `u32`". So Biome's coordinate system is **UTF-8 bytes**, matching DEC-024
exactly, with the same ~4 GiB ceiling as oxc.
<https://docs.rs/biome_rowan/latest/biome_rowan/struct.TextSize.html>

**[Fact — NEW, licensing]** Biome is **dual-licensed MIT OR Apache-2.0** — the repository root
contains both `LICENSE-MIT` and `LICENSE-APACHE`. (The GitHub API surfaces only `Apache-2.0`,
which is why a single-source check would mislead.) `LICENSE-MIT` names "Biome Developers and
Contributors (2023-present)" and "Rome Tools, Inc. and its affiliates (2020-2023)".
<https://github.com/biomejs/biome/blob/main/LICENSE-MIT>

**[Fact — NEW, standalone usability]** The crate docs steer callers to `parse_script`,
`parse_module`, `parse`, and `parse_js_with_cache` rather than the `Parser` struct itself
("You probably do not want to use the parser struct, unless you want to parse fragments of Js
source code"). The crate is part of a workspace of ~200 crates; whether `biome_js_parser` is
published to crates.io independently and at what cadence **could not be verified** (crates.io
did not render for automated fetch).

**[Fact — maintenance]** `biomejs/biome`, 25,391 stars, last push 2026-07-26, 503 open issues.
Weekly releases: `@biomejs/biome@2.5.5` (2026-07-21), 2.5.4 (2026-07-15), 2.5.3 (2026-07-08),
2.5.2 (2026-07-01), 2.5.1 (2026-06-23).

**[Fact — performance]** Slowest of the three Rust parsers in oxc's benchmark: `cal.com.tsx`
16.7 ms (4.97× oxc), `typescript.js` 130.1 ms (4.94× oxc); memory 22.5 MB / 117.4 MB.
<https://github.com/oxc-project/bench-javascript-parser-written-in-rust>

**[Interpretation]** Biome remains architecturally the closest existing thing to what DEC-024
wants: a tree that *is* a total representation of the bytes rather than a structure that happens
to carry positions, in UTF-8, with documented total error tolerance and named `ERROR`/`Bogus`
nodes. Roslyn's full-fidelity trees and rust-analyzer's rowan are the same lineage. Its costs
are equally concrete: it is the slowest and most memory-hungry of the Rust three (though 16.7 ms
for a large TSX file is still fine for our workload); it has **no JS binding for the parser**
(the npm package ships a linter/formatter CLI, not a parse API) and **no Swift binding**; and
adopting it means a **Rust toolchain that is not currently installed**, plus writing a C-ABI
shim. Note also that "lossless CST" removes the need for gap-filling but does *not* remove the
need for the P-2 partition assertion — Biome's own `Bogus` nodes are the analogue of the
zero-width problem and must be checked, not assumed.

---

## 4. Position coordinate systems — the cross-cutting table

This is the axis most likely to produce a silent, corpus-specific correctness failure, and the
one where documentation is least reliable.

| Candidate / binding | Unit actually reported | Documented as | Native? |
|---|---|---|---|
| tree-sitter, C / Rust / **Swift** | **UTF-8 bytes** | bytes | yes |
| tree-sitter, **node-tree-sitter** | **UTF-16 code units** (`start_byte / 2`) | "byte offset" ❌ | no — parses as UTF-16LE |
| tree-sitter, **web-tree-sitter** | **UTF-16 code units** (`byte >> 1`) | "byte index" ❌ | no — parses as UTF-16LE |
| tree-sitter `Point.column`, JS bindings | **UTF-16 code units** | column | no |
| TypeScript compiler API (JS) | **UTF-16 code units** (JS string indices) | — | n/a |
| @babel/parser `start`/`end`/`range` | **UTF-16 code units** | "character indices" | n/a |
| @babel/parser `loc.column` | **UTF-16 code units** | column | n/a |
| SWC, Rust `BytePos` | **UTF-8 bytes**, but **global across the SourceMap**, not per file | bytes | yes-ish |
| SWC, `@swc/core` JS | UTF-8 bytes, **offset by all prior parses in the process** | — | no |
| oxc, Rust `Span` | **UTF-8 bytes**, `u32`, per file | bytes | **yes** |
| oxc, `oxc-parser` napi | **UTF-16 code units** (converter on by default since 2025-02) | — | no |
| Biome, `TextSize` | **UTF-8 bytes**, `u32` | "UTF-8 bytes offset stored as u32" ✅ | **yes** |

**[Interpretation]** Three observations.

1. **Every JavaScript-side option reports UTF-16 code units.** There is no Node/Electron path to
   a byte-native parser. The choice on a JS stack is only *whose* conversion layer you trust —
   your own, node-tree-sitter's, or oxc's.
2. **Two of the eleven rows are actively mis-documented** (both tree-sitter JS bindings). Any
   spike must verify the coordinate system by *measurement on non-ASCII input*, never by reading
   the type declarations.
3. **UTF-8-byte-native and Swift-callable are currently disjoint sets.** tree-sitter is
   Swift-callable and byte-native via its C API; oxc and Biome are byte-native but need a shim;
   nothing is both out of the box except tree-sitter.

---

## 5. Error recovery — the decisive comparison

The concrete question from the brief: **what does each produce for a JSX file truncated
mid-element?**

| Candidate | Behaviour on truncated JSX | Evidence class |
|---|---|---|
| **TypeScript** | Never throws. Returns a tree covering the whole input, with located diagnostics ("JSX element 'span' has no corresponding closing tag", "'</' expected"). 76% of AST nodes survive in the worked example. **0 throws / 4,800 truncation points.** | **Measured** |
| **tree-sitter** | Always returns a tree. Unrecognized text becomes `ERROR` nodes; anticipated-but-absent tokens become zero-width `MISSING` nodes. Robustness under syntax errors is a stated design goal. Difftastic's `DFT_PARSE_ERROR_LIMIT` mode proves structural diffing over ERROR-containing trees is workable in practice. | Documented + third-party corroboration; **not run here** |
| **Biome** | Documented total tolerance: "able to produce an AST from **any** source code"; erroneous productions wrapped in `ERROR` nodes; `Bogus` nodes decorate broken code; "the original source code is completely represented in the final syntax nodes". | Documented; **not run here** |
| **oxc** | Binary. Recoverable → full AST + non-empty `diagnostics`, `panicked: false`. Unrecoverable → **empty `Program`**, `panicked: true`. Which category truncated JSX falls into is **unknown**. Recovery is curated per-error and has been *removed* from some errors. | Documented; **not run here** |
| **SWC** | "Can recover from **some** parsing errors" (own docs; example is a missing comma before a newline). Active work as recently as 2026-01. Historical panic on malformed TS (#1170). No published statement about JSX/TSX truncation. | Documented, weak; **not run here** |
| **@babel/parser** | **Throws on 4,400 / 4,800 truncation points (91.67%)** with `errorRecovery: true`. The option covers early/semantic errors (`DuplicateProto`, `InvalidLhs`, `IllegalReturn`, `AwaitNotInAsyncContext`, `StrictDelete`), not tokenizer/structural errors. `const a = <div className="x">` throws `UnexpectedToken` either way. | **Measured** |

**[Interpretation]** On the criterion the brief calls most important, the ranking of *verified*
evidence is: TypeScript (proven total, on this corpus) > Biome (documented total) ≈ tree-sitter
(documented robust, corroborated by difftastic) > oxc (documented partial, unknown for JSX) >
SWC (documented weak) > Babel (**measured near-total failure**). This is a ranking of evidence
quality as much as of capability, and P-1 exists to level it.

One structural note that cuts across all of them: a parser that returns *something* is necessary
but not sufficient. What DiffScope needs is a *localized* failure — the diagnostics or ERROR
nodes must have ranges, so the fallback can be regional rather than whole-file. TypeScript's
diagnostics carry `start`/`length`; tree-sitter's ERROR nodes carry ranges; oxc's `panicked` path
carries nothing at all, because the program is empty.

---

## 6. Language bindings

| Candidate | Swift | Node / Electron | Notes |
|---|---|---|---|
| tree-sitter | **First-party.** `tree-sitter/swift-tree-sitter` (BSD-3-Clause) + SPM manifests in core and in `tree-sitter-typescript` (`TreeSitterTypeScript` **and** `TreeSitterTSX` targets). | `web-tree-sitter` (WASM, tracks core, 0.26.11) or `tree-sitter` (native addon, lags at 0.25.0 / repo release v0.22.4 from 2024-12-30). | Only candidate with a zero-glue Swift path. JS bindings impose UTF-16. |
| TypeScript | None. Options: run `typescript.js` in **JavaScriptCore** (a macOS system framework — no extra runtime to ship), spawn Node, or (TS 7) speak the JSON-RPC/msgpack API server protocol. | Native — it *is* a Node library. | TS 7's out-of-process API is arguably a *better* Swift story than any FFI, but it is "not ready". |
| @babel/parser | None. Same JavaScriptCore / subprocess options. | Native. | |
| SWC | None. Rust → C ABI shim required. | `@swc/core` (napi). Global-span hazard applies. | Maintainer has said the JS `parse` API is not a long-term surface. |
| oxc | None. Rust → C ABI shim required. | `oxc-parser` (napi + WASM). UTF-16 conversion on by default. | |
| Biome | None. Rust → C ABI shim required. | **No parser API published to npm** — the npm package is the CLI. | Heaviest integration cost of the set. |

**[Fact]** No `Package.swift` exists at the repository root of `oxc-project/oxc`,
`swc-project/swc`, `biomejs/biome`, or `babel/babel` (HTTP 404 for all four, 2026-07-26).

**[Interpretation]** The stack decision and the parser decision are **not independent**, and
this table is the coupling. Roughly:

- *Swift stack* → tree-sitter is the only low-friction option; everything else means either a
  Rust toolchain plus an FFI shim, or embedding a JS engine.
- *Node/Electron stack* → TypeScript, Babel, oxc and (with care) SWC are all one `import` away;
  tree-sitter is available but only in UTF-16; Biome is effectively unavailable.
- *Rust engine (either stack)* → oxc and Biome become byte-native and the conversion layer
  disappears, at the cost of a toolchain prerequisite and, for a Swift UI, an FFI boundary.

---

## 7. Licensing — assessed against possible future public/commercial distribution

| Component | License | Copyleft? | Verdict for closed-source commercial distribution |
|---|---|---|---|
| tree-sitter core | MIT | no | fine |
| tree-sitter-typescript (grammar) | MIT | no | fine |
| web-tree-sitter / node-tree-sitter | MIT | no | fine |
| swift-tree-sitter | BSD-3-Clause | no | fine (attribution + no-endorsement clause) |
| TypeScript (5/6/7, and typescript-go) | Apache-2.0 | no | fine; includes an express patent grant |
| @babel/parser | MIT | no | fine |
| SWC | Apache-2.0 | no | fine; patent grant |
| oxc | MIT | no | fine |
| Biome | **MIT OR Apache-2.0** (dual) | no | fine; pick either |
| **GumTree** (matching algorithm reference impl.) | **LGPL-3.0** | **YES — weak copyleft** | ⚠️ see below |
| difftastic | (not a dependency candidate — binary-only crate, see `domain-existing-tools.md` §5.10) | — | — |

**⚠️ [Fact] GumTree is LGPL-3.0.** Every source file carries the header: "GumTree is free
software: you can redistribute it and/or modify it under the terms of the GNU Lesser General
Public License as published by the Free Software Foundation, either version 3 of the License, or
(at your option) any later version."
<https://github.com/GumTreeDiff/gumtree/blob/main/LICENSE>

**[Interpretation]** No parser candidate carries any distribution risk. The copyleft exposure is
entirely on the **algorithm** side, and it is real:

- **Linking** GumTree (as a JVM library) into a distributed product triggers LGPL-3.0's relinking
  and source-availability obligations for the GumTree portion, plus the anti-tivoisation terms
  of GPLv3 that LGPL-3.0 incorporates. For a notarized, sandboxed macOS app this is
  awkward-to-hostile.
- **Reading the papers and implementing the algorithm independently** is unaffected. Algorithms
  are not copyrightable; the ASE 2014 and ICSE 2024 papers plus the published pseudocode are the
  intended route.
- **Reading the GumTree source and porting it** is the dangerous middle ground and should be
  explicitly avoided in favour of paper-driven implementation, with the constraint written into
  the decision log rather than left to an implementer's judgement.

The same caution applies to RefactoringMiner (whose tie-breaking technique
`domain-existing-tools.md` §5.8 recommends stealing) — its license was **not verified** in this
pass; see Open questions.

---

## 8. Performance and memory — consolidated

| Source | Figure |
|---|---|
| oxc benchmark, M3 Max, `cal.com.tsx` | oxc **3.4 ms** · swc 13.4 ms · Biome 16.7 ms |
| oxc benchmark, M3 Max, `typescript.js` | oxc **26.3 ms** · swc 84.1 ms · Biome 130.1 ms |
| oxc benchmark, peak memory | oxc 11.5 / 68.8 MB · swc 16.6 / 92.0 MB · Biome 22.5 / 117.4 MB |
| oxc napi UTF-16 converter cost | ~1.09× (`checker.ts`: 31.9 ms on vs 29.3 ms off) |
| **Measured here**, TypeScript on 561 KiB of real TSX (159 files) | 13.2–13.8 ms → **~40 MiB/s** |
| **Measured here**, Babel on the same corpus | 18.9 ms → **~29 MiB/s** |
| **Measured here**, TypeScript, largest single file (51.3 KiB), warm | **0.3 ms** |
| **Measured here**, TypeScript retained heap, 159 ASTs with parent pointers | 4.5 MiB for 0.55 MiB source ≈ **8.2×** |
| tree-sitter | **No published figures found.** Only the qualitative goal "fast enough to parse on every keystroke in a text editor". |

**[Interpretation]** Parsing is not the bottleneck for this product and the benchmark spread is
mostly irrelevant to it. DiffScope parses **two versions of one file** per refresh. Even the
slowest candidate on the largest realistic TSX file is ~17 ms; TypeScript does a typical 50 KiB
file in 0.3 ms. The published Rust benchmarks measure throughput on a 10 MB `typescript.js`,
which is not our workload. What *should* drive the budget is the tree-matching stage — see
`domain-existing-tools.md` §1.1.6 (difftastic's O(L·R) graph, 3M-vertex cliff, and the
composer.lock incident that ate 64 GB) and §1.2.2 (GumTree's O(n³) recovery). **The parser is a
rounding error; the matcher is the cliff.** Choosing a parser on speed would be optimising the
wrong stage.

---

## 9. Maintenance activity

| Project | License | Stars | Latest release | Last activity | Open issues | Bus-factor read |
|---|---|---|---|---|---|---|
| tree-sitter (core) | MIT | 26,430 | v0.26.11, 2026-07-12 | push 2026-07-25 | 132 | Healthy; ~monthly releases. |
| **tree-sitter-typescript** | MIT | 526 | **v0.23.2, 2024-11-11** | **`master` commit 2025-01-30** | **47** | ⚠️ Quiet ~18 months. This is the grammar we need. |
| node-tree-sitter | MIT | 864 | v0.22.4, 2024-12-30 | push 2026-03-29 | 19 | ⚠️ Lags core by 4 minor versions. |
| swift-tree-sitter | BSD-3 | 408 | 0.10.0, 2026-03-18 | commits 2026-05-26 | 3 | Small but alive; now under the tree-sitter org (good sign). Release gap 2024-11 → 2026-03. |
| TypeScript (5/6) | Apache-2.0 | 109,961 | — | push 2026-07-23 | 5,059 | Corporate-backed; no bus-factor risk. |
| typescript-go (TS 7) | Apache-2.0 | 26,065 | typescript/v7.0.2, 2026-07-08 | push 2026-07-26 | 268 | Corporate-backed; **API "not ready"**. |
| @babel/parser | MIT | 43,958 | 8.0.4, 2026-07-09 | push 2026-07-24 | 764 | Very healthy, huge contributor base. |
| SWC | Apache-2.0 | 34,144 | 1.15.46, 2026-07-19 | push 2026-07-26 | 408 | Healthy but historically kdy1-centric. |
| oxc | MIT | 22,119 | 0.141.0, 2026-07-21 | push 2026-07-26 | 703 | Very fast-moving; **703 open issues and weekly breaking-ish releases** — high churn is itself a risk. |
| Biome | MIT OR Apache-2.0 | 25,391 | 2.5.5, 2026-07-21 | push 2026-07-26 | 503 | Healthy, weekly cadence, community-governed. |
| GumTree | **LGPL-3.0** | 1,322 | — | push 2026-07-23 | 21 | Academic; alive. |

---

## 10. Comparison table (all criteria)

Legend: ✅ good · ⚠️ caveat · ❌ bad · ? unverified.

| Criterion | tree-sitter | TypeScript API | Babel | SWC | oxc | Biome |
|---|---|---|---|---|---|---|
| **Coordinate system (native lib)** | ✅ UTF-8 bytes | ⚠️ UTF-16 | ⚠️ UTF-16 | ⚠️ UTF-8 but **global** | ✅ UTF-8 bytes | ✅ UTF-8 bytes |
| **Coordinate system (JS binding)** | ❌ UTF-16, **mis-documented** | ⚠️ UTF-16 | ⚠️ UTF-16 | ❌ global offset | ⚠️ UTF-16 by default | — no JS parser API |
| **Ranges exact & complete** | ⚠️ gaps (whitespace is `extras`) | ⚠️ tiles, but JSDoc aliases trivia (2.73% naive failure, **measured**) | ⚠️ token gaps + comments out-of-band | ? | ? | ✅ lossless CST by design |
| **Zero-width artifacts excludable** | ⚠️ `MISSING`, flagged via `ts_node_is_missing` | ✅ `pos===end`; recovery nodes also flagged | ⚠️ EOF only | ? | ? | ⚠️ `Bogus` nodes, unverified shape |
| **Error recovery on truncated JSX** | ✅ documented robust (not run) | ✅✅ **0/4,800 throws, measured** | ❌ **91.67% throw, measured** | ⚠️ "some errors" | ⚠️ binary; empty program if `panicked` | ✅ documented total (not run) |
| **Localized failure (ranged diagnostics)** | ✅ ERROR node ranges | ✅ `start`/`length` per diagnostic | ❌ single throw | ⚠️ error list | ❌ nothing when panicked | ✅ ERROR/Bogus node ranges |
| **Incremental reparse** | ✅ (but see #4001) | ⚠️ `updateLanguageServiceSourceFile` exists, untested | ❌ | ❌ | ❌ | ✅ documented |
| **Swift callable** | ✅ first-party SPM | ⚠️ JavaScriptCore / subprocess / TS7 RPC | ⚠️ same | ❌ shim needed | ❌ shim needed | ❌ shim needed |
| **Node callable** | ✅ two bindings | ✅ native | ✅ native | ⚠️ span hazard | ✅ native | ❌ |
| **New toolchain required** | no (C; Swift/Node both fine) | no | no | **Rust** (unless via npm) | **Rust** (unless via npm) | **Rust — mandatory** |
| **License** | ✅ MIT / BSD-3 | ✅ Apache-2.0 | ✅ MIT | ✅ Apache-2.0 | ✅ MIT | ✅ MIT OR Apache-2.0 |
| **Perf (large TSX)** | ? no figures | ✅ 0.3 ms / 51 KiB measured | ⚠️ ~1.4× slower than TS | ⚠️ 13.4 ms | ✅ 3.4 ms | ⚠️ 16.7 ms |
| **Maintenance** | ⚠️ core ✅, **grammar quiet 18 mo** | ✅ corporate; ⚠️ **TS 7 API discontinuity** | ✅ | ✅ | ⚠️ very high churn | ✅ |
| **Normalization risk (DEC-021)** | none found | none found | none found | none found | none found | none found |

---

## 11. Tree-matching algorithms — the selection angle

`domain-existing-tools.md` §1.2–1.3 already records *what these algorithms get wrong* and the
measured accuracy numbers. **That is not repeated here.** This section covers only what that
document lacks: how to *choose* among them, given DEC-024 and the 76%-repeated-siblings finding.

### 11.1 The complexity ladder, and what each rung buys

**[Fact]** Classical tree edit distance (Tai; Zhang–Shasha) is defined over **insert, delete,
rename only**. **Move is not an operation in the classical model.**
<https://vldb.org/pvldb/vol5/p334_mateuszpawlik_vldb2012.pdf>

| Algorithm | Complexity | Moves? | Optimal? |
|---|---|---|---|
| Zhang–Shasha (1989) | **O(n²m²)** time, O(nm) space | ❌ | ✅ optimal for insert/delete/rename |
| Klein (1998) | O(nm log n) | ❌ | ✅ |
| Demaine et al. (2007) | O(nm log² n) | ❌ | ✅ |
| RTED (Pawlik & Augsten, VLDB 2012) | O(n³) worst case; optimal path strategy | ❌ | ✅ |
| Chawathe et al. (1996), *LaDiff* | matching + **quadratic, optimal edit-script derivation given the matching** | ✅ **subtree move** | ✅ only *given* the matching |
| GumTree (2014) | greedy top-down + bottom-up; O(n³) recovery gated at `max_size` | ✅ | ❌ heuristic |
| Any model with move | — | ✅ | ❌ **finding the shortest transformation is NP-hard** (Falleri et al. 2014) |

**[Fact]** Chawathe et al. (1996) define the problem as finding a *minimum-cost edit script*
with four operations: node delete, node insert, node update, and **subtree move**; the system is
named LaDiff. It splits into two sub-problems, "a good matching" and "minimum cost edit script
computing".
<https://dl.acm.org/doi/10.1145/235968.233366> ·
<https://sigmodrecord.org/1996/06/24/change-detection-in-hierarchically-structured-information/>

**[Fact, from `domain-existing-tools.md` §1.2.3]** GumTree reuses **Chawathe's second step**
(edit-script derivation, quadratic and optimal *given* the mappings) and replaces the first. The
GumTree paper states Chawathe's own matching requires "acyclic labels and leaf nodes containing
a lot of text" — assumptions that do not hold for fine-grained ASTs of general-purpose
languages.

**[Interpretation — the selection consequence]** The literature has already made the choice for
us, and the reason is worth stating explicitly rather than inheriting:

- **Zhang–Shasha and its descendants are the wrong shape, not merely too slow.** They produce an
  optimal *distance*, without moves. For DiffScope, move detection is a headline feature
  (`14-losslessness-and-trust-model.md` §7.3, OQ-026), so an algorithm whose model cannot express
  a move is disqualified at the modelling layer regardless of complexity. The O(n²m²) figure is a
  secondary objection.
- **The matching/script-derivation split is the durable part.** Chawathe's second step is cheap
  and optimal *given* a matching. Every subsequent tool (GumTree, MTDIFF, IJM, RefactoringMiner)
  keeps it and competes only on the matching. So the engineering question is not "which tree-diff
  algorithm" but **"which matcher, plus Chawathe-style script derivation"**.
- **Once moves are in the model, optimality is off the table permanently.** Falleri et al. state
  "finding the shortest transformation is NP-hard"; the difftastic manual separately cites the
  survey result that unordered tree diffing is NP-hard and MAX SNP-hard. Everything after that
  point is a cost model, i.e. **taste** — which is why `domain-existing-tools.md` §5.9 budgets
  continuous effort for it.
- **RTED remains useful in one narrow role**: as an *oracle* for small subtrees in tests, where
  an optimal insert/delete/rename distance gives a ground truth to measure the heuristic
  matcher's regressions against. Not as the engine.

**[Fact]** Hyperparameters are not a detail. Martinez, Falleri & Monperrus, *"Hyperparameter
Optimization for AST Differencing"* (IEEE TSE, 2023; arXiv 2011.10268) present DAT (Diff Auto
Tuning) and report: "DAT is able to find a new configuration for GumTree that improves the
edit-scripts in **21.8% of the evaluated cases**."
<https://arxiv.org/abs/2011.10268>

**[Interpretation]** A fifth of cases improved by *tuning alone*, with no algorithmic change,
means the defaults are not a neutral starting point and that any comparison of matchers that
uses default hyperparameters is measuring configurations, not algorithms. If DiffScope
implements a GumTree-family matcher, the thresholds must be treated as tunable product
parameters with their own fixture corpus — not as constants copied from a paper.

### 11.2 Moves: how each family handles them

- **Classical TED (Zhang–Shasha, Klein, Demaine, RTED):** no move. A relocated subtree is
  delete + insert. For DiffScope this would violate nothing (the bytes are still all present)
  but would destroy the feature.
- **Chawathe / LaDiff:** `move` is primitive and takes the whole subtree. Optimal script *given*
  the matching.
- **GumTree:** `move(t, tp, i)` takes the whole subtree by definition. Whether the subtree's
  *internal* edits survive depends entirely on whether the mapping step matched the descendants
  — and per `domain-existing-tools.md` §1.2.2 the recovery phase that finds those descendant
  mappings is exactly the part that aborts on large subtrees. The `simple` bottom-up matcher
  "does not consider changes of nesting" at all, degrading genuine moves into insert+delete.
- **VS Code's `MovedText`** (`domain-existing-tools.md` §1.6.1) is the one clean positive
  precedent: the move carries `changes: DetailedLineRangeMapping[]` alongside its ranges.

**[Interpretation — selection consequence, and it is a hard constraint]** Under DEC-024 a move
must **regroup** segments, never **replace** them. That is a stronger requirement than any of
these algorithms provides natively: all of them emit an *edit script*, and an edit script is a
list of operations, not a partition. The practical implication is that the matcher's output must
be consumed as **a mapping (node ↔ node), not as an edit script.** The mapping is what DiffScope
can project onto its byte partition; the script is a lossy rendering of the mapping and would
reintroduce exactly the "move swallows its delta" failure documented for SemanticDiff and Git.
Chawathe's second step, which turns a mapping into a script, is therefore something we should
**not** adopt — we need the first step only.

### 11.3 Repeated identical subtrees — the common case

`domain-existing-tools.md` §1.3.2 establishes the frequency: **752 of 988 commits (76%)** in the
TOSEM 2024 benchmark contain at least one case of identical repeated statements. What follows is
how the algorithms actually resolve it, read from source.

**[Fact]** GumTree's top-down phase explicitly partitions candidates into **unique** and
**ambiguous** buckets and defers the ambiguous ones:

```java
// AbstractSubtreeMatcher.match
localHashMappings.unique().forEach(pair ->
    mappings.addMappingRecursively(pair.first.stream().findAny().get(), ...));
localHashMappings.ambiguous().forEach(pair -> ambiguousMappings.add(pair));
...
handleAmbiguousMappings(ambiguousMappings);
```
<https://github.com/GumTreeDiff/gumtree/blob/main/core/src/main/java/com/github/gumtreediff/matchers/heuristic/gt/AbstractSubtreeMatcher.java>

**[Fact]** `GreedySubtreeMatcher.handleAmbiguousMappings` sorts ambiguous *groups* by largest
source subtree first (`AmbiguousMappingsComparator`), then sorts the cartesian product of
candidate pairs with `FullMappingComparator` and assigns greedily, first-come-first-served:

```java
candidates.sort(comparator);
candidates.forEach(mapping -> {
    if (mappings.areBothUnmapped(mapping.first, mapping.second))
        mappings.addMappingRecursively(mapping.first, mapping.second);
});
```
<https://github.com/GumTreeDiff/gumtree/blob/main/core/src/main/java/com/github/gumtreediff/matchers/heuristic/gt/GreedySubtreeMatcher.java>

**[Fact]** `FullMappingComparator` is a **five-level deterministic tie-break chain**, applied in
this order:

1. `SiblingsSimilarityMappingComparator` — Dice coefficient over the two candidates' *parents'*
   already-mapped descendants (returns 0 immediately if both candidates share the same parent
   pair).
2. `ParentsSimilarityMappingComparator` — ancestor similarity.
3. `PositionInParentsSimilarityMappingComparator` — relative position within the parent.
4. `TextualPositionDistanceMappingComparator` — textual position distance.
5. `AbsolutePositionDistanceMappingComparator` — absolute position distance.

<https://github.com/GumTreeDiff/gumtree/blob/main/core/src/main/java/com/github/gumtreediff/matchers/heuristic/gt/MappingComparators.java>

**[Fact]** GumTree ships several matcher compositions, registered by id:
`gumtree-simple` = GreedySubtree + SimpleBottomUp (**default**, `Priority.MAXIMUM`);
`gumtree-classic` = GreedySubtree + GreedyBottomUp; `gumtree-simple-stable` = GreedySubtree +
SimpleMarriageBottomUp; `gumtree-hybrid`; `gumtree-classic-theta` (adds LCS, unmapped-leaves,
inner-nodes, leaf-move and cross-move matchers).
<https://github.com/GumTreeDiff/gumtree/blob/main/core/src/main/java/com/github/gumtreediff/matchers/CompositeMatchers.java>

**[Interpretation — four selection consequences]**

1. **Ambiguity detection is free; ambiguity *resolution* is the product decision.** GumTree
   already computes the ambiguous set exactly (hash-equal subtrees with >1 candidate on either
   side). DiffScope's OQ-027 policy — "ambiguity lowers confidence; it never resolves
   arbitrarily" — maps directly onto that set. We can surface "N equally-good alignments" without
   inventing any machinery, because the matcher hands us the set for free. **No surveyed tool
   exposes this**, and it is the cheapest differentiator in the entire design.
2. **The tie-break chain is context-based, not similarity-based, and that is the right lesson.**
   Note the convergent evolution: GumTree's `FullMappingComparator` (siblings → ancestors →
   position-in-parent → textual position → absolute position) and RefactoringMiner's tie-breakers
   (`domain-existing-tools.md` §1.3.2: identity of preceding/following statements, then
   Levenshtein of ancestors at increasing depth) are the *same idea* arrived at independently.
   Two independent designs landing on "disambiguate identical siblings by their context, not by
   their content" is the strongest signal in this literature. It is also cheap and
   language-agnostic.
3. **Greedy first-come-first-served resolution is deterministic but order-dependent.** The
   assignment depends on the sort order of the ambiguous groups. That is acceptable — DEC
   requires *determinism*, not optimality — but it means the ordering must be pinned, documented,
   and regression-tested, or a comparator change silently re-alignments every repeated-sibling
   case in the corpus.
4. **`minHeight = 2` is hostile to JSX and must be revisited.** GumTree's default exists "to
   avoid matching remaining leaf expressions with height 1 (e.g. `SimpleName` nodes), which
   coincidentally have the same value" (Alikhanifard & Tsantalis, TOSEM 2024, who lower it to 1
   and add a type guard). A JSX sibling like `<Item />` is a *height-1-or-2 subtree that is
   supposed to be matched*. Inheriting the Java-derived default would make DiffScope worst
   exactly where its corpus is densest. This is a concrete, testable hypothesis, not a hunch —
   spike P-6.

### 11.4 What this means for algorithm selection, stated plainly

**[Interpretation]** The honest reading of §11 plus `domain-existing-tools.md` §1.3 is that
**no published matcher is good enough to adopt as-is**, and the numbers say so: GumTree 3.0
greedy achieves a fully-correct fine-grained mapping in **4.8–18.1%** of commits on the TOSEM
benchmark. That is not a reason to despair, because DiffScope's guarantee is *coverage*, not
*mapping correctness* — a bad mapping produces an ugly diff, never a wrong one. But it does
reframe the selection:

- Do not shop for the most accurate matcher. Shop for the one whose **failure mode is most
  legible** and whose **ambiguity is most exposable**.
- Prefer the GumTree family for that reason: its ambiguity set is explicit, its tie-breaks are
  inspectable, and its failure modes are the best-documented in the literature (by its own
  authors).
- Treat the matcher as **replaceable**. The interface it must satisfy — take two trees, return a
  node↔node mapping plus an ambiguity set — is small. Committing to that interface, rather than
  to an algorithm, is the actual architecture decision.

---

## 12. Open questions

Things I could not determine from primary sources in this pass. Ordered by how much they block
the decision.

- **OQ-P1 — What does oxc return for truncated TSX: a partial AST or `panicked: true` with an
  empty program?** This single answer could move oxc from "strong candidate" to "unusable for
  DEC-007". Not determinable from docs; requires running it.
- **OQ-P2 — Does tree-sitter's TSX grammar actually recover usefully on half-typed JSX, and how
  large is the ERROR span?** Documented robustness is not a measurement. Difftastic's
  `DFT_PARSE_ERROR_LIMIT` mode is third-party corroboration, not evidence about TSX.
- **OQ-P3 — Does Biome's `Bogus`/`ERROR` node set include zero-width nodes?** If it does, Biome
  has the same exclusion requirement as tree-sitter despite the "lossless" framing.
- **OQ-P4 — Is `biome_js_parser` published to crates.io independently, at what version, and is
  it semver-stable?** crates.io did not render for automated fetch. If it is workspace-internal,
  the integration cost rises sharply.
- **OQ-P5 — What is the TypeScript 7 `unstable/ast` surface?** Does it expose `pos`/`end`,
  trivia, and parse diagnostics, and in what coordinate system? The npm export map proves the
  subpath exists; nothing verified its contents.
- **OQ-P6 — Is `updateLanguageServiceSourceFile` (TypeScript's incremental reparse) subject to
  an analogue of tree-sitter #4001** — i.e. can it produce diagnostics a fresh parse would not?
- **OQ-P7 — RefactoringMiner's license.** `domain-existing-tools.md` §5.8 recommends adopting its
  tie-breaking technique. The technique is described in the TOSEM 2024 paper (safe to implement
  from), but the license was not checked and should be before anyone reads its source.
- **OQ-P8 — Does any candidate normalize inside the parser?** I found no evidence that any of
  them applies Unicode normalization to identifiers or string literals. But I checked for it
  only incidentally; a targeted check (parse a file containing `U+005A U+0307` and one
  containing `U+017B`, confirm the raw slices differ) belongs in P-2.
- **OQ-P9 — tree-sitter performance figures.** None published. The qualitative claim
  ("fast enough to parse on every keystroke") is almost certainly sufficient for our workload,
  but there is no number to put in a budget.
- **OQ-P10 — Whether `tree-sitter-typescript`'s ~18-month quiet period reflects "done" or
  "unmaintained".** 47 open issues including three JSX-relevant ones suggests the latter, but no
  maintainer statement was found either way.
- **OQ-P11 — Whether the `Point.column` UTF-16 shift in the tree-sitter JS bindings is
  documented anywhere.** I found the shift in source and the contradicting docstrings; I did not
  find an issue acknowledging it. If none exists, filing one is cheap and would de-risk everyone.

---

## 13. Recommended spikes

P-1, P-2 and P-3 are carried over from the PARTIAL version, refined with what is now known.
P-4…P-7 are new and are the ones that close the evidence asymmetry in §2.

| ID | Spike | Time box |
|---|---|---|
| **P-1** | **Broken-JSX survival test — all candidates.** Take ~120 real `.tsx` files from the corpus, truncate each at 40 evenly-spaced points (4,800 cases, the exact protocol already used for TypeScript and Babel in §3.2.5 / §3.3), and record per candidate: (a) did it return anything; (b) if so, what fraction of the AST/CST survived vs the untruncated parse; (c) the byte extent of the largest error region; (d) for oxc specifically, the `panicked` rate. **Reuse the measured TypeScript and Babel numbers as the calibration baseline** — any harness that does not reproduce 0/4,800 and 4,400/4,800 respectively is measuring something else. Requires installing Rust and the npm parsers. | **1 day** (was ½; scope grew because two candidates are already done and four are not) |
| **P-2** | **Byte-partition round-trip.** For each candidate, build the DEC-024 partition by construction (drop zero-width, clamp overlaps, fill gaps and tail from bytes) and assert no-gaps/no-overlaps/Σ = length **and** exact byte reconstruction, on the non-ASCII subset of the corpus. Must include: a non-BMP character (emoji), a decomposed sequence (`U+005A U+0307`), a CRLF file, and a file with a JSDoc block. **Report the filler percentage per candidate** — TypeScript's is 0.01%; a candidate needing materially more is telling you its ranges are coarse. Also serves as the OQ-P8 normalization check. | **1 day** (was ½; the JSDoc and decomposed-sequence cases are now known to be load-bearing) |
| **P-3** | **tree-sitter incremental defect (#4001).** Reproduce under a save-driven edit pattern; measure how often spurious ERROR nodes appear and what a fresh re-parse costs by comparison. Decide fresh-vs-incremental on the numbers. | **2 hours** |
| **P-4** | **Coordinate-system trap test.** For every candidate *and every binding of it we might use*, parse a file whose first line is pure ASCII and whose second contains Polish diacritics, an emoji, and a decomposed `Ż`; assert that the reported offset of a token on line 3 equals its true UTF-8 byte offset. **Expect node-tree-sitter, web-tree-sitter and oxc-parser to fail this**, per §4 — the spike's job is to confirm the failure is exactly `byte/2` (or the documented converter) and that a correction layer fixes it, not to discover it. | **3 hours** |
| **P-5** | **Swift reachability probe.** Build a minimal macOS target that (a) links `TreeSitterTSX` via SPM and prints byte ranges for a TSX file, and (b) parses the same file via TypeScript running in JavaScriptCore and prints its UTF-16 ranges. Compare against the P-2 ground truth. This is the cheapest way to make the stack decision and the parser decision stop blocking each other. | **1 day** |
| **P-6** | **`minHeight` / JSX sibling sensitivity.** Using whichever tree the P-1 winner produces, implement only GumTree's top-down phase plus the ambiguity partition, and measure on the corpus: how many JSX sibling groups are classified ambiguous at `minHeight` = 1 vs 2, and how often the five-level tie-break chain changes the assignment. Directly tests the §11.3(4) hypothesis and OQ-027. | **1 day** |
| **P-7** | **TypeScript 7 API reconnaissance.** Import `typescript@7`'s `unstable/ast` and `unstable/ast/scanner`, and separately drive the `tsgo` API server over its JSON-RPC/msgpack transport. Answer OQ-P5: are `pos`/`end`, trivia and parse diagnostics available, in what units, and is the RPC route viable from Swift? Re-run immediately before the Phase 7 decision, since this is the fastest-moving fact in the document. | **½ day** |

**[Interpretation]** P-1, P-2 and P-4 together are the decision. P-5 unblocks the stack coupling.
P-3, P-6 and P-7 are refinements that can follow the decision if time is short. If only one day
is available, run P-4 — it is the cheapest, it is the failure mode most likely to survive
undetected into production, and it eliminates candidate/binding combinations rather than merely
ranking them.

---

## 14. Sources

**tree-sitter**
- Docs / design goals — <https://tree-sitter.github.io/tree-sitter/>
- Grammar DSL (`extras`) — <https://tree-sitter.github.io/tree-sitter/creating-parsers/2-the-grammar-dsl.html>
- C API (`ts_node_is_missing`) — <https://github.com/tree-sitter/tree-sitter/blob/master/lib/include/tree_sitter/api.h>
- Issue #4001 (incremental spurious errors) — <https://github.com/tree-sitter/tree-sitter/issues/4001>
- web-tree-sitter UTF-16 shift — <https://github.com/tree-sitter/tree-sitter/blob/master/lib/binding_web/lib/tree-sitter.c>
- web-tree-sitter node docs — <https://github.com/tree-sitter/tree-sitter/blob/master/lib/binding_web/src/node.ts>
- node-tree-sitter encoding + `StartIndex` — <https://github.com/tree-sitter/node-tree-sitter/blob/master/src/parser.cc> · <https://github.com/tree-sitter/node-tree-sitter/blob/master/src/node.cc> · <https://github.com/tree-sitter/node-tree-sitter/blob/master/tree-sitter.d.ts>
- Swift binding — <https://github.com/tree-sitter/swift-tree-sitter>
- SPM manifests — <https://github.com/tree-sitter/tree-sitter/blob/master/Package.swift> · <https://github.com/tree-sitter/tree-sitter-typescript/blob/master/Package.swift>
- Grammar issues #306 / #320 / #340 — <https://github.com/tree-sitter/tree-sitter-typescript/issues>

**TypeScript**
- `types.ts` (`TextRange`, `Node`) — <https://github.com/microsoft/TypeScript/blob/main/src/compiler/types.ts>
- `parser.ts` (diagnostics, `createMissingNode`) — <https://github.com/microsoft/TypeScript/blob/main/src/compiler/parser.ts>
- `utilities.ts` (`skipTrivia`, `getTokenPosOfNode`) — <https://github.com/microsoft/TypeScript/blob/main/src/compiler/utilities.ts>
- Local `typescript@6.0.3` `lib/typescript.d.ts` (lines 3673–3679, 4310–4322)
- typescript-go / TypeScript 7 — <https://github.com/microsoft/typescript-go> · `internal/api/` — <https://github.com/microsoft/typescript-go/tree/main/internal/api>
- npm registry metadata for `typescript@7.0.2` — <https://registry.npmjs.org/typescript>

**Babel**
- Parser options — <https://babeljs.io/docs/babel-parser>
- Repo — <https://github.com/babel/babel>

**SWC**
- License — <https://github.com/swc-project/swc/blob/main/LICENSE>
- `swc_ecma_parser` crate docs — <https://github.com/swc-project/swc/blob/main/crates/swc_ecma_parser/src/lib.rs> · <https://rustdoc.swc.rs/swc_ecma_parser/struct.Parser.html>
- `BytePos` / `SourceMap` — <https://rustdoc.swc.rs/swc_common/struct.BytePos.html> · <https://rustdoc.swc.rs/swc_common/source_map/struct.SourceMap.html>
- Issue #1366 (global spans, open since 2021) — <https://github.com/swc-project/swc/issues/1366>

**oxc**
- Parser architecture — <https://oxc.rs/docs/learn/architecture/parser>
- `oxc_parser` crate docs (`ParserReturn`, `panicked`, 4 GiB) — <https://github.com/oxc-project/oxc/blob/main/crates/oxc_parser/src/lib.rs>
- napi README — <https://github.com/oxc-project/oxc/blob/main/napi/parser/README.md>
- PR #9291 (UTF-16 converter on by default) — <https://github.com/oxc-project/oxc/pull/9291>
- Issue #959 (native UTF-16 spans, closed as not planned) — <https://github.com/oxc-project/oxc/issues/959>
- UTF-16 conversion bug trail: #9093, #9112, #9110, #9376, #12436, #13236, #13237, #13241, #13340, #13344, #14768 — <https://github.com/oxc-project/oxc/issues>
- Cross-parser benchmark — <https://github.com/oxc-project/bench-javascript-parser-written-in-rust>

**Biome**
- Architecture — <https://biomejs.dev/internals/architecture/>
- Parser architecture (secondary) — <https://deepwiki.com/biomejs/biome/6.1-parser-architecture>
- `biome_js_parser` crate docs — <https://github.com/biomejs/biome/blob/main/crates/biome_js_parser/src/lib.rs>
- `biome_rowan::TextSize` — <https://docs.rs/biome_rowan/latest/biome_rowan/struct.TextSize.html>
- Licenses — <https://github.com/biomejs/biome/blob/main/LICENSE-MIT> (and `LICENSE-APACHE`)
- cstree / rowan background — <https://github.com/domenicquirl/cstree> · <https://dev.to/cad97/lossless-syntax-trees-280c>

**Tree matching**
- Chawathe et al., SIGMOD 1996 — <https://dl.acm.org/doi/10.1145/235968.233366> · <https://sigmodrecord.org/1996/06/24/change-detection-in-hierarchically-structured-information/>
- Pawlik & Augsten, RTED, VLDB 2012 (complexity ladder, no-move model) — <https://vldb.org/pvldb/vol5/p334_mateuszpawlik_vldb2012.pdf>
- Martinez, Falleri & Monperrus, *Hyperparameter Optimization for AST Differencing*, IEEE TSE 2023 — <https://arxiv.org/abs/2011.10268>
- GumTree source: `AbstractSubtreeMatcher`, `GreedySubtreeMatcher`, `MappingComparators`, `CompositeMatchers`, `ConfigurationOptions` — <https://github.com/GumTreeDiff/gumtree/tree/main/core/src/main/java/com/github/gumtreediff/matchers>
- GumTree license (LGPL-3.0) — <https://github.com/GumTreeDiff/gumtree/blob/main/LICENSE>
- Prior-art failure modes, accuracy numbers, and the 76% repeated-siblings figure — `research/domain-existing-tools.md` §1.2–1.3 (not repeated here)

**Measurement scripts** (scratchpad, not part of the repo)
`ts-probe.mjs` · `ts-zero.mjs` · `babel-probe.mjs` · `babel-recover.mjs` · `bench.mjs` ·
`sweep.mjs` · `sweep2.mjs` · `sweep3.mjs` · `diag.mjs` · `diag2.mjs`
