import XCTest
@testable import CleanupCore

final class SkillRelationshipTests: XCTestCase, @unchecked Sendable {
    private var sandbox: URL!
    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("Sweep-relationships-\(UUID())").standardizedFileURL
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: sandbox) }

    private func root(_ tool: ToolKind, _ location: SkillLocation = .personal) throws -> SkillRoot {
        let path = location == .shared ? ".agents/skills" : ".\(tool.rawValue)/skills"
        let url = sandbox.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SkillRoot(tool: tool, url: url, location: location)
    }
    @discardableResult private func skill(_ root: SkillRoot, _ path: String, name: String = "同名技能") throws -> URL {
        let url = root.url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("---\nname: \(name)\n---\n".utf8).write(to: url.appendingPathComponent("SKILL.md"))
        return url
    }
    private func link(_ root: SkillRoot, _ name: String, target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: root.url.appendingPathComponent(name).path, withDestinationPath: target)
    }

    func testExplicitReferencesGroupWithObservedOriginalWithoutChangingRemovalRights() async throws {
        let claude = try root(.claude), codex = try root(.codex), shared = try root(.codex, .shared)
        let original = try skill(shared, "中文技能", name: "共享原件")
        try link(claude, "alias-one", target: "../../.agents/skills/中文技能")
        try link(codex, "alias-two", target: original.path)
        let scan = try await SkillCatalog().scan([claude, codex, shared])
        let inventory = SkillRelationshipInventory(scan: scan)
        let relation = try XCTUnwrap(inventory.relationships.first)
        XCTAssertEqual(inventory.relationships.count, 1)
        XCTAssertEqual(relation.originalPath, original.path)
        XCTAssertEqual(relation.name, "共享原件")
        XCTAssertTrue(relation.originalObserved)
        XCTAssertEqual(relation.directEntries.count, 1)
        XCTAssertEqual(relation.references.count, 2)
        XCTAssertEqual(Set(relation.entries.map { $0.root.tool }), [.claude, .codex])
        XCTAssertEqual(relation.directEntries.first?.removal, .readOnly)
        XCTAssertTrue(relation.references.allSatisfy { $0.removal == .reference })
        XCTAssertTrue(inventory.complete)
    }

    func testSameNameAtDifferentPathsRemainsSeparate() async throws {
        let claude = try root(.claude), codex = try root(.codex)
        let first = try skill(claude, "skill"), second = try skill(codex, "skill")
        let inventory = SkillRelationshipInventory(scan: try await SkillCatalog().scan([claude, codex]))
        XCTAssertEqual(inventory.relationships.count, 2)
        XCTAssertEqual(Set(inventory.relationships.map(\.originalPath)), [first.path, second.path])
        XCTAssertTrue(inventory.relationships.allSatisfy { $0.entries.count == 1 })
    }

    func testUnobservedTargetStaysUnknownEvenWhenItExistsOutsideScannedRoots() async throws {
        let claude = try root(.claude), shared = try root(.codex, .shared)
        let unscannedOriginal = try skill(shared, "outside", name: "must-not-be-read")
        try link(claude, "alias", target: unscannedOriginal.path)
        try link(claude, "missing", target: "../../absent/skill")
        let inventory = SkillRelationshipInventory(scan: try await SkillCatalog().scan([claude]))
        XCTAssertEqual(inventory.relationships.count, 2)
        XCTAssertTrue(inventory.relationships.allSatisfy { !$0.originalObserved && $0.directEntries.isEmpty })
        XCTAssertFalse(inventory.relationships.contains { $0.name == "must-not-be-read" })
        XCTAssertTrue(inventory.complete, "Completeness concerns scanned sources, not unverified link targets")
    }

    func testReferenceToNestedPathIsNotMistakenForExactOriginal() async throws {
        let claude = try root(.claude), codex = try root(.codex)
        let original = try skill(codex, "whole")
        try link(claude, "nested", target: original.appendingPathComponent("subfolder").path)
        let inventory = SkillRelationshipInventory(scan: try await SkillCatalog().scan([claude, codex]))
        XCTAssertEqual(inventory.relationships.count, 2)
        let reference = try XCTUnwrap(inventory.relationships.first { !$0.references.isEmpty })
        XCTAssertFalse(reference.originalObserved)
        XCTAssertEqual(reference.originalPath, original.path + "/subfolder")
    }

    func testIncompleteScanNeverClaimsCompleteRelationshipsAndKeepsObservedEntries() async throws {
        let claude = try root(.claude)
        try skill(claude, "one")
        let scan = try await SkillCatalog().scan([claude], priorWarnings: ["An authorized source could not be inspected"])
        let inventory = SkillRelationshipInventory(scan: scan)
        XCTAssertFalse(inventory.complete)
        XCTAssertEqual(inventory.relationships.count, 1)
        XCTAssertTrue(inventory.relationships[0].originalObserved)
        XCTAssertFalse(inventory.relationships[0].entries[0].selectable)
    }
}
