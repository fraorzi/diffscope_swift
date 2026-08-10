# raster-identical-bytes-differ

Every pixel identical, every byte different: the same image written at a different compression
level with a `tEXt` chunk added. F18 on the raster path, where `svg-text-only-change` is F18 on the
text-that-renders path.

This is what a re-export from a design tool looks like in a diff, and it is the case where a
comparison that only counts pixels reports "no change" about a file whose bytes moved.
