# 12 — Desktop UX Specification

**Status:** Phase 4. Authoritative for interface behaviour.
**Constrained by:** DEC-005, DEC-006, DEC-007, DEC-012 – DEC-019, DEC-026, DEC-027, DEC-031, DEC-033 – DEC-036.
**Stack-independent.** Nothing here presumes a rendering technology (OQ-033 is open).

---

## 1. Information architecture

One window (DEC-005). Two persistent regions plus a transient one:

```
┌─────────────────┬──────────────────────────────────────┐
│ Repository list │ Scope bar                            │
│ (sidebar)       ├──────────────────────────────────────┤
│                 │ Changed-file list │ Diff view        │
│                 │ (grouped, flat)   │ (side-by-side)   │
└─────────────────┴──────────────────────────────────────┘
```

No tabs, no secondary windows. Last-opened repository is restored (DEC-005), treated as a cache: if it has moved, been deleted, or changed state, the application recovers to the repository list rather than trusting its memory.

## 2. Repository list

Sources (DEC-037): **any number of user-added root directories**, scanned to depth 2 stopping at the first repository found (DEC-018), **plus individually added repositories** located anywhere. All sources merge into one list.

Populated by an eager parallel sweep at launch, refreshed on window focus (DEC-006). All repositories are shown, including clean ones (DEC-012).

Because two roots may contain identically-named repositories, **the list must disambiguate by more than name** — the row identity is the repository path, not its folder name.

Each row carries **two independent signals**:

| Signal | Source | Unknown state |
|---|---|---|
| Uncommitted file count | status | — |
| Commits ahead of base | merge-base + rev-list | **Explicit "unknown", never 0** |

The unknown state is mandatory, not cosmetic: displaying `0` when the base branch could not be determined is a factual misstatement of the same family the core invariant forbids.

**Semantics note.** The uncommitted count must state which convention it uses — `git status --porcelain` collapses untracked directories, libgit2's default expands them, and the same repository reads 63 or 165 depending on the choice (X-4). Whichever is adopted, it is documented and consistent.

Also displayed per repository: current branch, or the correct state where there is none — see §7.2.

## 3. Scope bar

Four scopes (DEC-008), always visible for the selected repository:

1. All local changes vs `HEAD`
2. Unstaged vs index
3. Staged vs `HEAD`
4. Current branch vs merge-base of base branch

Scope 4 additionally displays **which ref was used and how old it is** — for example `origin/master · 9 weeks old` (DEC-010). This display is a correctness requirement, not decoration: it is the sole staleness signal, because the application never fetches (DEC-011).

The detected base branch is shown and is overridable per repository (DEC-009). Overrides are stored in application configuration, never written into the repository.

Scopes that are undefined for the current repository state are **disabled with a stated reason**, never hidden. Hiding them would make the interface silently disagree with itself between repositories.

## 4. Changed-file list

Flat, one-dimensional, with group headers per workspace package and middle-elided paths (DEC-033).

- Path elision preserves **start and end**: the start identifies the package, the end identifies the file.
- Group headers are labels, not focus stops.
- Files outside any workspace package fall into a default group.

Per-file indicators: change kind (added / modified / deleted / renamed), and any degradation state from §6.

## 5. Diff view

Side-by-side only (DEC-014). Three modes over two code paths (DEC-013): **Structural** (default), **Expanded**, **Raw**.

All three operate on the same pinned source pair, so switching modes can never change which versions are compared.

### 5.1 Colour discipline

Change meaning is carried by **gutter, underline, and background texture — never by token colour** (DEC-035). Syntax highlighting is left untouched. Character-level intra-line changes are marked by underline or texture, not by recolouring characters.

This satisfies DEC-016 structurally: the information survives greyscale and colour-blindness because shape carries it.

### 5.2 Required indicators

Not optional features — these are how the invariant becomes visible (DEC-017):

| Indicator | Meaning |
|---|---|
| Confidence | How certain the structural alignment is |
| Ambiguity | Match was ambiguous; candidates not arbitrarily resolved (DEC-031) |
| Parser state | Whether the file parsed, partially parsed, or not at all |
| Fallback marking | This region is raw, not structural (INV-4) |
| Unverified | File exceeded the runtime validation threshold (DEC-022) |
| Invisible difference | Bytes differ but render identically (DEC-023) |
| Filter active | Git filter in play; structural diff withheld (DEC-028) |

### 5.3 Formatting groups

Formatting-only changes may be collapsed **with a disclosed count and immediate expansion** (DEC-017). The empty-diff state reads as *"no structural changes; N formatting differences (expand)"* — never a bare "no changes" unless the sides are byte-equal (INV-3).

### 5.4 Long lines

DEC-014's side-by-side choice makes long lines the known weak spot. Horizontal scrolling is linked between panes; wrapping is available; neither may truncate content silently. Spike X-2 found no rendering cliff at 50,000-character lines in either web candidate.

## 6. Degradation states

Every degradation is **visible**. Failure reduces visual quality, never correctness.

| State | Trigger | Presentation |
|---|---|---|
| Fallback region | Parse failure or low confidence | Region marked raw, reason stated |
| Whole-file fallback | Invariant violation at runtime (DEC-022) | File marked raw, reason stated |
| Unverified | Above validation size threshold | Explicitly labelled unverified |
| Unsupported language | Not TS/TSX/JS/JSX (DEC-004) | Ordinary raw diff, labelled — not an error |
| Filter active | Git filter detected (DEC-028) | Raw, with filter disclosed |
| Binary / generated | Detected non-text | No text diff attempted |

The unsupported-language state is the **majority case by file count** and must be designed as an ordinary, well-finished state rather than an error condition.

## 7. Repository states requiring specific handling

### 7.1 Clean repository

Selecting it must lead naturally to scope 4, not to an empty scope-1 view. A clean repository can have substantial review material: one in the current corpus is clean but two commits ahead of base.

### 7.2 Unborn HEAD

Real today (`carrefour-inapp`): `.git/HEAD` points at `refs/heads/main`, zero refs, zero commits.

- Branch display: the state, not a fabricated branch name.
- Ahead count: explicit unknown.
- All four scopes: unavailable, with reason — there is no `HEAD` to compare against.
- **Detection must not use `git symbolic-ref -q HEAD`**, which returns exit 0 and a branch that does not exist. Use `git rev-parse --verify HEAD` failing, or libgit2's `head_is_unborn`.

### 7.3 Detached HEAD

Not present in the current corpus, but must not crash or misreport. Branch display shows the detached state; scope 4 is unavailable.

### 7.4 Base branch undeterminable

Prompt for it (DEC-009), on the same screen family as §7.5.

### 7.5 No roots configured, or a configured root missing

Empty-state screen with a **plain directory picker — no suggested path, no auto-detection** (DEC-036 as amended). The application does not create directories.

`~/WebstormProjects` has no special status: it is a WebStorm-specific name, and nothing in this product depends on WebStorm. This mirrors DEC-015, which rejected hardcoding WebStorm as the editor.

A configured root that has disappeared is reported as such and does not remove the user's other roots or their per-repository configuration.

## 8. Refresh behaviour

Auto-refresh on file change, trailing-edge debounce with a maximum-delay cap (DEC-007, DEC-026). `node_modules` excluded from watching (DEC-027).

**Scroll anchoring** (DEC-034): anchor to the nearest segment labelled unchanged above the viewport top. Fallback chain when the anchor is deleted: nearest surviving unchanged segment above → top of file. Re-anchoring must not drift across repeated refreshes, and must have a non-animated path under reduced motion.

File selection is preserved across refresh where the file still exists in the scope, and degrades clearly where it does not.

## 9. Keyboard

DEC-016 commits to **full keyboard operation of every function**. This is a complete map, not a shortcut list. Minimum coverage:

| Function |
|---|
| Move between repositories |
| Move between files (one-dimensional, per DEC-033) |
| Switch scope |
| Next / previous change |
| Switch mode (Structural / Expanded / Raw) |
| Expand a collapsed range or formatting group |
| Show raw for the current region |
| Open current file and line in the editor |
| Focus movement between sidebar, file list, and diff |

Concrete key assignments are deferred to implementation but the **coverage** above is binding. Any function reachable only by pointer is a defect.

## 10. Editor integration

Configurable command template with file and line placeholders, defaulting to WebStorm (DEC-015).

- Failure — editor absent, command fails — must be **visible**, never a silent no-op.
- The template is user configuration and must never be populated from repository content, which is untrusted input.
- Opening "this line" from the old side of a deleted region has no destination in the current file; behaviour must be defined rather than left to produce a wrong jump.

## 11. Theming

Follows macOS system light/dark, with a built-in syntax theme per appearance (DEC-019). Appearance changes are handled while running, including mid-diff. Both variants are independently verified for contrast **and texture legibility**, since DEC-035 makes texture load-bearing.

## 12. Open items owned by this document

- Concrete key assignments (OQ-023 coverage is settled; bindings are not).
- Sorting and grouping order within the repository list.
- Minimum usable window width, given side-by-side.
- Visual design of ambiguity indication that does not read as malfunction (DEC-031).
- Whether the empty-state picker interacts with sandboxing (OQ-035).
