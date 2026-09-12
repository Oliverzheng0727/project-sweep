import AppKit
import CleanupCore
import SwiftUI

struct ProjectLibraryView: View {
    @ObservedObject var state: SweepState

    private var projects: [ProjectDirectory] {
        ProjectLibraryQuery(search: state.librarySearch, filter: state.libraryFilter,
                            newestFirst: state.libraryNewestFirst)
            .apply(to: state.catalog?.projects ?? [], summaries: state.scanSummaries,
                   recentPaths: state.recentProjectPaths, pinnedPaths: state.pinnedProjectPaths)
    }
    private var selectedProject: ProjectDirectory? { projects.first { $0.path == state.librarySelection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("你的项目，一目了然。").font(.largeTitle.weight(.semibold))
                    Text("双击打开项目，或选中后按回车深入整理。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("选择项目总目录…", action: state.chooseLibrary)
                    Button("直接打开单个项目…", action: state.chooseProject)
                    if state.libraryRoot != nil {
                        Divider()
                        Button("移除项目库入口（保留文件）", action: state.forgetLibrary)
                    }
                } label: { Label(AppText.string(state.libraryRoot == nil ? "添加目录" : "更换目录"), systemImage: "folder.badge.plus") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            if let library = state.libraryRoot {
                HStack(spacing: 14) {
                    ProjectFolderIcon(size: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(library.lastPathComponent).font(.headline)
                            Text("项目总目录").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(library.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Text(AppText.format("%lld 个项目", Int64(state.catalog?.projects.count ?? 0))).foregroundStyle(.secondary)
                    Button("刷新", systemImage: "arrow.clockwise", action: state.loadLibrary).disabled(state.busy)
                }.padding(16).background(SweepPalette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                HStack {
                    TextField("搜索项目名称", text: $state.librarySearch).textFieldStyle(.roundedBorder)
                    Menu {
                        Picker("项目筛选", selection: $state.libraryFilter) {
                            ForEach(ProjectLibraryFilter.allCases) { filter in
                                Text(AppText.string(filter.title)).tag(filter)
                            }
                        }
                    } label: {
                        Label(AppText.string(state.libraryFilter.title), systemImage: "line.3.horizontal.decrease")
                    }.fixedSize()
                    Toggle("按创建时间", isOn: $state.libraryNewestFirst).toggleStyle(.button)
                        .help("按文件夹创建时间从新到旧排列；未知时间放在最后")
                    Picker("浏览方式", selection: $state.libraryListMode) {
                        Image(systemName: "square.grid.2x2").accessibilityLabel("网格").tag(false)
                        Image(systemName: "list.bullet").accessibilityLabel("列表").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 80)
                }
                Group {
                    if state.libraryListMode {
                        List(selection: $state.librarySelection) {
                            ForEach(projects) { project in
                                libraryRow(project).tag(project.path)
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { state.openProject(project) })
                                    .accessibilityAction(named: "深入整理") { state.openProject(project) }
                                    .contextMenu {
                                        Button("深入整理") { state.openProject(project) }.disabled(!project.isAvailable)
                                        Button(AppText.string(state.isPinned(project) ? "取消置顶" : "置顶项目")) { state.togglePinned(project) }
                                    }
                            }
                        }.listStyle(.inset)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 14)], alignment: .leading, spacing: 14) {
                                ForEach(projects) { project in
                                    ProjectFolderCard(project: project, summary: state.summary(for: project), selected: state.librarySelection == project.path,
                                        pinned: state.isPinned(project), select: { state.librarySelection = project.path },
                                        open: { state.openProject(project) }, togglePin: { state.togglePinned(project) })
                                }
                            }.padding(2)
                        }
                    }
                }.overlay {
                    if projects.isEmpty, !state.busy {
                        let filtering = !state.librarySearch.isEmpty || state.libraryFilter != .all
                        ContentUnavailableView(AppText.string(filtering ? "没有符合当前筛选的项目" : "这个目录还没有项目文件夹"), systemImage: "folder",
                            description: Text(AppText.string(filtering ? "更改搜索或筛选条件。" : "请选择包含多个项目文件夹的上一级目录，也可以直接打开单个项目。")))
                    }
                }
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selectedProject?.title ?? AppText.string("先选中一个项目")).font(.headline)
                        Text(selectedProject?.issue.map(AppText.string) ?? AppText.string(selectedProject == nil ? "这里只列出项目，进入后才开始深入扫描。" : "可以保留成果并整理残留，或移除整个项目。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let project = selectedProject {
                        Button(AppText.string(state.isPinned(project) ? "取消置顶" : "置顶项目"),
                               systemImage: state.isPinned(project) ? "pin.slash" : "pin") {
                            state.togglePinned(project)
                        }.buttonStyle(.bordered)
                    }
                    Button("深入整理", systemImage: "arrow.right") {
                        if let project = selectedProject { state.openProject(project) }
                    }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.return, modifiers: [])
                        .disabled(selectedProject?.isAvailable != true || state.busy)
                }.padding(18).background(SweepPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SweepPalette.border.opacity(0.4), lineWidth: 0.5))
            } else {
                VStack(spacing: 20) {
                    HStack(spacing: 18) {
                        ProjectFolderIcon(size: 64).rotationEffect(.degrees(-9)).opacity(0.4)
                        ProjectFolderIcon(size: 64)
                        ProjectFolderIcon(size: 64).rotationEffect(.degrees(9)).opacity(0.4)
                    }.accessibilityHidden(true)
                    Text("先把项目总目录加进来").font(.title2.weight(.semibold))
                    Text("例如：Claude 文件夹中存放了「个人简历」「分镜图」「文献梳理」等项目。\n添加 Claude 文件夹后，就可以在这里逐个选择项目。")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(6)
                    Button("选择项目总目录", systemImage: "folder.badge.plus", action: state.chooseLibrary)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("只处理一个项目？直接打开…", action: state.chooseProject).buttonStyle(.plain).foregroundStyle(.secondary)
                    Text("也可以把项目总目录拖到这里").font(.caption).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SweepPalette.surface, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(SweepPalette.border, style: StrokeStyle(lineWidth: 1, dash: [7])))
            }
        }.padding(28)
            .onChange(of: state.libraryRoot) { state.librarySelection = nil; state.librarySearch = "" }
            .dropDestination(for: URL.self) { urls, _ in
                guard urls.count == 1, let url = urls.first, url.isFileURL, !state.executing else { return false }
                state.acceptLibrary(url); return true
            }
    }
    private func libraryRow(_ project: ProjectDirectory) -> some View {
        HStack(spacing: 12) {
            ProjectFolderIcon(size: 30, available: project.isAvailable)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(project.title).font(.body.weight(.medium))
                    if state.isPinned(project) {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(SweepPalette.accent)
                            .accessibilityLabel("已置顶")
                    }
                }
                Text(AppText.format("创建：%@", project.createdAt.map { AppText.date($0, dateStyle: .medium, timeStyle: .none) } ?? AppText.string("未知")))
                    .font(.caption).foregroundStyle(.secondary)
                if let issue = project.issue { Text(AppText.string(issue)).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let summary = state.summary(for: project) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(AppText.format("%@ · 缓存 %@", SweepState.size(summary.bytes), SweepState.size(summary.cacheBytes))).font(.callout).monospacedDigit()
                    Text(AppText.format("上次扫描 %@", AppText.date(summary.scannedAt, dateStyle: .none, timeStyle: .short))).font(.caption).foregroundStyle(.secondary)
                }
            } else { Text(AppText.string("未扫描")).font(.caption).foregroundStyle(.secondary) }
            Image(systemName: project.isAvailable ? "chevron.right" : "lock.fill").foregroundStyle(.secondary)
        }.padding(.vertical, 7).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }

}
