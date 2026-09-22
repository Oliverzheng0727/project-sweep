import XCTest
import Foundation
import CSQLite
import Darwin
@testable import CleanupCore

final class ToolDataServiceTests: XCTestCase, @unchecked Sendable {
    func fixture() throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/sweep-tool-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func write(_ root: URL, _ path: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    func claude(_ root: URL, project: String, id: String) throws -> URL {
        try write(root, "projects/\(project)/\(id).jsonl", "{\"type\":\"user\",\"sessionId\":\"\(id)\",\"cwd\":\"/work/\(project)\",\"message\":\"secret body\"}\n")
    }
    func testClaudeProjectOwnershipAndAssociatedFilesAreNarrow() async throws {
        let root = try fixture(); let a = UUID().uuidString; let b = UUID().uuidString
        let first = try claude(root, project: "encoded-a", id: a)
        let second = try claude(root, project: "encoded-b", id: b)
        let child = try write(root, "projects/encoded-a/\(a)/subagents/agent-child.jsonl", "child")
        let snapshot = try write(root, "file-history/\(a)/revision", "snapshot")
        let memory = try write(root, "projects/encoded-a/memory/MEMORY.md", "remember")
        let config = try write(root, "settings.json", "{}")
        _ = try write(root, "history.jsonl", "{\"sessionId\":\"\(a)\",\"display\":\"secret a\"}\n{\"sessionId\":\"\(b)\",\"display\":\"secret b\"}\n")
        let configuration = ToolConfiguration(tool: .claude, root: root)
        let result = try await ToolDataService().scan(configuration)
        let selected = try XCTUnwrap(result.items.first { $0.sessionID == a })
        XCTAssertEqual(selected.projectPath, "/work/encoded-a")
        XCTAssertTrue(selected.isSelectable)
        XCTAssertTrue(selected.details.contains("关联：" + snapshot.deletingLastPathComponent().path))
        XCTAssertFalse(String(describing: selected.metadata).contains("secret"))
        try ClaudeAdapter.delete([selected], configuration: configuration, ensureClosed: {})
        XCTAssertFalse(ToolFiles.exists(first)); XCTAssertFalse(ToolFiles.exists(child)); XCTAssertFalse(ToolFiles.exists(snapshot))
        XCTAssertTrue(ToolFiles.exists(second)); XCTAssertTrue(ToolFiles.exists(memory)); XCTAssertTrue(ToolFiles.exists(config))
        XCTAssertEqual(try ToolFiles.jsonLines(root.appendingPathComponent("history.jsonl")).map { $0.1["sessionId"] as? String }, [b])
        XCTAssertFalse(ToolFiles.exists(root.appendingPathComponent(ClaudeAdapter.journalName)))
    }
    func testChangedHistoryAbortsWithoutTouchingSession() async throws {
        let root = try fixture(); let id = UUID().uuidString
        let transcript = try claude(root, project: "p", id: id)
        _ = try write(root, "history.jsonl", "{\"sessionId\":\"\(id)\"}\n")
        let config = ToolConfiguration(tool: .claude, root: root)
        let scan = try await ToolDataService().scan(config)
        let item = try XCTUnwrap(scan.items.first { $0.sessionID == id })
        _ = try write(root, "history.jsonl", "{\"sessionId\":\"\(id)\",\"display\":\"changed\"}\n")
        XCTAssertThrowsError(try ClaudeAdapter.delete([item], configuration: config, ensureClosed: {}))
        XCTAssertTrue(ToolFiles.exists(transcript))
    }
    func testMalformedHistoryAndUnknownRecordsStayReadOnly() async throws {
        let root = try fixture(); let id = UUID().uuidString
        _ = try claude(root, project: "p", id: id)
        _ = try write(root, "history.jsonl", "not json\n")
        let scan = try await ToolDataService().scan(ToolConfiguration(tool: .claude, root: root))
        XCTAssertEqual(scan.items.first { $0.sessionID == id }?.risk, .unavailable)
        _ = try write(root, "projects/p/\(id).jsonl", "{\"type\":\"future-format\",\"sessionId\":\"\(id)\",\"cwd\":\"/work/p\"}\n")
        let next = try await ToolDataService().scan(ToolConfiguration(tool: .claude, root: root))
        XCTAssertTrue(next.items.allSatisfy { !$0.isSelectable })
    }
    func testClaudeIndexPreservesOtherEntries() async throws {
        let root = try fixture(); let a = UUID().uuidString; let b = UUID().uuidString
        _ = try claude(root, project: "p", id: a); _ = try claude(root, project: "p", id: b)
        let index = try write(root, "projects/p/sessions-index.json", "{\"version\":1,\"entries\":[{\"sessionId\":\"\(a)\"},{\"sessionId\":\"\(b)\",\"summary\":\"preserve\"}]}")
        let config = ToolConfiguration(tool: .claude, root: root)
        let scan = try await ToolDataService().scan(config)
        try ClaudeAdapter.delete([try XCTUnwrap(scan.items.first { $0.sessionID == a })], configuration: config, ensureClosed: {})
        let object = try ClaudeAdapter.validatedIndex(index, root: root)
        XCTAssertEqual((object["entries"] as? [[String: String]])?.first?["sessionId"], b)
    }
    func testRecoveryRestoresInterruptedMove() throws {
        let root = try fixture(); let file = try write(root, "projects/p/session.jsonl", "original")
        let snapshot = try Snapshotter.capture(file)
        let journal = root.appendingPathComponent(ClaudeAdapter.journalName)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: file, to: journal.appendingPathComponent("0"))
        let entry = ClaudeTransaction.Entry(path: file.path, slot: "0", replacement: false, snapshot: snapshot)
        try JSONEncoder().encode(ClaudeTransaction.Manifest(entries: [entry], committed: false)).write(to: journal.appendingPathComponent("manifest.json"))
        try ClaudeTransaction.recover(root: root)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
        XCTAssertFalse(ToolFiles.exists(journal))
    }
    func testMidTransactionFailureRollsBackAllMovedFiles() throws {
        let root = try fixture()
        let first = try write(root, "projects/p/a.jsonl", "first")
        let second = try write(root, "projects/p/b.jsonl", "second")
        var probes = 0
        XCTAssertThrowsError(try ClaudeTransaction.apply(root: root, removals: [first, second], replacements: [:], ensureClosed: {
            probes += 1
            if probes == 2 { throw CleanupError.changed("fixture interruption") }
        }))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
        XCTAssertFalse(ToolFiles.exists(root.appendingPathComponent(ClaudeAdapter.journalName)))
    }
    func testRecoveryRefusesChangedReplacement() throws {
        let root = try fixture(); let file = try write(root, "history.jsonl", "original")
        let snapshot = try Snapshotter.capture(file)
        let journal = root.appendingPathComponent(ClaudeAdapter.journalName)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: file, to: journal.appendingPathComponent("0"))
        _ = try write(root, "history.jsonl", "new user data")
        let entry = ClaudeTransaction.Entry(path: file.path, slot: "0", replacement: true, replacementDigest: ClaudeTransaction.digest(Data("replacement".utf8)), snapshot: snapshot)
        try JSONEncoder().encode(ClaudeTransaction.Manifest(entries: [entry], committed: false)).write(to: journal.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try ClaudeTransaction.recover(root: root))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new user data")
        XCTAssertTrue(ToolFiles.exists(journal.appendingPathComponent("0")))
    }
    func testCursorFixturesNeverEnableMutation() async throws {
        let root = try fixture()
        let database = try write(root, "User/workspaceStorage/a/state.vscdb", "fixture")
        _ = try write(root, "User/workspaceStorage/a/workspace.json", "{\"folder\":\"file:///work/project-a\"}")
        _ = try write(root, "Cache/data", "cache")
        let config = ToolConfiguration(tool: .cursor, root: root)
        let scan = try await ToolDataService().scan(config)
        XCTAssertEqual(scan.items.count, 2); XCTAssertTrue(scan.items.filter { $0.category == .session }.allSatisfy { !$0.isSelectable })
        XCTAssertTrue(scan.items.first { $0.category == .toolCache }?.isSelectable == true)
        XCTAssertEqual(scan.items.first { $0.category == .session }?.projectPath, "/work/project-a")
        let records = await ToolDataService().deleteSessions(scan.items.filter { $0.category == .session }, configuration: config, batchID: UUID())
        XCTAssertEqual(records.first?.status, .failed); XCTAssertTrue(ToolFiles.exists(database))
    }
    func testCodexReadonlySQLiteAndDependencyExpansion() async throws {
        let root = try fixture(); let a = UUID().uuidString; let b = UUID().uuidString
        let first = try write(root, "sessions/a.jsonl", "private conversation")
        let second = try write(root, "sessions/b.jsonl", "private child")
        let database = root.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        let schema = "CREATE TABLE threads(id TEXT, rollout_path TEXT, cwd TEXT, source TEXT, updated_at INTEGER); INSERT INTO threads VALUES ('\(a)','\(first.path)','/work/a','cli',1); INSERT INTO threads VALUES ('\(b)','\(second.path)','/work/b','{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"\(a)\",\"depth\":1}}}',2);"
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let before = try Data(contentsOf: database)
        let scan = try await ToolDataService().scan(ToolConfiguration(tool: .codex, root: root, executablePath: "/nonexistent/sweep-fixture-codex"))
        XCTAssertEqual(scan.items.count, 2)
        XCTAssertTrue(scan.items.allSatisfy { $0.risk == .unavailable })
        XCTAssertEqual(scan.items.first { $0.sessionID == a }?.relatedIDs, ["codex:session:\(b)"])
        XCTAssertEqual(try Data(contentsOf: database), before)
        XCTAssertFalse(String(describing: scan.items).contains("private conversation"))
    }
    func testCursorComposerMetadataListsIndividualReadOnlySessions() async throws {
        let root = try fixture()
        let database = try write(root, "User/workspaceStorage/a/state.vscdb", "")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE ItemTable(key TEXT,value TEXT); INSERT INTO ItemTable VALUES ('composer.composerData','{\"allComposers\":[{\"composerId\":\"one\"},{\"composerId\":\"two\"}]}');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let scan = try await ToolDataService().scan(ToolConfiguration(tool: .cursor, root: root))
        XCTAssertEqual(Set(scan.items.compactMap(\.sessionID)), ["one", "two"])
        XCTAssertTrue(scan.items.allSatisfy { !$0.isSelectable && $0.bytes == 0 })
    }
    func testCodexCapabilityUsesGeneratedSchemaAndIsolatedHome() throws {
        let root = try fixture()
        let script = try write(root, "fake-codex", """
        #!/bin/sh
        case "$CODEX_HOME" in *sweep-protocol-*) ;; *) exit 2 ;; esac
        /bin/mkdir -p "$5"
        /bin/cat > "$5/ClientRequest.json" <<'SCHEMA'
        {"definitions":{"ThreadDeleteParams":{"required":["threadId"]}},"method":"thread/delete"}
        SCHEMA
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        XCTAssertTrue(CodexAdapter.capability(script.path))
        _ = try write(root, "fake-codex", """
        #!/bin/sh
        /bin/mkdir -p "$5"
        /bin/echo '{"definitions":{},"method":"thread/delete"}' > "$5/ClientRequest.json"
        """)
        XCTAssertFalse(CodexAdapter.capability(script.path))
    }
    func testInstalledCodexOfficialDeleteInIsolatedHome() throws {
        guard let executable = ProcessInfo.processInfo.environment["PROJECT_SWEEP_TEST_CODEX"] else {
            throw XCTSkip("Set PROJECT_SWEEP_TEST_CODEX to run the installed CLI against a disposable home")
        }
        let root = try fixture()
        XCTAssertTrue(CodexAdapter.capability(executable))
        let rpc = try CodexRPC(executable: executable, root: root)
        defer { rpc.close() }
        _ = try rpc.request("initialize", params: ["clientInfo": ["name": "sweep_test", "version": "1"], "capabilities": ["experimentalApi": true]])
        try rpc.notify("initialized")
        let first = try rpc.request("thread/start", params: ["cwd": root.path, "persistExtendedHistory": true])
        let second = try rpc.request("thread/start", params: ["cwd": root.path, "persistExtendedHistory": true])
        let firstID = try XCTUnwrap((first["thread"] as? [String: Any])?["id"] as? String)
        let secondID = try XCTUnwrap((second["thread"] as? [String: Any])?["id"] as? String)
        _ = try rpc.request("thread/delete", params: ["threadId": firstID])
        let preserved = try rpc.request("thread/read", params: ["threadId": secondID, "includeTurns": false])
        XCTAssertEqual((preserved["thread"] as? [String: Any])?["id"] as? String, secondID)
        XCTAssertThrowsError(try rpc.request("thread/read", params: ["threadId": firstID, "includeTurns": false]))
    }
    func testSymlinkCacheNeverSelectable() async throws {
        let root = try fixture(); let outside = try fixture()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cache"), withDestinationURL: outside)
        let scan = try await ToolDataService().scan(ToolConfiguration(tool: .claude, root: root))
        XCTAssertTrue(scan.items.isEmpty); XCTAssertFalse(scan.warnings.isEmpty)
    }
    func testInterpreterDetectionUsesOnlyScriptOperand() {
        let node = "/opt/homebrew/bin/node"
        let claude = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        XCTAssertTrue(ToolProcessIdentity.matches(.claude, executable: node, arguments: [node, claude, "prompt"]))
        XCTAssertTrue(ToolProcessIdentity.matches(.claude, executable: "/usr/local/bin/bun", arguments: ["bun", "run", claude, "prompt"]))
        XCTAssertTrue(ToolProcessIdentity.matches(.claude, executable: node, arguments: [node, "--require", "/tmp/helper.js", "--", claude]))
        XCTAssertTrue(ToolProcessIdentity.matches(.claude, executable: node, arguments: [node, "/usr/local/bin/claude"]))
        XCTAssertFalse(ToolProcessIdentity.matches(.claude, executable: node, arguments: [node, "/work/ordinary.js", claude]))
        XCTAssertFalse(ToolProcessIdentity.matches(.claude, executable: node, arguments: [node, "-e", "console.log('" + claude + "')", claude]))
        XCTAssertFalse(ToolProcessIdentity.matches(.claude, executable: node, arguments: [node, "--eval=" + claude]))
        XCTAssertTrue(ToolProcessIdentity.matches(.codex, executable: "/Applications/Codex.app/Contents/MacOS/Codex", arguments: []))
        XCTAssertTrue(ToolProcessIdentity.matches(.cursor, executable: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper", arguments: []))
    }
    func testProcessArgumentsRemainAnExactInMemoryArray() throws {
        let arguments = try XCTUnwrap(ToolProcessIdentity.arguments(pid: ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(arguments.isEmpty)
        XCTAssertEqual(Array(arguments.dropFirst()), Array(CommandLine.arguments.dropFirst()))
    }
    func testCheckedReadRejectsLinksSpecialFilesAndOversizeBeforeOpening() throws {
        let root = try fixture()
        let regular = try write(root, "history.jsonl", "123456789")
        XCTAssertEqual(try ToolFiles.read(regular, root: root, limit: 9), Data("123456789".utf8))
        XCTAssertThrowsError(try ToolFiles.read(regular, root: root, limit: 8))
        let link = root.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        XCTAssertThrowsError(try ToolFiles.read(link, root: root))
        let fifo = root.appendingPathComponent("pipe.jsonl")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try ToolFiles.read(fifo, root: root))
        XCTAssertThrowsError(try ToolFiles.read(root, root: root))
    }
    func testCheckedReadRejectsNotLocalFileBeforeContentRead() throws {
        let root = try fixture(); let file = try write(root, "cloud-history.jsonl", "not downloaded")
        var checked = false
        XCTAssertThrowsError(try ToolFiles.read(file, root: root, locality: { _ in checked = true; return false }))
        XCTAssertTrue(checked)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not downloaded")
    }
    func testDatabaseRejectsSidecarSymlinkBeforeSQLiteOpen() throws {
        let root = try fixture(); let outside = try fixture()
        let database = try write(root, "state.sqlite", "not a database")
        let other = try write(outside, "shared", "untouched")
        try FileManager.default.createSymbolicLink(at: URL(fileURLWithPath: database.path + "-wal"), withDestinationURL: other)
        XCTAssertThrowsError(try ToolDatabase(database, root: root))
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "untouched")
    }
    func testClaudeBoundaryTimeChangeCannotBecomeNewTransactionBaseline() async throws {
        let root = try fixture(); let id = UUID().uuidString
        let transcript = try claude(root, project: "p", id: id)
        let history = try write(root, "history.jsonl", "{\"sessionId\":\"\(id)\"}\n")
        let configuration = ToolConfiguration(tool: .claude, root: root)
        let scan = try await ToolDataService().scan(configuration)
        let item = try XCTUnwrap(scan.items.first { $0.sessionID == id })
        let changed = "{\"sessionId\":\"\(id)\"}\n{\"sessionId\":\"new-session\",\"display\":\"new data\"}\n"
        XCTAssertThrowsError(try ClaudeAdapter.delete([item], configuration: configuration, ensureClosed: {
            try Data(changed.utf8).write(to: history)
        }))
        XCTAssertEqual(try String(contentsOf: history, encoding: .utf8), changed)
        XCTAssertTrue(ToolFiles.exists(transcript))
        XCTAssertFalse(ToolFiles.exists(root.appendingPathComponent(ClaudeAdapter.journalName)))
    }
    func testCommittedRecoveryAcceptsPartiallyRemovedSlot() throws {
        let root = try fixture()
        let first = try write(root, "projects/p/session/data/first", "first")
        _ = try write(root, "projects/p/session/data/second", "second")
        let original = first.deletingLastPathComponent()
        let snapshot = try Snapshotter.capture(original, recursive: true)
        let journal = root.appendingPathComponent(ClaudeAdapter.journalName)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        let slot = journal.appendingPathComponent("0")
        try FileManager.default.moveItem(at: original, to: slot)
        let entry = ClaudeTransaction.Entry(path: original.path, slot: "0", replacement: false, snapshot: snapshot)
        try JSONEncoder().encode(ClaudeTransaction.Manifest(entries: [entry], committed: true)).write(to: journal.appendingPathComponent("manifest.json"))
        try FileManager.default.removeItem(at: slot.appendingPathComponent("first"))
        try ClaudeTransaction.recover(root: root)
        XCTAssertFalse(ToolFiles.exists(journal)); XCTAssertFalse(ToolFiles.exists(original))
    }
    func testCommittedCleanupKeepsManifestUntilEverySlotIsRemoved() throws {
        let root = try fixture()
        let original = try write(root, "session.jsonl", "committed history")
        let snapshot = try Snapshotter.capture(original)
        let journal = root.appendingPathComponent(ClaudeAdapter.journalName)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: original, to: journal.appendingPathComponent("0"))
        let entry = ClaudeTransaction.Entry(path: original.path, slot: "0", replacement: false, snapshot: snapshot)
        let manifest = ClaudeTransaction.Manifest(entries: [entry], committed: true)
        let manifestURL = journal.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        XCTAssertThrowsError(try ClaudeTransaction.cleanupCommitted(root: root, journal: journal, manifest: manifest, afterSlot: {
            throw CleanupError.io("fixture interruption")
        }))
        XCTAssertTrue(ToolFiles.exists(manifestURL))
        XCTAssertFalse(ToolFiles.exists(journal.appendingPathComponent("0")))
        try ClaudeTransaction.recover(root: root)
        XCTAssertFalse(ToolFiles.exists(journal)); XCTAssertFalse(ToolFiles.exists(original))
    }
    func testRecoveryCanFinishEmptyJournalAfterManifestRemoval() throws {
        let root = try fixture(); let journal = root.appendingPathComponent(ClaudeAdapter.journalName)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        try ClaudeTransaction.recover(root: root)
        XCTAssertFalse(ToolFiles.exists(journal))
    }
    func testExecutableResolutionPreservesExplicitPath() {
        XCTAssertEqual(CodexAdapter.resolveExecutable("/custom location/codex"), "/custom location/codex")
        if let detected = CodexAdapter.resolveExecutable(nil) {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: detected))
            XCTAssertEqual(URL(fileURLWithPath: detected).lastPathComponent, "codex")
        }
    }

    func testCodexInventoryRejectsChildInsertedAfterQuery() throws {
        let root = try fixture(); let database = root.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads(id TEXT, rollout_path TEXT, cwd TEXT, source TEXT, updated_at INTEGER); INSERT INTO threads VALUES ('parent','/p','/work','cli',1);", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try CodexAdapter.readInventory(database, root: root).rows.count, 1)
        XCTAssertThrowsError(try CodexAdapter.readInventory(database, root: root, afterRead: {
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO threads VALUES ('child','/child','/work','cli',2);", nil, nil, nil), SQLITE_OK)
        }))
        XCTAssertEqual(try CodexAdapter.readInventory(database, root: root).rows.count, 2)
    }
    func testCodexInventoryRejectsWALCommitAfterQuery() throws {
        let root = try fixture(); let database = root.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE threads(id TEXT, rollout_path TEXT, cwd TEXT, source TEXT, updated_at INTEGER); INSERT INTO threads VALUES ('parent','/p','/work','cli',1);", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try CodexAdapter.readInventory(database, root: root, afterRead: {
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO threads VALUES ('child','/child','/work','cli',2);", nil, nil, nil), SQLITE_OK)
        }))
    }
    func testCodexMissingSourceAndUnknownParentStructureFailClosed() async throws {
        let parent = UUID().uuidString
        XCTAssertEqual(CodexAdapter.parentID(["subagent": ["thread_spawn": ["parent_thread_id": parent, "depth": 1]]]), parent)
        XCTAssertNil(CodexAdapter.parentID(["future-source": ["parent_thread_id": parent]]))
        XCTAssertNil(CodexAdapter.parentID(["subagent": ["thread_spawn": ["parent_thread_id": parent]]]))
        let root = try fixture(); let transcript = try write(root, "sessions/a.jsonl", "session")
        let database = root.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        let sql = "CREATE TABLE threads(id TEXT, rollout_path TEXT, cwd TEXT, source TEXT, updated_at INTEGER); INSERT INTO threads VALUES ('\(parent)','\(transcript.path)','/work',NULL,1);"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let scan = try await ToolDataService().scan(ToolConfiguration(tool: .codex, root: root, executablePath: "/nonexistent/sweep-codex"))
        XCTAssertEqual(scan.items.count, 1)
        XCTAssertEqual(scan.items.first?.sessionID, parent)
        XCTAssertTrue(scan.items.allSatisfy { !$0.isSelectable })
        XCTAssertEqual(scan.toolStatus?.sessionRead, .partial)
        XCTAssertTrue(scan.warnings.contains { $0.contains("元数据不完整") })
    }

}
