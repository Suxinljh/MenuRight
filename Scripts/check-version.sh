#!/bin/bash
#
# Assert every target reports the same version.
#
# The embedded app extensions must match the app exactly, or Xcode's
# `embeddedBinaryValidationUtility` fails the build at the very end — after a
# full build. This checks it in seconds and points at the single source
# (`Config/Version.xcconfig`), so a half-done version bump is caught early.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/MenuRight.xcodeproj"
TARGETS=(MenuRight MenuRightFinder MenuRightCodePreview MenuRightTests)

expected_marketing="$(sed -n 's/^MARKETING_VERSION *= *//p' "$ROOT/Config/Version.xcconfig" | head -1)"
expected_build="$(sed -n 's/^CURRENT_PROJECT_VERSION *= *//p' "$ROOT/Config/Version.xcconfig" | head -1)"
echo "Config/Version.xcconfig: $expected_marketing ($expected_build)"
echo

status=0
for target in "${TARGETS[@]}"; do
  settings="$(xcodebuild -project "$PROJECT" -target "$target" -showBuildSettings 2>/dev/null)"
  marketing="$(printf '%s\n' "$settings" | awk '/ MARKETING_VERSION =/{print $3; exit}')"
  build="$(printf '%s\n' "$settings" | awk '/ CURRENT_PROJECT_VERSION =/{print $3; exit}')"

  if [ "$marketing" = "$expected_marketing" ] && [ "$build" = "$expected_build" ]; then
    printf '  ok    %-24s %s (%s)\n' "$target" "$marketing" "$build"
  else
    printf '  FAIL  %-24s %s (%s)\n' "$target" "${marketing:-?}" "${build:-?}"
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  echo
  echo "A target disagrees with Config/Version.xcconfig."
  echo "A target-level MARKETING_VERSION / CURRENT_PROJECT_VERSION overrides the"
  echo "project-level xcconfig — remove it so there is only one place to edit."
  exit 1
fi

echo
echo "OK — all ${#TARGETS[@]} targets report $expected_marketing ($expected_build)."
