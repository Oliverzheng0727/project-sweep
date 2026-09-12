import XCTest
@testable import CleanupCore

final class UsabilityCoreTests: XCTestCase, @unchecked Sendable {
    private func withRoot(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-usability-\(UUID())").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }
    private func write(_ root: URL, _ path: String, _ content: String = "fixture") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
    func testSkillsAndParentsRemainProtectedWithoutUserKeepRule() async throws {
        try await withRoot { root in
            try write(root, "nested/.agents/skills/example/SKILL.md")
            try write(root, "nested/normal.txt")
            let result = try await ProjectScanner().scan(ScanRequest(root: root, protectedPaths: []))
            for path in ["nested", "nested/.agents", "nested/.agents/skills/example/SKILL.md"] {
                let item = try XCTUnwrap(result.items.first { $0.path == root.appendingPathComponent(path).path })
                XCTAssertFalse(item.isSelectable)
                XCTAssertEqual(item.metadata["systemProtection"], "true")
                XCTAssertThrowsError(try SelectionPlanner.makePlan(items: result.items, selectedIDs: [item.id]))
            }
            let remove = try await ProjectScanner().scan(ScanRequest(root: root, mode: .remove))
            XCTAssertEqual(remove.items.filter(\.isSelectable).map(\.path), [root.path])
        }
    }
    func testOverviewCountsCacheOnceAndSeparatesProtectedFiles() async throws {
        try await withRoot { root in
            try write(root, "__pycache__/nested/fixture.pyc", "1234")
            try write(root, ".agents/skills/a/SKILL.md", "12345")
            try write(root, "作品.txt", "123")
            try write(root, "作品.app/Contents/data", "12")
            let scan = try await ProjectScanner().scan(ScanRequest(root: root))
            let summary = ProjectOverview(items: scan.items)
            XCTAssertEqual(summary.inventoryCount, scan.items.filter { $0.tool == nil && $0.path != root.path }.count)
            XCTAssertEqual(summary.totalBytes, 14)
            XCTAssertEqual(summary.summary(for: .recommended).count, 1)
            XCTAssertEqual(summary.summary(for: .recommended).bytes, 4)
            XCTAssertEqual(summary.summary(for: .protected).bytes, 5)
            XCTAssertTrue(summary.isComplete)
            XCTAssertFalse(summary.units.contains { $0.path == root.path })
        }
    }
    func testSourceInsideCacheIsNeverAbsorbedAsRecommended() async throws {
        try await withRoot { root in
            try write(root, "__pycache__/important.py", "12")
            try write(root, "__pycache__/fixture.pyc", "1234")
            let scan = try await ProjectScanner().scan(ScanRequest(root: root))
            let summary = ProjectOverview(items: scan.items)
            XCTAssertEqual(summary.totalBytes, 6)
            XCTAssertEqual(summary.summary(for: .recommended).count, 0)
            XCTAssertEqual(summary.summary(for: .review).count, 2)
        }
    }
    func testUnknownSizeAndOpaqueUnitsDoNotClaimCompleteZero() {
        let item = CleanupItem(path: "/fixture/private", rootPath: "/fixture", risk: .unavailable, reason: "no access", isDirectory: true)
        let result = ProjectOverview(items: [item])
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.summary(for: .unavailable).incomplete)
        XCTAssertEqual(result.units.count, 1)
    }
    func testTypedEmptyUnsupportedAndRecoveryStates() async throws {
        try await withRoot { root in
            var scan = try await ToolDataService().scan(ToolConfiguration(tool: .claude, root: root))
            XCTAssertEqual(scan.toolStatus?.sessionRead, .unsupported)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"), withIntermediateDirectories: false)
            scan = try await ToolDataService().scan(ToolConfiguration(tool: .claude, root: root))
            XCTAssertEqual(scan.toolStatus?.sessionRead, .complete)
            XCTAssertTrue(scan.items.isEmpty)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cache"), withDestinationURL: root.deletingLastPathComponent())
            scan = try await ToolDataService().scan(ToolConfiguration(tool: .claude, root: root))
            XCTAssertEqual(scan.toolStatus?.sessionRead, .complete)
            XCTAssertEqual(scan.toolStatus?.filesIncomplete, true)
            try write(root, ".project-sweep-transaction/manifest.json", "{}")
            scan = try await ToolDataService().scan(ToolConfiguration(tool: .claude, root: root))
            XCTAssertEqual(scan.toolStatus?.sessionRead, .failed)
            XCTAssertEqual(scan.toolStatus?.requiresRecovery, true)
            let cursor = try await ToolDataService().scan(ToolConfiguration(tool: .cursor, root: root))
            XCTAssertEqual(cursor.toolStatus?.sessionRead, .unsupported)
            XCTAssertEqual(cursor.toolStatus?.sessionDeletion, .unavailable)
        }
    }
    func testMalformedTranscriptProducesPartialReading() async throws {
        try await withRoot { root in
            try write(root, "projects/a/\(UUID()).jsonl", "not-json")
            let scan = try await ToolDataService().scan(ToolConfiguration(tool: .claude, root: root))
            XCTAssertEqual(scan.toolStatus?.sessionRead, .partial)
            XCTAssertFalse(scan.items.contains(where: \.isSelectable))
        }
    }
}
