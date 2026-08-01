# 17 — Security, Privacy, and Licensing

**Status:** Phase 8. Authoritative.

---

## 1. Privacy posture

| Property | Status |
|---|---|
| Network access | **None.** Not for updates, not for fetch, not for anything (DEC-011, DEC-020) |
| Telemetry | **None** |
| Cloud processing | **None** |
| AI at runtime | **None** |
| Data leaving the machine | **None** |

The application reads local repositories and renders them. There is no egress path to disable, because none is built.

This is a design property, not a setting. It also simplifies entitlements: no network entitlement is requested.

## 2. The threat model

The application scans directories the user points it at and opens whatever repositories it finds. **Repository content is untrusted input.** A repository can be cloned from anywhere.

### 2.1 The rejected RCE surface

Reproducing `git diff` exactly for filtered files would require running the repository's configured `filter.*.clean` commands. That means **repository content deciding what executes** — a remote-code-execution surface reachable by cloning a hostile repository.

**Rejected in DEC-028.** Filtered files fall back to raw with the filter disclosed. This reasoning is recorded so the option is not revived later as a convenience feature.

### 2.2 Other untrusted-input rules

- The editor command template (DEC-015) is **user configuration** and must never be populated from repository content.
- File paths, branch names, and commit messages are rendered as **data**, never interpreted. Branch names in particular can contain almost anything.
- Parsers process hostile input by design. Parser failure must degrade to raw (F1/F2), never crash the process.
- Path traversal: scan traversal guards against symlink cycles and symlinks escaping the configured root (DEC-018).

### 2.3 What the application cannot do

Because it is strictly read-only (DEC-003), the blast radius of any defect excludes repository damage. It cannot stage, commit, discard, fetch, or modify Git configuration. Verified by test R-8, which snapshots `.git` before and after every operation the application can issue.

## 3. Sandboxing

**Open (OQ-035), and harder than it first appeared.**

DEC-037 allows arbitrary root directories *and* individually added repositories anywhere. Under the App Sandbox each location needs user-granted access, persisted across launches via **security-scoped bookmarks**, including handling revocation and stale bookmarks.

DEC-042 helps: a native Swift shell reaches these APIs directly, where a wrapper-based stack would not.

Two further sandbox tensions:

- **Subprocess execution.** The Git CLI is launched as a subprocess. This is permissible but interacts with sandbox configuration and must be verified early.
- **External editor launch** (DEC-015) starts another application.

Neither is blocking, but both must be settled before any App Store path is considered. Since DEC-020 leaves distribution undecided and no store requirement forces sandboxing, this can remain open without blocking v1.

## 4. Licensing

DEC-020 leaves distribution undecided, so every dependency is evaluated **against possible future public or commercial distribution**. Adopting a strongly copyleft component would quietly foreclose that option.

### 4.1 Adopted

| Component | Licence | Assessment |
|---|---|---|
| tree-sitter (C API) | MIT | Clean |
| tree-sitter-typescript grammar | MIT | Clean — but **stale**, see §4.3 |
| CodeMirror 6 | MIT | Clean |
| xterm.js 6.0.0 (`@xterm/xterm`) | MIT | Clean — the terminal's output grid, DEC-054. Pinned exactly, bundled, checked for network APIs |
| `@xterm/addon-fit` 0.11.0 | MIT | Clean — sizes the grid to the pane |
| Swift / AppKit / WebKit | Apple platform | Clean, first-party |
| Git CLI | GPL-2.0, invoked as a **subprocess** | Clean — separate process, no linking |

**On the Git CLI:** invoking a GPL program as a subprocess does not create a derivative work. This is the standard reading and is one reason the CLI is licensing-simpler than libgit2.

### 4.2 Rejected or avoided on licensing grounds

| Component | Licence | Outcome |
|---|---|---|
| **GumTree** | **LGPL-3.0** | **Avoided.** Algorithms implemented from publications; no source ported (DEC-030). Algorithms are not copyrightable; implementations are. |
| **libgit2** | GPL-2.0 with linking exception | Not adopted. The exception covers linking *unmodified* libgit2; modifications remain GPL-2.0. GPL v2 only, no "or later". GitHub reports `NOASSERTION`, so scanners flag it. Not the deciding factor — the CLI won on other grounds too — but it contributed. |

### 4.3 Maintenance risk that is not a licensing risk

`tree-sitter-typescript` is MIT and clean, but **stale** — verified via the GitHub API on 2026-07-27: last release v0.23.2 on 2024-11-11, last push 2025-08-29, 47 open issues.

**The specific correctness concern has been retired.** Issue #306 was carried through planning as "incorrect node ranges for multiline JSX" and treated as the top pre-implementation risk. M0-1 fetched the issue and found it is **"JSX captures whitespaces in nested, multiline tags"** — a text-node concern, not a range defect — and measured 1370 real `.tsx` files with **zero overlaps and 1370/1370 valid partitions**.

What remains is a **generic maintenance risk on a dependency the architecture rests on**: an under-maintained grammar may accumulate defects, and none are currently known to threaten the byte partition. MIT licensing keeps forking available as the mitigation if that changes.

By contrast, `tree-sitter/swift-tree-sitter` — the binding — is **healthy**: BSD-3-Clause, last release 0.10.0 on 2026-03-18, last push 2026-05-26, 3 open issues, maintained inside the tree-sitter organisation.

## 5. Discipline required of implementers

- Reading GumTree source for understanding is fine; transcribing it is not (DEC-030). The repository is public and easy to consult, so the distinction must be stated to anyone implementing the matcher.
- No dependency may be added without recording its licence against the distribution question.
- No network capability may be added without an explicit decision reversing §1.
