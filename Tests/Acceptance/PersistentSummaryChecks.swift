import CleanupCore
import Foundation

@main struct PersistentSummaryChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("Sweep-summary-\(UUID())").standardizedFileURL
        let library = sandbox.appendingPathComponent("创作项目库")
        let project = library.appendingPathComponent("论文")
        let suite = "sweep-summary-test-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); try? fm.removeItem(at: sandbox) }
        try fm.createDirectory(at: project.appendingPathComponent("__pycache__"), withIntermediateDirectories: true)
        try Data("private text must never persist".utf8).write(to: project.appendingPathComponent("私人终稿.txt"))
        try Data("cache".utf8).write(to: project.appendingPathComponent("__pycache__/fixture.pyc"))
        func makeState() -> SweepState {
            SweepState(store: RecordStore(directory: sandbox.appendingPathComponent(UUID().uuidString)),
                       restorePreferences: false, preferences: preferences, defaultToolRoots: [:], skillDiscovery: nil)
        }
        func finish(_ state: SweepState) async throws {
            for _ in 0..<1_000 {
                if !state.busy, !state.executing { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard !state.busy, !state.executing, state.error == nil else { throw CleanupError.io(state.error ?? "UI task timeout") }
        }
        let state = makeState()
        state.acceptLibrary(library)
        try await finish(state)
        let entry = state.catalog!.projects[0]
        let creationTime = entry.createdAt
        state.openProject(entry)
        try await finish(state)
        guard let summary = state.summary(for: entry), summary.bytes > 0, summary.cacheBytes > 0 else {
            fatalError("Complete project fixture did not produce the expected aggregate")
        }
        let restored = makeState()
        guard let saved = restored.summary(for: entry), saved.bytes == summary.bytes, saved.cacheBytes == summary.cacheBytes,
              saved.scannedAt == summary.scannedAt, saved.isHistorical else {
            fatalError("Restart discarded the complete project's scan summary")
        }
        guard restored.items.isEmpty, restored.selected.isEmpty, restored.review == nil,
              entry.createdAt == creationTime else { fatalError("Historical metadata restored destructive state or rewrote the project creation time") }
        print("PASS: restart restores complete summary metadata without file items, selections, or creation-time changes")
        let persisted = preferences.data(forKey: "projectScanSummaryMetadata")!
        let envelope = try JSONSerialization.jsonObject(with: persisted) as! [String: Any]
        let records = envelope["summaries"] as! [[String: Any]]
        guard records.count == 1,
              Set(records[0].keys) == Set(["path", "bytes", "cacheBytes", "scannedAt", "device", "inode"]),
              !(String(data: persisted, encoding: .utf8) ?? "").contains("私人终稿"),
              !(String(data: persisted, encoding: .utf8) ?? "").contains("private text") else {
            fatalError("Persistent statistics contain file inventories or document content")
        }
        print("PASS: persistent summary data contains only project identity, time and aggregate sizes")
        restored.acceptProject(project)
        guard restored.currentProjectSummary?.isHistorical == true,
              restored.currentProjectSummary?.scannedAt == summary.scannedAt,
              restored.items.isEmpty, restored.selected.isEmpty, restored.review == nil else {
            fatalError("Opening a cached project did not show history independently of a fresh scan")
        }
        restored.cancelScan()
        guard restored.scanSummaries[project.path]?.isHistorical == true, restored.items.isEmpty,
              restored.selected.isEmpty, restored.review == nil else {
            fatalError("Cancelled scanning promoted historical data into actionable results")
        }
        restored.scanProject()
        try await finish(restored)
        guard restored.currentProjectSummary?.isHistorical == false, !restored.items.isEmpty else {
            fatalError("Fresh scan did not replace historical metadata")
        }
        restored.selected = Set(restored.items.filter { $0.risk == .recommended }.map(\.id))
        restored.prepareReview()
        guard restored.review != nil else { fatalError("Fixture did not produce a review") }
        restored.scanProject()
        guard restored.currentProjectSummary?.isHistorical == true, restored.items.isEmpty,
              restored.selected.isEmpty, restored.review == nil else {
            fatalError("Rescanning reused a current summary or destructive state before validation")
        }
        restored.cancelScan()
        print("PASS: opening and rescanning display unverified history while clearing old file choices; cancellation keeps history unverified")

        restored.scanProject()
        try await finish(restored)
        let beforeIncomplete = restored.currentProjectSummary!
        let unreadable = project.appendingPathComponent("未授权内容")
        try fm.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        restored.scanProject()
        try await finish(restored)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path)
        guard !restored.projectOverview.isComplete, restored.currentProjectSummary?.isHistorical == true,
              restored.currentProjectSummary?.scannedAt == beforeIncomplete.scannedAt else {
            fatalError("An incomplete scan replaced previously complete statistics")
        }
        print("PASS: unreadable contents keep prior complete statistics historical instead of publishing incomplete totals")
        restored.scanProject()
        try await finish(restored)
        let failedItem = CleanupItem(path: project.appendingPathComponent("私人终稿.txt").path,
            rootPath: project.path, reason: "Isolated refusal fixture", snapshot: nil)
        restored.execute(CleanupPlan(items: [failedItem]))
        guard restored.scanSummaries[project.path]?.isHistorical == true else {
            fatalError("Cleanup retained previously verified project statistics")
        }
        try await finish(restored)
        guard restored.records.last?.status == .failed,
              fm.fileExists(atPath: project.appendingPathComponent("私人终稿.txt").path) else {
            fatalError("The deliberately unverified fixture should be refused without touching its file")
        }
        print("PASS: attempted cleanup marks affected project totals unverified, including safely refused operations")

        state.forgetLibrary()
        let forgotten = makeState()
        guard forgotten.scanSummaries[project.path] == nil, fm.fileExists(atPath: project.path) else {
            fatalError("Forgetting a library preserved persistent scan metadata or changed files")
        }
        print("PASS: forgetting a project library also forgets its scan statistics without touching files")

        let oldProject = sandbox.appendingPathComponent("旧论文")
        try fm.moveItem(at: project, to: oldProject)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let replacedEntry = try await ProjectCatalog().list(library).projects[0]
        guard restored.summary(for: replacedEntry) == nil else {
            fatalError("Replaced project reused a different folder's summary")
        }
        restored.acceptProject(project)
        guard restored.currentProjectSummary == nil else {
            fatalError("Opening a replacement folder showed historical data for the previous inode")
        }
        restored.cancelScan()
        print("PASS: project identity mismatch excludes old summaries from cards and the open project")

        let invalidSuite = "sweep-invalid-summary-test-\(UUID())"
        let invalidPreferences = UserDefaults(suiteName: invalidSuite)!
        defer { invalidPreferences.removePersistentDomain(forName: invalidSuite) }
        for data in [Data("broken JSON".utf8), Data(repeating: 120, count: 1_048_577)] {
            invalidPreferences.set(data, forKey: "projectScanSummaryMetadata")
            let invalid = SweepState(store: RecordStore(directory: sandbox.appendingPathComponent(UUID().uuidString)),
                restorePreferences: false, preferences: invalidPreferences, defaultToolRoots: [:], skillDiscovery: nil)
            guard invalid.scanSummaries.isEmpty, invalid.summaryCacheWarning != nil,
                  invalidPreferences.data(forKey: "projectScanSummaryMetadata") == nil else {
                fatalError("Corrupt or oversized cached data was retained or shown as a valid summary")
            }
        }
        print("PASS: malformed and oversized persisted statistics are discarded with a nonblocking explanation")
        let limitedStore = ProjectScanSummaryStore(defaults: invalidPreferences, maximumRecords: 1, maximumBytes: 400)
        var newer = summary
        newer.scannedAt = summary.scannedAt.addingTimeInterval(1)
        limitedStore.save(["/fixture/older": summary, "/fixture/newer": newer])
        let limited = limitedStore.load()
        guard Set(limited.summaries.keys) == Set(["/fixture/newer"]),
              limited.summaries["/fixture/newer"]?.isHistorical == true,
              (invalidPreferences.data(forKey: "projectScanSummaryMetadata")?.count ?? .max) <= 400 else {
            fatalError("Summary cache did not enforce bounded, newest-first metadata retention")
        }
        let injected = SweepState(store: RecordStore(directory: sandbox.appendingPathComponent(UUID().uuidString)),
            restorePreferences: false, preferences: preferences, defaultToolRoots: [:], skillDiscovery: nil,
            summaryStore: limitedStore)
        guard Set(injected.scanSummaries.keys) == Set(["/fixture/newer"]) else {
            fatalError("State ignored its injected summary store")
        }
        print("PASS: metadata cache retains recent entries within count and size limits and supports isolated storage")
    }
}
