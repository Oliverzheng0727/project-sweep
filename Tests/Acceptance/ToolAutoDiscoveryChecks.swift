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
        try fm.createSymbolicLink(at: cursorLink, withDestinationURL: codex)

        let state = SweepState(store: RecordStore(directory: sandbox.appendingPathComponent("logs")),
                               restorePreferences: false, preferences: preferences)
        let roots: [ToolKind: URL] = [.codex: codex, .claude: claude, .cursor: cursorLink]
        let found = state.discoverDefaultTools(at: roots, scanAfterDiscovery: false)
        guard found == 2, Set(state.configurations.map(\.tool)) == [.codex, .claude],
              preferences.data(forKey: "grant.codex") != nil,
              preferences.data(forKey: "grant.claude") != nil else {
            fatalError("Default tool folders were not connected automatically")
        }

        state.disconnectTool(.claude)
        let rediscovered = state.discoverDefaultTools(at: roots, scanAfterDiscovery: false)
        guard rediscovered == 0, state.configurations.map(\.tool) == [.codex],
              preferences.data(forKey: "grant.claude") == nil else {
            fatalError("An explicitly disconnected tool was automatically reconnected")
        }
        guard fm.fileExists(atPath: codex.path), fm.fileExists(atPath: claude.path),
              fm.fileExists(atPath: cursorLink.path) else { fatalError("Discovery modified tool data") }
        print("PASS: known tool folders connect automatically; symlinks and explicit disconnects remain untouched")
    }
}
