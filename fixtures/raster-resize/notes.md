# raster-resize

16 × 16 → 24 × 16. The changed number is **stated**, never silently rescaled to fit the stage: a
reader comparing two frames drawn at the same size cannot see that one of them grew.

The pixel pass covers both sides on a canvas of the larger size, so the region the smaller side
does not reach counts as differing rather than being quietly skipped.
