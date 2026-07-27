# 13 — Error and Fallback Model

**Status:** Phase 4/5. Authoritative for failure behaviour.
**Governing principle:** failure degrades **visual quality**, never **correctness**, and is never silent.

---

## 1. The three rules

1. **No silent degradation.** Every fallback, every skipped check, every withheld structural analysis is visible in the interface with a stated reason.
2. **No fabricated values.** Where something cannot be determined, the interface says unknown. It never substitutes a plausible default — a fabricated `0` ahead-count is the same class of defect as a hidden change.
3. **Correctness survives every failure path.** A parser crash, an invariant violation, a filter, or a size limit all end in raw textual diff — never in a missing change.

## 2. Failure taxonomy

| # | Failure | Detection | Response | Visible as |
|---|---|---|---|---|
| F1 | Parse error in part of a file | Parser reports error region | Structural for clean regions, raw for the rest | Fallback region marking |
| F2 | Parse failure of whole file | No usable tree | Whole-file raw | File-level fallback marking |
| F3 | Low match confidence | Matcher confidence below threshold | Raw for affected region | Confidence indicator + fallback |
| F4 | Ambiguous match | Matcher's ambiguous set non-empty | Present ambiguity; do not resolve arbitrarily | Ambiguity indicator (DEC-031) |
| F5 | Invariant violation at runtime | INV checks fail (DEC-022) | Discard structural result, whole-file raw | Fallback + reason |
| F6 | File above validation threshold | Size check | Structural allowed, checks skipped | **"Unverified"** label |
| F7 | Unsupported language | Extension / content classification | Raw diff | Ordinary labelled state, not an error |
| F8 | Git filter active | `git check-attr` | Raw diff, no structural claim | Filter disclosed (DEC-028) |
| F9 | Binary or generated file | Content detection | No text diff attempted | Stated file kind |
| F10 | File changed mid-analysis | Content hash mismatch vs pin | Discard, recompute against new pin | Transient; never a blended result |
| F11 | Base branch undeterminable | Detection cascade exhausted | Prompt; scope 4 unavailable | Prompt + explicit unknown |
| F12 | Unborn HEAD | `rev-parse --verify HEAD` fails | All scopes unavailable, reason stated | State shown in place of branch |
| F13 | Editor launch failure | Non-zero exit / not found | Report | Visible error, never a no-op |
| F14 | Root directory missing | Path check | Empty-state picker (DEC-036) | Picker screen |
| F15 | Watcher event loss | FSEvents drop signal | Full rescan of the repository | Refresh indication |

## 3. Failure paths that need deliberate testing

Several of these cannot occur in the current corpus and will therefore **ship untested unless forced**:

- **F8** — 0 of 21 repositories have Git filters active. Requires the `eol-filter-active` fixture.
- **F15** — 40,000 file creations produced 40,041 events with zero drops in measurement. The drop path exists in FSEvents but will not be exercised by normal use; it must be triggered deliberately.
- **F6** — depends on a threshold not yet chosen (OQ-043).
- **F10** — requires deliberately racing a file change against analysis (test R-9).
- **F13** — requires an intentionally broken editor command.

Recording this explicitly because "we never saw it fail" is not evidence when the trigger cannot arise locally.

## 4. What must never happen

Enumerated as prohibitions so they can be tested:

- A file displayed as unchanged when its two sides differ by any byte (INV-3).
- A fallback that is not marked as a fallback (INV-4).
- A change present in Raw mode but absent in Structural mode.
- Structural and Expanded disagreeing about what changed (INV-5).
- An ahead-count, branch name, or base ref displayed as a value when it is actually unknown.
- A validation check skipped without the file being labelled unverified.
- A move that discards the delta of its moved content (structurally prevented by DEC-024, still tested).
- A Git invocation without `--no-optional-locks` or equivalent (DEC-003).
- Executing any command defined by repository content (DEC-028).

## 5. Degradation ordering

When multiple conditions apply, the **most conservative** wins. Precedence, highest first:

```
F10 stale pin  →  F9 binary  →  F8 filter  →  F5 invariant violation
→  F2 whole-file parse failure  →  F7 unsupported  →  F6 unverified
→  F3/F4 confidence/ambiguity  →  F1 partial parse error
```

Rationale: a stale pin invalidates everything downstream, so it is checked first; ambiguity and partial parse errors are the mildest and only affect presentation of regions that are otherwise sound.

## 6. Error message requirements

Every visible failure states: **what** was withheld, **why**, and **what remains trustworthy**.

The third element is the one usually omitted and matters most here. "Could not parse this file" leaves the user unsure whether the diff is complete. The correct form is closer to: *"Structural analysis unavailable — file did not parse. All textual differences are shown."*

That sentence is the product's trust model in miniature, and it should read the same way everywhere it appears.
