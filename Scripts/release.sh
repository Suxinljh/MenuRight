#!/bin/bash
#
# Package a release and (optionally) publish it to GitHub.
#
# The update checker reads `releases/latest` from GitHub, so a release has to
# exist there for the check to have anything to find. This builds what the
# README promises for each architecture — a `.dmg` installer plus a `.zip` — and
# a source ZIP of the tagged commit, then either prints or runs the publishing
# commands.
#
#   Scripts/release.sh                     # build + dmg + zip, print the publish commands
#   Scripts/release.sh --publish           # build + package + tag + gh release create
#   Scripts/release.sh --notes NOTES.md    # use a file as the release body
#
# The release body always gets a generated "构建与验证说明" appendix: the machine
# running this script can only *execute* its own architecture, so the other
# architecture's artifacts are cross-compiled and must be labelled untested
# rather than quietly shipped as if they had been run.
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

# The host can execute one architecture only. Everything built for the other one
# is cross-compiled: it can be checked statically (arch, signature, bundle
# layout) but never launched here, so the release body says exactly that.
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64) TESTED_ARCH=arm64; UNTESTED_ARCH=x86_64 ;;
  *)     TESTED_ARCH=x86_64; UNTESTED_ARCH=arm64 ;;
esac

pretty_arch() {
  case "$1" in
    arm64)  echo "Apple Silicon (arm64)" ;;
    x86_64) echo "Intel (x86_64)" ;;
    *)      echo "$1" ;;
  esac
}

# Installer image: the app next to a /Applications symlink, so the usual
# drag-to-install works. `ditto` (not `cp`) keeps the bundle's extended
# attributes, which the code signature seal covers.
make_dmg() {
  local app="$1" dmg="$2" volname="$3" stage
  stage="$(mktemp -d "${TMPDIR:-/tmp}/menuright-dmg.XXXXXX")"
  ditto "$app" "$stage/$(basename "$app")"
  ln -s /Applications "$stage/Applications"
  rm -f "$dmg"
  hdiutil create -volname "$volname" -srcfolder "$stage" -ov -format UDZO -quiet "$dmg"
  rm -rf "$stage"
  hdiutil verify "$dmg" >/dev/null 2>&1 \
    || { echo "dmg failed its checksum verification: $dmg" >&2; exit 1; }
}

# 2. Build both architectures --------------------------------------------------
# Per-architecture builds rather than one universal binary: the README offers an
# Apple Silicon and an Intel download, and each stays smaller.
mkdir -p "$OUT"
rm -f "$OUT"/MenuRight-"$VERSION"-*.zip "$OUT"/MenuRight-"$VERSION"-*.dmg \
      "$OUT"/SHA256SUMS.txt "$OUT"/body-"$VERSION".md

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

  DMG="$OUT/MenuRight-$VERSION-$ARCH.dmg"
  make_dmg "$BUILT" "$DMG" "MenuRight $VERSION"
  echo "    $DMG  ($(du -h "$DMG" | cut -f1))"

  if [ "$ARCH" = "$UNTESTED_ARCH" ]; then
    echo "    note: $ARCH is cross-compiled on $HOST_ARCH — static checks only, never executed"
  fi
done

# Source ZIP of exactly the commit being released (no build products, no
# untracked files). `git archive` reads HEAD, which preflight proved is clean.
SOURCE_ZIP="$OUT/MenuRight-$VERSION-source.zip"
git archive --format=zip --prefix="MenuRight-$VERSION/" -o "$SOURCE_ZIP" HEAD
echo "    $SOURCE_ZIP  ($(du -h "$SOURCE_ZIP" | cut -f1))"

( cd "$OUT" && shasum -a 256 MenuRight-"$VERSION"-*.dmg MenuRight-"$VERSION"-*.zip >SHA256SUMS.txt )
echo "    $OUT/SHA256SUMS.txt"

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

# The appendix is generated, not hand-written, so a release can never claim more
# testing than the release machine actually performed.
#
# NB: /bin/bash on macOS is 3.2, which folds multibyte bytes into a variable
# name — write `${HOST_ARCH}` (braced) whenever a Chinese character follows a
# variable, or the expansion is parsed as an unbound name.
DISCLOSURE="$OUT/disclosure-$VERSION.md"
{
  echo
  echo "---"
  echo
  echo "## 构建与验证说明"
  echo
  echo "- \`MenuRight-$VERSION-$TESTED_ARCH\` —— $(pretty_arch "$TESTED_ARCH")：在发布机上实测（该架构的 XCTest、产物验签、DMG 挂载与包结构检查）。"
  echo "- \`MenuRight-${VERSION}-${UNTESTED_ARCH}\` —— $(pretty_arch "$UNTESTED_ARCH")：**未经测试**。发布机是 ${HOST_ARCH}，无法执行该架构的二进制；只做了静态检查（lipo 架构、codesign 验签、DMG 挂载与包结构），**没有真正启动过**。"
  echo "- 本项目未做公证（notarization），也没有 Developer ID 证书：产物用 Apple Development 签名并内嵌 Mac Team Provisioning Profile（仅列出开发者的 Mac）。首次打开若被 Gatekeeper 拦截，请在「访达」里右键 App →「打开」；若在别的 Mac 上因预置描述文件受限而无法启动，请从源码构建（见 \`MenuRight-$VERSION-source.zip\`）。"
  echo "- 产物校验和见 \`SHA256SUMS.txt\`。"
  echo
  echo "安装：打开 DMG，把 MenuRight.app 拖进「应用程序」，然后按 README 的首次使用引导启用 Finder 扩展。"
} >"$DISCLOSURE"

BODY="$OUT/body-$VERSION.md"
{ cat "$NOTES"; cat "$DISCLOSURE"; } >"$BODY"

TAG_CMD=(git tag -a "$TAG" -m "MenuRight $VERSION")
RELEASE_CMD=(gh release create "$TAG" --title "MenuRight $VERSION" --notes-file "$BODY" \
  "$OUT/MenuRight-$VERSION-arm64.dmg" "$OUT/MenuRight-$VERSION-x86_64.dmg" \
  "$OUT/MenuRight-$VERSION-arm64.zip" "$OUT/MenuRight-$VERSION-x86_64.zip" \
  "$SOURCE_ZIP" "$OUT/SHA256SUMS.txt")

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
