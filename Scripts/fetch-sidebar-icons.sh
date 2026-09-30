#!/usr/bin/env bash
#
# Fetches the sidebar icons from Lucide and regenerates the vector asset
# catalog the app renders them from.
#
#   Scripts/fetch-sidebar-icons.sh
#
# Why a manual script instead of a build phase: this project builds with
# ENABLE_USER_SCRIPT_SANDBOXING = YES, so a build phase has no network access.
# The generated .xcassets is committed, which also makes the exact icon shapes
# reproducible from the pinned tag below.
#
# Licence: Lucide is ISC. The script also downloads the upstream LICENSE into
# MenuRight/Resources/Third-Party-Notices/, which ships in the app bundle (the
# Settings window shows it under 通用设置 → 关于 → 开源许可).
#
# Override the pin when bumping the icon set:
#   LUCIDE_TAG=1.50.0 Scripts/fetch-sidebar-icons.sh
set -euo pipefail

# Tag form matters: Lucide tags are "1.49.0", never "v1.49.0".
LUCIDE_TAG="${LUCIDE_TAG:-1.49.0}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$PROJECT_DIR/MenuRight/Resources/SidebarIcons.xcassets"
NOTICES="$PROJECT_DIR/MenuRight/Resources/Third-Party-Notices"
BASE="https://raw.githubusercontent.com/lucide-icons/lucide/$LUCIDE_TAG"

# One entry per SettingsCategory, in sidebar order. Names must exist at
# LUCIDE_TAG: check with Scripts/check-icons.sh before shipping.
ICONS=(
  file-key          # 文件权限
  folder-key        # 文件夹权限
  bolt              # 通用设置
  file-plus-corner  # 新建文件
  folders           # 常用文件夹
  app-window-mac    # 常用软件
  globe-code        # 常用网页
  palette           # 代码主题
  file-archive      # 解压缩管理
)

mkdir -p "$CATALOG" "$NOTICES"
cat > "$CATALOG/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Lucide $LUCIDE_TAG → $CATALOG"
for name in "${ICONS[@]}"; do
  url="$BASE/icons/$name.svg"
  http="$(curl -sS --max-time 30 -o "$TMP/$name.svg" -w "%{http_code}" "$url")"
  if [ "$http" != "200" ]; then
    echo "FAIL: $name.svg -> HTTP $http ($url)" >&2
    echo "      Lucide renames icons between releases; pick a name that exists at $LUCIDE_TAG." >&2
    exit 1
  fi

  imageset="$CATALOG/lucide-$name.imageset"
  mkdir -p "$imageset"

  # Normalise the SVG: the catalog renders it as a template (alpha only), so the
  # stroke colour is cosmetic — but an explicit colour removes any dependence on
  # `currentColor` support in the rasteriser. The fixed 24x24 size is dropped so
  # the vector scales to the frame the view gives it; the viewBox keeps geometry.
  #
  # The size attributes must be removed from the ROOT TAG ONLY. `app-window-mac`
  # draws its window body as `<rect width="20" height="16" …/>`; a file-wide
  # regex silently deleted that, and the icon rendered as three dots.
  python3 - "$TMP/$name.svg" "$imageset/lucide-$name.svg" "$name" <<'PY'
import re
import sys

source, destination, name = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(source, encoding="utf-8").read()

if 'viewBox="0 0 24 24"' not in text:
    sys.exit(f"unexpected SVG geometry for {name}: no 24x24 viewBox")
if not re.search(r"<(path|rect|circle|line|ellipse|polyline|polygon)\b", text):
    sys.exit(f"unexpected SVG for {name}: no drawable element")

root = re.match(r"\s*<svg\b[^>]*>", text)
if root is None:
    sys.exit(f"unexpected SVG for {name}: no opening <svg> tag")

root_tag = root.group(0)
body = text[len(root_tag):]
size_attributes = re.compile(r'\s(?:width|height)="\d+"')
new_root_tag = size_attributes.sub("", root_tag)
if size_attributes.search(new_root_tag):
    sys.exit(f"{name}: root <svg> kept a fixed size")

# The body must survive untouched apart from the colour substitution. Anything
# else means a normalisation step reached into a drawable element.
expected_body = body.replace("currentColor", "#000000")
normalised = new_root_tag + body
normalised = re.sub(r"[ \t]+\n", "\n", normalised)   # drops the emptied lines
normalised = re.sub(r"\n{2,}", "\n", normalised)
normalised = normalised.replace("currentColor", "#000000")
final_root_tag = re.match(r"\s*<svg\b[^>]*>", normalised).group(0)
if normalised[len(final_root_tag):] != expected_body:
    sys.exit(f"{name}: normalisation modified the drawing, not just the root tag")

if not normalised.endswith("\n"):
    normalised += "\n"
open(destination, "w", encoding="utf-8").write(normalised)
PY

  cat > "$imageset/Contents.json" <<JSON
{
  "images" : [
    {
      "filename" : "lucide-$name.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true,
    "template-rendering-intent" : "template"
  }
}
JSON
  echo "    OK  lucide-$name.imageset"
done

curl -sS --max-time 30 -o "$NOTICES/lucide-LICENSE.txt" "$BASE/LICENSE"
head -1 "$NOTICES/lucide-LICENSE.txt" | grep -q "ISC License" \
  || { echo "FAIL: downloaded LICENSE does not start with 'ISC License'" >&2; exit 1; }

echo "==> done: ${#ICONS[@]} iconsets, license -> ${NOTICES#"$PROJECT_DIR"/}/lucide-LICENSE.txt"
