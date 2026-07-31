# 05 — Open Questions

Everything raised and not yet decided. Each entry carries a status as defined in [glossary.md](glossary.md).

**Rule for all agents: do not resolve an open question by assumption.** Bring it to the product owner as a concrete question with options, trade-offs, and a recommendation, then record the answer in [04-decision-log.md](04-decision-log.md) immediately. If work must proceed before an answer exists, mark the working assumption as a **provisional assumption** here and flag it for confirmation.

Questions are grouped by area. Identifiers are stable; resolved questions are struck through and annotated with the decision that closed them rather than deleted.

---

## Product and naming

**OQ-001 — Product name.** Status: Open.
`diffscope` is a placeholder working name used for the directory. Final naming affects the bundle identifier, app name, and any distribution. Low urgency, but must be settled before packaging work in Phase 8.

~~**OQ-002 — Target users beyond the product owner.**~~ **Resolved by DEC-020.** Personal tool; distribution deliberately left undecided. Critical consequence carried forward: licensing of Phase 3 candidates must still be evaluated against possible future distribution, because adopting a strongly copyleft engine would quietly foreclose that option.

---

## Losslessness and trust model

**OQ-003 — The exact core invariant.** Status: **Recommendation ready, awaiting decision.** See [research/losslessness-invariant.md](research/losslessness-invariant.md) for the full analysis and the corpus measurements that settle it. Summary of the recommendation: compare on bytes, snap display outward to grapheme boundaries, never normalize, and enforce five stated invariants (reconstruction, coverage-by-containment, equality honesty, fallback visibility, mode agreement). New sub-questions OQ-042 through OQ-045 spun out below.

Original framing retained for context:
The brief asks whether "every changed byte" is the correct invariant. It is very likely not, because bytes interact badly with encoding, byte-order marks, CRLF versus LF, Unicode normalization (NFC versus NFD — directly relevant given Polish text in the product owner's projects), and grapheme clusters.

Provisional two-part formulation under evaluation:

1. **Reconstruction** — the old side and the new side can each be reproduced byte-for-byte from the internal model alone. Cheap, total, catches gross model defects.
2. **Coverage** — every hunk of a canonical minimal character-or-grapheme-level diff intersects at least one presented edit, move, or fallback region. Catches the specific failure of the structural layer silently swallowing a difference.

Open sub-questions: what exactly is the canonical minimal diff computed over — bytes, Unicode scalars, or grapheme clusters; whether coverage should be checked at analysis time for every file or only in tests; what the runtime cost is; and what the application does when the check fails in production (fall back and warn, versus refuse to display).

**OQ-004 — Behavior when a file is not valid UTF-8, or has mixed or unknown encoding.** Status: Open.
Decoding bytes to text is potentially lossy and must be tracked explicitly. Related to OQ-003 and to binary-file handling.

**OQ-005 — Runtime cost and failure policy of the coverage check.** Status: Research required.
Depends on OQ-003. If coverage checking is affordable at runtime it becomes a live safety net; if not, it is a test-time-only guarantee, which is materially weaker. Preliminary finding: reconstruction and containment checks are linear with sorted intervals; the cost centre is computing the canonical diff itself.

**OQ-042 — Which canonical diff algorithm defines `D`.** Status: Open. Raised by the invariant research.
The coverage invariant is stated relative to a fixed, deterministic byte-level diff. Myers over bytes is the obvious candidate. It need not be the algorithm used for presentation — only for validation.

**OQ-043 — Runtime coverage-check size threshold and above-threshold behavior.** Status: Open.
Options: skip the check and mark the file explicitly as unverified, or force raw mode above the threshold. Marking as unverified is the more honest option; silently skipping is not acceptable.

**OQ-044 — Which invisible-difference classes ship in version one.** Status: Open.
Normalization differences are measured present in this corpus and cheap to detect. Zero-width and bidi controls are cheap. Homoglyph detection requires the Unicode confusables table and is a larger commitment.

**OQ-045 — Confirm the structural layer never sees normalized text.** Status: Open, recommended answer "never".
Needs stating as an explicit engine rule, so that no future agent introduces normalization as a matching optimization. A parser or matcher that normalizes identifiers or string literals internally would report a changed string as unchanged.

---

## Git behavior

~~**OQ-006 — Communicating remote staleness.**~~ **Resolved by DEC-010 and DEC-011.** Merge-base uses remote-tracking ref where available, falling back to local; the ref used and its age are always displayed. The application never fetches in version one. One sub-question remains open: displayed "age" is the committer date of the base ref tip, which is not the same as how long ago it was fetched — the latter is what the user actually wants and is not reliably recoverable. UI copy must not conflate them.

~~**OQ-007 — Base-branch detection.**~~ **Resolved by DEC-009.** Cascade: `origin/HEAD` → unique local `main`/`master` → prompt. Detected value displayed and overridable per repository, stored in application config, never in the repository. Sub-question still open: what key override storage uses, given that absolute paths are fragile across moves and renames.

**OQ-008 — Detached HEAD handling.** Status: Open, **downgraded**.
Detached HEAD remains worth handling, but **no repository in the current population is detached** — verified 2026-07-26. It is therefore a hypothetical case, not a tested-against-reality one. The real case is OQ-050.

**OQ-050 — Unborn HEAD (empty repository) handling.** Status: Open. **Blocking.** Supersedes the detached-HEAD framing of OQ-008.
`carrefour-inapp` has `.git/HEAD` pointing at `refs/heads/main` with **zero refs and zero commits**; everything is untracked.

The trap: `git symbolic-ref -q HEAD` **succeeds with exit 0** and returns `refs/heads/main`. The standard detached-HEAD detection idiom therefore reports a branch that does not exist. Any base-detection or scope logic built on it is confidently wrong rather than merely unhelpful.

Open: what the repository list shows for branch and ahead-count (DEC-012 requires an explicit unknown, never a fabricated zero); which of the four DEC-008 scopes are offered at all, given there is no `HEAD` commit to compare against; and what reliable detection of this state looks like — `git rev-parse --verify HEAD` failing is one candidate signal.

**Documentation note.** Earlier drafts recorded this repository as detached HEAD. That was a Phase 0 misreading: `git rev-parse --abbrev-ref HEAD` prints `HEAD` on stdout while writing `fatal:` to stderr, and stderr was suppressed. Corrected across all documents on 2026-07-26. Recorded here rather than deleted, because the failure mode — a Git command whose stdout looks meaningful while stderr carries the error — is exactly the kind of thing the implementation must guard against.

~~**OQ-009 — Which comparison scopes ship in version one.**~~ **Resolved by DEC-008.** Core four: all local vs `HEAD`; unstaged vs index; staged vs `HEAD`; branch vs merge-base of detected base branch. Branch-vs-branch, commit-vs-commit, and commit-vs-parent deferred. Note this promotes OQ-007 (base-branch detection) to blocking.

**OQ-010 — Git access mechanism.** Status: Research required (Phase 3), **in progress**.
Git CLI invocation versus libgit2 bindings versus a language-native implementation. Correctness, performance on the 1.5 GB repository, and packaging implications all bear on this. Explicitly not to be assumed. Interim position only: the CLI is currently better evidenced, because its read-only behavior has been established by measurement and because Raw mode must agree with `git diff` output by definition. No equivalent evidence exists yet for libgit2, whose licence and linking exception also need exact treatment under DEC-020.

**OQ-046 — Auto-gc exposure.** Status: Open. Raised by the read-only audit.
Whether any read-only Git command can trigger `gc --auto` on a large real repository. The audit ran on a scratch repository below auto-gc thresholds, so this is untested where it would matter. Note the obvious mitigation — setting `gc.auto=0` — is itself a config write and therefore prohibited by DEC-003, so a different approach is needed if a read path can trigger maintenance.

~~**OQ-047 — Filter-regime policy.**~~ **Resolved by DEC-025.** The Git layer produces the byte pair `git diff` would use, with filters applied consistently to both sides and disclosed when applied. Requires the `eol-filter-active` fixture, since 0 of 21 repositories currently have filters active.

**OQ-049 — How to obtain cleaned bytes read-only.** Status: Open. **Blocking for filtered repositories.** Raised by the DEC-025 amendment.
`git diff` compares both sides in cleaned (ODB) form, but no read-only plumbing emits cleaned bytes for a worktree file: `cat-file --filters` applies the smudge direction, `hash-object` returns only an OID. Four candidate approaches exist; at least one involves executing repository-configured filter commands, which is a security consideration in its own right — repository content would be choosing what runs.

**OQ-051 — `git status` and `git diff` disagree under an active EOL filter.** Status: Open. Raised by measurement.
Measured: status reports ` M` while diff reports zero lines, persisting after an index-refreshing status. The changed-file list (DEC-012, DEC-017) and the diff view would contradict each other, which is precisely the kind of internal inconsistency that destroys trust. Needs a defined resolution — which of the two the file list follows, and what is disclosed.

**OQ-054 — Case-folding and normalization in path matching.** Status: Open. Raised by measurement.
Measured: writing via `src/foo.ts` when disk holds `src/Foo.TS` makes FSEvents report the **on-disk** case. Git is case-sensitive, macOS's default filesystem is case-insensitive but case-preserving, so a mismatch means auto-refresh (DEC-007) silently stops updating that file. Path matching needs case-folded **and** NFC-normalized comparison — the latter realistic given Polish filenames and the NFD content already measured in this corpus.

**OQ-055 — A built-in terminal.** Status: Open. Raised by the product owner, 2026-07-29.

Asked for directly: a terminal inside the application that handles text editing in the input line the way Warp does — Option+←/→ by word, Cmd+←/→ to line ends, Option+Delete by word — which ordinary terminal emulators handle poorly because they pass keys through a line discipline instead of editing a real text field.

**Nothing in the planning set covers this.** Every existing mention of "terminal" refers to the user's *external* one. `00-index.md` states the product is not a Git client; `18-version-one-scope.md` admits no command execution at all; DEC-028 rejects executing even repository-configured filter commands, on the grounds that content would decide what runs.

What it would actually require, so the size is on record rather than guessed at: a pseudo-terminal, an ANSI/VT escape parser, a scrollback buffer, shell integration for prompt boundaries, and — the part being asked for — an input line that is a real editable text control with the standard macOS motion bindings, reconciled with the shell's own line editor. Warp's advantage comes from replacing the line discipline, not from adding key bindings to it.

It is a **second product inside the first**, and it does not touch the invariant the rest of the application exists to protect. It should not enter version one.

Two smaller things would deliver part of the value at a fraction of the cost, and both belong to the existing scope: "Open in Terminal here" for the selected repository (one `open -a Terminal <path>`, in the same family as DEC-015's editor template), and copying a file's path or a ready-made `git` command to the clipboard. Neither executes anything.

**Revisit** if the product ever moves from *reviewing* changes to *acting* on them — which is the read-only decision (DEC-003), not a UI question.

**OQ-048 — Confirm `--no-optional-locks` coverage.** Status: Open.
Verified for `status`. It is a top-level Git option so it should apply generally, but every command the application issues must be confirmed rather than assumed, and the read-only proof in the test plan must enforce this.

---

## Repository discovery and refresh

~~**OQ-011 — Scan strategy and depth.**~~ **Resolved by DEC-018.** Configurable depth, default 2, descent stops at the first repository found. Consequence: nested repositories and submodules are not surfaced by default, so OQ-014 and OQ-015 must be decided against this rule rather than independently. New requirement recorded: traversal must guard against symlink cycles and symlinks escaping the scan root.

**OQ-012 — Cost of status collection.** Status: Partially resolved by DEC-006 (eager parallel sweep at launch, refresh on focus). Remaining sub-questions below are still Open.
Measured 2026-07-26 (warm cache): full sequential `git status` sweep of all 21 repositories takes 326 ms; slowest single repository is 70 ms; reading all branch names from `.git/HEAD` takes 52 ms. Repository history size does **not** predict status cost — the 1.5 GB repository is not the slowest by much, because cost tracks working-tree file count. See the correction recorded in `00-index.md`.

Consequence: an eager sweep at launch is affordable at this scale, and the earlier concern about a severe long tail does not hold. Still open: behavior as repository count grows well beyond 21; cold-cache behavior (unmeasured, Phase 3.5 spike candidate); whether status is refreshed on window focus; and what the list displays while a repository is still being measured.

~~**OQ-013 — Clean repositories in the list.**~~ **Resolved by DEC-012.** All repositories shown, with two independent signals: uncommitted file count and commits-ahead-of-base. Measurement showed "clean" does not imply "nothing to review" — `5bonsai__website__nextjs` has zero uncommitted changes but is 2 commits ahead of base. Sorting and grouping of the list remain a Phase 4 UX question.

**OQ-014 — Nested repositories and monorepos.** Status: Open.
Zero nested repositories exist today, but 12 of 21 are pnpm monorepos. Open: whether workspace packages are surfaced in any way, and how a nested repository would be presented if one appeared.

**OQ-015 — Git worktrees and submodules.** Status: Deferred pending prioritization.
Neither exists in the current population. Likely deferrable past version one, but must be an explicit decision rather than an oversight, and must not crash or silently misreport if encountered.

~~**OQ-016 — Refresh model.**~~ **Resolved by DEC-007.** Auto-refresh, debounced ~400 ms, preserving file selection and scroll anchor; file watching for the currently open repository only. Debounce value remains provisional. Two sub-questions spun out as still-open: OQ-038 (scroll anchoring) and OQ-039 (atomic-replace saves).

**OQ-017 — Behavior when the configured root does not exist.** Status: Open.

**OQ-038 — Semantics of scroll-anchor preservation across refresh.** Status: Open. Raised by DEC-007.
"Preserve scroll position" cannot mean a pixel or line offset, because the content changes underneath. Anchoring must be semantic — plausibly to the nearest unchanged region, or to an edit index, or to a stable structural node. Needs specification in Phase 4/5, including behavior when the anchor itself is deleted by the incoming change.

**OQ-039 — File-watching behavior for atomic-replace saves.** Status: Research required (Phase 3.5). Raised by DEC-007.
JetBrains IDEs commonly save by writing a temporary file and renaming over the target. The resulting file-system events differ from in-place writes and can defeat naive watchers. Must be verified against actual WebStorm save behavior on macOS 26, including how many events a single save produces (which bears on the debounce value).

---

## Window, navigation, and UX

~~**OQ-018 — Window model.**~~ **Resolved by DEC-005.** Single window, sidebar repository list plus main diff pane, last-opened repository remembered. No tabs, no multi-window. Persisted "last repository" state must be treated as a cache, never as a source of truth.

~~**OQ-019 — View modes and their names.**~~ **Resolved by DEC-013.** Three named modes — Structural, Expanded, Raw — over two code paths, with Expanded specified as a preset over the structural renderer. "Smart" rejected as a name because it implies the tool decides what matters. Sub-question still open: which mode is the default (Structural is presumptive, to confirm in Phase 4).

~~**OQ-020 — Unified versus side-by-side diff.**~~ **Resolved by DEC-014.** Side-by-side only in version one; unified deferred. Consequence: long-line, word-wrap, horizontal-scroll and linked-scroll behavior are promoted to required Phase 4 specification items rather than polish.

~~**OQ-021 — Presentation feature set.**~~ **Resolved by DEC-017.** In scope: navigation essentials, syntax highlighting, move and wrapper visualization, plus all mandatory trust indicators (confidence, parser state, fallback marking, show-raw-region, formatting-only grouping with disclosed counts). Deferred: search within diff, filter by change type, minimap, personal annotations.

Two sub-questions spun out as still open:

- **OQ-040 — Separation of the two color systems.** Status: Open. Syntax highlighting and change indication now coexist, while DEC-016 forbids change meaning from depending on color. Their visual separation must be designed in Phase 4, not tuned late.
- **OQ-041 — File tree versus flat file list.** Status: Open. Not settled by DEC-017; relevant given 12 of 21 repositories are pnpm monorepos, where a flat list of changed files can be long and deeply nested.

~~**OQ-022 — Accessibility commitments for version one.**~~ **Resolved by DEC-016.** No meaning by color alone; full keyboard operation; respect system contrast and reduced-motion. Screen-reader support deferred with the gap documented honestly.

**OQ-023 — Keyboard map.** Status: Open, and **promoted to required specification work** by DEC-016.
Because full keyboard operation is now a commitment rather than a feature, Phase 4 must define a complete keyboard map covering repository selection, scope switching, file navigation, change navigation, and mode switching — not a handful of shortcuts.

~~**OQ-024 — Theming.**~~ **Resolved by DEC-019.** Follow macOS system light/dark with a built-in syntax theme per appearance. Consequence: both variants must independently satisfy the DEC-016 contrast and color-independence commitments, and theme changes must be handled while the application is running.

**OQ-025 — External editor invocation mechanism.** Status: Research required (Phase 3 / 3.5). Scope narrowed by DEC-015.
DEC-015 settled the *shape* — a configurable command template defaulting to WebStorm. Still open: which invocation mechanism is actually reliable on macOS 26 (URL scheme versus command-line launcher, including the case where the launcher is not installed); failure behavior when the editor is absent; sandboxing implications of launching an external process; and what "open this line" means when the line exists only on the old side of a deleted region.

---

## Diff engine specifics

**OQ-026 — Move detection in version one.** Status: Open, **risk materially reduced by DEC-024**.
Moves carry a known trap: a move that discards its internal delta is a losslessness violation. Under the byte-partition model a move regroups segments and cannot replace them, so the trap is structurally impossible rather than merely prohibited. What remains open is whether move *detection* ships in v1 at all, on cost and quality grounds rather than safety grounds. Domain research recommends modelling a move as `Move { fromRange, toRange, innerDiff }` with `innerDiff` empty **iff** the moved bytes are identical.

**OQ-052 — Position coordinate system is a stack-level disqualifier.** Status: Open. **High impact.** Raised by measurement.
**[Fact]** Both JavaScript bindings for tree-sitter report **UTF-16 code units while their type definitions describe them as bytes**: `node-tree-sitter` computes `ts_node_start_byte(node) / 2`, `web-tree-sitter` uses `byte_to_code_unit(byte) { return byte >> 1 }` with `TSInputEncodingUTF16LE`. The C, Rust, and **Swift** bindings are genuinely byte-native.

On a corpus that is 51% non-ASCII, this produces **silent** partition corruption rather than a loud error — exactly the failure shape DEC-024 exists to prevent. TypeScript and oxc-in-Node also report UTF-16.

This is not merely a parser criterion; it constrains the **stack** decision (OQ-033), because the same parser is safe or unsafe depending on which binding a stack forces. Any candidate reporting UTF-16 needs a conversion layer that is itself a correctness risk and must be independently tested (spike P-4).

~~**OQ-049 — How to obtain cleaned bytes read-only.**~~ **Resolved by DEC-028.** Filtered files fall back to raw with disclosure. Executing repository-configured filter commands was rejected on security grounds — repository content would choose what executes.

~~**OQ-027 — Repeated identical nodes.**~~ **Resolved by DEC-031.** Ambiguous matches surfaced as reduced confidence, never resolved arbitrarily. GumTree's top-down phase already computes the `unique()`/`ambiguous()` partition and discards it; no existing tool exposes it. Five-level contextual tie-break deferred. Original framing retained below for context.

**OQ-027 (original framing) — Repeated identical nodes.** Status: Superseded.
Multiple near-identical JSX siblings make matching genuinely ambiguous. Domain research found that **76% of commits contain at least one instance** (TOSEM 2024), and JSX makes it worse — so this is the common case, not an edge case. Policy needed: ambiguity must lower confidence and trigger visible degradation rather than produce an arbitrary confident pairing. Candidate tie-breakers from the literature: identity of neighbouring siblings, then ancestor edit distance at increasing depth. Ordering must be deterministic and documented (see T-7).

**OQ-028 — Invalid, incomplete, or conflicted source.** Status: Open.
Half-typed JSX during editing, and merge-conflict markers. Parser error recovery quality is a Phase 3.5 spike candidate.

**OQ-029 — Large, generated, minified, and binary files.** Status: Open.
Thresholds, degradation strategy, and detection method. Must degrade visibly, never silently.

**OQ-030 — File-level matching: renames, moves, deletions, untracked files.** Status: Open.
Including files that are both renamed and modified, and how much to trust Git's own rename detection.

**OQ-031 — Performance budgets.** Status: Research required.
No numbers exist yet. Needs targets for repository list population, scope switching, and diff rendering, measured against the actual repository population — notably the 1.5 GB repository and the 63-changed-file working tree.

**OQ-032 — Caching strategy.** Status: Open. Depends on OQ-031 and the pinned-source-pair model.

---

## Technical and delivery

**OQ-033 — The entire technology stack.** Status: Research required (Phase 3). **No stack has been chosen and none may be assumed.**
DEC-002 removed the cross-platform criterion but did not select a stack. Native macOS toolkits, Electron, Tauri, and others remain open candidates, as do all Git, parser, matcher, diff, and rendering components.

**OQ-034 — Distribution and updating.** Status: Open.
App Store versus outside distribution; code signing and notarization; whether an update mechanism is needed. Depends partly on OQ-002.

**OQ-035 — Sandboxing.** Status: Open. **Difficulty raised by DEC-037.**
A tool that reads arbitrary directories and launches an external editor has real tension with the App Sandbox. Interacts with OQ-034.

DEC-037 makes this materially harder: with multiple user-chosen roots *plus* individually added repositories anywhere, a sandboxed application must obtain user-granted access **per location** and persist it across launches via security-scoped bookmarks — including handling revocation and stale bookmarks. One root would have meant one grant. This is now a first-order input to the sandboxing decision rather than a detail.

**OQ-036 — Licensing of candidate dependencies.** Status: Research required (Phase 3).
Particularly relevant for any engine that would be embedded or forked. Commercial-use implications depend on OQ-002.

**OQ-037 — Test infrastructure.** Status: Research required.
Constrained by DEC-002: the diff engine must run headlessly in CI. Property-based and invariant-based testing approaches to be evaluated in Phase 6.

---

## Confirmed non-questions

Recorded so they are not reopened by mistake. These are constraints from the brief, not decisions to be made:

- No cloud processing without explicit approval.
- No telemetry without explicit approval.
- No AI required during normal application use.
- No silent `git fetch`.
- No silent repository modification.
- No destructive Git operations without explicit discussion.
- No requirement for GitHub, GitLab, Bitbucket, pull requests, or any remote.
- Formatting changes are never treated as nonexistent.
- AST equality is never treated as source equality.
- Parser output is never the sole source of truth.
