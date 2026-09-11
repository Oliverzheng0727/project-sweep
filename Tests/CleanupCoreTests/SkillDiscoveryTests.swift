import XCTest
import Darwin
@testable import CleanupCore

final class SkillDiscoveryTests: XCTestCase, @unchecked Sendable {
    private var home: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("Sweep-SkillDiscovery-\(UUID())").standardizedFileURL
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }
    @discardableResult private func directory(_ path: String) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var discovery: SkillDiscovery { SkillDiscovery(home: home, environment: [:]) }

    func testDefaultLocationsAreScopedToTheirAIAndDoNotSearchUnrelatedProjects() async throws {
        for path in [".claude/skills", ".claude/plugins/cache", ".codex/skills", ".codex/plugins/cache", ".agents/skills",
                     "Documents/秘密项目/.claude/skills", ".cursor/skills", ".claude/plugins/marketplaces/other/skills"] {
            try directory(path)
        }
        let result = try await discovery.discover()
        XCTAssertTrue(result.warnings.isEmpty); XCTAssertEqual(result.roots.count, 5)
        XCTAssertEqual(result.roots.filter { $0.tool == .claude }.count, 2)
        XCTAssertEqual(result.roots.filter { $0.tool == .codex }.count, 3)
        XCTAssertEqual(result.roots.first { $0.location == .shared }?.tool, .codex)
        XCTAssertTrue(result.roots.filter { $0.location == .plugins }.allSatisfy { $0.url.lastPathComponent == "cache" })
        let repeated = try await discovery.discover()
        XCTAssertEqual(result.roots, repeated.roots)
    }

    func testMissingDefaultsDoNotCreateFoldersAndRefreshFindsNewInstall() async throws {
        let empty = try await discovery.discover()
        XCTAssertTrue(empty.roots.isEmpty); XCTAssertTrue(empty.warnings.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
        let added = try directory(".claude/skills")
        let next = try await discovery.discover()
        XCTAssertEqual(next.roots.map { $0.url.path }, [added.path])
        try FileManager.default.removeItem(at: added)
        let removed = try await discovery.discover()
        XCTAssertTrue(removed.roots.isEmpty)
    }

    func testConfiguredLocationsStaySeparatedAndRepeatedDefaultsDeduplicate() async throws {
        let personal = try directory(".claude/skills")
        let custom = try directory("自定义 Codex/skills")
        let result = try await SkillDiscovery(home: home, environment: [
            "CLAUDE_CONFIG_DIR": personal.deletingLastPathComponent().path,
            "CODEX_HOME": custom.deletingLastPathComponent().path
        ]).discover()
        XCTAssertTrue(result.warnings.isEmpty); XCTAssertEqual(result.roots.count, 2)
        XCTAssertEqual(result.roots.first { $0.url.path == custom.path }?.tool, .codex)
        let relative = try await SkillDiscovery(home: home, environment: ["CODEX_HOME": "自定义 Codex"]).discover()
        XCTAssertEqual(relative.roots.count, 1)
        let wrongAI = try await SkillDiscovery(home: home, environment: ["CODEX_HOME": personal.deletingLastPathComponent().path]).discover()
        XCTAssertFalse(wrongAI.warnings.isEmpty)
        XCTAssertTrue(wrongAI.roots.allSatisfy { $0.tool == .claude })
    }

    func testLinkedDefaultOrAncestorIsReportedWithoutFollowingItsContents() async throws {
        let target = try directory("outside/skills")
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude"), withDestinationURL: target.deletingLastPathComponent())
        try directory(".codex")
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".codex/skills"), withDestinationURL: target)
        let result = try await discovery.discover()
        XCTAssertTrue(result.roots.isEmpty); XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testUnreadableDiscoveryIsNotAnEmptySuccessAndProtectsPossibleSharedOriginals() async throws {
        let readable = try directory(".claude/skills/original")
        try Data("---\nname: original\n---\n".utf8).write(to: readable.appendingPathComponent("SKILL.md"))
        let blocked = try directory(".codex")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let found = try await discovery.discover()
        XCTAssertFalse(found.warnings.isEmpty)
        let scanned = try await SkillCatalog().scan(found.roots, priorWarnings: found.warnings)
        XCTAssertFalse(scanned.complete); XCTAssertEqual(scanned.entries.count, 1)
        XCTAssertEqual(scanned.entries.first?.removal, .readOnly)
        XCTAssertTrue(scanned.entries.first?.impact.contains("检查未完整完成") == true)
    }

    func testDiscoveryCancellationPropagates() async throws {
        let worker = Task { try Task.checkCancellation(); return try await discovery.discover() }
        worker.cancel()
        do { _ = try await worker.value; XCTFail("Cancelled discovery returned results") }
        catch is CancellationError { }
    }
}
