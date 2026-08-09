# image-file

A JFIF header with one differing payload byte. `binary-file` is a PNG; this exists so the non-text path is exercised by more than one magic number and one extension.

The adjacent case worth knowing about is **SVG**, which is an image *and* valid text: it takes the raw path as an unsupported language (DEC-004), not the binary path, and that is correct. There is no fixture for it because the behaviour it exercises is `unsupported-language`, which already has one.
