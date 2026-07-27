# 08 — Architecture Options

**Status:** Phase 7, awaiting decision. **No option is recommended in this document** — the recommendation follows in `09-recommended-architecture.md` after discussion.
**Evidence base:** [22-experiment-log.md](22-experiment-log.md), [07-technical-research.md](07-technical-research.md).

---

## 1. Why the choices are not independent

The three open pairs — tree-sitter vs TypeScript, Monaco vs CodeMirror, CLI vs libgit2 — cannot be decided separately, because spike X-1 tied parser coordinates to host language:

> Every Node-hosted parser measured (tree-sitter, oxc, TypeScript) reports **UTF-16 code units while typing them as bytes**. The C, Rust, and Swift bindings are byte-native.

DEC-024 builds a **byte** partition. So the host language determines whether the engine gets byte-native offsets or needs a conversion layer that is itself a tested correctness surface. That single fact organises the option space.

Second organising fact, **updated after spike X-5**: native macOS rendering has now been measured on the same corpus and the same method. **There is no performance cliff** — TextKit 2 creates 5000 lines in 108.6 ms, applies 795 decorations in 56.5 ms, and scrolls comfortably.

The native risk therefore **changed character rather than disappearing**. It is no longer "performance might not work"; it is "virtualised panes, gap widgets, collapsed regions, gutter and navigation are weeks of UI construction that the web candidates supply for free." X-5 measured the floor of the native path, not its total.

## 2. Constraints every option must satisfy

| Constraint | Source |
|---|---|
| macOS only, permanently | DEC-002 |
| Engine runs **headlessly** in CI | DEC-002 |
| Byte partition as model primitive | DEC-024 |
| Strictly read-only Git | DEC-003 |
| No network at all | DEC-011, DEC-020 |
| Side-by-side rendering with alignment gaps, char-level marks, view zones | DEC-014, DEC-017 |
| Full keyboard operation | DEC-016 |
| Licence permits possible future distribution | DEC-020 |

Any option failing the headless requirement is disqualified regardless of other merit.

---

## 3. Option A — Full native Swift

**Shape.** Swift + AppKit. Engine in Swift. tree-sitter via its C API (Swift interop). Git via CLI subprocess. Custom text rendering on TextKit 2 or Core Text.

**Data flow.** `Git CLI → bytes → Swift engine → partition model → AppKit text view`. All in one process, one language.

| | |
|---|---|
| **Advantages** | Byte-native offsets, no conversion layer. Single language, single process, no IPC. Smallest bundle, fastest launch. Deepest macOS integration — appearance, FSEvents, accessibility APIs, security-scoped bookmarks for DEC-037. Headless trivially: a Swift CLI target sharing the engine module. |
| **Weaknesses** | **Rendering performance is now measured and fine (X-5); the cost is construction effort.** Virtualisation, alignment-gap widgets, collapsed regions, gutter, linked scrolling and navigation must all be built on TextKit 2 from scratch. Decoration is native's weakest measured axis at 56.5 ms vs ~17 ms for the web renderers. Target TextKit 2, noting that merely touching `NSTextView.layoutManager` silently downgrades to TextKit 1. |
| **Correctness risks** | Lowest of the four. No coordinate conversion, no serialisation boundary. |
| **Performance risks** | Unknown rendering. Everything else measured comfortable. |
| **Maintenance** | One language, no bundler, no npm surface. But a hand-built text renderer is a permanent liability. |
| **Packaging** | Simplest. Native bundle, standard signing/notarisation. **Requires full Xcode**, not currently installed. |
| **Licensing** | Clean — tree-sitter MIT, no copyleft. |
| **Testing** | Engine trivially headless. Rendering hardest to test of the four. |
| **Hard to change later** | The renderer. Committing to custom native text rendering is close to irreversible. |

---

## 4. Option B — Full web

**Shape.** Electron or Tauri v2. Engine in TypeScript. Parser in JS (TypeScript compiler API or tree-sitter WASM). CodeMirror 6 or Monaco as two plain views. Git via CLI subprocess.

**Data flow.** `Git CLI → bytes → JS engine → partition model → CodeMirror/Monaco`. One language, one process, no IPC.

| | |
|---|---|
| **Advantages** | Rendering **measured viable** — CodeMirror creates 5000 lines in 64 ms, scrolls at 0.1 ms/step, handles 50,000-char lines. Fastest path to a working diff view. Familiar tooling. Headless via Node. |
| **Weaknesses** | **Every parser reports UTF-16.** DEC-024 needs bytes, so a conversion layer is mandatory — and X-1 showed the failure mode is *silent*: wrong offsets still tile, still reconstruct, and pass T-0 and T-1 while failing only T-3. |
| **Correctness risks** | **Highest of the four**, concentrated in one place: the coordinate conversion. Mitigable by independent testing, but it is a permanent surface that the other options simply do not have. |
| **Performance risks** | Lowest — rendering measured; parsing negligible; JS matcher performance unmeasured but the matcher is the risk everywhere. |
| **Maintenance** | Large npm dependency surface. Electron adds a browser runtime to maintain and update. |
| **Packaging** | Electron: ~9.3 MB Monaco bundle plus runtime, large. Tauri: much smaller, uses system WKWebView. |
| **Licensing** | Clean — MIT/Apache throughout. |
| **Testing** | Easiest overall. Node headless, and the X-3 harness already exists in this shape. |
| **Hard to change later** | The coordinate model. If conversion proves unsound, the fix is a host-language change. |

---

## 5. Option C — Swift core, web rendering

**Shape.** Swift application shell. Engine in Swift with tree-sitter C API. Rendering in a `WKWebView` hosting CodeMirror. Git via CLI. Model crosses the boundary by serialisation.

**Data flow.** `Git CLI → bytes → Swift engine → partition model → serialise → WKWebView → CodeMirror`.

| | |
|---|---|
| **Advantages** | Byte-native engine **and** measured rendering — the two properties the other options each have only one of. Native shell keeps FSEvents, appearance, bookmarks, accessibility. No Electron runtime; WKWebView is system-provided. |
| **Weaknesses** | Two languages. A serialisation boundary that does not exist in A or B. Model transfer cost **unmeasured** (this was spike S-4, unfunded). |
| **Correctness risks** | Low for coordinates. New risk at the boundary: the serialised model must not lose or reinterpret ranges. Testable, and unlike B's conversion it is a *transport* problem rather than a *semantics* problem. |
| **Performance risks** | Serialisation of a large partition per file. For a 5000-line file with ~800 decorations this is likely trivial, but it is unquantified. |
| **Maintenance** | Highest interface surface of the four — two languages plus a contract between them. |
| **Packaging** | Native bundle plus bundled web assets. Moderate. Requires full Xcode. |
| **Licensing** | Clean. |
| **Testing** | Engine headless in Swift; renderer testable in a browser harness independently. Arguably the **best testability**, because the two halves can be tested separately with a documented contract between them. |
| **Hard to change later** | The engine/renderer contract. Everything else stays replaceable — either side can be swapped without touching the other. |

---

## 6. Option D — Rust core, web rendering

**Shape.** Tauri v2. Engine in Rust with tree-sitter's Rust bindings. CodeMirror in the webview. Git via CLI or `git2-rs`.

**Data flow.** Same as C, with Rust in place of Swift.

| | |
|---|---|
| **Advantages** | Byte-native engine and measured rendering, like C. Best-maintained tree-sitter binding of all candidates. `git2-rs` is the one healthy libgit2 binding. Smaller bundle than Electron. Rust's performance suits the matcher, which is the acknowledged risk. |
| **Weaknesses** | **Rust is not installed** — a new toolchain to adopt. Weakest macOS integration of the four; platform APIs reached through Tauri plugins or FFI, and DEC-037 needs security-scoped bookmarks, which is exactly the kind of thing that is native in Swift and awkward through a wrapper. |
| **Correctness risks** | Low for coordinates. Same boundary risk as C. |
| **Performance risks** | Lowest for the matcher. WKWebView frame-rate behaviour under Tauri was flagged in research and is unverified. |
| **Maintenance** | Two languages plus Tauri's own release cadence. |
| **Packaging** | Good — small bundles, mature tooling. |
| **Licensing** | Clean if using the CLI; `git2-rs` inherits libgit2's GPL-2.0-with-linking-exception, which under DEC-020's open distribution question needs care. |
| **Testing** | Engine headless in Rust; renderer separately. Comparable to C. |
| **Hard to change later** | The Tauri dependency and the Rust commitment. |

---

## 7. Comparison

| Criterion | A native | B web | C Swift+web | D Rust+web |
|---|---|---|---|---|
| Byte-native offsets | ✅ | ❌ conversion layer | ✅ | ✅ |
| Rendering measured | ✅ (X-5) | ✅ | ✅ | ✅ |
| Diff UI supplied by the toolkit | ❌ build it all | ✅ | ✅ | ✅ |
| Languages | 1 | 1 | 2 | 2 |
| IPC / serialisation boundary | none | none | yes | yes |
| macOS integration | best | weakest | strong | weak |
| Headless engine | trivial | trivial | trivial | trivial |
| Toolchain to adopt | full Xcode | none | full Xcode | full Xcode + Rust |
| Bundle size | smallest | largest (Electron) | moderate | small |
| Highest single risk | unmeasured renderer | silent coordinate bug | boundary cost | new toolchain + weak platform access |

## 8. What each option makes hard to reverse

Worth weighing separately, because DEC-001 exists to avoid unevaluated lock-in:

- **A** — the custom renderer. Practically irreversible.
- **B** — the coordinate model. Reversing means changing host language, i.e. rewriting.
- **C** — only the engine/renderer contract. Both sides remain independently replaceable.
- **D** — Rust and Tauri together. Reversible in principle, expensive in practice.

## 9. Cross-cutting sub-decisions

These follow from the option chosen rather than being free choices:

**Parser.** tree-sitter in A/C/D (byte-native via C/Rust/Swift). In B the choice is between TypeScript (never throws, 0/4800) and tree-sitter WASM — both UTF-16, both needing conversion. Note the two survivors were measured with **different metrics** and cannot yet be ranked against each other.

**Renderer.** CodeMirror leads Monaco on every measured axis except view-zone insertion, and by 14× on bundle size. Since neither offers a usable external-diff API, the diff UI is built from primitives either way.

**Git.** The CLI leads on status performance (46 ms vs 264 ms), binding health, licensing, and Raw-mode fidelity — where it is the reference by definition. libgit2 wins only on unborn-HEAD handling, and that advantage can be replicated on the CLI by using `rev-parse --verify HEAD` instead of the lying `symbolic-ref` idiom. **The CLI is the better default in all four options**; libgit2 remains defensible only in D, where `git2-rs` is healthy.

## 10. What would change the answer

- Measuring native macOS rendering would remove A's and C's largest unknown. It is the single most valuable unfunded experiment.
- Measuring serialisation cost for a realistic partition would settle C and D's boundary concern.
- A comparable error-recovery metric for tree-sitter vs TypeScript would settle the parser sub-decision independently.
