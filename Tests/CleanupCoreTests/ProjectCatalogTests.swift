import Darwin
import XCTest
@testable import CleanupCore

final class ProjectCatalogTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Sweep-项目库-\(UUID())").standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testCatalogListsProjectsWithoutRecursivelyScanningTheirContents() async throws {
        let a = try folder("个人简历/不应提前扫描")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: a.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: a.path) }
        _ = try folder("分镜图/内部目录")
        _ = try folder("作品.app/Contents")
        try Data("loose".utf8).write(to: root.appendingPathComponent("说明.txt"))
        let result = try await ProjectCatalog().list(root)
        XCTAssertEqual(Set(result.projects.map(\.title)), ["个人简历", "分镜图"])
        XCTAssertTrue(result.projects.allSatisfy(\.isAvailable))
        XCTAssertTrue(result.projects.allSatisfy { $0.snapshot.treeDigest == nil })
        XCTAssertEqual(result.looseFileCount, 2)
    }
    func testOpeningRejectsReplacedDirectoryAndSymbolicLink() async throws {
        let a = try folder("项目甲")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("链接"), withDestinationURL: a)
        let result = try await ProjectCatalog().list(root)
        let project = try XCTUnwrap(result.projects.first { $0.title == "项目甲" })
        XCTAssertEqual(try ProjectCatalog.validateOpening(project, from: result).path, a.path)
        XCTAssertFalse(try XCTUnwrap(result.projects.first { $0.title == "链接" }).isAvailable)
        try FileManager.default.moveItem(at: a, to: root.appendingPathComponent("原项目"))
        _ = try folder("项目甲")
        XCTAssertThrowsError(try ProjectCatalog.validateOpening(project, from: result))
    }
    func testNormalProjectChangesAreScannedFreshOnOpening() async throws {
        let a = try folder("项目甲")
        let result = try await ProjectCatalog().list(root)
        try Data("new".utf8).write(to: a.appendingPathComponent("新稿.txt"))
        XCTAssertEqual(try ProjectCatalog.validateOpening(result.projects[0], from: result).path, a.path)
    }
    func testFolderCreationDateIsIndependentOfModificationAndScanning() async throws {
        let projectURL = try folder("较早创建的项目")
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let modified = Date(timeIntervalSince1970: 1_750_000_000)
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified], ofItemAtPath: projectURL.path)
        let initial = try await ProjectCatalog().list(root)
        let project = try XCTUnwrap(initial.projects.first)
        XCTAssertEqual(try XCTUnwrap(project.createdAt).timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(project.modifiedAt.timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 1)
        try Data("新稿".utf8).write(to: projectURL.appendingPathComponent("新稿.txt"))
        _ = try await ProjectScanner().scan(ScanRequest(root: projectURL))
        let refreshed = try await ProjectCatalog().list(root)
        XCTAssertEqual(refreshed.projects.first?.createdAt, project.createdAt)
        XCTAssertNotEqual(refreshed.projects.first?.modifiedAt, project.modifiedAt)
    }
    func testProjectAssociationsDoNotMatchSiblingNamesOrGlobalCaches() {
        func item(_ id: String, path: String?, related: [String] = []) -> CleanupItem {
            CleanupItem(id: id, path: "/tool/\(id)", rootPath: "/tool", category: .session, reason: "test",
                tool: .claude, projectPath: path, relatedIDs: related, action: .deleteSession)
        }
        let inventory = [item("a", path: "/work/项目甲", related: ["child"]),
                         item("nested", path: "/work/项目甲/src"), item("sibling", path: "/work/项目甲备份"),
                         item("unknown", path: nil), item("child", path: "/work/项目乙", related: ["a"]),
                         CleanupItem(id: "cache", path: "/tool/cache", rootPath: "/tool", category: .toolCache, reason: "cache", tool: .claude)]
        let result = ProjectAssociations.items(for: URL(fileURLWithPath: "/work/项目甲"), from: inventory)
        XCTAssertEqual(Set(result.map(\.id)), ["a", "nested", "child"])
        XCTAssertTrue(result.first { $0.id == "child" }!.details.contains { $0.contains("项目乙") })
    }
    func testMissingAssociationStaysUnavailable() {
        let item = CleanupItem(id: "a", path: "/tool/a", rootPath: "/tool", reason: "test", tool: .codex,
            projectPath: "/work/a", relatedIDs: ["missing"], action: .deleteSession)
        let result = ProjectAssociations.items(for: URL(fileURLWithPath: "/work/a"), from: [item])
        XCTAssertEqual(result[0].risk, .unavailable)
        XCTAssertThrowsError(try SelectionPlanner.makePlan(items: result, selectedIDs: ["a"]))
    }
    func testProjectRemovalCannotOverlapSessionMutation() {
        let snapshot = FileSnapshot(device: 1, inode: 1, size: 0, modifiedNanoseconds: 0, mode: UInt32(S_IFDIR))
        let folder = CleanupItem(id: "folder", path: "/work/project", rootPath: "/work/project", reason: "test", isDirectory: true, snapshot: snapshot, metadata: ["projectMode": "remove"])
        let session = CleanupItem(id: "session", path: "/work/project/history/session.jsonl", rootPath: "/work/project/history", reason: "test", tool: .claude, action: .deleteSession)
        XCTAssertThrowsError(try SelectionPlanner.makePlan(items: [folder, session], selectedIDs: ["folder", "session"]))
    }
}
