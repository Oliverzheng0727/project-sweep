import CleanupCore
import Foundation

@main struct MultipleLibraryChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("Sweep-libraries-\(UUID())").standardizedFileURL
        let first = sandbox.appendingPathComponent("Claude 项目库")
        let second = sandbox.appendingPathComponent("工作文档")
        let suite = "sweep-multiple-library-test-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); try? fm.removeItem(at: sandbox) }
        for root in [first, second] {
            try fm.createDirectory(at: root.appendingPathComponent("论文/__pycache__"), withIntermediateDirectories: true)
            try Data("成果".utf8).write(to: root.appendingPathComponent("论文/最终成果.txt"))
            try Data("cache".utf8).write(to: root.appendingPathComponent("论文/__pycache__/fixture.pyc"))
        }
        let state = SweepState(store: RecordStore(directory: sandbox.appendingPathComponent("logs")),
                               restorePreferences: false, preferences: preferences, defaultToolRoots: [:])
        func finish(_ state: SweepState) async throws {
            for _ in 0..<1_000 {
                if !state.busy { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard !state.busy, state.error == nil else { throw CleanupError.io(state.error ?? "UI task timeout") }
        }
        state.acceptLibrary(first)
        try await finish(state)
        let firstID = state.activeLibraryID!
        state.acceptLibrary(second)
        try await finish(state)
        let secondID = state.activeLibraryID!
        guard state.libraryLocations.count == 2, firstID != secondID,
              state.catalog?.rootPath == second.path else { fatalError("Adding a library replaced an existing entry") }
        print("PASS: multiple libraries have independent saved entries and list only the active folder")
        state.acceptLibrary(first.appendingPathComponent("."))
        try await finish(state)
        guard state.libraryLocations.count == 2, state.activeLibraryID == firstID else {
            fatalError("Adding the same canonical library produced a duplicate")
        }
        print("PASS: adding an existing library activates it without duplicating its bookmark")
        let restored = SweepState(store: RecordStore(directory: sandbox.appendingPathComponent("restored-logs")),
                                  preferences: preferences, defaultToolRoots: [:])
        await Task.yield()
        try await finish(restored)
        guard restored.libraryLocations.count == 2, restored.activeLibraryID == firstID,
              restored.libraryRoot?.path == first.path else { fatalError("Restart lost libraries or active selection") }
        print("PASS: restarting restores each library and the active entry")

        state.openProject(state.catalog!.projects[0])
        try await finish(state)
        state.selected = Set(state.items.filter { $0.risk == .recommended }.map(\.id))
        state.prepareReview()
        guard state.review != nil, !state.selected.isEmpty else { fatalError("Fixture did not prepare a cleanup review") }
        state.selectLibrary(id: secondID)
        try await finish(state)
        guard state.selected.isEmpty, state.review == nil, state.items.isEmpty,
              state.root == nil, !state.isProjectOpen, state.catalog?.rootPath == second.path else {
            fatalError("Switching libraries retained a previous project's cleanup plan")
        }
        print("PASS: switching libraries clears project selections and pending cleanup")

        state.openProject(state.catalog!.projects[0])
        state.selectLibrary(id: firstID)
        state.selectLibrary(id: secondID)
        try await finish(state)
        try await Task.sleep(for: .milliseconds(50))
        guard state.catalog?.rootPath == second.path, state.items.isEmpty, state.root == nil else {
            fatalError("Late project scan polluted the newly selected library")
        }
        print("PASS: switching libraries cancels in-flight project and catalog scans")
        state.forgetLibrary()
        try await finish(state)
        guard state.libraryRoot?.path == first.path, state.catalog?.projects.count == 1 else {
            fatalError("Removing the active library discarded the previously saved library")
        }
        guard fm.fileExists(atPath: first.path), fm.fileExists(atPath: second.path) else {
            fatalError("Removing a library entry changed its project files")
        }
        print("PASS: removing an active library returns to the previous entry without changing files")

        preferences.set(Data("expired bookmark".utf8), forKey: "grant.library.\(firstID)")
        state.selectLibrary(id: firstID)
        guard state.activeLibraryID == firstID, state.libraryRoot == nil,
              state.libraryLocations.count == 1, state.activeLibrary?.availability == .unavailable,
              state.activeLibrary?.path == first.path, state.activeLibrary?.message != nil else {
            fatalError("Unavailable library vanished or retained unsafe active access")
        }
        state.acceptLibrary(first, replacing: firstID)
        try await finish(state)
        guard state.libraryLocations.count == 1, state.activeLibraryID == firstID,
              state.activeLibrary?.isAvailable == true, state.catalog?.rootPath == first.path else {
            fatalError("Reauthorizing a saved library failed to reconnect the original entry")
        }
        print("PASS: unavailable libraries retain their identity and path and can be reauthorized")

        let migrationSuite = "sweep-library-migration-\(UUID())"
        let migrationPreferences = UserDefaults(suiteName: migrationSuite)!
        defer { migrationPreferences.removePersistentDomain(forName: migrationSuite) }
        let legacyGrants = FolderGrants(defaults: migrationPreferences)
        _ = try legacyGrants.grant(first, key: "library")
        let migrated = SweepState(store: RecordStore(directory: sandbox.appendingPathComponent("migrated-logs")),
                                  preferences: migrationPreferences, defaultToolRoots: [:])
        await Task.yield()
        try await finish(migrated)
        guard migrated.libraryLocations.count == 1, migrated.libraryRoot?.path == first.path,
              let migratedID = migrated.activeLibraryID,
              migrationPreferences.data(forKey: "grant.library.\(migratedID)") != nil else {
            fatalError("Single-library migration lost the existing authorization")
        }
        migrated.forgetLibrary()
        guard migrated.libraryLocations.isEmpty, migrated.libraryRoot == nil,
              migrationPreferences.data(forKey: "grant.library.\(migratedID)") == nil,
              migrationPreferences.data(forKey: "grant.library") == nil, fm.fileExists(atPath: first.path) else {
            fatalError("Forgetting the migrated entry retained its bookmark or modified files")
        }
        print("PASS: legacy authorization migrates and can be forgotten without altering its folder")

        let detachable = sandbox.appendingPathComponent("外置项目库")
        let moved = sandbox.appendingPathComponent("已移动项目库")
        try fm.createDirectory(at: detachable.appendingPathComponent("作品"), withIntermediateDirectories: true)
        state.acceptLibrary(detachable)
        try await finish(state)
        let detachableID = state.activeLibraryID!
        try fm.moveItem(at: detachable, to: moved)
        state.loadLibrary()
        for _ in 0..<1_000 {
            if !state.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !state.busy, state.activeLibraryID == detachableID,
              state.libraryRoot == nil, state.catalog == nil,
              state.activeLibrary?.availability == .unavailable,
              state.activeLibrary?.path == detachable.path else {
            fatalError("A disconnected library was displayed as a readable empty library")
        }
        state.acceptLibrary(moved, replacing: detachableID)
        try await finish(state)
        guard state.activeLibraryID == detachableID, state.catalog?.projects.count == 1,
              state.activeLibrary?.isAvailable == true, state.libraryRoot?.path == moved.path else {
            fatalError("Reconnecting a moved library failed to restore its catalog")
        }
        print("PASS: a moved library becomes unavailable and reconnects without losing its saved identity")
    }
}
