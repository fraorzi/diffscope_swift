# Research — Desktop Stack and Diff Rendering

**Phase:** 3 (Technical research). **Status:** Research notes. **Not authoritative for any decision.**
**Date of research:** 2026-07-26. **Researcher:** agent, read-only pass.

This document is input to the Phase 7 architecture decision. It deliberately does **not** name a
winner. Where a stack looks unattractive it is still described on its own terms, because Phase 7
will weigh criteria this document does not know about.

## How to read this document

Three kinds of statement appear, and they are always marked:

- **[Fact]** — verified against a primary or near-primary source, or measured on this machine. A URL
  or a command follows.
- **[Interpretation]** — my reading of the facts. May be wrong. Never cite this as evidence.
- **[Unverified]** — claim found in a secondary source (blog, aggregator) that I could not confirm
  against a primary source. Treated as a lead, not evidence.

Anything not marked is structural prose.

---

## 0. Environment facts measured on this machine

These were measured directly, not read from documentation. They constrain the stack choice more
sharply than anything found on the web, because several candidate stacks assume a toolchain that is
not installed.

Commands run 2026-07-26 on macOS 26.5.2, arm64.

| Probe | Result | Verdict |
|---|---|---|
| `xcode-select -p` | `/Library/Developer/CommandLineTools` | **[Fact]** No full Xcode |
| `xcodebuild -version` | `error: tool 'xcodebuild' requires Xcode` | **[Fact]** Unavailable |
| `swift --version` | Apple Swift 6.2.4, target `arm64-apple-macosx26.0` | **[Fact]** Present |
| `xcrun --show-sdk-path` | `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`, SDK 26.2 | **[Fact]** |
| SDK frameworks | `SwiftUI.framework`, `AppKit.framework`, `Metal.framework`, `CoreText.framework` all present | **[Fact]** |
| `swiftc -typecheck` on a file importing `SwiftUI` + `AppKit` | exit 0 | **[Fact]** SwiftUI/AppKit compile CLT-only |
| `xcrun --find metal` | `error: unable to find utility "metal"` | **[Fact]** **No Metal shader compiler** |
| `xcrun --find notarytool` | `/Library/Developer/CommandLineTools/usr/bin/notarytool` | **[Fact]** Present |
| `xcrun --find stapler` | `/Library/Developer/CommandLineTools/usr/bin/stapler` | **[Fact]** Present |
| `which codesign` | `/usr/bin/codesign` | **[Fact]** Present |
| `swift build` / `swift run` on a fresh executable package | Built and ran, printed output | **[Fact]** **Headless Swift executables work CLT-only** |
| `swift test` with `import Testing` | `error: no such module 'Testing'` | **[Fact]** Fails by default |
| `swift test` with `import XCTest` | `error: no such module 'XCTest'` | **[Fact]** **XCTest is absent from CLT entirely** |
| `swift test` + `-Xswiftc -F <CLT>/Library/Developer/Frameworks` | Compiles and links; fails at runtime: `Library not loaded: @rpath/Testing.framework/...` | **[Fact]** swift-testing is shipped but not wired up |
| `cargo` / `rustc` | not found | **[Fact]** Rust absent |
| `node` / `pnpm` | v22.22.0 / 10.34.4 | **[Fact]** Present |

Four consequences follow, and they are load-bearing:

1. **[Fact]** `swift test` does not work on this machine. `XCTest.framework` is not in the Command
   Line Tools at all; `Testing.framework` (swift-testing) is physically present at
   `/Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework` with a valid
   `arm64-apple-macos.swiftinterface`, but SwiftPM neither adds the framework search path nor sets an
   rpath that resolves it. Passing `-Xswiftc -F …` gets it to build and link; the test bundle then
   fails to `dlopen`.
   **[Interpretation]** This does not disqualify Swift for the engine — a headless engine can be an
   executable target driven by a CLI fixture harness, and `swift build`/`swift run` demonstrably work.
   But it does mean "Swift + standard test tooling, headless, no Xcode" is currently false, and
   Phase 6's CI story on a Swift path either installs full Xcode or does not use `swift test`.

2. **[Fact]** The Metal shader compiler (`metal` / `metallib`) is not in the Command Line Tools. Zed
   documents this as an Xcode requirement for GPUI:
   <https://zed.dev/docs/development/macos> and
   <https://github.com/zed-industries/zed/discussions/7016> ("the tools `metal` and `metallib` are
   only included inside Xcode.app, not in any macOS Frameworks or the command line tools").
   **[Interpretation]** Any stack that compiles its own Metal shaders at build time (GPUI, and most
   custom-GPU renderers) makes full Xcode a hard prerequisite. Stacks that only *link* Metal at
   runtime, or use `MTLDevice.makeLibrary(source:)` runtime compilation, do not.

3. **[Fact]** Signing and notarization are fully available CLT-only: `codesign`, `notarytool`,
   `stapler`. Apple DTS confirms `notarytool` is designed to work standalone:
   <https://developer.apple.com/forums/thread/724780> — "you don't even need to install the full
   Command Line Tools package. `notarytool` is built to operate standalone."
   **[Interpretation]** Distribution outside the App Store is not gated on installing Xcode. App
   Store submission is a different matter (see §6.4).

4. **[Fact]** There is no `.app` bundle builder in the CLT. `xcodebuild`, `actool` (asset catalogs),
   and Interface Builder tooling are absent. SwiftPM produces a bare Mach-O executable.
   **[Interpretation]** A Swift GUI app without Xcode means hand-assembling `Contents/MacOS`,
   `Info.plist`, and resources via a script. This is well-trodden but it is real work and a real
   maintenance surface, and it is not the path Apple's documentation assumes.

---

## 1. The decisive question: can Monaco or CodeMirror render an externally-computed diff?

The brief flags this as decisive. Answering it first, because the answer partly collapses the
rendering option space.

### 1.1 Short answer

| Component | Accepts an external diff? | Confidence |
|---|---|---|
| Monaco **diff editor** | Not via public API. Private-API hack exists and has already broken once. | **[Fact]**, high |
| Monaco **two plain editors, driven manually** | Yes — this is entirely public API. | **[Fact]**, high |
| `@codemirror/merge` **MergeView** | **Yes, since 6.12.0 (2026-02-15)** via `DiffConfig.override`, but with a narrow signature. | **[Fact]**, high |
| CodeMirror 6 **two plain EditorViews, driven manually** | Yes — decorations are a first-class public API with no diff model at all. | **[Fact]**, high |

### 1.2 Monaco — the details

**[Fact]** Monaco's public API declares the diff algorithm as a closed string union, not a provider
object. From VS Code's `editorOptions.ts` (the file Monaco's `monaco.d.ts` is generated from):

```ts
/**
 * Diff Algorithm
*/
diffAlgorithm?: 'legacy' | 'advanced' | 'advanced-external' | 'advanced-wasm';
```

Source: <https://raw.githubusercontent.com/microsoft/vscode/main/src/vs/editor/common/config/editorOptions.ts>
Mirrored in the published typedoc: <https://microsoft.github.io/monaco-editor/typedoc/interfaces/editor_editor_api.editor.IDiffEditorOptions.html>

**[Interpretation]** The `'advanced-external'` and `'advanced-wasm'` members are new relative to the
`'legacy' | 'advanced'` pair that older documentation shows. I could not determine what they select —
in particular whether `'advanced-external'` means "an external process/worker computes the diff" in a
sense we could hook, or whether it selects an internal implementation. **This is worth ten minutes of
source reading before any spike**, because if `'advanced-external'` is a genuine extension point the
Monaco calculus changes. Recorded as OQ below.

**[Fact]** Passing a provider object where the type says string is a documented community workaround,
not API. Feature request #4264 asks for it to become real API and remains open with the
`feature-request` label; the requester writes "The below code is not going to work when monaco version
increase, so is there a way to achieve a permanent customized solution."
<https://github.com/microsoft/monaco-editor/issues/4264>

**[Fact]** The related bug #4764 reports exactly that breakage: an override of the diff provider
factory service, built around `WorkerBasedDocumentDiffProvider`, stopped working on upgrade to Monaco
0.49. No maintainer response, no linked PR.
<https://github.com/microsoft/monaco-editor/issues/4764>

**[Fact]** Monaco's own README states the stability contract explicitly: "monaco.d.ts: this specifies
the API of the editor (this is what is actually versioned, everything else is considered private and
might break with any release)."
<https://github.com/microsoft/monaco-editor>

**[Interpretation]** Combining those three: the diff-provider override is unambiguously private
surface, has already broken once across a minor version, and the maintainers have neither promised nor
refused to make it public. For a personal tool that is a survivable risk. For a tool whose entire
value proposition is a bespoke diff engine, building on it means the app's core feature rides on an
interface that the upstream project explicitly disclaims.

**[Fact]** Monaco's diff editor also carries hard limits that would apply to us if we used it as a
diff editor: `maxComputationTime` defaults to 5000 ms, `maxFileSize` defaults to 50 MB, and
`hideUnchangedRegions` is a built-in collapse mechanism with `contextLineCount` / `minimumLineCount` /
`revealLineCount`. Source as above.
**[Interpretation]** `maxComputationTime` is a property of *Monaco's* diff, so it is irrelevant if we
supply our own — but it is a signal that the component assumes it owns the computation.

**[Fact]** The escape hatch is real and fully public: `IViewZone` / `IViewZoneChangeAccessor`.
A view zone is "a full horizontal rectangle that 'pushes' text down", positioned by `afterLineNumber`
and sized by `heightInLines` or `heightInPx`.
<https://microsoft.github.io/monaco-editor/typedoc/interfaces/editor.IViewZone.html>
<https://microsoft.github.io/monaco-editor/typedoc/interfaces/editor.IViewZoneChangeAccessor.html>
**[Interpretation]** That is precisely the primitive alignment gaps need. Two plain
`monaco.editor.create()` instances + decorations + view zones + a scroll-sync listener reproduces the
structure of a side-by-side diff view without touching Monaco's diff model at all. Monaco's own diff
editor is built this way internally. The cost is that you inherit none of its behaviour and must
build gutters, navigation, collapse, and alignment yourself.

**[Fact]** Monaco's long-line and large-file behaviour is configurable but the defaults are punts:
`stopRenderingLineAfter` defaults to 10000 characters (`-1` disables), `maxTokenizationLineLength`
defaults to 20000 characters, above which the line is not tokenized (so: not syntax highlighted).
<https://microsoft.github.io/monaco-editor/typedoc/interfaces/editor_editor_api.editor.IStandaloneEditorConstructionOptions.html>

### 1.3 CodeMirror 6 — the details

**[Fact]** As of `@codemirror/merge` **6.12.0**, released **2026-02-15**, the changelog reads: "the
diffing routine used can now be replaced with a custom implementation via `DiffConfig.override`".
<https://github.com/codemirror/merge/blob/main/CHANGELOG.md>

**[Fact]** The signature, from source:

```ts
export interface DiffConfig {
  scanLimit?: number
  timeout?: number
  override?: (a: string, b: string) => readonly Change[]
}

export class Change {
  constructor(
    readonly fromA: number,
    readonly toA: number,
    readonly fromB: number,
    readonly toB: number
  ) {}
}

export function diff(a: string, b: string, config?: DiffConfig): readonly Change[]
```

Source: <https://raw.githubusercontent.com/codemirror/merge/main/src/diff.ts>

**[Fact]** Before 6.12.0 the answer was a flat no. In a 2024 forum thread the maintainer (Marijn
Haverbeke) said of supplying an externally computed diff: "That sounds like it'd be asynchronous (and
thus slow to update when the document is edited). I don't think this is going to be possible with the
`@codemirror/merge` package."
<https://discuss.codemirror.net/t/providing-own-diff-mechanism-in-mergeview/6875>

**[Interpretation]** So the capability exists now, but note what the signature costs us:

- `override` is **synchronous**. Our engine is a compute-heavy structural matcher. If it runs in a
  worker, or does anything async (reading blobs from Git, parsing with tree-sitter WASM), it cannot
  be called from inside `override` directly. The workaround is to pre-compute, cache by
  `(a, b)` identity, and have `override` return the cached result — a lookup, not a computation. That
  works but means MergeView is being lied to about what it is calling.
- `Change` is **four character offsets and nothing else**. There is no slot for move identity,
  wrapper relationship, confidence, fallback marking, or classification. Every trust indicator that
  DEC-017 makes mandatory would have to be layered on separately as decorations, keyed by position,
  outside the chunk model.
- Because the diff is expressed as flat character ranges, the structural information that is the
  entire point of the product survives only as *where* the ranges fall — the semantics are lost at
  the boundary.

**[Fact]** The `@codemirror/merge` GitHub repository was **archived on 2026-04-15** and moved to
`code.haverbeke.berlin/codemirror/merge`.
<https://github.com/codemirror/merge>
**[Interpretation]** This appears to be the whole CodeMirror project moving off GitHub rather than
abandonment (the `codemirror/dev` issue tracker is archived on the same date), but it does mean
issue-tracker history and future discoverability now live on self-hosted infrastructure. Worth
confirming the project's ongoing maintenance model before depending on it.

**[Fact]** CodeMirror 6's decoration system is a general-purpose facility with no diff model attached:
`Decoration.mark` (style a text range), `Decoration.widget` (insert non-text content),
`Decoration.replace` (substitute content, supports block mode), `Decoration.line` (style a whole line).
<https://codemirror.net/docs/ref/>
**[Interpretation]** This is the strongest argument for CodeMirror on this project: you can ignore
`@codemirror/merge` entirely, run two `EditorView`s, and express alignment gaps as block widgets,
collapsed regions as block `replace` decorations, intra-line character highlighting as `mark`
decorations, and confidence/fallback indicators as line decorations plus gutter markers. Nothing in
that list requires a diff model, and none of it is private API.

**[Fact]** CodeMirror 6 virtualizes vertically by design and this cannot be disabled — non-visible
lines are replaced by a `cm-gap` element carrying their height.
<https://discuss.codemirror.net/t/viewport-issues-with-cm-6/3586>

**[Fact]** Very long lines remain an acknowledged, unsolved weakness. `codemirror/dev` issue #29,
"Look for strategies to speed up drawing and updating (very) long lines", discusses replacing
off-viewport portions of a line with placeholder space nodes, notes that this is defeated by line
wrapping because "wrapping points cannot be determined without drawing the content", and uses a
"megabyte-long line" as the motivating case. The issue is closed but with no implementation, and the
repository is now archived.
<https://github.com/codemirror/dev/issues/29>

**[Fact]** `@codemirror/merge` has repeatedly needed large-input guards: 6.1.2 (2023-08-18) "fall back
to treating entire documents as changed" for very large files; 6.8.0 (2024-12-30) "limit the size of
highlighted chunks in the unified view, to prevent freezing"; 6.9.0 (2025-03-03) added a `timeout`
option to bail out. Source: changelog as above.

**[Fact]** Both Monaco and CodeMirror are MIT licensed.
<https://github.com/microsoft/monaco-editor> · <https://github.com/codemirror/merge>

### 1.4 What this means for the option space

**[Interpretation]** The question "can we drive Monaco/CodeMirror with our diff?" resolves into a
different and more useful question: **do we want a text *editor* component at all?**

Our view is read-only (DEC-003), non-editable, side-by-side only (DEC-014), with alignment gaps,
collapsed regions, move visualization, and mandatory trust indicators. Almost everything an editor
component sells — editing, undo, autocomplete, multi-cursor, input method handling, selection
semantics — is either irrelevant or actively in the way. What we actually need from it is: viewport
virtualization, text measurement, syntax highlighting, and a decoration mechanism.

That reframing means the honest comparison is not "Monaco vs CodeMirror" but "editor component vs
purpose-built virtualized renderer", where the editor component is a way to *not write*
virtualization and text measurement, at the cost of carrying a large dependency shaped for a different
job.

---

## 2. Rendering approaches

### 2.1 Monaco Editor (two plain editors, driven manually)

- **[Fact]** MIT. Generated from VS Code sources; only `monaco.d.ts` is versioned, everything else is
  private and may break every release. <https://github.com/microsoft/monaco-editor>
- **[Fact]** Public primitives that map to our needs: decorations (`createDecorationsCollection`),
  view zones (alignment gaps), overlay widgets, content widgets, scroll events.
- **[Fact]** Defaults degrade on long lines (`stopRenderingLineAfter` 10000, `maxTokenizationLineLength`
  20000).
- **[Interpretation]** Strengths: the most battle-tested code viewport on the web; TextMate-grade
  highlighting via `monaco-editor-textmate`/Shiki integration; excellent line measurement APIs
  (`getTopForLineNumber`, `getScrolledVisiblePosition`) which we need to draw move connectors between
  panes. Weaknesses: large (hundreds of KB minified plus workers), architecturally an editor, and its
  API surface beyond `monaco.d.ts` is explicitly unstable. Mobile unsupported (irrelevant here).

### 2.2 CodeMirror 6

- **[Fact]** MIT. Decoration API (`mark`/`widget`/`replace`/`line`, block variants) is public and
  general. Viewport virtualization is mandatory and built in.
  <https://codemirror.net/docs/ref/>
- **[Fact]** `@codemirror/merge` 6.12.0+ supports `DiffConfig.override` — a synchronous
  `(a, b) => readonly Change[]`. Chunks carry only four character offsets.
- **[Fact]** Long lines are an open weakness (issue #29, archived unresolved).
- **[Interpretation]** Modular, much smaller than Monaco, and the decoration model is a genuinely
  good fit for "render this precomputed annotation set". The `@codemirror/merge` route is tempting
  and probably wrong for us — it buys chunk bookkeeping and revert controls (which we don't want,
  being read-only) at the price of squeezing a structural diff through a flat-offset interface. The
  two-plain-views route keeps the parts that help.

### 2.3 Native macOS: NSTextView / TextKit 2

- **[Fact]** TextKit 2's completeness has been a running complaint. Michael Tsai's roundup
  "TextKit 2: The Promised Land" (2025-08-15) collects reports that progress on filling gaps has been
  slow. <https://mjtsai.com/blog/2025/08/15/textkit-2-the-promised-land/>
- **[Fact]** STTextView exists precisely because its author hit TextKit 2 bugs he could not work
  around inside `NSTextView`; the project has been in development ~4 years.
  <https://github.com/krzyzanowskim/STTextView> ·
  <https://christiantietze.de/posts/2022/05/sttextview-textkit-2-editor-without-nstextview/>
- **[Fact]** CodeEdit — a macOS-native editor project — went further and wrote its own text view
  (`CodeEditTextView`, MIT) after hitting problems with STTextView they "couldn't optimize out,
  especially when loading large documents." The README scopes it as a replacement for `NSTextView`
  in "*specific*" cases only, explicitly not for right-to-left text, custom layout elements, or
  system-text-view feature parity. <https://github.com/CodeEditApp/CodeEditTextView>
- **[Unverified]** Reports of TextKit 2 scrolling degrading noticeably above ~3000 lines and being
  problematic at 10k lines. Found only in secondary discussion, not measured.
- **[Interpretation]** The pattern across three independent macOS-native editor projects is the same:
  start on NSTextView/TextKit 2, hit walls on large documents, end up writing a custom line-layout
  text view on Core Text. That is a strong prior. **What is genuinely hard here** is not drawing text
  — Core Text does that well — it is everything `NSTextView` gives you for free that you then have to
  rebuild: selection, find, accessibility, text input, and above all *layout of a virtualized
  document with per-line heights*. For our read-only, non-editable, per-line-height-varying
  side-by-side view, a large fraction of that free functionality is irrelevant, which changes the
  trade-off relative to a general editor. Selection and copy remain genuinely required and are the
  part most likely to be underestimated.

### 2.4 Native macOS: Core Text directly

- **[Fact]** `CoreText.framework` is present in the CLT SDK (measured, §0).
- **[Interpretation]** Core Text gives exactly the primitives a diff view needs: `CTLine`,
  `CTTypesetter`, `CTRunDelegate`, precise glyph-run geometry for character-level highlighting, and
  proper shaping/ligature/Unicode handling for free (this matters — Polish diacritics, NFC/NFD, and
  grapheme clusters are already flagged in OQ-003/OQ-004). Building on `CALayer`-backed `NSView`
  subclasses with per-row layers, or a single view that draws visible rows in `draw(_:)`, is a
  well-understood pattern. This is the "custom rendering" option in native clothing, and unlike GPUI
  it does not require the Metal toolchain, so it is buildable with the CLT that are already installed.

### 2.5 Custom GPU rendering — Zed / GPUI as the reference

- **[Fact]** GPUI renders through the GPU with platform backends (Metal on macOS) rather than
  through native text views. <https://github.com/zed-industries/zed/tree/main/crates/gpui>
- **[Fact]** Licensing is deliberately split: Zed the editor is GPL-3.0-or-later; the `gpui` crate is
  Apache-2.0. Confirmed: `crates/gpui/LICENSE-APACHE` is a symlink to the repository-root
  `LICENSE-APACHE`. <https://github.com/zed-industries/zed/blob/main/crates/gpui/LICENSE-APACHE>
  **This split matters:** GPUI is usable in a closed or differently-licensed product; **Zed's editor
  code is not**, and copying rendering code out of `crates/editor` would be a GPL event.
- **[Fact]** Building GPUI requires the Metal toolchain, which requires full Xcode.
  <https://zed.dev/docs/development/macos> · <https://github.com/zed-industries/zed/discussions/7016>
- **[Fact]** GPUI's accessibility story is immature: Zed's own discussions describe menus as
  accessible but "no accessibility to any of the editing functions", with AccessKit integration into
  GPUI still being the plan rather than the state.
  <https://github.com/zed-industries/zed/discussions/6576> ·
  <https://github.com/zed-industries/zed/discussions/8146>
- **[Interpretation]** GPUI is the right thing to *study* and the wrong thing to *adopt* here. It
  answers "how do you make a text surface feel instant" convincingly, but it costs a Rust toolchain
  install, a full Xcode install, and a framework whose accessibility layer is the exact thing DEC-016
  says must not be architecturally foreclosed.

### 2.6 The xi-editor retrospective — a cautionary primary source

- **[Fact]** Raph Levien's xi-editor retrospective concludes "I now firmly believe that the process
  separation between front-end and core was not a good idea", citing races between editing actions and
  word-wrap updates; describes async as making "everything more complicated, in some cases
  considerably so"; reports that regex-based highlighting was ~2500× slower than a proper parser; and
  reports that an OpenGL text renderer sacrificed platform behaviours (emoji rendering failed).
  <https://raphlinus.github.io/xi/2020/06/27/xi-retrospective.html>
- **[Interpretation]** Two directly applicable lessons. First: a hard process boundary between the
  diff engine and the view is a trap if the view needs *synchronous* geometry from engine results —
  which ours does, because alignment gaps determine row heights. Put the boundary at a *thread* or
  *worker* with an explicit "results are a value, rendering is pure" contract, not at a place where
  the renderer must round-trip to lay out. Second: custom text rendering silently drops platform
  behaviours you didn't know you were relying on.

### 2.7 Virtualization strategy — the part that is actually hard

**[Interpretation]** This section is analysis, not sourced fact, but it is the crux and it is
stack-independent.

Side-by-side + alignment gaps forces a specific architecture. The two sides do not have independent
row models: a gap on the left exists precisely because of content on the right. If you build the view
as two independent editors, you must keep two virtualization engines in agreement about heights that
are derived from a shared alignment. That is where synchronized-scroll implementations go wrong.

The alternative is a **single virtual row list** where each row is a pair `(left cell | right cell)`,
and either cell may be empty (a gap). Virtualization then happens once, over rows, not twice over
lines. This is how a purpose-built renderer would naturally be written and it is *against the grain*
of both Monaco and CodeMirror, which virtualize per-document.

Long lines are worse in side-by-side because the horizontal budget is halved and because horizontal
scroll must either be linked (so both sides shift together, which is what a reviewer wants) or
independent (which breaks visual correspondence). Neither Monaco nor CodeMirror horizontally
virtualizes:

- Monaco punts with `stopRenderingLineAfter` (default 10000 chars) — it simply stops drawing. **[Fact]**
- CodeMirror has no solution; issue #29 is closed unresolved. **[Fact]**

Three strategies exist and each has a cost:

1. **Truncate** (Monaco's default). Cheap, and *violates our core invariant* if the truncated region
   contains a difference and that is not disclosed. Only acceptable with an explicit, visible marker.
2. **Wrap** (soft wrap). Makes row heights variable and content-dependent, which makes alignment-gap
   computation depend on measured layout — the exact race xi-editor hit. Also interacts badly with
   character-level intra-line highlighting spanning a wrap point.
3. **Horizontally virtualize**: render only the visible character range of each visible line. Requires
   monospace or per-run measurement to map x-offset to character index. **With a monospaced font and
   no ligatures this is arithmetic** and is the one place where a code-specific renderer has a large
   advantage over a general text component.

**[Interpretation]** Point 3 is a genuine argument for a purpose-built renderer, and it is worth a
spike because it may be much less work than it sounds *given* the read-only + monospace constraints.

### 2.8 Rendering comparison table

| | Monaco (2× plain) | CodeMirror 6 (2× plain) | `@codemirror/merge` | NSTextView / TextKit 2 | Core Text custom | GPU custom (GPUI-style) |
|---|---|---|---|---|---|---|
| External diff accepted | Yes (no diff model used) **[F]** | Yes (no diff model used) **[F]** | Yes since 6.12.0, sync, flat offsets only **[F]** | N/A — no diff model **[F]** | N/A **[F]** | N/A **[F]** |
| Alignment gaps | View zones, public API **[F]** | Block widget decorations **[F]** | Built in **[F]** | Manual layout | Manual layout | Manual layout |
| Char-level intra-line | Range decorations **[F]** | `Decoration.mark` **[F]** | Inline chunk highlight (limited) **[F]** | Attributed string ranges | `CTRun` geometry | Manual |
| Collapsed regions | View zones / folding | Block `replace` decorations **[F]** | `collapseUnchanged` **[F]** | Manual | Manual | Manual |
| Move/wrapper visualization | Overlay widget + line geometry APIs | Overlay + `coordsAtPos` | Not supported | Custom overlay view | Custom overlay | Custom |
| Vertical virtualization | Built in **[F]** | Built in, non-disableable **[F]** | Inherited | Weak above ~10k lines **[U]** | You write it | You write it |
| Long-line handling | Truncates at 10k chars by default **[F]** | Unsolved, issue closed **[F]** | Inherited | Poor | You write it (tractable if monospace) | You write it |
| Syntax highlighting | TextMate/Shiki or Monarch **[F]** | Lezer, or tree-sitter via adapters | Inherited | None built in | None built in | None built in |
| Accessibility baseline | WebKit/Chromium a11y tree | WebKit/Chromium a11y tree | same | `NSAccessibility` for free | You implement `NSAccessibility` | Immature (Zed) **[F]** |
| License | MIT **[F]** | MIT **[F]** | MIT **[F]** | Apple SDK | Apple SDK | Apache-2.0 (gpui) **[F]** |
| Requires full Xcode | No | No | No | No (CLT typecheck OK) **[F]** | No **[F]** | **Yes** (Metal toolchain) **[F]** |
| API stability risk | Only `monaco.d.ts` versioned **[F]** | Public, stable, semver | Public since 6.12.0 **[F]** | Apple SPI risk low | None (our code) | Pre-1.0 framework |

`[F]` = Fact with source above. `[U]` = Unverified.

---

## 3. Syntax highlighting engines

- **[Fact]** **tree-sitter** grammars for TypeScript and TSX exist as separate dialect grammars under
  `tree-sitter/tree-sitter-typescript`.
  <https://github.com/tree-sitter/tree-sitter-typescript>
  Ecosystem packs describe all bundled grammars as permissively licensed (MIT, Apache-2.0, BSD, ISC).
  <https://github.com/Goldziher/tree-sitter-language-pack>
  **[Interpretation]** Licensing is not a blocker here, but "permissive" is a per-grammar property —
  the two grammars we actually need (typescript, tsx) should be checked individually rather than
  trusted to an aggregator's summary.
- **[Fact]** tree-sitter compiles to WASM and `web-tree-sitter` is the supported browser binding
  (<https://github.com/tree-sitter/tree-sitter/discussions/2010>), and native bindings exist for Rust
  and Swift.
  **[Interpretation]** This is the single most stack-portable component in the whole design. Whatever
  the UI stack, tree-sitter is available: native in Swift and Rust, WASM in a webview, native or WASM
  in Node. Since DEC-004 scopes structural diffing to TS/TSX/JS/JSX, **the parser choice does not
  constrain the UI choice**, which is a useful degree of freedom.
- **[Fact]** **Shiki** is MIT and does not maintain grammars itself; grammars come from
  `shikijs/textmate-grammars-themes` and are "covered by their repositories' respective licenses,
  which are permissive (apache-2.0, mit, etc)".
  <https://shiki.style/languages> · <https://github.com/shikijs/textmate-grammars-themes>
- **[Fact]** `vscode-textmate` (the TextMate tokenizer engine VS Code and Shiki build on) is
  Microsoft's, MIT. <https://github.com/microsoft/vscode-textmate>
- **[Fact]** xi-editor measured regex-based (i.e. TextMate-style) highlighting at ~2500× slower than a
  proper parser. <https://raphlinus.github.io/xi/2020/06/27/xi-retrospective.html>
- **Native macOS:** **[Interpretation, low confidence]** I found no evidence that macOS ships any
  system syntax-highlighting API. `NSAttributedString` and Core Text are *presentation* layers with no
  tokenizer. Quick Look's source previews and Xcode's highlighter are not public API. A native stack
  therefore needs tree-sitter (via SwiftTreeSitter or the C library directly) or a hand-written
  tokenizer. I am recording this as interpretation because proving a negative from search is weak;
  it should be spot-checked against the current AppKit/Foundation API diffs.

**[Interpretation]** For this product tree-sitter is the natural choice for a second reason beyond
speed: the diff engine already needs a TS/TSX parse tree for structural matching. Using the same tree
for highlighting means highlight spans and structural nodes share a coordinate system, which makes
OQ-040 (separating the syntax colour system from the change-indication system) a rendering problem
rather than a reconciliation problem. TextMate/Shiki would produce a *second*, independently-derived
token stream that could disagree with the structural model at region boundaries.

---

## 4. Desktop stacks

Notes are per stack; the table in §5 is the summary. Startup/memory figures from secondary sources are
marked **[Unverified]** and should not be used as decision inputs without a spike.

### 4.1 Swift + SwiftUI

- **[Fact]** Compiles CLT-only (measured, §0). SDK 26.2 present.
- **[Fact]** `swift test` unusable CLT-only (measured, §0).
- **[Fact]** No `.app` bundling tool in CLT (measured, §0).
- **[Fact]** SwiftUI has no API to set scroll offset directly; synchronized scrolling is a known
  problem solved by reaching into the underlying scroll view (Introspect) or dropping to AppKit.
  <https://developer.apple.com/forums/thread/675431> ·
  <https://github.com/stonko1994/SimultaneouslyScrollView>
  Apple's own guidance for this is the AppKit document, not a SwiftUI one:
  <https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/NSScrollViewGuide/Articles/SynchroScroll.html>
- **[Interpretation]** DEC-014 makes synchronized side-by-side scrolling a *core* requirement, not a
  nicety — and it is exactly the thing SwiftUI is worst at. Combined with the need for a custom
  virtualized text surface, SwiftUI would end up as a thin chrome around an `NSViewRepresentable`
  wrapping an AppKit/Core Text view. That is a legitimate architecture (it is roughly what several
  shipping Mac apps do), but it should be chosen knowingly, not discovered halfway.
- Appearance/theming, keyboard handling, accessibility: best-in-class, free, live-updating. Nothing to
  research — this is what the platform is for.

### 4.2 Swift + AppKit

- **[Fact]** `AppKit.framework` present and typechecks CLT-only (measured, §0).
- **[Fact]** `NSScrollView` synchronized scrolling is a documented Apple pattern.
  <https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/NSScrollViewGuide/Articles/SynchroScroll.html>
- **[Interpretation]** AppKit gives the control the text rendering needs (custom `NSView` +
  `NSScrollView` + Core Text, per §2.4), keeps system appearance/keyboard/accessibility for the
  *chrome* (sidebar, toolbar, menus) for free, and is the only stack where full keyboard operation
  (DEC-016) is close to free rather than a build. Its costs are: more code for the same chrome than
  SwiftUI, a smaller talent/AI-assistance pool than web stacks, and the packaging friction in §0.

### 4.3 Electron

- **[Fact]** MIT licensed.
- **[Fact]** Official guidance: don't block the main process; "For long running CPU-heavy tasks, make
  use of worker threads, consider moving them to the BrowserWindow, or (as a last resort) spawn a
  dedicated process"; avoid `sendSync`; bundle to a single file because `require()` is expensive.
  <https://www.electronjs.org/docs/latest/tutorial/performance>
- **[Fact]** Signing + notarization are a well-trodden, documented path with first-party tooling
  (`@electron/notarize`, Forge, electron-builder), including the Hardened Runtime requirement.
  <https://www.electronjs.org/docs/latest/tutorial/code-signing> ·
  <https://www.electron.build/docs/features/code-signing/notarization/>
- **[Unverified]** ~150 MB baseline app before any of our code; ~168 MB idle RSS; ~1420 ms cold start.
  These come from comparison blogs, not measurement: <https://www.gethopp.app/blog/tauri-vs-electron>
- **[Interpretation]** Electron's real advantages here are unglamorous and substantial: it is the only
  stack where the diff engine (TypeScript), the renderer, and the test harness are the same language
  and the same runtime, so the "engine runs headlessly in CI" requirement is satisfied by `node
  engine.js fixture/` with zero extra machinery. Its real disadvantage for *this* app is that the
  thing we most need — a fast, custom, virtualized text surface — is the thing Chromium makes
  *adequate but not excellent*, and the price of adequate is ~150 MB and a second copy of a browser.

### 4.4 Tauri v2

- **[Fact]** MIT **or** Apache-2.0 (dual). <https://github.com/tauri-apps/tauri>
- **[Fact]** Renders through WRY into the *system* webview — `WKWebView` on macOS. WRY is Apache-2.0/MIT.
  <https://v2.tauri.app/concept/architecture/>
- **[Fact]** macOS desktop-only development requires Rust + Xcode **Command Line Tools**; full Xcode is
  only required for iOS. <https://v2.tauri.app/start/prerequisites/>
  **[Interpretation]** So Tauri's prerequisite delta on this machine is exactly one thing: install
  Rust. That is a smaller ask than full Xcode.
- **[Unverified]** ~10 MB DMG; ~42 MB idle RSS; ~380 ms cold start; roughly 25× smaller bundle than
  Electron. Same secondary source as above.
- **[Unverified]** WKWebView capped `requestAnimationFrame` at 60 fps on macOS 13–15, and the cap was
  removed in macOS 26. Source is a plugin README, not WebKit or Apple:
  <https://github.com/userFRM/tauri-plugin-macos-fps>
  **[Interpretation]** If true this is *good* news for us specifically (we target macOS 26) and it
  removes what would otherwise have been a real objection to WKWebView for a scroll-heavy surface.
  It is also exactly the kind of claim that must be measured rather than believed. Spike candidate.
- **[Interpretation]** Tauri's structural advantage over Electron here is that it forces a clean
  split: engine in Rust (headless by construction, `cargo test` is trivially CI-able), UI in the
  webview. Its structural disadvantage is that it forces that split whether you want it or not — every
  engine result crosses an IPC/serialization boundary, and per xi-editor's lesson (§2.6) that boundary
  is a hazard if the renderer needs engine output to compute layout. It also means two languages, two
  test suites, and a Rust learning/AI-assist cost from zero.

### 4.5 Others, assessed honestly and briefly

- **Flutter desktop.** **[Fact]** BSD-3 (widely documented). **[Unverified]** macOS is described as
  Flutter's most mature desktop target. <https://softaims.com/blog/flutter-web-desktop-production-ready-2026>
  **[Fact]** Flutter documents its own accessibility layer and known macOS VoiceOver gaps.
  <https://docs.flutter.dev/ui/accessibility>
  **[Interpretation]** Flutter draws everything itself, so it inherits the custom-renderer problem
  (§2.4/2.5) *without* the compensating benefit of being close to the platform, and adds a Dart
  toolchain that is otherwise unused in this workspace. Its text stack is good but is not a code-text
  stack. Not obviously wrong; hard to see what it wins here.
- **.NET MAUI.** **[Fact]** MIT. **[Interpretation]** On macOS, MAUI targets Mac Catalyst (UIKit), not
  AppKit — which means no `NSTextView`, no AppKit menu/keyboard idioms, and a "iPad app on a Mac"
  feel that fights DEC-005/DEC-016. Adds a .NET toolchain from zero. I would treat this as
  effectively disqualified for a macOS-only, keyboard-first, text-rendering-heavy tool, and I'm
  stating that as interpretation rather than pretending it's a measured finding.
- **Qt 6.** **[Fact]** Available under Qt Commercial, GPL-2.0, GPL-3.0, and LGPL-3.0; some modules are
  GPL-only, not LGPL. Static linking under LGPL typically makes the app a derivative work.
  <https://doc.qt.io/qt-6/licensing.html>
  **⚠ Copyleft flag:** given DEC-020 leaves distribution open, Qt is the one mainstream stack here
  whose licence could *retroactively* constrain how this app may be shipped. LGPL dynamic linking is
  workable but imposes relinking obligations; GPL-only modules are a trap; the commercial licence is
  a per-seat cost. **[Interpretation]** Technically Qt would do this job well (`QPlainTextEdit`
  lineage, mature virtualization). The licence, plus a toolchain install from zero, plus a
  non-native-feeling macOS shell, is a lot to accept for a personal tool.
- **Compose Multiplatform / Kotlin desktop.** **[Interpretation]** Apache-2.0, mature-ish, but runs on
  a JVM, draws everything with Skia (same custom-renderer trade-offs as Flutter), and adds a JVM
  toolchain. Same shape of objection as Flutter. Not researched further.
- **Wails (Go + WKWebView).** **[Interpretation]** Structurally near-identical to Tauri with Go
  instead of Rust; smaller ecosystem, less mature macOS integration. If the webview path is chosen,
  Tauri is the stronger member of that family. Not researched further.
- **Hybrid: native shell + embedded webview for the diff pane.** **[Interpretation]** Worth naming
  explicitly because it is not on anyone's list of "stacks" but is a real option: AppKit/SwiftUI for
  the window, sidebar, menus, keyboard map, and accessibility; a `WKWebView` hosting CodeMirror or a
  bespoke DOM renderer for the diff pane only. You get platform-native chrome and keyboard/a11y where
  those matter most, and DOM/CSS text rendering where the custom work is. Costs: two worlds, a
  bridge, and the theming problem doubles (system appearance must be pushed into the webview).

---

## 5. Stack comparison table

Legend: **[F]** verified, **[U]** unverified/secondary, **[I]** interpretation.

| | Swift + SwiftUI | Swift + AppKit | Electron | Tauri v2 | Flutter | Qt 6 | .NET MAUI |
|---|---|---|---|---|---|---|---|
| Toolchain to install here | none for build; **full Xcode for `swift test`** **[F]** | same **[F]** | none (Node present) **[F]** | **Rust** (CLT suffice) **[F]** | Flutter+Dart | Qt+toolchain | .NET |
| `.app` bundling without Xcode | manual scripting **[F]** | manual scripting **[F]** | Forge/builder **[F]** | `tauri build` **[F]** | `flutter build macos` | qmake/CMake | dotnet CLI |
| Signing + notarization | `codesign`/`notarytool`/`stapler` present **[F]** | same **[F]** | first-party docs **[F]** | built-in bundler **[F]** | supported | supported | supported |
| Bundle size | small **[I]** | small **[I]** | ~150 MB **[U]** | ~10 MB **[U]** | ~40 MB **[U]** | 20–60 MB **[U]** | large **[U]** |
| Idle memory | low **[I]** | low **[I]** | ~168 MB **[U]** | ~42 MB **[U]** | moderate **[U]** | low **[U]** | moderate **[U]** |
| Cold start | fast **[I]** | fast **[I]** | ~1420 ms **[U]** | ~380 ms **[U]** | moderate **[U]** | fast **[U]** | slow **[U]** |
| Heavy engine off the UI thread | Swift concurrency / `DispatchQueue` — same process **[I]** | same **[I]** | `worker_threads` / `utilityProcess`, official guidance **[F]** | Rust threads/`tokio`, engine already off-thread by architecture **[I]** | isolates | `QThread` | tasks |
| Engine runs headlessly | `swift build`/`swift run` ✅ **[F]**; `swift test` ❌ CLT-only **[F]** | same **[F]** | `node engine.js` — trivial **[I]** | `cargo test` — trivial **[I]** | `dart test` | ctest | dotnet test |
| System appearance live switch | free **[I]** | free **[I]** | `nativeTheme` + `prefers-color-scheme` **[I]** | `prefers-color-scheme` in WKWebView **[I]** | manual | manual | Catalyst |
| Keyboard-first operation (DEC-016) | good | **best** — menus/responder chain **[I]** | manual, must build accelerator map **[I]** | manual **[I]** | manual | good | poor on macOS **[I]** |
| Accessibility ceiling | native `NSAccessibility` | native `NSAccessibility` | WebKit/Chromium a11y tree, good for DOM **[I]** | WKWebView a11y tree **[I]** | own layer, gaps documented **[F]** | own layer | Catalyst |
| File watching | FSEvents / `DispatchSource` | same | `fs.watch`/chokidar | `notify` crate | packages | `QFileSystemWatcher` | FileSystemWatcher |
| Custom text rendering effort | **high** — must build it **[I]** | **high** — must build it **[I]** | **low** — Monaco/CM/DOM **[I]** | **low** — same **[I]** | high | medium | high |
| Licence | Apple SDK (proprietary, free to use); Swift Apache-2.0 w/ runtime exception | same | MIT **[F]** | MIT/Apache-2.0 **[F]** | BSD-3 | **GPL/LGPL/commercial ⚠** **[F]** | MIT |
| Copyleft exposure | none | none | none | none | none | **yes — see §6.1** | none |

---

## 6. Cross-cutting concerns

### 6.1 Licensing — copyleft flags first

DEC-020 leaves distribution undecided, and OQ-002's carried-forward note is explicit: a strongly
copyleft dependency would *quietly foreclose* commercial or closed distribution. Flagging accordingly.

**⚠ Copyleft / restricted:**

- **Qt 6** — GPL-2.0 / GPL-3.0 / LGPL-3.0 / commercial. Some modules GPL-only. Static linking under
  LGPL generally makes the app a derivative work. **[Fact]** <https://doc.qt.io/qt-6/licensing.html>
- **Zed's editor crates** — GPL-3.0-or-later. Only `gpui` is Apache-2.0. Copying rendering code out of
  `crates/editor` is a GPL event; using `gpui` is not. **[Fact]**
  <https://github.com/zed-industries/zed/blob/main/crates/gpui/LICENSE-APACHE>
- **libgit2** — GPL-2.0 **with a linking exception**: you may link it from proprietary software, but
  if you *modify libgit2 itself* you must distribute your modified source. **[Fact]**
  <https://github.com/libgit2/libgit2>
  **[Interpretation]** Usable, but "we vendored and patched libgit2" would be a distribution
  obligation. Note this in OQ-010.
- **git CLI itself** — GPL-2.0-only. **[Interpretation]** Invoking the system `git` as a subprocess is
  not linking and creates no obligation; *bundling* a `git` binary in the `.app` would. Phase 0
  already establishes we shell out to the system git, so this is currently a non-issue — but it
  becomes one the moment anyone proposes shipping a git binary for reproducibility.

**Permissive, no flag:**

| Component | Licence | Source |
|---|---|---|
| Monaco Editor | MIT | <https://github.com/microsoft/monaco-editor> **[F]** |
| CodeMirror 6 / `@codemirror/merge` | MIT | <https://github.com/codemirror/merge> **[F]** |
| Shiki | MIT (grammars separately, permissive) | <https://shiki.style/languages> **[F]** |
| `vscode-textmate` | MIT | <https://github.com/microsoft/vscode-textmate> **[F]** |
| tree-sitter + TS/TSX grammars | MIT / permissive per grammar | <https://github.com/tree-sitter/tree-sitter-typescript> **[F]** |
| Electron | MIT | **[F]** |
| Tauri / WRY | MIT or Apache-2.0 | <https://github.com/tauri-apps/tauri> **[F]** |
| GPUI | Apache-2.0 | **[F]** |
| gitoxide (`gix`) | MIT **or** Apache-2.0 | <https://github.com/GitoxideLabs/gitoxide> **[F]** |
| `CodeEditTextView` | MIT | <https://github.com/CodeEditApp/CodeEditTextView> **[F]** |
| STTextView | MIT (per repo) | <https://github.com/krzyzanowskim/STTextView> **[U]** — confirm |
| Flutter | BSD-3 | **[U]** — widely documented, not fetched |
| Swift toolchain | Apache-2.0 w/ Runtime Library Exception | **[U]** — widely documented, not fetched |

**[Interpretation]** Licensing does not eliminate any stack except Qt-under-a-closed-licence, and it
does not eliminate any rendering option. The realistic licensing risks in this project are all in the
**Git access layer** (OQ-010), not in the UI layer: libgit2's modification clause and any temptation
to bundle git. gitoxide's MIT/Apache dual licence is the cleanest option on that axis, but it is only
available on a Rust path.

### 6.2 Running the engine headlessly (hard requirement)

**[Fact]** Measured (§0): Swift executables build and run headlessly CLT-only; `swift test` does not.
**[Interpretation]** Ranking by how little machinery a CI fixture run needs:

1. **TypeScript engine** (Electron path, or engine-only): `node engine.js`. Zero extra machinery.
   Vitest/node:test already available.
2. **Rust engine** (Tauri path): `cargo test`, `cargo run`. Zero extra machinery *after* installing
   Rust. Rust's fixture/snapshot testing ecosystem (`insta`, `proptest`) is unusually good, and
   OQ-037 explicitly wants property-based testing.
3. **Swift engine**: `swift run` works; `swift test` needs full Xcode or a hand-rolled CLI harness.
   Swift also has `swift-testing` but see §0. Property-based testing in Swift is thin
   (`SwiftCheck` is dormant) — **[Interpretation]**, worth confirming.

**[Interpretation]** This criterion cuts *against* Swift more sharply than any performance argument
does, because OQ-037 and the entire Phase 6 corpus plan depend on cheap headless invariant testing,
and the core invariant (OQ-003) is exactly the kind of thing property-based testing exists for.

### 6.3 Compute-heavy engine without blocking the UI

- **Electron: [Fact]** official guidance is `worker_threads` first, `utilityProcess` second, and never
  `sendSync`. <https://www.electronjs.org/docs/latest/tutorial/performance>
- **Tauri: [Interpretation]** the engine is already in a different process-space from the renderer by
  construction; the question becomes serialization cost of diff results across the IPC boundary, which
  for a large structural diff is non-trivial and should be measured.
- **Swift/AppKit: [Interpretation]** same process, structured concurrency or a dedicated queue.
  Cheapest possible result hand-off (no serialization at all) — this is the strongest architectural
  argument for a single-language native stack, and it directly addresses xi-editor's lesson (§2.6).
- **[Interpretation]** Note the asymmetry: our results are *large* (a structural diff of a 63-file
  working tree with per-character alignment data). Stacks with a serialization boundary pay for that
  size on every scope switch; stacks without one do not. This is measurable and should be a spike.

### 6.4 Packaging, signing, sandboxing

- **[Fact]** `codesign`, `notarytool`, `stapler` all present CLT-only (§0). Notarization does not
  require Xcode. <https://developer.apple.com/forums/thread/724780>
- **[Fact]** App Sandbox access to user-chosen directories that persists across launches requires
  security-scoped bookmarks (`com.apple.security.files.bookmarks.app-scope`) and
  `startAccessingSecurityScopedResource()`.
  <https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html>
- **[Interpretation]** OQ-035's tension is real and concrete: the app scans a configurable root
  (default `~/WebstormProjects`) and launches an external editor (DEC-015). Under App Sandbox the scan
  root needs a user-granted, bookmarked folder — workable, one-time friction. Launching WebStorm from
  a sandboxed app is the harder half. Outside the App Store (Developer ID + notarization), sandboxing
  is optional, and given DEC-020 ("personal tool, distribution undecided") the low-friction path is
  Developer ID without sandbox, with the App Store path kept open by not *architecturally* depending
  on unsandboxed behaviour. **[Fact]** Notarization requires Hardened Runtime for Electron
  (<https://www.electron.build/docs/features/code-signing/notarization/>) and in practice for
  everything else too.
- **[Fact]** No network access is required at all (project constraint). **[Interpretation]** This
  genuinely simplifies things: no `com.apple.security.network.client` entitlement, no ATS
  configuration, and in an Electron/Tauri path a maximally restrictive CSP with no remote origins,
  which removes the single largest class of webview security concern.

### 6.5 macOS integration maturity

- **System appearance, live switching (DEC-019): [Interpretation]** free and automatic on
  AppKit/SwiftUI. In a webview, `prefers-color-scheme` is the mechanism and it is supported in WebKit;
  Electron additionally exposes `nativeTheme`. WebKit documents `prefers-contrast` and
  `prefers-reduced-motion` alongside it, mapping to macOS "Increase contrast" and "Reduce motion".
  <https://webkit.org/blog/13966/webkit-features-in-safari-16-4/>
  **[Interpretation]** So DEC-016's "respect system contrast and reduced-motion" is achievable in
  either world, but on a webview path it needs *deliberate CSS*, whereas natively much of it is
  inherited. Neither is free; the native one has a shorter distance to travel.
- **Keyboard (DEC-016, OQ-023): [Interpretation]** AppKit's responder chain + menu key equivalents is
  the only mechanism among these that gives a *complete, discoverable, system-integrated* keyboard map
  more or less for free, including "every menu item is a shortcut" and system key-repeat/accessibility
  behaviour. Web stacks require building the whole map by hand and are easy to get subtly wrong
  (focus management, focus rings, `Tab` order in a virtualized list).
- **Accessibility ceiling: [Interpretation]** DEC-016 defers screen-reader support but requires that
  it not be *architecturally impossible*. Ranking by how possible it remains: native AppKit views
  (`NSAccessibility` protocols, well-documented) > DOM in a webview (WebKit exposes an a11y tree from
  ARIA — but a *virtualized* list is a known hazard, since off-screen rows genuinely do not exist) >
  custom-drawn native (you implement the whole a11y tree yourself) > GPUI today (Zed's own
  discussions describe editing functions as inaccessible; AccessKit is the plan, not the state
  — **[Fact]**, <https://github.com/zed-industries/zed/discussions/6576>).
  **[Interpretation]** Custom rendering, in *any* stack, is where the accessibility commitment is most
  at risk. That is true equally of a Core Text view and a canvas-based DOM renderer, and it is the
  strongest argument for keeping the diff content in real DOM nodes or real `NSAccessibilityElement`s
  rather than pixels.
- **File watching (DEC-007, OQ-039): [Interpretation]** all stacks have a route (FSEvents natively,
  `notify` in Rust, chokidar/`fs.watch` in Node). The open question — WebStorm's atomic-replace saves
  producing rename events rather than write events — is a *platform* question, not a stack question,
  and its answer applies to all candidates. It should be spiked once, in whatever is cheapest.

---

## 7. Open questions raised by this research

New, or newly sharpened, relative to `05-open-questions.md`:

- **R-1.** What do Monaco's `'advanced-external'` and `'advanced-wasm'` `diffAlgorithm` values
  actually select? If either is a genuine extension point, the §1.2 conclusion needs revision.
  Resolvable by reading `vs/editor/browser/widget/diffEditor/` in the VS Code source. ~30 min.
- **R-2.** Is `@codemirror/merge` still actively maintained after the 2026-04-15 GitHub archive/move
  to `code.haverbeke.berlin`? Depending on it for a core feature needs an answer.
- **R-3.** Is the "WKWebView 60 fps cap removed in macOS 26" claim true? Single secondary source.
  Directly affects whether a webview is acceptable for a scroll-heavy surface on a ProMotion display.
- **R-4.** Does macOS expose *any* system syntax-highlighting/tokenizing API? I could not find one and
  am asserting a negative from absence of evidence.
- **R-5.** Can `swift test` be made to work CLT-only with the right SwiftPM configuration (rpath /
  `LD_RUNPATH_SEARCH_PATHS`), or is full Xcode genuinely required? §0 shows it builds and links but
  fails to `dlopen`. If solvable, the §6.2 ranking changes.
- **R-6.** What is the serialization cost of a full structural diff result crossing an IPC boundary
  (Tauri) or a worker boundary (Electron), for the largest realistic case (the 63-changed-file
  working tree in `mailingi-2025`)? Unknown and potentially decisive.
- **R-7.** Which of the three long-line strategies (§2.7) is compatible with the core invariant?
  Truncation as Monaco does it by default appears to violate it unless the truncation is disclosed.
- **R-8.** For a native path, what is the actual effort to implement text *selection and copy* across
  a virtualized two-pane Core Text view? This is the most commonly underestimated item in §2.4 and
  no source I found quantifies it.
- **R-9.** Are the individual `tree-sitter-typescript` and `tree-sitter-tsx` grammar licences
  confirmed permissive at the file level (not just per an aggregator's summary)?

---

## 8. Recommended spikes

Ordered by how much uncertainty they remove per hour. Each is timeboxed and has a stated kill
criterion, so a spike can fail fast rather than becoming a prototype.

### S-1 · Rendering feasibility bake-off — **2 days, hard stop**

The single highest-value experiment. Build *the same* narrow scene three ways: a 5,000-line TSX file
pair, side-by-side, with 40 alignment gaps, character-level intra-line marks on 200 lines, 3 collapsed
regions, and one move connector drawn between panes. Read-only, no interaction beyond scrolling.

Variants:
- (a) two plain CodeMirror 6 `EditorView`s + decorations + block widgets;
- (b) two plain Monaco editors + decorations + view zones;
- (c) hand-written DOM renderer over a single virtual row list (§2.7), no editor component.

Measure: time-to-first-paint, scroll frame time at 120 Hz, memory, and lines-of-code. Run all three in
a plain browser first — none of them needs a desktop shell to answer the question.

**Kill criterion:** any variant that cannot hold 120 Hz scroll on this scene is out.
**Settles:** OQ-033 partially, R-7, and the "editor component vs purpose-built renderer" fork in §1.4.

### S-2 · Long-line torture test — **half a day**

Same three variants, but one file pair containing a single 1 MB minified line plus several 20k-char
lines, side-by-side with linked horizontal scroll. This is where Monaco truncates by default and
CodeMirror has no answer (§2.7).

**Settles:** R-7, OQ-029, and whether "large/minified file" needs to be a distinct *rendering* mode
rather than only an engine-level classification.

### S-3 · Swift headless-test resolution — **2 hours**

Follow §0's dead end: try SwiftPM `linkerSettings` / `unsafeFlags` with `-rpath` pointing at
`/Library/Developer/CommandLineTools/Library/Developer/Frameworks`, and try `swift build` +
`--build-tests` + direct execution of the test binary. Determine definitively whether Swift is
testable headlessly without Xcode.

**Kill criterion:** if it needs full Xcode, record that as a hard prerequisite on every Swift path.
**Settles:** R-5, and materially affects OQ-037.

### S-4 · IPC / worker payload cost — **half a day**

Serialize a realistic structural-diff result (synthesize one at the right *shape* and size —
per-character alignment spans for a 63-file working tree) and measure round-trip cost across (a)
Electron `worker_threads` with structured clone, (b) Tauri's IPC with JSON, (c) Tauri with a binary
channel. Compare against the zero-cost in-process baseline.

**Settles:** R-6, §6.3, and quantifies the real cost of the Tauri architecture's forced split.

### S-5 · Monaco extension-point source read — **30 minutes**

Read `vs/editor/browser/widget/diffEditor/` and `diffProviderFactoryService` in VS Code's source.
Determine what `'advanced-external'` is and whether any supported seam exists.

**Settles:** R-1. Cheapest item on this list; do it before S-1 so S-1(b) is designed correctly.

### S-6 · tree-sitter in three hosts — **1 day**

Parse `tree-sitter-tsx` over the largest TSX file in the repository population from (a) Node via
`web-tree-sitter` WASM, (b) Node via native binding, (c) Swift via `SwiftTreeSitter`. Measure parse
time and incremental re-parse time. Confirm grammar licences at the file level while there.

**Settles:** R-9, confirms §3's claim that the parser choice doesn't constrain the UI choice, and
produces the first real number for OQ-031.

### S-7 · Platform behaviour probes — **half a day, stack-independent**

Three unrelated platform facts that every candidate stack needs and that only need answering once:
(a) what FSEvents actually emits for a WebStorm atomic-replace save, and how many events per save
(OQ-039, and the DEC-007 debounce value depends on it); (b) cold-cache `git status` sweep timing
across all 21 repositories, since Phase 0's numbers are warm-cache only (OQ-012); (c) whether
WKWebView on macOS 26 renders above 60 fps (R-3) — a `requestAnimationFrame` counter in a Safari
window is sufficient.

### S-8 · Native text-view reality check — **2 days, only if S-1(c) wins or S-1 is inconclusive**

Build variant (c) of S-1 as an AppKit `NSView` + Core Text over `NSScrollView`, with synchronized
scrolling per Apple's documented pattern, and implement *selection and copy across both panes*. The
selection requirement is the point of the spike, not the rendering.

**Kill criterion:** if selection + copy is not working at the end of day 2, treat native custom text
rendering as a multi-week item and price it accordingly in Phase 7.
**Settles:** R-8, and the largest unknown on the native path.

---

## 9. Source index

Primary and near-primary sources used, grouped.

**Monaco / diff API**
- <https://github.com/microsoft/monaco-editor>
- <https://raw.githubusercontent.com/microsoft/vscode/main/src/vs/editor/common/config/editorOptions.ts>
- <https://microsoft.github.io/monaco-editor/typedoc/interfaces/editor_editor_api.editor.IDiffEditorOptions.html>
- <https://microsoft.github.io/monaco-editor/typedoc/interfaces/editor_editor_api.editor.IStandaloneEditorConstructionOptions.html>
- <https://microsoft.github.io/monaco-editor/typedoc/interfaces/editor.IViewZone.html>
- <https://microsoft.github.io/monaco-editor/typedoc/interfaces/editor.IViewZoneChangeAccessor.html>
- <https://github.com/microsoft/monaco-editor/issues/4264>
- <https://github.com/microsoft/monaco-editor/issues/4764>

**CodeMirror**
- <https://codemirror.net/docs/ref/>
- <https://github.com/codemirror/merge>
- <https://github.com/codemirror/merge/blob/main/CHANGELOG.md>
- <https://raw.githubusercontent.com/codemirror/merge/main/src/diff.ts>
- <https://discuss.codemirror.net/t/providing-own-diff-mechanism-in-mergeview/6875>
- <https://discuss.codemirror.net/t/viewport-issues-with-cm-6/3586>
- <https://github.com/codemirror/dev/issues/29>

**Native macOS text rendering**
- <https://github.com/krzyzanowskim/STTextView>
- <https://christiantietze.de/posts/2022/05/sttextview-textkit-2-editor-without-nstextview/>
- <https://github.com/CodeEditApp/CodeEditTextView>
- <https://mjtsai.com/blog/2025/08/15/textkit-2-the-promised-land/>
- <https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/NSScrollViewGuide/Articles/SynchroScroll.html>
- <https://developer.apple.com/forums/thread/675431>

**Custom / GPU rendering**
- <https://github.com/zed-industries/zed/tree/main/crates/gpui>
- <https://github.com/zed-industries/zed/blob/main/crates/gpui/LICENSE-APACHE>
- <https://zed.dev/docs/development/macos>
- <https://github.com/zed-industries/zed/discussions/7016>
- <https://github.com/zed-industries/zed/discussions/6576>
- <https://github.com/zed-industries/zed/discussions/8146>
- <https://raphlinus.github.io/xi/2020/06/27/xi-retrospective.html>

**Syntax highlighting**
- <https://github.com/tree-sitter/tree-sitter-typescript>
- <https://github.com/tree-sitter/tree-sitter/discussions/2010>
- <https://shiki.style/languages>
- <https://github.com/shikijs/textmate-grammars-themes>
- <https://github.com/microsoft/vscode-textmate>

**Stacks**
- <https://www.electronjs.org/docs/latest/tutorial/performance>
- <https://www.electronjs.org/docs/latest/tutorial/code-signing>
- <https://www.electron.build/docs/features/code-signing/notarization/>
- <https://v2.tauri.app/start/prerequisites/>
- <https://v2.tauri.app/concept/architecture/>
- <https://github.com/tauri-apps/tauri>
- <https://doc.qt.io/qt-6/licensing.html>
- <https://docs.flutter.dev/ui/accessibility>

**Platform / packaging / licensing**
- <https://developer.apple.com/forums/thread/724780>
- <https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html>
- <https://webkit.org/blog/13966/webkit-features-in-safari-16-4/>
- <https://github.com/libgit2/libgit2>
- <https://github.com/GitoxideLabs/gitoxide>

**Secondary sources (treated as leads only)**
- <https://www.gethopp.app/blog/tauri-vs-electron> — Tauri/Electron size, memory, startup figures
- <https://github.com/userFRM/tauri-plugin-macos-fps> — WKWebView frame-rate cap claim
- <https://softaims.com/blog/flutter-web-desktop-production-ready-2026> — Flutter desktop maturity
</content>
