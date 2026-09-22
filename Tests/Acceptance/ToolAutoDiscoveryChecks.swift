import CleanupCore
import Foundation

@main struct ToolAutoDiscoveryChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("Sweep-tool-discovery-\(UUID())").standardizedFileURL
        let codex = sandbox.appendingPathComponent(".codex")
        let claude = sandbox.appendingPathComponent(".claude")
        let cursorLink = sandbox.appendingPathComponent("Cursor")
        let preferenceName = "sweep-tool-discovery-test-\(UUID())"
        let preferences = UserDefaults(suiteName: preferenceName)!
        defer {
            preferences.removePersistentDomain(forName: preferenceName)
            try? fm.removeItem(at: sandbox)
        }
        try fm.createDirectory(at: codex, withIntermediateDirectories: true)
        try fm.createDirectory(at: claude, withIntermediateDirectories: true)
        try fm.createDirectory(at: claude.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: cursorLink, withDestinationURL: codex)

        let roots: [ToolKind: URL] = [.codex: codex, .claude: claude, .cursor: cursorLink]
        let state = SweepState(store: RecordStore(directory: sandbox.appendingPathComponent("logs")),
                               restorePreferences: false, preferences: preferences, defaultToolRoots: roots)
        state.discoverDefaultTools(scanAfterDiscovery: false)
        try await finish(state)
        guard Set(state.configurations.map(\.tool)) == [.codex, .claude],
              preferences.data(forKey: "grant.codex") != nil,
              preferences.data(forKey: "grant.claude") != nil else {
            fatalError("Default tool folders were not connected automatically")
        }

        state.disconnectTool(.claude)
        state.discoverDefaultTools(scanAfterDiscovery: false)
        try await finish(state)
        guard state.configurations.map(\.tool) == [.codex],
              preferences.data(forKey: "grant.claude") == nil else {
            fatalError("An explicitly disconnected tool was automatically reconnected")
        }
        guard fm.fileExists(atPath: codex.path), fm.fileExists(atPath: claude.path),
              fm.fileExists(atPath: cursorLink.path) else { fatalError("Discovery modified tool data") }
        print("PASS: known tool folders connect automatically; symlinks and explicit disconnects remain untouched")

        // Entering the related tab must not rescan the project or drop its selection.
        let project = sandbox.appendingPathComponent("作品")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let cache = project.appendingPathComponent(".DS_Store")
        try Data("fixture".utf8).write(to: cache)
        let projectScan = try await ProjectScanner().scan(ScanRequest(root: project))
        state.root = project; state.isProjectOpen = true
        state.items = projectScan.items; state.filesScanned = true
        let chosen = projectScan.items.first { $0.path == cache.path }!
        state.selected = [chosen.id]
        state.toolInspections[.codex] = ToolInspection(phase: .pending)
        state.projectTab = .related
        try await finish(state)
        guard state.inspection(for: .codex).report?.sessionRead == .unsupported,
              state.selected == [chosen.id],
              state.items.filter({ $0.tool == nil }) == projectScan.items else {
            fatalError("Opening related records must inspect pending tools without rescanning project files or clearing selection")
        }
        print("PASS: opening related records checks pending tools while preserving project files and selection")

        state.projectTab = .files; state.projectTab = .related
        guard !state.busy, state.selected == [chosen.id] else { fatalError("Reopening a checked tab restarted discovery") }
        print("PASS: repeated project tab switches retain completed results and selected files")

        state.toolInspections[.codex] = ToolInspection(phase: .cancelled)
        state.discoverDefaultTools()
        try await finish(state)
        guard state.inspection(for: .codex).report?.sessionRead == .unsupported,
              state.selected == [chosen.id] else { fatalError("Manual related refresh did not retry a cancelled tool while keeping file selection") }
        print("PASS: manual related refresh retries cancelled tools and retains project file selection")

        let relaunch = SweepState(store: RecordStore(directory: sandbox.appendingPathComponent("other-logs")),
                                 preferences: preferences, defaultToolRoots: roots)
        relaunch.discoverDefaultTools(scanAfterDiscovery: false)
        try await finish(relaunch)
        guard !relaunch.configurations.contains(where: { $0.tool == .claude }),
              relaunch.toolDiscoveryMessages[.claude] != nil else { fatalError("Explicit disconnect did not survive relaunch") }
        print("PASS: explicit disconnect survives relaunch and provides a reconnect explanation")

        let deferredPreferences = UserDefaults(suiteName: preferenceName + "-deferred")!
        defer { deferredPreferences.removePersistentDomain(forName: preferenceName + "-deferred") }
        let deferred = SweepState(store: RecordStore(directory: sandbox.appendingPathComponent("deferred-logs")),
                                  restorePreferences: false, preferences: deferredPreferences, defaultToolRoots: roots)
        deferred.configurations = [ToolConfiguration(tool: .codex, root: codex)]
        deferred.acceptProject(project)
        deferred.projectTab = .related // Enter while the project scanner is still busy, with only one connected tool.
        try await finish(deferred)
        guard deferred.filesScanned, Set(deferred.configurations.map(\.tool)) == [.codex, .claude],
              deferred.inspection(for: .claude).report?.sessionRead == .complete else {
            fatalError("Related discovery was dropped while scanning or failed to find an additional tool")
        }
        print("PASS: a related-tab request during scanning discovers missing tools after project files complete")

        let cancelPreferences = UserDefaults(suiteName: preferenceName + "-cancel")!
        defer { cancelPreferences.removePersistentDomain(forName: preferenceName + "-cancel") }
        let cancelled = SweepState(store: RecordStore(directory: sandbox.appendingPathComponent("cancel-logs")),
                                   restorePreferences: false, preferences: cancelPreferences, defaultToolRoots: roots)
        cancelled.discoverDefaultTools()
        cancelled.cancelScan()
        try await Task.sleep(for: .milliseconds(100))
        guard cancelled.configurations.isEmpty, !cancelled.busy,
              cancelPreferences.data(forKey: "grant.codex") == nil else { fatalError("Cancelled discovery saved a late connection") }
        print("PASS: cancelling discovery rejects late results and leaves access bookmarks untouched")

        cancelled.page = .tools
        try await finish(cancelled)
        cancelled.acceptTool(claude, for: .claude)
        try await finish(cancelled)
        guard cancelled.inspection(for: .claude).report != nil else { fatalError("Custom tool connection did not start inspection") }
        print("PASS: choosing a custom tool folder starts its scan without a second button press")
    }

    @MainActor private static func finish(_ state: SweepState) async throws {
        for _ in 0..<2_000 where state.busy { try await Task.sleep(for: .milliseconds(10)) }
        guard !state.busy, state.error == nil else { fatalError("Tool workflow did not finish: \(state.error ?? "timeout")") }
    }
}
