import XCTest
import Darwin
@testable import CleanupCore

final class SkillManagementTests: XCTestCase, @unchecked Sendable {
    private var sandbox: URL!
    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("Sweep-Skills-\(UUID())").standardizedFileURL
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: sandbox) }
    private func source(_ tool: ToolKind, _ location: SkillLocation = .personal, suffix: String? = nil) throws -> SkillRoot {
        let path = suffix ?? (location == .shared ? ".agents/skills" : ".\(tool.rawValue)/" + (location == .plugins ? "plugins" : "skills"))
        let url = sandbox.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SkillRoot(tool: tool, url: url, location: location)
    }
    @discardableResult private func skill(_ root: SkillRoot, _ name: String, title: String? = nil) throws -> URL {
        let url = root.url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("---\nname: \(title ?? name)\ndescription: 仅用于测试\n---\nUntrusted skill body.\n".utf8).write(to: url.appendingPathComponent("SKILL.md"))
        try Data("fixture script".utf8).write(to: url.appendingPathComponent("script.py"))
        return url
    }
    private func plan(_ roots: [SkillRoot], names: Set<String>) async throws -> SkillRemovalPlan {
        let scan = try await SkillCatalog().scan(roots)
        XCTAssertTrue(scan.complete, scan.warnings.joined(separator: "\n"))
        return try SkillRemovalPlan.make(entries: scan.entries, selected: Set(scan.entries.filter { names.contains($0.url.lastPathComponent) }.map(\.id)), roots: roots)
    }
    private var store: RecordStore { RecordStore(directory: sandbox.appendingPathComponent("records")) }

    func testSeparateAIToolsAndSourceKinds() async throws {
        let claude = try source(.claude), codex = try source(.codex), shared = try source(.codex, .shared), plugins = try source(.claude, .plugins)
        try skill(claude, "same-name"); try skill(codex, "same-name"); try skill(shared, "shared")
        try skill(codex, ".system/builtin"); try skill(claude, "synced/cloud")
        try skill(plugins, "cache/vendor/plugin/1.0/skills/plugin-skill")
        let scan = try await SkillCatalog().scan([claude, codex, shared, plugins])
        XCTAssertTrue(scan.complete, scan.warnings.joined(separator: "\n")); XCTAssertEqual(scan.entries.count, 6)
        let same = scan.entries.filter { $0.name == "same-name" }
        XCTAssertEqual(Set(same.map { $0.root.tool }), [.claude, .codex]); XCTAssertEqual(Set(same.map(\.id)).count, 2)
        XCTAssertTrue(same.allSatisfy(\.selectable))
        for entry in scan.entries where entry.name != "same-name" { XCTAssertFalse(entry.selectable, entry.url.path) }
    }
    func testReferenceTrashAndRestorePreservesSharedOriginalAndOtherAI() async throws {
        let claude = try source(.claude), codex = try source(.codex), shared = try source(.codex, .shared)
        let target = try skill(shared, "共享技能")
        let original = try Data(contentsOf: target.appendingPathComponent("SKILL.md"))
        let a = claude.url.appendingPathComponent("共享技能"), b = codex.url.appendingPathComponent("共享技能")
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: b, withDestinationURL: target)
        let scan = try await SkillCatalog().scan([claude, codex, shared])
        let entry = try XCTUnwrap(scan.entries.first { $0.root.id == claude.id })
        XCTAssertEqual(entry.removal, .reference)
        let plan = try SkillRemovalPlan.make(entries: scan.entries, selected: [entry.id], roots: [claude, codex, shared])
        let outcomes = await SkillCleanupExecutor(store: store).execute(plan, authorizedRoots: plan.roots)
        let record = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(record.status, .succeeded, record.message)
        XCTAssertFalse(ToolFiles.exists(a)); XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("SKILL.md")), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: b.path), target.path)
        XCTAssertNotNil(record.skillLinkTarget)
        let restored = try await CleanupExecutor(store: store).restore(record)
        XCTAssertEqual(restored.status, .restored)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: a.path), target.path)
        let records = try await store.load(); XCTAssertEqual(records.count, 1); XCTAssertEqual(records[0].status, .restored)
        let recordData = try Data(contentsOf: sandbox.appendingPathComponent("records/operations.json"))
        XCTAssertFalse(String(decoding: recordData, as: UTF8.self).contains("Untrusted skill body"))
    }
    func testBrokenRelativeLinkNeverReadsTargetAndRestoresWithoutOverwrite() async throws {
        let root = try source(.claude)
        let link = root.url.appendingPathComponent("missing")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../missing/技能")
        let plan = try await plan([root], names: ["missing"])
        let outcomes = await SkillCleanupExecutor(store: store).execute(plan, authorizedRoots: [root])
        let record = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(record.status, .succeeded, record.message)
        try Data("do not overwrite".utf8).write(to: link)
        do { _ = try await CleanupExecutor(store: store).restore(record); XCTFail("Must not overwrite") } catch { }
        XCTAssertEqual(try Data(contentsOf: link), Data("do not overwrite".utf8))
        try FileManager.default.removeItem(at: link)
        _ = try await CleanupExecutor(store: store).restore(record)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "../../missing/技能")
    }
    func testPhysicalSkillTrashAndRestoreIsScopedAndChecksModification() async throws {
        let root = try source(.codex)
        let selected = try skill(root, "one"), untouched = try skill(root, "two")
        let before = try Data(contentsOf: selected.appendingPathComponent("SKILL.md"))
        let plan = try await plan([root], names: ["one"])
        let records = await SkillCleanupExecutor(store: store).execute(plan, authorizedRoots: [root])
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.status, .succeeded, record.message); XCTAssertTrue(ToolFiles.exists(untouched)); XCTAssertFalse(ToolFiles.exists(selected))
        _ = try await CleanupExecutor(store: store).restore(record)
        XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent("SKILL.md")), before)
        let changed = try await self.plan([root], names: ["one"])
        try Data("changed".utf8).write(to: selected.appendingPathComponent("script.py"))
        let result = await SkillCleanupExecutor(store: store).execute(changed, authorizedRoots: [root])
        XCTAssertEqual(result.first?.status, .failed); XCTAssertTrue(ToolFiles.exists(selected))
    }
    func testSharedOriginalCannotBeRemovedAndNewReferenceBlocksOldPlan() async throws {
        let a = try source(.codex), b = try source(.claude)
        let target = try skill(a, "original")
        let plan = try await plan([a, b], names: ["original"])
        try FileManager.default.createSymbolicLink(at: b.url.appendingPathComponent("alias"), withDestinationURL: target)
        let scan = try await SkillCatalog().scan([a, b])
        XCTAssertEqual(scan.entries.first { $0.url.path == target.path }?.removal, .readOnly)
        let outcomes = await SkillCleanupExecutor(store: store).execute(plan, authorizedRoots: [a, b])
        XCTAssertEqual(outcomes.first?.status, .failed); XCTAssertTrue(ToolFiles.exists(target))
    }
    func testChangedLinkAndRevokedAuthorizationFailWithoutMovingAnything() async throws {
        let root = try source(.claude)
        let link = root.url.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/missing/one")
        let plan = try await plan([root], names: ["alias"])
        let revoked = await SkillCleanupExecutor(store: store).execute(plan, authorizedRoots: [])
        XCTAssertEqual(revoked.first?.status, .failed)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/missing/two")
        let changed = await SkillCleanupExecutor(store: store).execute(plan, authorizedRoots: [root])
        XCTAssertEqual(changed.first?.status, .failed)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "/missing/two")
    }
    func testWrongAIAndMislabelledSharedPathsRejected() throws {
        let claude = try source(.claude)
        XCTAssertThrowsError(try SkillCatalog.validateRoot(SkillRoot(tool: .codex, url: claude.url, location: .personal)))
        let shared = try source(.codex, .shared)
        XCTAssertThrowsError(try SkillCatalog.validateRoot(SkillRoot(tool: .codex, url: shared.url, location: .personal)))
        XCTAssertThrowsError(try SkillCatalog.validateRoot(SkillRoot(tool: .claude, url: sandbox, location: .personal)))
    }
    func testBatchAndRepeatRemovalRemainScoped() async throws {
        let root = try source(.codex)
        let first = try skill(root, "first"), second = try skill(root, "second"), other = try skill(root, "other")
        let plan = try await plan([root], names: ["first", "second"])
        let executor = SkillCleanupExecutor(store: store)
        let outcomes = await executor.execute(plan, authorizedRoots: [root])
        XCTAssertEqual(outcomes.count, 2); XCTAssertTrue(outcomes.allSatisfy { $0.status == .succeeded }, outcomes.map(\.message).joined(separator: ";"))
        XCTAssertFalse(ToolFiles.exists(first)); XCTAssertFalse(ToolFiles.exists(second)); XCTAssertTrue(ToolFiles.exists(other))
        let repeated = await executor.execute(plan, authorizedRoots: [root])
        XCTAssertTrue(repeated.allSatisfy { $0.status == .failed })
        for outcome in outcomes where outcome.status == .succeeded { _ = try await CleanupExecutor(store: store).restore(outcome) }
        XCTAssertTrue(ToolFiles.exists(first)); XCTAssertTrue(ToolFiles.exists(second))
    }
    func testReplacedSourceAndSkillHeaderLinkAreRejected() async throws {
        let root = try source(.codex)
        try skill(root, "fixture")
        let plan = try await plan([root], names: ["fixture"])
        let moved = root.url.deletingLastPathComponent().appendingPathComponent("old-skills")
        try FileManager.default.moveItem(at: root.url, to: moved)
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        let replacement = try skill(root, "fixture")
        let result = await SkillCleanupExecutor(store: store).execute(plan, authorizedRoots: [root])
        XCTAssertEqual(result.first?.status, .failed); XCTAssertTrue(ToolFiles.exists(replacement))
        let header = replacement.appendingPathComponent("SKILL.md")
        try FileManager.default.removeItem(at: header)
        try FileManager.default.createSymbolicLink(at: header, withDestinationURL: moved.appendingPathComponent("fixture/SKILL.md"))
        let scan = try await SkillCatalog().scan([root])
        XCTAssertFalse(scan.complete); XCTAssertFalse(scan.entries.contains { $0.selectable })
    }
    func testOpenSkillFileAndUnwritableLogBlockRemoval() async throws {
        let root = try source(.codex)
        let url = try skill(root, "fixture")
        let plan = try await plan([root], names: ["fixture"])
        let handle = try FileHandle(forReadingFrom: url.appendingPathComponent("script.py"))
        let busy = await SkillCleanupExecutor(store: store).execute(plan, authorizedRoots: [root])
        try handle.close()
        if let moved = busy.first, moved.status == .succeeded { _ = try await CleanupExecutor(store: store).restore(moved) }
        XCTAssertEqual(busy.first?.status, .failed); XCTAssertTrue(ToolFiles.exists(url))
        let blocked = sandbox.appendingPathComponent("blocked-records")
        try Data("not a directory".utf8).write(to: blocked)
        let failed = await SkillCleanupExecutor(store: RecordStore(directory: blocked)).execute(plan, authorizedRoots: [root])
        XCTAssertEqual(failed.first?.status, .failed); XCTAssertTrue(ToolFiles.exists(url))
    }
    func testNestedLinksPluginMarkersAndManagedRootsRemainReadOnly() async throws {
        let root = try source(.claude)
        let nested = try skill(root, "nested")
        try FileManager.default.createSymbolicLink(atPath: nested.appendingPathComponent("outside").path, withDestinationPath: "/missing")
        let plugin = try skill(root, "plugin")
        try FileManager.default.createDirectory(at: plugin.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
        let misleading = try source(.codex, suffix: ".codex/plugins/cache/vendor/skills")
        try FileManager.default.createSymbolicLink(atPath: misleading.url.appendingPathComponent("alias").path, withDestinationPath: "/missing")
        let scan = try await SkillCatalog().scan([root, misleading])
        XCTAssertEqual(scan.entries.count, 3); XCTAssertTrue(scan.entries.allSatisfy { !$0.selectable })
        XCTAssertThrowsError(try SkillRemovalPlan.make(entries: scan.entries, selected: Set(scan.entries.map(\.id)), roots: [root, misleading]))
    }
    func testUnreadableSkillAndCancellationAreExplicit() async throws {
        let root = try source(.codex)
        let readable = try skill(root, "readable"), blocked = try skill(root, "blocked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let scan = try await SkillCatalog().scan([root])
        XCTAssertFalse(scan.complete); XCTAssertEqual(scan.entries.first { $0.url.path == readable.path }?.removal, .readOnly)
        let task = Task { try Task.checkCancellation(); return try await SkillCatalog().scan([root]) }; task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch is CancellationError { } catch { XCTFail("\(error)") }
    }
    func testOldRecordsDecodeAndProjectSkillProtectionUnchanged() async throws {
        let root = try source(.codex, .shared)
        let protected = try skill(root, "fixture")
        let scan = try await ProjectScanner().scan(ScanRequest(root: sandbox))
        XCTAssertFalse(try XCTUnwrap(scan.items.first { $0.path == protected.path }).isSelectable)
        let record = CleanupRecord(originalPath: protected.path, action: .trash, status: .failed, message: "legacy")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "skillLinkTarget")
        let legacy = try JSONDecoder().decode(CleanupRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.skillLinkTarget)
    }
}
