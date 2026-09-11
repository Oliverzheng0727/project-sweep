import XCTest
@testable import CleanupCore

final class CleanupExecutorTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    private var storeURL: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Sweep-Execute-\(UUID())").standardizedFileURL
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("Sweep-Store-\(UUID())").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: storeURL)
    }
    private func item(_ name: String = "example.txt") async throws -> CleanupItem {
        let url = root.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        let result = try await ProjectScanner().scan(ScanRequest(root: root))
        return try XCTUnwrap(result.items.first { $0.title == name })
    }
    func testRealSystemTrashAndRestoreKeepsBytesAndRecords() async throws {
        let entry = try await item()
        let store = RecordStore(directory: storeURL)
        let executor = CleanupExecutor(store: store)
        let results = await executor.execute(CleanupPlan(items: [entry]), configurations: [])
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.status, .succeeded, result.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.path))
        let restored = try await executor.restore(result)
        XCTAssertEqual(restored.status, .restored)
        XCTAssertEqual(try Data(contentsOf: entry.url), Data("fixture".utf8))
        let saved = try await store.load()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].status, .restored)
    }
    func testRestorationNeverOverwritesNewFile() async throws {
        let entry = try await item()
        let executor = CleanupExecutor(store: RecordStore(directory: storeURL))
        let outcomes = await executor.execute(CleanupPlan(items: [entry]), configurations: [])
        let record = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(record.status, .succeeded, record.message)
        try Data("new user file".utf8).write(to: entry.url)
        do { _ = try await executor.restore(record); XCTFail("Must refuse overwrite") } catch { }
        XCTAssertEqual(try Data(contentsOf: entry.url), Data("new user file".utf8))
        try FileManager.default.removeItem(at: entry.url)
        _ = try await executor.restore(record)
    }
    func testChangedFileIsUntouched() async throws {
        let entry = try await item()
        try Data("new contents".utf8).write(to: entry.url)
        let results = await CleanupExecutor(store: RecordStore(directory: storeURL)).execute(CleanupPlan(items: [entry]), configurations: [])
        XCTAssertEqual(results.first?.status, .failed)
        XCTAssertEqual(try Data(contentsOf: entry.url), Data("new contents".utf8))
    }
    func testOpenFileIsUntouched() async throws {
        let entry = try await item()
        let handle = try FileHandle(forReadingFrom: entry.url)
        defer { try? handle.close() }
        let results = await CleanupExecutor(store: RecordStore(directory: storeURL)).execute(CleanupPlan(items: [entry]), configurations: [])
        XCTAssertEqual(results.first?.status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path))
    }
    func testTraversalAndChangedSymbolicLinkAreRejected() async throws {
        let entry = try await item()
        let outside = root.deletingLastPathComponent().appendingPathComponent("Sweep-outside-\(UUID()).txt")
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertThrowsError(try PathSafety.validate(outside, within: root))
        try FileManager.default.removeItem(at: entry.url)
        try FileManager.default.createSymbolicLink(at: entry.url, withDestinationURL: outside)
        let results = await CleanupExecutor(store: RecordStore(directory: storeURL)).execute(CleanupPlan(items: [entry]), configurations: [])
        XCTAssertEqual(results.first?.status, .failed)
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }
    func testSourceNewlyAddedToGitIsProtectedAtExecution() async throws {
        let entry = try await item("new.swift")
        for args in [["init", "-q", root.path], ["-C", root.path, "add", "new.swift"]] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args
            try p.run(); p.waitUntilExit()
        }
        let results = await CleanupExecutor(store: RecordStore(directory: storeURL)).execute(CleanupPlan(items: [entry]), configurations: [])
        XCTAssertEqual(results.first?.status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path))
    }
    func testOverlappingOrMissingSessionDependenciesCannotBeHidden() throws {
        let first = CleanupItem(id: "a", path: root.path + "/a.jsonl", rootPath: root.path, reason: "session", relatedIDs: ["b"], action: .deleteSession)
        XCTAssertThrowsError(try SelectionPlanner.makePlan(items: [first], selectedIDs: ["a"]))
        let second = CleanupItem(id: "b", path: root.path + "/b.jsonl", rootPath: root.path, reason: "session", action: .deleteSession)
        XCTAssertEqual(try SelectionPlanner.makePlan(items: [first, second], selectedIDs: ["a"]).items.count, 2)
    }
    func testNewlyTrackedFileInExistingNestedRepositoryIsUntouched() async throws {
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for repo in [root!, nested] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["init", "-q", repo.path]; try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
        let source = nested.appendingPathComponent("new.swift")
        try Data("fixture".utf8).write(to: source)
        let scan = try await ProjectScanner().scan(ScanRequest(root: root))
        let entry = try XCTUnwrap(scan.items.first { $0.path == source.path })
        XCTAssertTrue(entry.isSelectable)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", nested.path, "add", "new.swift"]; try p.run(); p.waitUntilExit()
        let executor = CleanupExecutor(store: RecordStore(directory: storeURL))
        let results = await executor.execute(CleanupPlan(items: [entry]), configurations: [])
        // Restore the disposable fixture even while demonstrating the regression.
        if let moved = results.first, moved.status == .succeeded { _ = try await executor.restore(moved) }
        XCTAssertEqual(results.first?.status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path))
    }

    func testChangedPackageInteriorIsUntouchedAtExecution() async throws {
        let package = root.appendingPathComponent("Document.app")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let content = package.appendingPathComponent("data.txt")
        try Data("fixture".utf8).write(to: content)
        let scan = try await ProjectScanner().scan(ScanRequest(root: root))
        let entry = try XCTUnwrap(scan.items.first { $0.path == package.path })
        let handle = try FileHandle(forWritingTo: content)
        try handle.write(contentsOf: Data("new document content".utf8)); try handle.close()
        let results = await CleanupExecutor(store: RecordStore(directory: storeURL)).execute(CleanupPlan(items: [entry]), configurations: [])
        XCTAssertEqual(results.first?.status, .failed)
        XCTAssertEqual(try Data(contentsOf: content), Data("new document content".utf8))
    }

    func testMixedToolSelectionDeletesSessionsBeforeTrashingCache() async throws {
        let id = UUID().uuidString
        let transcript = root.appendingPathComponent("projects/p/" + id + ".jsonl")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("{\"type\":\"user\",\"sessionId\":\"\(id)\",\"cwd\":\"/fixture/project\",\"message\":\"disposable\"}\n".utf8).write(to: transcript)
        try Data("cache fixture".utf8).write(to: cache.appendingPathComponent("data"))
        let configuration = ToolConfiguration(tool: .claude, root: root)
        let scan = try await ToolDataService().scan(configuration)
        let selectedCache = try XCTUnwrap(scan.items.first { $0.category == .toolCache })
        let selectedSession = try XCTUnwrap(scan.items.first { $0.sessionID == id })
        XCTAssertTrue(selectedSession.isSelectable)
        let executor = CleanupExecutor(store: RecordStore(directory: storeURL), deleteSessions: { selected, config, batch in
            do {
                for entry in selected { try ToolFiles.verifyStamp(config.root, entry.metadata["rootSnapshot"]) }
                try ClaudeAdapter.delete(selected, configuration: config, ensureClosed: {})
                return selected.map { CleanupRecord(batchID: batch, originalPath: $0.path, action: .deleteSession, tool: .claude, status: .succeeded, message: "fixture deleted") }
            } catch {
                return selected.map { CleanupRecord(batchID: batch, originalPath: $0.path, action: .deleteSession, tool: .claude, status: .failed, message: error.localizedDescription) }
            }
        }, ensureToolClosed: { _ in })
        let outcomes = await executor.execute(CleanupPlan(items: [selectedCache, selectedSession]), configurations: [configuration])
        for outcome in outcomes where outcome.action == .trash && outcome.status == .succeeded {
            _ = try await executor.restore(outcome)
        }
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy { $0.status == .succeeded }, outcomes.map(\.message).joined(separator: "; "))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path))
    }

    func testReorderedSessionOutcomesRetainTheirOwnIntentIDs() async throws {
        let store = RecordStore(directory: storeURL)
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let parent = CleanupItem(id: "parent", path: canonicalRoot.path + "/parent.jsonl", rootPath: canonicalRoot.path,
                                 reason: "fixture", tool: .codex, action: .deleteSession)
        let child = CleanupItem(id: "child", path: canonicalRoot.path + "/child.jsonl", rootPath: canonicalRoot.path,
                                reason: "fixture", tool: .codex, action: .deleteSession)
        let executor = CleanupExecutor(store: store, deleteSessions: { selected, _, batch in
            let intents = (try? await store.load()) ?? []
            // Store a fixture marker with the original intent ID so the mapping is observable.
            return selected.reversed().map { entry in
                CleanupRecord(batchID: batch, originalPath: entry.path, action: .deleteSession, tool: .codex,
                              status: .succeeded, message: intents.first { $0.originalPath == entry.path }!.id.uuidString)
            }
        }, ensureToolClosed: { _ in })
        let records = await executor.execute(CleanupPlan(items: [parent, child]), configurations: [ToolConfiguration(tool: .codex, root: canonicalRoot)])
        XCTAssertEqual(records.count, 2)
        for record in records { XCTAssertEqual(record.id.uuidString, record.message) }
        let saved = try await store.load()
        XCTAssertEqual(saved.count, 2)
        for record in saved { XCTAssertEqual(record.id.uuidString, record.message) }
    }

    func testRestoreReturnsPhysicalSuccessWhenRecordStoreCannotBeWritten() async throws {
        let entry = try await item()
        let executor = CleanupExecutor(store: RecordStore(directory: storeURL))
        let outcomes = await executor.execute(CleanupPlan(items: [entry]), configurations: [])
        let moved = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(moved.status, .succeeded, moved.message)
        // Replace the disposable log directory with a file: all attempted writes fail,
        // independently of account privileges or filesystem permission overrides.
        try FileManager.default.removeItem(at: storeURL)
        try Data("unwritable record store fixture".utf8).write(to: storeURL)
        let restored = try await executor.restore(moved)
        XCTAssertEqual(restored.status, .restored)
        XCTAssertTrue(restored.message.contains("记录保存失败"))
        XCTAssertEqual(try Data(contentsOf: entry.url), Data("fixture".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(moved.trashPath)))
    }

}
