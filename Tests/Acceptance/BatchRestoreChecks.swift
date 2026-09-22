import Foundation
import CleanupCore

@main struct BatchRestoreChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sweep-batch-state-" + UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: root.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Project"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let batch = UUID()
        func fixture(_ name: String) throws -> CleanupRecord {
            let trash = root.appendingPathComponent(".Trash/" + name)
            try Data(name.utf8).write(to: trash)
            return CleanupRecord(batchID: batch, originalPath: root.appendingPathComponent("Project/" + name).path,
                                 trashPath: trash.path, action: .trash, status: .succeeded, bytes: 10,
                                 message: "fixture", trashSnapshot: try Snapshotter.capture(trash))
        }
        let good = try fixture("restore.txt"), conflict = try fixture("conflict.txt")
        let session = CleanupRecord(batchID: batch, originalPath: "/fixture/session", action: .deleteSession,
                                    tool: .codex, status: .succeeded, bytes: 20, message: "fixture")
        try Data("existing".utf8).write(to: URL(fileURLWithPath: conflict.originalPath))
        let store = RecordStore(directory: root.appendingPathComponent("logs"))
        try await store.append([good, conflict, session])
        let suite = "sweep-batch-state-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let state = SweepState(store: store, restorePreferences: false, preferences: preferences, defaultToolRoots: [:])
        state.page = .records
        await state.loadRecords()
        state.prepareRestore(records: state.recordBatches[0].records)
        guard let obsolete = state.restoreReview, obsolete.records.count == 2,
              obsolete.excludedRecords.count == 1, !fm.fileExists(atPath: good.originalPath) else {
            fatalError("review must list only recoverable files without executing")
        }
        print("PASS: restore review lists files and excludes nonrecoverable sessions without moving data")
        state.page = .settings
        state.executeRestore(obsolete)
        guard state.restoreReview == nil, !state.executing, !fm.fileExists(atPath: good.originalPath) else {
            fatalError("navigation must invalidate a pending restore confirmation")
        }
        print("PASS: navigation invalidates old restore review and blocks its execution")
        state.page = .records
        state.prepareRestore(records: state.records)
        let plan = state.restoreReview!
        state.executeRestore(plan)
        state.executeRestore(plan)
        for _ in 0..<300 where state.executing { try await Task.sleep(for: .milliseconds(10)) }
        guard !state.executing, let report = state.restoreReport,
              report.outcomes.count == 2, report.restoredCount == 1,
              state.records.first(where: { $0.id == good.id })?.status == .restored,
              state.records.first(where: { $0.id == conflict.id })?.status == .succeeded,
              try String(contentsOfFile: conflict.originalPath, encoding: .utf8) == "existing" else {
            fatalError("partial restoration must preserve physical successes and report conflict individually")
        }
        print("PASS: duplicate restore submission is blocked and partial success remains visible")
        await state.loadRecords()
        state.prepareRestore(records: state.records)
        guard state.restoreReview?.records.map(\.id) == [conflict.id], state.recordBatches.count == 1 else {
            fatalError("already restored files must not be offered again")
        }
        print("PASS: reload keeps the original batch and excludes restored items from retry")
    }
}
