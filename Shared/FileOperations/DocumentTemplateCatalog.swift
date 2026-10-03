import Foundation
import os

/// The blank iWork documents the app copies for “New File → Pages/Numbers/Keynote”,
/// and the single place that decides whether a kind can be created at all.
///
/// Word/Excel/PowerPoint need no template: `OOXMLDocumentFactory` writes their
/// packages. Pages/Numbers/Keynote are closed formats (IWA/protobuf inside a
/// package), so they are **copied** from a blank document the user saves once
/// into `MenuRight/Resources/Templates/`. A missing template hides the menu item
/// instead of offering an action that can only fail (P6 scope: "模板缺失时该项隐藏并提示").
///
/// The directory is injectable so the unit tests never need a bundled template.
enum DocumentTemplateCatalog {
    static let log = Logger(subsystem: "xin.ljhsu.MenuRight", category: "document-templates")

    /// Subdirectory of the app bundle's `Resources`, added as a **folder
    /// reference** in the Xcode project so dropping a file in is enough — no
    /// project edit per template.
    static let bundleSubdirectory = "Templates"

    /// File name expected in the template directory, or nil for kinds that are
    /// generated rather than copied.
    static func templateFileName(for type: NewFileType) -> String? {
        switch type {
        case .pages: return "blank.pages"
        case .numbers: return "blank.numbers"
        case .keynote: return "blank.key"
        case .text, .markdown, .html, .css, .javascript, .json,
             .docx, .xlsx, .pptx:
            return nil
        }
    }

    /// `Contents/Resources/Templates` of the running main app.
    static var bundledDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(bundleSubdirectory, isDirectory: true)
    }

    /// The override folder from settings, or nil when unset or unusable.
    ///
    /// **The bookmark is the source of truth, not the path.** The folder the user
    /// picks lives outside the app's container, and the sandbox lets the app back
    /// in only through a security-scoped bookmark: a stored path string is not a
    /// capability by itself, so a release build that checked `fileExists` on the
    /// path alone found the user's own folder "unusable" after every relaunch and
    /// silently fell back to the bundled templates.
    ///
    /// A path with no bookmark — or one that will not resolve — is still tried:
    /// a folder inside the container needs no bookmark, and the shape check below
    /// then answers honestly instead of pretending the folder is gone.
    ///
    /// The folder is only *touched* here (to answer "is it usable"), so the
    /// access started for that check is stopped again before returning. The URL
    /// this hands back is therefore not a guarantee of access: anything that does
    /// real work inside the folder must go through `withOverrideDirectory(for:)`.
    static func overrideDirectory(for settings: NewFileSettings) -> URL? {
        withOverrideDirectory(for: settings) { $0 }
    }

    /// Resolves the override folder and runs `body` with its security-scoped
    /// access held, or returns nil when there is no usable override.
    ///
    /// Holding the access across the whole `body` is the point: the template copy
    /// reads a file inside a folder outside the container, so a start/stop pair
    /// wrapped around a `fileExists` check would leave the copy itself
    /// unauthorized. Callers fall back to the bundled templates on nil.
    static func withOverrideDirectory<T>(
        for settings: NewFileSettings,
        _ body: (URL) -> T
    ) -> T? {
        guard let url = resolveOverride(for: settings) else { return nil }
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started { url.stopAccessingSecurityScopedResource() }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            log.notice("template override is not a folder: \(url.path, privacy: .public)")
            return nil
        }
        return body(url)
    }

    /// Where the bookmark — or, failing that, the stored path — points.
    ///
    /// No security-scoped access is started and the folder is not checked for
    /// existence: this only turns stored settings into a URL, so both
    /// `withOverrideDirectory` and the tests can tell "no override configured"
    /// apart from "override configured but not reachable".
    static func resolveOverride(for settings: NewFileSettings) -> URL? {
        if let bookmark = settings.templateDirectoryBookmark {
            switch SecurityScopedBookmark.resolve(bookmark) {
            case .success(let resolved):
                if resolved.isStale {
                    log.notice("template override bookmark is stale: \(resolved.url.path, privacy: .public)")
                }
                return resolved.url
            case .failure(let error):
                log.error("template override bookmark will not resolve: \(String(describing: error), privacy: .public)")
            }
        }
        let path = settings.templateDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The directory templates are actually read from: the user's override when
    /// it is usable, otherwise the copies inside the app bundle.
    static func resolvedDirectory(for settings: NewFileSettings, bundle: Bundle = .main) -> URL? {
        if let override = overrideDirectory(for: settings) { return override }
        return bundle.resourceURL?.appendingPathComponent(bundleSubdirectory, isDirectory: true)
    }

    /// True when an override is configured but unusable (deleted, or not a
    /// folder). The settings pane warns; the bundled templates are used.
    static func hasBrokenOverride(for settings: NewFileSettings) -> Bool {
        settings.hasCustomTemplateDirectory && overrideDirectory(for: settings) == nil
    }

    /// Resolved template URL, or nil when the file is not there.
    ///
    /// `fileExists` works for both shapes an iWork document can have on disk: a
    /// package directory (the usual case on APFS) and a flat file (non-HFS
    /// volume). Copying is delegated to `FileManager.copyItem`, which preserves
    /// whichever it is.
    static func templateURL(for type: NewFileType, in directory: URL?) -> URL? {
        guard let fileName = templateFileName(for: type), let directory else { return nil }
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Whether this build can create `type` right now.
    static func canCreate(_ type: NewFileType, in directory: URL?) -> Bool {
        switch type.category {
        case .text, .office:
            // Generated by the extension (text) or by this app (OOXML).
            return true
        case .iWork:
            return templateURL(for: type, in: directory) != nil
        }
    }

    static func creatableTypes(in directory: URL?) -> Set<NewFileType> {
        Set(NewFileType.allCases.filter { canCreate($0, in: directory) })
    }

    /// Template-backed kinds this build cannot create, in catalog order.
    static func missingTemplateTypes(in directory: URL?) -> [NewFileType] {
        NewFileType.allCases.filter { $0.category == .iWork && !canCreate($0, in: directory) }
    }

    /// Computes and publishes `NewFileAvailability`, and returns it.
    ///
    /// Called at launch and again whenever the new-file settings change (the
    /// template directory is configurable now), so `FinderSync.menu(for:)` never
    /// has to touch the filesystem.
    @discardableResult
    static func publishAvailability(
        bundle: Bundle = .main,
        defaults: UserDefaults = SettingsStore.defaultUserDefaults()
    ) -> NewFileAvailability {
        publishAvailability(
            directory: bundle.resourceURL?.appendingPathComponent(bundleSubdirectory, isDirectory: true),
            defaults: defaults
        )
    }

    /// Settings-aware publish: uses the resolved directory, i.e. the user's
    /// override when it is usable and the bundled copy otherwise.
    @discardableResult
    static func publishAvailability(
        settings: NewFileSettings,
        bundle: Bundle = .main,
        defaults: UserDefaults = SettingsStore.defaultUserDefaults()
    ) -> NewFileAvailability {
        publishAvailability(
            directory: resolvedDirectory(for: settings, bundle: bundle),
            defaults: defaults
        )
    }

    /// Directory-injectable seam: the unit tests publish from a scratch folder,
    /// never from the test runner's own bundle.
    @discardableResult
    static func publishAvailability(
        directory: URL?,
        defaults: UserDefaults
    ) -> NewFileAvailability {
        let creatable = NewFileType.allCases
            .filter { canCreate($0, in: directory) }
            .map(\.rawValue)
        let availability = NewFileAvailability(creatableTypes: creatable)
        availability.write(to: defaults)

        let missing = missingTemplateTypes(in: directory).map(\.rawValue)
        log.notice(
            "published new-file availability creatable=\(creatable.joined(separator: ","), privacy: .public) missingTemplates=\(missing.joined(separator: ","), privacy: .public) directory=\(directory?.path ?? "<none>", privacy: .public)"
        )
        return availability
    }
}
