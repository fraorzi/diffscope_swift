# 03 — Feature Matrix

**Status:** Phase 1 complete. Reflects DEC-001 through DEC-020.
**Authority:** Descriptive; [04-decision-log.md](04-decision-log.md) wins on conflict.

Status values follow [glossary.md](glossary.md). **Mandatory** means the item derives from the core invariant and is not cuttable scope.

---

## Repository discovery and list

| Feature | Status | Ref |
|---|---|---|
| Multiple user-chosen roots | In v1 | DEC-037 |
| Individually added repositories, any location | In v1 | DEC-037 |
| Hardcoded or suggested default root path | **Rejected** — editor-specific | DEC-036 amended |
| Auto-detection of candidate roots | Rejected — predictability over convenience | DEC-036 amended |
| Scan depth configurable, default 2 | In v1 | DEC-018 |
| Stop descending at first repository found | In v1 | DEC-018 |
| Eager parallel status sweep at launch | In v1 | DEC-006 |
| Refresh repository list on window focus | In v1 | DEC-006 |
| Show all repositories including clean ones | In v1 | DEC-012 |
| Uncommitted file count per repository | In v1 | DEC-012 |
| Commits-ahead-of-base per repository | In v1 | DEC-012 |
| Explicit unknown state when base undeterminable | In v1 | DEC-012 |
| Symlink cycle and root-escape guards | In v1 | DEC-018 |
| Continuous watching of all repositories | Rejected for v1 | DEC-006 |
| Nested repositories as separate entries | Open, constrained by depth rule | OQ-014 |
| Worktrees and submodules | Deferred | OQ-015 |
| Favorites / pinned repositories | Open | — |
| Behavior when root does not exist | Open | OQ-017 |
| Sorting and grouping of the list | Open | OQ-013 note |

## Git behavior

| Feature | Status | Ref |
|---|---|---|
| Scope: all local changes vs `HEAD` | In v1 | DEC-008 |
| Scope: unstaged vs index | In v1 | DEC-008 |
| Scope: staged vs `HEAD` | In v1 | DEC-008 |
| Scope: branch vs merge-base of base branch | In v1 | DEC-008 |
| Base detection cascade | In v1 | DEC-009 |
| Per-repository base override, stored in app config | In v1 | DEC-009 |
| Detected base displayed, not hidden | Mandatory | DEC-009 |
| Prefer remote-tracking ref, fall back to local | In v1 | DEC-010 |
| Display base ref name and age | Mandatory | DEC-010 |
| Read-only: no writes of any kind | Mandatory | DEC-003 |
| Audit all Git invocations for incidental writes | Mandatory | DEC-003 |
| `git fetch`, automatic | Rejected | Brief, DEC-011 |
| `git fetch`, manual button | Deferred to v2 | DEC-011 |
| Staging / unstaging | Deferred to v2 | DEC-003 |
| Commit, discard, branch operations | Rejected for v1 | DEC-003 |
| Branch-vs-branch, commit-vs-commit, commit-vs-parent | Deferred | DEC-008 |
| Detached HEAD behavior | Open, blocking | OQ-008 |
| Git access mechanism (CLI / libgit2 / native) | Research required | OQ-010 |

## Diff engine

| Feature | Status | Ref |
|---|---|---|
| Structural alignment for TS/TSX/JS/JSX | In v1 | DEC-004 |
| Raw textual fallback for all other types | In v1, mandatory path | DEC-004 |
| Nested token / word / character diffing | In v1 | Brief |
| Wrapper add/remove alignment | In v1 | DEC-017 |
| Move detection | Open — trap documented | OQ-026 |
| Formatting-only classification | In v1, never a filter | Brief, DEC-017 |
| Potentially-behavior-affecting classification | In v1 | Brief |
| Confidence scoring | Mandatory | DEC-017 |
| Reconstruction of both sides from model | Mandatory | OQ-003 |
| Coverage validation against canonical minimal diff | Mandatory, formulation open | OQ-003 |
| Pinned source pair | Mandatory | DEC-007 |
| Structural and Expanded produce identical edit sets | Mandatory, testable | DEC-013 |
| Tailwind-specific subsystem | Rejected | Brief, DEC-004 |
| Structural support for CSS / JSON / MD / HTML | Deferred to v2 | DEC-004 |
| File classification into structural vs fallback | Open | DEC-004 |
| Repeated-node ambiguity policy | Research required | OQ-027 |
| Invalid / incomplete / conflicted source handling | Open | OQ-028 |
| Large, generated, minified, binary file handling | Open | OQ-029 |
| Rename / move / delete / untracked file matching | Open | OQ-030 |
| Performance budgets | Research required | OQ-031 |
| Caching strategy | Open | OQ-032 |

## Presentation

| Feature | Status | Ref |
|---|---|---|
| Side-by-side layout | In v1 | DEC-014 |
| Unified layout | Deferred | DEC-014 |
| Structural mode | In v1 | DEC-013 |
| Expanded mode (preset over structural renderer) | In v1 | DEC-013 |
| Raw mode, always available | Mandatory | DEC-013 |
| Confidence indicator | Mandatory | DEC-017 |
| Parser-state indicator | Mandatory | DEC-017 |
| Fallback-region marking | Mandatory | DEC-017 |
| "Show raw for this region" action | Mandatory | DEC-017 |
| Formatting-only grouping with disclosed count | Mandatory | DEC-017 |
| Previous / next change navigation | In v1 | DEC-017 |
| Collapsed unchanged ranges with expansion | In v1 | DEC-017 |
| Changed-file list | In v1 | DEC-017 |
| Syntax highlighting | In v1 | DEC-017 |
| Move and wrapper visualization | In v1 (move half depends on OQ-026) | DEC-017 |
| Whitespace visualization | In v1, via Expanded mode | DEC-013 |
| Inline character-level highlighting | In v1 | Brief |
| Search within diff | Deferred | DEC-017 |
| Filter by change type | Deferred — suppression risk noted | DEC-017 |
| Change minimap | Deferred | DEC-017 |
| Personal annotations / comments | Deferred | DEC-017 |
| File tree vs flat list | Open | OQ-041 |
| Long-line, wrap, horizontal and linked scrolling | Required spec work | DEC-014 |
| Default mode on open | Open (Structural presumptive) | OQ-019 note |
| Two-color-system separation | Open | OQ-040 |

## Platform, shell, and integration

| Feature | Status | Ref |
|---|---|---|
| macOS only, permanently | Accepted | DEC-002 |
| Single window, sidebar + diff pane | In v1 | DEC-005 |
| Remember last-opened repository | In v1 | DEC-005 |
| Repository tabs | Rejected | DEC-005 |
| Multiple windows | Rejected | DEC-005 |
| Auto-refresh on file change, ~400 ms debounce | In v1 | DEC-007 |
| Watch currently open repository | In v1 | DEC-007 |
| Preserve file selection and scroll anchor | In v1, semantics open | DEC-007, OQ-038 |
| Open file/line in editor, configurable command | In v1 | DEC-015 |
| System light/dark theming | In v1 | DEC-019 |
| Match WebStorm theme | Rejected | DEC-019 |
| Headless diff engine execution for CI | Mandatory | DEC-002 |
| Network access | Rejected entirely | DEC-011, DEC-020 |
| Telemetry | Rejected | Brief |
| Cloud processing | Rejected | Brief |
| AI at runtime | Rejected | Brief |
| Code signing / notarization / updates | Not required in v1 | DEC-020 |
| Sandboxing | Open | OQ-035 |

## Accessibility

| Feature | Status | Ref |
|---|---|---|
| No meaning by color alone | Mandatory | DEC-016 |
| Full keyboard operation of every function | Mandatory | DEC-016 |
| Respect system contrast setting | In v1 | DEC-016 |
| Respect reduced-motion setting | In v1 | DEC-016 |
| Complete keyboard map specification | Required spec work | OQ-023 |
| Screen-reader / VoiceOver support | Deferred, documented as a gap | DEC-016 |

## Undecided at the largest scale

| Item | Status | Ref |
|---|---|---|
| **Entire technology stack** | Research required | OQ-033 |
| Exact losslessness invariant | Research required | OQ-003 |
| Product name | Open | OQ-001 |
| Distribution and updating | Open | OQ-034 |
| Dependency licensing conclusions | Research required | OQ-036 |
| Test infrastructure | Research required | OQ-037 |
