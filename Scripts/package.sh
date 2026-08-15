#!/bin/bash
# Builds DiffScope.app and zips it for a third-party tester (gate G3 of docs/23-release-gates.md).
#
# The bundle is **unsigned** — a deliberate decision, recorded in the gate: no Apple Developer
# account is required, and the tester passes Gatekeeper by hand with the instructions in
# docs/25-tester-packet.md.
#
# Everything the application needs at runtime goes inside the bundle. A build that quietly reads
# from the checkout works perfectly on this machine and fails only on the tester's, which is the
# classic way this step goes wrong — so the script proves independence rather than assuming it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
APP="$OUT/DiffScope.app"
VERSION="$(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unversioned)"

echo "==> building the renderer bundle"
(cd "$ROOT/Renderer" && npm run build >/dev/null)

echo "==> building for release"
(cd "$ROOT" && swift build -c release >/dev/null)

BIN="$ROOT/.build/release/diffscope-app"
RESOURCE_BUNDLE="$ROOT/.build/release/DiffScope_diffscope-app.bundle"
[ -x "$BIN" ] || { echo "no release binary at $BIN"; exit 1; }
[ -d "$RESOURCE_BUNDLE" ] || { echo "no resource bundle at $RESOURCE_BUNDLE"; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DiffScope"

# `Bundle.module` resolves against the main bundle's resource directory first and the executable's
# directory second. Both are populated, so the lookup cannot depend on which rule wins.
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/MacOS/"

echo "==> drawing the icon"
ICONSET="$OUT/DiffScope.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
swift "$ROOT/Scripts/make-icon.swift" "$OUT/icon-1024.png" >/dev/null
for size in 16 32 64 128 256 512; do
  sips -z $size $size "$OUT/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$OUT/icon-1024.png" \
    --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/DiffScope.icns"
rm -rf "$ICONSET" "$OUT/icon-1024.png"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DiffScope</string>
  <key>CFBundleDisplayName</key><string>DiffScope</string>
  <key>CFBundleExecutable</key><string>DiffScope</string>
  <key>CFBundleIdentifier</key><string>local.diffscope.app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>DiffScope</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- No network entitlement is requested and no network code exists. The privacy claim in
       docs/25-tester-packet.md is a statement about the source, not about a setting. -->
</dict>
</plist>
PLIST

echo "==> proving it runs with nothing from the source tree"
# Copied somewhere unrelated and launched with a working directory that has no checkout in it. If
# anything were still being read from the repository, this is where it would fail.
PROOF="$(mktemp -d)"
cp -R "$APP" "$PROOF/"
PROOF_CONFIG="$PROOF/config.json"

# The working tree the definition of done is stated against (M8-J). Built by a script, outside the
# application, and handed to the selftest by path: the walk over 63 files is the measurement behind
# "reviewable entirely from the keyboard", and it is not a claim to make from the engine's checks.
KEYBOARD_TREE="$PROOF/keyboard-tree"
"$ROOT/Scripts/keyboard-tree.sh" "$KEYBOARD_TREE" >/dev/null

if (cd / && DIFFSCOPE_SELFTEST=1 DIFFSCOPE_CONFIG="$PROOF_CONFIG" \
      DIFFSCOPE_KEYBOARD_TREE="$KEYBOARD_TREE" \
      "$PROOF/DiffScope.app/Contents/MacOS/DiffScope" >"$PROOF/log" 2>&1); then
  grep -c "SELFTEST.*OK" "$PROOF/log" | xargs -I{} echo "    {} selftest arms passed from $PROOF"
  grep "SELFTEST keyboard" "$PROOF/log" | sed 's/^/    /'
  # A skipped keyboard walk must not look like a passed one: the packaging step is where this claim
  # is made, so it is the step that refuses to make it without the measurement.
  if grep -q "SELFTEST keyboard=SKIPPED" "$PROOF/log"; then
    echo "!! the keyboard walk was skipped — the 63-file tree never reached the selftest"; exit 1
  fi
else
  STATUS=$?
  # **The exit code, and the last arm that reported.** A run died here once in four and the log
  # simply stopped: the code maps to the arm through the `exit(N)` constants, and the last line
  # says which arm got that far. Without both, the whole log is a haystack.
  echo "!! the packaged application failed away from the source tree (exit $STATUS):"
  echo "   last arm to report: $(grep 'SELFTEST' "$PROOF/log" | tail -1 | cut -c1-120)"
  echo "   the whole log is kept at $PROOF/log"
  cat "$PROOF/log"
  exit 1
fi
rm -rf "$PROOF"

echo "==> zipping"
ZIP="$OUT/DiffScope-$VERSION.zip"
rm -f "$ZIP"
(cd "$OUT" && ditto -c -k --keepParent DiffScope.app "$(basename "$ZIP")")
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "$SHA  $(basename "$ZIP")" > "$OUT/SHA256SUMS"

echo
echo "    $ZIP"
echo "    sha256 $SHA"
echo "    give the tester the zip and docs/25-tester-packet.md"
