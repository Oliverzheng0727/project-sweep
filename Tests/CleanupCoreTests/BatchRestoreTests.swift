import XCTest
@testable import CleanupCore

final class BatchRestoreTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    private var store: RecordStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Sweep-Batch-Restore-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("项目"), withIntermediateDirectories: true)
        store = RecordStore(directory: root.appendingPathComponent("records"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func trashed(_ name: String, batch: UUID = UUID()) throws -> CleanupRecord {
        let source = root.appendingPathComponent(".Trash/" + name)
        try Data(name.utf8).write(to: source)
        return CleanupRecord(batchID: batch, originalPath: root.appendingPathComponent("项目/" + name).path,
                             trashPath: source.path, action: .trash, status: .succeeded, bytes: Int64(name.utf8.count),
                             message: "fixture", trashSnapshot: try Snapshotter.capture(source))
    }

    func testGroupingUsesOperationIdentityAndDoesNotCountDuplicateRecords() throws {
        let first = UUID(), second = UUID()
        var a = try trashed("成果.txt", batch: first)
        a.date = Date(timeIntervalSince1970: 100)
        var b = try trashed("缓存.txt", batch: first)
        b.date = Date(timeIntervalSince1970: 120)
        var c = try trashed("新的.txt", batch: second)
        c.date = Date(timeIntervalSince1970: 200)
        var restored = a; restored.status = .restored
        let groups = CleanupBatch.group([a, b, c, restored])
        XCTAssertEqual(groups.map(\.id), [second, first])
        XCTAssertEqual(groups[1].records.count, 2)
        XCTAssertEqual(groups[1].restorableRecords.map(\.id), [b.id])
        XCTAssertEqual(groups[1].restoredCount, 1)
        XCTAssertEqual(groups[1].processedBytes, a.bytes + b.bytes)
    }

    func testReviewExcludesSessionsFailedFilesAndMissingRestoreMetadata() throws {
        let file = try trashed("可以恢复.txt")
        let session = CleanupRecord(batchID: file.batchID, originalPath: "/fixture/session", action: .deleteSession,
                                    tool: .codex, status: .succeeded, bytes: 50, message: "fixture")
        var failed = file; failed.id = UUID(); failed.status = .failed
        var incomplete = file; incomplete.id = UUID(); incomplete.trashSnapshot = nil
        let plan = RestorePlan(records: [file, session, failed, incomplete, file])
        XCTAssertEqual(plan.records.map(\.id), [file.id])
        XCTAssertEqual(plan.excludedRecords.count, 3)
        XCTAssertEqual(plan.bytes, file.bytes)
    }

    func testBatchKeepsSuccessfulRestoresWhenOtherFilesConflictOrAreMissing() async throws {
        let batch = UUID()
        let good = try trashed("恢复.txt", batch: batch)
        let conflict = try trashed("同名.txt", batch: batch)
        let missing = try trashed("已清空.txt", batch: batch)
        try Data("new user file".utf8).write(to: URL(fileURLWithPath: conflict.originalPath))
        try FileManager.default.removeItem(atPath: try XCTUnwrap(missing.trashPath))
        try await store.append([good, conflict, missing])
        let report = await RestoreExecutor(store: store).execute(RestorePlan(records: [good, conflict, missing]))
        XCTAssertEqual(report.restoredCount, 1)
        XCTAssertEqual(report.outcomes.count, 3)
        XCTAssertEqual(report.outcomes.filter { $0.status == .failed }.count, 2)
        XCTAssertEqual(try String(contentsOfFile: good.originalPath, encoding: .utf8), "恢复.txt")
        XCTAssertEqual(try String(contentsOfFile: conflict.originalPath, encoding: .utf8), "new user file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(conflict.trashPath)))
        let saved = try await store.load()
        XCTAssertEqual(saved.first { $0.id == good.id }?.status, .restored)
        XCTAssertEqual(saved.first { $0.id == conflict.id }?.status, .succeeded)
        XCTAssertEqual(saved.first { $0.id == missing.id }?.status, .succeeded)
    }

    func testStaleReviewCannotRestoreChangedPersistedTarget() async throws {
        let reviewed = try trashed("reviewed.txt")
        var current = reviewed
        current.originalPath = root.appendingPathComponent("项目/different.txt").path
        try await store.append([current])
        let report = await RestoreExecutor(store: store).execute(RestorePlan(records: [reviewed]))
        XCTAssertEqual(report.restoredCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reviewed.originalPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.originalPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(reviewed.trashPath)))
    }

    func testRecordRemovedFromLogIsNotRestored() async throws {
        let reviewed = try trashed("unregistered.txt")
        let report = await RestoreExecutor(store: store).execute(RestorePlan(records: [reviewed]))
        XCTAssertEqual(report.restoredCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(reviewed.trashPath)))
    }

    func testAlreadyRestoredRecordCannotBeRepeatedEvenIfTrashFileReappears() async throws {
        let reviewed = try trashed("restored.txt")
        var current = reviewed; current.status = .restored
        try await store.append([current])
        let report = await RestoreExecutor(store: store).execute(RestorePlan(records: [reviewed]))
        XCTAssertEqual(report.restoredCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reviewed.originalPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(reviewed.trashPath)))
    }

    func testConcurrentRequestsOnlyRestoreEachRecordOnce() async throws {
        let record = try trashed("concurrent.txt")
        try await store.append([record])
        let plan = RestorePlan(records: [record])
        async let first = RestoreExecutor(store: store).execute(plan)
        async let second = RestoreExecutor(store: store).execute(plan)
        let reports = await [first, second]
        XCTAssertEqual(reports.reduce(0) { $0 + $1.restoredCount }, 1)
        XCTAssertEqual(try String(contentsOfFile: record.originalPath, encoding: .utf8), "concurrent.txt")
        let saved = try await store.load()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.status, .restored)
    }

    func testCancelledBatchDoesNotRestoreAnyFiles() async throws {
        let record = try trashed("cancelled.txt")
        try await store.append([record])
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await RestoreExecutor(store: store).execute(RestorePlan(records: [record]))
        }
        let report = await operation.value
        XCTAssertEqual(report.restoredCount, 0)
        XCTAssertEqual(report.outcomes.first?.status, .skipped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(record.trashPath)))
    }
}
