import XCTest
@testable import CleanupCore

final class ProjectStorageBreakdownTests: XCTestCase {
    private func item(_ relative: String, bytes: Int64 = 0, directory: Bool = false,
                      category: CleanupCategory = .other, risk: CleanupRisk = .review,
                      complete: Bool = true) -> CleanupItem {
        let path = relative.isEmpty ? "/项目" : "/项目/" + relative
        return CleanupItem(path: path, rootPath: "/项目", category: category, risk: risk, reason: "fixture",
                           bytes: bytes, isDirectory: directory,
                           parentPath: relative.isEmpty ? nil : URL(fileURLWithPath: path).deletingLastPathComponent().path,
                           snapshot: complete ? FileSnapshot(device: 1, inode: 1, size: bytes, modifiedNanoseconds: 0, mode: 0) : nil)
    }

    // Adding ordinary parent sizes would double the real occupied bytes.
    func testMixedProjectCountsEachFileOnlyOnceAndExcludesToolData() {
        let items = [item("", bytes: 100, directory: true), item("素材", bytes: 60, directory: true),
                     item("素材/photo.PNG", bytes: 20, category: .document), item("素材/movie.mov", bytes: 30, category: .document),
                     item("素材/sound.flac", bytes: 10), item("README.md", bytes: 5, category: .source),
                     item("报告.pdf", bytes: 15, category: .document), item("notes.txt", bytes: 10), item("unknown.dat", bytes: 10),
                     CleanupItem(path: "/tool/log", rootPath: "/tool", reason: "fixture", bytes: 500, tool: .claude)]
        let result = ProjectStorageBreakdown(items: items)
        XCTAssertEqual(result.totalBytes, 100)
        XCTAssertEqual(result.segments.reduce(0) { $0 + $1.count }, 7)
        XCTAssertEqual(result.segments.first { $0.kind == .images }?.bytes, 20)
        XCTAssertEqual(result.segments.first { $0.kind == .video }?.bytes, 30)
        XCTAssertEqual(result.segments.first { $0.kind == .audio }?.bytes, 10)
        XCTAssertEqual(result.segments.first { $0.kind == .documents }?.bytes, 25)
        XCTAssertTrue(result.isComplete)
    }

    // Counting a cache directory and its descendants would inflate the cache segment.
    func testNestedCacheUsesOneUnitWhileSourceWithinReviewCacheRemainsSource() {
        let items = [item("", directory: true), item("__pycache__", bytes: 40, directory: true, category: .cache, risk: .recommended),
                     item("__pycache__/nested", bytes: 40, directory: true), item("__pycache__/nested/file.pyc", bytes: 40),
                     item(".pytest_cache", bytes: 15, directory: true, category: .cache),
                     item(".pytest_cache/important.py", bytes: 5, category: .source), item(".pytest_cache/state", bytes: 10)]
        let result = ProjectStorageBreakdown(items: items)
        XCTAssertEqual(result.totalBytes, 55)
        XCTAssertEqual(result.segments.first { $0.kind == .cache }?.bytes, 50)
        XCTAssertEqual(result.segments.first { $0.kind == .cache }?.count, 2)
        XCTAssertEqual(result.segments.first { $0.kind == .source }?.bytes, 5)
    }

    // Dropping parent context would mislabel dependency and build output as user source/documents.
    func testDependencyAndBuildContextDoesNotOverrideProtectedSource() {
        let items = [item("", directory: true), item("node_modules", bytes: 36, directory: true, category: .dependency),
                     item("node_modules/library", bytes: 36, directory: true), item("node_modules/library/index.js", bytes: 30, category: .source),
                     item("node_modules/library/user.swift", bytes: 6, category: .source, risk: .protected),
                     item("build", bytes: 20, directory: true, category: .build), item("build/output.js", bytes: 20, category: .source)]
        let result = ProjectStorageBreakdown(items: items)
        XCTAssertEqual(result.segments.first { $0.kind == .dependencies }?.bytes, 30)
        XCTAssertEqual(result.segments.first { $0.kind == .build }?.bytes, 20)
        XCTAssertEqual(result.segments.first { $0.kind == .source }?.bytes, 6)
        XCTAssertEqual(result.totalBytes, 56)
    }

    // Paths, not basenames, determine identity; opaque documents count as one complete item.
    func testSameNamedFilesAndOpaqueDocumentPackagesRemainDistinct() {
        let items = [item("", directory: true), item("A", bytes: 7, directory: true), item("B", bytes: 8, directory: true),
                     item("A/photo.png", bytes: 7, category: .document), item("B/photo.png", bytes: 8, category: .document),
                     item("作品.pages", bytes: 20, directory: true, category: .document)]
        let result = ProjectStorageBreakdown(items: items)
        XCTAssertEqual(result.totalBytes, 35)
        XCTAssertEqual(result.segments.first { $0.kind == .images }?.count, 2)
        XCTAssertEqual(result.segments.first { $0.kind == .documents }?.count, 1)
        XCTAssertEqual(result.segments.first { $0.kind == .documents }?.bytes, 20)
    }

    // Unknown sizes must not masquerade as a fully measured zero-byte segment.
    func testUnreadableDirectoryMarksOnlyItsSegmentAndTotalIncomplete() {
        let items = [item("", bytes: 7, directory: true), item("photo.jpg", bytes: 7, category: .document),
                     item("private", directory: true, risk: .unavailable, complete: false)]
        let result = ProjectStorageBreakdown(items: items)
        XCTAssertEqual(result.totalBytes, 7)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.segments.first { $0.kind == .other }?.count, 1)
        XCTAssertEqual(result.segments.first { $0.kind == .other }?.incomplete, true)
        XCTAssertEqual(result.segments.first { $0.kind == .images }?.incomplete, false)
    }

    // Category filters need file and atomic-container identities, never a mixed parent aggregate.
    func testStorageIndexExposesOnlyFilesAndAccountingUnitsForFiltering() {
        let items = [item("", directory: true), item("mixed", directory: true), item("mixed/file.pdf", bytes: 10, category: .document),
                     item("mixed/file.png", bytes: 20, category: .document),
                     item("__pycache__", bytes: 50, directory: true, category: .cache, risk: .recommended),
                     item("__pycache__/file.pyc", bytes: 50)]
        let index = ProjectStorageIndex(items: items)
        XCTAssertNil(index.filterKind(for: items[0]))
        XCTAssertNil(index.filterKind(for: items[1]))
        XCTAssertEqual(index.filterKind(for: items[2]), .documents)
        XCTAssertEqual(index.filterKind(for: items[3]), .images)
        XCTAssertEqual(index.filterKind(for: items[4]), .cache)
        XCTAssertEqual(index.filterKind(for: items[5]), .cache)
    }
    // Remove mode disables individual cleanup; that UI permission must not relabel dependencies as user source.
    func testWholeProjectRemovalKeepsDependencySpaceClassification() {
        let root = item("", directory: true)
        let directory = item("node_modules", bytes: 30, directory: true, category: .dependency, risk: .protected)
        var source = item("node_modules/index.js", bytes: 30, category: .source, risk: .protected)
        source.metadata["projectMode"] = "remove"
        let result = ProjectStorageBreakdown(items: [root, directory, source])
        XCTAssertEqual(result.segments.first { $0.kind == .dependencies }?.bytes, 30)
        XCTAssertNil(result.segments.first { $0.kind == .source })
    }

}
