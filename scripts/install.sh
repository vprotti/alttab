#!/bin/bash
# Replaces the AltTab in /Applications with a fresh build of this checkout.
#
#   scripts/install.sh              build when the sources changed, then install
#   scripts/install.sh --no-build   install dist/AltTab.app as it is
#   scripts/install.sh --clean      also forget settings, for a first-launch start
#
# In order:
#   1. builds dist/AltTab.app unless it is newer than every source;
#   2. quits the running copy, and makes sure it is gone;
#   3. moves the old /Applications/AltTab.app to the Trash, recoverable;
#   4. clears the old copy's Accessibility and Screen Recording entries. macOS
#      ties both to the exact binary, so a new build would otherwise sit behind
#      a switch that shows on but still points at the old one;
#   5. moves to the Trash any LaunchAgent that execs /Applications/AltTab.app
#      directly. One left behind by another switcher at the same path once
#      started a second copy at every login;
#   6. copies the new app in and opens it. It asks for the permissions again.
#
# Settings (shortcut, language, switches) are kept unless --clean is passed.
set -euo pipefail

[ "$(uname -s)" = "Darwin" ] || { echo "error: this installs a Mac app; run it on the Mac" >&2; exit 1; }

cd "$(dirname "$0")/.."
ROOT="$PWD"
SOURCE="$ROOT/dist/AltTab.app"
TARGET="/Applications/AltTab.app"
BUNDLE_ID="br.com.nasralla.alttab"

BUILD=1
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --clean) CLEAN=1 ;;
    *) echo "usage: scripts/install.sh [--no-build] [--clean]" >&2; exit 64 ;;
  esac
done

if [ "$BUILD" = 1 ]; then
  STALE=""
  if [ -x "$SOURCE/Contents/MacOS/AltTab" ]; then
    STALE="$(find "$ROOT/Sources" "$ROOT/Support" -type f -newer "$SOURCE/Contents/MacOS/AltTab" 2>/dev/null | head -1 || true)"
  fi
  if [ ! -x "$SOURCE/Contents/MacOS/AltTab" ] || [ -n "$STALE" ]; then
    "$ROOT/scripts/build.sh"
  fi
fi
[ -x "$SOURCE/Contents/MacOS/AltTab" ] || { echo "error: $SOURCE missing, run scripts/build.sh" >&2; exit 1; }

NEW_VERSION="$(defaults read "$SOURCE/Contents/Info" CFBundleShortVersionString)"
OLD_VERSION="$(defaults read "$TARGET/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "none")"
echo "==> AltTab $NEW_VERSION replacing $OLD_VERSION"

# Asked by bundle id, so another app that happens to be called AltTab is left
# alone. "is running" never launches the app just to answer.
is_running() {
  [ "$(osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null || true)" = "true" ]
}
binaries="$TARGET/Contents/MacOS/AltTab|$SOURCE/Contents/MacOS/AltTab"

if is_running || pgrep -f "$binaries" >/dev/null; then
  echo "==> Quitting the running copy"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 25); do
    pgrep -f "$binaries" >/dev/null || break
    sleep 0.2
  done
  if pgrep -f "$binaries" >/dev/null; then
    pkill -TERM -f "$binaries" || true
    sleep 1
    pkill -KILL -f "$binaries" 2>/dev/null || true
  fi
fi

if [ -d "$TARGET" ]; then
  TRASHED="$HOME/.Trash/AltTab $OLD_VERSION $(date +%Y%m%d-%H%M%S).app"
  echo "==> Moving the old copy to the Trash"
  mv "$TARGET" "$TRASHED" || {
    echo "error: could not move $TARGET; is /Applications writable by this account?" >&2
    exit 1
  }
fi

echo "==> Clearing the old permission entries"
tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || echo "    note: Accessibility entry not reset; remove it by hand in System Settings"
tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || echo "    note: Screen Recording entry not reset; remove it by hand in System Settings"

for plist in "$HOME/Library/LaunchAgents/"*.plist; do
  [ -f "$plist" ] || continue
  if plutil -convert xml1 -o - "$plist" 2>/dev/null | grep -q "/Applications/AltTab.app"; then
    echo "==> Removing stale LaunchAgent $(basename "$plist")"
    launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
    mv "$plist" "$HOME/.Trash/" 2>/dev/null || rm -f "$plist"
  fi
done

if [ "$CLEAN" = 1 ]; then
  echo "==> Forgetting settings"
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  rm -rf "$HOME/Library/Application Support/$BUNDLE_ID"
fi

echo "==> Installing"
ditto "$SOURCE" "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
open "$TARGET"

echo "==> Done: AltTab $NEW_VERSION is in /Applications and running."
echo "    Grant Accessibility (required) and Screen Recording (previews) when it asks."
