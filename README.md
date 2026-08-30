# Menu Right

Native macOS Finder productivity utility.

> Right-click copy of file name / path / URL from Finder, plus file operations
> (New File / New Folder / Cut / Paste Here), with a small SwiftUI host app to
> manage the Finder Sync Extension.

## Current phase

**Phase A2.5 - Folder Authorization Foundation**

Goal: the smallest supported authorization architecture that lets the sandboxed
Finder Sync extension write inside directories the user explicitly authorized.

Flow: Menu Right app -> Add Folder (NSOpenPanel) -> app-scope security-scoped
bookmark -> persisted in the App Group container -> Finder Sync extension
resolves the bookmark -> startAccessingSecurityScopedResource() -> existing
FileOperationService actions -> stopAccessingSecurityScopedResource().

Status: automated builds/tests PASS; cross-process bookmark access requires the
manual gate (real NSOpenPanel selection) to be confirmed in Finder.

## Phase A2 (previous phase)

Goal: reliable Finder file-write operations while preserving App Sandbox.

### Implemented actions (Phase A1 + A2)

| Area | Actions |
| ---- | ------- |
| Selection | Copy Name, Copy Path, Copy File URL, Cut |
| Container | New File (Text/Markdown/JSON), New Folder, Paste Here, Copy Folder Path |

Naming convention (collision-safe, never overwrites):

- `Untitled.txt` -> `Untitled 2.txt` -> `Untitled 3.txt`
- `New Folder` -> `New Folder 2` -> `New Folder 3`
- Cut/Paste never auto-renames: a destination conflict fails that item with an
  alert (partial moves report which items failed; the cut payload keeps only
  failed URLs for retry).

Cut state lives on the system pasteboard as a versioned JSON payload
(`xin.ljhsu.MenuRight.cut-items`), not in memory or App Group state, so it
survives extension restarts.

### Architecture

- SwiftUI host app (MenuRight) - extension status + system management UI
- Finder Sync Extension (MenuRightFinder) - AppKit / FinderSync.framework
- FileOperations/ - service, result model, name resolver, move planner,
  cut-payload codec/pasteboard bridge, alert presenter
- All pure logic is Foundation-only and unit-tested without Finder mocks

### Security model

- App Sandbox stays enabled for the app and the extension.
- App Group `group.xin.ljhsu.MenuRight` added ONLY for folder-authorization
  metadata + bookmark data.
- Main app: `com.apple.security.files.user-selected.read-write` +
  `com.apple.security.files.bookmarks.app-scope` (NSOpenPanel grant origin).
- Extension: same bookmark/user-selected entitlements so it can resolve and
  consume bookmarks created by the containing app.
- No Full Disk Access, no temporary exceptions, no shell/AppleScript bypass.
- Monitored scope remains the user home directory only.

### Folder Access (A2.5)

Authorize folders (e.g. Home once) via Menu Right -> Folder Access -> Add
Folder. Authorized entries persist as security-scoped bookmarks in the shared
App Group store; the extension resolves the nearest authorized ancestor before
New File / New Folder / Paste Here and balances start/stop scoped access.

### Phase A2 verified constraint

Automated build and unit tests pass, but the sandboxed extension cannot write
outside its container. Verified with a sandboxed probe app carrying the same
entitlements: writes to the real Home (e.g. ~/Desktop) fail with
NSCocoaErrorDomain 513 / POSIX EPERM(1). Per Phase A2 policy the sandbox is
NOT disabled and no broad entitlements were added. Enabling Home writes in a
later phase requires the supported permission model (user-selected file access
with security-scoped bookmarks, or a Developer ID build without sandbox).

### Requirements

- Xcode 15+ (project format Xcode 14-compatible)
- macOS 14.0+ deployment target
- An Apple Development signing team for local runs

### Build & test

```sh
xcodebuild -project MenuRight.xcodeproj -scheme MenuRight -configuration Debug build
xcodebuild -project MenuRight.xcodeproj -scheme MenuRight -configuration Debug test
```

### Manual verification (Phase A2)

A build passing is NOT enough — the sandboxed extension's write access must be
verified in the real Finder:

1. Enable the extension (MenuRight app -> Manage Finder Extension).
2. **Test A - New File**: in ~/Desktop/MenuRight-A2-Test/ (or any Home
   subfolder), right-click background -> New File -> Text File. Expect
   Untitled.txt; repeat, expect Untitled 2.txt.
3. **Test B - New Folder**: repeat New Folder twice; expect New Folder,
   New Folder 2.
4. **Test C - Cut/Paste**: create Source/test.txt and Destination/; Cut
   Source/test.txt; right-click Destination/ -> Paste Here. Expect source gone
   and Destination/test.txt present.
5. **Test D - Multi-select**: move two files together.
6. **Test E - Collision**: destination already contains the same filename;
   expect the existing file untouched, source kept, and an error alert.
7. **Test F - Folder guard**: attempt FolderA -> FolderA/Sub; expect rejection.

If Test A fails with a sandbox/permission error, record the exact NSError
domain/code/POSIX and do NOT disable the sandbox — report it.

### Manual check (Phase A1 regression)

1. Run MenuRight and confirm the Finder Extension status shows Enabled.
2. Right-click a file in Home: Copy Name / Copy Path / Copy File URL work.
3. Right-click folder background: Copy Folder Path works.

## Roadmap (planned, NOT implemented)

- Clipboard History (monitor + history UI, global hotkey)
- Quick Look extensions
- Image handling, Git detection, scripts, destination favorites,
  Copy To / Move To — later phases

None of the roadmap items are shipped in Phase A2.
