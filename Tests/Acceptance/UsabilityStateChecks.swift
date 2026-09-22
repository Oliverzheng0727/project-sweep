import CleanupCore
import Foundation

@main struct UsabilityStateChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Sweep-usability-state-\(UUID())").standardizedFileURL
        let name = "sweep-usability-state-\(UUID())"
        let preferences = UserDefaults(suiteName: name)!
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { preferences.removePersistentDomain(forName: name); try? fm.removeItem(at: root) }
        let cache = root.appendingPathComponent(".DS_Store")
        try Data("cache".utf8).write(to: cache)
        let source = root.appendingPathComponent("作品.md")
        try Data("keep".utf8).write(to: source)
        let scan = try await ProjectScanner().scan(ScanRequest(root: root))
        let state = SweepState(store: RecordStore(directory: root.appendingPathComponent("records")), restorePreferences: false, preferences: preferences, defaultToolRoots: [:])
        state.root = root; state.isProjectOpen = true; state.items = scan.items; state.filesScanned = true
        let cacheItem = state.items.first { $0.path == cache.path }!
        var session = CleanupItem(id: "fixture-session", path: "/fixture/session", rootPath: "/fixture", category: .session,
            reason: "fixture", tool: .claude, sessionID: UUID().uuidString, projectPath: root.path, action: .deleteSession)
        session.relatedIDs = []
        state.items.append(session)
        state.selected = [cacheItem.id, session.id]
        var filters = BrowserFilters(); filters.search = "作品"; filters.category = .source; filters.risk = .review
        state.setFilters(filters, for: .projectFiles)
        guard state.visibleItems(.projectFiles).map(\.path) == [source.path], state.selected == [cacheItem.id, session.id] else { fatalError("Filtering cleared selection") }
        filters.tree = true; filters.largestFirst = false
        state.setFilters(filters, for: .projectFiles); state.projectTab = .related; state.projectTab = .files
        for _ in 0..<1_000 where state.busy { try await Task.sleep(for: .milliseconds(10)) }
        guard state.filters(for: .projectFiles) == filters, state.selected.count == 2 else { fatalError("View switch lost state") }
        print("PASS: search, category, risk, ordering, tree and project tabs preserve selection")
        filters = BrowserFilters(); filters.onlySelected = true
        state.setFilters(filters, for: .projectFiles)
        guard state.visibleItems(.projectFiles).map(\.id) == [cacheItem.id] else { fatalError("Only-selected leaked scope") }
        print("PASS: only-selected is scoped while cross-tab selections stay intact")
        guard !state.associationComplete, state.associationEmptyTitle == "连接工具后检查关联记录" else { fatalError("Disconnected shown as zero") }
        state.configurations = [ToolConfiguration(tool: .claude, root: root)]
        state.toolInspections[.claude] = ToolInspection(phase: .pending)
        guard !state.associationComplete else { fatalError("Pending marked complete") }
        for read in [SessionReadState.partial, .failed, .unsupported] {
            state.toolInspections[.claude] = .finished(ScanResult(rootPath: root.path, items: [], toolStatus: ToolScanStatus(sessionRead: read)))
            guard !state.associationComplete, state.associationSummary.contains("未完整完成") else { fatalError("Incomplete result shown as complete") }
        }
        print("PASS: unconnected, pending, partial, failed and unsupported never claim complete empty history")
        state.toolInspections[.claude] = .finished(ScanResult(rootPath: root.path, items: [], toolStatus: ToolScanStatus(sessionRead: .complete, sessionDeletion: .unavailable)))
        guard state.associationComplete, state.associationSummary == "1 条关联会话" else { fatalError("Read-only capability confused with read failure") }
        state.items = scan.items
        guard state.associationSummary == "未找到关联会话" else { fatalError("Complete empty history not represented") }
        let cacheFailure = ToolInspection.finished(ScanResult(rootPath: root.path, items: [], toolStatus: ToolScanStatus(filesIncomplete: true)))
        guard cacheFailure.phase == .partial, cacheFailure.checkedAllSessions else { fatalError("File scan failure confused with session reading") }
        print("PASS: complete empty reading is distinct from deletion capability")
        state.inspect(cacheItem)
        for _ in 0..<100 where state.inspectorURL == nil && state.inspectorMessage == nil { try await Task.sleep(for: .milliseconds(10)) }
        guard state.inspectorURL?.path == cache.path, state.inspectedID == cacheItem.id else { fatalError("Safe inspector did not load") }
        guard state.selected.count == 2 else { fatalError("Inspection changed cleanup selection") }
        state.closeInspector()
        guard state.inspectorURL == nil, state.inspectedID == nil else { fatalError("Preview not released") }
        print("PASS: local inspector validates file without changing cleanup selection and releases preview")
        state.toolInspections[.claude] = ToolInspection(phase: .scanning)
        state.cancelScan()
        guard state.selected.isEmpty, state.review == nil, state.toolInspections[.claude]?.phase == .cancelled,
              !state.associationComplete else { fatalError("Cancellation retains stale cleanup or zero result") }
        state.toolInspections[.claude] = .finished(ScanResult(rootPath: root.path, items: [], toolStatus: ToolScanStatus()))
        state.page = .tools
        guard state.inspection(for: .claude).phase == .pending, !state.associationComplete else { fatalError("Entering tool page reused completion after clearing results") }
        print("PASS: cancellation and tool-page entry invalidate stale plans and inspection results")
        state.page = .project
        state.configurations = []
        state.scanProject()
        guard state.projectScanActive, state.projectScanProgress?.count == 0,
              state.projectScanStartedAt != nil, state.items.isEmpty, state.selected.isEmpty else {
            fatalError("Starting a project scan must immediately show fresh progress without old cleanup items")
        }
        state.cancelScan()
        try await Task.sleep(for: .milliseconds(50))
        guard !state.projectScanActive, state.projectScanProgress == nil, state.projectScanStartedAt == nil,
              state.items.isEmpty else { fatalError("Cancellation retained progress or accepted a late callback") }
        print("PASS: scan starts with visible progress and cancellation rejects stale updates")
        state.scanProject()
        for _ in 0..<1_000 where state.busy { try await Task.sleep(for: .milliseconds(10)) }
        guard state.filesScanned, !state.projectScanActive, !state.busy, state.error == nil,
              state.items.contains(where: { $0.path == source.path }) else { fatalError("Completion did not replace progress with complete inventory") }
        state.backToLibrary()
        guard state.projectScanProgress == nil, state.projectScanStartedAt == nil else { fatalError("Leaving the project kept stale progress") }
        print("PASS: complete inventory replaces progress and project exit clears the scan state")
    }
}
