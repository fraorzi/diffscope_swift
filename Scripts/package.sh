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

# The bundle itself is `make-app.sh`, shared with `install.sh` — one description of what the
# application is, two callers with different obligations. What belongs to *this* script is what a
# release gate owes a tester: the proof that the bundle runs with nothing from the checkout, the
# keyboard walk, the zip and its checksum.
"$ROOT/Scripts/make-app.sh" "$OUT" >/dev/null

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
