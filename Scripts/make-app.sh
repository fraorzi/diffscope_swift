#!/bin/bash
# Assembles DiffScope.app. Nothing else: no proof run, no zip, no checksum.
#
#   Scripts/make-app.sh [out-dir]        # → <out-dir>/DiffScope.app, default dist/
#
# Extracted from `package.sh` when `install.sh` needed the same bundle for a different purpose.
# There is one description of what the application *is* and two callers with different obligations:
# the release gate proves the bundle runs away from the checkout and zips it for a tester, and the
# installer copies it into /Applications so the owner's Spotlight entry is never stale.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
APP="$OUT/DiffScope.app"
VERSION="$(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unversioned)"
mkdir -p "$OUT"

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

echo "$APP"
