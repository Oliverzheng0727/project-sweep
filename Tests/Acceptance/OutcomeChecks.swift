import Foundation
import CleanupCore

@main struct OutcomeChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sweep-outcome-check-" + UUID().uuidString).resolvingSymlinksInPath()
        let log = root.appendingPathComponent("logs")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: log.path)
            try? fm.removeItem(at: root)
        }
        let store = RecordStore(directory: log)
        let prior = CleanupRecord(originalPath: "/fixture/prior", action: .trash, status: .failed, message: "prior fixture")
        try await store.append([prior])
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: log.path)
        let file = root.appendingPathComponent("must-survive.txt")
        try Data("do not delete".utf8).write(to: file)
        let item = CleanupItem(path: file.path, rootPath: root.path, reason: "fixture", snapshot: try Snapshotter.capture(file))
        let state = SweepState(store: store, restorePreferences: false)
        state.execute(CleanupPlan(items: [item]))
        for _ in 0..<300 where state.executing { try await Task.sleep(for: .milliseconds(10)) }
        guard !state.executing else { fatalError("operation did not finish") }
        guard fm.fileExists(atPath: file.path) else { fatalError("fixture unexpectedly deleted") }
        guard state.records.count == 2, state.records.contains(where: { $0.originalPath == file.path && $0.status == .failed }), state.recordWarning != nil else {
            fatalError("returned persistence failure missing from visible records")
        }
        await state.loadRecords()
        guard state.records.count == 2, state.recordWarning != nil else { fatalError("reload erased in-memory outcomes") }
        print("PASS: read-only log failure remains visible alongside persisted records")
        print("PASS: repeated load preserves current execution outcomes and warning")
        print("PASS: blocked log write leaves selected fixture file intact")
    }
}
