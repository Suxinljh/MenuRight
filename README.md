# Menu Right

Native macOS Finder productivity utility.

> Ubuntu-style right-click copy of file name / path / URL from Finder, with a
> small SwiftUI host app to manage the Finder Sync Extension.

## Current phase

**Phase A1 - Finder Foundation**

Goal: a stable native macOS project with a working Finder Sync Extension and
real Finder context-menu actions.

### Implemented actions

| Action          | Single selection                          | Multiple selection               |
| --------------- | ----------------------------------------- | -------------------------------- |
| Copy Name       | `example.png`                           | one name per line                |
| Copy Path       | `/Users/foo/Projects/MenuRight/README.md` | one absolute path per line     |
| Copy File URL   | `file:///Users/foo/Projects/MenuRight/README.md` | one file URL per line |

Background (container) right-click shows **Copy Folder Path**.

### Architecture

- SwiftUI host app (`MenuRight`) - extension status + system management UI
- Finder Sync Extension (`MenuRightFinder`) - AppKit / FinderSync.framework
- Pure Foundation selection/formatting logic, unit-tested without Finder mocks

### Monitored scope

Only `FileManager.default.homeDirectoryForCurrentUser` (the user home
directory and its subdirectories). No /, /Volumes, network/SMB/NAS volumes,
external drives, or iCloud extension.

### Requirements

- Xcode 15+ (project format Xcode 14-compatible)
- macOS 14.0+ deployment target
- An Apple Development signing team for local runs

### Build & test

```sh
xcodebuild -project MenuRight.xcodeproj -scheme MenuRight -configuration Debug build
xcodebuild -project MenuRight.xcodeproj -scheme MenuRight -configuration Debug test
```

### Manual check

1. Run `MenuRight` and confirm the Finder Extension status shows **Enabled**
   (use `Manage Finder Extension` to enable it).
2. Open Finder, browse into a folder under the user home directory.
3. Right-click a file: the three copy actions appear.
4. Multi-select two files and verify the actions copy one line per item.
5. Right-click folder background: `Copy Folder Path` appears.

## Roadmap (planned, NOT implemented)

- Clipboard History (monitor + history UI, global hotkey)
- Quick Look extensions
- Image handling, Git detection, scripts, file move/create — later phases

None of the roadmap items are shipped in Phase A1.
