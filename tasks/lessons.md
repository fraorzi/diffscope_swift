# Lessons

Recorded after a correction, per the global instructions. One entry per lesson, not per incident —
an incident that only repeats an entry gets added to it.

---

## A negative control that cannot reach the code it controls for proves nothing

**2026-09-04, DEC-117.** The control asserted that with the new rule off an untouched word between
two indent marks *is* swallowed. It failed on the first run — and not because the fix was wrong. The
synthetic case used a three-byte indent, so DEC-094's older *no longer than the shorter flank* rule
had already refused the island and the new rule was never consulted. The control was exercising a
path that did not include the thing it was controlling for.

Rebuilt with an eighteen-space indent — what a real rewrap produces — it failed and then passed in
the right order.

**How to apply:** after writing a control, check that the code it is meant to disable is actually
reached in that case. A control that passes without touching the rule is worse than none, because it
reads as evidence.

---

## `swift run diffscope-verify` is not the whole gate

**2026-09-04, DEC-119a.** A change touching no renderer file shipped a defect that hid a real edit,
with the check suite green. `CLAUDE.md` names `swift build` and `swift run diffscope-verify`; the
application selftest is run by `Scripts/package.sh` and catches a different class of thing entirely —
here, an arm about ⌘E round-tripping noticed that a model had silently gained a fold.

**How to apply:** any engine change that alters `unifiedBlocks`, `changeStops`, `folds` or
`collapses` runs `DIFFSCOPE_SELFTEST=1 swift run diffscope-app` before it is committed. It is two
minutes and it caught what thirty seconds of unit checks could not.

---

## A test can pass for the wrong reason, and the way to find out is to break the fix

**2026-09-04.** A new selftest arm asserted that a formatting group's marker exists in the unified
layout. It passed. It also passed with the fix reverted — because it counted `.ds-fold` across the
whole page, and the test model carried other folds. Rewritten to count the group's own class it
reported the same number both ways, which meant the claim was **not demonstrated**, and the change
was reverted rather than shipped.

**How to apply:** every new assertion gets run once with its fix reverted. If it still passes, it is
measuring something else. This is the same shape as the entry above and the same shape the UI audit
found in `grep`-for-the-guard checks; it keeps recurring because a passing test feels like evidence.

---

## A difference between two measurements is an attribution only if both cover the same population

**2026-09-05, M14-E.** "The alignment contributes 2373 false lines and the widening passes 6706" was
reported to the owner as the audit's largest remaining lever. It was wrong: the 39 pairs whose
canonical diff ran out of budget contribute **zero** canonical hunk lines and a great deal of shipped
error, so the subtraction was over two different sets of files. Re-derived by isolating each pass,
the widening stack accounts for 358.

**How to apply:** before subtracting two numbers and calling the difference a cause, ask which files
are in each. M12-J recorded the same lesson from the other side — a timing regression that was four
background surveys sharing a machine.

---

## Measure the path the reader waits for, not the function you are changing

**2026-09-05, DEC-125.** `fallbackDiffWorkBudget` was a tenth of the canonical budget, set by M11-E
to keep a dense-JSX file near its parse baseline. M11-E timed `structuralDiff` **alone**. The product
validates immediately afterwards, computing the same diff at the full budget — so the tenth saved
nothing the reader felt, and cost an INV-2 violation on eleven real files by building a model against
one alignment and checking it against another.

**How to apply:** when a budget or a threshold is justified by a timing, check that the timing covers
what happens next. A number taken over a sub-path attributes its cost to the wrong decision.

---

## Ask an invariant of the corpus, not only of the fixtures

**2026-09-05, DEC-125.** Four thousand real pairs went through the shipped pipeline on every survey
run since M11, and nothing checked an invariant on any of them; the check suite validated a few dozen
fixtures. The first run that asked found eleven files violating INV-2, shipping since DEC-105.

**How to apply:** a corpus survey that reports only presentation metrics cannot distinguish *the
picture improved* from *the model broke*. Validate first, print it first, and count the pairs where
the question could not be asked.

---

## Write incrementally when the work can be interrupted

**2026-09-03/04.** Six subagents died to session limits and server errors mid-task. The three told to
append their findings after every few items left usable partial reports; the ones holding everything
in memory left nothing, and their work was done twice.

**How to apply:** any delegated task longer than a few minutes is instructed to create its output
file first and append as it goes.
