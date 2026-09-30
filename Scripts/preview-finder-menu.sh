#!/usr/bin/env bash
#
# Prints the Finder context menu the extension would build, in the language the
# app currently has stored — using the extension's own plan/title code.
#
#   Scripts/preview-finder-menu.sh
#
# What this proves: the shared App-Group payload is read correctly, the language
# resolves, every title renders in both languages, and a title handed back by
# Finder maps to the right action (title-based replay).
#
# What it cannot prove: that Finder calls `menu(for:)` and draws the result —
# that still needs a real right-click (§3.5 item 15 in the verification handbook).
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

cat > "$BUILD_DIR/main.swift" <<'SWIFT'
import Foundation

// A command-line tool has no App Group entitlement, so the plist is read
// directly instead of through `UserDefaults(suiteName:)`.
let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/Group Containers/group.xin.ljhsu.MenuRight/Library/Preferences/group.xin.ljhsu.MenuRight.plist"
)

let suite = "menu-preview.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
var payloadBytes = 0

if let raw = try? Data(contentsOf: plist),
   let plistObject = try? PropertyListSerialization.propertyList(from: raw, format: nil),
   let payload = (plistObject as? [String: Any])?["xin.ljhsu.MenuRight.settings"] as? Data {
    payloadBytes = payload.count
    defaults.set(payload, forKey: FinderMenuLanguage.storageKey)
}

// P6-b: the "New File" submenu is filtered by what the running main app
// published it can create, so the preview reads that payload too.
var availabilityBytes = 0
if let raw = try? Data(contentsOf: plist),
   let plistObject = try? PropertyListSerialization.propertyList(from: raw, format: nil),
   let payload = (plistObject as? [String: Any])?["xin.ljhsu.MenuRight.newFileAvailability"] as? Data {
    availabilityBytes = payload.count
    defaults.set(payload, forKey: NewFileAvailability.storageKey)
}

let stored = FinderMenuLanguage.selection(from: defaults)
let resolved = FinderMenuLanguage.resolve(from: defaults, preferred: Locale.preferredLanguages)
print("settings payload : \(payloadBytes) bytes from \(plist.lastPathComponent)")
print("stored selection : \(stored.rawValue)")
print("menu language    : \(resolved.rawValue)")
if payloadBytes == 0 {
    print("                 (no payload found — falling back like a fresh install)")
}

let availability = NewFileAvailability.read(from: defaults)
let newFileKinds = NewFileKind.available(from: availability)
print("availability     : \(availabilityBytes) bytes → new file kinds: \(newFileKinds.map(\.rawValue).joined(separator: ", "))")
if availability == nil {
    print("                 (app has not published; text kinds only, like a fresh install)")
}

// P7-b: the favorites submenus are filtered by the same payload's three lists.
let favorites = FinderFavorites.entries(from: defaults)
print("favorites        : \(favorites.count) shown → \(favorites.map { "\($0.kind.rawValue):\($0.menuTitle)" }.joined(separator: ", "))")

let container = URL(fileURLWithPath: "/Users/foo/My Project", isDirectory: true)
let selection = FinderSelectionContext(itemURLs: [], targetedURL: container)
let itemSelection = FinderSelectionContext(
    itemURLs: [URL(fileURLWithPath: "/Users/foo/My Project/report.pdf")],
    targetedURL: nil
)

func render(_ title: String, _ plan: [FinderMenuPlanItem], _ language: AppLanguage) {
    print("\n--- \(title) [\(language.rawValue)] ---")
    for item in plan {
        switch item {
        case .action(let action):
            print("  " + FinderMenuTitles.title(for: action, language: language))
        case .submenu(let titleKey, let actions):
            print("  " + FinderMenuTitles.submenuTitle(titleKey, language: language) + " ▸")
            for action in actions {
                print("      " + FinderMenuTitles.title(for: action, language: language))
            }
        }
    }
}

let containerPlan = FinderMenuBuilder.plan(
    for: selection,
    hasCutPayload: true,
    newFileKinds: newFileKinds,
    favorites: favorites
)
let itemPlan = FinderMenuBuilder.plan(for: itemSelection, hasCutPayload: false, newFileKinds: newFileKinds)

// P9: an archive selection offers 解压 ▸ and 压缩 ▸.
let archiveSelection = FinderSelectionContext(
    itemURLs: [URL(fileURLWithPath: "/Users/foo/My Project/bundle.zip")],
    targetedURL: nil
)
let archivePlan = FinderMenuBuilder.plan(
    for: archiveSelection,
    hasCutPayload: false,
    newFileKinds: newFileKinds,
    archives: FinderArchives.classify(archiveSelection.itemURLs, defaults: defaults)
)

// P9: a mixed selection can only be compressed.
let mixedSelection = FinderSelectionContext(
    itemURLs: [
        URL(fileURLWithPath: "/Users/foo/My Project/report.pdf"),
        URL(fileURLWithPath: "/Users/foo/My Project/notes.txt"),
    ],
    targetedURL: nil
)
let mixedPlan = FinderMenuBuilder.plan(
    for: mixedSelection,
    hasCutPayload: false,
    newFileKinds: newFileKinds,
    archives: FinderArchives.classify(mixedSelection.itemURLs, defaults: defaults)
)

for language in [resolved, resolved == .simplifiedChinese ? AppLanguage.english : .simplifiedChinese] {
    render("Background right-click", containerPlan, language)
    render("Item right-click", itemPlan, language)
    render("Archive right-click", archivePlan, language)
    render("Mixed selection right-click", mixedPlan, language)
}

// Title-based replay: Finder reconstructs the menu item and drops
// representedObject, so the title is the only key the extension gets back.
print("\n--- replay in \(resolved.rawValue) ---")
var failures = 0
func expect(_ title: String, _ expected: String) {
    let mapped: String
    if let subject = FinderMenuTitles.copySubject(forTitle: title) {
        mapped = "\(subject)"
    } else if FinderMenuTitles.isUnlockTitle(title) {
        mapped = "unlock"
    } else if let kind = FinderMenuTitles.newFileKind(forTitle: title) {
        mapped = kind.rawValue
    } else {
        mapped = "UNMATCHED"
    }
    let ok = mapped == expected
    if !ok { failures += 1 }
    print("  \(title) → \(mapped) \(ok ? "OK" : "MISMATCH (expected \(expected))")")
}

for language in FinderMenuTitles.concreteLanguages {
    expect(FinderMenuTitles.title(for: .copyName(payload: "report.pdf"), language: language), "names")
    expect(FinderMenuTitles.title(for: .copyFolderPath(payload: container.path), language: language), "folderPath")
    expect(FinderMenuTitles.title(for: .setLocked(items: [], locked: false), language: language), "unlock")
    expect(FinderMenuTitles.title(for: .newFile(kind: .json, directory: container), language: language), "json")
}

print(failures == 0 ? "\npreview-finder-menu: PASS" : "\npreview-finder-menu: FAIL (\(failures) replay mismatches)")
exit(failures == 0 ? 0 : 1)
SWIFT

SDK="$(xcrun --show-sdk-path --sdk macosx)"
ARCH="$(uname -m)"
swiftc -O -sdk "$SDK" -target "$ARCH-apple-macos14.0" -o "$BUILD_DIR/preview" \
    "$BUILD_DIR/main.swift" \
    "$PROJECT_DIR/MenuRightFinder/FinderMenuBuilder.swift" \
    "$PROJECT_DIR/MenuRightFinder/FinderSelectionContext.swift" \
    "$PROJECT_DIR/MenuRightFinder/FinderMenuLanguage.swift" \
    "$PROJECT_DIR/MenuRightFinder/FinderFavorites.swift" \
    "$PROJECT_DIR/MenuRightFinder/FinderArchives.swift" \
    "$PROJECT_DIR/Shared/Settings/AppLanguage.swift" \
    "$PROJECT_DIR/Shared/Settings/Localization.swift" \
    "$PROJECT_DIR/Shared/Settings/NewFileAvailability.swift" \
    "$PROJECT_DIR/Shared/IPC/MenuRightIPC.swift"
"$BUILD_DIR/preview"
