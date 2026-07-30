# 23 — Release gates

**Status:** Accepted 2026-07-29. Authoritative for the three points at which this project stops being an internal build and is handed to somebody.

Milestones M0–M8 are engineering gates: they end when a measurement holds. The three gates here are **handover gates** — they end when a *person* can do something they could not do before. That is a different acceptance test, and it needs writing down separately, because "all checks pass" has never meant "someone else can use this".

---

## How a gate is signalled

A gate is not passed by an agent's opinion. Each one ends with a **report written to `docs/`** and a line in the conversation naming it. The report is what makes the claim checkable later; the conversation line is only a pointer.

| Gate | Report | The sentence that announces it |
|---|---|---|
| G1 | `docs/23a-poc-report.md` | **POC READY** — with the walkthrough log and the known-gaps list *(written 2026-07-29)* |
| G2 | `docs/24-design-contract.md` | **DESIGN INTAKE READY** — naming the one file to paste into |
| G3 | `docs/25-tester-packet.md` | **TESTER BUILD READY** — naming the `.zip` and its checksum |

**A gate is never announced from checks alone.** Every one of them requires the agent to have run the application and looked at what it drew. The suite proves the model; it has never been able to see the screen — the reason the selftest snapshots exist at all (M6-D, where a verified move reached the renderer unpaired while every harness check passed).

---

## G1 — Proof of concept, ready for the product owner to use

**Question it answers:** can the person who commissioned this sit down and review a real change with it?

**Explicitly not in scope.** No new features. The gate is a *verification* gate, and adding to it would defeat its purpose — the point is to find out what the existing thing is like to use, before deciding what to build next. Anything discovered goes on the gaps list, not into the gate.

### Exit criteria

Every item observed on the owner's own repositories, not on fixtures.

- [ ] `swift run -c release diffscope-app` launches and discovers repositories under the real root
- [ ] A repository with uncommitted work renders a diff without a crash, in all three modes
- [ ] All four scopes produce a file list, or state why they are unavailable (unborn HEAD, no base branch)
- [ ] Navigation: ⌘N/⌘P walk every change in a long file, ⌘E expands a fold, folds and formatting groups disclose their counts
- [ ] Refresh: saving a file in WebStorm updates the view without losing the reader's place
- [ ] ⌘O opens the editor, and a broken `DIFFSCOPE_EDITOR` reports the failure rather than doing nothing
- [ ] Each degradation is seen at least once with its notice: unsupported language, binary, oversized, parse failure
- [ ] A repository with **no** changes, and a file with a **single-byte** change, both read correctly
- [ ] `swift run diffscope-verify` passes, and `DIFFSCOPE_SELFTEST=1` exits 0
- [ ] The walkthrough is logged with the actual repository names and what was observed, including anything that felt wrong but is not a defect

### What gets built

A short launch section in the report — the two commands, the environment variables (`DIFFSCOPE_ROOT`, `DIFFSCOPE_EDITOR`, `DIFFSCOPE_SNAPSHOT_DIR`) — and the **known-gaps list**, which is the deliverable that matters. Known gaps are already recorded across `21-agent-handoff.md`; the report collects them in one place phrased for someone using the app rather than reading its source.

---

## G2 — Ready to receive a design

**Question it answers:** can a design be pasted in without touching behaviour, and without any risk to the invariant?

**The assumption on record:** the design arrives from Claude, as either a set of tokens or a working HTML/CSS prototype. The gate covers both, because the two need the same thing underneath — a boundary between *what the interface means* and *what it looks like*.

### Exit criteria

- [ ] **One token file.** Every colour, font, size, spacing, radius and border in `Renderer/src/` lives in `tokens.css` as a custom property. Nothing else declares one.
- [ ] **A check enforces it**, in `diffscope-verify`: a literal colour, font stack or hard-coded size outside the token file fails the suite. Without the check the boundary lasts until the next edit.
- [ ] **The AppKit chrome has the same treatment** — window, lists, status line and controls read their values from one Swift constant table mirroring the token names, so a design does not stop at the edge of the webview.
- [ ] **`24-design-contract.md` exists**, naming every class the renderer emits, what it means, and which ones are load-bearing: `ds-changed`, `ds-fallback`, `ds-moved`, `ds-formatting`, `ds-behaviour`, `ds-uncertain`, `ds-invisible`, `ds-fold`, `ds-fold-formatting`, `ds-badge`, `ds-chip`.
- [ ] **The rules a design may not break are stated and checked**, not merely written:
      - a change mark may be restyled but never hidden — no `display: none`, no zero-opacity, no colour equal to its background, on any `ds-` class carrying a difference;
      - meaning is carried by **texture, not colour** (DEC-035), because colour alone fails for a colour-blind reader and in a screenshot;
      - a disclosed count stays visible wherever grouping quietens something (DEC-017);
      - the notice bar cannot be styled away — INV-4 is a promise about what is *seen*.
- [ ] **The paste-in procedure is one paragraph**: replace the token file (or drop the prototype's CSS in beside it), `npm run build` in `Renderer/`, `swift run diffscope-verify`, then the selftest with `DIFFSCOPE_SNAPSHOT_DIR` to look at every state.
- [ ] The selftest snapshot set covers every visual state a design would want to see: structural, expanded, disclosure, moved, navigation, refresh, anchored, degraded.

### Why the checks and not just the document

A design that hides a change mark would violate the core invariant through CSS while every engine check passed — the model would still contain the difference, and the reader would not see it. That is the one class of regression a restyle can cause, so it is the one the gate must make impossible rather than discourage.

---

## G3 — A build a third party can test

**Question it answers:** can somebody who has never seen this repository run the application and report something useful?

**Distribution form:** an **unsigned `.app` in a zip**, per the product owner's decision. No Apple Developer account is required; the tester passes Gatekeeper manually and the packet tells them exactly how.

### Exit criteria

- [ ] `Scripts/package.sh` produces `DiffScope.app` from a release build: `Info.plist`, an icon, the renderer bundle inside the app's resources, and a zip with a recorded SHA-256
- [ ] **The bundle runs with the source tree deleted or moved.** A build that quietly reads from the checkout is the classic way this fails, and it fails only on the tester's machine
- [ ] **First run by a stranger works**: no default path is assumed (DEC-036/DEC-037), a missing or empty root shows the picker rather than an error or a blank window, and choosing a directory with no repositories says so
- [ ] Launched with **no Git repositories anywhere**, and on a machine with **no WebStorm**, neither path crashes and both explain themselves
- [ ] `DIFFSCOPE_EDITOR` is documented for testers who use a different editor, and the default's failure is visible rather than silent
- [ ] **`25-tester-packet.md`** contains: what the application does, the Gatekeeper instructions, three or four concrete things to try, what is *known* missing so nobody reports it twice, how to report an observation, and the privacy statement
- [ ] The privacy statement is one paragraph and is **true and demonstrable**: reads only, never writes to a repository (R-8 snapshots `.git` before and after every Git operation), never sends anything anywhere, no telemetry, no AI at runtime
- [ ] The packet says what to do about a diff that looks wrong: **keep the file**, because the pair is what makes it reproducible

### What the tester is asked for

Not bug reports in the abstract. The useful question for a stranger is narrower: *did the diff ever tell you something that was not true?* Everything else — slowness, ugliness, missing features — is welcome but secondary, because only the first kind threatens the invariant this project is built around.

---

## Ordering

**G1 → G2 → G3**, and the order is not arbitrary.

G1 first because the gaps list it produces is the input to every decision after it. G2 second because a design applied before the owner has used the application is a design for an imagined product. G3 last because handing a stranger something the owner has not used, and does not like the look of, wastes the one thing a third-party tester is expensive to get: a first impression.

They are gates, not milestones in the M-series sense — G2 and G3 both contain real implementation work (a token layer, a packaging script), but each is defined by the handover it enables rather than by the code it adds.
