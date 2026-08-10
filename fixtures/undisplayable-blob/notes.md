# undisplayable-blob

A structurally real zip, differing in one stored member. Neither text nor drawable, so it takes the
third class of DEC-063: `#unrenderable`, with a sentence that says what the file is and why nothing
is compared, and with both sides' byte counts — a reader who can see the sides differ knows the
tool found a difference and declined to draw it.

The sentence is checked (`runRenderedComparisonChecks`); before DEC-063 this state carried
`String(describing: error)`.
