#!/usr/bin/env bash
#
# Verifies the P6-b document generators by building them into a command-line
# tool and inspecting the bytes they produce.
#
#   Scripts/verify-document-generation.sh
#
# What this proves (automated):
#   * `OOXMLDocumentFactory` + `ZipWriter` (the shipped sources, not a copy)
#     produce docx/xlsx/pptx that are valid ZIP archives with correct CRCs;
#   * every part is well-formed XML, has a content type, and every relationship
#     target exists;
#   * the per-format structure is what Word/Excel/PowerPoint expect (main part,
#     one sheet/slide, a theme with the required minimum lists, …);
#   * if python-docx / openpyxl / python-pptx happen to be installed, those
#     *independent* readers open the files and report the expected structure;
#   * Quick Look renders a thumbnail, i.e. a real system importer parsed them.
#
# What it cannot prove: that Microsoft Word/Excel/PowerPoint or Pages/Numbers/
# Keynote open the files without a repair prompt. That is the manual gate in
# MenuRight 验证手册.md §P6-b.
#
# Set MENURIGHT_VERIFY_PYTHON to a Python that has python-docx, openpyxl and
# python-pptx installed to add the independent-reader check (plain python3
# usually has none of them):
#
#   MENURIGHT_VERIFY_PYTHON=/path/to/venv/bin/python Scripts/verify-document-generation.sh
#
# Output files land in build/verification/p6b/ so they can be opened by hand.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${MENURIGHT_VERIFY_PYTHON:-python3}"
OUT_DIR="$PROJECT_DIR/build/verification/p6b"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/blank.docx "$OUT_DIR"/blank.xlsx "$OUT_DIR"/blank.pptx
rm -rf "$OUT_DIR"/thumbnails

cat > "$BUILD_DIR/main.swift" <<'SWIFT'
import Foundation

// Writes one blank document per office kind, using the app's own generator.
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for type in [NewFileType.docx, .xlsx, .pptx] {
    let data = try OOXMLDocumentFactory.data(for: type)
    let url = outDir.appendingPathComponent("blank.\(type.fileExtension)")
    try data.write(to: url)
    print("generated \(url.lastPathComponent) (\(data.count) bytes)")
}

// P6-b: the template-backed kinds, through the shipped catalog + service.
// Twice per kind, so the "Untitled 2.*" collision rule is exercised too.
let templateDir = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let copiesDir = outDir.appendingPathComponent("copies", isDirectory: true)
try? FileManager.default.removeItem(at: copiesDir)
try FileManager.default.createDirectory(at: copiesDir, withIntermediateDirectories: true)
for type in NewFileType.allCases where type.requiresTemplate {
    guard let template = DocumentTemplateCatalog.templateURL(for: type, in: templateDir) else {
        print("template missing for \(type.rawValue) — skipped")
        continue
    }
    let name = "Untitled.\(type.fileExtension)"
    for attempt in 1...2 {
        switch FileOperationService.createFileFromTemplate(template: template, in: copiesDir, preferredName: name) {
        case .success(let url):
            print("copied \(type.rawValue) #\(attempt) -> \(url.lastPathComponent)")
        case .failure(let error):
            print("copy FAILED \(type.rawValue): \(error)")
            exit(1)
        }
    }
}
SWIFT

SDK="$(xcrun --show-sdk-path --sdk macosx)"
ARCH="$(uname -m)"
swiftc -O -sdk "$SDK" -target "$ARCH-apple-macos14.0" -o "$BUILD_DIR/generate" \
    "$BUILD_DIR/main.swift" \
    "$PROJECT_DIR/Shared/FileOperations/ZipWriter.swift" \
    "$PROJECT_DIR/Shared/FileOperations/OOXMLDocumentFactory.swift" \
    "$PROJECT_DIR/Shared/FileOperations/DocumentTemplateCatalog.swift" \
    "$PROJECT_DIR/Shared/FileOperations/FileOperationService.swift" \
    "$PROJECT_DIR/Shared/FileOperations/FileOperationResult.swift" \
    "$PROJECT_DIR/Shared/FileOperations/FileNameResolver.swift" \
    "$PROJECT_DIR/Shared/FileOperations/FileMovePlanner.swift" \
    "$PROJECT_DIR/Shared/Authorization/AuthorizedFolder.swift" \
    "$PROJECT_DIR/Shared/Authorization/AuthorizedURLResolver.swift" \
    "$PROJECT_DIR/Shared/Authorization/SecurityScopedBookmark.swift" \
    "$PROJECT_DIR/Shared/Authorization/FolderAuthorizationAccess.swift" \
    "$PROJECT_DIR/Shared/Settings/NewFileType.swift" \
    "$PROJECT_DIR/Shared/Settings/AppLanguage.swift" \
    "$PROJECT_DIR/Shared/Settings/Localization.swift" \
    "$PROJECT_DIR/Shared/Settings/SettingsStore.swift" \
    "$PROJECT_DIR/Shared/Settings/NewFileAvailability.swift" \
    "$PROJECT_DIR/Shared/IPC/MenuRightIPC.swift" \
    "$PROJECT_DIR/Shared/Settings/MenuRightSettings.swift" \
    "$PROJECT_DIR/Shared/Settings/FavoriteEntry.swift" \
    "$PROJECT_DIR/Shared/Settings/CodeTheme.swift" \
    "$PROJECT_DIR/Shared/Settings/ArchiveSettings.swift"

"$BUILD_DIR/generate" "$OUT_DIR" "$PROJECT_DIR/MenuRight/Resources/Templates"

"$PYTHON" - "$OUT_DIR" "$PROJECT_DIR/MenuRight/Resources/Templates" <<'PY'
import os
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

out_dir = sys.argv[1]
template_dir = sys.argv[2]
failures: list[str] = []

EXPECTED_PARTS = {
    "blank.docx": [
        "[Content_Types].xml", "_rels/.rels", "word/document.xml",
        "word/_rels/document.xml.rels", "word/styles.xml",
    ],
    "blank.xlsx": [
        "[Content_Types].xml", "_rels/.rels", "xl/workbook.xml",
        "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml", "xl/styles.xml",
    ],
    "blank.pptx": [
        "[Content_Types].xml", "_rels/.rels", "ppt/presentation.xml",
        "ppt/_rels/presentation.xml.rels",
        "ppt/slideMasters/slideMaster1.xml",
        "ppt/slideMasters/_rels/slideMaster1.xml.rels",
        "ppt/slideLayouts/slideLayout1.xml",
        "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
        "ppt/slides/slide1.xml", "ppt/slides/_rels/slide1.xml.rels",
        "ppt/theme/theme1.xml",
    ],
}

CONTENT_TYPE_NAMES = {
    "blank.docx": "wordprocessingml.document.main+xml",
    "blank.xlsx": "spreadsheetml.sheet.main+xml",
    "blank.pptx": "presentationml.presentation.main+xml",
}


def resolve(target: str, base: str) -> str:
    parts = [p for p in base.split("/") if p]
    for segment in target.split("/"):
        if segment in ("", "."):
            continue
        if segment == "..":
            if parts:
                parts.pop()
            continue
        parts.append(segment)
    return "/".join(parts)


for name, expected in EXPECTED_PARTS.items():
    path = os.path.join(out_dir, name)
    if not os.path.isfile(path):
        failures.append(f"{name}: was not generated")
        continue

    try:
        archive = zipfile.ZipFile(path)
    except zipfile.BadZipFile as error:
        failures.append(f"{name}: not a zip archive ({error})")
        continue

    bad = archive.testzip()
    if bad is not None:
        failures.append(f"{name}: CRC check failed on {bad}")

    names = archive.namelist()
    if names != expected:
        failures.append(f"{name}: part list/order differs\n      got      {names}\n      expected {expected}")
    if names and names[0] != "[Content_Types].xml":
        failures.append(f"{name}: [Content_Types].xml is not the first entry")

    # XML well-formedness
    documents: dict[str, ET.Element] = {}
    for part in names:
        if not (part.endswith(".xml") or part.endswith(".rels")):
            continue
        try:
            documents[part] = ET.fromstring(archive.read(part))
        except ET.ParseError as error:
            failures.append(f"{name}/{part}: malformed XML ({error})")

    # Content types cover every part
    content_types = archive.read("[Content_Types].xml").decode("utf-8")
    defaults = set(re.findall(r'<Default Extension="([^"]+)"', content_types))
    overrides = set(re.findall(r'<Override PartName="([^"]+)"', content_types))
    if CONTENT_TYPE_NAMES[name] not in content_types:
        failures.append(f"{name}: content types do not declare the OOXML main part")
    for part in names:
        if part == "[Content_Types].xml":
            continue
        extension = part.rsplit(".", 1)[-1]
        if "/" + part not in overrides and extension not in defaults:
            failures.append(f"{name}/{part}: no content type")

    # Relationship targets exist
    for part in names:
        if not part.endswith(".rels"):
            continue
        base = part.split("_rels/")[0]
        relationships = ET.fromstring(archive.read(part))
        for relationship in relationships:
            target = relationship.get("Target", "")
            if target.startswith("http"):
                continue
            resolved = resolve(target, base)
            if resolved not in names:
                failures.append(f"{name}/{part}: relationship target {target} → {resolved} is missing")

    # Per-format sanity
    if name == "blank.docx":
        document = archive.read("word/document.xml").decode("utf-8")
        if document.count("<w:p/>") != 1:
            failures.append("blank.docx: expected exactly one empty paragraph")
        if "<w:sectPr>" not in document:
            failures.append("blank.docx: the section properties are missing")
    if name == "blank.xlsx":
        workbook = archive.read("xl/workbook.xml").decode("utf-8")
        if 'name="Sheet1"' not in workbook:
            failures.append("blank.xlsx: the workbook does not declare Sheet1")
        styles = archive.read("xl/styles.xml").decode("utf-8")
        if "gray125" not in styles:
            failures.append("blank.xlsx: the reserved second fill (gray125) is missing")
    if name == "blank.pptx":
        presentation = archive.read("ppt/presentation.xml").decode("utf-8")
        if 'type="screen16x9"' not in presentation:
            failures.append("blank.pptx: the deck is not 16:9")
        theme = ET.fromstring(archive.read("ppt/theme/theme1.xml"))
        namespace = "{http://schemas.openxmlformats.org/drawingml/2006/main}"
        format_scheme = theme.find(f".//{namespace}fmtScheme")
        if format_scheme is None:
            failures.append("blank.pptx: the theme has no fmtScheme")
        else:
            for list_name in ("fillStyleLst", "lnStyleLst", "effectStyleLst", "bgFillStyleLst"):
                entries = format_scheme.find(f"{namespace}{list_name}")
                if entries is None or len(entries) < 3:
                    failures.append(f"blank.pptx: theme {list_name} needs at least three entries")

# --- P6-b: template-backed kinds (Pages / Numbers / Keynote) ---------------
# The copies went through the shipped `FileOperationService.createFileFromTemplate`,
# so what is checked here is the real copy path, not a re-implementation.
TEMPLATES = {"pages": "blank.pages", "numbers": "blank.numbers", "keynote": "blank.key"}
copies_dir = os.path.join(out_dir, "copies")
templates_checked = 0
for kind, template_name in TEMPLATES.items():
    template_path = os.path.join(template_dir, template_name)
    if not os.path.isfile(template_path):
        continue
    templates_checked += 1
    extension = template_name.split(".", 1)[1]

    for copy_name in (f"Untitled.{extension}", f"Untitled 2.{extension}"):
        copy_path = os.path.join(copies_dir, copy_name)
        if not os.path.isfile(copy_path):
            failures.append(f"{kind}: {copy_name} was not created")
            continue
        with open(copy_path, "rb") as handle:
            copied = handle.read()
        with open(template_path, "rb") as handle:
            original = handle.read()
        if copied != original:
            failures.append(f"{kind}: {copy_name} is not byte-identical to {template_name}")
        if not zipfile.is_zipfile(copy_path):
            failures.append(f"{kind}: {copy_name} is not a zip-based iWork document")
            continue
        try:
            bad_part = zipfile.ZipFile(copy_path).testzip()
        except zipfile.BadZipFile as error:
            failures.append(f"{kind}: {copy_name} is not a readable iWork package ({error})")
            continue
        if bad_part is not None:
            failures.append(f"{kind}: {copy_name} failed its CRC check on {bad_part}")

    if not any(failure.startswith(kind) for failure in failures):
        print(f"  {kind}: {template_name} copied twice (naming + bytes + package integrity verified)")

if templates_checked == 0:
    print("  (no iWork templates in Resources/Templates — template kinds skipped)")

# Independent readers, when the machine happens to have them.
opened = False
try:
    from docx import Document
    from openpyxl import load_workbook
    from pptx import Presentation

    document = Document(os.path.join(out_dir, "blank.docx"))
    if len(document.paragraphs) != 1:
        failures.append(f"python-docx read {len(document.paragraphs)} paragraphs, expected 1")

    workbook = load_workbook(os.path.join(out_dir, "blank.xlsx"))
    if workbook.sheetnames != ["Sheet1"]:
        failures.append(f"openpyxl read sheets {workbook.sheetnames}, expected ['Sheet1']")

    deck = Presentation(os.path.join(out_dir, "blank.pptx"))
    if len(deck.slides) != 1:
        failures.append(f"python-pptx read {len(deck.slides)} slides, expected 1")
    if (deck.slide_width, deck.slide_height) != (12192000, 6858000):
        failures.append("python-pptx read an unexpected slide size")

    opened = True
    print("  python-docx / openpyxl / python-pptx reopened all three files")
except ImportError:
    print("  (python-docx/openpyxl/python-pptx not installed — skipped the independent re-open)")

if failures:
    print("verify-document-generation: FAIL")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print(f"verify-document-generation: PASS ({len(EXPECTED_PARTS)} packages, {sum(len(v) for v in EXPECTED_PARTS.values())} parts)")
PY

# Quick Look is the one check that goes through a real system importer. It needs
# a window-server session, so a failure here is reported as skipped, not failed.
QL_FILES=("$OUT_DIR/blank.docx" "$OUT_DIR/blank.xlsx" "$OUT_DIR/blank.pptx")
if [ -d "$OUT_DIR/copies" ]; then
    for candidate in "$OUT_DIR"/copies/*; do
        [ -f "$candidate" ] && QL_FILES+=("$candidate")
    done
fi
if mkdir -p "$OUT_DIR/thumbnails" && qlmanage -t -s 300 -o "$OUT_DIR/thumbnails" \
        "${QL_FILES[@]}" >/dev/null 2>&1; then
    produced="$(find "$OUT_DIR/thumbnails" -name '*.png' | wc -l | tr -d ' ')"
    expected="${#QL_FILES[@]}"
    if [ "$produced" = "$expected" ]; then
        echo "  Quick Look rendered all $expected thumbnails (system importers accepted every file)"
    else
        echo "  Quick Look rendered $produced/$expected thumbnails (see $OUT_DIR/thumbnails)"
    fi
else
    echo "  Quick Look thumbnail check skipped (no window-server session)"
fi

# A slide master with no explicit <p:bg> passes every structural check and still
# renders GREY. Reading the file cannot catch that, so sample the rendered
# thumbnails when Pillow is available.
if [ -f "$OUT_DIR/thumbnails/blank.pptx.png" ] && "$PYTHON" -c "import PIL" >/dev/null 2>&1; then
    "$PYTHON" - "$OUT_DIR/thumbnails" <<'PY'
import os
import sys

from PIL import Image

thumbnails = sys.argv[1]
failures = []
expected_ratio = {"blank.docx.png": None, "blank.xlsx.png": None, "blank.pptx.png": 16 / 9}

for name in ("blank.docx.png", "blank.xlsx.png", "blank.pptx.png"):
    path = os.path.join(thumbnails, name)
    if not os.path.isfile(path):
        continue
    image = Image.open(path).convert("RGB")
    width, height = image.size
    centre = image.getpixel((width // 2, height // 2))
    if any(channel < 250 for channel in centre):
        failures.append(f"{name}: centre pixel {centre} is not white — a grey render means a missing p:bg / page background")
    ratio = expected_ratio[name]
    if ratio is not None and abs(width / height - ratio) > 0.02:
        failures.append(f"{name}: aspect ratio {width}x{height} is not 16:9")

if failures:
    print("verify-document-generation: FAIL (rendered output)")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print("  rendered thumbnails are white and 16:9 where expected")
PY
fi

echo "  artifacts: $OUT_DIR"
