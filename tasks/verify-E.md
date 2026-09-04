# Verification — Area E (block-level presentation)

Status: in progress. Written incrementally.

## 0. The root cause the lead found — confirmed, with the mechanism quoted

### 0.1 Mechanism

Reproduced exactly as reported (`/tmp/vE/e.tsx` → `/tmp/vE/f.tsx`, `--emit-structural`):

```
=== UNIFIED BLOCKS ===
   0  old 1–1 new 1–4
```

control (`e.tsx` → `g.tsx`, closing `/>` moved onto the last changed line):

```
=== UNIFIED BLOCKS ===
   0  old 1–1 new 1–4 reflowed — the whole old half is withheld
```

The deciding line is `Sources/DiffScopeEngine/Unified.swift:81`:

```swift
let newTokens = layoutTokens(new[block.newStart..<block.newEnd])
```

The withholding question is asked **against the block's own new half and nothing else**. The block's
new half is built in `unifiedBlocks` at `Sources/DiffScopeEngine/Unified.swift:180-189` from the
snapped union of the hunks:

```swift
let newRange = snap(new, stop.newStart, stop.newEnd)
...
newStart: last.newStart, newEnd: max(last.newEnd, newRange.end))
```

so `block.newEnd` is the end of the **last line any hunk touched**. Prettier's closing `/>` sits on
its own line, is byte-identical to nothing on the old side and is touched by no hunk, so it is one
line past `block.newEnd`.

Then at `Sources/DiffScopeEngine/Unified.swift:95-103` the per-line walk runs out of tape:

```swift
for token in lineTokens {
    var found = false
    while walker < newTokens.count {
        let candidate = newTokens[walker]
        walker += 1
        if candidate == token { found = true; break }
    }
    if !found { matched = false; break }
}
```

The old line's tokens are `< Img src = { a . src } alt = "" / >`. `/` and `>` are not in
`newTokens` because they live at new line 5. `matched` goes false, the line is kept, and — since it
is the only old line — nothing is withheld at all. The old element is printed in full beside its own
rewrap, with **no** "re-wrapped — N lines not printed" note, because `buildUnified`
(`Renderer/src/main.js:500`) only writes the note when `hiddenLines > 0`.

The failure is all-or-nothing per line, and JSX elements that Prettier explodes are usually one old
line, so "one token short" and "the whole element printed twice" are the same event.

**A second consequence, not in the report:** this shape is invisible to the corpus survey.
`duplicatedLineBreakdown` (`Sources/diffscope-verify/CorpusSurvey.swift:449-455`) only counts an old
line as duplicated when some **byte-identical** new line exists in the block:

```swift
guard let newIndex = newLines.indices.first(where: {
    !taken.contains($0) && Array(new[newLines[$0].start..<newLines[$0].end]) == text
}) else { continue }
```

A rewrapped line has no byte-identical partner by construction, so the whole family scores 0 on
`duplicated-line`. That is why the shipped 106 duplicated lines look small next to what a reader
sees.

