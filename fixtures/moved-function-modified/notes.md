# moved-function-modified

THE LOSSLESSNESS TRAP (OQ-026): the same relocation as `moved-function`, with one edit
inside the relocated line — `0.23` becomes `0.25`.

If the line were reported as moved, that delta would ride along inside the move and
vanish. DEC-038 admits byte-identical moves only, so the correct answer is **no move at
all** here, and that is what the structural layer produces: `moved-function` reports one
move, this fixture reports zero. T-11 fails if any link's two sides differ.
