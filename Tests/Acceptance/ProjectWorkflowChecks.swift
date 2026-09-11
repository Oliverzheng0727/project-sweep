import CleanupCore
import Foundation

@main struct ProjectWorkflowChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("Sweep-workflow-\(UUID())").standardizedFileURL
        let library = sandbox.appendingPathComponent("Claude项目库")
        let tool = sandbox.appendingPathComponent("工具记录")
        let preferenceName = "sweep-workflow-test-\(UUID())"
        let preferences = UserDefaults(suiteName: preferenceName)!
        defer { preferences.removePersistentDomain(forName: preferenceName); try? fm.removeItem(at: sandbox) }
        func write(_ url: URL, _ text: String) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let a = library.appendingPathComponent("个人简历").standardizedFileURL
        let b = library.appendingPathComponent("分镜图").standardizedFileURL
        let aID = UUID().uuidString, bID = UUID().uuidString
        for (project, id) in [(a, aID), (b, bID)] {
            try write(project.appendingPathComponent("最终成果.txt"), "需要保留")
            try write(project.appendingPathComponent("__pycache__/fixture.pyc"), "cache")
            let row: [String: Any] = ["type": "user", "sessionId": id, "cwd": project.path, "message": ["role": "user", "content": "fixture"]]
            let data = try JSONSerialization.data(withJSONObject: row)
            try write(tool.appendingPathComponent("projects/\(id)/\(id).jsonl"), String(decoding: data, as: UTF8.self) + "\n")
            try write(tool.appendingPathComponent("projects/\(id)/memory/MEMORY.md"), "保留的记忆")
        }
        let state = SweepState(store: RecordStore(directory: sandbox.appendingPathComponent("logs")), restorePreferences: false, preferences: preferences)
        state.configurations = [ToolConfiguration(tool: .claude, root: tool)]
        func finish() async throws {
            for _ in 0..<1_000 {
                if !state.busy { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard !state.busy, state.error == nil else { throw CleanupError.io(state.error ?? "UI task timeout") }
        }
        state.acceptLibrary(library)
        try await finish()
        guard !state.isProjectOpen, state.items.isEmpty, state.catalog?.projects.count == 2 else { fatalError("Library eagerly scanned projects") }
        print("PASS: library lists two projects without opening or scanning either")
        state.openProject(state.catalog!.projects.first { $0.path == a.path }!)
        try await finish()
        guard state.root?.path == a.path, state.items.filter({ $0.action == .deleteSession }).map(\.sessionID) == [aID],
              state.items.filter({ $0.tool == nil }).allSatisfy({ PathSafety.isWithin($0.path, root: a.path) }) else { fatalError("Project scope leaked") }
        guard state.items.filter({ $0.category == .projectMemory }).count == 1,
              state.items.filter({ $0.category == .projectMemory }).allSatisfy({ !$0.isSelectable }) else { fatalError("Project memory not scoped/protected") }
        print("PASS: selected project contains only its files, own session and protected memory")
        state.selected = Set(state.items.filter { $0.risk == .recommended || $0.action == .deleteSession }.map(\.id))
        state.prepareReview()
        guard let plan = state.review, plan.items.count == 2, Set(plan.items.map(\.action)) == [.trash, .deleteSession] else { fatalError("Combined review is incomplete") }
        print("PASS: one checklist includes selected cache and linked session without execution")
        state.backToLibrary()
        try await finish()
        guard state.selected.isEmpty, state.review == nil, !state.isProjectOpen else { fatalError("Library retains stale project selection") }
        state.acceptProject(a)
        state.acceptProject(b)
        try await finish()
        guard state.root?.path == b.path, state.items.filter({ $0.action == .deleteSession }).map(\.sessionID) == [bID],
              state.items.filter({ $0.tool == nil }).allSatisfy({ PathSafety.isWithin($0.path, root: b.path) }) else { fatalError("Canceled scan polluted next project") }
        print("PASS: switching projects cancels old results and clears pending cleanup")
        state.mode = .remove
        try await finish()
        let offered = state.items.filter { $0.tool == nil && $0.isSelectable }
        guard offered.map(\.path) == [b.path] else { fatalError("Remove mode does not isolate the selected root") }
        guard fm.fileExists(atPath: a.path), fm.fileExists(atPath: b.path), fm.fileExists(atPath: tool.path) else { fatalError("Read-only workflow mutated fixtures") }
        print("PASS: remove mode offers only the chosen project; browsing leaves all data intact")
        state.backToLibrary()
        state.forgetLibrary()
        state.disconnectTool(.claude)
        guard state.libraryRoot == nil, state.configurations.isEmpty,
              preferences.data(forKey: "grant.library") == nil,
              fm.fileExists(atPath: a.path), fm.fileExists(atPath: tool.path) else { fatalError("Disconnect modified project data") }
        print("PASS: disconnecting the library and tool preserves files and removes saved access")
    }
}
