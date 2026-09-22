import AppKit
import CleanupCore
import SwiftUI
import QuickLook

struct ItemBrowser: View {
    @ObservedObject var state: SweepState
    let toolMode: Bool
    var scope: BrowserScope = .all
    @FocusState private var listFocused: Bool
    private var filters: BrowserFilters { state.filters(for: scope) }
    private var scopedItems: [CleanupItem] { state.scopedItems(scope) }
    private var filtered: [CleanupItem] { state.visibleItems(scope) }
    private func binding<T>(_ keyPath: WritableKeyPath<BrowserFilters, T>) -> Binding<T> {
        Binding(get: { state.filters(for: scope)[keyPath: keyPath] }, set: { value in
            var copy = state.filters(for: scope); copy[keyPath: keyPath] = value; state.setFilters(copy, for: scope)
        })
    }
    var body: some View {
        let matches = filtered
        let tree = toolMode ? nil : ProjectTree(items: scopedItems, matching: matches, filters: filters, expansion: state.projectTreeExpansion)
        let displayed = filters.tree && !toolMode ? tree?.displayedIDs ?? [] : Set(matches.map(\.id))
        let hiddenSelected = state.selected.subtracting(displayed).count
        GeometryReader { geometry in
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("搜索名称或路径", text: binding(\.search)).textFieldStyle(.roundedBorder)
                Menu {
                    Picker("文件分类", selection: binding(\.category)) {
                        Text("全部分类").tag(Optional<CleanupCategory>.none)
                        ForEach(CleanupCategory.allCases) { Text(AppText.string($0.title)).tag(Optional($0)) }
                    }
                    Picker("判断状态", selection: binding(\.risk)) {
                        Text("全部状态").tag(Optional<CleanupRisk>.none)
                        ForEach([CleanupRisk.recommended, .review, .protected, .unavailable], id: \.self) { Text(AppText.string($0.title)).tag(Optional($0)) }
                    }
                } label: { Label(AppText.string(filters.category?.title ?? filters.risk?.title ?? "筛选"), systemImage: "line.3.horizontal.decrease") }
                    .fixedSize()
                if !toolMode {
                    Picker("文件展示方式", selection: binding(\.tree)) {
                        Text("文件树").tag(true)
                        Text("平铺列表").tag(false)
                    }.pickerStyle(.segmented).frame(width: 148).help("文件树显示父子层级；平铺列表将整个项目和内部内容分区展示")
                }
                Toggle("按大小", isOn: binding(\.largestFirst)).toggleStyle(.button)
                Toggle("仅看已选", isOn: binding(\.onlySelected)).toggleStyle(.button)
            }.fixedSize(horizontal: false, vertical: true)
            if !state.warnings.isEmpty {
                DisclosureGroup(AppText.format("%lld 条扫描提示", Int64(state.warnings.count))) {
                    ScrollView { VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(state.warnings.enumerated()), id: \.offset) { _, warning in Text(AppText.string(warning)).frame(maxWidth: .infinity, alignment: .leading) }
                    } }.frame(maxHeight: 90)
                }.font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 0) {
                itemList(tree)
                if state.inspectorVisible, let item = state.inspectedItem {
                    Divider().padding(.horizontal, 10)
                    FileInspectorView(state: state, item: item).frame(width: 290)
                }
            }.frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            VStack(spacing: 6) {
                HStack {
                    Text(AppText.format("已选 %lld 项", Int64(state.selected.count))).font(.callout.weight(.medium))
                    if hiddenSelected > 0 { Text(AppText.format("其中 %lld 项在当前列表外", Int64(hiddenSelected))).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if scope == .projectFiles {
                        Text(filters.hasQuery ? AppText.format("匹配 %lld 项 · 所在目录不计入匹配", Int64(matches.count)) : AppText.string("大小含下级内容，不重复累计"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("选择明确缓存") { state.selected.formUnion(filtered.filter { $0.risk == .recommended }.map(\.id)) }
                        .disabled(state.busy || !filtered.contains { $0.risk == .recommended })
                    Button("清空选择") { state.selected = [] }.disabled(state.selected.isEmpty)
                    Spacer()
                    Button("查看清理清单…", action: state.prepareReview).buttonStyle(.borderedProminent)
                        .disabled(state.selected.isEmpty || state.busy || state.executing)
                }
            }.fixedSize(horizontal: false, vertical: true)
        }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }.quickLookPreview($state.previewURL)
    }
    private func itemList(_ tree: ProjectTree?) -> some View {
        ScrollViewReader { scroll in
        List(selection: Binding<String?>(get: { state.inspectedID }, set: { value in
            if value != state.inspectedID, let item = state.items.first(where: { $0.id == value }) { state.inspect(item) }
        })) {
            if toolMode {
                let groups = Dictionary(grouping: filtered) { "\($0.tool?.title ?? AppText.string("工具")) · \($0.projectPath ?? AppText.string("未关联项目"))" }
                ForEach(groups.keys.sorted(), id: \.self) { group in
                    Section {
                        ForEach(groups[group] ?? []) { row($0).tag($0.id) }
                    } header: {
                        HStack {
                            if let tool = groups[group]?.first?.tool { ToolLogo(tool: tool, size: 18) }
                            Text(group).lineLimit(2)
                            Spacer()
                            Button("选择 / 取消本组") { state.toggleGroup(groups[group] ?? []) }.buttonStyle(.borderless).disabled(state.busy)
                        }
                    }
                }
            } else if let tree {
                if filters.tree {
                    ForEach(tree.rows) { node in
                        ProjectFileRow(state: state, row: node, tree: true).tag(node.id)
                            .listRowBackground(node.isRoot ? SweepPalette.accent.opacity(0.065) : Color.clear)
                    }
                } else {
                    if let root = tree.flatRoot {
                        Section("整个项目") {
                            ProjectFileRow(state: state, row: root, tree: false).tag(root.id)
                                .listRowBackground(SweepPalette.accent.opacity(0.065))
                        }
                    }
                    if !tree.flatContents.isEmpty {
                        Section("项目内文件") {
                            ForEach(tree.flatContents) { node in ProjectFileRow(state: state, row: node, tree: false).tag(node.id) }
                        }
                    }
                }
            }
        }.listStyle(.inset)
            .focusable(!toolMode).focused($listFocused).focusEffectDisabled()
            .onChange(of: state.inspectedID) { _, id in
                if !toolMode, let id { listFocused = true; scroll.scrollTo(id) }
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: .down) { key in
                guard !toolMode, !state.busy, !state.executing else { return .ignored }
                let displayed = filters.tree ? tree?.rows.map(\.item) ?? []
                    : (tree?.flatRoot.map { [$0.item] } ?? []) + (tree?.flatContents.map(\.item) ?? [])
                if key.key == .upArrow || key.key == .downArrow {
                    guard !displayed.isEmpty else { return .ignored }
                    let current = displayed.firstIndex { $0.id == state.inspectedID }
                    let next = current.map { min(displayed.count - 1, max(0, $0 + (key.key == .downArrow ? 1 : -1))) } ?? 0
                    state.inspect(displayed[next]); return .handled
                }
                guard filters.tree, let tree, let index = tree.rows.firstIndex(where: { $0.id == state.inspectedID }) else { return .ignored }
                let node = tree.rows[index]
                if key.key == .rightArrow {
                    if node.hasChildren && !node.isExpanded { state.toggleProjectExpansion(node) }
                    else if node.hasChildren, index + 1 < tree.rows.count { state.inspect(tree.rows[index + 1].item) }
                    else { return .ignored }
                } else if node.hasChildren && node.isExpanded { state.toggleProjectExpansion(node) }
                else if let parent = tree.rows.first(where: { $0.item.path == node.item.parentPath }) { state.inspect(parent.item) }
                else { return .ignored }
                return .handled
            }.overlay {
            if scope == .projectFiles && state.projectScanActive {
                ProjectScanProgressView(progress: state.projectScanProgress, stageTitle: state.projectScanStageTitle,
                    startedAt: state.projectScanStartedAt)
            } else if filtered.isEmpty && !state.busy {
                ContentUnavailableView(AppText.string(emptyTitle), systemImage: "tray", description: Text(AppText.string(emptyMessage)))
            }
        }.background(.background, in: RoundedRectangle(cornerRadius: 10))
        }
    }
    private var emptyTitle: String {
        if !scopedItems.isEmpty { return "没有符合筛选条件的内容" }
        if toolMode, scope == .all {
            return state.configurations.isEmpty ? "连接工具后检查本地记录" : toolPageComplete ? "未找到可列出的本地记录" : "工具记录尚未完整检查"
        }
        return toolMode ? state.associationEmptyTitle : "暂无文件"
    }
    private var emptyMessage: String {
        if !scopedItems.isEmpty { return "调整筛选或关闭“仅看已选”；已有勾选仍然保留。" }
        if toolMode, scope == .all {
            return toolPageComplete ? "已连接工具的本地检查已完成。" : "连接目录并点击“扫描已授权目录”，检查范围与结果将显示在这里。"
        }
        return toolMode ? state.associationEmptyMessage : "完成扫描后将在这里显示项目内容。"
    }
    private var toolPageComplete: Bool {
        !state.configurations.isEmpty && state.configurations.allSatisfy { state.inspection(for: $0.tool).phase == .complete }
    }
    private func row(_ item: CleanupItem) -> some View {
        HStack(spacing: 9) {
            Toggle(AppText.format("选择 %@", item.displayTitle), isOn: Binding(get: { state.selected.contains(item.id) }, set: { _ in state.toggle(item) }))
                .labelsHidden().toggleStyle(.checkbox).disabled(!item.isSelectable || state.busy)
                .accessibilityLabel(AppText.format("清理选择：%@", item.displayTitle)).help(item.isSelectable ? AppText.string("勾选加入清理清单") : AppText.string(item.reason))
            Image(systemName: item.action == .deleteSession ? "bubble.left.and.bubble.right" : item.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(item.isDirectory ? .blue : SweepPalette.file(item.category)).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle).font(.body.weight(.medium)).lineLimit(1)
                Text(AppText.string(item.reason)).font(.caption).foregroundStyle(.secondary).lineLimit(state.inspectorVisible ? 1 : 2)
                if item.category == .session, let modified = item.modifiedAt {
                    Text(AppText.date(modified, dateStyle: .medium, timeStyle: .short)).font(.caption).foregroundStyle(.secondary)
                }
                if !state.inspectorVisible { Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.risk == .unavailable ? AppText.string("未完整统计") : SweepState.size(item.bytes)).font(.callout).monospacedDigit()
                if !state.inspectorVisible { Text(AppText.string(item.risk.title)).font(.caption).foregroundStyle(.secondary) }
            }
            Button { state.inspect(item) } label: { Image(systemName: "info.circle").frame(width: 24, height: 28) }
                .buttonStyle(.plain).accessibilityLabel(AppText.format("查看 %@ 的详情", item.displayTitle)).disabled(state.busy)
        }.padding(.vertical, 5).contentShape(Rectangle())
            .contextMenu {
                Button("查看详情") { state.inspect(item) }
                Button("快速查看") { state.preview(item) }.disabled(!PreviewSafety.isEligible(item) || state.busy)
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            }
    }
}
