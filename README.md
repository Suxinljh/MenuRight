# Menu Right

Native macOS Finder productivity utility.

> Right-click copy of file name / path / URL from Finder, plus file operations
> (New File / New Folder / Cut / Paste Here), with a small SwiftUI host app to
> manage the Finder Sync Extension.

## Current phase

**Phase P5-1 - Main App is the single writer (over App-Group IPC)**

Goal: the sandboxed Finder Sync extension never writes to disk itself. It asks
the main app to perform the operation, and the main app re-establishes the
user's authorization (security-scoped bookmark) before every mutation.

Flow: Menu Right app -> Add Folder (NSOpenPanel) -> app-scope security-scoped
bookmark -> persisted in the App Group container -> Finder Sync extension sends
a `fileOperation` request over an App-Group Unix socket -> **main app** resolves
the bookmark, matches the requested path against the authorized roots ->
`startAccessingSecurityScopedResource()` -> `FileOperationService` ->
`stopAccessingSecurityScopedResource()`.

The extension holds no bookmark capability: it transmits paths only.

Status: automated builds/tests PASS; the Finder integration (extension loading,
real NSOpenPanel selection, cross-process bookmark access) requires the manual
gate below.

### IPC transport (P5-0.6 / P5-1)

- App-Group Unix domain socket `<App Group>/ipc.sock`; length-prefixed JSON
  frames, 64 KiB cap; `ping` + `fileOperation`.
- **Deadlines**: every read/write waits with `poll()` against a wall-clock
  deadline; `SO_RCVTIMEO`/`SO_SNDTIMEO` are additional defence in depth. A peer
  that connects and then goes silent cannot block a caller.
- **Both sides verify the peer** by code signature (audit token +
  `SecCodeCheckValidity`) against a designated requirement that pins the bundle
  identifier *and* the team OU. Either side can refuse a socket it did not
  expect, so a same-user process cannot impersonate the main app.
- The socket file is `chmod 0600` after `bind()`; a pre-existing path that is not
  our own socket, or a socket that still has a live listener, is never removed.
- `SO_NOSIGPIPE` is set on every socket, so writing to a closed peer fails with
  `EPIPE` instead of killing the process with SIGPIPE.
- The extension runs all IPC on a private serial queue and only touches the main
  thread to present an alert (Finder menu actions must never block).

### Swift language mode

The toolchain is Swift 6.2.1 (Xcode 26.1) but every target builds in
**Swift 5 language mode** (`SWIFT_VERSION = 5.0`), so strict concurrency
diagnostics are *not* compile-time enforced. Concurrency-critical state is
therefore synchronized explicitly (serial queues for the IPC lifecycle, an
`NSLock` for the authorization store) rather than relying on the compiler.

## Phase A2.5 (previous phase)

Folder Authorization Foundation: the smallest supported authorization
architecture that lets the extension write inside directories the user
explicitly authorized. Superseded by P5-1 for *who performs the write*; the
bookmark model itself is unchanged.

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
  metadata + bookmark data + the IPC socket.
- Main app: `com.apple.security.files.user-selected.read-write` +
  `com.apple.security.files.bookmarks.app-scope` (NSOpenPanel grant origin).
- Extension: **no file entitlements at all** — it does not resolve bookmarks and
  does not write. Every mutation is requested over IPC and executed by the main
  app after it re-establishes authorization. The shared write/authorization
  sources are deliberately not compiled into the extension target, so the
  architecture is enforced by the build graph rather than by convention.
- No Full Disk Access, no temporary exceptions, no shell/AppleScript bypass.
- Monitored scope remains the user home directory only.
- Every requested path is re-validated by the main app: it is canonicalized,
  matched against the authorized roots by path *components*, and the bookmark
  resolution result must still contain the target. A wire-supplied `name` is
  rejected unless it is a single, representable path component, and the final
  write URL is checked again immediately before the write.

### Folder Access (A2.5, unchanged)

Authorize folders (e.g. Home once) via Menu Right -> Folder Access -> Add
Folder. Authorized entries persist as security-scoped bookmarks in the shared
App Group store. New File / New Folder / Paste Here require the nearest
authorized ancestor; start/stop scoped access is balanced by `defer`.

Stale bookmarks are **renewed transparently**: the refreshed bookmark is created
from the still-resolving stale bookmark and written back to the App Group store
under a lock. Only if the renewal itself fails does the operation report
`stale_bookmark_needs_reauthorization` and ask the user to re-authorize. The
single-target and multi-target paths use the same policy.

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

Both targets (`MenuRight` and `MenuRightFinder`) must build; the scheme's test
action builds both before running `MenuRightTests`.

**Signing (this machine, verified):** a plain `xcodebuild ... build` fails with
`No profiles for 'xin.ljhsu.MenuRight.FinderSync' were found` because no
provisioning profiles are installed yet. Let Xcode create them once:

```sh
xcodebuild -project MenuRight.xcodeproj -scheme MenuRight -configuration Debug build \
  -allowProvisioningUpdates
```

That produced a fully signed Debug build (Apple Development, team `92X76S5UFL`,
leaf certificate `OU=92X76S5UFL`) and is the prerequisite for loading the
extension in Finder.

For a headless run where signing is irrelevant (CI-style verification of the
unit tests only):

```sh
xcodebuild -project MenuRight.xcodeproj -scheme MenuRight -configuration Debug test \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```

That variant runs the full suite (159 tests at the time of writing) but produces
an unsigned app — it is useless for actually loading the extension in Finder.
Real Finder verification needs the signed build.

### Signing and hardening

- Hardened runtime is enabled for the app and the extension in every
  configuration.
- **Release is signed without `get-task-allow`** (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`
  on the Release configs). Debug keeps the Xcode-injected base entitlements so a
  debugger can attach. Verified: Release app/appex entitlements contain only
  sandbox + App Group (+ the app's file entitlements), and the appex still passes
  embedded-binary validation.
- Distribution/notarization is still out of reach with a Personal Team: the
  development provisioning profile is what makes the build installable, and a
  Developer ID / Apple Distribution profile (paid Apple Developer Program) is
  required to ship. `codesign` reports the hardened-runtime flag
  (`flags=0x10000(runtime)`) on the Release products.

### Swift concurrency status

The targets build in Swift 5 language mode. With
`SWIFT_STRICT_CONCURRENCY=complete` there are **0 errors** and 7 remaining
warnings, all one design decision: `NSAlert` is main-actor-isolated but
`OperationPresenter` is not annotated, and `FinderSync`'s outcome-handler
closure is not `Sendable` (FinderSync.swift:400). Fixing them means deciding
FinderSync's isolation model (`@MainActor` on the subclass vs
`@unchecked Sendable`), which can only be verified in the same Finder gate that
is still pending — so it is deliberately deferred. The mechanically safe subset
already landed: the wire-contract types, `ExtensionIPCClient` outcomes,
`ScopedAccessConfiguration`, `FolderAuthorizationStore`, `FileOperationDispatcher`
and `MainAppIPCServer` are `Sendable` (with `@unchecked` + justification where a
lock or queue provides the synchronization).

### Reproducible IPC gate verification

The peer-identity gate needs a real signed peer, so the unit tests inject a stub
verifier. `Scripts/verify-ipc-peer.swift` closes that gap without Finder: it
connects to the **running** main app and runs the exact requirement strings the
extension ships.

```sh
swiftc -O Scripts/verify-ipc-peer.swift Shared/IPC/MenuRightIPC.swift \
  Shared/IPC/PeerIdentity.swift Shared/IPC/UnixSocketTransport.swift \
  -o /tmp/verify-ipc-peer && /tmp/verify-ipc-peer
```

Checked (all PASS on 2026-09-30, signed Debug build, team `92X76S5UFL`):

- `mainAppRequirementString` VERIFIES the live main app
  (`bundleId=xin.ljhsu.MenuRight team=92X76S5UFL`) — this is the check the
  extension runs after `connect()`;
- the extension's own requirement does NOT match the main app;
- a wrong `certificate leaf[subject.OU]` is rejected, so the M2 team binding is
  real (`SecCodeCheckValidity` returns `-67050` = `errSecCSReqFailed`).

Observed live behaviour of the signed app:

- `<App Group>/ipc.sock` is created `srw-------` (0600) **after** `bind()`;
- a non-extension client that sends a valid `ping` frame gets its connection
  closed with **no response** (~10 ms) and a rejection logged. Two observed
  shapes: an Apple-signed but wrong binary fails the requirement
  (`SecCodeCheckValidity failed OSStatus=-67050`), while an unsigned/ad-hoc
  client is rejected even earlier
  (`SecCodeCopyGuestWithAttributes failed OSStatus=100001`). Both fail closed —
  neither receives a reply;
- the second `start()` call is a no-op (`already running`), confirming the
  lifecycle is serialized;
- `bootstrap-diagnostics.log` is appended to (existing history preserved — the
  old `Data.write` fallback used to truncate it).

Still `Manual: PENDING` — everything that needs Finder itself: extension
loading, the extension's own client-side check from inside its sandbox, New
File / New Folder / Cut / Paste, stale-bookmark renewal, and the least-privilege
regression.

### Manual verification (P5-1 + A2 integration)

**Install/enable for testing: `Scripts/install-dev-app.sh`** (signed build → `ditto` install into
`~/Applications` → register + enable the extension → verify). Use it instead of copying the app by
hand: `cp -R` breaks an Xcode debug build's hard links and the kernel then kills the copy with
"Taskgated Invalid Signature", while `codesign --verify` still reports it as valid.

**Step-by-step runbook: `MenuRight 验证手册.md`** — it covers the build/install step, how to make
Finder actually load the new extension (it loads the registered copy from `~/Applications`, not
DerivedData), how to read the logs, and a per-feature pass/fail checklist.

A build passing is NOT enough — the sandboxed extension's behaviour must be
verified in the real Finder. Automated tests do not and cannot cover this.

1. Enable the extension (MenuRight app -> Manage Finder Extension).
2. **Test A - New File**: in ~/Desktop/MenuRight-A2-Test/ (or any authorized
   Home subfolder), right-click background -> New File -> Text File. Expect
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
8. **Test G - no hang (H1)**: quit MenuRight, then occupy the socket with a
   foreign listener (`nc -lU "<App Group>/ipc.sock"`). Trigger New File: expect
   the "Menu Right not running" alert within a few seconds and a responsive
   Finder menu — never a spinning/blocked extension.
9. **Test H - impostor rejected (H2)**: same setup as G with a listener that is
   *not* MenuRight. The extension must refuse (no bogus success) and report that
   Menu Right is unavailable.
10. **Test I - transparent renewal (H3)**: authorize ~/Desktop/t, rename it to
    t2 in Finder, then New File inside t2. Expect success (not "Folder Access
    Required"), and the bookmark row in `FolderAuthorization.json` refreshed.
11. **Test J - least privilege regression (L5)**: with the extension's file
    entitlements removed, Copy Name / Copy Path / Copy File URL / Copy Folder
    Path / Cut / New File / New Folder / Paste Here all still work.

Evidence commands:

```sh
log stream --predicate 'subsystem == "xin.ljhsu.MenuRight"'
ls -le@ "$(getconf DARWIN_USER_DIR)../"   # inspect the App Group container
stat -f "%p %Su %N" "<App Group>/ipc.sock"   # expect 600 <owner>
```

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

None of the roadmap items are shipped in Phase P5-1.

### Out of scope (deliberately not addressed)

- Swift 6 language mode / strict-concurrency migration (see the language-mode
  note above); concurrency is synchronized by hand instead.
- Release/notarization/hardened-runtime verification (`get-task-allow` is
  expected in Debug only).
- Full TOCTOU hardening against symlink swaps; containment is enforced by
  component-wise comparison plus a final check before the write.
- os_log payload privacy (several diagnostics are still `.public`).
