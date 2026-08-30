import XCTest

final class FileMovePlannerTests: XCTestCase {
    private let notADirectory: (URL) -> Bool = { _ in false }
    private let nothingExists: (URL) -> Bool = { _ in false }

    // MARK: - Valid moves

    func testValidFileMove() {
        let plans = FileMovePlanner.plan(
            sourceURLs: [URL(fileURLWithPath: "/Projects/foo.txt")],
            destinationDirectory: URL(fileURLWithPath: "/Projects/Backup"),
            isDirectory: notADirectory,
            fileExists: nothingExists
        )
        XCTAssertEqual(
            plans[0].decision,
            .proceed(destinationURL: URL(fileURLWithPath: "/Projects/Backup/foo.txt"))
        )
    }

    func testValidFolderMove() {
        let isDirectory: (URL) -> Bool = { $0.lastPathComponent == "FolderA" }
        let plans = FileMovePlanner.plan(
            sourceURLs: [URL(fileURLWithPath: "/Projects/FolderA")],
            destinationDirectory: URL(fileURLWithPath: "/Backups"),
            isDirectory: isDirectory,
            fileExists: nothingExists
        )
        XCTAssertEqual(
            plans[0].decision,
            .proceed(destinationURL: URL(fileURLWithPath: "/Backups/FolderA"))
        )
    }

    // MARK: - Same directory (no-op)

    func testMovingFileIntoItsOwnParentIsNoOp() {
        let plans = FileMovePlanner.plan(
            sourceURLs: [URL(fileURLWithPath: "/Projects/foo.txt")],
            destinationDirectory: URL(fileURLWithPath: "/Projects/"),
            isDirectory: notADirectory,
            fileExists: nothingExists
        )
        XCTAssertEqual(plans[0].decision, .noOp)
    }

    func testMovingFolderIntoItsOwnParentIsNoOp() {
        let isDirectory: (URL) -> Bool = { $0.lastPathComponent == "FolderA" }
        let plans = FileMovePlanner.plan(
            sourceURLs: [URL(fileURLWithPath: "/Projects/FolderA")],
            destinationDirectory: URL(fileURLWithPath: "/Projects"),
            isDirectory: isDirectory,
            fileExists: nothingExists
        )
        XCTAssertEqual(plans[0].decision, .noOp)
    }

    // MARK: - Invalid guards

    func testFolderIntoItselfRejected() {
        let isDirectory: (URL) -> Bool = { $0.lastPathComponent == "FolderA" }
        let plans = FileMovePlanner.plan(
            sourceURLs: [URL(fileURLWithPath: "/Projects/FolderA")],
            destinationDirectory: URL(fileURLWithPath: "/Projects/FolderA"),
            isDirectory: isDirectory,
            fileExists: nothingExists
        )
        guard case .invalid = plans[0].decision else {
            return XCTFail("expected invalid, got \(plans[0].decision)")
        }
    }

    func testFolderIntoDescendantRejected() {
        let isDirectory: (URL) -> Bool = { $0.pathComponents.contains("FolderA") }
        let plans = FileMovePlanner.plan(
            sourceURLs: [URL(fileURLWithPath: "/Projects/FolderA")],
            destinationDirectory: URL(fileURLWithPath: "/Projects/FolderA/Subfolder"),
            isDirectory: isDirectory,
            fileExists: nothingExists
        )
        guard case .invalid = plans[0].decision else {
            return XCTFail("expected invalid, got \(plans[0].decision)")
        }
    }

    func testDeepDescendantRejected() {
        let isDirectory: (URL) -> Bool = { $0.pathComponents.contains("FolderA") }
        let plans = FileMovePlanner.plan(
            sourceURLs: [URL(fileURLWithPath: "/Projects/FolderA")],
            destinationDirectory: URL(fileURLWithPath: "/Projects/FolderA/a/b/c"),
            isDirectory: isDirectory,
            fileExists: nothingExists
        )
        guard case .invalid = plans[0].decision else {
            return XCTFail("expected invalid, got \(plans[0].decision)")
        }
    }

    func testSiblingPrefixIsNotAncestor() {
        // /foo/bar as a folder, destination /foo/barista: NOT a descendant.
        let isDirectory: (URL) -> Bool = { $0.lastPathComponent == "bar" }
        let plans = FileMovePlanner.plan(
            sourceURLs: [URL(fileURLWithPath: "/foo/bar")],
            destinationDirectory: URL(fileURLWithPath: "/foo/barista"),
            isDirectory: isDirectory,
            fileExists: nothingExists
        )
        XCTAssertEqual(
            plans[0].decision,
            .proceed(destinationURL: URL(fileURLWithPath: "/foo/barista/bar"))
        )
    }

    func testSiblingFileIsNotAncestor() {
        // File /foo/bar.txt moving into /foo/barista — a normal move.
        let plans = FileMovePlanner.plan(
            sourceURLs: [URL(fileURLWithPath: "/foo/bar.txt")],
            destinationDirectory: URL(fileURLWithPath: "/foo/barista"),
            isDirectory: notADirectory,
            fileExists: nothingExists
        )
        XCTAssertEqual(
            plans[0].decision,
            .proceed(destinationURL: URL(fileURLWithPath: "/foo/barista/bar.txt"))
        )
    }

    // MARK: - Destination conflicts

    func testDestinationConflictDetected() {
        let fileExists: (URL) -> Bool = { $0.path == "/Backups/foo.txt" }
        let plans = FileMovePlanner.plan(
            sourceURLs: [URL(fileURLWithPath: "/Projects/foo.txt")],
            destinationDirectory: URL(fileURLWithPath: "/Backups"),
            isDirectory: notADirectory,
            fileExists: fileExists
        )
        XCTAssertEqual(
            plans[0].decision,
            .conflict(destinationURL: URL(fileURLWithPath: "/Backups/foo.txt"))
        )
    }

    func testConflictOnlyForExactDestinationName() {
        let fileExists: (URL) -> Bool = { $0.path == "/Backups/foo.txt" }
        let plans = FileMovePlanner.plan(
            sourceURLs: [URL(fileURLWithPath: "/Projects/bar.txt")],
            destinationDirectory: URL(fileURLWithPath: "/Backups"),
            isDirectory: notADirectory,
            fileExists: fileExists
        )
        XCTAssertEqual(
            plans[0].decision,
            .proceed(destinationURL: URL(fileURLWithPath: "/Backups/bar.txt"))
        )
    }

    // MARK: - Batch behavior

    func testMultiItemPlanIsPerItem() {
        let isDirectory: (URL) -> Bool = { $0.lastPathComponent == "FolderA" }
        let fileExists: (URL) -> Bool = { $0.path == "/Projects/Backup/b.txt" }
        let plans = FileMovePlanner.plan(
            sourceURLs: [
                URL(fileURLWithPath: "/Projects/a.txt"),
                URL(fileURLWithPath: "/Projects/b.txt"),
                URL(fileURLWithPath: "/Projects/FolderA"),
            ],
            destinationDirectory: URL(fileURLWithPath: "/Projects/Backup/"),
            isDirectory: isDirectory,
            fileExists: fileExists
        )
        XCTAssertEqual(plans.count, 3)
        XCTAssertEqual(plans[0].decision, .proceed(destinationURL: URL(fileURLWithPath: "/Projects/Backup/a.txt")))
        XCTAssertEqual(plans[1].decision, .conflict(destinationURL: URL(fileURLWithPath: "/Projects/Backup/b.txt")))
        XCTAssertEqual(plans[2].decision, .proceed(destinationURL: URL(fileURLWithPath: "/Projects/Backup/FolderA")))
    }
}
