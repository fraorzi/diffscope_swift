# Domain research: what is already known to go wrong with structural diffing

**Purpose.** Phase 2 domain research. This document is *not* a competitor matrix. It records
documented failure modes, maintainer statements, and measured accuracy results for
structural / syntax-aware diff tools, so that DiffScope does not rediscover known failures.

**Governing invariant being tested against.** Structural analysis may change *alignment,
grouping, labelling and presentation*. It must never *suppress or discard* a textual
difference. Exact source text is the source of truth.

**Method.** Primary sources only: official repos and manuals, maintainer blog posts, source
code of the tools themselves, issue trackers, and peer-reviewed papers. Every claim in
"Verified facts" has a URL. Quotes are kept short and attributed. Where I could not verify
something, it is in "Open questions" rather than asserted.

**Date of research:** 2026-07-26.

---

## 1. Verified facts

### 1.1 Difftastic

Repo: <https://github.com/Wilfred/difftastic> · Manual: <https://difftastic.wilfred.me.uk/>

#### 1.1.1 What it explicitly does not show

| Fact | Source |
| --- | --- |
| README states difftastic "ignores whitespace that isn't syntactically significant". | <https://github.com/Wilfred/difftastic#can-difftastic-do-merges> (README "Can difftastic do merges?") |
| Same section: "AST diffing is a lossy process from the perspective of a text diff." Given as the reason difftastic cannot do merges. | README, same section |
| The internal simplified syntax tree stores only node content and node position; the manual says "It does not store whitespace between nodes, and position is ignored during diffing." (section heading is literally *Lossy Syntax Trees*) | <https://difftastic.wilfred.me.uk/parsing.html> ; source: `manual/src/parsing.md` |
| Blank lines are invisible to the syntactic diff. Manual: "Generally we want syntactic diffing to ignore blank lines." and immediately concedes "This is occasionally problematic, as it can hide accidental code reformatting." Three worked examples are given where blank-line insertions/removals are simply not reported. | <https://difftastic.wilfred.me.uk/tricky_cases.html#novel-blank-lines> |
| `--strip-cr` **defaults to `on`**. Help text: carriage returns are removed *before* diffing. With the default, a CRLF↔LF line-ending change is invisible. Turning it off is what makes difftastic "consider multiline string literals ... to differ if the two input files have different line endings". | `src/options.rs`, `Arg::new("strip-cr") … .default_value("on")` — <https://github.com/Wilfred/difftastic/blob/master/src/options.rs> |
| `--ignore-comments` exists as an opt-in filter ("Don't consider comments when diffing"). Off by default. | `src/options.rs` |
| Difftastic distinguishes two "no output" states in code: `"No changes."` when `lhs_src == rhs_src` (byte-identical) versus `"No syntactic changes."` when the bytes differ but the tree does not. | `src/main.rs`, `print_diff_result` — <https://github.com/Wilfred/difftastic/blob/master/src/main.rs> |

#### 1.1.2 Where "no syntactic changes" is provably wrong

The README claims the parse-error fallback is "a conservative choice to ensure that difftastic
never claims that two syntactically different files are the same." That guarantee is violated
in practice for indentation-significant languages:

- **Issue #587 — "Significant whitespace changes (e.g. in Python) are ignored"**, opened
  2023-10-25, **still open**. Reporter shows two Python files where an `if` block is dedented
  one level (a real behaviour change) and `difft` prints `No syntactic changes.` The reporter
  verified with `--dump-syntax` that the two syntax trees genuinely differ, i.e. the
  information was available and was lost downstream of parsing.
  <https://github.com/Wilfred/difftastic/issues/587>
- **Issue #818** (closed) reproduces the same class of bug with a contrived Python file where
  `print(foo)` moves out of a function body — the two files print *different values* at
  runtime and difftastic reports no syntactic changes.
  <https://github.com/Wilfred/difftastic/issues/818>
- **Issue #942** (closed, 2026-01) shows a real `pwndbg` commit where an entire `if/elif`
  restructuring by dedent is invisible in difftastic and clearly visible in `git diff`.
  <https://github.com/Wilfred/difftastic/issues/942>
- PR **#984** "Display relevant indentations (fixes #587)" is **open**, i.e. unfixed as of this
  research. <https://github.com/Wilfred/difftastic/pull/984>

This is the single most important precedent for DiffScope: a structural differ that drops
whitespace from its internal model can report *"no changes"* on a diff that changes program
behaviour.

#### 1.1.3 Display-layer failures (alignment quality)

- **Issue #857** (open, 2025-07): difftastic's `--display=inline` omits unchanged context lines
  inside a changed region, so a struct field that was *not* touched reads as replaced. Reporter
  attaches the plain `diff -u` output showing the truth.
  <https://github.com/Wilfred/difftastic/issues/857>
- **Issue #729** (open, 2024-06): "Wrong diff highlights for a lot of unchanged lines".
  <https://github.com/Wilfred/difftastic/issues/729>
- README, Known Issues: "Display. Difftastic has a side-by-side display which usually works
  well, but can be confusing."

#### 1.1.4 Documented "tricky cases" (maintainer's own list)

The manual has a whole page enumerating cases tree diffing gets wrong, prefaced with "Not all
of these cases work well in difftastic yet."
<https://difftastic.wilfred.me.uk/tricky_cases.html>

Cases relevant to a JSX/TS product:

- **Adding / changing / expanding / contracting delimiters** — wrapping `x` in `(x)` should
  highlight only the delimiters. Difftastic handles the simple wrap case (nodes are considered
  equal at different depths), but the *expanding delimiter* case `(x) y` → `(x y)` is explicitly
  "sensitive to the cost model" and has flipped between releases.
- **Rewrapping large nodes** — `[[foo]] (x y)` → `([[foo]] x y)`; a naive syntax differ prefers
  "remove `()`, add `()`" as more minimal. Tracked as issue #44.
- **Middle insertions** — `foo(bar(123))` → `foo(extra(bar(123)))`. Called out as "challenging
  for diffing algorithms that do a bottom-up then top-down matching of trees" — that is exactly
  GumTree's shape.
- **Punctuation atoms** — `foo(1, bar)` → `foo(bar, 2)`. Two candidate anchors (`bar` or `,`),
  can't keep both because they reorder. Difftastic hard-codes a small list of punctuation
  characters that get lower priority. Language-agnostic solution is stated as difficult.
- **Trailing punctuation** — trailing commas. Difftastic solves it by declaring per-language
  AST node types (list literals etc.) where trailing punctuation "doesn't matter", i.e. a
  deliberate, configured suppression of a real character difference.
- **Sliders, flat and nested** — the classic ambiguity where two placements have identical
  edit cost. Manual: from an LCS perspective "these two choices are equivalent". The nested
  variant is explicitly language-dependent: "Most languages want to prefer the inner
  delimiter, whereas Lisps and JSON prefer the outer delimiter."
- **Replacements with minor similarities** — replacing a whole function produces a confusing
  diff of many tiny matches on `function`, `(`, `)`, `{`, `}`. Manual notes this problem exists
  in line diffs too but "The more precise, granular behaviour of tree diffs makes this problem
  much more common though."
- **Small changes to large strings** — a string literal is one atom. Manual concedes it is
  correct but unhelpful to mark the whole literal novel, and that splitting strings on spaces
  breaks because users still want to see `" "` vs `"  "`.
- **Unordered data types** — difftastic always treats order as meaningful. The manual cites the
  survey result that unordered tree diffing is NP-hard (and MAX SNP-hard).
- **Multiline comments / reflowing doc comments** — difftastic wants to treat comments whose
  decorative `*` prefixes moved as identical.

#### 1.1.5 Parse failures and merge conflicts

- Default behaviour: fall back to a line-oriented diff with word highlighting whenever parse
  errors occur. `DEFAULT_PARSE_ERROR_LIMIT = 0`. Users can opt in to structural diffing over
  broken files with `DFT_PARSE_ERROR_LIMIT=N`, in which case tree-sitter `ERROR` nodes are
  treated as atoms and a normal tree diff runs. The file header reports the error count.
  Sources: `src/options.rs`; <https://difftastic.wilfred.me.uk/tricky_cases.html#invalid-syntax>
- README acknowledges parse errors arise from unsupported language features, preprocessor-
  dependent languages (C++), or genuine syntax errors, and recommends allowing a small number.
- Merge-conflicted files: since v0.50 (2023-08-16), passing a single file containing
  `<<<<<<<` / `=======` / `>>>>>>>` makes difftastic reconstruct the two sides and diff those.
  <https://difftastic.wilfred.me.uk/usage.html#files-with-conflicts>
- If the input format is unrecognised, or the input is very large, it uses a line diff.
  <https://difftastic.wilfred.me.uk/introduction.html#fallback-line-oriented-diffing>

#### 1.1.6 Performance cliffs — exact numbers

From `src/options.rs` (<https://github.com/Wilfred/difftastic/blob/master/src/options.rs>):

```
DEFAULT_BYTE_LIMIT        = 1_000_000     // --byte-limit  / DFT_BYTE_LIMIT
DEFAULT_GRAPH_LIMIT       = 3_000_000     // --graph-limit / DFT_GRAPH_LIMIT
DEFAULT_PARSE_ERROR_LIMIT = 0             // --parse-error-limit
```

- `--byte-limit`: "Use a line-oriented diff if either input file exceeds this size." → **1 MB**.
- `--graph-limit`: "Use a line-oriented diff if the internal graph exceeds this number of
  vertices. This limit controls the worst case runtime and memory usage for difftastic."
  → **3,000,000 vertices**.
- README Known Issues: "Difftastic scales relatively poorly on files with a large number of
  changes"; and "Robustness. Difftastic regularly has releases that fix crashes."

Open memory/perf issues:
- #373 "Diffing composer.lock files kills the host by eating all memory" — reporter says all
  64 GB RAM plus swap consumed within seconds. Open since 2022-09.
  <https://github.com/Wilfred/difftastic/issues/373>
- #629 "Surprisingly slow diffs for small changes between JSON files" (open).
  <https://github.com/Wilfred/difftastic/issues/629>
- #641 "memory allocation error" (open). #651 large HTML memory explosion (closed).
  #82, #153, #236 similar (closed).

#### 1.1.7 Algorithm and its optimality caveat

Maintainer blog post: <https://www.wilfred.me.uk/blog/2022/09/06/difftastic-the-fantastic-diff/>
(also summarised at <https://difftastic.wilfred.me.uk/diffing.html>)

- Diffing is modelled as shortest-path (Dijkstra) over a DAG whose vertices are pairs of
  positions in the two syntax trees. Graph size is **O(L·R)**.
- Delimiter entry/exit means a vertex is really a triple
  `(lhs position, rhs position, list_of_parents_to_exit_together)`, which "exponentially
  increases the size of the graph, O(2^N) where N is the highest list nesting level".
- **The result is not guaranteed optimal.** He caps consideration at two graph vertices per
  position pair; a route is always found but "it is not necessarily the shortest."
- Performance is bought by "aggressively discard[ing] obviously unchanged s-expressions at the
  beginning, middle and end of the file" — analogous to GNU diff's `--horizon-lines`.
- A* was tried and gave no meaningful improvement over Dijkstra.
- Minimality is explicitly *not* the goal: he adjusted the edge cost model plus added a
  secondary pass to pick aesthetically better results at equal cost. "The minimal diff isn't
  always helpful either. Sometimes difftastic goes too far."
- Failure modes he names himself: large string literals, and over-matching (matching an `=` on
  both sides that is merely distracting).

#### 1.1.8 Interface surface (library vs CLI, output formats)

- **CLI only.** `Cargo.toml` declares `[[bin]] name = "difft"` and there is **no `src/lib.rs`**
  (HTTP 404 on the raw path). The crate publishes a binary, not a reusable library.
  <https://github.com/Wilfred/difftastic/blob/master/Cargo.toml>
- Output modes (`--display`): `side-by-side` (default), `side-by-side-show-both`, `inline`,
  `json`.
- The JSON shape (`src/display/json.rs`) is: per-file `{language, path, status}` plus either
  `chunks` or `aligned_lines`; each line has optional `lhs`/`rhs` sides; each side has
  `line_number` and a list of `changes`, each `{start, end, content, highlight}` where
  `highlight ∈ {delimiter, normal, string, type, comment, keyword, tree_sitter_error}`.
  → **Column offsets within a line, not byte offsets into the file, and only for changed
  regions.** The JSON alone is not sufficient to reconstruct either file.
  <https://github.com/Wilfred/difftastic/blob/master/src/display/json.rs>
- Stated **non-goals** (README): *patching* ("it does not generate patches that you can apply
  later"; patch files are line-oriented, which he calls too limited because difftastic may find
  additions and removals on the same line) and *merging* (points at Mergiraf instead).
- `--check-only` answers "same AST?" without computing a diff — much faster.

---

### 1.2 GumTree and the tree-diff literature

#### 1.2.1 What a tree edit script actually asserts (Falleri et al., ASE 2014)

Paper: *Fine-grained and accurate source code differencing*, Falleri, Morandat, Blanc,
Martinez, Monperrus. DOI 10.1145/2642937.2642982 · PDF <https://hal.science/hal-01054552/document>

- The model is an **ordered labelled tree**; each node has a *label* (its grammar production)
  and an optional *value* (the token text). Values that "do not encode information" are
  discarded (their example: `MethodDeclaration` carries no value). Whitespace never enters the
  model at all.
- Edit actions: `updateValue`, `add`, `delete` (leaf only), `move(t, tp, i)` where move takes
  the whole subtree with it.
- **"finding the shortest transformation is NP-hard"** once move is allowed. Everything after
  that is heuristics.
- Two hard constraints on mappings, stated in the paper: a node can belong to only one mapping,
  and "mappings involve two nodes with identical labels". Both constraints are later shown to
  be sources of error (§1.5).
- Algorithm: greedy top-down search for isomorphic subtrees (anchors) → bottom-up container
  matching by Dice similarity of already-mapped descendants → an optimal (expensive) recovery
  pass inside matched containers.
- Thresholds in the 2014 paper: `minHeight = 2`, `maxSize = 100`, `minDice = 0.5`, chosen "according
  to our expertise". The paper's own Threats to Validity says other values could perform
  differently and more experiments are needed.
- **Evaluation scope is much narrower than usually assumed.** The manual-inspection dataset is
  144 file pairs drawn *only* from revisions "for which the ChangeDistiller differencing
  algorithm states that there is only one single source code change". The famous "good job in
  95.1% of cases" number is measured on single-change revisions only. Also: the raters were
  three of the authors (they say so), and the baseline `diff` was configured to discard
  whitespace.
- All experiments were Java only; the paper flags this as an external-validity threat.

**Does GumTree map back to exact source byte ranges?** Partially yes. The `Tree` interface
declares `int getPos()`, `int getLength()`, and `default int getEndPos() { return getPos() +
getLength(); }`. So each node carries an offset+length into the source.
<https://github.com/GumTreeDiff/gumtree/blob/main/core/src/main/java/com/github/gumtreediff/tree/Tree.java>
That covers *nodes*; it does not cover the bytes *between* sibling nodes, and it says nothing
about whether the parser front-end put comments into the tree at all (see below).

**Comments are a known gap in GumTree front-ends.** Issues:
#39 "JAVA Comment change not getting detected" (closed, 2016),
#35 "Gumtree not showing comment diff for Javascript source files" (closed),
#246 "C++ Comments incorrectly flagged as added/deleted" (closed),
#141 "cannot ignore code-commenting in javaparser" (open),
plus PRs #368/#378 adding comments to the JDT visitor.
<https://github.com/GumTreeDiff/gumtree/issues>

#### 1.2.2 GumTree's own authors on GumTree's failures (ICSE 2024)

Paper: *Fine-grained, Accurate, and Scalable Source Code Differencing*, Falleri & Martinez,
ICSE '24. DOI 10.1145/3597503.3639148 · PDF <https://hal.science/hal-04855170v1/document>

This is the most valuable single source in this document, because it is the original authors
documenting their own algorithm's defects ten years on.

- Section heading, verbatim: **"Achilles Heel of GumTree: Recovery Phase"**.
- The recovery phase uses an optimal tree-edit algorithm with **O(n³)** complexity, so a
  `max_size` hyperparameter (default **1000** nodes) aborts it on large subtrees. Container
  nodes near the root (e.g. `ClassDef`) routinely exceed it.
- Consequence when recovery aborts: **spurious insert/delete actions on nodes that did not
  change**. Because leaves below `min_size` (default 1) are never matched top-down, an aborted
  recovery leaves the class's modifiers, `class` keyword, identifier, etc. reported as
  added *and* removed. Measured in their manual study: **86 of 100 inspected cases**.
- Measured cost of the threshold on Defects4J (832 bug fixes), Table 1:

  | `max_size` | recovery applied | recovery aborted | median edit-script size | total time |
  | --- | --- | --- | --- | --- |
  | 100 | 3062 | 3430 | 33 | 6,897 ms |
  | 500 | 4758 | 1728 | 28 | 58,803 ms |
  | **1000 (default)** | 5228 | 1258 | 26 | 187,699 ms |
  | 1500 | 5453 | 1032 | 25 | 391,652 ms |

  Doubling the runtime from 1000→1500 buys one unit of median edit-script size and still leaves
  1032 aborted recoveries. This is the documented performance/accuracy cliff.
- **"Aggressive recovery" (15 of 100 cases)** — the optimal recovery is *too* eager because it
  reuses as many nodes as possible to shorten the script. Their worked example (JabRef): the
  identifier `Util` was mapped to `names`, producing a rename that no developer performed.
  This is a *wrong* output, not merely an ugly one.
- **"Missing moves" (15 of 100 cases)** — when a leaf or tiny subtree changes nesting and was
  not matched top-down, the cheap heuristic emits insert+delete instead of a move.
- Their own Threats to Validity concedes edit-script *size* is a poor proxy for quality: a
  shorter script may be harder to understand or contain irrelevant actions.

#### 1.2.3 Preceding and competing algorithms

- **Chawathe et al. (1996)**, *Change detection in hierarchically structured information* — the
  origin of the "compute mappings, then derive an optimal edit script from them" split. The
  GumTree paper states Chawathe's algorithm has constraints — "acyclic labels and leaf nodes
  containing a lot of text" — that do not hold for fine-grained ASTs of general-purpose
  programming languages. GumTree reuses Chawathe's *second* step (edit-script derivation is
  quadratic and optimal *given* the mappings); the hard part is the mapping step.
- **ChangeDistiller** (Fluri et al., 2007) — statement-granularity tree diff. In the GumTree
  2014 evaluation, ChangeDistiller was too slow for large ASTs, so the authors *discarded
  revision pairs whose trees exceeded ~3,000 nodes* from that part of the study.
- **MTDIFF** (Dotzler & Philippsen, ASE 2016), *Move-optimized source code tree differencing* —
  five general optimisations that shorten edit scripts for 18–98% of changes when bolted onto
  GumTree, RTED, JSync and ChangeDistiller. DOI 10.1145/2970276.2970315 ·
  <https://ieeexplore.ieee.org/document/7582801/>
- **IJM** (Frick, Grassauer, Beck, Pinzger, ICSME 2018), *Generating Accurate and Compact Edit
  Scripts Using Tree Differencing* — builds on GumTree; notably it **modifies the AST shape**
  (merging `SimpleName` value nodes into their parents and deleting redundant name nodes) to
  stop semantically nonsensical matches. PDF: <https://pinzger.github.io/papers/Frick2018-ijm.pdf>

---

### 1.3 Measured accuracy of AST diff tools (the numbers that matter)

#### 1.3.1 Differential testing (ICSE 2021)

*A Differential Testing Approach for Evaluating Abstract Syntax Tree Mapping Algorithms*,
Fan, Xia, Lo, Hassan, Wang, Li. DOI 10.1109/ICSE43902.2021.00108 ·
PDF <https://xin-xia.github.io/publication/icse212.pdf>

- Corpus: 10 Java projects, **263,165 file revisions**.
- Result: inaccurate mappings are produced for **20–29% of file revisions by GumTree,
  25–36% by MTDiff, and 21–30% by IJM**.
- Their conclusion sentence: state-of-the-art AST mapping algorithms "still need improvements."
- Failure taxonomy they derive includes **NIT = 0 mappings** — two statements mapped together
  that share *zero* identical tokens (i.e. the tool asserted a correspondence between unrelated
  statements). In their 200-statement expert-validated sample this occurred 22× for GumTree and
  72× for MTDiff.
- Note for our purposes: they explicitly **exclude comment and Javadoc nodes** from the token
  lists, "Because comments and Javadocs are typically not treated as code". Comments being
  outside the model is the default assumption across this entire literature.

#### 1.3.2 The AST-diff benchmark (TOSEM 2024)

*A Novel Refactoring and Semantic Aware Abstract Syntax Tree Differencing Tool and a Benchmark
for Evaluating the Accuracy of Diff Tools*, Alikhanifard & Tsantalis.
DOI 10.1145/3696002 · PDF <https://arxiv.org/pdf/2403.05939>

Five structural limitations they identify and quantify across GumTree 2.1, GumTree 3.0
(greedy and simple), IJM, MTDiff, RefactoringMiner 3.0:

1. **No multi-mapping support.** No existing AST diff tool allows one node to map to several.
   Real edits do this constantly (extract duplicated code into one method; merge duplicated
   branches; split a declaration+initialisation into two statements). Current tools match one
   instance and leave the rest as unmatched insert/delete — or mismatch them with unrelated code.
2. **Semantically incompatible mappings.** Because the only constraint is "same AST type",
   GumTree will happily map a method parameter to a `catch` exception declaration to a lambda
   parameter (all `SingleVariableDeclaration` in JDT), or a type reference to a variable
   reference, or a method-body `Block` to an `if`-body `Block`. Counted (Table 6, both datasets):

   | AST node type | RM 3.0 | GT 3.0 greedy | GT 3.0 simple | GT 2.1.0 | IJM | MTDiff |
   | --- | --- | --- | --- | --- | --- | --- |
   | Block | 0 | 83 | 116 | 79 | 61 | 77 |
   | Type | 0 | 118 | 94 | 60 | 0 | 398 |
   | SimpleName | 0 | 418 | 0 | 356 | 18 | 793 |
   | **Total** | **0** | **629** | **214** | **504** | **85** | **1288** |

3. **Ignoring language clues**; 4. **No refactoring awareness**; 5. **No commit-level /
   inter-file analysis** (a fragment moved to a *different* file in the same commit cannot be
   matched at all by file-pair tools).

**Repeated identical siblings — quantified.** This is the ambiguity we specifically worried
about, and the paper measures it: *"in 752 out of 988 commits (76%) in our benchmark ... there
is at least one case of identical repeated statements."* Their fix was not a better similarity
score but **tie-breaking criteria**: whether the statements preceding/following the candidate
mappings are identical, plus Levenshtein edit distance of the candidates' *parent* nodes,
recursively up the ancestor chain (`parent-edit-distance` array, indexed by ancestor depth).

**Perfect-diff rate** — the fraction of commits where the tool's mapping set exactly equals the
benchmark's. This is the closest published analogue to a correctness guarantee:

| Granularity / dataset | RM 3.0 | GT 3.0 greedy | GT 3.0 simple | GT 2.1.0 | IJM | MTDiff |
| --- | --- | --- | --- | --- | --- | --- |
| Statements only, Defects4J | 89.4 | 75.4 | 72.4 | 75.6 | 75.6 | 68.3 |
| Statements only, Refactoring | 82.4 | **14.9** | **13.8** | **11.2** | **13.8** | **5.9** |
| + sub-expressions, Defects4J | 85.9 | **18.1** | 63.3 | — | — | — |
| + sub-expressions, Refactoring | 70.2 | **4.8** | **8.5** | — | — | — |

Read the bottom-right cells carefully: **on refactoring-heavy commits, GumTree 3.0 greedy
produces a fully correct fine-grained mapping in under 5% of cases.** The authors' own gloss
is that bug-fix datasets (the ones everyone benchmarks on) are "a low barrier" for assessing
AST diff accuracy.

Also worth noting for our own design: their language-independent hardening techniques
(fine-grained AST types) sometimes *hurt* — blocking a legitimate mapping when a variable gets
wrapped in a method invocation, because its fine-grained type changed from
`InfixExpression-SimpleName` to `MethodInvocation-SimpleName`.

---

### 1.4 SemanticDiff — the product that does the opposite of our invariant

Site: <https://semanticdiff.com/> · Docs: <https://semanticdiff.com/docs/>
Issue tracker: <https://github.com/Sysmagine/SemanticDiff>

- Positioning, verbatim from its own docs: a diff that "distinguishes between relevant and
  irrelevant changes", where irrelevant changes "are hidden to help you focus on the actual
  changes". <https://semanticdiff.com/docs/what-is-semanticdiff/>
- The **Invariances** page is an explicit, per-language catalogue of textual differences the
  product deliberately does not show. <https://semanticdiff.com/docs/invariances/>
  Selected entries directly relevant to a JS/TS/JSX product:
  - JavaScript / JSX: adding/removing unnecessary parentheses; changing an integer literal's
    base; string escaping; **reordering keys in an object declaration**; converting between
    anonymous and arrow functions; ignoring whitespace in JSX tags per React's rules;
    **collapsing multiple whitespace characters in JSX tags**; treating HTML entities and their
    text form as equivalent; **ignoring JSX attribute order unless a spread operator appears**.
  - Python: reordering of keyword arguments; splitting/combining strings.
  - HTML: collapsing whitespace per CSS rules; ignoring attribute order; ignoring class order
    inside `class`; ignoring boolean attribute values; case-insensitive tags/attributes.
  - JSON5 / .po: reordering of keys / of messages.
- Comments: by default treated like strings and diffed, with an explicit toggle to hide comment
  changes. <https://semanticdiff.com/docs/adjust-diff/hide-comment-changes/>
- **Moved code — the exact hazard we are worried about.** SemanticDiff detects moves and can
  detect whether a moved block contains further changes, but by default
  *"the source of the move is simply shown as one large deletion"* and the target as one large
  addition. Seeing the delta inside a move requires clicking **"Compare With Original"** (or
  flipping a default in options). A move must span at least one complete line to be detected.
  <https://semanticdiff.com/docs/understand-diff/moved-code/>
- **Parse failure**: <https://semanticdiff.com/docs/limitations/> — "Code must be syntactically
  correct." If the code cannot be parsed, it shows a fallback diff (if enabled) **or fails with
  an error**. It also warns of false positives where valid code is rejected because a construct
  isn't supported yet.
- **Fallback diff**: same algorithms with no structural awareness; each line is treated as one
  long token; a warning banner is shown above the content. Moved-line detection still works.
  <https://semanticdiff.com/docs/understand-diff/fallback-diff/>
- In its own comparison post it states difftastic "does not support showing indention changes in
  Python code" (matching difftastic issue #587), and that difftastic's C/C++ parsers mishandle
  preprocessor directives. <https://semanticdiff.com/blog/semanticdiff-vs-difftastic/>

**Takeaway:** SemanticDiff is the clean inverse of DiffScope. Its differentiator is a
*suppression list*. That list is nevertheless an excellent inventory of exactly the churn
categories DiffScope must be able to *label and collapse* — because it is the same taxonomy,
used for the opposite purpose.

---

### 1.5 diffsitter and other tree-sitter structural diff tools

- **diffsitter** — <https://github.com/afnanenayet/diffsitter>. README's own Disclaimer:
  "very much a work in progress and nowhere close to production ready (yet)". Summary line:
  it creates diffs that "ignore formatting differences like spacing". Algorithm per the
  difftastic manual: LCS over the *leaves* of the syntax tree. It supports filtering which
  tree-sitter node kinds are considered at all, via config — i.e. a first-class suppression
  mechanism. Supported languages listed in README: Bash, C#, C++, CSS, Go, Java, OCaml, PHP,
  Python, Ruby, Rust, TypeScript/TSX, HCL.
- **Mergiraf** — <https://mergiraf.org/> — tree-sitter-based *merge* (not diff). Referenced by
  difftastic's README as the thing difftastic explicitly does not do.
- The difftastic manual maintains a survey page of prior tree-diff tools with algorithm and
  output for each: json-diff (pairwise, JSON), GumTree (top-down then bottom-up), Tristan
  Hume's Jane Street A* s-expression differ (2017, source unavailable —
  <https://thume.ca/2017/06/17/tree-diffing/>), **Autochrome** (Clojure, Dijkstra, HTML output;
  the manual recommends it as the best-documented design —
  <https://fazzone.github.io/autochrome.html>), graphtage (Levenshtein over a generic tree
  model, JSON/XML/YAML/CSS), diffsitter, and sdiff (Scheme, MH-Diff from the Chawathe paper).
  <https://difftastic.wilfred.me.uk/tree_diffing.html>
  Two of these — json-diff and graphtage — do not consider `"foo"` and `["foo"]` to have *any*
  similarity, per the same page.
- **github/semantic** (Haskell) — <https://github.com/github/semantic> — used Myers SES and
  RWS-Diff for its diffing. It is no longer an active product path. *(Status flagged in Open
  questions; I did not verify archival state from a primary source.)*

**Relevant tree-sitter facts (for anything built on it):**
- Whitespace is not in the tree. `extras` in a tree-sitter grammar is "an array of tokens that
  may appear anywhere in the language ... often used for whitespace and comments. The default
  value of `extras` is to accept whitespace." Whitespace is skipped, not represented; comments
  become nodes only if the grammar declares them.
  <https://tree-sitter.github.io/tree-sitter/creating-parsers/2-the-grammar-dsl.html>
- Errors always yield a tree. `ts_node_is_error`, `ts_node_has_error`, and crucially
  `ts_node_is_missing` — "Missing nodes are inserted by the parser in order to recover from
  certain kinds of syntax errors." **A MISSING node corresponds to zero source bytes**, i.e. a
  tree node with no textual extent.
  <https://github.com/tree-sitter/tree-sitter/blob/master/lib/include/tree_sitter/api.h>
- Tree-sitter's stated design goal is to be "Robust enough to provide useful results even in
  the presence of syntax errors". <https://tree-sitter.github.io/tree-sitter/>

---

### 1.6 IDE diff viewers

#### 1.6.1 VS Code

Defaults are in source, `src/vs/editor/common/config/diffEditor.ts`
(<https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/config/diffEditor.ts>):

```
maxComputationTime:   5000        // ms; setting doc: "Timeout in milliseconds after which
                                  //     diff computation is cancelled. Use 0 for no timeout."
maxFileSize:          50          // MB;  "Use 0 for no limit."
ignoreTrimWhitespace: true        // ← default ON
diffAlgorithm:        'advanced'  // enum: legacy | advanced | advanced-external | advanced-wasm
experimental.showMoves:        false
experimental.showEmptyDecorations: true
hideUnchangedRegions.enabled:  false   (contextLineCount 3, minimumLineCount 3, revealLineCount 20)
```

- **`diffEditor.ignoreTrimWhitespace` defaults to `true`.** Setting description: "When enabled,
  the diff editor ignores changes in leading or trailing whitespace." So out of the box, VS
  Code's diff editor hides indentation-only changes. This is the single most widely deployed
  instance of the behaviour our invariant forbids.
  Schema: `src/vs/editor/common/config/editorConfigurationSchema.ts`.
- **Timeout semantics are explicitly approximate.** `LinesDiff.hitTimeout` is documented in
  source as: "Indicates if the time out was reached. In that case, the diffs might be an
  approximation and the user should be asked to rerun the diff with more time."
  <https://github.com/microsoft/vscode/blob/main/src/vs/editor/common/diff/linesDiffComputer.ts>
  → VS Code *degrades diff correctness under time pressure* and surfaces a flag for it.
- **Positive precedent for moves.** VS Code's `MovedText` carries both the `lineRangeMapping`
  *and* `changes: readonly DetailedLineRangeMapping[]`, documented as "The diff from the
  original text to the moved text ... Can be empty if the text didn't change (only moved)."
  The move model does *not* discard the internal delta — it nests it. (Same file.) But move
  display is off by default (`experimental.showMoves: false`).

#### 1.6.2 JetBrains (IntelliJ / WebStorm)

Docs: <https://www.jetbrains.com/help/idea/differences-viewer.html>

- Whitespace modes: **None** (default; all differences highlighted), **Trim whitespaces**,
  **Ignore whitespaces**, **Ignore whitespaces and empty lines** (the last also absorbs
  splitting/joining lines when non-whitespace content is unchanged).
  Note that JetBrains' *default* is the safe one, unlike VS Code's.
- Highlighting granularity: **Words**, **Lines**, **Split changes**, **Characters**, **None**.
  "Split changes" breaks a large modification into smaller segments — a presentation-level
  regrouping, not a filter.
- **Collapse Unchanged Fragments** with a configurable threshold on the Diff & Merge settings
  page.
- **The known complaint that matters for us**: YouTrack IDEA-22363 / IJPL-105250, *"Diff Window
  in Ignore Whitespace Mode: Says 'No Difference' Even If There're Ignored Differences"* — users
  see a file in the changelist, open the diff, and are told there is no difference, because the
  ignored differences were suppressed rather than disclosed. The requested fix is to
  *distinguish* "no differences" from "only unimportant differences".
  <https://youtrack.jetbrains.com/issue/IDEA-22363/>
  This is independent confirmation, from a mature IDE's user base, that *suppression without
  disclosure is experienced as a bug*. It is the strongest external validation of DiffScope's
  core invariant that I found.
- Related open request: IJPL-99523 "Make diff tool SMART, semantic, structure aware".
  <https://youtrack.jetbrains.com/issue/IJPL-99523/>

---

### 1.7 Git's own diff machinery

Primary source: `Documentation/diff-options.adoc` and `Documentation/diff-algorithm-option.adoc`
in <https://github.com/git/git>.

#### 1.7.1 Algorithms

| Option | Git's own description |
| --- | --- |
| `myers` / `default` | "The basic greedy diff algorithm. Currently, this is the default." |
| `minimal` | "Spend extra time to make sure the smallest possible diff is produced." |
| `patience` | Patience diff. |
| `histogram` | "extends the patience algorithm to 'support low-occurrence common elements'". |
| `--anchored=<text>` | If a line exists in both files exactly once and starts with `<text>`, try to prevent it appearing as an add/remove. Uses patience internally. Repeatable. |
| `--indent-heuristic` | "shifts diff hunk boundaries to make patches easier to read. This is the default." (`--no-indent-heuristic` disables.) |

`--indent-heuristic` is worth calling out as prior art *in the right direction*: it is a pure
**alignment/presentation** heuristic — it changes which of several equal-cost hunk placements is
shown, without changing what text is reported as added or removed. That is exactly the class of
transformation DiffScope's invariant permits.

**Empirical consequences of the algorithm choice** — *How different are different diff
algorithms in Git?*, Nugroho, Hata, Matsumoto, Empirical Software Engineering 25 (2020).
DOI 10.1007/s10664-019-09772-z · PDF <https://d-nb.info/1203519214/34>

- Across CI-Java projects, Myers vs Histogram disagree on **1.7%–8.2% of commits**.
- Files with differing added/deleted line *counts*: **0.8%–6.2%**; differing line *positions*:
  **1.4%–7.6%**.
- Downstream SZZ bug-introducing-commit identification differs for **6.0%–13.3%** of bug-fix
  commits depending purely on the diff algorithm.
- Manual quality assessment of 377 sampled changes: for code changes, Histogram judged better
  in **62.6%** of files, Myers better in **16.9%**, same in 20.6%. For non-code changes the two
  are roughly equivalent.
- Their stated root cause for Myers being worse: it "frequently catches the blank lines or
  parentheses" as anchors instead of unique lines like a function declaration — the slider
  problem, again.
- Recommendation in the abstract: use `--histogram` for code changes.

#### 1.7.2 `--color-moved` — documented false-positive / false-negative behaviour

Modes and Git's own caveats:

- `plain`: "This mode picks up any moved line, but it is not very useful in a review to
  determine if a block of code was moved without permutation." → maximal false positives by
  design.
- `blocks`: "Blocks of moved text of at least 20 alphanumeric characters are detected greedily."
  and "Adjacent blocks cannot be told apart."
- `zebra` (the default when `--color-moved` is given bare): same detection as `blocks`,
  alternating colours to delimit blocks. `default` is a synonym for `zebra` and the docs warn
  "This may change to a more sensible mode in the future."
- The 20-character threshold is a literal constant: `#define COLOR_MOVED_MIN_ALNUM_COUNT 20` in
  `diff.h`; enforced in `adjust_last_block()` in `diff.c`, which *unsets* the moved flag on
  every line of a block that fails the threshold (and is skipped entirely in `plain` mode).
  The source even carries a `NEEDSWORK` comment noting the heuristic is duplicated from
  `blame_entry_score()` in `blame.c`.
  <https://github.com/git/git/blob/master/diff.h> · <https://github.com/git/git/blob/master/diff.c>
  → **False negative**: short moved blocks (a 3-line import move, a small JSX element) are
  silently not reported as moves at all.
  → **False positive**: two independent edits that happen to produce ≥20 alnum chars of
  identical text anywhere in the same diff are painted as a move.
- `--color-moved-ws=<mode>`: `no` (default), `ignore-space-at-eol`, `ignore-space-change`,
  `ignore-all-space`, `allow-indentation-change`. The last "Initially ignore any whitespace in
  the move detection, then group the moved code blocks only into a block if the change in
  whitespace is the same per line" and is incompatible with the others.
- **Critical structural fact**: Git's move detection matches *whole lines by equality* (modulo
  the chosen whitespace flags). There is no representation of "moved **and** modified". A block
  that is relocated *and* edited internally simply breaks into smaller moved blocks around the
  edited lines, and the edited lines appear as an unrelated add/remove pair. Git has no way to
  express "this moved, and here is its internal delta".

#### 1.7.3 `--word-diff`

- It is built on top of the line diff: "The `--word-diff` option operates by taking the same
  line-by-line diff that is produced without the option and computing word-by-word changes
  within each hunk. This may produce a larger diff than a dedicated word-diff tool would."
  The docs then warn the output may change if Git changes implementation.
- `plain` mode uses `[-removed-]` / `{+added+}` and "Makes no attempts to escape the delimiters
  if they appear in the input, so the output may be ambiguous." → the *serialisation itself* is
  lossy.
- `--word-diff-regex` has two exclamation-marked warnings in Git's own prose:
  "Anything between these matches is considered whitespace and **ignored(!)**" and
  "A match that contains a newline is **silently truncated(!)** at the newline."
- `porcelain` mode represents newlines in the input as a lone `~` line.

#### 1.7.4 `git diff --no-index`

- Compares two arbitrary filesystem paths. Can be omitted when at least one path is outside the
  work tree or when run outside a repository. **This form implies `--exit-code`.** If both paths
  are directories, additional (relative) pathspecs may limit the comparison.
  <https://github.com/git/git/blob/master/Documentation/git-diff.adoc>

---

## 2. Direct answers to the research questions

**Q. What concrete cases are documented where structural diff tools produce wrong or misleading
output?**

1. Difftastic reports `No syntactic changes.` for Python files that differ in
   behaviour-changing indentation (issues #587 open, #818, #942). The trees genuinely differ;
   the information was lost after parsing.
2. Difftastic's inline display omits unchanged context inside a changed region, making untouched
   code read as replaced (#857).
3. GumTree's own authors document *spurious insert-deletes* on unmodified nodes when the
   recovery phase aborts (86/100 inspected cases) and *aggressive recovery* inventing renames
   that never happened — `Util` → `names` (15/100 cases). ICSE 2024.
4. GumTree/IJM/MTDiff map statements sharing **zero** identical tokens (NIT = 0), i.e. assert a
   correspondence between unrelated statements. ICSE 2021.
5. GumTree maps semantically incompatible nodes that merely share an AST type — a method
   parameter to a catch-clause exception declaration to a lambda parameter; a type reference to
   a variable reference; a method body block to an `if` body block. 629 occurrences for
   GumTree 3.0 greedy in the TOSEM 2024 benchmark.
6. Git's Myers algorithm anchors on blank lines and braces instead of unique lines, producing
   hunks whose reported changes do not correspond to what was edited (EMSE 2020, §3.1).
7. `--color-moved=plain` paints coincidentally-identical lines as moves.
8. Difftastic's own "Tricky Cases" page enumerates ~15 more, several marked as not yet working.

**Q. How do existing tools handle unparseable / partially-typed / merge-conflicted source?**

- **Difftastic**: falls back to line diff at the *first* parse error by default
  (`DFT_PARSE_ERROR_LIMIT=0`); reports the error count in the file header; opt-in structural
  diffing over broken files treats tree-sitter ERROR nodes as atoms. Understands conflict
  markers natively since v0.50 and reconstructs both sides.
- **SemanticDiff**: requires syntactically correct code; otherwise fallback diff *if enabled*,
  else it **errors out**. Also admits false rejections of valid code for unsupported constructs.
- **GumTree**: depends on a real compiler front-end (JDT, srcML, etc.); a parse failure means no
  tree and no diff. No documented degradation path.
- **diffsitter**: not documented; project self-describes as not production ready.
- **Tree-sitter itself** always returns a tree with ERROR nodes and zero-width MISSING nodes;
  it is the only layer in the stack with a documented robustness goal.
- **Git**: has no parser and therefore no failure mode here — a property worth respecting.

**Q. How do they handle repeated identical nodes (e.g. several near-identical JSX siblings)?**

- It is a *measured*, not hypothetical, problem: **76% of commits (752/988)** in the TOSEM 2024
  benchmark contain at least one case of identical repeated statements.
- Difftastic treats it as a cost-model tie ("Sliders (Flat)"): from an LCS perspective the two
  placements "are equivalent", and its stated preference is to mark *contiguous* nodes as novel.
  It also enforces per-language priority rules (punctuation atoms are lower priority than real
  atoms) to break ties.
- GumTree's top-down phase requires isomorphic subtrees above `minHeight`/`min_size`; when
  several candidates are isomorphic it falls back to parent similarity, which is exactly where
  the ambiguity bites. GumTree's `simple` recovery deliberately refuses to consider nesting
  changes to avoid making things worse — at the cost of "missing moves".
- RefactoringMiner 3.0's answer is the most concrete published one: **deterministic tie-breaking
  by context**, using (a) whether the preceding/following statements of each candidate mapping
  are identical and (b) Levenshtein distance between the candidates' ancestors at increasing
  depth. This is the technique to steal.
- Git's line-level analogue is patience/histogram: anchor only on lines that occur uniquely (or
  least often), and `--anchored=<text>` to let the user pin one manually.

**Q. Does any existing tool make a losslessness or coverage guarantee? If not, what do they
guarantee instead?**

**No tool surveyed makes a losslessness or coverage guarantee.** What they offer instead:

| Tool | What it actually guarantees |
| --- | --- |
| Difftastic | A *conservative fallback*: line diff on parse errors, on files >1 MB, and when the search graph exceeds 3M vertices. README frames this as ensuring it "never claims that two syntactically different files are the same" — and issue #587 shows this framing does not hold for whitespace-significant languages. It also distinguishes `No changes.` from `No syntactic changes.`, which is disclosure of *existence* but not of *content*. |
| GumTree | A *short* edit script (explicitly not minimal — minimality is NP-hard with moves). Node-level `getPos()`/`getLength()` give byte anchoring for nodes that exist in the tree. |
| SemanticDiff | Transparency about its suppression list (a published Invariances page and a Limitations page), plus an escape hatch (fallback diff). Suppression is the product. |
| VS Code | A `hitTimeout` flag admitting the diff "might be an approximation"; and a move model that nests the internal delta rather than discarding it. |
| Git | Determinism given a fixed algorithm, plus patch applicability — the strongest practical guarantee in the set, and the one purchased by *not* parsing. |

The closest published proxy for a correctness guarantee is the TOSEM 2024 **perfect-diff rate**,
and it is sobering: 4.8%–18.1% for GumTree 3.0 greedy at fine granularity.

**Q. What are the documented performance cliffs?**

| Tool | Cliff | Behaviour at the cliff |
| --- | --- | --- |
| Difftastic | file > **1 MB** (`DFT_BYTE_LIMIT`) | silently switches to line diff |
| Difftastic | search graph > **3,000,000 vertices** (`DFT_GRAPH_LIMIT`) | silently switches to line diff |
| Difftastic | graph is **O(L·R)** with an **O(2^N)** blow-up in nesting depth N | mitigated by capping at 2 vertices per position pair — result no longer guaranteed shortest |
| Difftastic | in the wild | 64 GB RAM + swap exhausted on a `composer.lock` (#373); open perf issues on JSON, HTML, large C |
| GumTree | recovery phase is **O(n³)**, gated at `max_size = 1000` nodes | recovery aborts → spurious insert/delete on unchanged nodes; 1258/6486 aborts on Defects4J at the default |
| GumTree | raising `max_size` 1000→1500 | total time 188 s → 392 s for a 1-unit median edit-script improvement |
| ChangeDistiller | trees > ~3,000 nodes | too slow; such pairs were discarded from the GumTree 2014 study |
| VS Code | **5000 ms** (`maxComputationTime`), **50 MB** (`maxFileSize`) | returns an approximate diff with `hitTimeout = true` |

**Q. For move detection specifically: what goes wrong? We are worried about a move that carries
an internal delta which then gets discarded.**

The worry is well-founded and is a real, observed failure at three different levels:

1. **Git cannot express it at all.** `--color-moved` matches whole lines by equality. A block
   that moved *and* changed internally fragments into several moved blocks plus a floating
   add/remove pair, or — if the fragments fall below `COLOR_MOVED_MIN_ALNUM_COUNT = 20` —
   is not reported as a move at all.
2. **SemanticDiff hides it by default.** Its docs are explicit: by default the move source is
   rendered as "one large deletion" and the target as one large addition; the internal delta
   exists but is behind a "Compare With Original" click. This is the exact
   move-swallows-its-delta shape.
3. **GumTree's semantics make it structurally possible to lose.** `move(t, tp, i)` moves the
   *whole subtree* by definition. Whether the subtree's internal edits survive depends entirely
   on whether the mapping step matched the descendants — and the ICSE 2024 paper shows the
   recovery phase that finds those descendant mappings is precisely the part that aborts on
   large subtrees. When it aborts, you get a move whose children are reported as
   inserted-and-deleted rather than as a nested update.
4. **The inverse error is equally documented**: GumTree 3.0 `simple` "does not consider changes
   of nesting", so genuine moves degrade into spurious insert+delete pairs (15/100 cases).

The one clean positive precedent is **VS Code's `MovedText`**, which carries
`changes: DetailedLineRangeMapping[]` alongside the move's line ranges, with the source comment
noting the change list "Can be empty if the text didn't change (only moved)". A move there is a
container, not a replacement.

---

## 3. My technical interpretation

*Everything in this section is my inference from the facts above, not a sourced claim.*

**3.1 Every documented "wrong output" traces to one of four root causes.** Not to bugs.

- *(a) Information deleted at model-construction time.* Difftastic's `#587` cannot be fixed in
  the diff algorithm, because the whitespace was already gone: the manual says the simplified
  tree stores no inter-node whitespace and ignores position during diffing. Implication: the
  losslessness decision is made in the **tree-building** layer, not the diffing layer, and it is
  irreversible downstream. This is the design lesson.
- *(b) A heuristic threshold that silently changes the semantics of the output.* GumTree's
  `max_size`, difftastic's `DFT_GRAPH_LIMIT` and `DFT_BYTE_LIMIT`, VS Code's
  `maxComputationTime`, Git's `COLOR_MOVED_MIN_ALNUM_COUNT`. In every case, crossing the
  threshold degrades the *meaning* of the output, and in most cases the user is not told.
  Difftastic's `--display=json` `status` field and VS Code's `hitTimeout` are the only
  disclosure mechanisms I found.
- *(c) Genuine ambiguity resolved silently.* Sliders, repeated identical siblings, punctuation
  atoms. Every tool picks one interpretation and shows it as fact. None of them expose "these
  two alignments cost the same".
- *(d) Optimising for the wrong objective.* Minimal edit script ≠ comprehensible edit script.
  Both Wilfred ("Sometimes difftastic goes too far") and Falleri & Martinez (aggressive recovery
  inventing a `Util`→`names` rename; edit-script size a poor proxy in Threats to Validity) say
  this independently. Cost-model tuning is a permanent, unfinished part of the product, not a
  one-off.

**3.2 The invariant is achievable, and cheaply, if it is enforced at the right layer.** The
mechanical way to guarantee it: represent the diff as a **total, ordered partition of both
files' byte ranges** — every byte of the before-file and every byte of the after-file belongs to
exactly one segment, and each segment is classified (unchanged / removed / added / moved /
reformatted). Structural analysis then only decides *how segments are grouped, ordered and
labelled*, never which bytes exist. This makes losslessness a checkable invariant
(`Σ segment lengths == file length`, no gaps, no overlaps) that can be asserted in tests and in
production. No surveyed tool does this; difftastic's JSON emits only changed regions with
in-line column offsets, which cannot be checked this way.

**3.3 "Formatting-only" should be a computed property of a segment, never a filter.** The right
shape looks like: classify the segment structurally, then *separately* record
`normalizedTextEqual: boolean`. A group labelled "formatting-only" is a group where every
member's normalised text matched but raw bytes did not — which is verifiable and reversible.
SemanticDiff's Invariances page is effectively a ready-made taxonomy of labels
(paren-only, quote-style, trailing-comma, JSX-whitespace, attribute-reorder, key-reorder,
literal-base, escape-style). Their list is worth mirroring as *label vocabulary* while
inverting its purpose.

**3.4 Moves must be containers.** Model a move as `Move { fromRange, toRange, innerDiff }` where
`innerDiff` is a full sub-diff, empty iff the text is byte-identical. Follow VS Code's
`MovedText`, not Git's line-equality matching and not SemanticDiff's default collapse. The
"moved with changes" case should be the *default* rendering, not a click-through — that is
precisely the inversion that distinguishes DiffScope.

**3.5 Ambiguity should be a first-class output, not a hidden coin flip.** Difftastic's sliders,
repeated JSX siblings, and GumTree's isomorphic-candidate ties are all cases where the cost
function is genuinely indifferent. Because DiffScope guarantees textual completeness, it can
afford to *say so* ("2 equally-good alignments; showing the contiguous one") — a
line-diff-compatible tool cannot, because its output has to be a patch. This looks like a
defensible, unclaimed product differentiator.

**3.6 Adopt RefactoringMiner's tie-breaking, not its architecture.** The 76%-of-commits figure
means repeated-sibling ties are the common case, not an edge case, and JSX makes it worse
(sibling `<Item />`s, repeated `className` strings, repeated import specifiers). Their
tie-breakers — identity of preceding/following siblings, then Levenshtein distance of ancestors
at increasing depth — are language-agnostic and cheap. Their full approach (language-aware
refactoring detection) is Java-specific and out of scope.

**3.7 Two-tier engine is unavoidable, and the boundary must be visible.** Every tool has a
fallback. The difference DiffScope can make is that the fallback is *announced and attributed*
("structural analysis unavailable: 3 parse errors at lines 12, 40, 41 — showing line diff"),
rather than a silent mode switch. Note also that tree-sitter's error recovery means we *can*
run structurally over broken files (difftastic's `DFT_PARSE_ERROR_LIMIT` path proves it) —
but only if ERROR/MISSING nodes are handled explicitly. MISSING nodes carry zero source bytes,
which would break a naive byte-partition invariant; they need to be excluded from the byte
partition and represented as annotations instead.

**3.8 The performance budget is knowable in advance.** Difftastic's 1 MB / 3M-vertex defaults
are a well-calibrated starting point from someone who profiled hard in Rust. A desktop app with
a real UI thread has *less* budget than a CLI, not more. Budget on **tree node count**, not file
size — difftastic's own #373 (a `composer.lock` far under any sane byte limit) shows byte size
is the wrong proxy.

---

## 4. Open questions

Things I could not determine from primary sources within this pass:

1. **Difftastic's actual whitespace-in-strings behaviour.** The manual says
   `" "` and `"  "` must differ, and strings are atoms compared by content — so it should work.
   I did not run difftastic to confirm, and I did not find an issue either way.
2. **Whether difftastic's structural diff over ERROR nodes (`DFT_PARSE_ERROR_LIMIT > 0`) has
   documented failure modes.** The README recommends raising it to 20; I found no issue thread
   evaluating output quality in that mode.
3. **Whether GumTree's JDT front-end includes comments by default in current `main`.** Issues
   #39/#35/#246 show it historically did not, and PRs #368/#378 added comment support to the JDT
   visitor — but I did not verify the merged default behaviour in current source.
4. **Whether `--color-moved` has documented cross-file behaviour.** I established that detection
   works over the emitted symbol stream of a single diff, but did not confirm from a primary
   source whether a function moved between two files in one commit is detected.
5. **SemanticDiff's move detection algorithm.** Its docs describe behaviour and the one-complete-
   line minimum, but the algorithm is closed-source and undocumented.
6. **github/semantic's archival status and its documented diffing limitations.** I have a
   secondary claim that it used Myers SES and RWS-Diff; I did not verify from the repo, and I
   found no limitations document. Treat as unverified.
7. **Whether Git's default `diff.algorithm` has changed from `myers` in a recent release.**
   Current `Documentation/diff-algorithm-option.adoc` on `master` still says myers is
   "Currently, this is the default", but I did not check release notes for a pending change.
8. **JetBrains' actual line-matching algorithm and any published accuracy data.** The help pages
   document options, not internals. IDEA-22363's current status/resolution could not be read
   (the YouTrack page is a JS app and did not render for fetching); only its title and existence
   are confirmed via search indexing.
9. **Empirical data on tree-sitter grammar disagreements for TSX/JSX specifically** — e.g. how
   `tree-sitter-typescript` represents JSX text nodes and whitespace within them. This matters a
   lot for us (SemanticDiff has *five separate* JSX whitespace invariances) and deserves its own
   investigation.
10. **Any published user study on whether structural diffs actually improve review outcomes**
    beyond the GumTree author-rated study (which was authors rating their own tool on
    single-change revisions).

---

## 5. Implications for a lossless structural differ

Ordered by how strongly the evidence supports them.

**5.1 Make the byte partition the primitive; make it assertable.**
Root cause (a) above is fatal and irreversible. Build the internal model as a total ordered
partition over both files' bytes, with structural labels attached to segments — not as a tree
whose nodes happen to have positions. Assert coverage (`no gaps, no overlaps, Σ == len`) in
tests and, cheaply, at runtime. This converts "we promise not to lose text" from a policy into a
property. **No existing tool does this**, which is both the risk and the opportunity.

**5.2 Whitespace, blank lines, and line endings must be in the model from the start.**
Concrete checklist derived from actual documented failures:
- inter-token whitespace (difftastic: not stored)
- indentation as a distinct, first-class dimension (difftastic #587/#818/#942 — Python and YAML
  are correctness-critical; JSX/TS are not, but reviewers still want to see it)
- blank line insertion/removal (difftastic tricky_cases: invisible by design)
- CR/LF (difftastic `--strip-cr` defaults to on; VS Code `ignoreTrimWhitespace` defaults to true)
- trailing whitespace and whitespace at EOL
- whitespace *inside* string literals and inside JSX text nodes

**5.3 Ship a defined disclosure vocabulary rather than a suppression list.**
Invert SemanticDiff's Invariances page. Every entry there becomes a **label** in our taxonomy:
`paren-only`, `literal-base`, `escape-style`, `trailing-comma`, `quote-style`,
`object-key-reorder`, `jsx-attr-reorder`, `jsx-whitespace`, `import-reorder`,
`tailwind-class-reorder`, `arrow-vs-function`. Each collapsed group must carry an exact count
and expand to raw bytes. A collapsed group is a *claim about* the bytes; the bytes stay.

**5.4 Never emit a bare "no changes".**
This is the single most transferable finding: JetBrains IDEA-22363 shows users treat
"no difference, but I suppressed some" as a bug, and difftastic's `No syntactic changes.` is a
real-world instance of exactly this failure. DiffScope's equivalent state must be
"**no structural changes; 14 formatting differences (expand)**" with the differences one
interaction away. Difftastic already distinguishes `No changes.` (byte-identical) from
`No syntactic changes.` internally — take that distinction and make it visible and actionable.

**5.5 Moves are containers with a nested diff, shown by default.**
`Move { fromRange, toRange, innerDiff }`. `innerDiff` empty **iff** the moved bytes are
identical. Follow VS Code's `MovedText`. Explicitly reject: Git's whole-line-equality matching
(cannot express moved+modified), Git's 20-alnum-char floor (silently drops small moves), and
SemanticDiff's default collapse to delete+add. Because we guarantee coverage, a move must never
be allowed to *replace* the segments it contains — only to regroup them.

**5.6 Budget on tree size, degrade explicitly, never silently.**
Starting points calibrated from difftastic: byte limit ~1 MB, graph/vertex limit ~3M, but
**budget primarily on node count** (difftastic #373: a moderate-size lockfile ate 64 GB).
Every degradation — parse errors, size limit, time limit — must produce a visible, attributed
banner naming the reason and the affected range. Precedent for the flag exists
(VS Code `hitTimeout`); precedent for surfacing it to users does not.

**5.7 Design the parse-failure path first, not last.**
It is the common case in a desktop tool watching a working tree (half-typed code, merge
conflicts, unsaved buffers). Requirements:
- always render a complete diff, structural or not (Git's guarantee)
- tree-sitter ERROR nodes handled as opaque atoms, per difftastic's `DFT_PARSE_ERROR_LIMIT` mode
- **MISSING nodes are zero-width and must be excluded from the byte partition** and represented
  as annotations, or they break invariant 5.1
- handle conflict markers natively (difftastic v0.50 is the precedent)
- reject SemanticDiff's "fail with an error" behaviour outright

**5.8 Treat repeated identical siblings as the common case and break ties deterministically.**
76% of commits contain at least one instance (TOSEM 2024); JSX makes it worse. Implement
RefactoringMiner's tie-breakers — identity of neighbouring siblings, then ancestor edit distance
at increasing depth — plus difftastic's "prefer contiguous novel nodes" rule and its
"punctuation atoms rank below real atoms" rule. Make the ordering **deterministic and
documented**, so the same input always yields the same alignment. Where the tie is genuinely
unbreakable, say so in the UI rather than picking silently.

**5.9 Budget continuous effort for the cost model, and treat it as taste, not correctness.**
Both maintainer sources say cost-model tuning never finishes and that minimality is the wrong
objective. Two structural mitigations they both used and we should copy from day one:
(a) a secondary pass that picks the most legible among equal-cost results;
(b) a corpus of adversarial fixtures. Seed that corpus from difftastic's Tricky Cases page
verbatim (delimiter add/change/expand/contract, disconnected delimiters, rewrapping large nodes,
middle insertions, punctuation atoms, trailing punctuation, flat and nested sliders,
minimising depth changes, replacements with minor similarities, matching substrings in comments,
multiline and reflowed comments, small changes to large strings, novel blank lines, invalid
syntax) plus a JSX-specific set: wrapper removal with N children preserved, N near-identical
siblings with one edited, prop reordering, Prettier reflow, Tailwind class reorder, and
import reordering. **Because our invariant forbids suppression, these become regression tests
with checkable pass conditions** — the bytes must all still be present — which is something
difftastic and GumTree structurally cannot test for.

**5.10 Do not plan to reuse difftastic as an engine.**
It is a binary-only crate (`[[bin]] name = "difft"`, no `src/lib.rs`); its JSON output emits
only changed regions with per-line column offsets and cannot reconstruct either file; and its
core model discards the very information our invariant requires. It is an excellent *reference
implementation and oracle to diff against*, not a dependency.

---

## Appendix: source index

**Difftastic**
- Repo / README — <https://github.com/Wilfred/difftastic>
- Manual — <https://difftastic.wilfred.me.uk/> (Introduction, Usage, Parsing, Diffing,
  Tricky Cases, Tree Diffing)
- `src/options.rs` (limits, defaults, output modes) — <https://github.com/Wilfred/difftastic/blob/master/src/options.rs>
- `src/main.rs` (`print_diff_result`) · `src/display/json.rs` (JSON schema) · `Cargo.toml`
- Maintainer blog, *Difftastic, the Fantastic Diff* (2022-09-06) — <https://www.wilfred.me.uk/blog/2022/09/06/difftastic-the-fantastic-diff/>
- Issues: [#587](https://github.com/Wilfred/difftastic/issues/587) ·
  [#818](https://github.com/Wilfred/difftastic/issues/818) ·
  [#942](https://github.com/Wilfred/difftastic/issues/942) ·
  [#984 (PR)](https://github.com/Wilfred/difftastic/pull/984) ·
  [#857](https://github.com/Wilfred/difftastic/issues/857) ·
  [#729](https://github.com/Wilfred/difftastic/issues/729) ·
  [#373](https://github.com/Wilfred/difftastic/issues/373) ·
  [#629](https://github.com/Wilfred/difftastic/issues/629) ·
  [#44](https://github.com/Wilfred/difftastic/issues/44)

**GumTree and tree-diff literature**
- Falleri et al., ASE 2014 — <https://hal.science/hal-01054552/document> · DOI 10.1145/2642937.2642982
- Falleri & Martinez, ICSE 2024 — <https://hal.science/hal-04855170v1/document> · DOI 10.1145/3597503.3639148
- GumTree repo — <https://github.com/GumTreeDiff/gumtree> · `core/.../tree/Tree.java`
- Dotzler & Philippsen, MTDIFF, ASE 2016 — DOI 10.1145/2970276.2970315
- Frick et al., IJM, ICSME 2018 — <https://pinzger.github.io/papers/Frick2018-ijm.pdf>
- Fan et al., ICSE 2021 (differential testing) — <https://xin-xia.github.io/publication/icse212.pdf>
- Alikhanifard & Tsantalis, TOSEM 2024 (benchmark) — <https://arxiv.org/pdf/2403.05939> · DOI 10.1145/3696002

**SemanticDiff**
- <https://semanticdiff.com/docs/what-is-semanticdiff/> ·
  <https://semanticdiff.com/docs/invariances/> ·
  <https://semanticdiff.com/docs/limitations/> ·
  <https://semanticdiff.com/docs/understand-diff/moved-code/> ·
  <https://semanticdiff.com/docs/understand-diff/fallback-diff/> ·
  <https://semanticdiff.com/docs/adjust-diff/hide-comment-changes/> ·
  <https://semanticdiff.com/blog/semanticdiff-vs-difftastic/>

**Other structural tools**
- diffsitter — <https://github.com/afnanenayet/diffsitter>
- Autochrome — <https://fazzone.github.io/autochrome.html>
- Tristan Hume, tree diffing — <https://thume.ca/2017/06/17/tree-diffing/>
- graphtage — <https://blog.trailofbits.com/2020/08/28/graphtage/>
- Mergiraf — <https://mergiraf.org/>
- Tree-sitter — <https://tree-sitter.github.io/tree-sitter/> · `lib/include/tree_sitter/api.h`

**IDE diff viewers**
- VS Code `diffEditor.ts`, `editorConfigurationSchema.ts`, `linesDiffComputer.ts` — <https://github.com/microsoft/vscode>
- JetBrains Differences Viewer — <https://www.jetbrains.com/help/idea/differences-viewer.html>
- YouTrack IDEA-22363 / IJPL-105250 · IJPL-99523 — <https://youtrack.jetbrains.com/>

**Git**
- `Documentation/diff-options.adoc`, `Documentation/diff-algorithm-option.adoc`,
  `Documentation/git-diff.adoc`, `diff.c`, `diff.h` — <https://github.com/git/git>
- Nugroho, Hata, Matsumoto, EMSE 2020 — <https://d-nb.info/1203519214/34> · DOI 10.1007/s10664-019-09772-z
