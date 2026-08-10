# svg-text-only-change

The case the whole class exists for. The source differs — a `<title>`, and `#fff` written as
`#FFFFFF` — and **not one pixel does**.

Without the sentence F18 requires, a reader is shown two identical pictures and concludes the tool
found nothing. What it found is a difference that does not reach the screen: DEC-023's invisible
difference, at the scale of a whole file. The rendered comparison must say *"the two files render
identically — 0 pixels differ, the bytes differ"* and point at the source reading, which an SVG has
and a raster does not.

Also the case that proves SVG is **text that renders** rather than binary (DEC-063). Treated as
binary it would hide a real textual diff; treated as text alone it would hide that the mark moved.
