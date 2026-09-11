import XCTest
@testable import CleanupCore

final class ProjectScannerTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Sweep-测试-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }
    @discardableResult private func file(_ name: String, _ body: String = "content") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
        return url
    }
    func testMixedProjectPreservesWorksAndDoesNotGuessOldNames() async throws {
        try file("__pycache__/main.pyc")
        try file("dist/演示.pdf")
        try file("最终版.pptx")
        try file("旧版素材.png")
        try file("temp_analysis.py")
        let result = try await ProjectScanner().scan(ScanRequest(root: root))
        XCTAssertEqual(result.items.first { $0.title == "__pycache__" }?.risk, .recommended)
        XCTAssertEqual(result.items.first { $0.title == "dist" }?.risk, .review)
        for name in ["最终版.pptx", "旧版素材.png", "temp_analysis.py"] {
            XCTAssertEqual(result.items.first { $0.title == name }?.risk, .review)
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("最终版.pptx"), encoding: .utf8), "content")
    }
    func testKeepRuleProtectsAncestorButNotUnrelatedCache() async throws {
        let keep = try file("exports/成品.pdf")
        try file("exports/scratch.txt")
        try file("__pycache__/a.pyc")
        let result = try await ProjectScanner().scan(ScanRequest(root: root, protectedPaths: [keep.path]))
        XCTAssertEqual(result.items.first { $0.title == "exports" }?.risk, .protected)
        XCTAssertEqual(result.items.first { $0.path == keep.path }?.risk, .protected)
        XCTAssertEqual(result.items.first { $0.title == "__pycache__" }?.risk, .recommended)
    }
    func testSymlinkIsNeverFollowedAndAncestorCannotBeSelected() async throws {
        let outside = try file("outside.txt")
        let folder = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: outside)
        let result = try await ProjectScanner().scan(ScanRequest(root: root))
        XCTAssertEqual(result.items.first { $0.title == "link" }?.risk, .unavailable)
        XCTAssertFalse(result.items.first { $0.title == "work" }!.isSelectable)
    }
    func testChangedNestedFileInvalidatesDirectorySnapshot() async throws {
        let url = try file("__pycache__/child/a.pyc")
        let result = try await ProjectScanner().scan(ScanRequest(root: root))
        let cache = try XCTUnwrap(result.items.first { $0.title == "__pycache__" })
        try Data("changed longer content".utf8).write(to: url)
        XCTAssertThrowsError(try Snapshotter.verify(cache.url, matches: XCTUnwrap(cache.snapshot)))
    }
    func testParentAndChildSelectionsAreDeduplicated() async throws {
        try file("__pycache__/a.pyc")
        let result = try await ProjectScanner().scan(ScanRequest(root: root))
        let selected = result.items.filter { $0.title == "__pycache__" || $0.title == "a.pyc" }
        let plan = try SelectionPlanner.makePlan(items: result.items, selectedIDs: Set(selected.map(\.id)))
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items[0].title, "__pycache__")
    }
    func testGitTrackedFileAndItsAncestorAreProtected() async throws {
        try file("dist/keep.txt")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["init", "-q", root.path]; try p.run(); p.waitUntilExit()
        let a = Process(); a.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        a.arguments = ["-C", root.path, "add", "dist/keep.txt"]; try a.run(); a.waitUntilExit()
        let result = try await ProjectScanner().scan(ScanRequest(root: root))
        XCTAssertEqual(result.items.first { $0.title == "keep.txt" }?.risk, .protected)
        XCTAssertEqual(result.items.first { $0.title == "dist" }?.risk, .protected)
    }
    func testRemovalModeOnlyOffersWholeRoot() async throws {
        try file("源码.swift")
        let result = try await ProjectScanner().scan(ScanRequest(root: root, mode: .remove))
        XCTAssertEqual(result.items.filter(\.isSelectable).map(\.path), [root.path])
    }
    func testCancelledScanDoesNotReturnPartialSelectableResults() async throws {
        for i in 0..<100 { try file("a/\(i).txt") }
        let task = Task { try await ProjectScanner().scan(ScanRequest(root: root)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { }
    }
    func testLargeTreeAndMidScanCancellation() async throws {
        for group in 0..<20 {
            for index in 0..<500 { try file("目录\(group)/文件\(index).txt", "x") }
        }
        let complete = try await ProjectScanner().scan(ScanRequest(root: root))
        XCTAssertEqual(complete.items.count, 10_021)
        XCTAssertEqual(complete.items.first { $0.path == root.path }?.bytes, 10_000)
        do {
            _ = try await ProjectScanner().scan(ScanRequest(root: root)) { progress in
                if progress.count >= 100 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            XCTFail("Mid-scan cancellation must not return a partial actionable inventory")
        } catch is CancellationError { }
    }
    func testPackageContentsStayOpaqueButChangesInvalidatePackageAndAncestor() async throws {
        let content = try file("exports/Document.app/Contents/data.txt")
        let result = try await ProjectScanner().scan(ScanRequest(root: root))
        XCTAssertFalse(result.items.contains { $0.path == content.path })
        let package = try XCTUnwrap(result.items.first { $0.title == "Document.app" })
        let parent = try XCTUnwrap(result.items.first { $0.title == "exports" })
        let handle = try FileHandle(forWritingTo: content)
        try handle.write(contentsOf: Data("changed inside existing file".utf8)); try handle.close()
        XCTAssertThrowsError(try Snapshotter.verify(package.url, matches: XCTUnwrap(package.snapshot)))
        XCTAssertThrowsError(try Snapshotter.verify(parent.url, matches: XCTUnwrap(parent.snapshot)))
    }
    func testKeepPathInsideOpaquePackageProtectsPackageAndAncestor() async throws {
        let keep = try file("exports/Document.app/Contents/data.txt")
        let result = try await ProjectScanner().scan(ScanRequest(root: root, protectedPaths: [keep.path]))
        for name in ["Document.app", "exports"] {
            XCTAssertFalse(try XCTUnwrap(result.items.first { $0.title == name }).isSelectable)
        }
    }
    func testPackageRootIsAtomicInBothModes() async throws {
        try file("Document.app/Contents/data.txt")
        let package = root.appendingPathComponent("Document.app")
        for mode in [ProjectMode.organize, .remove] {
            let result = try await ProjectScanner().scan(ScanRequest(root: package, mode: mode))
            XCTAssertEqual(result.items.count, 1)
            XCTAssertEqual(result.items[0].isSelectable, mode == .remove)
            if mode == .remove { XCTAssertNotNil(result.items[0].snapshot?.treeDigest) }
        }
    }
    func testPackageWithSymlinkIsUnavailableWithoutExposingContents() async throws {
        let outside = try file("outside.txt")
        try file("Document.app/Contents/data.txt")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Document.app/Contents/link"), withDestinationURL: outside)
        let result = try await ProjectScanner().scan(ScanRequest(root: root))
        XCTAssertEqual(result.items.first { $0.title == "Document.app" }?.risk, .unavailable)
        XCTAssertFalse(result.items.contains { $0.title == "link" })
    }

    func testUnreadablePackageInteriorFailsClosedIncludingRemovalRoot() async throws {
        let content = try file("Document.app/Contents/data.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: content.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: content.path) }
        let package = root.appendingPathComponent("Document.app")
        let result = try await ProjectScanner().scan(ScanRequest(root: package, mode: .remove))
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].risk, .unavailable)
    }
    func testRemovalRootWithKeepPathInsidePackageIsUnavailable() async throws {
        let keep = try file("Document.app/Contents/data.txt")
        let result = try await ProjectScanner().scan(ScanRequest(root: root, mode: .remove, protectedPaths: [keep.path]))
        XCTAssertFalse(result.items.contains(where: \.isSelectable))
    }
    func testDirectoryGitInventoryIncludesEveryNestedRepository() throws {
        for name in ["a", "b/deeper"] {
            let source = try file("exports/" + name + "/tracked.txt")
            let repo = source.deletingLastPathComponent()
            for args in [["init", "-q", repo.path], ["-C", repo.path, "add", "tracked.txt"]] {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args
                try p.run(); p.waitUntilExit(); XCTAssertEqual(p.terminationStatus, 0)
            }
        }
        let tracked = try GitInventory.trackedFilesForSelection(root.appendingPathComponent("exports"), isDirectory: true)
        XCTAssertEqual(tracked, Set([root.appendingPathComponent("exports/a/tracked.txt").path,
                                     root.appendingPathComponent("exports/b/deeper/tracked.txt").path]))
    }

    func testOpaquePackageAndGitBytesContributeToRemovalTotal() async throws {
        try file("Document.app/Contents/data.txt", "package bytes")
        try file(".git/objects/fixture", "git bytes")
        let result = try await ProjectScanner().scan(ScanRequest(root: root, mode: .remove))
        XCTAssertFalse(result.items.contains { $0.title == "data.txt" || $0.title == "fixture" })
        XCTAssertEqual(result.items.first { $0.title == "Document.app" }?.bytes, Int64("package bytes".utf8.count))
        XCTAssertEqual(result.items.first { $0.title == ".git" }?.bytes, Int64("git bytes".utf8.count))
        XCTAssertEqual(result.items.first { $0.path == root.path }?.bytes, Int64("package bytesgit bytes".utf8.count))
    }
    func testToolConfigurationDescendantsAreProtectedInOrganizeMode() async throws {
        for name in [".agents", ".claude", ".codex", ".cursor"] {
            try file(name + "/nested/auth.json")
            try file(name + "/skills/custom/SKILL.md")
        }
        try file("normal/auth.json")
        let result = try await ProjectScanner().scan(ScanRequest(root: root))
        for entry in result.items where [".agents", ".claude", ".codex", ".cursor"].contains(where: { PathSafety.isWithin(entry.path, root: root.appendingPathComponent($0).path) }) {
            XCTAssertFalse(entry.isSelectable, entry.path)
            XCTAssertThrowsError(try SelectionPlanner.makePlan(items: result.items, selectedIDs: [entry.id]))
        }
        XCTAssertTrue(try XCTUnwrap(result.items.first { $0.path == root.appendingPathComponent("normal/auth.json").path }).isSelectable)
    }

    func testTrackedMissingFileStillProtectsAncestorsWithoutMatchingSiblingPrefix() async throws {
        let tracked = try file("源码/嵌套/kept.swift")
        try file("源码-copy/__pycache__/free.pyc")
        try git(["init", "-q", root.path])
        try git(["-C", root.path, "add", "源码"])
        try FileManager.default.removeItem(at: tracked)
        let result = try await ProjectScanner().scan(ScanRequest(root: root))
        for path in ["源码", "源码/嵌套"] {
            let item = try XCTUnwrap(result.items.first { $0.path == root.appendingPathComponent(path).path })
            XCTAssertEqual(item.risk, .protected)
            XCTAssertEqual(item.metadata["systemProtection"], "true")
        }
        let sibling = try XCTUnwrap(result.items.first { $0.path == root.appendingPathComponent("源码-copy/__pycache__").path })
        XCTAssertEqual(sibling.risk, .recommended)
        XCTAssertNil(sibling.metadata["systemProtection"])
    }

    func testNestedRepoAndOpaquePackageExtendProtectionDuringScan() async throws {
        for path in ["nested/repo", "exports/作品.app"] {
            let source = try file(path + "/Contents/源码.swift")
            let repo = root.appendingPathComponent(path)
            try git(["init", "-q", repo.path])
            try git(["-C", repo.path, "add", "Contents/源码.swift"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
        try file("unrelated/__pycache__/free.pyc")
        let result = try await ProjectScanner().scan(ScanRequest(root: root))
        for path in ["nested", "nested/repo/Contents/源码.swift", "exports", "exports/作品.app"] {
            let item = try XCTUnwrap(result.items.first { $0.path == root.appendingPathComponent(path).path })
            XCTAssertEqual(item.risk, .protected)
            XCTAssertEqual(item.metadata["systemProtection"], "true")
        }
        XCTAssertFalse(result.items.contains { $0.path.hasPrefix(root.appendingPathComponent("exports/作品.app").path + "/") })
        XCTAssertEqual(result.items.first { $0.title == "__pycache__" }?.risk, .recommended)
    }

    func testRescanRefreshesTrackedProtection() async throws {
        let cache = try file("__pycache__/.DS_Store")
        try git(["init", "-q", root.path])
        let scanner = ProjectScanner()
        let before = try await scanner.scan(ScanRequest(root: root))
        XCTAssertEqual(before.items.first { $0.path == cache.path }?.risk, .recommended)
        try git(["-C", root.path, "add", "__pycache__/.DS_Store"])
        let after = try await scanner.scan(ScanRequest(root: root))
        for path in [cache.path, cache.deletingLastPathComponent().path] {
            let item = try XCTUnwrap(after.items.first { $0.path == path })
            XCTAssertEqual(item.risk, .protected)
            XCTAssertThrowsError(try SelectionPlanner.makePlan(items: after.items, selectedIDs: [item.id]))
        }
    }

    func testProgressStartsBeforeFileTraversal() async throws {
        final class Counts: @unchecked Sendable {
            let lock = NSLock()
            private var values: [Int] = []
            func append(_ value: Int) { lock.lock(); defer { lock.unlock() }; values.append(value) }
            func read() -> [Int] { lock.lock(); defer { lock.unlock() }; return values }
        }
        try file("作品.md")
        let counts = Counts()
        let result = try await ProjectScanner().scan(ScanRequest(root: root)) { counts.append($0.count) }
        XCTAssertEqual(counts.read().first, 0, "Show preparation before any file traversal, including small projects")
        XCTAssertEqual(counts.read().last, result.items.count)
    }

    private func git(_ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

}
