#!/bin/bash
# Builds the eight fixtures of `15-test-corpus-plan.md` §4.7a — the cases where a *correct*
# rendered comparison can still mislead (DEC-063).
#
# Generated rather than committed by hand, for the reason the corpus stores exact bytes: an image
# that passes through an editor, an optimiser or a screenshot tool is no longer the image the case
# is about. Everything below is written byte by byte, deterministically, so re-running this script
# reproduces the same files and `MANIFEST.json` stays true.
#
# **This script writes; the application does not.** R-8 is a statement about the Git operations
# `diffscope-app` itself can issue and is untouched by a script building fixture material — the same
# separation `keyboard-tree.sh` draws.

set -euo pipefail

ROOT="${1:-fixtures}"
mkdir -p "$ROOT"

python3 - "$ROOT" <<'PYTHON'
import os, struct, sys, zlib

root = sys.argv[1]

def chunk(kind, payload):
    return (struct.pack(">I", len(payload)) + kind + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff))

def png(width, height, pixel, *, level=9, text=None):
    """A PNG written here rather than by an encoder, so the bytes are the case.

    `pixel(x, y) -> (r, g, b, a)`. Rows carry filter byte 0: no prediction, so the compressed
    stream depends only on the pixels and the compression level — which is what
    `raster-identical-bytes-differ` needs to vary while the image does not."""
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            raw.extend(bytes(pixel(x, y)))
    body = [chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))]
    if text is not None:
        body.append(chunk(b"tEXt", text))
    body.append(chunk(b"IDAT", zlib.compress(bytes(raw), level)))
    body.append(chunk(b"IEND", b""))
    return b"\x89PNG\r\n\x1a\n" + b"".join(body)

def write(case, name, data):
    directory = os.path.join(root, case)
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, name), "wb") as handle:
        handle.write(data)

def text(case, name, content):
    write(case, name, content.encode("utf-8"))

# ---- SVG: text that also renders (DEC-063) -------------------------------------------------
#
# The first case is the one the whole class exists for: the source differs and not one pixel does.
# A reader shown a blank comparison concludes the tool found nothing, when what it found is a
# difference that does not reach the screen.
mark = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16">
  <title>{title}</title>
  <rect width="16" height="16" fill="{background}"/>
  <rect x="4" y="4" width="8" height="8" fill="{foreground}"/>
</svg>
"""
text("svg-text-only-change", "before.svg",
     mark.format(title="Mark", background="#282860", foreground="#fff"))
text("svg-text-only-change", "after.svg",
     mark.format(title="Acme mark", background="#282860", foreground="#FFFFFF"))

# The same file with the inner square moved: source and rendering both differ, and the two readings
# must agree that something changed.
moved = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16">
  <title>Mark</title>
  <rect width="16" height="16" fill="#282860"/>
  <rect x="{x}" y="4" width="8" height="8" fill="#ffffff"/>
</svg>
"""
text("svg-rendered-change", "before.svg", moved.format(x=4))
text("svg-rendered-change", "after.svg", moved.format(x=2))

# The control for the `<img>` boundary. An SVG is repository content and can carry script and
# remote references; the pane must draw it and run none of it (DEC-063, extending DEC-028).
hostile = """<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     viewBox="0 0 16 16" width="16" height="16" onload="globalThis.__diffscopeHostile = {marker}">
  <script type="text/javascript">globalThis.__diffscopeHostile = {marker};</script>
  <image href="https://example.invalid/pixel-{marker}.png" x="0" y="0" width="1" height="1"/>
  <use xlink:href="https://example.invalid/sprite-{marker}.svg#icon"/>
  <rect width="16" height="16" fill="#282860"/>
</svg>
"""
text("svg-hostile", "before.svg", hostile.format(marker=1))
text("svg-hostile", "after.svg", hostile.format(marker=2))

# ---- Raster ---------------------------------------------------------------------------------
def square(size, dot=False, width=None):
    width = width or size
    def pixel(x, y):
        if dot and 4 <= x <= 5 and 4 <= y <= 5:
            return (255, 255, 255, 255)
        return (40, 40, 96, 255)
    return png(width, size, pixel)

# Dimensions change: the changed number is stated, never silently rescaled.
write("raster-resize", "before.png", square(16))
write("raster-resize", "after.png", square(16, width=24))

# Re-encoded at the same visual result: every pixel identical, every byte different. F18 on the
# raster path — the tEXt chunk and the compression level are the only things that moved.
write("raster-identical-bytes-differ", "before.png",
      png(16, 16, lambda x, y: (40, 40, 96, 255), level=9))
write("raster-identical-bytes-differ", "after.png",
      png(16, 16, lambda x, y: (40, 40, 96, 255), level=1, text=b"Software\x00diffscope-fixture"))

# One side absent: Blend, Split and Pixel diff have nothing to compare against, and each says so.
write("image-added", "before.png", b"")
write("image-added", "after.png", square(16, dot=True))

# Over the pixel budget — 5000 × 4000 is 20 megapixels against a budget of 16. Uniform, so the file
# stays small: what is being tested is the refusal, not the disk.
write("image-over-budget", "before.png", png(5000, 4000, lambda x, y: (40, 40, 96, 255)))
write("image-over-budget", "after.png", png(5000, 4000, lambda x, y: (40, 40, 97, 255)))

# Neither text nor drawable: an archive, which gets `#unrenderable` and a sentence rather than an
# empty frame. A minimal but structurally real zip, written by hand for the same reason as the PNGs.
def zip_of(name, content):
    data = content.encode("utf-8")
    crc = zlib.crc32(data) & 0xffffffff
    local = (b"PK\x03\x04" + struct.pack("<HHHHHIIIHH", 20, 0, 0, 0, 0, crc, len(data), len(data),
                                         len(name), 0) + name.encode("ascii") + data)
    central = (b"PK\x01\x02" + struct.pack("<HHHHHHIIIHHHHHII", 20, 20, 0, 0, 0, 0, crc,
                                           len(data), len(data), len(name), 0, 0, 0, 0, 0, 0)
               + name.encode("ascii"))
    end = (b"PK\x05\x06" + struct.pack("<HHHHIIH", 0, 0, 1, 1, len(central), len(local), 0))
    return local + central + end

write("undisplayable-blob", "before.zip", zip_of("payload.txt", "one"))
write("undisplayable-blob", "after.zip", zip_of("payload.txt", "two"))
PYTHON

echo "wrote the eight §4.7a fixtures under $ROOT"
