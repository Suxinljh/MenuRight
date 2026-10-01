#!/bin/bash
#
# Build, install and enable the MenuRight Finder extension for local testing.
#
# WHY THIS SCRIPT EXISTS
# ----------------------
# Three traps cost real debugging time (2026-09-30 / 2026-10-01):
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
#  3. Xcode.app and xcodebuild share ONE default DerivedData
#     (~/Library/Developer/Xcode/DerivedData/<project>-<hash>). If both resolve
#     Swift packages at the same time, they delete and re-create the same
#     SourcePackages/checkouts working copies underneath each other, and the
#     loser dies inside `git submodule update` with
#       fatal: Unable to read current working directory: No such file or directory
#       Couldn’t update repository submodules: ... / Could not resolve package
#       dependencies: fatalError
#     SWCompression carries the SWCompression-Test-Files submodule at
#     'Tests/Test Files', which makes it the package that trips over this.
#     Step 1 absorbs it: packages are resolved in a retried step, and the build
#     runs with automatic package resolution off.
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

echo "==> 1/7 Resolving Swift packages (a concurrent Xcode resolve may have to be survived)"
RESOLVE_LOG=/tmp/menuright-install-resolve.log
RESOLVED=0
for attempt in 1 2 3; do
  if xcodebuild -project MenuRight.xcodeproj -scheme MenuRight -configuration "$CONFIG" \
       -resolvePackageDependencies >"$RESOLVE_LOG" 2>&1; then
    RESOLVED=1
    [ "$attempt" -eq 1 ] || echo "    resolved on attempt $attempt — another SwiftPM process had clobbered the checkout"
    break
  fi
  # The first attempt can lose the race described in trap 3 above, but the
  # winner leaves a complete checkout behind, so a retry succeeds.
  echo "    attempt $attempt failed (another SwiftPM process is using this DerivedData); retrying"
  sleep 2
done
if [ "$RESOLVED" != 1 ]; then
  echo "PACKAGE RESOLUTION FAILED — see $RESOLVE_LOG"
  tail -20 "$RESOLVE_LOG"
  echo "If Xcode is open on this project, quit it and run this script again:"
  echo "two SwiftPM processes cannot share one DerivedData."
  exit 1
fi
echo "    packages resolved"

echo "==> 2/7 Building $CONFIG (signed, provisioning updates allowed)"
# -disableAutomaticPackageResolution keeps the build from re-entering the
# checkout/submodule path that step 1 just resolved.
xcodebuild -project MenuRight.xcodeproj -scheme MenuRight -configuration "$CONFIG" \
  -disableAutomaticPackageResolution \
  build -allowProvisioningUpdates >/tmp/menuright-install-build.log 2>&1 \
  || { echo "BUILD FAILED — see /tmp/menuright-install-build.log"; tail -20 /tmp/menuright-install-build.log; exit 1; }

BUILT_DIR=$(xcodebuild -project MenuRight.xcodeproj -scheme MenuRight -configuration "$CONFIG" \
  -disableAutomaticPackageResolution \
  -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $3; exit}')
BUILT_APP="$BUILT_DIR/MenuRight.app"
[ -d "$BUILT_APP" ] || { echo "built app not found at $BUILT_APP"; exit 1; }
echo "    built: $BUILT_APP"

echo "==> 3/7 Checking the built app's own signature"
codesign --verify --deep --strict "$BUILT_APP" || { echo "signature invalid"; exit 1; }
echo "    signature valid"

echo "==> 4/7 Installing with ditto (NOT cp -R) into $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
# Backups go OUTSIDE ~/Applications on purpose: LaunchServices scans that
# directory, and a second copy carrying the same bundle id makes the extension
# enablement ambiguous ("Enabled" for one copy, "Disabled" for the other).
BACKUP_DIR="$HOME/MenuRight-old-copies"
mkdir -p "$BACKUP_DIR"
if [ -d "$INSTALLED_APP" ]; then
  BACKUP="$BACKUP_DIR/MenuRight.app.previous-$(date +%m%d-%H%M%S)"
  mv "$INSTALLED_APP" "$BACKUP"
  echo "    previous copy moved to $BACKUP"
  # Prune this script's own backups, keeping the three most recent.
  ls -1dt "$BACKUP_DIR"/MenuRight.app.previous-* 2>/dev/null | tail -n +4 | while read -r old; do
    rm -rf "$old"
  done
fi
ditto "$BUILT_APP" "$INSTALLED_APP"

echo "==> 5/7 Verifying the INSTALLED copy launches (the cp -R trap)"
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

# Being alive is not enough: the app deliberately refuses to clobber a socket that
# already has a live listener (the H2 protection). If another MenuRight instance
# already owns <App Group>/ipc.sock, this new one is up but unreachable, and the
# extension keeps talking to the other (possibly stale) instance.
SOCKET="$HOME/Library/Group Containers/group.xin.ljhsu.MenuRight/ipc.sock"
if lsof -U -a -p "$LAUNCH_PID" 2>/dev/null | grep -q "ipc.sock"; then
  echo "    this instance owns the IPC socket"
else
  echo "    WARNING: this instance does NOT own $SOCKET"
  echo "    Another MenuRight instance is already listening, so this one is unreachable."
  echo "    Quit the other instance (in Xcode: press Stop), then run this script again:"
  pgrep -lf "MenuRight.app/Contents/MacOS/MenuRight" || true
fi

echo "==> 6/7 Registering and enabling the Finder extension"

# Exactly ONE registration for MenuRight.app. Xcode's own
# `RegisterWithLaunchServices` build step adds its build product on every build,
# and stale copies accumulate; System Settings reads its extension list from
# pluginkit, so several registrations make the toggle point at a different copy
# than the app that is running. The pruning lives in its own script because it is
# also worth running after an Xcode build — see its header for the measurements.
"$(dirname "${BASH_SOURCE[0]}")/prune-launchservices.sh" "$INSTALLED_APP"

"$LSREGISTER" -f -R -trusted "$INSTALLED_APP"
pluginkit -e use -i "$EXTENSION_ID"
pkill -f MenuRightFinder 2>/dev/null || true   # Finder relaunches it on demand
# Replacing the app gives the .appex a new plugin identity, and Finder keeps
# serving its cached plugin list: without restarting Finder the context menu
# silently disappears even though pluginkit reports the plugin as enabled.
# Observed for real: the extension vanished from `pluginkit -m -p
# com.apple.FinderSync` and no menu(for:) was called afterwards.
killall Finder 2>/dev/null || true
sleep 2

echo "==> 7/7 Verifying the system state"
STATE="?"
for _ in 1 2 3 4 5; do
  LINE=$(pluginkit -m -p com.apple.FinderSync -v 2>/dev/null | grep "$EXTENSION_ID" | head -1)
  if [ -n "$LINE" ]; then
    STATE=$(printf '%s' "$LINE" | cut -c1)
    [ "$STATE" = "+" ] && break
  fi
  sleep 1
done
echo "$LINE"
if [ -z "$LINE" ]; then
  echo "    WARNING: the extension is NOT registered as a Finder Sync plugin at all."
  echo "    Check that the appex exists: ls '$INSTALLED_APP/Contents/PlugIns/'"
fi
if [ "$STATE" = "+" ]; then
  echo
  echo "OK — the extension is registered, enabled, and Finder was restarted so it"
  echo "     picks up this build:"
  echo "     $LINE"
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
