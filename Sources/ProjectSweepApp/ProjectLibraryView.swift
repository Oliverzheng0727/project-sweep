import AppKit
import CleanupCore
import SwiftUI

struct ProjectLibraryView: View {
    @ObservedObject var state: SweepState

    private var projects: [ProjectDirectory] {
        (state.catalog?.projects ?? []).filter { state.librarySearch.isEmpty || $0.title.localizedStandardContains(state.librarySearch) }
            .sorted {
                if state.libraryNewestFirst, $0.createdAt != $1.createdAt {
                    return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
                }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
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
                } label: { Label(state.libraryRoot == nil ? "添加目录" : "更换目录", systemImage: "folder.badge.plus") }
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
                    Text("\(state.catalog?.projects.count ?? 0) 个项目").foregroundStyle(.secondary)
                    Button("刷新", systemImage: "arrow.clockwise", action: state.loadLibrary).disabled(state.busy)
                }.padding(16).background(SweepPalette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                HStack {
                    TextField("搜索项目名称", text: $state.librarySearch).textFieldStyle(.roundedBorder)
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
                                    .contextMenu { Button("深入整理") { state.openProject(project) }.disabled(!project.isAvailable) }
                            }
                        }.listStyle(.inset)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 14)], alignment: .leading, spacing: 14) {
                                ForEach(projects) { project in
                                    ProjectFolderCard(project: project, summary: state.summary(for: project), selected: state.librarySelection == project.path,
                                        select: { state.librarySelection = project.path }, open: { state.openProject(project) })
                                }
                            }.padding(2)
                        }
                    }
                }.overlay {
                    if projects.isEmpty, !state.busy {
                        ContentUnavailableView(state.librarySearch.isEmpty ? "这个目录还没有项目文件夹" : "没有找到这个项目", systemImage: "folder",
                            description: Text(state.librarySearch.isEmpty ? "请选择包含多个项目文件夹的上一级目录，也可以直接打开单个项目。" : "尝试其他名称。"))
                    }
                }
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selectedProject?.title ?? "先选中一个项目").font(.headline)
                        Text(selectedProject?.issue ?? (selectedProject == nil ? "这里只列出项目，进入后才开始深入扫描。" : "可以保留成果并整理残留，或移除整个项目。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
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
                Text(project.title).font(.body.weight(.medium))
                Text("创建：\(project.createdAt?.formatted(date: .abbreviated, time: .omitted) ?? "未知")")
                    .font(.caption).foregroundStyle(.secondary)
                if let issue = project.issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let summary = state.summary(for: project) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(SweepState.size(summary.bytes)) · 缓存 \(SweepState.size(summary.cacheBytes))").font(.callout).monospacedDigit()
                    Text("上次扫描 \(summary.scannedAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            } else { Text("未扫描").font(.caption).foregroundStyle(.secondary) }
            Image(systemName: project.isAvailable ? "chevron.right" : "lock.fill").foregroundStyle(.secondary)
        }.padding(.vertical, 7).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }

}
