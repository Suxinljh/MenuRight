#!/bin/bash
#
# Build, install and enable the MenuRight Finder extension for local testing.
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# Two traps cost real debugging time on 2026-09-30:
#
#  1. `cp -R` of an Xcode-built app bundle produces a copy that `codesign
#     --verify` happily reports as "valid on disk", but the kernel kills it at
#     launch with SIGKILL / "Taskgated Invalid Signature" (an Xcode Debug build
#     uses a debug dylib whose hard links `cp -R` breaks). `ditto` preserves
#     them and produces a launchable copy. Never `cp -R` an .app.
#
#  2. Finder only loads the extension that is *registered and enabled* in the
#     system — not "the one you just built". If a stale copy exists elsewhere,
#     you silently test old code and the app's own window shows
#     "Finder Extension: Disabled".
#
# So: exactly ONE installed copy, installed with ditto, re-registered and
# re-enabled every time, and verified at the end.
#
# Usage:
#   Scripts/install-dev-app.sh              # Debug (default)
#   Scripts/install-dev-app.sh Release
#
set -euo pipefail

CONFIG="${1:-Debug}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/MenuRight.app"
EXTENSION_ID="xin.ljhsu.MenuRight.FinderSync"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

cd "$PROJECT_DIR"

echo "==> 1/6 Building $CONFIG (signed, provisioning updates allowed)"
xcodebuild -project MenuRight.xcodeproj -scheme MenuRight -configuration "$CONFIG" \
  build -allowProvisioningUpdates >/tmp/menuright-install-build.log 2>&1 \
  || { echo "BUILD FAILED — see /tmp/menuright-install-build.log"; tail -20 /tmp/menuright-install-build.log; exit 1; }

BUILT_DIR=$(xcodebuild -project MenuRight.xcodeproj -scheme MenuRight -configuration "$CONFIG" \
  -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $3; exit}')
BUILT_APP="$BUILT_DIR/MenuRight.app"
[ -d "$BUILT_APP" ] || { echo "built app not found at $BUILT_APP"; exit 1; }
echo "    built: $BUILT_APP"

echo "==> 2/6 Checking the built app's own signature"
codesign --verify --deep --strict "$BUILT_APP" || { echo "signature invalid"; exit 1; }
echo "    signature valid"

echo "==> 3/6 Installing with ditto (NOT cp -R) into $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
if [ -d "$INSTALLED_APP" ]; then
  BACKUP="$INSTALLED_APP.previous-$(date +%m%d-%H%M%S)"
  mv "$INSTALLED_APP" "$BACKUP"
  echo "    previous copy moved to $BACKUP"
fi
ditto "$BUILT_APP" "$INSTALLED_APP"

echo "==> 4/6 Verifying the INSTALLED copy launches (the cp -R trap)"
"$INSTALLED_APP/Contents/MacOS/MenuRight" >/tmp/menuright-installed-launch.log 2>&1 &
LAUNCH_PID=$!
sleep 3
if kill -0 "$LAUNCH_PID" 2>/dev/null; then
  echo "    installed copy is running (pid $LAUNCH_PID) — leaving it running"
else
  echo "    FAILED: the installed copy was killed at launch."
  echo "    (this is exactly what cp -R produces; check /tmp/menuright-installed-launch.log)"
  exit 1
fi

echo "==> 5/6 Registering and enabling the Finder extension"
"$LSREGISTER" -f -R -trusted "$INSTALLED_APP"
pluginkit -a "$INSTALLED_APP/Contents/PlugIns/MenuRightFinder.appex" 2>/dev/null || true
pluginkit -e use -i "$EXTENSION_ID"
pkill -f MenuRightFinder 2>/dev/null || true   # Finder relaunches it on demand
sleep 1

echo "==> 6/6 Verifying the system state"
pluginkit -m -i "$EXTENSION_ID" -v
STATE=$(pluginkit -m -i "$EXTENSION_ID" -v | head -1 | cut -c1)
if [ "$STATE" = "+" ]; then
  echo
  echo "OK — extension is enabled and points at the installed copy above."
  echo "Next: open $INSTALLED_APP (it is already running) and check that the window"
  echo "shows 'Finder Extension: Enabled'. If it still says Disabled, click"
  echo "'Manage Finder Extension' and toggle MenuRight there, then relaunch the app."
else
  echo
  echo "WARNING: the extension is not enabled ('$STATE'). Click 'Manage Finder Extension'"
  echo "in the app, or run: pluginkit -e use -i $EXTENSION_ID"
fi
echo
echo "Reminder: quit any other MenuRight instance (e.g. one started by Xcode) so that only"
echo "one app owns the IPC socket:  pgrep -lf 'MenuRight.app/Contents/MacOS/MenuRight'"
