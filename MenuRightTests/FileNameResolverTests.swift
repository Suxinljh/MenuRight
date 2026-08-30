import XCTest

final class FileNameResolverTests: XCTestCase {
    func testPreferredNameIsUsedWhenUnused() {
        XCTAssertEqual(FileNameResolver.uniqueName(preferred: "Untitled.txt", existing: []), "Untitled.txt")
    }

    func testFirstCollisionAppendsTwo() {
        XCTAssertEqual(FileNameResolver.uniqueName(preferred: "Untitled.txt", existing: ["Untitled.txt"]), "Untitled 2.txt")
    }

    func testSequenceIsUntitledTwoThree() {
        XCTAssertEqual(
            FileNameResolver.uniqueName(preferred: "Untitled.txt", existing: ["Untitled.txt", "Untitled 2.txt"]),
            "Untitled 3.txt"
        )
    }

    func testFirstFreeSlotIsUsed() {
        XCTAssertEqual(
            FileNameResolver.uniqueName(preferred: "Untitled.txt", existing: ["Untitled.txt", "Untitled 3.txt"]),
            "Untitled 2.txt"
        )
    }

    func testPreferredNameUsedWhenOnlyVariantsExist() {
        // "Untitled 2.txt" exists but the base name is free — use the base name.
        XCTAssertEqual(
            FileNameResolver.uniqueName(preferred: "Untitled.txt", existing: ["Untitled 2.txt"]),
            "Untitled.txt"
        )
    }

    func testMarkdownExtensionPreserved() {
        XCTAssertEqual(
            FileNameResolver.uniqueName(preferred: "Untitled.md", existing: ["Untitled.md"]),
            "Untitled 2.md"
        )
    }

    func testJSONExtensionPreserved() {
        XCTAssertEqual(
            FileNameResolver.uniqueName(preferred: "Untitled.json", existing: ["Untitled.json", "Untitled 2.json"]),
            "Untitled 3.json"
        )
    }

    func testMultipleDotName() {
        XCTAssertEqual(
            FileNameResolver.uniqueName(preferred: "archive.tar.gz", existing: ["archive.tar.gz"]),
            "archive.tar 2.gz"
        )
    }

    func testExtensionlessName() {
        XCTAssertEqual(FileNameResolver.uniqueName(preferred: "README", existing: ["README"]), "README 2")
    }

    func testChineseName() {
        XCTAssertEqual(
            FileNameResolver.uniqueName(preferred: "报告.txt", existing: ["报告.txt"]),
            "报告 2.txt"
        )
    }

    func testEmojiName() {
        XCTAssertEqual(
            FileNameResolver.uniqueName(preferred: "照片 😀.txt", existing: ["照片 😀.txt"]),
            "照片 😀 2.txt"
        )
    }

    func testHiddenFileStaysExtensionless() {
        XCTAssertEqual(FileNameResolver.uniqueName(preferred: ".env", existing: [".env"]), ".env 2")
    }

    func testCaseInsensitiveComparison() {
        XCTAssertEqual(
            FileNameResolver.uniqueName(preferred: "Untitled.txt", existing: ["UNTITLED.TXT"]),
            "Untitled 2.txt"
        )
    }

    func testNewFolderSequence() {
        XCTAssertEqual(
            FileNameResolver.uniqueName(preferred: "New Folder", existing: ["New Folder", "New Folder 2"]),
            "New Folder 3"
        )
    }
}
