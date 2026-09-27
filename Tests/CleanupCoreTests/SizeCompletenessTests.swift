import XCTest
@testable import CleanupCore

final class SizeCompletenessTests: XCTestCase {
    // A protected opaque directory may have only a partial byte total; protection does not prove size completeness.
    func testPartialDirectorySizeRemainsIncompleteInProtectedOverview() throws {
        let item = CleanupItem(path: "/项目/资料", rootPath: "/项目", risk: .protected,
            reason: "包含无法校验的内容", bytes: 123, isDirectory: true, parentPath: "/项目",
            snapshot: FileSnapshot(device: 1, inode: 2, size: 0, modifiedNanoseconds: 0, mode: 0),
            metadata: ["sizeIncomplete": "true"])
        let decoded = try JSONDecoder().decode(CleanupItem.self, from: JSONEncoder().encode(item))
        let overview = ProjectOverview(items: [decoded])
        XCTAssertFalse(overview.isComplete)
        XCTAssertTrue(overview.summary(for: .protected).incomplete)
        XCTAssertEqual(overview.totalBytes, 123, "Keep the observed byte total without presenting it as complete")
        XCTAssertFalse(decoded.isSelectable, "Size presentation must not weaken cleanup protection")
    }

    // An actual zero-byte file is a known measurement; a missing snapshot is not.
    func testKnownZeroAndUnverifiedZeroAreDistinguished() {
        var item = CleanupItem(path: "/项目/empty.txt", rootPath: "/项目", reason: "fixture", bytes: 0,
            snapshot: FileSnapshot(device: 1, inode: 2, size: 0, modifiedNanoseconds: 0, mode: 0))
        XCTAssertTrue(ProjectOverview(items: [item]).isComplete)
        item.snapshot = nil
        XCTAssertFalse(ProjectOverview(items: [item]).isComplete)
    }
}
