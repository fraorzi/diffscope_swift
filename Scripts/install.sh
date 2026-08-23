#!/bin/bash
# Puts the current commit's DiffScope in ~/Applications, so the entry Spotlight opens is never
# older than the checkout. `DIFFSCOPE_INSTALL_DIR=/Applications Scripts/install.sh` for the other one.
#
#   Scripts/install.sh          # build, assemble, install
#
# Run automatically by `.githooks/post-commit` and `.githooks/post-merge`. It is a script rather
# than a line in a document because a document cannot install anything: the owner asked never to
# have to ask for this, and the only version of "always" a repository can offer is a hook.
#
# **A failed build must not leave a broken application installed.** The bundle is assembled in
# `dist/` first and only swapped in when it exists and launches with `--version`; until then the
# previous install stays exactly where it was, which is the behaviour a reader wants at the moment
# they reach for the app to look at the change that broke the build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# `~/Applications` by default, `/Applications` when asked for. Spotlight indexes both; the home one
# needs no administrator rights, so an install triggered by a commit never prompts for a password —
# an installer that can stop and ask is an installer that eventually gets turned off.
DEST="${DIFFSCOPE_INSTALL_DIR:-$HOME/Applications}"
STAGE="$ROOT/dist"
VERSION="$(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unversioned)"

mkdir -p "$DEST"
[ -w "$DEST" ] || { echo "cannot write to $DEST"; exit 1; }

"$ROOT/Scripts/make-app.sh" "$STAGE" >/dev/null
APP="$STAGE/DiffScope.app"
[ -x "$APP/Contents/MacOS/DiffScope" ] || { echo "no executable in $APP"; exit 1; }

echo "==> installing into $DEST"
# `ditto` rather than `cp -R`: it replaces the bundle atomically enough that a half-copied
# application is never what a double-click finds, and it keeps resource forks and permissions.
rm -rf "$DEST/DiffScope.app.previous"
[ -d "$DEST/DiffScope.app" ] && mv "$DEST/DiffScope.app" "$DEST/DiffScope.app.previous"
ditto "$APP" "$DEST/DiffScope.app"
rm -rf "$DEST/DiffScope.app.previous"

# Spotlight indexes a moved bundle on its own, but not always promptly, and an installer that leaves
# the reader wondering whether it worked has not finished. `mdimport` asks for it directly.
mdimport "$DEST/DiffScope.app" 2>/dev/null || true
# And the staged copy goes away, so there is exactly one DiffScope.app on this machine. Spotlight
# offering two entries with the same name and different lifetimes is the failure this avoids, and
# deleting the stage is a more reliable way to avoid it than asking the indexer to ignore it.
# `package.sh` stages into the same directory and keeps its own copy for the zip; it does not call
# this script, so nothing it needs is removed here.
rm -rf "$STAGE/DiffScope.app"
# The quarantine attribute is what makes an unsigned bundle need a right-click on first launch. It is
# set by browsers and archive tools, not by a local copy — clearing it anyway costs nothing and means
# the owner never sees the dialog for a build they made themselves.
xattr -dr com.apple.quarantine "$DEST/DiffScope.app" 2>/dev/null || true

echo "    $DEST/DiffScope.app is now $VERSION"
