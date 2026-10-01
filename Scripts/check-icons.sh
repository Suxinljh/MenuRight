#!/usr/bin/env bash
#
# Verifies that every icon the code asks for exists in the committed catalog —
# for all four catalogs — and that no catalog has an orphan left behind by a
# rename.
#
#   Scripts/check-icons.sh
#
# Catalogs:
#   MenuRight/Resources/SidebarIcons.xcassets      sidebar rows (Lucide)
#   MenuRight/Resources/SettingsIcons.xcassets     新建文件 types + 文件权限 actions
#   MenuRight/Resources/BrandAssets.xcassets       sidebar brand lockup + the
#                                                 menu bar status item (the one
#                                                 brand asset drawn as a template)
#
# The Finder context menu carries no *catalog* icons: the only images it draws
# are the 常用项 PNGs the app renders into the App Group at runtime
# (`FavoriteIconProvider`), and the sandboxed extension cannot read an asset
# catalog at all — so there is no fourth catalog to check here.
#
# Why this lives here and not in XCTest: MenuRightTests is a host-less logic test
# bundle, so it cannot see any asset catalog. And a missing asset is not a crash
# — `Image("typo")` renders an empty icon — so "it built" proves nothing.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$PROJECT_DIR" <<'PY'
import json
import os
import re
import sys

root = sys.argv[1]
failures: list[str] = []


def read(relative: str) -> str:
    path = os.path.join(root, relative)
    if not os.path.isfile(path):
        failures.append(f"missing source file: {relative}")
        return ""
    return open(path, encoding="utf-8").read()


def names(pattern: str, relative: str) -> list[str]:
    return re.findall(pattern, read(relative))


# --- what the code references, per catalog ---------------------------------
sidebar = names(r'"(lucide-[a-z0-9-]+)"', "MenuRight/App/Settings/SettingsCategory.swift")

file_types = names(r'return "((?:phosphor|lucide)-[a-z0-9-]+)"', "Shared/Settings/NewFileType.swift")
actions = names(r'return "(lucide-[a-z0-9-]+)"', "Shared/Settings/MenuRightSettings.swift")
settings = file_types + actions

brand = names(r'Image\("(menuright-[a-z-]+)"\)', "MenuRight/App/Settings/SettingsComponents.swift")

# The menu bar mark is brand artwork too, but it is the one brand asset drawn as
# a *template*: the system tints status items with the menu bar's colour, so the
# artwork's own white fills would be invisible on a light menu bar.
status_bar = names(r'assetName = "([a-z0-9-]+)"', "MenuRight/App/StatusMenu/StatusMenuPlan.swift")

# (catalog, names the code asks for, subset of those that must be a template)
CATALOGS = [
    ("MenuRight/Resources/SidebarIcons.xcassets", sorted(set(sidebar)), set(sidebar)),
    ("MenuRight/Resources/SettingsIcons.xcassets", sorted(set(settings)), set(settings)),
    (
        "MenuRight/Resources/BrandAssets.xcassets",
        sorted(set(brand + status_bar)),
        set(status_bar),
    ),
]

for relative, used, template_names in CATALOGS:
    catalog = os.path.join(root, relative)
    label = os.path.basename(relative)

    if not used:
        failures.append(f"{label}: no icon names found in the code")
    duplicates = sorted({n for n in used if used.count(n) > 1})
    if duplicates:
        failures.append(f"{label}: duplicate names in the code: {duplicates}")
    if not os.path.isdir(catalog):
        failures.append(f"{label}: catalog directory missing")
        continue

    for asset in used:
        imageset = os.path.join(catalog, f"{asset}.imageset")
        contents = os.path.join(imageset, "Contents.json")
        svg = os.path.join(imageset, f"{asset}.svg")
        if not os.path.isfile(svg):
            failures.append(f"{label}/{asset}: missing {asset}.svg")
            continue
        metadata = json.load(open(contents, encoding="utf-8"))
        properties = metadata.get("properties", {})
        if properties.get("preserves-vector-representation") is not True:
            failures.append(f"{label}/{asset}: does not preserve vector representation")
        if asset in template_names and properties.get("template-rendering-intent") != "template":
            failures.append(f"{label}/{asset}: must be template rendering (the system tints it)")
        if asset not in template_names and properties.get("template-rendering-intent") == "template":
            failures.append(f"{label}/{asset}: brand artwork must keep its own colours")
        if metadata.get("images", [{}])[0].get("filename") != f"{asset}.svg":
            failures.append(f"{label}/{asset}: Contents.json names the wrong file")
        markup = open(svg, encoding="utf-8").read()
        if "viewBox=" not in markup:
            failures.append(f"{label}/{asset}: svg lost its viewBox")
        if "currentColor" in markup:
            failures.append(f"{label}/{asset}: svg still uses currentColor")
        if not re.search(r"<(path|rect|circle|line|polyline|polygon)\b", markup):
            failures.append(f"{label}/{asset}: svg has no drawable element")

    on_disk = sorted(n for n in os.listdir(catalog) if n.endswith(".imageset"))
    orphans = sorted(set(on_disk) - {f"{a}.imageset" for a in used})
    if orphans:
        failures.append(f"{label}: orphan imagesets (removed from the code): {orphans}")

# --- catalogs must match what the fetch scripts download -------------------
def fetch_names(relative: str, pattern: str) -> set[str]:
    # MULTILINE: the lists are one entry per line inside a bash array.
    return set(re.findall(pattern, read(relative), re.MULTILINE))


fetch_sidebar = fetch_names("Scripts/fetch-sidebar-icons.sh", r"^\s*([a-z0-9-]+)\s+#")
fetch_settings = fetch_names("Scripts/fetch-setting-icons.sh", r'"((?:phosphor|lucide)-[a-z0-9-]+):')

expected_sidebar = {f"lucide-{n}" for n in fetch_sidebar}
if expected_sidebar != set(sidebar):
    failures.append(
        "fetch-sidebar-icons.sh and SettingsCategory disagree: "
        f"{sorted(expected_sidebar ^ set(sidebar))}"
    )

settings_referenced = set(file_types) | set(actions)
if fetch_settings != settings_referenced:
    failures.append(
        "fetch-setting-icons.sh and the code disagree: "
        f"{sorted(fetch_settings ^ settings_referenced)}"
    )

# --- report ---------------------------------------------------------------
if failures:
    print("check-icons: FAIL")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

counts = ", ".join(f"{os.path.basename(path).replace('.xcassets', '')}={len(used)}" for path, used, _ in CATALOGS)
print(f"check-icons: PASS ({counts})")
PY
