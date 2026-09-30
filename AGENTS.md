# AGENTS.md

## Dev environment tips

- Project: native macOS app using Swift 6.2.1, SwiftUI, AppKit, FinderSync.framework, XCTest, and Xcode 26.1.
- Deployment target: macOS 14.0+.
- Main targets: `MenuRight`, `MenuRightFinder`, `MenuRightTests`.
- Before modifying code, run `git status` and never overwrite, revert, or delete existing user changes.
- Prefer Apple native APIs. Do not add third-party dependencies without a clear need.
- Finder features must respect App Sandbox and the existing authorization model. Do not bypass permissions using AppleScript, Accessibility, CGEvent, or similar mechanisms.

## Testing instructions

- Run the relevant XCTest tests after code changes.
- When modifying the Finder Extension, verify that both `MenuRight` and `MenuRightFinder` build successfully.
- Add or update tests for new or modified testable behavior.
- Finder menus, extension loading, permissions, and other macOS integration require manual verification.
- Do not describe automated tests as verification of real Finder behavior.

## PR instructions

- PR title format: `[MenuRight] <Title>`
- Keep PRs focused on the current task. Avoid unrelated refactoring.
- Before opening a PR, verify that the affected targets build and relevant XCTest tests pass.
- PR descriptions should briefly include: changes made, test results, and required manual verification.
- Clearly distinguish `Automated: PASS` from `Manual: PENDING/PASS`.

## Memory instructions

- At the end of every conversation, create a Markdown memory file in the `Memory/` directory.
- File name format: `Memory-mm-dd-num.md`, for example `Memory-09-30-01.md`.
- `num` is an incrementing number for the current date, starting from `01`.
- Record information with long-term value, including completed work, technical decisions, important issues, and follow-up items.
- Do not record casual conversation, redundant information, or temporary debugging output.
- Only record information that actually occurred or was confirmed during the conversation. Never fabricate memory.