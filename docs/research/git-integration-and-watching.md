# Research — Git Integration and File Watching

**Status:** Partially complete. §1–§3 are **verified by local measurement**. §4 (Git access mechanism comparison) and §5 (file watching) are **NOT YET RESEARCHED** — the delegated agent failed before producing them.
**Provenance:** This document replaces the output of a background research agent that terminated on a session limit. The sections marked verified were measured directly on this machine on 2026-07-26 in scratch repositories outside `~/WebstormProjects`. No user repository was modified.

---

## 1. Read-only audit — VERIFIED BY MEASUREMENT

Method: scratch repository with staged, unstaged, and untracked changes plus two branches. Before and after each command, every file under `.git` was hashed (SHA-256) and the hash sets compared. Any difference means the command wrote.

### 1.1 Result table

| Command | Writes to `.git`? |
|---|---|
| `git status --porcelain` | **Conditional — see §1.2** |
| `git --no-optional-locks status --porcelain` | No |
| `git diff` | No |
| `git diff --cached` | No |
| `git diff HEAD` | No |
| `git diff --stat HEAD` | No |
| `git diff-index HEAD` | No |
| `git diff-files` | No |
| `git ls-files` | No |
| `git ls-tree HEAD` | No |
| `git cat-file -p <blob>` | No |
| `git rev-parse HEAD` | No |
| `git merge-base <a> <b>` | No |
| `git rev-list --count a..b` | No |
| `git log -1 --format=…` | No |
| `git show --stat HEAD` | No |
| `git for-each-ref` | No |
| `git symbolic-ref -q HEAD` | No |
| `git check-attr text -- <path>` | No |

### 1.2 The `git status` index rewrite — precise conditions

An initial audit showed plain `git status --porcelain` as clean, which appeared to contradict the expectation that it can rewrite the index. **The first audit was misleading**: the index was already fresh, so there was nothing to refresh.

Constructing the actual triggering condition — `touch` on tracked files, changing mtime while leaving content identical, so the index stat cache goes stale — produces:

```
index before touch + status : acefa9c5e77f9c11…
index after  plain status   : b860619f14a983c8…   → REWROTE
index before touch + status : 4656e4a394fbceb7…
index after  --no-optional-locks status : 4656e4a394fbceb7…   → did not write
```

**Verified conclusion:** plain `git status` rewrites `.git/index` when the stat cache is stale. `git --no-optional-locks status` does not, under the same condition.

**Why this matters more than it looks.** The triggering condition is *exactly* this application's normal operating mode. The user saves in WebStorm → mtime changes → stat cache goes stale → the next status call rewrites the index. Under DEC-006 (eager sweep at launch, refresh on focus) and DEC-007 (auto-refresh on save), the application would be rewriting index files continuously across up to 21 repositories.

**Binding requirement:** every Git invocation the application issues must pass `--no-optional-locks`. This is not a defensive nicety; without it the read-only claim of DEC-003 is simply false in ordinary use.

### 1.3 Commands NOT audited

Deliberately not tested, and must never be issued by the application: `fetch`, `gc`, `maintenance`, `checkout`, `add`, `commit`, `reset`, `stash`, `prune`, `repack`, `worktree`, `update-index`, `write-tree`, anything under `git remote`.

Note also that Git may run **background maintenance** (`gc --auto`) as a side effect of some commands. None of the audited read-only commands triggered it here, but the audit ran on a tiny repository where auto-gc thresholds are not met. This is an open item — see §6.

## 2. EOL and encoding filters — VERIFIED BY MEASUREMENT

The concern: if Git transforms bytes when handing them to us, a byte-exact diff tool inherits a lie.

Measured with `.gitattributes` containing `text eol=crlf` and `core.autocrlf true`:

```
blob in object database          : 61 0a 62 0a          ("a\nb\n")
git cat-file -p HEAD:lf.txt      : 61 0a 62 0a          ← filter NOT applied
git show HEAD:lf.txt             : 61 0a 62 0a          ← filter NOT applied
worktree after checkout          : 61 0d 0a 62 0d 0a    ← filter APPLIED
```

**Verified conclusion:** `cat-file` and `show` return raw object-database bytes. Smudge/EOL filters are applied on checkout into the working tree, not on plumbing reads.

### 2.1 The consequence, which is a genuine design problem

For any scope comparing a **committed side** against the **working tree** (DEC-008 scopes 1 and 2), the two sides come from different filter regimes:

- old side via `cat-file` → raw ODB bytes
- new side read from disk → post-smudge bytes

Where a filter is active, these differ on **every line** of the file. A byte-exact diff would present the entire file as changed. That is technically true — the bytes really do differ — but it is useless, and worse, it would **disagree with `git diff`**, which applies the filters and correctly reports no change.

That disagreement is not a cosmetic problem. Raw mode is the **control view** (DEC-013): its entire purpose is to let the user check a structural claim against plain Git output. A Raw mode that contradicts `git diff` destroys the property it exists to provide.

**Recommended resolution, for decision:** the Git layer owns filter handling and must produce the byte pair that Git's own diff would use — filters applied consistently to both sides. The diff engine still performs no transformation; it receives whatever pair the Git layer produced. Where a filter was applied, the Git layer must **disclose** it, since a transformation happened between disk and the compared bytes.

This preserves both properties: the engine contract stays "bytes in, bytes out, unmodified" (DEC-021 §4.2), and Raw mode continues to agree with `git diff`.

### 2.2 Current corpus exposure — measured

| Check | Result |
|---|---|
| Repositories setting `core.autocrlf` | **0 of 21** |
| Repositories setting `core.eol` | **0 of 21** |
| `.gitattributes` with `text`/`eol`/`crlf` directives | **none found** |
| The 34 CRLF files — does Git report them as changed? | No — CRLF in both ODB and worktree |

**The hazard is latent, not active.** Every repository uses Git defaults, so ODB bytes currently equal worktree bytes. The 34 CRLF files are genuinely CRLF in the object database.

This means the problem cannot be discovered by testing against the current corpus, which is precisely why it needs a fixture (`fixtures/eol-filter-active/`, to be added to §4.4 of the test corpus plan) rather than being left to be found in production after someone clones a repository configured by a Windows colleague.

## 3. Verified answers to specific scope questions

- Exact blob bytes for a committed side: `git cat-file -p <rev>:<path>` — confirmed raw, no filtering.
- Merge-base: `git merge-base` — no writes.
- Ahead count: `git rev-list --count <base>..HEAD` — no writes. Measured across all 21 repositories at 504 ms sequential.
- Base ref age: `git log -1 --format=%cI <ref>` — no writes. Note this is the **committer date of the ref tip**, not the time of last fetch, per DEC-010's recorded caveat.
- Detached HEAD detection: `git symbolic-ref -q HEAD` returns non-zero on detached HEAD — no writes.

## 4. Git access mechanism comparison — NOT RESEARCHED

**This section is empty and blocks OQ-010.** The delegated agent failed before reaching it. Required: comparison of Git CLI subprocess invocation vs libgit2 (and bindings: SwiftGit2, nodegit, git2-rs) vs native implementations, covering correctness parity, write side effects, performance, API stability, licensing — **libgit2's licence and its linking exception need exact treatment**, given DEC-020 leaves distribution open.

Interim position, stated as an assumption rather than a conclusion: the CLI is currently better evidenced, because the audit above establishes its read-only behavior empirically, and because CLI output is by definition what Raw mode must agree with. No such evidence exists yet for libgit2. **This is not a decision** — see OQ-010.

## 5. File watching — NOT RESEARCHED

**This section is empty and blocks OQ-039 and the DEC-007 debounce value.** Required: FSEvents vs kqueue vs DispatchSource; behavior under atomic-replace saves (how many events one WebStorm save emits — this determines the ~400 ms debounce); recursive watch cost and descriptor limits with large `node_modules` trees; whether `.git` internals can be watched to detect branch switches and external commits; dropped events; case-insensitive filesystem implications.

## 6. Open questions raised by this document

- **OQ-046 — Auto-gc exposure.** Whether any read-only command can trigger `gc --auto` on a large real repository. The audit ran on a scratch repository below auto-gc thresholds, so this is untested where it matters. `gc.auto=0` cannot be set by us (that would be a config write), so if a read path can trigger maintenance, the mitigation must be different.
- **OQ-047 — Filter-regime policy.** §2.1 above. Recommended resolution given; needs a decision.
- **OQ-048 — Do all needed operations have `--no-optional-locks` equivalents?** Verified for `status`. It is a top-level Git option so it should apply generally, but each command the application issues must be confirmed rather than assumed.

## 7. Sources

- Measured locally, 2026-07-26, in scratch repositories under the session scratchpad. Scripts retained there. No repository under `~/WebstormProjects` was modified; all inspection of real repositories used `--no-optional-locks` and read-only subcommands.
- `git --no-optional-locks` documented in git(1) top-level options — https://git-scm.com/docs/git
- `gitattributes(5)`, `text` and `eol` — https://git-scm.com/docs/gitattributes
- `git-cat-file(1)` — https://git-scm.com/docs/git-cat-file
