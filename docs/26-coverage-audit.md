# 26 — Coverage audit

**Status:** First edition 2026-07-29 (M8-C). Authoritative for *where* each named test is proven and, more usefully, *what could fail it*.

A check nobody can fail proves nothing. Every row below therefore has two columns that matter: the check that runs, and the input that would make it fail if the behaviour regressed. A row with an empty second column is untested-by-construction and is called out as such rather than left looking green.

Counts are from `swift run diffscope-verify` at 855 checks, 32 fixtures.

---

## T-series — per-fixture invariants

Applied by `runFixtureChecks` to **both paths** of every fixture: raw (`trivialModel`) and structural (`structuralDiff`), the latter where DEC-004 admits the language.

| T | What it asserts | Runs | Input that can fail it |
|---|---|---|---|
| T-0 | Partition well-formed — no gaps, overlaps, zero-width; Σ == length | 60 | Any partition edit; four deliberate defects were injected in M1 to prove the harness catches them |
| T-1 | Old side reconstructs byte-for-byte | 60 | Computed independently of the partition's own checks, so a partition with a bug in its self-checking cannot mark its own homework |
| T-2 | New side reconstructs byte-for-byte | 60 | as T-1 |
| T-3 | Every canonical-diff hunk byte is **contained** in a presented range | 60 | Any change to snapping, reconciliation or the move search; the check distinguishes *unverified* (DEC-043 budget) from *failed* |
| T-4 | "No changes" shown **iff** byte-equal | 60 | `identical` in one direction, every other fixture in the other |
| T-5 | A fallback that reaches the contract is marked | 30 | `binary-file`, `invalid-utf8` — both unrenderable, marked whole rather than per segment |
| T-6 | Structural and Expanded present identical segment sets | 60 | Holds by construction (flags over one model), asserted anyway — "by construction" was wrong in M6-D |
| T-7 | Same input → identical **encoded contract** | 60 | Strengthened in M8-C: previously only a summary string was compared, so a model differing in a field the summary omits passed |
| T-8 | Canonically equivalent, byte-different → still a change | 2 | `nfc-vs-nfd`. Compared through **scalar arrays**; `String ==` is canonical equivalence and would make this test vacuous (M6-C) |
| T-9 | Broken source still presents every difference | 2 | `truncated-file`, `invalid-tsx` — selected by the parser actually reporting error nodes, not by whether the run happened to fall back |
| T-10 | Presented ranges start and end on grapheme-cluster boundaries | 60 | `unicode-graphemes`. **Failed on first run** — see below |
| T-11 | Every move's two sides are byte-equal, so no delta is swallowed | 3 | `moved-function` (one statement), `moved-block` (a multi-line block), `moved-two-blocks` (two independent moves, so `link` pairs rather than counts); `moved-function-modified` proves the edited case produces **none** |

### What the first run found

- **T-10 had no implementation.** `14-losslessness-and-trust-model.md` §4 requires presented regions to be snapped **outward** to grapheme-cluster boundaries, and nothing did it. The canonical diff of `'😀'` → `'😀‍💻'` is an insertion beginning *between* the emoji and its zero-width joiner — correct on bytes, unrenderable on screen. `snapToGraphemeBoundaries` now runs after syntax snapping, which is the right order because a syntax boundary is not obliged to fall on a cluster boundary and this case proves it does not.
- **T-5 and T-9 were each written too narrowly and failed correct behaviour**, which is recorded because both corrections are the interesting part: an unrenderable file marks its fallback *whole* rather than per segment, and a pure deletion has no changed bytes on the new side at all.

### T-11's coverage, and what constructing it keeps teaching

Three firing checks on three shapes as of M8-L, up from one. The corpus now asserts its own coverage — *a fixture that produces a move*, *one whose move spans several lines*, *one that produces two independent moves* — because a T-check that never fires is invisible in a green suite, which is how the single-shape gap was found in the first place.

**Constructing move fixtures has now failed four times, always the same way.** Two near-identical functions swapped (M8-C); `export const VAT_RATE` sharing its `export ` prefix with a neighbour (M8-C); and two short single lines sharing `" = "` and `";"` with the lines that replaced them (M8-L). The generalisation: *the shorter the relocated line, the more likely the canonical diff has already spent its bytes matching fragments elsewhere*, leaving no whole changed line for the line-based search of DEC-038 to pair. Blocks relocate detectably; short statements often do not.

This is a property of DEC-038 as decided, not a defect. Widening the search to partly-changed lines would put bytes the canonical diff calls unchanged inside a `moved` range, which is a reopening of DEC-038.

**The check that counts multi-line moves was itself wrong first.** It asked whether any *segment* of a move contained a newline; a relocated block arrives as one segment per line, so none does, and it reported zero multi-line moves on a corpus containing two. Measured over the link's whole span now.

---

## R-series — repository-level

Built by `runGitChecks` and `runRefreshChecks` against scratch repositories, since none of these are file-pair fixtures.

| R | What it asserts | Where | Notes |
|---|---|---|---|
| R-1…R-3 | Base detection cascade: `origin/HEAD` → unique local `main`/`master` → prompt | `GitChecks` | |
| R-4 | Detached HEAD is defined behaviour, no crash | `GitChecks` | |
| R-5 | No remote falls back to a local base ref | `GitChecks` | Covered inside the R-1…R-3 cascade rather than by its own name |
| R-6 | Ahead-count is unknown, never a fabricated zero | `GitChecks` | |
| R-7 | All four scopes select the right blob pairs | `GitChecks` | |
| R-8 | **No Git operation writes** — `.git` snapshotted before and after each | `GitChecks` | Runs over the whole closed registry, so a new operation without a proof fails. Extended in M8-B: `forbiddenArguments` also rejects any operation that would *execute* repository-configured commands, which is a different property from not writing |
| R-9 | A file changed mid-analysis never yields a blended pair | `RefreshChecks` | Hostile writer rewriting in place; the naive content-comparison guard let 3 blends through in 8,095 reads, the stat bracket alone 6 in 20, and the two together **4 per 1,000** until DEC-068 separated the confirming read in time (M9-E). The arm is bounded by **reads**, not by a clock — at 1.5 s it sampled 15, which could not have seen any of those rates |
| R-10, R-11 | Scan depth honoured; symlink cycles and root escapes refused | `GitChecks` | |
| R-12 | Unborn HEAD, and the idiom that reports it wrongly | `GitChecks` | Not in the original plan; added when `carrefour-inapp` turned out to be unborn rather than detached |

---

## Failure taxonomy — F-series

Ranked and checked since DEC-051; see `13-error-and-fallback-model.md` §5 and `DegradationChecks`.

| F | Reachable | Forced by |
|---|---|---|
| F1 partial parse error | **No producer** | — ranked but never constructed |
| F2 whole-file parse failure | yes | `merge-conflict-markers`, parser-unavailable path |
| F3/F4 confidence, ambiguity | **No producer** | — DEC-045 withdrew the indicator; the rank remains |
| F5 invariant violation | yes | deliberately broken models in `main.swift` |
| F6 unverified | yes | dissimilar 120 KB buffers (the size route now ends in F16) |
| F7 unsupported language | yes | `line-ending-change` (`.txt`), `binary-file` (`.png`) |
| F8 filter active | yes | `eol-filter-active` scratch repository (M8-B) |
| F9 binary / undecodable | yes | `binary-file`, `invalid-utf8` |
| F10 stale pin | yes | R-9's racing writer |
| F13 editor failure | yes | `/usr/bin/false` and a nonexistent path |
| F15 watcher drop | yes | forced through `deliver(flags:)` |
| F16 structural budget | yes | synthetic ladders and 2 MB+ inputs |

**F1 and F3/F4 are the two rows with ranks and no producers.** Either wire them or record why they stay theoretical — carried in the handoff's "what to do next".

---

## What this table is not

It says which behaviours are *checked*, not which are *correct*. Two known gaps sit outside it entirely: the interface below the diff panes has been looked at only through selftest snapshots, and no third party has run the application at all. Those are `23-release-gates.md`'s business, not this document's.
