import CleanupCore
import SwiftUI
import UniformTypeIdentifiers

struct SweepView: View {
    @ObservedObject var state: SweepState
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: sidebarSelection) {
                    Section("管理") {
                        ForEach(SweepState.Page.allCases) { page in
                            Label { Text(AppText.string(page.rawValue)) } icon: {
                                Image(systemName: page.icon)
                            }.tag(page.rawValue)
                        }
                    }
                    Section("项目位置") {
                        ForEach(state.libraryLocations) { library in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(library.path.isEmpty ? AppText.string("原项目库") : library.title).lineLimit(1)
                                    if library.availability == .unavailable {
                                        Text("需要重新连接").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: library.availability == .unavailable ? "externaldrive.badge.exclamationmark" : "folder")
                            }.tag("library:" + library.id).help(library.path)
                                .contextMenu {
                                    Button("打开项目库") { state.selectLibrary(id: library.id) }
                                    Button("重新连接此项目库…") { state.reconnectLibrary(id: library.id) }
                                }
                        }
                        Button("添加项目库…", systemImage: "plus", action: state.chooseLibrary)
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                Label("本地运行", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }.navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 250)
                .disabled(state.executing)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch state.page ?? .project {
                    case .project: ProjectView(state: state)
                    case .tools: ToolsView(state: state)
                    case .skills: SkillsView(state: state.skills, execute: state.executeSkills).disabled(state.executing)
                    case .records: RecordsView(state: state)
                    case .settings: SweepSettingsView(state: state)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if state.page != .skills || state.executing {
                    Divider()
                    HStack(spacing: 9) {
                        if state.busy || state.executing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "lock.shield").foregroundStyle(.secondary) }
                        Text(AppText.string(state.status)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if state.busy { Button("取消扫描", action: state.cancelScan).controlSize(.small) }
                    }.padding(.horizontal, 18).padding(.vertical, 8)
                }
            }.background(SweepPalette.canvas)
                .navigationTitle(state.page == .project && state.isProjectOpen
                                 ? state.root?.lastPathComponent ?? AppText.string("项目库")
                                 : AppText.string((state.page ?? .project).rawValue))
                .toolbar { WorkspaceToolbar(state: state) }
        }
        .sheet(item: $state.review) {
            ReviewView(state: state, plan: $0).environment(\.locale, AppText.preference.locale)
        }
        .alert("无法完成操作", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            Button("好") { state.error = nil }
        } message: { Text(AppText.string(state.error ?? "")) }
    }

    private var sidebarSelection: Binding<String?> {
        Binding(get: {
            if state.page == .project, let id = state.activeLibraryID { return "library:" + id }
            return state.page?.rawValue
        }, set: { value in
            guard !state.executing, let value else { return }
            if value.hasPrefix("library:") { state.selectLibrary(id: String(value.dropFirst(8))) }
            else if let page = SweepState.Page(rawValue: value) {
                if page == .project, state.isProjectOpen { state.backToLibrary() }
                state.page = page
            }
        })
    }
}
