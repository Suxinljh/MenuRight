MenuRight — "New File" blank documents
======================================

Word / Excel / PowerPoint need nothing here: MenuRight writes those packages
itself (minimal OOXML; see Shared/FileOperations/OOXMLDocumentFactory.swift).

The three files in this folder are the blank documents the app **copies** for
Pages / Numbers / Keynote:

    blank.pages       88 KB   Pages 26.4   — one blank portrait page
    blank.numbers    134 KB   Numbers 26.4 — one blank table
    blank.key        446 KB   Keynote      — one blank 16:9 white slide

They are ordinary documents saved from the apps (flat .pages/.numbers/.key
files, not `.template` bundles). The rule is simple: whatever sits here is what
"New File → Pages/Numbers/Keynote" produces, so keep them blank.

Replacing one
-------------

1. Open the app, File ▸ New, pick the blank document (a plain white theme is
   the smallest).
2. File ▸ Save… as "blank" with the app's own extension, into this folder,
   overwriting the old file.
3. Rebuild. This folder is an Xcode **folder reference**, so no project change
   is needed — every file in it is copied into the app bundle.

Notes
-----

* A missing file is not an error. That type is hidden from the Finder "New
  File" submenu, and the 新建文件 pane marks it 缺少模板 / "Template missing"
  and lists the file it wants.
* `blank.key` carries the Keynote theme's own media (17 master slides plus
  stock photos, ~400 KB), so every new `.key` is that size. A freshly saved
  plain-white deck would be smaller; either works.
* Files are copied byte-for-byte (`FileManager.copyItem`), so whatever a
  document carries — author metadata, fonts, embedded media — ends up in every
  new file. Prefer documents saved with no personal content.
* `Scripts/verify-document-generation.sh` copies these through the same code
  path the app uses and checks naming, bytes and package integrity.
