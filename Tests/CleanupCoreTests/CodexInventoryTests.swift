import XCTest
import Foundation
import CSQLite
@testable import CleanupCore

final class CodexInventoryTests: XCTestCase, @unchecked Sendable {
    private func fixture(_ rows: [[String?]]) throws -> (URL, String) {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/sweep-codex-inventory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-codex")
        try Data("""
        #!/bin/sh
        /bin/mkdir -p "$5"
        /bin/echo '{"definitions":{"ThreadDeleteParams":{"required":["threadId"]}},"method":"thread/delete"}' > "$5/ClientRequest.json"
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads(id TEXT, rollout_path TEXT, cwd TEXT, source TEXT, updated_at INTEGER, title TEXT)", nil, nil, nil), SQLITE_OK)
        for row in rows {
            let path = row[1].map { $0.hasPrefix("/") ? $0 : root.appendingPathComponent($0).path }
            if let path, !path.hasSuffix("missing.jsonl"), PathSafety.isWithin(path, root: root.path) {
                try Data("private transcript body".utf8).write(to: URL(fileURLWithPath: path))
            }
            let values = [row[0], path, row[2], row[3], "100", "Test session"].map { value in
                value.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL"
            }.joined(separator: ",")
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO threads VALUES (" + values + ")", nil, nil, nil), SQLITE_OK)
        }
        return (root, executable.path)
    }

    func testEmptyProjectPathKeepsReadableSessionsAndMarksInventoryPartial() async throws {
        let knownID = UUID().uuidString, unassignedID = UUID().uuidString
        let (root, executable) = try fixture([
            [knownID, "sessions/known.jsonl", "/work/project", "vscode"],
            [unassignedID, "sessions/unassigned.jsonl", "", "unknown"]
        ])
        let before = try Data(contentsOf: root.appendingPathComponent("state_5.sqlite"))
        let scan = try await ToolDataService().scan(.init(tool: .codex, root: root, executablePath: executable))
        XCTAssertEqual(Set(scan.items.compactMap(\.sessionID)), [knownID, unassignedID])
        XCTAssertEqual(scan.items.first { $0.sessionID == knownID }?.projectPath, "/work/project")
        XCTAssertNil(scan.items.first { $0.sessionID == unassignedID }?.projectPath)
        XCTAssertEqual(scan.toolStatus?.sessionRead, .partial)
        XCTAssertEqual(scan.toolStatus?.sessionDeletion, .unavailable, "Incomplete dependencies block deletion even when the installed protocol supports it")
        XCTAssertTrue(scan.items.allSatisfy { !$0.isSelectable })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("state_5.sqlite")), before)
        XCTAssertFalse(String(describing: scan).contains("private transcript body"))
    }

    func testMissingFileAndMalformedSourceDoNotDiscardOtherMetadata() async throws {
        let first = UUID().uuidString, missing = UUID().uuidString, malformed = UUID().uuidString
        let (root, executable) = try fixture([
            [first, "sessions/first.jsonl", "/work/first", "cli"],
            [missing, "sessions/missing.jsonl", "/work/missing", "exec"],
            [malformed, "sessions/malformed.jsonl", "/work/malformed", "{malformed"]
        ])
        let scan = try await ToolDataService().scan(.init(tool: .codex, root: root, executablePath: executable))
        XCTAssertEqual(Set(scan.items.compactMap(\.sessionID)), [first, missing, malformed])
        XCTAssertEqual(scan.toolStatus?.sessionRead, .partial)
        XCTAssertEqual(scan.toolStatus?.sessionDeletion, .unavailable)
        XCTAssertTrue(scan.items.allSatisfy { !$0.isSelectable })
        XCTAssertNil(scan.items.first { $0.sessionID == missing }?.snapshot)
        XCTAssertNotNil(scan.items.first { $0.sessionID == first }?.snapshot)
        XCTAssertFalse(String(describing: scan).contains("{malformed"))
    }

    func testMissingParentDisablesWholeInventoryAfterLinking() async throws {
        let first = UUID().uuidString, child = UUID().uuidString, absentParent = UUID().uuidString
        let source = "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"\(absentParent)\",\"depth\":1}}}"
        let (root, executable) = try fixture([
            [first, "sessions/first.jsonl", "/work/first", "cli"],
            [child, "sessions/child.jsonl", "/work/child", source]
        ])
        let scan = try await ToolDataService().scan(.init(tool: .codex, root: root, executablePath: executable))
        XCTAssertEqual(scan.items.count, 2)
        XCTAssertEqual(scan.toolStatus?.sessionRead, .partial)
        XCTAssertTrue(scan.items.allSatisfy { !$0.isSelectable })
    }

    func testUntrustedRolloutPathNeverHidesSafeSiblingOrEscapesScope() async throws {
        let safeID = UUID().uuidString, outsideID = UUID().uuidString
        let (root, executable) = try fixture([
            [outsideID, "/not-authorized/transcript.jsonl", "/work/outside", "exec"],
            [safeID, "sessions/safe.jsonl", "/work/safe", "cli"]
        ])
        let scan = try await ToolDataService().scan(.init(tool: .codex, root: root, executablePath: executable))
        XCTAssertEqual(scan.items.compactMap(\.sessionID), [safeID])
        XCTAssertEqual(scan.toolStatus?.sessionRead, .partial)
        XCTAssertTrue(scan.items.allSatisfy { !$0.isSelectable && PathSafety.isWithin($0.path, root: root.path) })
    }

    func testCompleteInventoryRetainsSelectableProjectGroups() async throws {
        let parent = UUID().uuidString, child = UUID().uuidString, separate = UUID().uuidString
        let source = "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"\(parent.lowercased())\",\"depth\":1}}}"
        let (root, executable) = try fixture([
            [parent, "sessions/parent.jsonl", "/work/项目一", "vscode"],
            [child, "sessions/child.jsonl", "/work/项目一", source],
            [separate, "sessions/separate.jsonl", "/work/项目二", "exec"]
        ])
        let scan = try await ToolDataService().scan(.init(tool: .codex, root: root, executablePath: executable))
        XCTAssertEqual(scan.toolStatus?.sessionRead, .complete)
        XCTAssertEqual(scan.items.count, 3)
        XCTAssertTrue(scan.items.allSatisfy(\.isSelectable))
        XCTAssertEqual(scan.items.first { $0.sessionID == parent }?.relatedIDs, ["codex:session:\(child)"])
        XCTAssertEqual(scan.items.first { $0.sessionID == child }?.metadata["parentID"], parent)
        XCTAssertEqual(scan.items.first { $0.sessionID == separate }?.relatedIDs, [])
        let plan = try SelectionPlanner.makePlan(items: scan.items, selectedIDs: ["codex:session:\(parent)"])
        XCTAssertEqual(Set(plan.items.compactMap(\.sessionID)), [parent, child])
    }
}
