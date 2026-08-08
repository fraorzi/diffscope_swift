# 11 — Git Behaviour Specification

**Status:** Phase 5. Authoritative for Git interaction.
**Mechanism undecided** — CLI vs libgit2 is OQ-010, open going into Phase 7. This document specifies **behaviour**, which both must satisfy.

---

## 1. The read-only guarantee

The application never writes to the working tree, the index, or Git configuration (DEC-003). This is the product's central trust claim, and it covers **every Git operation the application issues on its own** — including `git fetch`, which is excluded entirely (DEC-011).

**One thing qualifies it, and it is named rather than buried (DEC-053).** Since T1 the application contains a terminal, and a terminal runs whatever the user types into it — `git commit` included. That is the user acting, deliberately, in a shell they opened. The guarantee above is unchanged in what it covers: the engine, the Git layer, the refresh, the watcher, every automatic path. R-8 proves that and proves nothing about the terminal, which is the user's.

The one command the *application* composes is `cd` when the terminal follows the reader's selection, under the guard in DEC-056. It changes no repository state, and it is the only one.

### 1.1 Read-only is about effects, not command names

**Measured:** plain `git status` rewrites `.git/index` when the stat cache is stale — i.e. after a file's mtime changes, which is exactly this application's normal operating mode under DEC-006 and DEC-007. `git --no-optional-locks status` does not, under the identical condition.

**Binding requirement: every Git invocation passes `--no-optional-locks` or the mechanism's equivalent.** Without it the DEC-003 claim is false in ordinary use, not in an edge case.

### 1.2 Audited-clean operations

Verified by hashing every file under `.git` before and after:

`status --porcelain` (with `--no-optional-locks`) · `diff` · `diff --cached` · `diff HEAD` · `diff --stat` · `diff-index` · `diff-files` · `ls-files` · `ls-tree` · `cat-file -p` · `rev-parse` · `merge-base` · `rev-list --count` · `log -1` · `show --stat` · `for-each-ref` · `symbolic-ref -q` · `check-attr`

libgit2 was separately measured clean for repository open, `status()`, `diff()`, and `revparse_single()`.

### 1.3 Prohibited, permanently

`fetch` · `gc` · `maintenance` · `checkout` · `add` · `commit` · `reset` · `stash` · `prune` · `repack` · `worktree` · `update-index` · `write-tree` · anything under `remote` · **any command defined by repository content** (DEC-028).

### 1.4 Enforcement

The read-only property is proven by test, not by review: snapshot the repository directory including `.git` internals, run every operation the application can issue, assert byte-equality. Adding a Git call without a corresponding proof fails CI (test R-8).

**Open:** whether any read path can trigger `gc --auto` on a large repository (OQ-046). The audit ran below auto-gc thresholds. The obvious mitigation — setting `gc.auto=0` — is itself a config write and therefore prohibited.

## 2. Obtaining bytes

The engine requires exact bytes. `git cat-file -p` and `git show` return **raw object-database bytes with smudge/EOL filters not applied** (measured); filters apply on checkout into the working tree.

### 2.1 Filter regime

`git diff` normalises the **worktree side down into ODB form** — the *clean* direction, not smudging the committed side upward. Proven two ways: `hash-object --stdin --path` of a CRLF worktree file yields the ODB OID, and a custom clean/smudge driver produced patch text in cleaned form.

Therefore the compared pair is **both sides in cleaned (ODB) form** (DEC-025 as amended).

**But those bytes are not obtainable read-only.** No plumbing emits cleaned bytes for a worktree file: `cat-file --filters` applies the smudge direction, `hash-object` returns only an OID.

**Resolution (DEC-028): files with an active filter get no structural diff.** They fall back to raw with the filter disclosed. Executing the repository's configured filter commands was rejected — repository *content* would decide what executes, which is a remote-code-execution surface reachable by cloning a hostile repository.

Filter detection uses `git check-attr` (audited clean).

**Current exposure is latent, not active:** 0 of 21 repositories set `core.autocrlf` or `core.eol`, and no `.gitattributes` carries `text`/`eol`/`crlf` directives. The 34 CRLF files are CRLF in the object database too. This behaviour therefore **cannot be validated against the current corpus** and requires the `eol-filter-active` fixture.

### 2.2 Status semantics

**Measured discrepancy:** libgit2 reports 165 entries where `git status --porcelain` reports 63 for the same repository — libgit2 defaults to expanding untracked directories, matching `--porcelain -uall`.

Whichever mechanism is chosen, the convention must be **explicit and documented**, because DEC-012's headline count differs by 2.6× between them.

## 3. Comparison scopes

Four scopes (DEC-008):

| # | Scope | Old side | New side |
|---|---|---|---|
| 1 | All local vs `HEAD` | `HEAD` blob | working tree |
| 2 | Unstaged vs index | index blob | working tree |
| 3 | Staged vs `HEAD` | `HEAD` blob | index blob |
| 4 | Branch vs merge-base | merge-base blob | `HEAD` blob |

Scopes undefined for the current repository state are **disabled with a stated reason**, never hidden.

## 4. Base-branch resolution

Cascade (DEC-009): `origin/HEAD` → unique local `main`/`master` → prompt the user. Measured against the corpus: 17 of 21 resolve at step 1, 3 more at step 2, 1 requires the prompt.

The detected base is **displayed** and overridable per repository, stored in application configuration and never written into the repository. A silently wrong base produces a plausibly-shaped but entirely wrong diff — a trust failure of the same class as hiding a change.

The base side prefers the **remote-tracking ref**, falling back to local (DEC-010). The ref used and its age are always displayed — this is the sole staleness signal, since the application never fetches.

**Age is the committer date of the ref tip**, which is *not* the time of last fetch. The latter is what the user actually wants and is not reliably recoverable. UI copy must not conflate them.

## 5. Repository states

### 5.1 Unborn HEAD

Real today (`carrefour-inapp`): `.git/HEAD` points at `refs/heads/main`, zero refs, zero commits.

**Detection must not use `git symbolic-ref -q HEAD`** — measured, it returns exit 0 and `refs/heads/main`, a branch that does not exist. Use `git rev-parse --verify HEAD` failing, or libgit2's `head_is_unborn`, which is a first-class property and the one clear advantage libgit2 showed in measurement.

Behaviour: all four scopes unavailable with reason; ahead-count explicit unknown; branch display shows the state, not a fabricated name.

### 5.2 Detached HEAD

Not present in the current corpus — an earlier record claiming otherwise was a Phase 0 misreading, corrected. Must not crash or misreport. Scope 4 unavailable.

### 5.3 No remote

Base falls back to the local ref automatically (DEC-010).

## 6. Discovery

Any number of user-added roots, scanned to depth 2 with descent stopping at the first repository found, **plus individually added repositories anywhere** (DEC-018, DEC-037).

- Traversal guards against symlink cycles and symlinks escaping the root.
- Nested repositories and submodules are not surfaced by default, a direct consequence of stopping at the first repository found. Encountering one must not crash or misreport (OQ-014, OQ-015).
- Identically-named repositories from different roots must be disambiguated — path is the identity, not folder name.

## 7. Status collection

Eager parallel sweep at launch across all roots, refreshed on window focus (DEC-006). Measured on one root of 21 repositories: 326 ms sequential, negligible parallelised; slowest single repository 70 ms; `.git` size does **not** predict cost, which tracks working-tree file count.

Per repository the sweep collects: branch or state, uncommitted count, merge-base, ahead-count. Ahead-count measured at 504 ms sequential for 21 repositories.

## 8. Pinning

Every diff is bound to a **content hash for each side**. Recomputation produces a new pin atomically. This makes a mixed-version diff structurally impossible rather than merely unlikely (DEC-007).

## 9. Open items

- OQ-010 — mechanism. Contested after measurement: libgit2 wins on unborn-HEAD handling; the CLI wins on status performance (46 ms vs 264 ms), binding health, licensing, and Raw-mode fidelity where it is the reference by definition.
- OQ-046 — auto-gc exposure on large repositories.
- OQ-048 — confirm `--no-optional-locks` coverage for every command actually issued.
- OQ-054 — case-folded and NFC-normalised path matching; measured that FSEvents reports on-disk case while Git is case-sensitive, so a mismatch silently stops auto-refresh for that file.
- Override storage key, given that multiple roots can reach the same repository by different paths.
