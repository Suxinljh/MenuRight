import XCTest

/// Lifecycle tests for scoped access via the injected configuration seam.
/// No real security-scoped bookmark API is touched.
final class FolderAuthorizationAccessTests: XCTestCase {
    private final class Recording {
        var started: [String] = []
        var stopped: [String] = []
        var resolved: [String] = []
        var bodyCalls = 0
        var persistedRefresh: [String] = []
    }

    private func folder(_ path: String) -> AuthorizedFolder {
        // bookmarkData payload = utf8 path; the injected resolver decodes it.
        AuthorizedFolder(
            displayName: (path as NSString).lastPathComponent,
            originalPath: path,
            bookmarkData: Data(path.utf8)
        )
    }

    private func configuration(
        record: Recording,
        startOK: Bool = true,
        stale: Bool = false
    ) -> ScopedAccessConfiguration {
        ScopedAccessConfiguration(
            resolveBookmark: { data in
                let path = String(data: data, encoding: .utf8) ?? "/unknown"
                record.resolved.append(path)
                return (URL(fileURLWithPath: path), stale)
            },
            startAccess: { url in
                record.started.append(url.path)
                return startOK
            },
            stopAccess: { url in
                record.stopped.append(url.path)
            },
            makeFreshBookmark: { url in
                Data(("fresh:" + url.path).utf8)
            }
        )
    }

    private func persistHook(record: Recording) -> (AuthorizedFolder, Data) throws -> Void {
        { folder, data in
            record.persistedRefresh.append(String(data: data, encoding: .utf8) ?? "?")
        }
    }

    func testBodyRunsAndStopCalledWhenStartSucceeds() throws {
        let record = Recording()
        let result = try FolderAuthorizationAccess.withAccess(
            to: URL(fileURLWithPath: "/Users/foo/Desktop/a.txt"),
            folders: [folder("/Users/foo")],
            configuration: configuration(record: record)
        ) { _ in
            record.bodyCalls += 1
            return 42
        }

        XCTAssertEqual(result, 42)
        XCTAssertEqual(record.bodyCalls, 1)
        XCTAssertEqual(record.started, ["/Users/foo"])
        XCTAssertEqual(record.stopped, ["/Users/foo"], "stop must balance start")
    }

    func testBodyThrowsStillStops() {
        let record = Recording()
        XCTAssertThrowsError(
            try FolderAuthorizationAccess.withAccess(
                to: URL(fileURLWithPath: "/Users/foo/a.txt"),
                folders: [folder("/Users/foo")],
                configuration: configuration(record: record)
            ) { _ in
                throw FileOperationError.unknown("boom")
            }
        )
        XCTAssertEqual(record.started.count, 1)
        XCTAssertEqual(record.stopped.count, 1, "stop must be called even when the body throws")
    }

    func testStartFailureSkipsBodyAndThrows() {
        let record = Recording()
        XCTAssertThrowsError(
            try FolderAuthorizationAccess.withAccess(
                to: URL(fileURLWithPath: "/Users/foo/a.txt"),
                folders: [folder("/Users/foo")],
                configuration: configuration(record: record, startOK: false)
            ) { _ in record.bodyCalls += 1 }
        ) { error in
            XCTAssertEqual(error as? FolderAuthorizationError, .accessStartFailed(URL(fileURLWithPath: "/Users/foo/a.txt")))
        }
        XCTAssertEqual(record.bodyCalls, 0)
        XCTAssertEqual(record.stopped.count, 0, "never started -> never stopped")
    }

    func testNoAuthorizationThrowsWithoutRunningBody() {
        let record = Recording()
        XCTAssertThrowsError(
            try FolderAuthorizationAccess.withAccess(
                to: URL(fileURLWithPath: "/Users/other/a.txt"),
                folders: [folder("/Users/foo")],
                configuration: configuration(record: record)
            ) { _ in record.bodyCalls += 1 }
        ) { error in
            XCTAssertEqual(error as? FolderAuthorizationError, .authorizationRequired(URL(fileURLWithPath: "/Users/other/a.txt")))
        }
        XCTAssertEqual(record.bodyCalls, 0)
        XCTAssertTrue(record.started.isEmpty)
    }

    func testStaleBookmarkRefreshesAndPersists() throws {
        let record = Recording()
        try FolderAuthorizationAccess.withAccess(
            to: URL(fileURLWithPath: "/Users/foo/Desktop/x.txt"),
            folders: [folder("/Users/foo")],
            configuration: configuration(record: record, stale: true),
            persistRefreshedBookmark: persistHook(record: record)
        ) { _ in record.bodyCalls += 1 }

        XCTAssertEqual(record.bodyCalls, 1)
        XCTAssertEqual(record.persistedRefresh, ["fresh:/Users/foo"])
        XCTAssertEqual(record.stopped.count, 1)
    }

    func testStaleBookmarkWithoutPersistHookThrows() {
        let record = Recording()
        XCTAssertThrowsError(
            try FolderAuthorizationAccess.withAccess(
                to: URL(fileURLWithPath: "/Users/foo/x.txt"),
                folders: [folder("/Users/foo")],
                configuration: configuration(record: record, stale: true)
            ) { _ in record.bodyCalls += 1 }
        ) { error in
            XCTAssertEqual(error as? FolderAuthorizationError, .staleBookmarkNeedsReauthorization(URL(fileURLWithPath: "/Users/foo/x.txt")))
        }
        XCTAssertEqual(record.bodyCalls, 0)
        XCTAssertEqual(record.stopped.count, 1, "started during refresh attempt must still be stopped")
    }

    func testMultipleRootsBalanced() throws {
        let record = Recording()
        let folders = [folder("/Users/foo/Projects"), folder("/Users/foo/Desktop")]
        try FolderAuthorizationAccess.withAccesses(
            to: [
                URL(fileURLWithPath: "/Users/foo/Projects/a.txt"),
                URL(fileURLWithPath: "/Users/foo/Desktop/b.txt"),
            ],
            folders: folders,
            configuration: configuration(record: record)
        ) { record.bodyCalls += 1 }

        XCTAssertEqual(record.bodyCalls, 1)
        XCTAssertEqual(Set(record.started), Set(["/Users/foo/Projects", "/Users/foo/Desktop"]))
        XCTAssertEqual(record.started.count, record.stopped.count, "stops balance starts")
    }

    func testSameRootForMultipleTargetsStartedOnce() throws {
        let record = Recording()
        try FolderAuthorizationAccess.withAccesses(
            to: [
                URL(fileURLWithPath: "/Users/foo/a.txt"),
                URL(fileURLWithPath: "/Users/foo/b.txt"),
            ],
            folders: [folder("/Users/foo")],
            configuration: configuration(record: record)
        ) { record.bodyCalls += 1 }

        XCTAssertEqual(record.bodyCalls, 1)
        XCTAssertEqual(record.started, ["/Users/foo"], "dedupe: one scope, one start")
        XCTAssertEqual(record.stopped, ["/Users/foo"])
    }

    func testMissingAuthorizationForOneTargetFailsWholeBatch() {
        let record = Recording()
        XCTAssertThrowsError(
            try FolderAuthorizationAccess.withAccesses(
                to: [
                    URL(fileURLWithPath: "/Users/foo/a.txt"),
                    URL(fileURLWithPath: "/Users/other/b.txt"),
                ],
                folders: [folder("/Users/foo")],
                configuration: configuration(record: record)
            ) { record.bodyCalls += 1 }
        ) { error in
            XCTAssertEqual(error as? FolderAuthorizationError, .authorizationRequired(URL(fileURLWithPath: "/Users/other/b.txt")))
        }
        XCTAssertEqual(record.bodyCalls, 0)
        XCTAssertTrue(record.started.isEmpty)
    }

    /// The authoritative check (`authorizeResolvedRoot`) accepts a case-only
    /// difference only where the volume does. The metadata spelling is what the
    /// user picked earlier, the bookmark resolves to the on-disk name, so the
    /// pre-filter (exact spelling) passes on both volumes and only the
    /// resolved-root check can differ.
    func testResolvedRootAllowsACaseOnlyDifferenceOnlyOnACaseInsensitiveVolume() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-auth-case-\(UUID().uuidString)", isDirectory: true)
        let realDirectory = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let differentlyCasedRoot = root.appendingPathComponent("downloads")
        let target = differentlyCasedRoot.appendingPathComponent("Untitled.txt")
        let caseSensitive = AuthorizedURLResolver.volumeSupportsCaseSensitiveNames(for: target)

        let authorized = AuthorizedFolder(
            displayName: "Downloads",
            originalPath: differentlyCasedRoot.path,
            bookmarkData: Data(realDirectory.path.utf8)
        )

        let record = Recording()
        var thrown: Error?
        do {
            try FolderAuthorizationAccess.withAccess(
                to: target,
                folders: [authorized],
                configuration: configuration(record: record)
            ) { _ in record.bodyCalls += 1 }
        } catch {
            thrown = error
        }

        if caseSensitive {
            XCTAssertEqual(thrown as? FolderAuthorizationError, .authorizationRequired(target))
            XCTAssertEqual(record.bodyCalls, 0)
        } else {
            XCTAssertNil(thrown)
            XCTAssertEqual(record.bodyCalls, 1)
        }
        XCTAssertEqual(record.started, [realDirectory.path], "the resolved bookmark URL is what gets started")
        XCTAssertEqual(record.stopped, [realDirectory.path], "stop must balance start")
    }
}
