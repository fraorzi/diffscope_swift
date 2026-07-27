# 20 — Implementation Plan

**Status:** Phase 8. Practical guidance for the first agent to write application code.
**Prerequisite:** the product owner must explicitly declare the planning phase complete. Until then, no application code.

---

## 1. Before anything else

**M0 is complete.** All three gates ran on 2026-07-27; full results and methods are in `22-experiment-log.md`.

| Gate | Result |
|---|---|
| **M0-1** `tree-sitter-typescript` #306 | **Passed.** The issue was mischaracterised throughout planning as "incorrect node ranges"; it is actually *"JSX captures whitespaces in nested, multiline tags"* — a text-node concern. Measured on **1370 real `.tsx` files: zero overlaps, 1370/1370 valid partitions.** |
| **M0-2** serialisation cost | **Passed.** 5149 segments, 276 KB JSON → **1.13 ms** steady state across `WKWebView`. Not a bottleneck. A "smaller" flat binary encoding measured **6.5× slower** — do not optimise this. |
| **M0-3** Swift binding health | **Passed.** `tree-sitter/swift-tree-sitter`: BSD-3-Clause, release 0.10.0 (2026-03-18), pushed 2026-05-26, 3 open issues, maintained in the tree-sitter org. |

**DEC-042 stands, confirmed rather than assumed.**

Two findings from M0 that change what to build:

- **~26% of bytes land in filler segments**, because tree-sitter leaves exclude inter-token whitespace. Not a defect — and useful: filler segments *are* the formatting, giving `formatting-only` classification a natural home.
- **`node-tree-sitter` fails at exactly 32,768 characters.** Irrelevant here (the C API takes a length) but it would have silently broken Option B. Do not use the Node binding for anything load-bearing.

Implementation therefore begins at **M1** (`19-roadmap.md`).

## 2. Repository layout

```
diffscope/
  docs/                    ← this planning set; keep synchronised
  Engine/                  ← Swift package: partition, matcher, validation
  EngineTests/             ← fixture runner, invariant tests
  Renderer/                ← CodeMirror bundle + contract adapter
  App/                     ← AppKit shell
  fixtures/                ← per 15-test-corpus-plan.md
  Tools/                   ← headless CLI target for CI
```

`Engine` must not import AppKit or WebKit. That is what makes DEC-002's headless requirement structural rather than aspirational.

## 3. Build order within M1

Deliberately inverted from instinct — the checker precedes the thing checked:

1. Byte partition type with assertions (no gaps, no overlaps, Σ == length, no zero-width).
2. Reconstruction (INV-1). Trivial by construction; test it anyway, **independently of the partition code**.
3. Independent Myers over bytes for `D` (DEC-039). Separate file, separate implementation, no shared helpers with anything on the presentation path.
4. Containment check (INV-2).
5. Fixture harness and runner.
6. Only then: a trivial partition producer (whole file as one fallback segment).

Step 6 last is the point. If the harness cannot prove a trivial partition correct, it cannot prove a real one.

## 4. The conversion function

In DEC-042 the X-1 hazard exists in exactly one place: converting byte offsets to CodeMirror's UTF-16 positions on the webview side.

**Rules:**
- One function. One file. No duplicates anywhere in the codebase.
- Tested with the X-1 discriminating probe: a string where bytes, UTF-16 units, and codepoints all diverge — including a 4-byte character (surrogate pair) and the corpus's decomposed `Ż` (`U+005A U+0307`).
- The test asserts the **unit**, not just round-tripping. A consistently-wrong converter round-trips fine.

Recall why: applying a UTF-16 offset to a byte buffer returned `"const "` where `"MARKER"` was expected — different, plausible, wrong text, with no error raised.

## 5. Test discipline

- **Invariant tests are automatic and apply to every fixture** with no per-case expectation file. They cannot be forgotten because they are not written per case.
- **Alignment-quality tests are opt-in per fixture** and fail at a lower severity. Conflating the two trains people to ignore failures.
- **T-1 and T-3 are implemented independently of the partition code**, even though DEC-024 makes them hold by construction. A partition implementation with a bug in its own checking would otherwise mark its own homework.
- **R-8 is a snapshot proof**, not an assertion: hash every file under `.git` before and after every Git operation the application can issue. Adding a Git call without a proof fails CI.
- **Fixture bytes are verified against recorded hashes.** A fixture whose CRLF or NFD content is silently repaired by an editor or formatter is worse than no fixture — it passes while testing nothing.

## 6. Fixtures that cannot occur locally

These will ship untested unless deliberately constructed, because the trigger cannot arise in the current corpus:

| Fixture | Why it cannot occur | Ref |
|---|---|---|
| `eol-filter-active` | 0 of 21 repositories have filters active | DEC-025, DEC-028, DEC-041 |
| Forced watcher drop | 40,000 creations produced zero drops | F15 |
| Oversized file above the `D` threshold | Threshold not yet exercised | DEC-040 |
| Mid-analysis file change | Requires deliberate racing | R-9 |
| Editor launch failure | Requires an intentionally broken command | F13 |

## 7. Things that will look like bugs and are not

Worth knowing before they cause a wrong "fix":

- **A region marked changed with no visible difference.** That is DEC-023 working — bytes differ, rendering is identical. The disclosure indicator explains it. Do not "fix" it by suppressing the region.
- **A clean repository showing review material.** Scope 4 compares against merge-base; clean ≠ nothing to review.
- **The file list showing a file whose diff is empty.** Under an active filter, `git status` and `git diff` genuinely disagree (DEC-041). Both are shown; the discrepancy is explained.
- **`symbolic-ref` reporting a branch that does not exist.** Measured on `carrefour-inapp`. Use `rev-parse --verify HEAD`.
- **`NSTextView.layoutManager` silently downgrading TextKit 2 to TextKit 1.** Relevant if any native text rendering is added later.

## 8. Keeping documentation synchronised

- A decision changed in code but not in `04-decision-log.md` is a **defect**, not a shortcut.
- New decisions get a DEC entry with the full format — including options rejected and a revisit trigger.
- Measurements go in `22-experiment-log.md` with method, not just results.
- When research invalidates an accepted decision, **reopen it explicitly** against its revisit trigger. Do not work around it silently.
- `00-index.md` carries current status and is updated at each milestone boundary.
