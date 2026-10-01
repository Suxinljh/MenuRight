#!/bin/bash
#
# Keep exactly ONE LaunchServices registration for MenuRight.app.
#
#   Scripts/prune-launchservices.sh [keep-path]
#
# Default keep-path: /Applications/MenuRight.app when it exists (the DMG
# install), otherwise ~/Applications/MenuRight.app (the development install).
#
# WHY THIS EXISTS
# ---------------
# Every Xcode build registers its build product with LaunchServices (the built-in
# `RegisterWithLaunchServices` step), and copies pile up in DerivedData, in
# repo-relative build dirs from `-derivedDataPath` runs, and in the install
# script's own backup directory. Measured on 2026-10-01: **22 registered copies,
# 13 of them dangling** — the directory was long gone, the registration was not.
#
# Two real consequences, both observed:
#   * a stale copy whose .appex is not sandboxed is *actively rejected* by
#     pluginkit — `rejecting; Ignoring mis-configured plugin at …: plug-ins must
#     be sandboxed`;
#   * System Settings → Privacy & Security → Extensions reads its list from
#     pluginkit, so with several copies registered the toggle can belong to a
#     different copy than the app that is running, and the extension appears
#     missing or refuses to stay on.
#
# Run it after building in Xcode, or before wondering why the extension state
# looks wrong. `Scripts/install-dev-app.sh` calls it on every install.
set -euo pipefail

# Default keep-path: /Applications/MenuRight.app when it exists (the DMG
# install), otherwise ~/Applications/MenuRight.app (the development install).
#
# Measured 2026-10-01: with both copies on disk and this defaulting to
# ~/Applications, pruning kept the *development* copy registered while the user
# ran the DMG copy from /Applications. Finder then loaded the extension out of
# the other bundle, and every menu action failed peer verification with
# "peer executable path mismatch: got=/Applications/… expected=/Users/…".
if [ -n "${1:-}" ]; then
    KEEP="$1"
elif [ -d "/Applications/MenuRight.app" ]; then
    KEEP="/Applications/MenuRight.app"
else
    KEEP="$HOME/Applications/MenuRight.app"
fi
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

[ -d "$KEEP" ] || { echo "prune-launchservices: no app at $KEEP" >&2; exit 1; }

# Every registered bundle whose path ends in MenuRight.app, minus our copy.
# The `\(.*[^[:space:]]\)` is deliberate: a greedy `\(.*\)` also swallows the
# space before the `(0x…)` address, and the trailing-space path then never
# matches a `MenuRight.app$` filter — the whole thing silently does nothing.
# Read through a process substitution rather than a pipe so the counter below
# survives, and no `mapfile`: macOS ships bash 3.2, which does not have it.
PRUNED=0
while IFS= read -r path; do
    [ -z "$path" ] && continue
    [ "$path" = "$KEEP" ] && continue
    if "$LSREGISTER" -u "$path" >/dev/null 2>&1; then
        PRUNED=$((PRUNED + 1))
        echo "    unregistered $path"
    fi
done < <(
    "$LSREGISTER" -dump 2>/dev/null \
        | sed -n 's/^[[:space:]]*path:[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*(0x[0-9a-f]*)[[:space:]]*$/\1/p' \
        | grep 'MenuRight\.app$' \
        | sort -u || true
)

# Re-assert the one we keep, so it is the newest entry LaunchServices knows.
"$LSREGISTER" -f -R -trusted "$KEEP" >/dev/null 2>&1

if [ "$PRUNED" -eq 0 ]; then
    echo "prune-launchservices: clean (1 registration: $KEEP)"
else
    echo "prune-launchservices: unregistered $PRUNED stale copy/copies, kept $KEEP"
fi
