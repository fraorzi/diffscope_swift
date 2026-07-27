# 07 — Technical Research (synthesis)

**Status:** Phase 3 complete. This is a **synthesis and index**, not the research itself.
**Detail lives in `research/`.** Do not duplicate it here; add findings there and conclusions here.

| Source document | Scope | Confidence |
|---|---|---|
| [research/losslessness-invariant.md](research/losslessness-invariant.md) | Invariant formulation, Unicode | Measured on corpus |
| [research/domain-existing-tools.md](research/domain-existing-tools.md) | Existing tools, known failures | Primary sources, cited |
| [research/stack-desktop-and-rendering.md](research/stack-desktop-and-rendering.md) | Desktop stacks, diff rendering | Primary sources, cited |
| [research/git-integration-and-watching.md](research/git-integration-and-watching.md) | Read-only audit, EOL filters | Measured locally |
| [research/git-mechanism-and-watching.md](research/git-mechanism-and-watching.md) | Git mechanism, FSEvents | Measured locally |
| [research/parsers-and-tree-matching.md](research/parsers-and-tree-matching.md) | Parsers, coordinates, matching | Measured: 4800 truncations |

---

## 1. Conclusions that changed decisions

Findings that were not merely informative but forced or altered a decision.

| Finding | Effect |
|---|---|
| No tool models the byte partition as primitive; tree-with-positions loses trivia irreversibly | **DEC-024** — partition as primitive |
| `git diff` cleans the worktree side down to ODB form, not the reverse | **DEC-025 amended** |
| No read-only plumbing emits cleaned bytes; reproducing `git diff` needs executing repo-configured commands | **DEC-028** — raw fallback, rejected on security grounds |
| One WebStorm-shaped save = 5 FSEvents in ~11 ms; atomic replace leaves a window with no file | **DEC-026** — trailing edge + cap |
| `node_modules` is 93% of watched paths; exclusion limit is 8, corpus max is 3 | **DEC-027** |
| Edit scripts cannot be projected onto a byte partition without reviving the move trap | **DEC-029** — mapping only |
| GumTree is LGPL-3.0; all parsers are permissive | **DEC-030** — implement from papers |
| GumTree already computes `unique()`/`ambiguous()` and discards it; 76% of commits contain the case | **DEC-031** — surface ambiguity |
| `carrefour-inapp` is unborn HEAD, not detached; `symbolic-ref` succeeds and lies | Phase 0 correction; **OQ-050** |

## 2. Hard constraints established

**2.1 Coordinate systems are a stack-level disqualifier (OQ-052).**
Both tree-sitter **JavaScript** bindings return UTF-16 code units while typing them as bytes (`ts_node_start_byte(node) / 2`; `byte_to_code_unit(byte) { return byte >> 1 }`). C, Rust and **Swift** bindings are byte-native. TypeScript and oxc-in-Node are also UTF-16. On a 51%-non-ASCII corpus this corrupts the partition **silently**. The same parser is therefore safe or unsafe depending on the binding a stack forces — so this is an input to the stack decision, not only the parser decision.

**2.2 No parser tiles the file.**
Measured: TypeScript's naive leaf concatenation fails **2.73%** of truncations *and 4 of 120 valid files* — `JSDocComment` nodes alias the following token's leading trivia, producing a simultaneous gap and overlap. The DEC-024 construction (drop zero-width, clamp overlaps, fill from bytes) passes **0 / 4800** with 0.01% filler.
Consequence for spike design: **a spike testing only broken input would miss this**, because it also occurs on valid files.

**2.3 Error recovery separates the candidates sharply.**

| Parser | Behavior on 4800 truncation points |
|---|---|
| TypeScript | **Never throws (0/4800)**; ~76% of tree intact mid-JSX; located diagnostics |
| Babel `errorRecovery: true` | **Throws 4400/4800 (91.67%)** — identical to the option being off |
| oxc | Binary: unrecoverable → **empty `Program`, `panicked: true`** — worse than partial |
| tree-sitter | `ERROR` + zero-width `MISSING` nodes; recovers |

Babel's `errorRecovery` covers early/semantic errors (`DuplicateProto`, `InvalidLhs`, `IllegalReturn`), never `UnexpectedToken`/`Unterminated*` — and half-typed JSX is always the latter. This effectively disqualifies Babel under DEC-007, where invalid source is routine.

**2.4 Rendering: the decisive question is answered.**

| Component | External diff? |
|---|---|
| Monaco **diff editor** | Not via public API. Private override broke on 0.49; `monaco.d.ts` is the only versioned surface |
| Monaco, **two plain editors** + `IViewZone` + decorations | Yes, fully public — Monaco's own diff editor is built this way |
| `@codemirror/merge` 6.12.0 (2026-02-15) | Yes, `DiffConfig.override` — but returns bare ranges, no room for labels or confidence |
| CodeMirror 6, **two plain views** + decorations | Yes, no diff model at all |

**2.5 Performance is not where the risk is.**
Git spawn floor 6.2 ms; the 1.5 GB repository's status is 44 ms and is not the slowest. TypeScript parses a 51 KiB TSX file in 0.3 ms; the slowest Rust candidate handles a large file in 16.7 ms. **The cliff is the matcher, not the parser or Git.** Budget on node count, not bytes — difftastic #373 records a moderate lockfile consuming 64 GB.

## 3. Maintenance and licensing risk

- **Parsers: no licensing risk.** All MIT / Apache-2.0 / BSD-3; Biome dual MIT-OR-Apache.
- **GumTree: LGPL-3.0** — the only copyleft exposure, on the algorithm side. Addressed by DEC-030.
- **libgit2: GPL-2.0 with linking exception**, covering static and dynamic linking of *unmodified* libgit2. **Modifications remain GPL-2.0**, and implementing filter drivers may constitute modification. GPL v2 only, no "or later". GitHub reports `NOASSERTION`, so scanners will flag it.
- **libgit2 bindings for the likely stacks are stale**: SwiftGit2 last released 2019; nodegit last stable 2020. Healthy bindings (git2-rs, LibGit2Sharp) target languages ruled out. libgit2 v1.9 is the final v1.x; v2.0 breaks API and ABI.
- **libgit2 supports only built-in CRLF and IDENT filters, not external clean/smudge drivers.**
  **Corrected by measurement (X-4):** this was initially carried forward as though libgit2 would fail the DEC-025 case generally. It does not. On a repository with `text eol=crlf` active, libgit2's diff output was **identical to `git diff` (both 0 lines)**. Built-in CRLF is the common case and libgit2 handles it correctly. The residual gap is external filter drivers only — Git LFS, custom `filter.*.clean` — which remains untested and is already covered by DEC-028's raw fallback.
- **`tree-sitter-typescript` is stale** relative to tree-sitter core: last release 2024-11-11 (verified via the GitHub API 2026-07-27), last push 2025-08-29, 47 open issues including #306.
  **Correction (M0-1):** #306 was recorded here and elsewhere as "incorrect node ranges for multiline JSX". Fetching the issue showed it is actually **"JSX captures whitespaces in nested, multiline tags"** — a text-node concern, not a range defect. Measured across 1370 real `.tsx` files: **zero overlaps, 1370/1370 valid partitions.** Staleness remains a generic maintenance risk; it is no longer a specific correctness threat.
- **TypeScript 7 discontinuity:** npm `typescript@7.0.2` is the Go port — no `main`, no `types`, 20 native binary dependencies, `exports` reduced to `./lib/version.cjs` plus `unstable/*`. typescript-go's README lists the API as "not ready". A risk for a JS path; arguably an opportunity for a Swift path, since the API is an out-of-process JSON-RPC/msgpack server.

## 4. Interim position on OQ-010 (Git mechanism) — not a decision

**Updated after spike X-4** (see `22-experiment-log.md`), which removed the measurement asymmetry.

Both mechanisms are read-only clean on the operations tested, and both match `git diff` under a built-in CRLF filter. The picture then splits:

- **libgit2 wins** on unborn-HEAD handling — it exposes `head_is_unborn` as a first-class property, while the Git CLI's `symbolic-ref -q HEAD` idiom returns exit 0 and a branch that does not exist.
- **The CLI wins** on status performance (46 ms vs 264 ms on the 1.5 GB repository — libgit2 is 5.7× slower, contradicting the assumption that avoiding process spawn would favour it), on binding health for plausible stacks, on licensing under DEC-020, and on Raw-mode fidelity — where the CLI is the reference by definition.
- **Semantics differ by default:** libgit2 reports untracked directories expanded (165 entries) where `git status --porcelain` collapses them (63). Same repository, 2.6× difference in DEC-012's headline count. Whichever mechanism is chosen, this must be explicit.

The CLI leads on more criteria, and its two strongest are structural rather than incidental. But **the app needs a correct unborn-HEAD probe regardless of mechanism** — on the CLI route that means knowing not to trust `symbolic-ref`, and using `git rev-parse --verify HEAD` instead.

## 5. Open questions carried into Phase 3.5 and 7

OQ-008 (downgraded), OQ-010, OQ-033 (stack), OQ-046, OQ-048, OQ-050 (unborn HEAD), OQ-051 (status/diff disagreement), OQ-052 (coordinates), OQ-054 (case folding), plus OQ-P1…OQ-P11 in the parser document, led by oxc's `panicked` rate on truncated TSX.

## 6. What no amount of further reading will settle

These need running code, which is what Phase 3.5 is for:

- Whether a candidate rendering approach can actually draw this diff at acceptable speed.
- Whether a given binding's offsets are what its documentation claims.
- Whether tree-sitter's incremental-parse defect (#4001) fires under save-driven editing.
- Whether oxc returns an empty `Program` for realistic half-typed TSX.
- Whether live WebStorm saves match the simulated atomic-replace event pattern.
