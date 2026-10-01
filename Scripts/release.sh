#!/bin/bash
#
# Package a release and (optionally) publish it to GitHub.
#
# The update checker reads `releases/latest` from GitHub, so a release has to
# exist there for the check to have anything to find. This builds the two
# architecture-specific ZIPs the README promises, then either prints or runs the
# two publishing commands.
#
#   Scripts/release.sh                     # build + zip, print the publish commands
#   Scripts/release.sh --publish           # build + zip + tag + gh release create
#   Scripts/release.sh --notes NOTES.md    # use a file as the release body
#
# The version comes from Config/Version.xcconfig — bump it with Scripts/version.sh
# *before* running this, and commit that bump.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PUBLISH=0
NOTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=1; shift ;;
    --notes) NOTES="${2:-}"; [ -n "$NOTES" ] || { echo "--notes needs a file" >&2; exit 2; }; shift 2 ;;
    *) echo "usage: release.sh [--publish] [--notes <file>]" >&2; exit 2 ;;
  esac
done

VERSION="$(Scripts/version.sh | awk '{print $1}')"
BUILD="$(Scripts/version.sh | sed -n 's/.*(\(.*\)).*/\1/p')"
TAG="v$VERSION"
OUT="$ROOT/build/release"
APP_NAME="MenuRight.app"

echo "==> Releasing MenuRight $VERSION ($BUILD) as $TAG"

# 1. Preflight -----------------------------------------------------------------
if [ -n "$(git status --porcelain)" ]; then
  echo "working tree is not clean — commit or stash first (a release must match a commit)" >&2
  git status --short >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "tag $TAG already exists" >&2
  exit 1
fi
Scripts/check-version.sh >/dev/null || { echo "targets disagree on the version" >&2; exit 1; }
if [ "$PUBLISH" -eq 1 ] && ! command -v gh >/dev/null; then
  echo "--publish needs the GitHub CLI (gh)" >&2
  exit 1
fi

# 2. Build both architectures --------------------------------------------------
# Per-architecture builds rather than one universal binary: the README offers an
# Apple Silicon and an Intel download, and each stays smaller.
mkdir -p "$OUT"
rm -f "$OUT"/MenuRight-"$VERSION"-*.zip

for ARCH in arm64 x86_64; do
  echo "==> Building $ARCH"
  xcodebuild -project MenuRight.xcodeproj -scheme MenuRight -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$ROOT/build/release-$ARCH" \
    ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO \
    build -allowProvisioningUpdates >"$OUT/build-$ARCH.log" 2>&1 \
    || { echo "build failed for $ARCH — see $OUT/build-$ARCH.log" >&2; tail -20 "$OUT/build-$ARCH.log" >&2; exit 1; }

  BUILT="$ROOT/build/release-$ARCH/Build/Products/Release/$APP_NAME"
  [ -d "$BUILT" ] || { echo "built app not found at $BUILT" >&2; exit 1; }
  codesign --verify --deep --strict "$BUILT" || { echo "signature invalid for $ARCH" >&2; exit 1; }

  ZIP="$OUT/MenuRight-$VERSION-$ARCH.zip"
  ditto -c -k --sequesterRsrc --keepParent "$BUILT" "$ZIP"
  echo "    $ZIP  ($(du -h "$ZIP" | cut -f1))"
done

# 3. Publish -------------------------------------------------------------------
if [ -z "$NOTES" ]; then
  NOTES="$OUT/notes-$VERSION.md"
  {
    echo "MenuRight $VERSION (build $BUILD)"
    echo
    echo "<!-- 在这里写更新说明;更新检查会把这段文字显示在提示框里。 -->"
  } >"$NOTES"
  echo "==> Wrote a placeholder release body to $NOTES — edit it before publishing"
fi

TAG_CMD=(git tag -a "$TAG" -m "MenuRight $VERSION")
RELEASE_CMD=(gh release create "$TAG" --title "MenuRight $VERSION" --notes-file "$NOTES" \
  "$OUT/MenuRight-$VERSION-arm64.zip" "$OUT/MenuRight-$VERSION-x86_64.zip")

if [ "$PUBLISH" -eq 0 ]; then
  echo
  echo "==> Dry run. To publish:"
  printf '    %q ' "${TAG_CMD[@]}"; echo
  printf '    %q ' "${RELEASE_CMD[@]}"; echo
  echo
  echo "    (or re-run: Scripts/release.sh --publish --notes $NOTES)"
  exit 0
fi

echo "==> Tagging and publishing"
"${TAG_CMD[@]}"
git push origin "$TAG"
"${RELEASE_CMD[@]}"
echo
echo "==> Published $TAG — the app's update check will now find it."
