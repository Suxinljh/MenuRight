#!/usr/bin/env bash
#
# Fetches the icons used *inside* the settings panes (New File rows, File
# Permission rows) and regenerates the catalog they render from.
#
# The Finder context menu deliberately carries no icons: Finder draws extension
# menu item images as-is, so they never pick up the highlighted (white) or
# disabled (grey) menu text colour, and a menu whose items carry images also
# reserves an icon column. See README "Settings and right-click icons".
#
#   Scripts/fetch-setting-icons.sh
#
# Two upstream sets, both pinned:
#   - Phosphor Icons (MIT)   — the file-type icons in 新建文件
#   - Lucide (ISC)           — JSON plus every right-click action icon
#
# Why a manual script rather than a build phase: this project builds with
# ENABLE_USER_SCRIPT_SANDBOXING = YES, so build phases have no network. The
# generated catalogs are committed, which also pins the exact artwork.
#
# Licence texts are downloaded into MenuRight/Resources/Third-Party-Notices/ and
# ship inside the app bundle (通用设置 → 关于 → 开源许可).
set -euo pipefail

PHOSPHOR_VERSION="${PHOSPHOR_VERSION:-2.1.1}"
LUCIDE_TAG="${LUCIDE_TAG:-1.49.0}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS_CATALOG="$PROJECT_DIR/MenuRight/Resources/SettingsIcons.xcassets"
NOTICES="$PROJECT_DIR/MenuRight/Resources/Third-Party-Notices"
PHOSPHOR_BASE="https://unpkg.com/@phosphor-icons/core@$PHOSPHOR_VERSION/assets/regular"
LUCIDE_BASE="https://raw.githubusercontent.com/lucide-icons/lucide/$LUCIDE_TAG/icons"

# File-type icons for 新建文件: "<asset-name>:<phosphor-name>[:lucide]".
FILE_TYPES=(
  "phosphor-file-txt:file-txt"
  "phosphor-file-md:file-md"
  "phosphor-file-html:file-html"
  "phosphor-file-css:file-css"
  "phosphor-file-js:file-js"
  "phosphor-file-doc:file-doc"
  "phosphor-file-xls:file-xls"
  "phosphor-file-ppt:file-ppt"
  "phosphor-file:file"
  "phosphor-table:table"
  "phosphor-lectern:lectern"
  "lucide-file-braces-corner:file-braces-corner:lucide"
)

# Right-click *action* icons, shown in the 文件权限 pane. "Open Terminal" uses
# `square-chevron-right`; "Copy Name" uses `copy`.
MENU_ICONS=(
  "lucide-square-chevron-right:square-chevron-right"
  "lucide-copy:copy"
  "lucide-spline-pointer:spline-pointer"
  "lucide-file-plus-corner:file-plus-corner"
  "lucide-folder-closed:folder-closed"
  "lucide-clipboard:clipboard"
)

# Actions with no icon assigned yet get a semantically matching Lucide icon so
# the list does not look half-finished.
EXTRA_ACTION_ICONS=(
  "lucide-square-arrow-out-up-right:square-arrow-out-up-right"
  "lucide-link:link"
  "lucide-lock-keyhole:lock-keyhole"
  "lucide-file-archive:file-archive"
  "lucide-star:star"
)

mkdir -p "$NOTICES" "$SETTINGS_CATALOG"
printf '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n' > "$SETTINGS_CATALOG/Contents.json"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Normalises an upstream SVG into a template asset:
#   - `currentColor` becomes an explicit black (template rendering only uses
#     alpha, but an explicit colour removes any dependence on currentColor
#     support in the rasteriser);
#   - a fixed size is removed from the ROOT tag only, so the viewBox drives
#     geometry (`app-window-mac` lost its window body to a file-wide regex once);
#   - the drawing itself must survive byte-for-byte otherwise.
normalise() {
  local source="$1" destination="$2" label="$3"
  python3 - "$source" "$destination" "$label" <<'PY'
import re
import sys

source, destination, label = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(source, encoding="utf-8").read()

if "viewBox=" not in text:
    sys.exit(f"{label}: no viewBox")
if not re.search(r"<(path|rect|circle|line|ellipse|polyline|polygon)\b", text):
    sys.exit(f"{label}: no drawable element")

root = re.match(r"\s*<svg\b[^>]*>", text)
if root is None:
    sys.exit(f"{label}: no opening <svg> tag")
root_tag = root.group(0)
body = text[len(root_tag):]

new_root = re.sub(r'\s(?:width|height)="[0-9.]+"', "", root_tag)
expected_body = body.replace("currentColor", "#000000")
normalised = new_root + body
normalised = re.sub(r"[ \t]+\n", "\n", normalised)
normalised = re.sub(r"\n{2,}", "\n", normalised)
normalised = normalised.replace("currentColor", "#000000")
final_root = re.match(r"\s*<svg\b[^>]*>", normalised).group(0)
if normalised[len(final_root):] != expected_body:
    sys.exit(f"{label}: normalisation modified the drawing, not just the root tag")
if not normalised.endswith("\n"):
    normalised += "\n"
open(destination, "w", encoding="utf-8").write(normalised)
PY
}

imageset() {
  local catalog="$1" asset="$2" svg="$3" name="$4"
  local set="$catalog/$asset.imageset"
  mkdir -p "$set"
  cp "$svg" "$set/$asset.svg"
  cat > "$set/Contents.json" <<JSON
{
  "images" : [
    {
      "filename" : "$asset.svg",
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
}

fetch_phosphor() {  # <name> <destination>
  local name="$1" destination="$2"
  local http
  http="$(curl -sSL --max-time 30 -o "$destination" -w "%{http_code}" "$PHOSPHOR_BASE/$name.svg")"
  [ "$http" = "200" ] || { echo "FAIL: phosphor/$name -> HTTP $http" >&2; exit 1; }
}

fetch_lucide() {  # <name> <destination>
  local name="$1" destination="$2"
  local http
  http="$(curl -sSL --max-time 30 -o "$destination" -w "%{http_code}" "$LUCIDE_BASE/$name.svg")"
  [ "$http" = "200" ] || { echo "FAIL: lucide/$name -> HTTP $http" >&2; exit 1; }
}

echo "==> Phosphor $PHOSPHOR_VERSION + Lucide $LUCIDE_TAG"
for entry in "${FILE_TYPES[@]}"; do
  IFS=":" read -r asset name kind <<< "$entry"
  source_file="$TMP/$asset.svg"
  if [ "${kind:-}" = "lucide" ]; then
    fetch_lucide "$name" "$source_file"
  else
    fetch_phosphor "$name" "$source_file"
  fi
  normalise "$source_file" "$TMP/$asset.norm.svg" "$asset"
  imageset "$SETTINGS_CATALOG" "$asset" "$TMP/$asset.norm.svg" "$name"
  echo "    OK  settings/$asset"
done

for entry in "${MENU_ICONS[@]}" "${EXTRA_ACTION_ICONS[@]}"; do
  IFS=":" read -r asset name <<< "$entry"
  fetch_lucide "$name" "$TMP/$asset.svg"
  normalise "$TMP/$asset.svg" "$TMP/$asset.norm.svg" "$asset"
  imageset "$SETTINGS_CATALOG" "$asset" "$TMP/$asset.norm.svg" "$name"
  echo "    OK  settings/$asset"
done

curl -sSL --max-time 30 -o "$NOTICES/phosphor-LICENSE.txt" \
  "https://unpkg.com/@phosphor-icons/core@$PHOSPHOR_VERSION/LICENSE"
head -1 "$NOTICES/phosphor-LICENSE.txt" | grep -qi "MIT License" \
  || { echo "FAIL: downloaded Phosphor LICENSE is not MIT" >&2; exit 1; }

echo "==> done: ${#FILE_TYPES[@]} file-type icons, $((${#MENU_ICONS[@]} + ${#EXTRA_ACTION_ICONS[@]})) action icons"
