import AppKit
import CleanupCore
import SwiftUI

@MainActor
final class SweepState: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case project = "项目库", tools = "工具数据", skills = "技能管理", records = "清理记录", settings = "设置"
        var id: String { rawValue }
        var icon: String { switch self { case .project: "folder"; case .tools: "square.stack.3d.up"; case .skills: "puzzlepiece.extension"; case .records: "clock.arrow.circlepath"; case .settings: "slider.horizontal.3" } }
    }
    enum ProjectTab: String, CaseIterable, Identifiable {
        case files = "项目文件", related = "关联记录"
        var id: String { rawValue }
    }
    @Published var page: Page? = .project {
        didSet {
            guard page != oldValue else { return }
            invalidate(); items = []; warnings = []
            skills.cancel()
            if page == .project, isProjectOpen { scanProject() }
            if page == .tools { resetToolInspections() }
        }
    }
    @Published var libraryRoot: URL?
    @Published var catalog: ProjectCatalogResult?
    @Published var librarySearch = ""
    @Published var librarySelection: String?
    @Published var libraryNewestFirst = false
    @Published var libraryListMode = false { didSet { preferences.set(libraryListMode, forKey: "libraryListMode") } }
    @Published var scanSummaries: [String: ProjectScanSummary] = [:]
    @Published var browserFilters: [BrowserScope: BrowserFilters] = [:]
    @Published var projectTreeExpansion = ProjectTreeExpansion()
    private var prefersProjectTree = true
    @Published var inspectedID: String?
    @Published var inspectorURL: URL?
    @Published var inspectorMessage: String?
    @Published var inspectorVisible = false
    @Published var toolInspections: [ToolKind: ToolInspection] = [:]
    private var inspectorTask: Task<Void, Never>?
    private var inspectorGeneration = UUID()
    private let preferences: UserDefaults
    @Published var isProjectOpen = false
    @Published var projectTab: ProjectTab = .files { didSet { if oldValue != projectTab { closeInspector() } } }
    @Published var filesScanned = false
    @Published private(set) var projectScanProgress: ScanProgress?
    @Published private(set) var projectScanStartedAt: Date?
    @Published var relatedToolsScanned = 0
    @Published var root: URL? {
        didSet { if root?.path != oldValue?.path { projectTreeExpansion.reset(rootPath: root?.path) } }
    }
    @Published var mode: ProjectMode = .organize { didSet { if oldValue != mode, isProjectOpen { scanProject() } } }
    @Published var items: [CleanupItem] = [] {
        didSet { projectOverview = ProjectOverview(items: items); projectTreeExpansion.reconcile(items: items) }
    }
    @Published private(set) var projectOverview = ProjectOverview(items: [])
    @Published var selected: Set<String> = []
    @Published var warnings: [String] = []
    @Published var busy = false
    @Published var executing = false
    @Published var status = "所有操作仅在这台 Mac 上进行"
    @Published var error: String?
    @Published var review: CleanupPlan?
    @Published var records: [CleanupRecord] = []
    @Published var recordWarning: String?
    @Published var previewURL: URL?
    private var currentOutcomes: [UUID: CleanupRecord] = [:]
    private var previewTask: Task<Void, Never>?
    @Published var configurations: [ToolConfiguration] = []
    @Published var keepPaths: Set<String> = []
    @Published var codexExecutable = "" { didSet { preferences.set(codexExecutable, forKey: "codexExecutable") } }
    private let grants: FolderGrants
    private let store: RecordStore
    let skills: SkillManagementState
    private var scanTask: Task<Void, Never>?
    private var generation = UUID()

    init(store: RecordStore = RecordStore(), restorePreferences: Bool = true, preferences: UserDefaults = .standard) {
        self.store = store
        self.skills = SkillManagementState(preferences: preferences, restorePreferences: restorePreferences)
        self.preferences = preferences
        self.libraryListMode = preferences.bool(forKey: "libraryListMode")
        self.prefersProjectTree = preferences.object(forKey: "projectFileTree") as? Bool ?? true
        self.grants = FolderGrants(defaults: preferences)
        guard restorePreferences else {
            Task { await loadRecords() }
            return
        }
        keepPaths = Set(preferences.stringArray(forKey: "keepPaths") ?? [])
        codexExecutable = preferences.string(forKey: "codexExecutable") ?? ""
        do { libraryRoot = try grants.resolve("library") } catch { warnings.append("项目库授权不可用，请重新选择总目录。") }
        do { root = try grants.resolve("project") } catch { warnings.append("项目授权不可用，请重新选择：\(error.localizedDescription)") }
        for tool in ToolKind.allCases {
            do {
                if let root = try grants.resolve(tool.rawValue) {
                    configurations.append(ToolConfiguration(tool: tool, root: root))
                }
            } catch { warnings.append("\(tool.title) 授权不可用，请重新选择文件夹。") }
        }
        Task {
            await loadRecords()
            if libraryRoot != nil, !isProjectOpen { loadLibrary() }
        }
    }

    func chooseLibrary() {
        guard !executing, let url = pickFolder(message: "选择存放多个项目的总目录，例如 Claude 文件夹", initial: libraryRoot) else { return }
        acceptLibrary(url)
    }
    func acceptLibrary(_ url: URL) {
        guard !executing else { return }
        do {
            libraryRoot = try grants.grant(url, key: "library")
            librarySearch = ""; librarySelection = nil
            isProjectOpen = false; root = nil; catalog = nil; page = .project
            loadLibrary()
        } catch { self.error = error.localizedDescription }
    }
    func loadLibrary() {
        guard let libraryRoot, !executing else { return }
        invalidate(); items = []; warnings = []; busy = true; status = "正在列出项目文件夹…"
        let token = generation
        scanTask = Task {
            do {
                let result = try await ProjectCatalog().list(libraryRoot)
                guard !Task.isCancelled, token == generation else { return }
                guard result.rootPath == libraryRoot.path else { throw CleanupError.unsafe("项目库授权已变化，请重新选择。") }
                catalog = result; busy = false
                status = "找到 \(result.projects.count) 个项目文件夹 · 选中一个项目后开始深入整理"
            } catch {
                guard token == generation else { return }
                busy = false
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func openProject(_ project: ProjectDirectory) {
        guard !busy, !executing, let catalog, catalog.rootPath == libraryRoot?.path else { return }
        do { acceptProject(try ProjectCatalog.validateOpening(project, from: catalog)) }
        catch { self.error = error.localizedDescription }
    }
    func backToLibrary() {
        guard !executing else { return }
        isProjectOpen = false; root = nil; invalidate(); items = []; warnings = []
        filesScanned = false; relatedToolsScanned = 0
        if libraryRoot != nil { loadLibrary() }
    }
    func forgetLibrary() {
        guard !executing else { return }
        invalidate(); grants.revoke("library")
        librarySearch = ""; librarySelection = nil; scanSummaries = [:]
        libraryRoot = nil; catalog = nil; root = nil; isProjectOpen = false
        items = []; warnings = []; status = "已移除项目库入口，原文件保持不变"
    }
    func chooseProject() {
        if let url = pickFolder(message: "选择你要整理的项目文件夹") { acceptProject(url) }
    }
    func acceptProject(_ url: URL) {
        guard !executing else { return }
        do {
            let granted = try grants.grant(url, key: "project")
            isProjectOpen = false; mode = .organize; page = .project
            root = granted; projectTab = .files; isProjectOpen = true; scanProject()
        }
        catch { self.error = "无法授权文件夹：\(error.localizedDescription)" }
    }
    func chooseTool(_ tool: ToolKind) {
        guard let url = pickFolder(message: "独立授权 \(tool.title) 的本地数据根目录（可选自定义位置）", initial: tool.defaultRoot) else { return }
        do {
            let root = try grants.grant(url, key: tool.rawValue)
            configurations.removeAll { $0.tool == tool }
            configurations.append(ToolConfiguration(tool: tool, root: root))
            invalidate(); resetToolInspections(); items = []
            if page == .project, isProjectOpen { scanProject() }
        } catch { self.error = error.localizedDescription }
    }
    func disconnectTool(_ tool: ToolKind) {
        guard !executing else { return }
        invalidate(); grants.revoke(tool.rawValue)
        configurations.removeAll { $0.tool == tool }; toolInspections.removeValue(forKey: tool); items = []; warnings = []
        if page == .project, isProjectOpen { scanProject() }
        else { resetToolInspections(); status = "已断开 \(tool.title)，原记录保持不变" }
    }
    private func pickFolder(message: String, initial: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.message = AppText.string(message)
        panel.directoryURL = initial; panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }
    func invalidate() {
        scanTask?.cancel(); scanTask = nil; generation = UUID(); busy = false
        projectScanProgress = nil; projectScanStartedAt = nil
        selected = []; review = nil
        browserFilters = [:]; closeInspector()
        projectTreeExpansion.filteredCollapsedPaths = []
        for tool in toolInspections.keys where toolInspections[tool]?.phase == .scanning || toolInspections[tool]?.phase == .pending {
            toolInspections[tool] = ToolInspection(phase: .cancelled)
        }
        previewTask?.cancel(); previewTask = nil; previewURL = nil
    }
    func cancelScan() { invalidate(); status = "扫描已取消" }
    func scanProject() {
        guard let root, isProjectOpen, !executing else { return }
        invalidate(); items = []; warnings = []; busy = true; status = "正在检查项目…"
        filesScanned = false; relatedToolsScanned = 0
        projectScanStartedAt = Date()
        projectScanProgress = ScanProgress(count: 0, path: root.path, phase: .protection)
        let token = generation
        let request = ScanRequest(root: root, mode: mode, protectedPaths: keepPaths)
        let configs = currentConfigurations
        toolInspections = Dictionary(uniqueKeysWithValues: configs.map { ($0.tool, ToolInspection(phase: .pending)) })
        scanTask = Task {
            do {
                let result = try await ProjectScanner().scan(request) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.projectScanActive else { return }
                        self.projectScanProgress = progress
                        self.status = "\(self.projectScanStageTitle) · 已检查 \(progress.count) 项 · \(URL(fileURLWithPath: progress.path).lastPathComponent)"
                    }
                }
                guard !Task.isCancelled, token == generation else { return }
                guard result.rootPath == root.path, result.items.allSatisfy({ $0.rootPath == root.path }) else {
                    throw CleanupError.unsafe("扫描结果与当前授权目录不一致，请重新选择项目。")
                }
                items = result.items; warnings = result.warnings; filesScanned = true
                let overview = projectOverview
                if mode == .organize, overview.isComplete, let snapshot = result.items.first(where: { $0.path == root.path })?.snapshot {
                    scanSummaries[root.path] = ProjectScanSummary(bytes: overview.totalBytes,
                        cacheBytes: overview.summary(for: .recommended).bytes, scannedAt: result.scannedAt, snapshot: snapshot)
                }
                var inventory: [CleanupItem] = []
                for config in configs {
                    guard !Task.isCancelled, token == generation else { return }
                    toolInspections[config.tool] = ToolInspection(phase: .scanning)
                    status = "正在查找此项目的 \(config.tool.title) 关联记录…"
                    do {
                        let toolResult = try await ToolDataService().scan(config)
                        guard !Task.isCancelled, token == generation else { return }
                        guard toolResult.rootPath == config.root.path,
                              toolResult.items.allSatisfy({ $0.rootPath == config.root.path && $0.tool == config.tool }) else {
                            throw CleanupError.unsafe("工具扫描结果与授权目录不一致。")
                        }
                        toolInspections[config.tool] = .finished(toolResult)
                        inventory += toolResult.items; warnings += toolResult.warnings
                        relatedToolsScanned += 1
                    } catch {
                        guard !Task.isCancelled, token == generation else { return }
                        toolInspections[config.tool] = ToolInspection(phase: .failed, message: error.localizedDescription)
                        warnings.append("\(config.tool.title)：\(error.localizedDescription)")
                    }
                }
                guard !Task.isCancelled, token == generation else { return }
                let related = ProjectAssociations.items(for: root, from: inventory)
                if !related.isEmpty { items += related }
                busy = false
                status = "已检查当前项目 \(result.items.count) 项 · \(associationSummary)"
            } catch {
                guard token == generation else { return }
                busy = false; if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    func scanTools() {
        guard !executing else { return }
        invalidate(); items = []; warnings = []; busy = true; status = "正在检查已授权的工具…"
        let token = generation
        let configs = currentConfigurations
        toolInspections = Dictionary(uniqueKeysWithValues: configs.map { ($0.tool, ToolInspection(phase: .pending)) })
        scanTask = Task {
            for config in configs {
                toolInspections[config.tool] = ToolInspection(phase: .scanning)
                do {
                    let result = try await ToolDataService().scan(config) { [weak self] progress in
                        Task { @MainActor in
                            guard let self, self.generation == token, self.busy else { return }
                            self.status = "\(config.tool.title) · 已检查 \(progress.count) 项"
                        }
                    }
                    guard !Task.isCancelled, token == generation else { return }
                    guard result.rootPath == config.root.path,
                          result.items.allSatisfy({ $0.rootPath == config.root.path && $0.tool == config.tool }) else {
                        throw CleanupError.unsafe("工具扫描结果与当前授权目录不一致，请重新授权。")
                    }
                    toolInspections[config.tool] = .finished(result)
                    items += result.items; warnings += result.warnings
                } catch {
                    guard !Task.isCancelled, token == generation else { return }
                    toolInspections[config.tool] = ToolInspection(phase: .failed, message: error.localizedDescription)
                    warnings.append("\(config.tool.title)：\(error.localizedDescription)")
                }
            }
            guard token == generation else { return }
            busy = false; status = "已检查 \(items.count) 项 · 请明确选择需要清理的内容"
        }
    }
    var claudeRecoveryAvailable: Bool {
        toolInspections[.claude]?.report?.requiresRecovery == true
            && configurations.contains { $0.tool == .claude }
    }
    func recoverClaudeTransaction() {
        guard !busy, !executing,
              let configuration = currentConfigurations.first(where: { $0.tool == .claude }) else { return }
        invalidate(); items = []; executing = true
        status = "正在恢复未完成的 Claude 事务…"
        Task {
            do {
                try await ToolDataService().recoverInterruptedClaudeTransaction(configuration: configuration)
                executing = false
                scanTools()
            } catch {
                executing = false
                status = "事务恢复未完成"
                self.error = error.localizedDescription
            }
        }
    }
    var currentConfigurations: [ToolConfiguration] {
        configurations.map { value in
            var value = value
            if value.tool == .codex { value.executablePath = codexExecutable.isEmpty ? nil : codexExecutable }
            return value
        }
    }
    func preview(_ item: CleanupItem) {
        guard !busy, !executing, items.contains(where: { $0.id == item.id }) else { return }
        let authorizedRoot = item.tool.flatMap { tool in configurations.first { $0.tool == tool }?.root } ?? (item.tool == nil ? root : nil)
        guard let authorizedRoot else { error = "文件夹授权不可用，请重新选择。"; return }
        previewTask?.cancel(); previewURL = nil
        let token = generation
        previewTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try PreviewSafety.validate(item, authorizedRoot: authorizedRoot)
                }
                let url = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, generation == token else { return }
                previewURL = url
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                self.error = error.localizedDescription
            }
        }
    }
    func toggle(_ item: CleanupItem) {
        guard item.isSelectable, !busy, !executing else { return }
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }
    func toggleGroup(_ group: [CleanupItem]) {
        let ids = Set(group.filter(\.isSelectable).map(\.id))
        if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
    }
    func keep(_ item: CleanupItem) {
        if keepPaths.contains(item.path) { keepPaths.remove(item.path) } else { keepPaths.insert(item.path) }
        preferences.set(Array(keepPaths), forKey: "keepPaths")
        if page == .project { scanProject() }
    }
    func prepareReview() {
        do { review = try SelectionPlanner.makePlan(items: items, selectedIDs: selected) }
        catch { self.error = error.localizedDescription }
    }
    func execute(_ plan: CleanupPlan) {
        invalidate(); executing = true; status = "正在执行已确认的清理…"
        let configs = currentConfigurations
        Task {
            let result = await CleanupExecutor(store: store).execute(plan, configurations: configs)
            executing = false; selected = []; items = []
            for outcome in result { currentOutcomes[outcome.id] = outcome }
            await loadRecords()
            page = .records
            status = "处理完成：\(result.filter { $0.status == .succeeded }.count) 项成功，共 \(result.count) 项"
        }
    }
    func loadRecords() async {
        do {
            let persisted = try await store.load()
            let index = Dictionary(persisted.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
            let unsaved = currentOutcomes.values.contains { outcome in
                guard let saved = index[outcome.id] else { return true }
                return saved.status != outcome.status || saved.message != outcome.message || saved.trashPath != outcome.trashPath
            }
            recordWarning = unsaved ? "部分操作结果未能完整保存到磁盘。下方保留了本次运行的真实结果；退出应用后这些未保存结果可能丢失。" : nil
            records = index.merging(currentOutcomes, uniquingKeysWith: { _, latest in latest }).values.sorted { $0.date > $1.date }
        } catch {
            let existing = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
            records = existing.merging(currentOutcomes, uniquingKeysWith: { _, latest in latest }).values.sorted { $0.date > $1.date }
            recordWarning = "无法读取磁盘上的清理记录：\(error.localizedDescription)。本次运行的结果仍显示在下方。"
        }
    }
    func executeSkills(_ plan: SkillRemovalPlan) {
        guard !executing else { return }
        invalidate(); executing = true; status = "正在移除已确认的技能…"
        let sources = skills.roots
        skills.cancel()
        Task {
            let results = await SkillCleanupExecutor(store: store).execute(plan, authorizedRoots: sources)
            for result in results { currentOutcomes[result.id] = result }
            skills.didExecute(); executing = false
            await loadRecords(); page = .records
            status = "技能处理完成：\(results.filter { $0.status == .succeeded }.count) 项成功，共 \(results.count) 项"
        }
    }
    func restore(_ record: CleanupRecord) {
        executing = true
        Task {
            do {
                let restored = try await CleanupExecutor(store: store).restore(record)
                currentOutcomes[restored.id] = restored
                await loadRecords(); status = "已恢复到原位置"
            }
            catch { self.error = error.localizedDescription }
            executing = false
        }
    }
    static func size(_ bytes: Int64) -> String {
        guard AppText.usesEnglish else { return bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        if bytes == 0 { return "0 KB" }
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 { value /= 1000; unit += 1 }
        if unit == 0 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        let precision = value >= 10 ? 0 : 1
        return String(format: "%.*f %@", locale: Locale(identifier: "en"), precision, value, units[unit])
    }
}

extension SweepState {
    var projectScanActive: Bool { page == .project && isProjectOpen && busy && !filesScanned }
    var projectScanStageTitle: String {
        switch projectScanProgress?.phase ?? .protection {
        case .protection: "正在核对保护规则"
        case .files: "正在读取文件属性"
        case .verification: "正在校验目录内容"
        }
    }
    func filters(for scope: BrowserScope) -> BrowserFilters {
        if let saved = browserFilters[scope] { return saved }
        var defaults = BrowserFilters()
        defaults.tree = scope == .projectFiles && prefersProjectTree
        return defaults
    }
    func setFilters(_ filters: BrowserFilters, for scope: BrowserScope) {
        if scope == .projectFiles {
            if !filters.sameQuery(as: self.filters(for: scope)) { projectTreeExpansion.filteredCollapsedPaths = [] }
            if filters.tree != prefersProjectTree {
                prefersProjectTree = filters.tree
                preferences.set(filters.tree, forKey: "projectFileTree")
            }
        }
        browserFilters[scope] = filters
    }
    func toggleProjectExpansion(_ row: ProjectTreeRow) {
        guard !busy, !executing else { return }
        projectTreeExpansion.toggle(row, filtering: filters(for: .projectFiles).hasQuery)
    }
    func toggleProjectSelection(_ row: ProjectTreeRow) {
        guard row.showsCheckbox(mode: mode), items.contains(where: { $0.id == row.id }) else { return }
        toggle(row.item)
    }
    func scopedItems(_ scope: BrowserScope) -> [CleanupItem] {
        items.filter { scope == .all || (scope == .projectFiles ? $0.tool == nil : $0.tool != nil) }
    }
    func visibleItems(_ scope: BrowserScope) -> [CleanupItem] {
        let filter = filters(for: scope)
        let source = scope == .projectFiles && mode == .organize && !filter.tree && !filter.onlySelected
            ? projectOverview.units : scopedItems(scope)
        return filter.apply(to: source, selected: selected)
    }
    func inspection(for tool: ToolKind) -> ToolInspection {
        toolInspections[tool] ?? ToolInspection(phase: configurations.contains { $0.tool == tool } ? .pending : .disconnected)
    }
    private func resetToolInspections() {
        toolInspections = Dictionary(uniqueKeysWithValues: configurations.map { ($0.tool, ToolInspection(phase: .pending)) })
    }
    var matchedSessionCount: Int { items.filter { $0.action == .deleteSession && $0.sessionID != nil }.count }
    var associationComplete: Bool { !configurations.isEmpty && configurations.allSatisfy { inspection(for: $0.tool).checkedAllSessions } }
    var associationSummary: String {
        guard !configurations.isEmpty else { return "关联记录尚未检查" }
        let count = matchedSessionCount
        if associationComplete { return count == 0 ? "未找到关联会话" : "\(count) 条关联会话" }
        if configurations.contains(where: { inspection(for: $0.tool).phase == .scanning }) {
            return count > 0 ? "已找到 \(count) 条 · 仍在检查" : "正在检查关联记录"
        }
        return count > 0 ? "已找到 \(count) 条 · 检查未完整完成" : "关联记录检查未完成"
    }
    var associationEmptyTitle: String {
        configurations.isEmpty ? "连接工具后检查关联记录" : associationComplete ? "未找到关联会话" : "关联记录检查未完成"
    }
    var associationEmptyMessage: String {
        configurations.isEmpty ? "选择工具的本地记录目录，才能检查这个项目的历史。" : associationComplete
            ? "在已连接工具中，没有找到明确属于这个项目的会话。"
            : "请查看上方各工具状态；未完成检查不代表没有历史记录。"
    }
    func summary(for project: ProjectDirectory) -> ProjectScanSummary? {
        guard let summary = scanSummaries[project.path], summary.snapshot.device == project.snapshot.device,
              summary.snapshot.inode == project.snapshot.inode else { return nil }
        return summary
    }
    var inspectedItem: CleanupItem? { items.first { $0.id == inspectedID } }
    func closeInspector() {
        inspectorTask?.cancel(); inspectorTask = nil; inspectorGeneration = UUID()
        inspectedID = nil; inspectorURL = nil; inspectorMessage = nil; inspectorVisible = false
    }
    func inspect(_ item: CleanupItem) {
        guard !executing, !busy, items.contains(where: { $0.id == item.id }) else { return }
        closeInspector(); inspectedID = item.id; inspectorVisible = true
        guard PreviewSafety.isEligible(item) else {
            inspectorMessage = item.action == .deleteSession ? "仅展示会话元数据与删除影响。" : item.isDirectory ? "文件夹可在完整文件树或 Finder 中查看。" : "此内容暂不可预览。"
            return
        }
        let authorizedRoot = item.tool.flatMap { tool in configurations.first { $0.tool == tool }?.root } ?? (item.tool == nil ? root : nil)
        guard let authorizedRoot else { inspectorMessage = "目录授权不可用，请重新选择。"; return }
        let token = inspectorGeneration
        inspectorTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) { try PreviewSafety.validate(item, authorizedRoot: authorizedRoot) }
                let url = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, inspectorGeneration == token, inspectedID == item.id else { return }
                inspectorURL = url
            } catch {
                guard !Task.isCancelled, inspectorGeneration == token else { return }
                inspectorMessage = error.localizedDescription
            }
        }
    }
}
