# Research — Git Access Mechanism and File Watching on macOS

**Status:** Complete for the two sections it covers. Written 2026-07-26.
**Scope:** This document supplies **§4 (Git access mechanism, blocks OQ-010)** and **§5 (file watching, blocks OQ-039 and the DEC-007 debounce value)** of `git-integration-and-watching.md`, which marked both as NOT RESEARCHED. That file's §1–§3 (read-only audit, filter measurement, scope answers) are **not repeated here** and are treated as established. This document references them rather than restating them.

**Method.** Two evidence classes are used and are labelled throughout:

- **[MEASURED]** — observed on this machine (macOS 26.5.2, arm64, git 2.50.1 Apple Git-155, Swift 6.2.4). Working code retained under the session scratchpad (`watch/fsev.swift`, `watch/kq.swift`, `watch/run{1..6}.sh`, `watch/filterdir{,2}.sh`, `watch/perf.sh`).
- **[SOURCE]** — primary documentation or upstream source, URL given.
- **[INTERPRETATION]** — my reading, explicitly not a fact.

**Safety.** No repository under `~/WebstormProjects` was modified. All inspection of real repositories used read-only subcommands with `--no-optional-locks`, plus `find`/`stat`/`open(O_EVTONLY)`. Every test requiring writes ran in throwaway repositories under the scratchpad.

**Two things I could not do, stated up front:**

1. **libgit2 was not installed and installing was out of scope.** Nothing in Section A about libgit2's *runtime* behaviour is measured. It is derived from libgit2's own headers, generated API docs, and source on GitHub, and is labelled accordingly. Several claims below are marked **UNVERIFIED — spike required**. This is the single biggest gap in this document and Spike A1 exists to close it.
2. **I did not drive a real WebStorm save.** Section B measures a faithful reproduction of the IntelliJ "safe write" syscall sequence, whose steps are documented by JetBrains support and by the temp-file names it leaves behind. Verifying against the real editor is Spike B1 and is cheap.

---

# Section A — Git access mechanism (OQ-010)

## A.1 The question underneath the question

DEC-013 makes Raw mode the **control view**: its purpose is to let the user check a structural claim against plain Git output. DEC-025 then requires the Git layer to produce *the byte pair `git diff` itself would use*. Together these make "does the mechanism agree with Git?" not a nice-to-have but the product's central trust claim.

That reframes OQ-010. The interesting axis is not speed — Section A.7 shows speed is a non-issue at this corpus size — it is **how many places the mechanism can silently disagree with `git diff`**, and whether those places are detectable.

## A.2 Filter handling — the decisive finding, and a correction to DEC-025

### A.2.1 Git normalises the *worktree* side, not the ODB side [MEASURED]

`git-integration-and-watching.md` §2.1 recommends "filters applied consistently to both sides" without fixing the direction. The direction is measurable and it matters, because only one of the two directions is obtainable read-only.

Scratch repo: ODB holds `alpha\nbeta\n` (LF), `.gitattributes` says `*.txt text eol=crlf`, worktree holds `alpha\r\nbeta\r\n` (CRLF).

```
ODB oid                                    fbbee861521bd5355538b096fa3998541cd33909
ODB bytes                                  616c7068610a626574610a          (LF)
worktree bytes                             616c7068610d0a626574610d0a      (CRLF)
git --no-optional-locks diff               0 lines                          ← no change
git hash-object --stdin --path=lf.txt      fbbee861521bd5355538b096fa3998541cd33909
git hash-object --stdin  (no --path)       17f2fc0a7500e6b218190262d5a329086ba965ff
```

The post-clean OID of the worktree bytes **equals** the ODB OID. Therefore `git diff` converts the worktree side *down* into ODB form (the **clean** direction) and compares in ODB space. It does **not** smudge the committed side up into worktree form.

Confirmed independently with a custom filter driver (`filter.demo.clean = tr a-z A-Z`, `smudge = tr A-Z a-z`):

```
ODB content                    [HELLO WORLD]
worktree content               [hello world]
git status doc.md              []           ← clean
git diff doc.md                0 lines

after a genuine edit on disk (goodbye world):
    diff --git a/doc.md b/doc.md
    -HELLO WORLD
    +GOODBYE WORLD          ← patch text is in ODB (cleaned) form, both sides
```

**Consequence for DEC-025:** the byte pair to display is **both sides in ODB form**, obtained by applying the *clean* filter to the worktree side. DEC-025's wording should be tightened from "filters applied consistently to both sides" to "**the worktree side is normalised into ODB form via the clean filter; the committed side is used raw**". As written, DEC-025 is satisfiable in two ways and one of them (smudging the ODB side) does not reproduce `git diff`.

Also note the patch text itself is in cleaned form — so a user reading Raw mode of a file under a filter is *already* not seeing their disk bytes. That is Git's behaviour, and DEC-025's disclosure requirement therefore applies to Raw mode too, not only to Structural mode.

### A.2.2 There is no read-only Git plumbing that emits the cleaned bytes [MEASURED + SOURCE]

This is a genuine hole and it is worth stating plainly.

| Command | Direction | Emits bytes? | Writes? |
|---|---|---|---|
| `git cat-file -p <rev>:<path>` | raw ODB | yes | no (audited in §1 of the prior doc) |
| `git cat-file --filters <rev>:<path>` | **smudge** (ODB → worktree) | yes | no |
| `git hash-object --stdin --path=<path>` | **clean** (worktree → ODB) | **no — OID only** | **no** [MEASURED] |
| `git hash-object -w …` | clean | no | **yes — writes a blob** |

`git cat-file --filters` documentation: "Show the content as converted by the filters configured in the current working tree for the given `<path>` (i.e. smudge filters, end-of-line conversion, etc.)" — verified in the local `git-cat-file(1)` man page, git 2.50.1. That is the wrong direction for our need.

`git hash-object` without `-w` was measured not to write: hashing `.git/objects` file list before and after produced identical digests (`bcf4f445…` → `bcf4f445…`, reported `NO WRITE`).

So the cleaned bytes are reachable only by:

- **(a)** `hash-object --path` to get the cleaned OID, then `cat-file -p <oid>` — **works only if that blob already exists in the ODB**. For an unchanged file it does; for the changed files we actually want to diff, it usually does not.
- **(b)** reimplementing the conversion ourselves — tractable for the built-in CRLF/`text`/`eol`/`working-tree-encoding` rules, impossible in general;
- **(c)** running the configured `filter.<driver>.clean` command ourselves — which means **executing a command written in a repository's configuration**. Note this is exactly what `git diff` already does (measured above: git ran my `upper.sh`), so it is not a new exposure relative to Git — but it *is* a new exposure relative to "this app only reads".
- **(d)** not producing a byte pair at all when a filter is active, and falling back to `git diff`'s own patch text with a disclosure banner.

**[INTERPRETATION]** (a) is a cheap and correct fast path for the "is this file actually changed in Git's eyes" question and should be adopted regardless. For the byte pair, (b) covers 100% of the current corpus and (d) is the honest fallback. (c) should be a deliberate, separately-decided trust decision, not something that slides in.

### A.2.3 `git status` and `git diff` disagree under an active EOL filter [MEASURED]

Same fixture as A.2.1:

```
git --no-optional-locks status --porcelain   [ M lf.txt]
git --no-optional-locks diff-files           :100644 100644 fbbee86… 0000000… M   lf.txt
git --no-optional-locks diff-index HEAD      :100644 100644 fbbee86… 0000000… M   lf.txt
git --no-optional-locks diff                 0 lines
```

Status says modified. Diff says nothing changed. This **persists after a plain, index-refreshing `git status`**, so it is not an artefact of `--no-optional-locks`.

**[INTERPRETATION]** the cause is Git's stat-based fast path: the index records size 12, the worktree file is 14 bytes, and `ce_match_stat_basic` reports `DATA_CHANGED` on a size mismatch without reading and converting content, while `git diff` does read and convert. Git even emits `warning: in the working copy of 'lf.txt', LF will be replaced by CRLF the next time Git touches it`.

**Direct product consequence.** The repository list and changed-file list come from `status`; the diff view comes from `diff`. Under an active EOL filter the app will list a file as changed and then show an empty diff. Given DEC-013 positions the tool as a trust instrument, an unexplained empty diff is a worse failure than most. The file list needs a reconciliation step — the cheapest correct one is A.2.2(a): compare `hash-object --stdin --path` against the index OID, which is read-only and settles it exactly. Raised as OQ-051.

### A.2.4 libgit2's filter handling [SOURCE, partly UNVERIFIED]

- libgit2 **does** apply filters when reading working-directory content for diff, in the same (clean) direction as Git. `src/libgit2/diff_file.c`, function `diff_file_content_load_workdir_file`, calls `git_filter_list_load(&fl, fc->repo, NULL, fc->file->path, GIT_FILTER_TO_ODB, GIT_FILTER_ALLOW_UNSAFE)` and then `git_filter_list__convert_buf(&out, fl, &raw)`. `GIT_FILTER_TO_ODB` is the clean direction. Direction parity is therefore correct by construction. [SOURCE: github.com/libgit2/libgit2 `src/libgit2/diff_file.c`]
- **But libgit2 only ships two built-in filters** — CRLF (priority 0) and IDENT (priority 100) — and does not execute `filter.<driver>.clean` / `.smudge` commands from gitconfig. External filter drivers must be re-implemented in C and registered via `git_filter_register`. The feature request (libgit2 issue #1473, opened 2013-04-17) is closed without external-command support; the library's position is that shelling out from an embedded library is architecturally undesirable. [SOURCE: libgit2 filter API docs; libgit2#1473]
- Practical fallout observed by others: git-crypt under TortoiseGit's libgit2 path fails to encrypt while its CLI path works; Git LFS is not supported natively by libgit2/pygit2. [SOURCE: TortoiseGit issue #2224; git-lfs/git-lfs#375]

**[INTERPRETATION]** this is the sharpest correctness difference between the two mechanisms, and it fails in the worst possible direction for this product: with an external filter configured, libgit2 would silently compare *un-cleaned* worktree bytes against ODB bytes and report a whole-file change that `git diff` does not report — precisely the DEC-025 failure mode, reintroduced by the choice of mechanism. Current corpus exposure is zero (prior doc §2.2: 0 of 21 repos have any filter active, no `.gitattributes` text/eol directives, no git-lfs installed on this machine — verified: `which git-lfs` → not found). The hazard is latent, as before.

**UNVERIFIED — spike required:** that libgit2's *built-in CRLF* filter produces byte-identical results to Git's for the `text`, `eol`, `core.autocrlf`, `core.eol` and `working-tree-encoding` matrix. I have no measurement of this.

## A.3 Write side effects

| Operation | Git CLI | libgit2 |
|---|---|---|
| status, stat cache stale | rewrites `.git/index` unless `--no-optional-locks` — **[MEASURED, prior doc §1.2]** | `GIT_STATUS_OPT_UPDATE_INDEX` → `GIT_DIFF_UPDATE_INDEX`: "When diff finds a file in the working directory with stat information different from the index, but the OID ends up being the same, **write the correct stat information into the index**." Opt-in, not default. [SOURCE: libgit2 `git_diff_option_t` docs] |
| index reload | n/a | `GIT_STATUS_OPT_NO_REFRESH` — "Bypasses the default status behavior of doing a 'soft' index reload (i.e. reloading the index data if the file on disk has been modified outside libgit2)." Default is *reload from disk* (a read). [SOURCE: `include/git2/status.h`] |
| diff, cat-file, merge-base, rev-list, for-each-ref, ls-tree, symbolic-ref, check-attr | no writes — **[MEASURED, prior doc §1.1]** | no equivalent audit exists |
| `hash-object` without `-w` | no write — **[MEASURED]** | n/a |
| auto-maintenance | see A.3.1 | libgit2 has no auto-gc |

**Reading of the libgit2 side:** the flags are structured so that a read-only configuration is *expressible* — do not set `UPDATE_INDEX`, and the mutual-exclusion check in `src/libgit2/status.c` confirms the two are alternatives:

```c
if ((opts->flags & GIT_STATUS_OPT_NO_REFRESH) != 0 &&
    (opts->flags & GIT_STATUS_OPT_UPDATE_INDEX) != 0) {
    git_error_set(GIT_ERROR_INVALID, "updating index from status "
        "is not allowed when index refresh is disabled");
```

**[INTERPRETATION]** libgit2 is *probably* read-only by default for our operations, and its opt-in model is arguably safer than Git's, where the write is the default and must be suppressed on every invocation. But "probably" is doing real work in that sentence. DEC-003 is an absolute constraint and the CLI's compliance is measured while libgit2's is inferred from flag documentation. **The asymmetry of evidence is currently the strongest argument in the comparison, and it is an artefact of what has been tested — not a property of the libraries.** Spike A1 exists to remove it.

### A.3.1 Auto-maintenance — partial evidence for OQ-046 [MEASURED]

Watching a scratch repository's `.git` with FSEvents during git operations (Section B fixture), `git commit` produced an event on `.git/objects/maintenance.lock`. **No read-only command in the audit produced one.** That is consistent with maintenance being triggered by write commands, not reads.

This does not close OQ-046 — the observation is on a tiny repository, and the prior doc's caveat about auto-gc thresholds still applies. But it does give a **cheap, non-invasive way to close it**: run the app's full read-only command set against the real 1.5 GB repository with an FSEvents watcher on its `.git`, and check for any `maintenance.lock`, `gc.log`, `*.pack` or `objects/` event. Watching is purely observational, so this test is safe against real repositories. Folded into Spike A3.

## A.4 Correctness parity, item by item

| Concern | Git CLI | libgit2 | Confidence |
|---|---|---|---|
| **`git diff` byte-exact agreement** | tautologically yes | see A.6 | — |
| **Clean-filter direction** | clean the worktree side [MEASURED] | same (`GIT_FILTER_TO_ODB`) [SOURCE] | high |
| **External filter drivers** | executed [MEASURED] | **not supported** [SOURCE] | high |
| **`working-tree-encoding`** | supported | unverified | low |
| **Rename detection** | `diff.renames` defaults to true, but **"affects only git diff Porcelain … not lower level commands such as git-diff-files"** [SOURCE: local `git-config(1)`, git 2.50.1] | not automatic; `git_diff_find_similar` is a separate call that "modifies a diff in place, replacing old entries that look like renames or copies" [SOURCE] | high |
| **merge-base** | `git merge-base` [MEASURED no-write, prior doc §3] | `git_merge_base` / `git_merge_bases` exist; equivalence to Git's best-common-ancestor choice on criss-cross merges unverified | low |
| **`.gitignore` semantics** | reference implementation | `git_ignore_path_is_ignored` exists; historical divergence reports on negation and directory patterns | low |
| **Binary detection** | `diff.<driver>.binary`, attribute `binary`, NUL scan | `diff_file_content_binary_by_size` short-circuits before filtering unless `GIT_DIFF_SHOW_BINARY` [SOURCE] | medium |
| **Worktrees** | native | `git_worktree_*` API exists | medium |
| **Submodules** | native | `git_submodule_*` API exists; `GIT_STATUS_OPT_EXCLUDE_SUBMODULES` | medium |
| **`textconv` diff drivers** | executed | no external-command execution ⇒ not supported | high |
| **Index extensions** (untracked cache, fsmonitor) | consumed | unverified | low |

**The rename-detection row is a trap worth calling out.** If the implementation reaches for plumbing (`diff-files`, `diff-index`) because plumbing is stabler to parse, it gets **no rename detection at all** unless `-M` is passed explicitly — while the `git diff` a user runs in a terminal to check the app *does* detect renames. That is a Raw-mode disagreement caused purely by choosing plumbing over porcelain, on the CLI path, with no libgit2 involved. Raised as OQ-052.

## A.5 Getting the exact blob bytes per scope

| DEC-008 scope | Old side | New side |
|---|---|---|
| 1. all local vs HEAD | `cat-file -p HEAD:<path>` (raw ODB) | worktree bytes, **cleaned** (A.2.2) |
| 2. unstaged vs index | `cat-file -p :<path>` (stage 0 blob) | worktree bytes, **cleaned** |
| 3. staged vs HEAD | `cat-file -p HEAD:<path>` | `cat-file -p :<path>` — both raw ODB, **no filter problem at all** |
| 4. branch vs merge-base | `cat-file -p $(merge-base …):<path>` | `cat-file -p HEAD:<path>` — both raw ODB, **no filter problem** |

**[INTERPRETATION]** scopes 3 and 4 are entirely ODB-to-ODB and are immune to the whole filter question. Only scopes 1 and 2 touch the worktree. If the filter work in A.2.2 turns out to be expensive or contentious, scopes 3 and 4 are unaffected and can ship independently — which is a useful sequencing fact for planning.

`:<path>` (index blob) and `<rev>:<path>` both resolve through `cat-file`, already audited as non-writing.

## A.6 Raw mode: can Git's own textual diff be obtained?

**Git CLI:** trivially — it *is* the output. This is not a small advantage. Raw mode's stated job (DEC-013) is agreeing with `git diff`; the CLI path makes agreement structural rather than something to be maintained.

**libgit2:** produces patch text via `git_patch_to_buf` / `git_diff_print`. **Byte-for-byte identity with `git diff` is UNVERIFIED and I would not assume it.** Known risk areas, each of which would show up as a visible Raw-mode difference:

- abbreviated OID length on the `index abc1234..def5678` line;
- default context lines and hunk-header function-context detection;
- rename/copy detection being off unless `git_diff_find_similar` is called with matching thresholds;
- `diff.algorithm`: libgit2 documents `GIT_DIFF_PATIENCE` and `GIT_DIFF_MINIMAL`; I found **no histogram option**. Git's default is Myers, so the default case matches, but a user with `diff.algorithm=histogram` in `~/.gitconfig` would get a different hunk decomposition from `git diff` than from libgit2 — and would not be told why;
- `diff.noprefix`, `diff.mnemonicPrefix`, `diff.external`, `textconv`;
- trailing `\ No newline at end of file` and whitespace-error conventions.

**[INTERPRETATION]** if libgit2 were chosen, Raw mode would most defensibly still shell out to `git diff` — one subprocess, only when Raw mode is on screen. That is a perfectly reasonable hybrid and it costs ~50 ms (A.7). But it means the "no subprocess" argument for libgit2 does not actually hold for this product, which materially weakens the case for the dependency.

## A.7 Performance [MEASURED]

Timing harness overhead matters here; an early run using a `python3` subprocess per timing inflated everything by ~18 ms. Corrected numbers, mean of 10–20 runs in-process:

```
/usr/bin/true                                             1.4 ms
git --version                                             6.2 ms
git --no-optional-locks -C mailingi-2025 rev-parse HEAD    6.0 ms
git --no-optional-locks -C mailingi-2025 status --porcelain 44.2 ms
```

**Process-spawn floor for git is ≈ 6 ms**, of which ~1.4 ms is `fork`/`exec` and ~4.6 ms is git's own startup (config discovery and parsing).

Per-repository, warm cache, `--no-optional-locks` throughout (includes ~6 ms spawn each):

| Repository | `.git` | worktree files | status | diff HEAD | diff --cached | ls-files | for-each-ref | cat-file --batch ×200 |
|---|---|---|---|---|---|---|---|---|
| mailingi-2025 | 1.5 GB | 24,267 | 99 / 66 ms | 52 | 36 | 25 | 29 | 151 |
| they__they-digital__nextjs | 724 MB | 40,064 | 43 / 30 | 51 | 57 | 43 | 41 | 89 |
| js-gloves__website__nextjs | — | 77,789 | 65 / 59 | 46 | 29 | 25 | 32 | 146 |
| orzi-kurs | — | 50,464 | 62 / 53 | 29 | 26 | 26 | 29 | 43 |
| carrefour-inapp | 204 KB | 24 | 28 / 25 | 24 | 25 | 24 | 24 | 28 |

(status shown as first-run / second-run. These figures carry the ~18 ms harness overhead; subtract it for the true cost — e.g. the 1.5 GB repo's status is 44 ms, matching the corrected measurement above.)

**Reading of this:**

- The 1.5 GB repository is **not** a performance problem. It is not even the slowest on most operations. This confirms the prior doc's correction that cost tracks working-tree file count, not history size.
- **Spawn overhead is the dominant cost for small operations.** `rev-parse HEAD` is ~6 ms of which ~6 ms is startup. A design that issues 8 separate git calls per repository across 21 repositories pays ~1 s in process startup alone.
- **[INTERPRETATION]** the mitigation is batching, not a different library: `cat-file --batch` over a persistent pipe amortises startup across many blob reads (measured 200 blobs in 43–151 ms *including* spawn), and `--porcelain=v2 --branch` folds branch, ahead/behind and file status into one invocation. With those two, the CLI's spawn overhead stops mattering at this corpus size. libgit2 would remove ~6 ms per call; at 21 repositories refreshed on focus that is worth roughly 100–200 ms once, against a dependency with the correctness and licensing surface described above.

## A.8 Licence — libgit2, treated exactly

DEC-020 leaves distribution undecided and OQ-002 records that adopting a strongly copyleft engine would quietly foreclose commercial or public distribution. So this needs to be precise.

**The core licence** is GPL v2 **with a linking exception**. The exception text: the authors "give you unlimited permission to link the compiled version of this library into combinations with other programs, and to distribute those combinations without any restriction coming from the use of this file." [SOURCE: github.com/libgit2/libgit2 `COPYING`]

What that means, carefully:

1. **Linking a proprietary or differently-licensed application against unmodified libgit2 does not make that application GPL.** Static and dynamic linking are both covered — the exception speaks of "the compiled version of this library into combinations with other programs" without distinguishing.
2. **Modifications to libgit2 itself remain GPL v2.** If we patch libgit2 — and note that A.2.4 says implementing external filter drivers would mean exactly that, or at minimum registering custom filters, which may or may not count depending on how it is done — those changes are GPL v2 and must be distributable as source. Registering a filter through the public `git_filter_register` API is use, not modification; patching `src/libgit2/filter.c` is modification.
3. **GPL v2 only.** The project states v2 specifically, not v2.2, not v3.x, not "or later". [SOURCE: `COPYING`]
4. **Dependencies carry their own licences** and travel with a static build: zlib, PCRE2 (BSD), SHA1DC (MIT), llhttp (MIT), ntlmclient (MIT), **winhttp definitions (LGPL v2.1 — Windows only, irrelevant here)**, RFC 6234 SHA-256 (BSD-style), Unicode data, sheredom/utf8.h (public domain). `examples/` is CC0 and is not linked in. GitHub's licence detector reports libgit2 as `NOASSERTION` because of the exception, which is a good reminder that automated licence scanners in a future CI or app-store pipeline will flag it and require a human explanation.
5. **Attribution obligations remain.** Distributing a binary linked against libgit2 still requires conveying the licence and copyright notice. For a macOS app that means a licences/acknowledgements surface.

**Bindings sit on top of that and add their own layer:** SwiftGit2 (MIT), nodegit (MIT), git2-rs (Apache-2.0/MIT), objective-git (MIT), LibGit2Sharp (MIT). **A permissive binding does not soften the underlying libgit2 terms** — the GPL-with-exception applies to the C library actually being linked.

**Contrast — the Git CLI:** git is GPL v2 (no linking exception), but invoking a separate program as a subprocess is not linking and does not create a derivative work. The app would depend on git being present on the system (it is: Apple ships it, and Command Line Tools are already installed here). **[INTERPRETATION]** this is the cleaner licensing position for an undecided-distribution product by a clear margin, with one real caveat: relying on the *user's* git introduces version skew — behaviour could differ across git versions, and Apple Git lags upstream. A version floor check at launch handles that.

## A.9 Binding availability and maintenance [MEASURED via GitHub/npm/crates.io APIs, 2026-07-26]

| Binding | Language | Licence | Last push | Latest release | Reading |
|---|---|---|---|---|---|
| **libgit2** (C) | C | GPL2+exception | 2026-07-26 | v1.9.6, 2026-07-18 | Actively maintained. 10.5k stars. |
| **git2-rs** | Rust | Apache-2.0/MIT | 2026-07-25 | git2 0.21.0 (2026-05-18); libgit2-sys 0.18.7+**1.9.6** (2026-07-22) | Healthiest binding by a distance. Tracks upstream within days. **But: no Rust in this project.** |
| **nodegit** | Node | MIT | 2026-07-16 | **stable 0.27.0 is from 2020-07-28**; only prereleases since (0.28.0-alpha.38, 2026-04-23) | Six years without a stable release. Native module → node-gyp, prebuilds, arm64 and Electron ABI rebuild pain. |
| **SwiftGit2** | Swift | MIT | 2025-11-24 | **0.6.0, 2019-05-24** | Seven years without a release; commits continue. Would mean vendoring from a git ref. |
| **objective-git** | ObjC | MIT | **2023-09-17** | 0.14.2, 2018-10-27 | Effectively dormant. |
| **LibGit2Sharp** | C# | MIT | 2026-07-23 | 0.32.0, 2026-07-23 | Healthy — but .NET is not a candidate stack here. |

**API stability of libgit2 itself:** v1.9 is stated to be the **final release of the v1.x line**; v2.0 will carry API *and ABI* breaking changes to support SHA-256. Upstream's own position is that they "cannot promise a completely stable API" because they must track behaviour changes in git. [SOURCE: libgit2 releases and issue #4960]

**[INTERPRETATION]** cross-referencing this table against the stack constraints (Swift 6.2.4 CLT without full Xcode, Node 22, no Rust) is uncomfortable. The two healthy bindings are for languages this project has ruled out or has no other reason to adopt. **The binding available to the most likely native stack (Swift) has not cut a release since 2019.** For a product whose entire premise is trusting the diff, depending on an unreleased binding to a library whose next major version breaks ABI is a meaningful risk that has nothing to do with libgit2's own quality. Note also that this cuts across OQ-010 and the stack decision — if a stack is chosen first, it may effectively decide OQ-010 by elimination, and that ordering should be deliberate rather than accidental.

## A.10 Language-native implementations

- **JavaScript: `isomorphic-git`** — pure JS, MIT. Designed for browsers and for repos without a local git. It reimplements diff and does not aim at byte-exact `git diff` parity; filter-driver support is absent. Not surveyed in depth because the parity bar here rules it out early. **[INTERPRETATION]** any pure reimplementation is the *worst* fit for this specific product, because Raw mode's whole value is being able to say "this is what Git says", and a reimplementation makes that a claim to be defended rather than a fact.
- **Go: go-git** — MIT, mature, but no Go in this project.
- **Swift: no maintained pure-Swift Git implementation found.**
- **Reading `.git` directly for cheap facts** is a legitimate partial strategy and is already in use: the prior doc measured reading all 21 branch names straight from `.git/HEAD` at 52 ms total, versus ~6 ms *per repo* for `rev-parse`. Loose-ref/packed-ref parsing is simple and read-only. **[INTERPRETATION]** worth keeping as an optimisation for the repository-list sweep specifically (DEC-006), independent of how diffs are computed. It must never be the source of truth for a diff.

## A.11 Edge cases in this population

### A.11.1 `carrefour-inapp` is **not** on detached HEAD — it has no commits at all [MEASURED]

OQ-008 and the prior doc both describe `carrefour-inapp` as being on detached HEAD. Measured today:

```
git --no-optional-locks -C carrefour-inapp symbolic-ref -q HEAD   → refs/heads/main   (rc=0)
.git/HEAD                                                          → ref: refs/heads/main
git --no-optional-locks -C carrefour-inapp branch --list           → (empty)
git --no-optional-locks -C carrefour-inapp for-each-ref            → (empty)
git --no-optional-locks -C carrefour-inapp rev-parse HEAD          → fatal: ambiguous argument 'HEAD' (rc=128)
git --no-optional-locks -C carrefour-inapp rev-list --count HEAD   → fatal (rc=128)
git --no-optional-locks -C carrefour-inapp status --porcelain      → ?? .gitignore, ?? README.md, ?? config/, …
ls .git                                                            → HEAD config description hooks info objects refs
```

This is an **unborn HEAD**: `git init` with zero commits, zero refs, no remote. Either the earlier characterisation was wrong or the repository changed; either way the docs are now inaccurate and OQ-008 needs restating.

**Why this is a harder case than detached HEAD, not an easier one:**

- `symbolic-ref -q HEAD` **succeeds and returns a branch name that does not exist.** The obvious detection idiom (`symbolic-ref` exit code) reports "on branch main" and is wrong. Detecting unbornness requires additionally checking that the ref resolves — e.g. `rev-parse --verify HEAD` exit code, or `for-each-ref` being empty.
- **All four DEC-008 scopes are undefined.** There is no HEAD tree, no index worth comparing (everything is untracked), no base branch, no merge-base. DEC-012's "explicit unknown state" requirement applies to all of them, not just the ahead-count.
- Every `HEAD`-referencing command exits **128 with a message on stderr**. Any code path that treats non-zero git exit as "error, show a failure state" will show 21 repositories fine and one broken one.

**No repository in the population is currently on detached HEAD.** All others resolve to a branch (`dev/fo`, `master`, `feat/hide-food-pictogram-pvc-variant`, `main`, …). Detached HEAD remains worth handling but the *tested-against-reality* case is unborn HEAD. Raised as OQ-050.

libgit2 has `GIT_EUNBORNBRANCH` for this and arguably models it better than the CLI's exit-128-plus-stderr. Not verified.

### A.11.2 No remote, no main/master

`carrefour-inapp` (0 refs, 0 remotes), `js-gloves__backend__strapi` and `theymail__email_tester` are the no-`node_modules` outliers; `carrefour-inapp` is the no-remote case. Base-branch detection (DEC-011/OQ-007) has nothing to work with in the unborn repo — there are no local branches and no remote-tracking refs. Scope 4 must degrade to an explicit unavailable state rather than a zero.

## A.12 Comparison table — Section A

| Axis | Git CLI subprocess | libgit2 + binding | Pure reimplementation |
|---|---|---|---|
| Raw-mode agreement with `git diff` | **structural** (it is the output) | needs verification; realistically shell out anyway | claim to be defended |
| Read-only compliance (DEC-003) | **measured clean** with `--no-optional-locks` | inferable from flags; **unmeasured** | depends |
| External filter drivers (DEC-025) | executed, correct | **unsupported → silent whole-file false diffs** | unsupported |
| Built-in CRLF filter | correct by definition | same direction; byte parity unverified | unverified |
| Rename detection | on by default in porcelain, **off in plumbing** | off unless `git_diff_find_similar` | own semantics |
| Cleaned worktree bytes obtainable read-only | **no** (A.2.2) — gap applies to both | no | n/a, computes its own |
| Per-call overhead | ~6 ms spawn; amortisable via `--batch` | none | none |
| Big-repo perf | fine (1.5 GB repo not the slowest) | expected fine | unknown |
| Unborn HEAD | exit 128 + stderr, needs care | `GIT_EUNBORNBRANCH` | unknown |
| Licence w/ undecided distribution | **cleanest** — subprocess, not linking | GPL2 + linking exception; workable, needs care and an acknowledgements surface | varies |
| Binding health for likely stacks | n/a | **Swift binding: no release since 2019** | n/a |
| Dependency/packaging | requires git present (it is); version skew | vendored C lib, build config, ABI break at v2.0 | none |
| Failure mode when it disagrees with git | cannot, by construction | **silent** | **silent** |

## A.13 Open questions arising from Section A

- **OQ-049 — Byte source for the cleaned worktree side.** A.2.2 shows no read-only Git plumbing emits it. Choose among (a) OID-only fast path, (b) reimplement built-in conversions, (c) execute the configured clean filter, (d) disclose-and-fall-back. (c) is a trust decision, not an implementation detail.
- **OQ-050 — Unborn HEAD.** Supersedes/corrects the detached-HEAD framing in OQ-008. `carrefour-inapp` has zero commits and zero refs; `symbolic-ref` succeeds and lies. All four scopes undefined.
- **OQ-051 — status/diff disagreement under an active EOL filter.** A.2.3. The file list would show a change the diff view cannot render.
- **OQ-052 — Porcelain vs plumbing for the diff enumeration.** Plumbing is stabler to parse but silently loses rename detection (`diff.renames` is porcelain-only). Raw mode would then disagree with the user's own `git diff`.
- **OQ-053 — Git version floor.** If the CLI is used, which minimum git version is supported, and what is checked at launch. Apple Git 2.50.1 here; a user's Homebrew git may differ.

---

# Section B — File watching on macOS (OQ-039, DEC-007 debounce)

## B.1 How many events does one atomic-replace save emit? [MEASURED]

The IntelliJ "safe write" sequence (Settings → Appearance & Behavior → System Settings → *Use "safe write"*, on by default) is:

1. write new content to `<file>.___jb_tmp___`
2. rename `<file>` → `<file>.___jb_old___`
3. rename `<file>.___jb_tmp___` → `<file>`
4. delete `<file>.___jb_old___`

[SOURCE: JetBrains support — the failure message names both temp suffixes and the setting that disables the behaviour.]

Reproduced exactly against an FSEvents stream with `kFSEventStreamCreateFlagFileEvents | NoDefer`, latency 0.0:

```
2.9036 cb=2 ItemInodeMetaMod|ItemRenamed|ItemModified|ItemIsFile   …/src/app.ts
2.9036 cb=2 ItemRenamed|ItemIsFile                                 …/src/app.ts.___jb_old___
2.9036 cb=2 ItemCreated|ItemRenamed|ItemModified|ItemXattrMod|…    …/src/app.ts.___jb_tmp___
2.9036 cb=2 ItemRenamed|ItemIsFile                                 …/src/app.ts
2.9159 cb=3 ItemRemoved|ItemRenamed|ItemIsFile                     …/src/app.ts.___jb_old___
```

**Answer: one atomic-replace save produces 5 FSEvents events across 1–2 callbacks.** Over 20 repeated saves:

| Metric | Value |
|---|---|
| Events per save | 4–5 (mode 5) |
| Callbacks per save (latency 0.0, NoDefer) | 1–2 |
| Event-span per save | min 0.0 ms, **p50 11.1 ms**, p90 12.3 ms, **max 13.3 ms** |

For comparison, an ordinary in-place write (`printf > file`) produces **1 event**: `ItemInodeMetaMod|ItemModified|ItemIsFile`.

**Three properties that matter more than the count:**

1. **The target path appears twice** (steps 2 and 3), and **never carries `ItemCreated`** for the final rename-into-place. Any watcher logic keyed on "created ⇒ new file, modified ⇒ edit" mis-classifies a JetBrains save. Only path identity is reliable.
2. **Three of the five events are for `.___jb_tmp___` / `.___jb_old___` paths**, i.e. 60% of the event volume is noise. These are also files that would briefly appear as untracked in `git status` if a status ran mid-sequence.
3. **There is a window in which the target path does not exist** — measured directly on the kqueue side in B.3 (`path_exists=no`). A refresh that fired inside that window would see a deleted file.

### B.1.1 Implication for the DEC-007 400 ms debounce [MEASURED → INTERPRETATION]

The measured event span of a single save is **≈ 11 ms, worst case 13 ms**. A debounce need only exceed ~25 ms to coalesce one save reliably. **400 ms is roughly 30× the required minimum.**

That is not an argument to lower it. The dominant term is not one save — it is **bursts**: WebStorm's Save All, formatter-on-save followed by a second write, and a build tool rewriting outputs. It is also perceptual: 400 ms is below the ~1 s threshold where a UI update reads as a separate event rather than a response to your save.

**[INTERPRETATION]** the measurement supports keeping ~400 ms, and reframes what it is for. It is *not* needed to coalesce a single save (25 ms would do); it is a **quiet-period detector for bursts**. That distinction matters for the implementation: a *trailing-edge* debounce (restart the timer on every event, fire when quiet for 400 ms) is the right shape. A *leading-edge* debounce would fire on the first event of a save — which, per property 3 above, may be the moment the file does not exist.

Worth adding a **maximum-delay cap** (e.g. fire regardless after 2 s of continuous events) so that a long-running writer such as `pnpm install` does not starve the refresh indefinitely.

**Still to verify (Spike B1):** whether a real WebStorm save also writes `.idea/workspace.xml` or other project metadata in the same window, which would add events. My reproduction covers only the document save.

## B.2 FSEvents semantics [SOURCE: local SDK header, primary]

All quotes from `/Library/Developer/CommandLineTools/SDKs/MacOSX26.2.sdk/…/FSEvents.framework/Headers/FSEvents.h`.

**Latency and `NoDefer`** — this is the single most important paragraph for DEC-007:

> "Affects the meaning of the latency parameter. If you specify this flag and more than latency seconds have elapsed since the last event, your app will receive the event immediately. The delivery of the event resets the latency timer and any further events will be delivered after latency seconds have elapsed. This flag is useful for apps that are interactive and want to react immediately to changes but avoid getting swamped by notifications when changes are occurring in rapid succession. If you do not specify this flag, then when an event occurs after a period of no events, the latency timer is started. Any events that occur during the next latency seconds will be delivered as one group (including that first event). … This is the default behavior and is more appropriate for background, daemon or batch processing apps."

Apple's own overview names our exact case as the motivation for latency:

> "Clients can supply a 'latency' parameter that tells how long to wait after an event occurs before forwarding it; this reduces the volume of events and reduces the chance that the client will see an 'intermediate' state, like those that arise when doing a **'safe save' of a file**, creating a package, or downloading a file via Safari."

**Measured consequence of that asymmetry:**

| Configuration | One safe-write save delivers as |
|---|---|
| latency 0.0, `NoDefer` on | 1–2 callbacks, first arrives immediately |
| latency 0.4, `NoDefer` on | **2 callbacks separated by exactly 0.4 s** — first 4 events immediately, the `___jb_old___` removal 400 ms later |
| latency 0.4, `NoDefer` **off** | **1 callback**, all events grouped, delivered ~0.4 s after the save |

**[INTERPRETATION]** `NoDefer` with a non-zero latency is the worst of both worlds here: it splits one logical save across two callbacks separated by the full latency, which an application-level debounce then has to re-merge anyway. Two coherent configurations exist: **(i)** latency 0.0 + `NoDefer` + a 400 ms trailing debounce in the app — maximum control, and the debounce is visible in our own code where it can be tuned and tested; or **(ii)** latency 0.4 + `NoDefer` off — let FSEvents do the coalescing, less code, but the debounce becomes an opaque framework parameter and cannot express a max-delay cap.

**[INTERPRETATION]** (i) is preferable for this product because DEC-007 explicitly marks the debounce value as provisional and subject to tuning, and because the pinned-source-pair model needs the refresh trigger to be our own code path anyway.

**Delivery reliability** — the header is unusually blunt, and it should be read as a design constraint:

> "It is important to note that event flags are simply hints about the sort of operations that occurred at that path. Furthermore, the FSEvent stream should NOT be treated as a form of historical log that could somehow be replayed to arrive at the current state of the file system. The FSEvent stream simply indicates what paths changed; and clients need to reconcile what is really in the file system with their internal data model — and recognize that what is actually in the file system can change immediately after you check it."

**Dropped events:**

> `kFSEventStreamEventFlagMustScanSubDirs` — "Your application must rescan not just the directory given in the event, but all its children, recursively. This can happen if there was a problem whereby events were coalesced hierarchically. … If this flag is set you may be able to get an idea of whether the bottleneck happened in the kernel (less likely) or in your client (more likely) by checking for the presence of the informational flags kFSEventStreamEventFlagUserDropped or kFSEventStreamEventFlagKernelDropped."

**Volume boundaries:** `kFSEventStreamEventFlagMount` / `Unmount` are delivered when a volume is mounted or unmounted under a watched path; the header warns "a newly-mounted volume could contain an arbitrarily large directory hierarchy. Avoid pitfalls like triggering a recursive scan of a non-local filesystem, which you can detect by checking for the absence of the `MNT_LOCAL` flag in the `f_flags` returned by `statfs()`." Not a realistic case for `~/WebstormProjects` on internal storage, but it is the documented behaviour.

**Root moved:** `kFSEventStreamCreateFlagWatchRoot` yields a `RootChanged` event (event ID zero) if the watched directory or an ancestor is renamed. The header recommends holding an open fd on the directory and using `F_GETPATH` to find its new location. Relevant to OQ-017 (configured root does not exist) and to a repository being renamed while open.

**Exclusion paths:** `FSEventStreamSetExclusionPaths()` — "Sets directories to be filtered from the EventStream. **A maximum of 8 directories maybe specified.**" Available since macOS 10.9. [SOURCE: SDK header line 1424 — verbatim, typo included.]

**`IgnoreSelf`:** suppresses events caused by our own process. Since this application never writes, it is unnecessary — but it is a useful assertion: if `IgnoreSelf` is set and behaviour is unchanged, the app genuinely is not writing into the tree.

## B.3 kqueue / DispatchSource under atomic replace [MEASURED]

`DispatchSource.makeFileSystemObjectSource` is a thin wrapper over kqueue `EVFILT_VNODE` and inherits its semantics exactly: **it watches an open file descriptor, i.e. an inode, not a path.**

Watching a single file (`O_EVTONLY`), same fixture:

```
0.5395 notes=attrib        fd_inode=26176843 nlink=1 path_exists=yes path_inode=26176843   ← in-place write
0.5404 notes=write|extend  fd_inode=26176843 nlink=1 path_exists=yes path_inode=26176843
2.0494 notes=write|extend  fd_inode=26176843 nlink=1 path_exists=yes path_inode=26176843   ← append
3.5638 notes=rename        fd_inode=26176843 nlink=1 path_exists=NO  path_inode=0          ← safe write
3.5726 notes=delete|link   fd_inode=26176843 nlink=0 path_exists=yes path_inode=26176888
(nothing further)
```

**The watch is dead after the atomic replace.** A subsequent in-place write to the file at the same path produced **no event at all** — the descriptor still refers to the old, now-unlinked inode (`nlink=0`), while the path resolves to a new inode (`26176888`).

Two further details visible in the trace:

- At the `rename` notification the target path **does not exist** (`path_exists=no`). A watcher that reacted immediately would observe a missing file.
- An in-place write produces **two** callbacks (`attrib`, then `write|extend`), so even the simple case needs coalescing.

**Conclusion:** raw kqueue/DispatchSource on files is **not usable as-is** for this product. It can be made to work — re-`open` and re-arm on every `rename`/`delete`, watch the containing directory as well so that the replacement is noticed — but that is reimplementing what FSEvents already does, with a race window at every re-arm.

## B.4 Recursive watch cost and `node_modules` [MEASURED]

Working-tree file counts across the 21 repositories (excluding `.git`):

| Repository | worktree files | of which `node_modules` | top-level `node_modules` dirs | `.git` files |
|---|---|---|---|---|
| js-gloves__website__nextjs | 77,789 | 72,958 (94%) | 1 | 6,575 |
| orzi-kurs | 50,464 | 39,712 (79%) | **3** | 1,918 |
| 5bonsai__website__nextjs | 48,913 | 47,115 (96%) | 1 | 370 |
| remington__ogoleni__next | 48,024 | 45,860 (96%) | 1 | 4,329 |
| next-tailwind-starter | 40,909 | 40,092 (98%) | 1 | 140 |
| they__they-digital__nextjs | 40,064 | 38,801 (97%) | 1 | 27 |
| polska-bezgotowkowa__website__nextjs | 39,948 | 38,190 (96%) | 1 | 8,235 |
| mailingi-2025 | 24,267 | 15,180 (63%) | 1 | 5,396 |
| … | … | … | 0–1 | … |
| carrefour-inapp | 24 | 0 | 0 | 45 |
| theymail__email_tester | 25 | 0 | 0 | 109 |

**Cost of a per-file kqueue watch on the largest tree** (`js-gloves__website__nextjs`, excluding `.git`):

```
directory walk        : 89,714 paths in 542 ms
open(O_EVTONLY) all   : 89,714 fds in 2,182 ms, 0 failures
paths excluding node_modules : 6,047   ← 93% reduction
```

System limits on this machine: `kern.maxfiles=184320`, `kern.maxfilesperproc=92160`, shell `ulimit -n` 1048576. **89,714 fds for one repository is 97% of `kern.maxfilesperproc`.** One repository fits; two would not. It also costs 2.2 s of startup before the first event can arrive.

**FSEvents costs zero file descriptors and has no enumeration step** — the stream is serviced by `fseventsd` and starts delivering immediately (measured `READY` to first event with no warm-up).

**Should `node_modules` be excluded, and can it be?**

- **Should:** yes. It is 63–98% of the file count in every monorepo, it is `.gitignore`d in all 21 repositories (verified: every repo has a `.gitignore`), and nothing in it can change a Git diff.
- **Can:** yes, three ways, and they are not equivalent:
  1. **`FSEventStreamSetExclusionPaths`, max 8 directories.** The maximum number of *top-level* `node_modules` directories in the corpus is **3** (`orzi-kurs`), so the whole population fits within the limit today with room to spare. But 8 is a hard ceiling; a deeper pnpm workspace could exceed it, and third-party watchers have hit this limit in practice (parcel-bundler/watcher#190). Needs a documented fallback.
  2. **Watch a set of paths that excludes `node_modules`** — enumerate the repository's top-level entries and watch each except `node_modules`. Robust, but misses newly created top-level directories unless the root is also watched.
  3. **Post-filter in the callback.** Always correct, costs nothing to get right, but does not avoid the kernel→daemon→app delivery cost. Measured: **40,000 file creations delivered 40,041 events across 1,384 callbacks in ~4.5 s, with zero drops.** So a `pnpm install` in a watched tree really does deliver ~40k events to our callback.

**[INTERPRETATION]** use (1) or (2) *and* (3). Exclusion at the stream level is an optimisation that can silently fail (limit exceeded, nested `node_modules` created later); the post-filter is the correctness guarantee. The 400 ms debounce already absorbs the *refresh* storm; exclusion is about not burning CPU delivering events we will discard.

**Drop behaviour at load [MEASURED]:** 40,000 rapid file creations produced **no `MustScanSubDirs`, no `UserDropped`, no `KernelDropped`**, and events arrived 1:1 with filesystem operations (40,041 events for 40 directories + 40,000 files). Encouraging, but the header is explicit that drops are possible and the app must be able to fall back to a full rescan. Handling `MustScanSubDirs` is not optional just because I could not provoke it.

## B.5 Watching `.git` internals [MEASURED]

`.git` is inside the working tree, so a recursive watch on the repository root covers it. Measured events in a scratch repository:

**Branch switch** (`git checkout feature`) — 11 events:

```
.git/index.lock       ItemCreated|ItemRenamed|ItemModified|ItemXattrMod
.git/index            ItemRenamed   (×2)
.git/logs/HEAD        ItemCreated|ItemModified|ItemXattrMod
.git/HEAD.lock        ItemCreated|ItemRenamed|ItemModified|ItemXattrMod
.git/HEAD             ItemRenamed   (×2)
.git/AUTO_MERGE.lock      ItemCreated|ItemRemoved|ItemXattrMod   (×2)
.git/packed-refs.lock     ItemCreated|ItemRemoved|ItemXattrMod   (×2)
```

**External commit** (`git add` + `git commit`) — 20 events across `.git/objects/**` (including `tmp_obj_*` staging files), `.git/index`, `.git/refs/heads/feature`, `.git/logs/HEAD`, `.git/logs/refs/heads/feature`, `.git/COMMIT_EDITMSG`, and `.git/objects/maintenance.lock`.

**Detection recipe [INTERPRETATION], derived from the above:**

| Signal | Watch | Notes |
|---|---|---|
| Branch switch / detach | `.git/HEAD` | arrives as `ItemRenamed`, never `ItemModified` — git writes `HEAD.lock` and renames. **Watching for a "modified" flag on `HEAD` would miss every branch switch.** |
| Index change (stage/unstage) | `.git/index` | same pattern: `index.lock` created, then `index` renamed. |
| External commit / ref move | `.git/refs/**`, `.git/logs/HEAD` | packed refs move to `.git/packed-refs`; **both loose and packed must be handled**, since a ref update may leave no loose file. |
| Auto-maintenance | `.git/objects/maintenance.lock`, `.git/gc.log` | see A.3.1 — the OQ-046 probe. |

**Two pitfalls in this data:**

1. **Everything in `.git` arrives as rename-into-place**, because git writes `X.lock` and renames. Watchers keyed on `ItemModified` see almost nothing; watchers keyed on path see everything.
2. **`.git` is noisy in its own right** — `.git/objects/**` fires for every loose object written, and `js-gloves__website__nextjs` and `polska-bezgotowkowa__website__nextjs` already hold 6,575 and 8,235 files under `.git`. **[INTERPRETATION]** watch `.git` selectively — `HEAD`, `index`, `refs/`, `packed-refs`, `logs/HEAD` — and filter out `.git/objects/**` and `*.lock` paths, treating a lock file's *removal* rather than its creation as the completion signal if lock-based sequencing is ever needed.

## B.6 Case-insensitive, case-preserving filesystem [MEASURED]

APFS on macOS is case-insensitive but case-preserving by default. Measured:

- File on disk: `src/Foo.TS`.
- Written through the path `src/foo.ts` (same file — the write succeeded and did not create a second file).
- **FSEvents reported the path as `…/src/Foo.TS`** — the on-disk canonical case, *not* the case the writer used.

**Why this bites specifically here.** Git is case-**sensitive**: the index stores whatever case was committed. FSEvents reports whatever case is on disk. If a file was committed as `components/Button.tsx` and later renamed on disk to `components/button.tsx`, git may still track the old name while events arrive under the new one — and a case-sensitive comparison of event path against git path silently never matches, so **the file stops auto-refreshing with no error anywhere**.

**[INTERPRETATION]** path matching between watcher events and Git paths must be **case-insensitive on macOS** (Unicode case-folded, since filenames can be non-ASCII), while Git paths themselves must be preserved verbatim for every Git invocation. Two representations, one for matching and one for use. Additionally APFS stores filenames in a normalisation-insensitive way while HFS+ normalised to NFD — so a filename containing precomposed characters (Polish `ł`, `ż`, `ó` are realistic in this user's repositories) may compare unequal byte-for-byte between the event path and the Git path. Matching should normalise (NFC) as well as case-fold. Raised as OQ-054.

## B.7 Wrappers

| Wrapper | Backend on macOS | Licence | Status | Fit |
|---|---|---|---|---|
| **FSEvents (direct)** | — | system framework | stable since 10.5 | No dependency; ~120 lines of Swift, as demonstrated. Full control of latency/NoDefer/FileEvents/exclusions. |
| **DispatchSource** | kqueue | system | stable | Broken by atomic replace (B.3) without manual re-arm. Fine for watching a handful of *single files* such as `.git/HEAD` where the app can re-arm, poor for trees. |
| **chokidar** (Node) | v4+ **no longer bundles the `fsevents` native module**; falls back to `fs.watch` (libuv) | MIT | v5.0.0, 2025-11-25; ESM-only, Node ≥ 20 | Only relevant if the stack is Node/Electron. The v4 change means the well-tested FSEvents path is no longer the default — **[INTERPRETATION]** this needs verification before relying on it, because chokidar's historical reputation for macOS correctness was built on that native module. |
| **notify** (Rust) | FSEvents by default (`macos_fsevent`); optional `macos_kqueue` | CC0-1.0 | 9.0.0-rc.4, 2026-05 | **No Rust in this project.** Documents the same editor-variance problem: "the actual events can differ a lot between file editors. Some truncate the file on save, some create a new one and replace the old one." |
| **Watchman** (Meta) | FSEvents | MIT | maintained | A separate long-running daemon with its own config and state. **[INTERPRETATION]** heavy for a single-repository watch on one machine; it solves a problem (many clients, huge monorepos, cross-machine) this product does not have. It would also be an external process the user must install. |
| **@parcel/watcher** | FSEvents, C++ N-API | MIT | maintained | Node only; already uses `FSEventStreamSetExclusionPaths` and has hit the 8-path limit in the wild (issue #190) — useful corroboration of B.4. |

**[INTERPRETATION]** if the stack is Swift, using FSEvents directly is clearly right: the wrappers exist to paper over cross-platform differences this app does not have, and the working implementation is small enough that it was written and measured during this research session. If the stack is Node/Electron, the choice is between chokidar (with its v4 backend change verified first) and `@parcel/watcher`.

## B.8 Comparison table — Section B

| Property | FSEvents | kqueue / DispatchSource | chokidar | notify (Rust) | Watchman |
|---|---|---|---|---|---|
| Recursive tree watch | native | **no** — one fd per file/dir | yes (via backend) | yes | yes |
| fds for 89,714-path tree | **0** [MEASURED] | **89,714**, 2.2 s to arm [MEASURED] | backend-dependent | 0 (FSEvents) | 0 |
| Survives atomic replace | **yes** [MEASURED] | **no — watch dies** [MEASURED] | yes | yes | yes |
| Events per JetBrains save | **5** [MEASURED] | 2 then dead [MEASURED] | ≥1 (post-processed) | varies | 1 (coalesced) |
| Built-in coalescing | latency param [MEASURED] | none | app-level | app-level | daemon-level |
| Drop signalling | `MustScanSubDirs`+`User/KernelDropped` | n/a | leaks through | leaks through | handled |
| Exclusions | **max 8 dirs** [SOURCE: SDK header] | n/a (explicit set) | glob-based | glob-based | expressive |
| Path case reported | on-disk canonical [MEASURED] | n/a (fd-based) | on-disk | on-disk | on-disk |
| Extra dependency | none | none | npm + backend | crate | **external daemon** |
| Latency to first event | immediate w/ NoDefer [MEASURED] | immediate | small | small | small |

## B.9 Recommended watcher shape [INTERPRETATION]

Not a decision, but the shape the measurements point at:

1. **FSEvents, one stream per open repository** (DEC-007 already narrows watching to the currently open repository), `kFSEventStreamCreateFlagFileEvents`, latency 0.0, `NoDefer`.
2. **Exclusion paths** for each top-level `node_modules` (≤ 3 today, limit 8), **plus** an unconditional post-filter on `/node_modules/` and `.git/objects/` in the callback.
3. **Trailing-edge debounce at 400 ms with a 2 s maximum-delay cap.** Measured floor to coalesce one save is ~25 ms; 400 ms is a burst quiet-period, not a save coalescer.
4. **Path matching case-folded and NFC-normalised**; Git paths kept verbatim for Git calls.
5. **`MustScanSubDirs` / `UserDropped` / `KernelDropped` ⇒ full re-status of the repository**, not an incremental update.
6. **`.git` handled as a second, narrower concern**: `HEAD`, `index`, `refs/**`, `packed-refs`, `logs/HEAD` — all keyed on path, none on `ItemModified`, because git renames into place.
7. **`kFSEventStreamCreateFlagWatchRoot`** so a renamed or deleted repository root is detected rather than silently going quiet (relates to OQ-017).
8. Every refresh **re-pins the content-hash pair** (DEC-007). The watcher signals "something changed"; it is never the source of *what* changed.

## B.10 Open questions arising from Section B

- **OQ-054 — Case and Unicode normalisation in path matching.** B.6. Case-folded plus NFC for matching; verbatim for Git. Affects any repository with non-ASCII filenames.
- **OQ-055 — `MustScanSubDirs` recovery path.** Could not be provoked at 40k events. The recovery behaviour still needs specifying and a deliberate test (inject the flag).
- **OQ-056 — Real WebStorm save shape.** B.1 measured a faithful reproduction, not the editor. Whether a real save adds `.idea/**` writes in the same window is unverified and slightly affects burst size (not the debounce conclusion).
- **OQ-057 — Watch lifecycle across repository switch.** DEC-007 watches only the open repository; stream teardown/creation on switch, and what happens to in-flight debounced events belonging to the previous repository, is unspecified.

---

# Recommended spikes

| # | Spike | Time box | Answers | Why it is worth the time |
|---|---|---|---|---|
| **A1** | **libgit2 read-only + parity harness.** Build libgit2 locally (scratch only). Hash every file under `.git` before/after `git_status_list_new` (default flags, and with `NO_REFRESH`), `git_diff_tree_to_workdir`, `git_diff_index_to_workdir`, `git_diff_tree_to_index`, `git_merge_base`. Then diff `git_patch_to_buf` output against `git diff` byte-for-byte on ~10 real files. | **4 h** | OQ-010's only unmeasured half; A.3 and A.6 | Currently the CLI wins the comparison largely because it is the only side that has been measured. That is not a fair basis for a decision. |
| **A2** | **EOL-filter fixture** (`fixtures/eol-filter-active/`, already planned in §4.4 of the test corpus plan): `.gitattributes` with `text eol=crlf`, `core.autocrlf`, `working-tree-encoding`, and one external `filter.*.clean/smudge` driver. Assert `git diff`, `git status`, `hash-object --path` agreement, and record the status/diff disagreement of A.2.3 as an expected-behaviour test. | **2 h** | OQ-047, OQ-049, OQ-051, DEC-025 | The hazard is invisible against the current corpus (0/21 exposed). Without a fixture it will be found by a user, not by us. |
| **A3** | **Auto-maintenance probe on the real 1.5 GB repository.** Attach an FSEvents watcher to `mailingi-2025/.git` (observation only, no writes) and run the app's entire read-only command set. Flag any `maintenance.lock`, `gc.log`, `*.pack`, or `objects/` event. | **1 h** | **OQ-046** | Closes an open question against the repository where auto-gc thresholds actually could be met, and is completely safe because watching writes nothing. |
| **A4** | **Unborn-HEAD and no-remote behaviour matrix.** Against `carrefour-inapp` (read-only) plus scratch fixtures for detached HEAD and a repo with a remote but no local base branch: record exact exit codes and stderr for every command in the app's set. | **1.5 h** | **OQ-050**, OQ-008, OQ-007, DEC-012 | A.11.1 shows the current docs are wrong about this repository, and the naive detection idiom returns a confidently incorrect answer. |
| **A5** | **Batched-invocation prototype.** `status --porcelain=v2 --branch` plus a persistent `cat-file --batch` pipe across all 21 repositories; compare against the current per-call approach. | **2 h** | A.7; feeds OQ-012 | If batching removes the spawn overhead, the main performance argument for libgit2 disappears and OQ-010 simplifies to correctness and licensing. |
| **B1** | **Real WebStorm save capture.** Open a scratch project in WebStorm, run the FSEvents logger already written, and capture: single save, Save All of 5 files, format-on-save, and a save with `.idea` open. | **1 h** | **OQ-039**, OQ-056, DEC-007 | The last step from "faithful reproduction" to "measured against the actual editor". Cheap, and OQ-039 is explicitly about real WebStorm behaviour. |
| **B2** | **Drop-and-recover test.** Force `MustScanSubDirs` (suspend the callback queue under load, or a very large `pnpm install` in a watched tree) and verify the full-rescan path. | **2 h** | **OQ-055** | 40k events produced zero drops, so this path will otherwise ship untested and will first execute in front of a user. |
| **B3** | **Unicode/case path-matching test.** Repository with filenames differing only in case, and with Polish diacritics in NFC and NFD; verify event path ↔ Git path matching. | **1 h** | **OQ-054** | Realistic for this user's repositories, and the failure mode is silent: auto-refresh just stops for that file. |

**Total: 14.5 h.** If only three can be funded: **A1** (the comparison is otherwise decided by unequal evidence), **A2** (the DEC-025 hazard cannot be found any other way), **B1** (it is the literal text of OQ-039 and costs an hour).

---

# Sources

**Measured locally, 2026-07-26**, macOS 26.5.2 (25F84) arm64, git 2.50.1 (Apple Git-155), Swift 6.2.4. Harness retained in the session scratchpad under `watch/`. No repository under `~/WebstormProjects` was modified; real repositories were only read (`--no-optional-locks` subcommands, `find`, `stat`, `open(O_EVTONLY)`).

**Git**

- `git(1)`, `--no-optional-locks` — https://git-scm.com/docs/git (also verified in the local man page: "Do not perform optional operations that require locks. This is equivalent to setting the GIT_OPTIONAL_LOCKS to 0.")
- `git-config(1)`, `diff.renames` — local man page, git 2.50.1: "Defaults to true. Note that this affects only git diff Porcelain … and not lower level commands such as git-diff-files(1)."
- `git-cat-file(1)`, `--filters` — local man page, git 2.50.1
- `git-hash-object(1)`, `-w` / `--path` — local man page, git 2.50.1
- `gitattributes(5)` — https://git-scm.com/docs/gitattributes

**libgit2**

- Licence, `COPYING` — https://github.com/libgit2/libgit2/blob/main/COPYING
- Filter application in diff, `src/libgit2/diff_file.c` — https://github.com/libgit2/libgit2/blob/main/src/libgit2/diff_file.c
- `git_status_opt_t` / `include/git2/status.h` — https://libgit2.org/docs/reference/main/status/git_status_opt_t.html and https://github.com/libgit2/libgit2/blob/main/include/git2/status.h
- `git_diff_option_t` (`GIT_DIFF_UPDATE_INDEX`) — https://libgit2.org/docs/reference/main/diff/git_diff_option_t.html
- `git_diff_find_similar` — https://libgit2.org/docs/reference/main/diff/git_diff_find_similar.html
- `git_filter_mode_t` / filter API — https://libgit2.org/docs/reference/main/filter/
- External clean/smudge filter support, issue #1473 — https://github.com/libgit2/libgit2/issues/1473
- Licence clarification, issue #3807 — https://github.com/libgit2/libgit2/issues/3807
- v2.0 / API stability, issue #4960 and releases — https://github.com/libgit2/libgit2/issues/4960, https://github.com/libgit2/libgit2/releases
- Downstream evidence of missing filter drivers: TortoiseGit issue #2224 — https://gitlab.com/tortoisegit/tortoisegit/-/issues/2224; git-lfs issue #375 — https://github.com/git-lfs/git-lfs/issues/375

**Bindings** (activity data pulled from the GitHub, npm and crates.io APIs on 2026-07-26)

- SwiftGit2 — https://github.com/SwiftGit2/SwiftGit2
- nodegit — https://github.com/nodegit/nodegit, https://www.npmjs.com/package/nodegit
- git2-rs — https://github.com/rust-lang/git2-rs, https://crates.io/crates/git2, https://crates.io/crates/libgit2-sys
- objective-git — https://github.com/libgit2/objective-git
- LibGit2Sharp — https://github.com/libgit2/libgit2sharp

**macOS file watching**

- `FSEvents.h`, macOS 26.2 SDK — `/Library/Developer/CommandLineTools/SDKs/MacOSX26.2.sdk/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/FSEvents.framework/Versions/A/Headers/FSEvents.h` (primary; all header quotes verbatim, including the 8-directory exclusion limit at line 1424)
- File System Events Programming Guide — https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/TechnologyOverview/TechnologyOverview.html
- `kqueue(2)` `EVFILT_VNODE` — Darwin man page
- notify (Rust) — https://docs.rs/notify/latest/notify/
- chokidar — https://github.com/paulmillr/chokidar, https://www.npmjs.com/package/chokidar
- @parcel/watcher exclusion-path limit in practice — https://github.com/parcel-bundler/watcher/issues/190

**JetBrains save behaviour**

- "Use safe write" and the `___jb_tmp___` / `___jb_old___` sequence — JetBrains IDE support: https://intellij-support.jetbrains.com/hc/en-us/community/posts/115000329604
