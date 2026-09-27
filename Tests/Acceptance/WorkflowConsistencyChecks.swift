import CleanupCore
import Foundation

@main struct WorkflowConsistencyChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("Sweep-consistency-\(UUID())").standardizedFileURL
        let library = sandbox.appendingPathComponent("项目库")
        let project = library.appendingPathComponent("论文")
        let suite = "sweep-consistency-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: project.path)
            try? fm.removeItem(at: sandbox)
            preferences.removePersistentDomain(forName: suite)
        }
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let original = try await ProjectCatalog().list(library).projects[0]
        let state = SweepState(store: RecordStore(directory: sandbox.appendingPathComponent("records")),
                               restorePreferences: false, preferences: preferences, defaultToolRoots: [:], skillDiscovery: nil)
        state.scanSummaries[project.path] = ProjectScanSummary(bytes: 100, cacheBytes: 80, scannedAt: Date(), snapshot: original.snapshot)
        var failures: [String] = []
        func check(_ result: Bool, _ message: String) {
            if result { print("PASS: \(message)") }
            else { failures.append(message); print("FAIL: \(message)") }
        }
        // A valid inode alone must not make an unreadable project's hidden summary filterable.
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: project.path)
        let unavailable = try await ProjectCatalog().list(library).projects[0]
        let scanned = ProjectLibraryQuery(filter: .scanned).apply(to: [unavailable], summaries: state.scanSummaries, recentPaths: [], pinnedPaths: [])
        let cached = ProjectLibraryQuery(filter: .withCache).apply(to: [unavailable], summaries: state.scanSummaries, recentPaths: [], pinnedPaths: [])
        check(!unavailable.isAvailable && state.summary(for: unavailable) == nil && scanned.isEmpty && cached.isEmpty,
              "unavailable projects cannot match hidden scan or cache summaries")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: project.path)
        let available = try await ProjectCatalog().list(library).projects[0]
        let restored = ProjectLibraryQuery(filter: .withCache).apply(to: [available], summaries: state.scanSummaries, recentPaths: [], pinnedPaths: [])
        check(state.summary(for: available)?.cacheBytes == 80 && restored.map(\.path) == [project.path],
              "restored access makes the same project summary visible and filterable again")

        // Refreshing the scan must replace classification context even when the file identity is unchanged.
        let root = "/isolated/项目"
        let parent = root + "/generated"
        let file = CleanupItem(path: parent + "/index.js", rootPath: root, category: .source, reason: "fixture",
                               bytes: 20, parentPath: parent,
                               snapshot: FileSnapshot(device: 1, inode: 3, size: 20, modifiedNanoseconds: 0, mode: 0))
        let rootItem = CleanupItem(path: root, rootPath: root, reason: "fixture", isDirectory: true)
        var container = CleanupItem(path: parent, rootPath: root, category: .dependency, reason: "fixture", isDirectory: true, parentPath: root)
        state.items = [rootItem, container, file]
        state.selected = [file.id]
        var query = BrowserFilters(); query.storageKind = .dependencies; query.minimumBytes = 20
        state.setFilters(query, for: .projectFiles)
        let before = state.visibleItems(.projectFiles).map(\.id)
        container.category = .build
        state.items = [rootItem, container, file]
        let oldKind = state.visibleItems(.projectFiles)
        query.storageKind = .build
        state.setFilters(query, for: .projectFiles)
        let after = state.visibleItems(.projectFiles).map(\.id)
        query.onlySelected = true
        state.setFilters(query, for: .projectFiles)
        state.selected = []
        let unselected = state.visibleItems(.projectFiles)
        state.selected = [file.id]
        query.tree = true
        state.setFilters(query, for: .projectFiles)
        let selected = state.visibleItems(.projectFiles).map(\.id)
        state.items = []
        check(before == [file.id] && oldKind.isEmpty && after == [file.id] && unselected.isEmpty
              && selected == [file.id] && state.visibleItems(.projectFiles).isEmpty,
              "scan replacement and selection changes never reuse stale storage classification or matches")

        // A protected or reviewable unit can still have an incomplete measured size.
        var incomplete = CleanupItem(path: root + "/作品.pages", rootPath: root, category: .document,
                                     risk: .protected, reason: "fixture", bytes: 12, isDirectory: true, parentPath: root,
                                     snapshot: FileSnapshot(device: 1, inode: 4, size: 12, modifiedNanoseconds: 0, mode: 0))
        incomplete.metadata["sizeIncomplete"] = "true"
        let breakdown = ProjectStorageBreakdown(items: [rootItem, incomplete])
        check(breakdown.totalBytes == 12 && !breakdown.isComplete && breakdown.segments.first?.incomplete == true,
              "space totals retain known bytes while explicitly marking incomplete protected units")
        guard failures.isEmpty else { throw CleanupError.io(failures.joined(separator: "; ")) }
    }
}
