# 06 — Domain Research (synthesis)

**Status:** Phase 2 complete. Synthesis and index; detail lives in [research/domain-existing-tools.md](research/domain-existing-tools.md), which carries the citations.

The objective was **not** a competitor comparison. It was to find what is already documented to go wrong with structural diffing, so those failures are not rediscovered.

---

## 1. The single most transferable finding

**Users report "no difference, but I suppressed some" as a bug.** JetBrains YouTrack IDEA-22363 records exactly this. Difftastic's `No syntactic changes.` is a real-world instance of the same failure.

This is independent confirmation of the core invariant from a direction the brief did not anticipate: it is not only a correctness principle, it is a **usability** finding. Users experience suppression as malfunction.

Difftastic already distinguishes internally between `No changes.` (byte-identical) and `No syntactic changes.` (differs, but not structurally). The product opportunity is to take that distinction and make it **visible and actionable** — the equivalent state here must read as *"no structural changes; 14 formatting differences (expand)"*, with the differences one interaction away.

## 2. Why existing engines cannot be reused

**Difftastic** is the closest existing tool in spirit, and is unusable as a dependency:

- It is a **binary-only crate** — `[[bin]] name = "difft"`, no `src/lib.rs`. There is no library API.
- Its JSON output emits **only changed regions** with per-line column offsets, and **cannot reconstruct either file**.
- Its model discards exactly the information the invariant requires: inter-token whitespace is not stored, blank-line changes are invisible by design, and `--strip-cr` defaults to on.

It is an excellent **reference implementation and test oracle**, and that is how the test corpus should use it.

**GumTree** produces a tree edit script, which is the wrong output shape for a byte partition (DEC-029), and is LGPL-3.0 (DEC-030).

**SemanticDiff** is the product built on the opposite premise — its published Invariances list enumerates what it deliberately does not show. That list is directly useful **inverted**: every entry becomes a *label* in our classification vocabulary rather than a suppression rule — `paren-only`, `literal-base`, `escape-style`, `trailing-comma`, `quote-style`, `object-key-reorder`, `jsx-attr-reorder`, `jsx-whitespace`, `import-reorder`, `tailwind-class-reorder`, `arrow-vs-function`. A collapsed group is *a claim about* the bytes; the bytes stay.

## 3. Documented failure modes to design against

**3.1 What gets lost.** Concrete checklist derived from real reported defects: inter-token whitespace, indentation as a first-class dimension (difftastic #587/#818/#942 — correctness-critical for Python and YAML, still wanted by reviewers in JSX/TS), blank-line insertion and removal, CR/LF, trailing whitespace, and whitespace *inside* string literals and JSX text nodes.

Note VS Code's `ignoreTrimWhitespace` **defaults to true** — a mainstream diff viewer hides whitespace changes by default.

**3.2 Repeated identical siblings are the common case.** 76% of commits contain at least one instance (TOSEM 2024). This drove DEC-031.

**3.3 Moves.** Git's `--color-moved` uses whole-line equality — it cannot express *moved and modified* — and applies a 20-alphanumeric-character floor that silently drops small moves. SemanticDiff collapses moves to delete-plus-add by default. The recommended model is `Move { fromRange, toRange, innerDiff }` with `innerDiff` empty **iff** the moved bytes are identical.

**3.4 Performance cliffs are about node count, not bytes.** difftastic #373 records a moderate-size lockfile consuming 64 GB. Starting budgets from difftastic: ~1 MB byte limit, ~3M graph vertices — but budget primarily on nodes.

**3.5 Parse failure is the common case in a desktop tool** watching a working tree. Requirements: always render a complete diff, structural or not (Git's guarantee); treat tree-sitter `ERROR` nodes as opaque atoms; **exclude zero-width `MISSING` nodes from the partition** and represent them as annotations; handle conflict markers natively (difftastic v0.50 is precedent); and reject SemanticDiff's fail-with-an-error behavior.

**3.6 Cost-model tuning never finishes.** Both maintainer sources say minimality is the wrong objective. Two mitigations they each adopted: a secondary pass choosing the most legible among equal-cost results, and a corpus of adversarial fixtures.

## 4. Where this product differs from everything surveyed

- **No surveyed tool makes a losslessness or coverage guarantee.** They guarantee readability instead. This is simultaneously the risk and the opportunity.
- **No surveyed tool exposes matcher ambiguity**, although GumTree computes it internally (DEC-031).
- **No surveyed tool builds the byte partition as the primitive** (DEC-024).
- Because the invariant forbids suppression, difftastic's Tricky Cases become **regression tests with checkable pass conditions** — the bytes must all still be present. Difftastic and GumTree structurally cannot test for that.

## 5. Fixtures to import verbatim

Difftastic's Tricky Cases list, seeded into the corpus: delimiter add/change/expand/contract, disconnected delimiters, rewrapping large nodes, middle insertions, punctuation atoms, trailing punctuation, flat and nested sliders, minimising depth changes, replacements with minor similarities, matching substrings in comments, multiline and reflowed comments, small changes to large strings, novel blank lines, invalid syntax.

Plus the JSX-specific set already in [15-test-corpus-plan.md](15-test-corpus-plan.md): wrapper removal with N children preserved, N near-identical siblings with one edited, prop reordering, Prettier reflow, Tailwind class reorder, import reordering.
