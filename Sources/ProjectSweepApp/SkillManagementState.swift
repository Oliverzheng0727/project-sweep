import AppKit
import CleanupCore
import SwiftUI

@MainActor
final class SkillManagementState: ObservableObject {
    @Published var tool: ToolKind = .claude { didSet { if tool != oldValue { selected = []; inspectedID = nil; review = nil } } }
    @Published private(set) var roots: [SkillRoot] = []
    @Published private(set) var entries: [SkillEntry] = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanned = false
    @Published private(set) var status = "进入此页后自动检索本机技能。"
    @Published var search = ""
    @Published var onlySelected = false
    @Published var selected: Set<String> = []
    @Published var inspectedID: String?
    @Published var error: String?
    @Published var review: SkillRemovalPlan?
    private let preferences: UserDefaults
    private let grants: FolderGrants
    private let discovery: SkillDiscovery?
    private var connectedRoots: [SkillRoot] = []
    private var unavailableRoots: [SkillRoot] = []
    private var authorizationWarnings: [String] {
        unavailableRoots.map { "\($0.tool.title) · \($0.url.path)：自定义目录授权失效，请通过“添加自定义目录”重新选择。" }
    }
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(preferences: UserDefaults = .standard, restorePreferences: Bool = true, discovery: SkillDiscovery? = SkillDiscovery()) {
        self.preferences = preferences; grants = FolderGrants(defaults: preferences)
        self.discovery = discovery
        guard restorePreferences, let data = preferences.data(forKey: "skillSources"),
              let saved = try? JSONDecoder().decode([SkillRoot].self, from: data) else { return }
        for var root in saved {
            do {
                guard let url = try grants.resolve("skill-" + root.id) else { throw CleanupError.unavailable("缺少目录授权。") }
                root.url = url; try SkillCatalog.validateRoot(root); connectedRoots.append(root)
            } catch { unavailableRoots.append(root) }
        }
        roots = connectedRoots
        warnings = authorizationWarnings
    }

    var toolRoots: [SkillRoot] { roots.filter { $0.tool == tool } }
    func isAutomatic(_ root: SkillRoot) -> Bool { !connectedRoots.contains(where: { $0.id == root.id }) }
    func activate() { if !scanning { scan() } }
    func countLabel(for tool: ToolKind) -> String {
        if scanning { return "扫描中" }
        if !scanned { return "待检索" }
        if !roots.contains(where: { $0.tool == tool }) { return warnings.isEmpty ? "未发现" : "检查未完成" }
        return "\(entries.filter { $0.root.tool == tool }.count) 项"
    }
    var visible: [SkillEntry] {
        entries.filter {
            $0.root.tool == tool && (!onlySelected || selected.contains($0.id))
                && (search.isEmpty || [$0.name, $0.summary, $0.url.path, $0.source].joined(separator: " ").localizedCaseInsensitiveContains(search))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var inspected: SkillEntry? { entries.first { $0.id == inspectedID } }
    var hiddenSelectionCount: Int { selected.subtracting(visible.map(\.id)).count }
    var selectedBytes: Int64 { entries.filter { selected.contains($0.id) }.reduce(0) { $0 + ($1.bytes ?? 0) } }

    func choose(_ location: SkillLocation) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let initial = location == .shared ? home.appendingPathComponent(".agents/skills")
            : tool.defaultRoot.appendingPathComponent(location == .plugins ? "plugins" : "skills")
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true; panel.directoryURL = initial
        panel.message = location == .plugins
            ? AppText.format("连接 %@ 的插件目录，仅查看技能来源。", tool.title)
            : AppText.format("连接 %@ 的%@：请选择包含各技能文件夹的 skills 目录。", tool.title, AppText.string(location.title))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        connect(url, tool: tool, location: location)
    }

    func connect(_ url: URL, tool: ToolKind, location: SkillLocation) {
        let candidate = SkillRoot(tool: tool, url: url.standardizedFileURL, location: location)
        do {
            // Reject aliases and wrong-AI paths before FolderGrants canonicalizes them.
            try SkillCatalog.validateRoot(candidate)
            guard !connectedRoots.contains(where: { $0.tool == tool && $0.url.path == candidate.url.path }) else {
                error = "此来源已经连接。"; return
            }
            var granted = candidate
            granted.url = try grants.grant(candidate.url, key: "skill-" + candidate.id)
            for old in unavailableRoots where old.tool == tool && old.url.path == candidate.url.path { grants.revoke("skill-" + old.id) }
            unavailableRoots.removeAll { $0.tool == tool && $0.url.path == candidate.url.path }
            connectedRoots.append(granted); saveSources(); scan()
        } catch { self.error = error.localizedDescription }
    }

    func disconnect(_ root: SkillRoot) {
        guard !isAutomatic(root) else { return }
        cancel(); connectedRoots.removeAll { $0.id == root.id }; roots.removeAll { $0.id == root.id }; grants.revoke("skill-" + root.id)
        entries = []; saveSources()
        if connectedRoots.isEmpty && discovery == nil { status = "已断开来源，原技能保持不变。" } else { scan() }
    }

    func scan() {
        cancel(); entries = []; warnings = []; scanned = false
        scanning = true; status = "正在自动检索 Claude Code 和 Codex 的技能目录…"
        let token = generation; let manual = connectedRoots; let discovery = discovery
        let authorizationWarnings = authorizationWarnings
        task = Task {
            do {
                let found = try await discovery?.discover()
                guard !Task.isCancelled, token == generation else { return }
                // A saved custom authorization wins over the same automatically found path.
                roots = manual + (found?.roots ?? []).filter { candidate in
                    !manual.contains {
                        $0.tool == candidate.tool && ($0.url.path == candidate.url.path
                            || ($0.location == .plugins && candidate.location == .plugins
                                && PathSafety.isWithin(candidate.url.path, root: $0.url.path)))
                    }
                }
                status = "正在读取技能名称、来源和共享引用…"
                let result = try await SkillCatalog().scan(roots, priorWarnings: authorizationWarnings + (found?.warnings ?? []))
                guard !Task.isCancelled, token == generation else { return }
                entries = result.entries; warnings = result.warnings; scanning = false; scanned = true
                status = roots.isEmpty && result.complete ? "未在默认位置发现技能，可添加自定义目录。"
                    : "已找到 \(entries.count) 项 · \(result.complete ? "技能来源检查完成" : "检查未完整完成")"
            } catch {
                guard token == generation else { return }
                scanning = false; self.error = error.localizedDescription; status = "技能扫描未完成"
            }
        }
    }
    func cancel() {
        task?.cancel(); task = nil; generation = UUID()
        if scanning { status = "技能扫描已取消" }
        scanning = false; selected = []; review = nil; inspectedID = nil
    }
    func toggle(_ entry: SkillEntry) {
        guard !scanning, entry.selectable, entry.root.tool == tool, entries.contains(where: { $0.id == entry.id }) else { return }
        if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
    }
    func prepareReview() {
        do { review = try SkillRemovalPlan.make(entries: entries, selected: selected, roots: roots) }
        catch { self.error = error.localizedDescription }
    }
    func selectVisible() {
        guard !scanning else { return }
        selected.formUnion(visible.filter(\.selectable).map(\.id))
    }
    func didExecute() { cancel(); entries = []; scanned = false; status = "移除已处理，再次扫描可更新技能列表。" }
    private func saveSources() { preferences.set(try? JSONEncoder().encode(connectedRoots + unavailableRoots), forKey: "skillSources") }
}
