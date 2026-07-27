# 09 — Recommended Architecture

**Status:** Accepted as DEC-042. Authoritative.
**Options considered and rejected:** [08-architecture-options.md](08-architecture-options.md).
**Evidence:** [22-experiment-log.md](22-experiment-log.md), spikes X-1 … X-5.

---

## 1. The shape

**Swift application shell and engine, rendering in `WKWebView` with CodeMirror 6, Git through the CLI.**

```
┌──────────────────────── Swift process ─────────────────────────┐
│                                                                 │
│  Git layer          Engine                    Shell             │
│  ─────────          ──────                    ─────             │
│  git CLI            tree-sitter (C API)       AppKit window     │
│  --no-optional-     byte partition            FSEvents watcher  │
│    locks            matcher (from papers)     bookmarks         │
│  pinned pairs       classification            keyboard map      │
│       │             validation                                  │
│       └──── bytes ──────►│                                       │
│                          │ partition model                      │
│                          ▼                                       │
│                   ┌─────────────┐                               │
│                   │ serialise   │  ← the one irreversible       │
│                   └──────┬──────┘     commitment                │
└──────────────────────────┼──────────────────────────────────────┘
                           ▼
                  ┌────────────────────┐
                  │ WKWebView          │
                  │  CodeMirror 6      │
                  │  two plain views   │
                  │  decorations,      │
                  │  block widgets,    │
                  │  linked scrolling  │
                  └────────────────────┘
```

## 2. Why this and not the others

| Property | Why it decided the choice |
|---|---|
| **Byte-native offsets** | X-1: every Node binding reports UTF-16 while typing it as bytes. The failure is *silent* — wrong offsets still tile, still reconstruct, pass T-0 and T-1, fail only T-3. Swift reaches tree-sitter's C API, where the property is native. Option B would have carried this surface permanently. |
| **Rendering supplied, not built** | X-5 showed native rendering performs fine, then reframed the risk: virtualised panes, gap widgets, collapsed regions, gutter and navigation are weeks of construction. CodeMirror supplies them. This is what separated C from A. |
| **Smallest irreversible commitment** | A locks in a custom renderer; B locks in the coordinate model (reversing means changing host language); D locks in Rust plus Tauri. C locks in only the engine↔renderer contract — both sides stay independently replaceable. |
| **Platform access** | DEC-037's multiple roots need security-scoped bookmarks; FSEvents, appearance and accessibility are all native. D reaches these through a wrapper. |
| **Testability** | Engine headless in Swift (DEC-002 requirement), renderer testable in a browser harness, contract documented between them. |

## 3. Component decisions

**Parser — tree-sitter via C API.** Byte-native, never throws (0/4800 truncations), error recovery real.

**Renderer — CodeMirror 6.** Led every measured axis except view-zone insertion; 667 KB versus Monaco's 9.3 MB. Neither offers a usable external-diff API, so the diff UI is built from primitives regardless — which made bundle size and API stability the deciding factors.

**Git — CLI subprocess**, always `--no-optional-locks` (measured: plain `git status` rewrites the index whenever the stat cache is stale, which is this application's normal operating mode).

**Matcher — implemented from publications**, never ported (GumTree is LGPL-3.0, DEC-030). Consumed as a node↔node mapping only, never an edit script (DEC-029).

## 4. What this architecture costs, stated plainly

**Two languages and a serialisation boundary.** **Measured in M0-2 and cleared:** a 5149-segment model — 276 KB of JSON from a real 23.8 KB `.tsx` file — crosses into `WKWebView` in **1.13 ms** steady state. Negligible against the ~400 ms refresh debounce and CodeMirror's 64 ms create.

Note for whoever later decides this needs optimising: a flat `Int32` encoding is 4.5× smaller and **6.5× slower**, because base64 decoding in JavaScript costs more than `JSON.parse` saves. `JSON.parse` is a native fast path. Measure before shrinking.

**The parser choice is forced, not earned.** TypeScript is unreachable from Swift, so tree-sitter wins by architecture. That means adopting the candidate with the weaker-looking error-recovery number: ~38.4% of bytes outside `ERROR` spans on truncated files, against TypeScript's ~76% tree intact. **The metrics are not comparable**, so this does not establish TypeScript was better — but the option is gone either way.

Practical consequence: **alignment quality on half-typed files is bounded by tree-sitter's recovery.** A quality ceiling, not a correctness problem — `ERROR` regions become visibly marked fallback segments.

**`tree-sitter-typescript` is stale and has a directly relevant defect.** Last release 2024-11-11, last `master` commit 2025-01-30, 47 open issues including #306. **Verified in M0-1 and downgraded:** the actual issue is "JSX captures whitespaces in nested, multiline tags" — a text-node concern, not a range defect. Measured across 1370 real `.tsx` files: zero overlaps, 1370/1370 valid partitions.

## 5. The contract between halves

The only thing this architecture makes expensive to change, so it is specified deliberately.

**Swift → webview:** the partition model for one pinned source pair — segments with byte ranges, labels, classifications, confidence, links, and nesting.

**Webview → Swift:** user intent only — selection, navigation, mode switch, expand, open-in-editor.

Rules:
- The webview **never computes a diff** and never re-derives ranges. It renders what it is given.
- Ranges cross the boundary as **byte offsets**, converted to CodeMirror's UTF-16 positions **on the webview side, in one place, tested independently**. This is the one location where the X-1 hazard exists in this architecture; confining it to a single tested function is the mitigation.
- The pin identity crosses with the model, so the renderer can never display a model against the wrong source.

## 6. Headless operation

Required by DEC-002. The engine is a Swift module; the application and a CLI test target both link it. The fixture corpus (`15-test-corpus-plan.md`) runs against the CLI target with no GUI, no webview, and no window server.

## 7. Immediate risks

| Risk | Mitigation |
|---|---|
| ~~`tree-sitter-typescript` #306 range defects~~ | **Resolved in M0-1** — mischaracterised; it is a whitespace/text-node issue, not a range defect |
| Serialisation cost at the boundary | Measure early with a realistic partition |
| Byte↔UTF-16 conversion in the webview | Single function, independently tested, X-1's probe as the test |
| Swift tree-sitter binding health | Assess; the C API's byte-native property is established, the binding's maintenance is not |
| Matcher cost on dense JSX trees | Budget on node count; the acknowledged risk everywhere |

## 8. What would reopen this

Serialisation cost proving material, or a genuine grammar defect emerging that a byte partition cannot absorb. (#306, the original concern, was resolved in M0-1.) Both are checkable early, and both are cheaper to discover before implementation than after.
