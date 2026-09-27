import XCTest
@testable import CleanupCore

final class ScannerSafetyRegressionTests: XCTestCase, @unchecked Sendable {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sweep-ScannerSafety-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    private func file(_ path: String, content: String = "fixture") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }

    func testRemovalOfProjectInsideKeptAncestorIsRefusedWithoutMatchingSiblingPrefix() async throws {
        let kept = root.appendingPathComponent("保留目录")
        let project = try file("保留目录/子项目/成品.txt").deletingLastPathComponent()
        let sibling = try file("保留目录-copy/子项目/成品.txt").deletingLastPathComponent()
        let scanner = ProjectScanner()
        let blocked = try await scanner.scan(ScanRequest(root: project, mode: .remove, protectedPaths: [kept.path]))
        let blockedRoot = try XCTUnwrap(blocked.items.first { $0.path == project.path })
        XCTAssertFalse(blockedRoot.isSelectable)
        XCTAssertThrowsError(try SelectionPlanner.makePlan(items: blocked.items, selectedIDs: [blockedRoot.id]))

        let allowed = try await scanner.scan(ScanRequest(root: sibling, mode: .remove, protectedPaths: [kept.path]))
        XCTAssertEqual(allowed.items.filter(\.isSelectable).map(\.path), [sibling.path])
    }

    func testRemovalRejectsFileAddedAfterInventoryBeforeFinalVerification() async throws {
        try file("已扫描.txt")
        let project = try XCTUnwrap(root)
        let added = project.appendingPathComponent("扫描后新建.txt")
        do {
            _ = try await ProjectScanner().scan(ScanRequest(root: project, mode: .remove)) { progress in
                if progress.path == project.path, progress.phase == .verification {
                    try? Data("not in the reviewed inventory".utf8).write(to: added)
                }
            }
            XCTFail("A newly captured baseline must not accept a file missing from the inventory")
        } catch CleanupError.changed { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: added.path), "The mutation must occur to exercise the regression")
    }

    func testRemovalRejectsFileModifiedAfterInventoryBeforeFinalVerification() async throws {
        let changed = try file("嵌套/已扫描.txt")
        let project = try XCTUnwrap(root)
        let newBody = Data("new document content after it was listed".utf8)
        do {
            _ = try await ProjectScanner().scan(ScanRequest(root: project, mode: .remove)) { progress in
                if progress.path == project.path, progress.phase == .verification {
                    try? newBody.write(to: changed)
                }
            }
            XCTFail("A changed descendant must invalidate the original inventory snapshot")
        } catch CleanupError.changed { }
        XCTAssertEqual(try Data(contentsOf: changed), newBody)
    }

    func testRemovalRetainsVersionHistorySnapshotsAndAcceptsUnchangedGitProject() async throws {
        let source = try file("源码.swift")
        for arguments in [["init", "-q", root.path], ["-C", root.path, "add", source.lastPathComponent]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try file(".svn/pristine/fixture")
        try file(".hg/store/fixture")
        let scan = try await ProjectScanner().scan(ScanRequest(root: root, mode: .remove))
        XCTAssertEqual(scan.items.filter(\.isSelectable).map(\.path), [root.path])
        for name in [".git", ".svn", ".hg"] {
            let history = try XCTUnwrap(scan.items.first { $0.title == name })
            XCTAssertNotNil(history.snapshot?.treeDigest, "Removal must retain the visited history baseline: \(name)")
            XCTAssertNoThrow(try Snapshotter.verify(history.url, matches: XCTUnwrap(history.snapshot)))
        }
        let project = try XCTUnwrap(scan.items.first { $0.path == root.path })
        XCTAssertNoThrow(try Snapshotter.verify(project.url, matches: XCTUnwrap(project.snapshot)))
        XCTAssertEqual(try SelectionPlanner.makePlan(items: scan.items, selectedIDs: [project.id]).items.count, 1)
    }

    func testDirectlySelectedToolConfigurationDescendantsStaySystemProtected() async throws {
        for directory in [".agents", ".claude", ".codex", ".cursor"] {
            let skill = try file("项目/\(directory)/skills/custom/SKILL.md")
            let cache = try file("项目/\(directory)/skills/custom/.DS_Store")
            let project = skill.deletingLastPathComponent()
            let result = try await ProjectScanner().scan(ScanRequest(root: project))
            for path in [skill.path, cache.path] {
                let item = try XCTUnwrap(result.items.first { $0.path == path })
                XCTAssertFalse(item.isSelectable, path)
                XCTAssertEqual(item.metadata["systemProtection"], "true", path)
                XCTAssertThrowsError(try SelectionPlanner.makePlan(items: result.items, selectedIDs: [item.id]))
            }
        }
    }

    func testConfigurationProtectionDoesNotMatchSimilarDirectoryNames() async throws {
        let cache = try file("项目/.agents-copy/custom/.DS_Store")
        let result = try await ProjectScanner().scan(ScanRequest(root: cache.deletingLastPathComponent()))
        let entry = try XCTUnwrap(result.items.first { $0.path == cache.path })
        XCTAssertTrue(entry.isSelectable)
        XCTAssertEqual(entry.risk, .recommended)
        XCTAssertNil(entry.metadata["systemProtection"])
    }

    func testIncompleteSizePropagatesThroughAllAncestorsButNotSibling() async throws {
        let target = try file("独立/成品.txt")
        let known = try file("外层/内层/已知.txt", content: "known")
        let link = known.deletingLastPathComponent().appendingPathComponent("未扫描链接")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let result = try await ProjectScanner().scan(ScanRequest(root: root))
        for path in [root.path, root.appendingPathComponent("外层").path, known.deletingLastPathComponent().path] {
            let item = try XCTUnwrap(result.items.first { $0.path == path })
            XCTAssertEqual(item.metadata["sizeIncomplete"], "true", path)
            XCTAssertFalse(item.isSelectable)
        }
        let partial = try XCTUnwrap(result.items.first { $0.path == known.deletingLastPathComponent().path })
        XCTAssertEqual(partial.bytes, Int64("known".utf8.count), "Retain measured bytes without treating unknown content as zero")
        let sibling = try XCTUnwrap(result.items.first { $0.path == target.deletingLastPathComponent().path })
        XCTAssertNil(sibling.metadata["sizeIncomplete"])
    }
}
