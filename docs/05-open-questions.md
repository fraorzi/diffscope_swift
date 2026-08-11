# 05 — Open Questions

Everything raised and not yet decided. Each entry carries a status as defined in [glossary.md](glossary.md).

**Rule for all agents: do not resolve an open question by assumption.** Bring it to the product owner as a concrete question with options, trade-offs, and a recommendation, then record the answer in [04-decision-log.md](04-decision-log.md) immediately. If work must proceed before an answer exists, mark the working assumption as a **provisional assumption** here and flag it for confirmation.

Questions are grouped by area. Identifiers are stable; resolved questions are struck through and annotated with the decision that closed them rather than deleted.

**Audited 2026-08-11** against the decision log and the code, and **OQ-054 was fixed the same day** (DEC-069). **Twenty-four entries were marked Open while a decision, a measurement or a shipped implementation had already answered them** — a document that says *undecided* about something built three milestones ago sends a fresh agent to re-decide it, which is the failure this document exists to prevent. Each is now struck through with what closed it: OQ-003, 004, 005, 008, 010, 017, 026, 028, 031, 033, 036, 037, 038, 039, 040, 042, 043, 044, 045, 048, 049, 050, 051, 052.

**One entry appeared twice**, Open in one section and struck through in another (OQ-049). That is the same drift in miniature.

**Seven are genuinely open. Five more are part-answered** and now say which part.

**OQ-054 was closed the same day by DEC-069** — the audit called it the most consequential entry still open, and building the fix found that both halves of its stated problem were wrong while a narrower real defect sat underneath. See its entry, and M9-F.

| Genuinely open | Why it stays open |
|---|---|
| **OQ-032** caching | Specified in `16-…` §6, never decided. What blocks it is that nothing has been slow enough to need it |
| **OQ-041** tree versus flat list | DEC-033's grouping is a middle position, not an answer. Left open on purpose |
| **OQ-034** distribution · **OQ-035** sandboxing | Shipping questions. A tester build is not a distribution |
| **OQ-056** Git write operations | Version two, and it reopens DEC-003 explicitly or not at all |
| **OQ-001** the product name | Packaging has already adopted the placeholder |
| **OQ-015** worktrees and submodules | Deferred; neither exists in the population |

| Part-answered | What is left |
|---|---|
| **OQ-012** cost of status collection | Cold-cache behaviour, still entirely unmeasured; and scale past ~100 repositories |
| **OQ-014** nested repositories and monorepos | Workspace packages are grouped; a nested repository would simply not be seen |
| **OQ-025** external editor | Sandbox implications, and what *open this line* means for a deleted region |
| **OQ-029** large, generated, minified, binary | Only `generated` — `FixtureCatalog` counts that gap by name |
| **OQ-030** file-level matching | Renames are consumed; nothing says what a *wrong* one would look like |

---

## Product and naming

**OQ-001 — Product name.** Status: Open, **and packaging has already adopted the placeholder.**
`diffscope` is a placeholder working name used for the directory. Final naming affects the bundle identifier, app name, and any distribution. Low urgency, but must be settled before packaging work in Phase 8.

**Phase 8 arrived without this being settled.** `Scripts/package.sh` ships `DiffScope.app` in `DiffScope-<version>.zip` with a drawn icon, and `25-tester-packet.md` calls the product DiffScope to a stranger. That is the placeholder being used, not the question being answered — recorded here so the name is renamed deliberately if it is renamed at all, rather than discovered to be load-bearing later. It reaches the bundle identifier, the icon, the packet and the repository name.

~~**OQ-002 — Target users beyond the product owner.**~~ **Resolved by DEC-020.** Personal tool; distribution deliberately left undecided. Critical consequence carried forward: licensing of Phase 3 candidates must still be evaluated against possible future distribution, because adopting a strongly copyleft engine would quietly foreclose that option.

---

## Losslessness and trust model

~~**OQ-003 — The exact core invariant.**~~ **Resolved by DEC-021**, which took the recommendation below in full: comparison on bytes, display snapped outward to grapheme boundaries, no normalization anywhere, and the five invariants stated as INV-1 … INV-5. Enforced rather than asserted — `validate()` runs on every model, T-10's grapheme snapping is `snapToGraphemeBoundaries`, and the ŻABKA fixture is the negative control the recommendation was derived from. The recommendation is kept below because it is the argument, and the argument is what a future agent needs before reopening any of it.

Original framing retained for context:
The brief asks whether "every changed byte" is the correct invariant. It is very likely not, because bytes interact badly with encoding, byte-order marks, CRLF versus LF, Unicode normalization (NFC versus NFD — directly relevant given Polish text in the product owner's projects), and grapheme clusters.

Provisional two-part formulation under evaluation:

1. **Reconstruction** — the old side and the new side can each be reproduced byte-for-byte from the internal model alone. Cheap, total, catches gross model defects.
2. **Coverage** — every hunk of a canonical minimal character-or-grapheme-level diff intersects at least one presented edit, move, or fallback region. Catches the specific failure of the structural layer silently swallowing a difference.

Open sub-questions: what exactly is the canonical minimal diff computed over — bytes, Unicode scalars, or grapheme clusters; whether coverage should be checked at analysis time for every file or only in tests; what the runtime cost is; and what the application does when the check fails in production (fall back and warn, versus refuse to display).

~~**OQ-004 — Behavior when a file is not valid UTF-8, or has mixed or unknown encoding.**~~ **Resolved by DEC-021 and DEC-051.** The premise — "decoding bytes to text is potentially lossy and must be tracked" — was answered by never decoding: comparison is on bytes, so no encoding is ever assumed and nothing is lost to a wrong guess. Where the bytes cannot be *shown* as text, `Degradation.binary` (**F9**) carries it, and its documentation says so explicitly: *invalid UTF-8 is mapped here*. DEC-051 gives it rank 1 in the precedence order, so a file that is both undecodable and, say, oversize reports the more specific reason.

~~**OQ-005 — Runtime cost and failure policy of the coverage check.**~~ **Resolved by DEC-022, DEC-040 and DEC-043**, in that order. DEC-022 makes the check live rather than test-time; DEC-040 sets the threshold above which the independent `D` is not computed; DEC-043 replaced that file-size threshold with a **bound on counted work**, and a file that exceeds it is labelled **unverified** rather than silently skipped. The preliminary finding below held: the cost centre is `D` itself.

~~**OQ-042 — Which canonical diff algorithm defines `D`.**~~ **Resolved by DEC-039.** `D` is **Myers over bytes**, implemented independently of the presentation path — the independence being the point, since a validator sharing code with the thing it validates agrees with its defects. Minimality is checked against a dynamic-programming LCS reference over 600 random inputs rather than assumed.

~~**OQ-043 — Runtime coverage-check size threshold and above-threshold behavior.**~~ **Resolved by DEC-040, then re-specified by DEC-043.** The honest option below was taken: above the bound the file is labelled **unverified** and the partition assertions still run. DEC-043 changed what the bound *is* — counted work rather than file size — because a bound on bytes refuses a large simple file while admitting a small pathological one.

~~**OQ-044 — Which invisible-difference classes ship in version one.**~~ **Resolved by DEC-023.** Three ship: `normalization-form`, `invisible-control` and `whitespace-lookalike`. Homoglyph detection did not, for the reason given below — the confusables table is a larger commitment than the value. Measured in M6-C, which is worth reading before touching the detector: Swift's `String ==` is canonical equivalence, so the obvious NFC test is always false and the detector silently detected nothing while its fixtures passed.

~~**OQ-045 — Confirm the structural layer never sees normalized text.**~~ **Confirmed, and the answer is "never" — DEC-021, DEC-024.** It is now an engine rule rather than an intention: comparison is on bytes end to end, the byte partition is the primitive the structural layer is built over, and `21-agent-handoff.md` §6 lists normalisation first among the questions that must not be silently re-decided — *not reopenable; disqualified by measurement*. The ŻABKA fixture is what makes a future violation fail rather than merely be discouraged.

---

## Git behavior

~~**OQ-006 — Communicating remote staleness.**~~ **Resolved by DEC-010 and DEC-011.** Merge-base uses remote-tracking ref where available, falling back to local; the ref used and its age are always displayed. The application never fetches in version one. One sub-question remains open: displayed "age" is the committer date of the base ref tip, which is not the same as how long ago it was fetched — the latter is what the user actually wants and is not reliably recoverable. UI copy must not conflate them.

~~**OQ-007 — Base-branch detection.**~~ **Resolved by DEC-009.** Cascade: `origin/HEAD` → unique local `main`/`master` → prompt. Detected value displayed and overridable per repository, stored in application config, never in the repository. Sub-question still open: what key override storage uses, given that absolute paths are fragile across moves and renames.

~~**OQ-008 — Detached HEAD handling.**~~ **Built and checked.** `RepositoryHead.detached(String)` in `DiffScopeGit/Repository.swift` reads as *detached at &lt;sha&gt;* in the repository row, and the suite asserts it by name. It remains a hypothetical case in this population, which is why it is closed by a check rather than by a measurement.

~~**OQ-050 — Unborn HEAD (empty repository) handling.**~~ **Built and checked**, and all three of its open parts are answered — by implementation against DEC-012's rule that an unknown is stated rather than fabricated, not by a new decision:

- **What the list shows.** `RepositoryHead.unborn(intendedBranch:)` says there are no commits *and* names the branch that would be created. The suite asserts exactly that sentence.
- **Which scopes are offered.** `Scopes.swift` gates on the unborn case directly, and the interface disables an unavailable scope **with its reason on the line** (M8-K).
- **Reliable detection.** `git rev-parse --verify HEAD` failing is the signal, exactly as this entry proposed — not `symbolic-ref`, which is the trap recorded below.

The original text is kept in full because the trap it records is the general lesson: **a Git command whose stdout looks meaningful while stderr carries the error.**
`carrefour-inapp` has `.git/HEAD` pointing at `refs/heads/main` with **zero refs and zero commits**; everything is untracked.

The trap: `git symbolic-ref -q HEAD` **succeeds with exit 0** and returns `refs/heads/main`. The standard detached-HEAD detection idiom therefore reports a branch that does not exist. Any base-detection or scope logic built on it is confidently wrong rather than merely unhelpful.

Open: what the repository list shows for branch and ahead-count (DEC-012 requires an explicit unknown, never a fabricated zero); which of the four DEC-008 scopes are offered at all, given there is no `HEAD` commit to compare against; and what reliable detection of this state looks like — `git rev-parse --verify HEAD` failing is one candidate signal.

**Documentation note.** Earlier drafts recorded this repository as detached HEAD. That was a Phase 0 misreading: `git rev-parse --abbrev-ref HEAD` prints `HEAD` on stdout while writing `fatal:` to stderr, and stderr was suppressed. Corrected across all documents on 2026-07-26. Recorded here rather than deleted, because the failure mode — a Git command whose stdout looks meaningful while stderr carries the error — is exactly the kind of thing the implementation must guard against.

~~**OQ-009 — Which comparison scopes ship in version one.**~~ **Resolved by DEC-008.** Core four: all local vs `HEAD`; unstaged vs index; staged vs `HEAD`; branch vs merge-base of detected base branch. Branch-vs-branch, commit-vs-commit, and commit-vs-parent deferred. Note this promotes OQ-007 (base-branch detection) to blocking.

~~**OQ-010 — Git access mechanism.**~~ **Resolved by DEC-042: the CLI**, with `--no-optional-locks` on every invocation. The interim position below became the decision, and the measurement is why: `status` on the 1.5 GB repository is **46 ms** by CLI against **264 ms** by libgit2 (5.7×), the bindings are healthier, the licence is simpler, and Raw mode has to agree with `git diff` by definition — which a reimplementation would have to earn and the CLI has for free.

~~**OQ-046 — Auto-gc exposure.**~~ **Resolved by measurement, 2026-08-09 — the answer is no.** Measured two ways in `22-experiment-log.md` → **M8-M**: a scratch repository with the thresholds brought down to it (`gc.auto=1`, `gc.autoPackLimit=1`, foreground) where three full sweeps of the registry change nothing while a single `git commit` fires immediately, and the largest real repository in the corpus — 6,115 loose objects, **91% of git's default threshold** — unchanged after the read-only operations. The eager-threshold arm is now a permanent check, so an operation added to the registry that does trigger maintenance fails the suite.

Both mitigations were unavailable, which is why this had to be measured rather than configured around: `gc.auto=0` is a config write forbidden by DEC-003, and `-c gc.auto=0` is forbidden by `GitOperation.forbiddenArguments`. A user's own `git commit` in the built-in terminal can still trigger gc, which is DEC-053's separation working as intended.

~~**OQ-047 — Filter-regime policy.**~~ **Resolved by DEC-025.** The Git layer produces the byte pair `git diff` would use, with filters applied consistently to both sides and disclosed when applied. Requires the `eol-filter-active` fixture, since 0 of 21 repositories currently have filters active.

~~**OQ-049 — How to obtain cleaned bytes read-only.**~~ **Resolved by DEC-028: you do not.** A filtered file falls back to raw **with the filter disclosed**, because every approach that produces cleaned bytes runs a command the *repository* configures — repository content choosing what executes. `cat-file --textconv` was subsequently removed from the read-only registry for the same reason, with `GitOperation.forbiddenArguments` standing guard: R-8 proved it does not *write*, and running repository-configured commands is a different property from writing.

**This entry appeared twice in this document**, Open here and struck through under *Diff engine specifics*, which is the drift the audit of 2026-08-11 found. Its home is here, with Git behaviour; the other is a cross-reference.

~~**OQ-051 — `git status` and `git diff` disagree under an active EOL filter.**~~ **Resolved by DEC-041: the file list follows `git status`.** The measurement below is the case that forced it — status reports ` M` while diff reports zero lines — and the resolution is that the list keeps saying *changed* while the diff view **discloses the filter and says the two sides are byte-equal**. Hiding the row would be the tool deciding the reader is wrong about their own repository. F8 is what carries the disclosure, and it fires *even when the sides are byte-equal*, which is this case exactly.

~~**OQ-054 — Case-folding and normalization in path matching.**~~ **Resolved by DEC-069, 2026-08-11 — and this entry was wrong about the mechanism, wrong about the remedy, and right that something was broken.** Measured in `22-experiment-log.md` → **M9-F**. Kept in full below, because the corrections are worth more than the conclusion.

**What it claimed, and what was measured:**

- *"auto-refresh silently stops updating that file"* — **cannot happen.** `RepositoryWatcher.deliver` ORs the event flags and signals `.changed` for the **whole repository**; no FSEvents path is ever compared with a Git path. The entry was written against a per-file watching design, and DEC-007 with DEC-027 built a per-repository one.
- *"needs case-folded **and** NFC-normalized comparison"* — **the normalisation half needs no code.** Swift's `String ==`, `hasPrefix` and `Set` membership are canonical equivalence, so NFC and NFD forms already compare and hash equal. That is now asserted in the suite rather than relied on quietly: it is the second time this project has depended on those semantics and the first (M6-C) was a defect.
- The filesystem itself is **case-insensitive and normalization-insensitive for lookup**, so *reading* a file never fails for either reason. Only Swift-side comparison can break, and only on case.
- **Root scanning was never broken.** `contentsOfDirectory` returns the filesystem's own spelling and `resolvingSymlinksInPath` canonicalises case — so the first check written for this passed on the unfixed code.

**What was actually broken**, and it is narrow: an **individually added** repository is taken verbatim from the configuration and goes through neither of those. DEC-037 put roots and individual repositories in one list, so the same working tree reached both ways produced **two rows** — two watchers, two sweeps, and a reader editing in one while the other went stale. `removeSource` and the add-source dedupe compared paths exactly and failed the same way. The spellings differ by more than case: `/var` against `/private/var` for the same file.

**DEC-069's answer is to stop computing identity from the string and ask the filesystem** — device plus inode where the path exists, a folded string only where there is nothing to ask.

**The original text, retained:**

Measured: writing via `src/foo.ts` when disk holds `src/Foo.TS` makes FSEvents report the **on-disk** case. Git is case-sensitive, macOS's default filesystem is case-insensitive but case-preserving, so a mismatch means auto-refresh (DEC-007) silently stops updating that file. Path matching needs case-folded **and** NFC-normalized comparison — the latter realistic given Polish filenames and the NFD content already measured in this corpus.

~~**OQ-055 — A built-in terminal.**~~ Status: **Resolved 2026-07-31 — build it**, recorded as **DEC-053** on 2026-08-01 once gate T0 had passed, and extended by **DEC-067** on 2026-08-10 to several sessions in tabs across a full-width drawer. The product owner put it at the front of the queue. Plan and gate: [26-terminal-plan.md](26-terminal-plan.md); measurement: `22-experiment-log.md` → T0. The analysis below is kept because its cost estimate is what the plan is built on.

Asked for directly: a terminal inside the application that handles text editing in the input line the way Warp does — Option+←/→ by word, Cmd+←/→ to line ends, Option+Delete by word — which ordinary terminal emulators handle poorly because they pass keys through a line discipline instead of editing a real text field.

**Nothing in the planning set covers this.** Every existing mention of "terminal" refers to the user's *external* one. `00-index.md` states the product is not a Git client; `18-version-one-scope.md` admits no command execution at all; DEC-028 rejects executing even repository-configured filter commands, on the grounds that content would decide what runs.

What it would actually require, so the size is on record rather than guessed at: a pseudo-terminal, an ANSI/VT escape parser, a scrollback buffer, shell integration for prompt boundaries, and — the part being asked for — an input line that is a real editable text control with the standard macOS motion bindings, reconciled with the shell's own line editor. Warp's advantage comes from replacing the line discipline, not from adding key bindings to it.

It is a **second product inside the first**, and it does not touch the invariant the rest of the application exists to protect. It should not enter version one.

Two smaller things would deliver part of the value at a fraction of the cost, and both belong to the existing scope: "Open in Terminal here" for the selected repository (one `open -a Terminal <path>`, in the same family as DEC-015's editor template), and copying a file's path or a ready-made `git` command to the clipboard. Neither executes anything.

**The interaction with OQ-056 matters more than the feature does.** A terminal inside the application lets the user run `git commit` inside a product that promises it never writes to a repository. That is not a violation — the user is doing it, deliberately, in a shell — but it dissolves the sentence "this application cannot modify your repositories" into something that needs a paragraph of explanation. If Git write operations are taken up under OQ-056 the tension disappears; if they are not, a terminal quietly grants the same power without any of OQ-056's questions being answered.

**What actually happened (T4, 2026-08-01).** The terminal was built, and the paragraph of explanation was written rather than avoided: eleven documents said the application could not change a repository, and each now distinguishes *the application acting on its own* from *the user typing in a shell*. `25-tester-packet.md` says both in plain words, because it goes to a stranger with the zip. A check holds those sentences in place, with a negative control that catches the old wording reappearing. **OQ-056 is untouched by this** — staging and committing as product features still need their own decision, and DEC-053 says so explicitly.

**Revisit** if the product ever moves from *reviewing* changes to *acting* on them — which is the read-only decision (DEC-003), not a UI question.

**OQ-056 — Git write operations: stage, unstage, commit, pull.** Status: Open. Raised by the product owner, 2026-07-31.

Asked for directly, and **this is the one decision the product cannot drift into** — it reopens DEC-003, which made version one *strictly* read-only.

**DEC-003 anticipated it.** Its consequences say: *"Staging is positioned as a natural version-two capability. It requires a correct and trusted hunk model, which is precisely what version one establishes. Sequencing is therefore favorable rather than merely cautious."* So this is the planned next product, not a contradiction of the last one — provided the sequencing is honoured rather than skipped.

**What version one buys that makes this safe later.** Staging a hunk means writing exactly the bytes the interface claimed were in that hunk. The whole invariant apparatus — INV-1 reconstruction, INV-2 containment, the byte partition, the independent canonical diff — is what makes "these bytes and no others" a checkable claim rather than a hope. Staging built on an unproven hunk model is how a diff tool corrupts someone's work.

**What changes, and none of it is small:**

- **The read-only proof (R-8) stops being a blanket claim.** Today every registered Git operation is proven to leave `.git` byte-identical. With writes there are two registries — operations that must not write, and operations that write deliberately — and the second needs a different proof: that it wrote *what was shown* and nothing else.
- **Index-lock races with WebStorm and the terminal become real.** DEC-003 avoided them entirely by not writing. A concurrent `git add` from another tool while this one stages is a first-order concern, not an edge case.
- **`--no-optional-locks` and `GIT_OPTIONAL_LOCKS=0` are read-path settings.** A write path needs the opposite and needs to handle lock contention explicitly.
- **Pull is a different animal from stage and commit.** It touches the network, can rewrite the working tree under a reader, and can conflict. DEC-011 forbids automatic fetch for staleness reasons; a *user-initiated* pull is a separate question from an automatic one, and should be decided separately.
- **The pinned pair (DEC-049) becomes mutable under the reader.** Refresh currently assumes changes come from outside; after a write it also comes from inside, and the anchor machinery has to survive both.
- **Undo.** A tool that can stage must answer what happens when the user regrets it. `git reset` is easy; the trust story around it is not.

**Recommended sequencing if it is taken up:** unstage before stage (it destroys nothing), stage-whole-file before stage-hunk, commit after both, pull last and never automatic. Each step gets its own decision entry, and R-8 is re-specified before the first write ships — not after.

**Revisit:** this is a version-two scope decision, and taking it up means reopening DEC-003 explicitly with a new decision entry, per the rule in `21-agent-handoff.md` §6 that read-only must not be silently re-decided. See also [[OQ-055]]: the terminal **has since been built** (DEC-053), so the sideways grant is now real — a user can commit from inside the application today. That does not answer any question below. What it changes is the framing: the argument for staging as a feature is no longer "the product cannot write", it is "a hunk-accurate staging surface is safer and clearer than a command line", which is a better argument and a different one.

~~**OQ-048 — Confirm `--no-optional-locks` coverage.**~~ **Confirmed, and enforced rather than confirmed once.** The flag is not passed per call site: `GitRunner.readOnlyGlobalArguments` prepends it to **every** invocation, and two checks hold that — one asserting the runner always passes it, one asserting the auto-gc registry does. Coverage of the commands themselves comes from the closed operation registry plus R-8, which snapshots `.git` before and after all 18 registered operations, so a new Git call without a proof fails the suite. That is the "must be confirmed rather than assumed" this entry asked for, made structural.

---

## Repository discovery and refresh

~~**OQ-011 — Scan strategy and depth.**~~ **Resolved by DEC-018.** Configurable depth, default 2, descent stops at the first repository found. Consequence: nested repositories and submodules are not surfaced by default, so OQ-014 and OQ-015 must be decided against this rule rather than independently. New requirement recorded: traversal must guard against symlink cycles and symlinks escaping the scan root.

**OQ-012 — Cost of status collection.** Status: Partially resolved by DEC-006 (eager parallel sweep at launch, refresh on focus). Remaining sub-questions below are still Open.
Measured 2026-07-26 (warm cache): full sequential `git status` sweep of all 21 repositories takes 326 ms; slowest single repository is 70 ms; reading all branch names from `.git/HEAD` takes 52 ms. Repository history size does **not** predict status cost — the 1.5 GB repository is not the slowest by much, because cost tracks working-tree file count. See the correction recorded in `00-index.md`.

Consequence: an eager sweep at launch is affordable at this scale, and the earlier concern about a severe long tail does not hold.

Two of the four sub-questions are answered: **status is refreshed on window focus** (DEC-006, built 2026-07-31 and listed in `23b-…` as closed), and **the list shows what is cheap to know while a repository is still being measured** — per-file badges from the extension, a `stat` and a 4 KB probe, with anything needing a full read left to the diff view (DEC-033 as amended).

**Still open:** behaviour as repository count grows well beyond 21 — `16-…` §4 says re-measure past ~100 — and **cold-cache behaviour, which remains entirely unmeasured**; every figure in this project is warm.

~~**OQ-013 — Clean repositories in the list.**~~ **Resolved by DEC-012.** All repositories shown, with two independent signals: uncommitted file count and commits-ahead-of-base. Measurement showed "clean" does not imply "nothing to review" — `5bonsai__website__nextjs` has zero uncommitted changes but is 2 commits ahead of base. Sorting and grouping of the list remain a Phase 4 UX question.

**OQ-014 — Nested repositories and monorepos.** Status: **Half answered.**
Zero nested repositories exist today, but 12 of 21 are pnpm monorepos.

**Workspace packages are surfaced** — DEC-033 as amended groups the changed-file list by declared package where one exists and by parent directory otherwise, with headers suppressed where grouping buys nothing. That shape came from measurement rather than from the specification: all 12 `pnpm-workspace.yaml` files were read and **none declares `packages:`**, so the specified per-package grouping would have put one meaningless header above every list.

**Still open:** how a nested repository would be presented if one appeared. DEC-018 stops descent at the first repository found, so today one would simply not be seen.

**OQ-015 — Git worktrees and submodules.** Status: Deferred pending prioritization.
Neither exists in the current population. Likely deferrable past version one, but must be an explicit decision rather than an oversight, and must not crash or silently misreport if encountered.

~~**OQ-016 — Refresh model.**~~ **Resolved by DEC-007.** Auto-refresh, debounced ~400 ms, preserving file selection and scroll anchor; file watching for the currently open repository only. Debounce value remains provisional. Two sub-questions spun out as still-open: OQ-038 (scroll anchoring) and OQ-039 (atomic-replace saves).

~~**OQ-017 — Behavior when the configured root does not exist.**~~ **Resolved by DEC-036, then generalised by DEC-052.** A missing source is **named rather than dropped**: DEC-036 settled the single-root case, and DEC-052 made configuration a JSON file the user can read holding any number of roots plus individual repositories, each missing one reported by path. The empty state offers a picker **with no suggested path** — the `~/WebstormProjects` default is gone, per the no-editor-specific-defaults rule.

~~**OQ-038 — Semantics of scroll-anchor preservation across refresh.**~~ **Resolved by DEC-034, and measured in M7-C.** Anchoring is semantic, as this entry required: anchors come from the **canonical diff's matched blocks**, one per line, identified by a 3-line content hash plus an occurrence index. The behaviour when the anchor is deleted is a resolution the model reports rather than hides (`exact`, `noPreviousAnchor`, and the degraded cases), and the drift clause is checked rather than argued — twenty refreshes with no change resolve to one position.

**Read M7-C before touching it.** DEC-034's own words were *"the nearest segment labeled unchanged"*, and implemented literally that gives **Raw zero anchors**, because Raw is one fallback segment over the whole file.

~~**OQ-039 — File-watching behavior for atomic-replace saves.**~~ **Resolved by measurement, and it is in `16-…` §1.4.** A single atomic-replace save produces **5 events**, spanning 11.1 ms at p50 and 13.3 ms at maximum — which is what DEC-026's 400 ms quiet period is sized against, with a 2 s cap for continuous saving. 40,000 file creations produced 40,041 events and **zero drops**; the drop path is therefore forced through `deliver(flags:)` in the suite, because untriggered means untested.

---

## Window, navigation, and UX

~~**OQ-018 — Window model.**~~ **Resolved by DEC-005.** Single window, sidebar repository list plus main diff pane, last-opened repository remembered. No tabs, no multi-window. Persisted "last repository" state must be treated as a cache, never as a source of truth.

~~**OQ-019 — View modes and their names.**~~ **Resolved by DEC-013.** Three named modes — Structural, Expanded, Raw — over two code paths, with Expanded specified as a preset over the structural renderer. "Smart" rejected as a name because it implies the tool decides what matters. Sub-question still open: which mode is the default (Structural is presumptive, to confirm in Phase 4).

~~**OQ-020 — Unified versus side-by-side diff.**~~ **Resolved by DEC-014.** Side-by-side only in version one; unified deferred. Consequence: long-line, word-wrap, horizontal-scroll and linked-scroll behavior are promoted to required Phase 4 specification items rather than polish.

~~**OQ-021 — Presentation feature set.**~~ **Resolved by DEC-017.** In scope: navigation essentials, syntax highlighting, move and wrapper visualization, plus all mandatory trust indicators (confidence, parser state, fallback marking, show-raw-region, formatting-only grouping with disclosed counts). Deferred: search within diff, filter by change type, minimap, personal annotations.

Two sub-questions spun out as still open:

- ~~**OQ-040 — Separation of the two color systems.**~~ **Resolved by DEC-035, and delivered by DEC-066.** The separation is not a hue budget but a division of carriers: **syntax gets colour, change gets shape** — a sign column, a glyph, an underline, a background texture — so a change never depends on a hue that syntax is also using. DEC-066's token table is what made it implementable in one pass, and the **greyscale column** of `ChangeLanguage.dc.html` is where it gets checked before any code is written. It has already caught three things during the design review (`27-…` §3), including added and removed lines sharing a glyph and a texture, distinguished by hue alone in a layout that has no panes. The check is live too: the style audit reads the **computed style of the live document** and fails a mark distinguished by colour alone, with a hostile injection as its control.
- **OQ-041 — File tree versus flat file list.** Status: Open, and **deliberately left open** — see `21-agent-handoff.md` §0. Not settled by DEC-017; relevant given 12 of 21 repositories are pnpm monorepos, where a flat list of changed files can be long and deeply nested. DEC-033's grouping (see OQ-014) is the middle position currently shipping — headers where a package or parent directory earns one — and it is not the same thing as a tree, which is why this stays open rather than being quietly closed by it.

~~**OQ-022 — Accessibility commitments for version one.**~~ **Resolved by DEC-016.** No meaning by color alone; full keyboard operation; respect system contrast and reduced-motion. Screen-reader support deferred with the gap documented honestly.

~~**OQ-023 — Keyboard map.**~~ **Resolved by DEC-057, 2026-08-09.** Coverage was settled by `12-…` §9; the concrete bindings are now `KeyboardMap.bindings` in `Sources/DiffScopeShell`, which the menu bar is *generated from* and the check suite links directly. A function §9 requires and nothing binds fails `diffscope-verify` by name. Measured in `22-experiment-log.md` → **M8-J**, where the coverage check found that *show raw for the current region* had never been implemented at all.

~~**OQ-024 — Theming.**~~ **Resolved by DEC-019.** Follow macOS system light/dark with a built-in syntax theme per appearance. Consequence: both variants must independently satisfy the DEC-016 contrast and color-independence commitments, and theme changes must be handled while the application is running.

**OQ-025 — External editor invocation mechanism.** Status: **Mostly answered; one part still open.**
DEC-015 settled the *shape* — a configurable command template defaulting to WebStorm, overridable through `DIFFSCOPE_EDITOR` and now through a Settings window, never populated from repository content.

**Answered:** the mechanism is the command-line launcher with `{file}` and `{line}` substituted; **failure when the editor is absent is shown in the status line** rather than swallowed, and F13 reports both its arms. Building that fixture found an unrelated defect worth keeping on record — the template was substituted *before* being split, so a path containing a space became three arguments.

**Still open:** the sandboxing implications of launching another application (which is OQ-035's territory), and what *open this line* should mean when the line exists only on the old side of a deleted region. ⌘⏎ opens at the line the reader is on, which is well-defined everywhere else.

---

## Diff engine specifics

~~**OQ-026 — Move detection in version one.**~~ **Resolved by DEC-038: it ships, for byte-identical moves only.** Which is the domain recommendation below taken at its narrowest — `innerDiff` empty **iff** the moved bytes are identical, and nothing shipped for the case where it would not be. Measured in M6-D: 120 of 120 corpus files recognise a relocation with **0 false moves**, and the rejection floor is *counted* (`movesBelowFloor`) rather than silent, because git's silent floor is the thing DEC-038 exists to avoid.

Two things this entry did not anticipate. The first `moved` label came from reconciliation and **claimed a move while seeing one side only**, so it could not check the condition DEC-038 names; it is gone, replaced by a deliberate search. And moved-and-modified content presents as delete plus add — accepted in DEC-038, recorded as a known weakness rather than hidden.

~~**OQ-052 — Position coordinate system is a stack-level disqualifier.**~~ **Resolved by DEC-042 and DEC-044**, and it did the job this entry was raised to do: it **disqualified a stack**. Swift's tree-sitter binding is byte-native, which is most of why DEC-042 chose a Swift core over a full-web architecture whose UTF-16 conversion surface would have been permanent and whose failure mode is silent. DEC-044 then confined the one conversion that remains to **one function on the Swift side**, independently tested — `21-…` §7 still lists it as the single place X-1's hazard survives, which is the honest status for a hazard that is contained rather than eliminated.
**[Fact]** Both JavaScript bindings for tree-sitter report **UTF-16 code units while their type definitions describe them as bytes**: `node-tree-sitter` computes `ts_node_start_byte(node) / 2`, `web-tree-sitter` uses `byte_to_code_unit(byte) { return byte >> 1 }` with `TSInputEncodingUTF16LE`. The C, Rust, and **Swift** bindings are genuinely byte-native.

On a corpus that is 51% non-ASCII, this produces **silent** partition corruption rather than a loud error — exactly the failure shape DEC-024 exists to prevent. TypeScript and oxc-in-Node also report UTF-16.

This is not merely a parser criterion; it constrains the **stack** decision (OQ-033), because the same parser is safe or unsafe depending on which binding a stack forces. Any candidate reporting UTF-16 needs a conversion layer that is itself a correctness risk and must be independently tested (spike P-4).

~~**OQ-049 — How to obtain cleaned bytes read-only.**~~ **Resolved by DEC-028.** Filtered files fall back to raw with disclosure. Executing repository-configured filter commands was rejected on security grounds — repository content would choose what executes.

~~**OQ-027 — Repeated identical nodes.**~~ **Resolved by DEC-031.** Ambiguous matches surfaced as reduced confidence, never resolved arbitrarily. GumTree's top-down phase already computes the `unique()`/`ambiguous()` partition and discards it; no existing tool exposes it. Five-level contextual tie-break deferred. Original framing retained below for context.

**OQ-027 (original framing) — Repeated identical nodes.** Status: Superseded.
Multiple near-identical JSX siblings make matching genuinely ambiguous. Domain research found that **76% of commits contain at least one instance** (TOSEM 2024), and JSX makes it worse — so this is the common case, not an edge case. Policy needed: ambiguity must lower confidence and trigger visible degradation rather than produce an arbitrary confident pairing. Candidate tie-breakers from the literature: identity of neighbouring siblings, then ancestor edit distance at increasing depth. Ordering must be deterministic and documented (see T-7).

~~**OQ-028 — Invalid, incomplete, or conflicted source.**~~ **Both halves built, and the spike was run.** Merge-conflict markers are detected in `SyntaxPartition` and mapped to **F2** — no usable tree for the whole file — rather than being parsed into nonsense. Half-typed source is covered by tree-sitter's error recovery, whose quality was the spike: **~38.4% of bytes fall outside `ERROR` regions on truncated files**, accepted as a quality ceiling and recorded as such, with `parseErrorRegions` reporting F1 with region and byte counts so a partial parse is stated rather than inferred. The spike is also what disqualified two alternatives: oxc returns an **empty program** for 94.77% of truncated TSX while appearing to succeed, and Babel throws on 91.67%.

**OQ-029 — Large, generated, minified, and binary files.** Status: **Three of four answered; `generated` is the one still open.**
**Thresholds and detection are DEC-050 and DEC-051**, both measured in M8-A: 2 MB before parsing, 30,000 nodes before matching, 10,000,000 counted comparisons during it, with the gate on **node count rather than bytes** because a 200 KB minified file and a 200 KB hand-written one buy wildly different amounts of work. Binary is F9, and every breach states its reason in the interface — the "visibly, never silently" this entry asked for.

**What is not decided is what `generated` should mean**, and `FixtureCatalog` records that gap by name rather than by omission: `generated-file` is a P0 case listed as *not proven — OQ-029 is open*, because a fixture would freeze an answer nobody has chosen. **Closing this entry means answering that, and the catalog will stop reporting a gap when it is answered.**

**OQ-030 — File-level matching: renames, moves, deletions, untracked files.** Status: **Partly answered by what ships.**
Git's own rename detection is consumed: `ChangedFile` carries `originalPath` beside `path`, `ChangeKind` has `renamed` (rendered `→`), and added, deleted, untracked, type-changed and unmerged are all distinguished. **Still open, and unchanged by that:** how much to trust the detection — a rename is a similarity heuristic, and nothing in this product yet says what it would show if git called two unrelated files a rename.

~~**OQ-031 — Performance budgets.**~~ **Answered — `16-performance-and-scaling.md` §3 is the table, and it is measurement rather than estimate.** Every number this entry asked for exists against the real population: the launch sweep (326 ms sequential across 21 repositories, parallel in practice), scope switching and the Git floor (§1.1), and rendering. **Both original estimates were replaced by measurement and both were wrong** (M8-A): matching cost is roughly **quadratic** in node count rather than linear, and the budget had to be **counted work** rather than elapsed time, because a wall-clock deadline makes the diff depend on machine load. Composition of the unified layout was the last unmeasured piece and is now in §3 too (M9-D).

**OQ-032 — Caching strategy.** Status: **Specified, never decided.** `16-…` §6 says what it would be — keyed by the **pinned content-hash pair**, which makes invalidation exact rather than heuristic, with parse results, per-repository status and merge-base as the candidates, and an explicit rule that the cache may never be the reason a diff shows old content. **None of it is built, and no decision entry exists.** OQ-031 no longer blocks it; what blocks it is that nothing has been slow enough to need it.

---

## Technical and delivery

~~**OQ-033 — The entire technology stack.**~~ **Resolved by DEC-042: Swift shell and engine, tree-sitter via the C API, CodeMirror 6 in a `WKWebView`, Git CLI.** Every component this entry listed was chosen against measurement, and M0 existed specifically so that measurement could *invalidate* the choice before anything was built on it. The rejected candidates and their reasons are in `21-…` §5 — the interesting ones being rejections on **silent** failure modes rather than on performance: oxc returning an empty program for 94.77% of truncated TSX while appearing to succeed, and a full-web architecture whose UTF-16 conversion surface would fail without saying so.

**OQ-034 — Distribution and updating.** Status: Open, and **deliberately left open** — see `21-agent-handoff.md` §0. App Store versus outside distribution; code signing and notarization; whether an update mechanism is needed. Depends partly on OQ-002.

What exists is a **tester build, not a distribution**: `Scripts/package.sh` produces an **unsigned** `DiffScope.app` with a zip and a SHA-256, and `25-tester-packet.md` goes with it. It proves independence rather than assuming it — the bundle is copied to a temporary directory and the full selftest is run from `/`, so a build that quietly read from the checkout fails there rather than on someone else's machine. None of that answers signing, notarization or updating.

**OQ-035 — Sandboxing.** Status: Open, and **deliberately left open** — see `21-agent-handoff.md` §0. **Difficulty raised by DEC-037**, and raised again by DEC-053: the built-in terminal spawns interactive shells, which is a larger sandbox surface than the Git subprocess `17-…` §3 weighs. Nothing forces the question while distribution is undecided (OQ-034), and §3 explains why it can stay open without blocking version one.
A tool that reads arbitrary directories and launches an external editor has real tension with the App Sandbox. Interacts with OQ-034.

DEC-037 makes this materially harder: with multiple user-chosen roots *plus* individually added repositories anywhere, a sandboxed application must obtain user-granted access **per location** and persist it across launches via security-scoped bookmarks — including handling revocation and stale bookmarks. One root would have meant one grant. This is now a first-order input to the sandboxing decision rather than a detail.

~~**OQ-036 — Licensing of candidate dependencies.**~~ **Answered — `17-security-privacy-and-licensing.md` §4 is the register**, and every shipped dependency is MIT: tree-sitter and its TypeScript grammar, CodeMirror 6, xterm.js 6.0.0 and its fit addon. The entry's own warning was the one that mattered: adopting a strongly copyleft engine would have quietly foreclosed distribution, and **GumTree is LGPL-3.0** — so its algorithms were implemented from the publications and no source was ported (DEC-030), on the ground that algorithms are not copyrightable and implementations are. What remains under §4.3 is a **maintenance** risk rather than a licensing one: the grammar's last release was 2024-11-11, and MIT keeps forking available as the mitigation.

~~**OQ-037 — Test infrastructure.**~~ **Answered by what exists: `diffscope-verify`**, headless, exit 1 on failure, **1598 checks over 55 fixtures**. Both approaches this entry named are in it. *Invariant-based*: T-0 … T-11 apply to **every** fixture automatically, on both the raw and structural paths, with no per-case expectation file. *Property-based*: the canonical diff is checked for minimality against a dynamic-programming LCS reference over 600 randomly generated pairs.

Three habits are worth more than the count, and each was paid for: **T-1 and T-3 are implemented independently of the partition code**, because X-1 found a defect that passes T-0 and T-1 and fails only T-3; **R-8 is a snapshot of `.git` before and after every Git operation**, so a new Git call without a proof fails the run; and **fixture bytes are verified against recorded hashes**, because editors silently repair CRLF and NFD.

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
