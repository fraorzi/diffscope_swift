# prop-reordering

Props reordered **and** reformatted, values unchanged. `18-version-one-scope.md`'s definition of done, item 4: this must never report "no change" — guaranteed here by T-4 rather than by a bespoke assertion. It must also never be presented as formatting-only, which is asserted, because formatting-only is the one classification the interface may quieten (DEC-048).

Measured: 12 hunks, and the classifier reports neither `reordering` nor `formatting-only`. §4.1 hoped for `reordering`; the detector is an exact-permutation equivalence test over the aligned gap pair (DEC-046) and the reformat means the pairs are fragments rather than whole attribute lists. Recorded as a known gap rather than papered over: the dangerous direction — claiming formatting-only — is checked, and the harmless one is not claimed either.
