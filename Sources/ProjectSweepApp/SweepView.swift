import CleanupCore
import SwiftUI
import UniformTypeIdentifiers

struct SweepView: View {
    @ObservedObject var state: SweepState
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                Label("项目清理", systemImage: "square.stack.3d.up.fill")
                    .font(.title3.weight(.semibold)).foregroundStyle(.teal).padding(.horizontal, 16).padding(.top, 22)
                List(SweepState.Page.allCases, selection: $state.page) { page in
                    Label(page.rawValue, systemImage: page.icon).padding(.vertical, 7).tag(page)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 7) {
                    Label("本地运行", systemImage: "lock.shield")
                    Text("有序整理，留出空间。")
                }.font(.caption).foregroundStyle(.secondary).padding(20)
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
                        else { Image(systemName: "checkmark.shield").foregroundStyle(.teal) }
                        Text(state.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if state.busy { Button("取消扫描", action: state.cancelScan).controlSize(.small) }
                    }.padding(.horizontal, 24).padding(.vertical, 12)
                }
            }
        }
        .tint(SweepPalette.accent(for: colorScheme))
        .sheet(item: $state.review) { ReviewView(state: state, plan: $0) }
        .alert("无法完成操作", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            Button("好") { state.error = nil }
        } message: { Text(state.error ?? "") }
    }
}

enum SweepPalette {
    static func accent(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .teal : Color(red: 0.03, green: 0.43, blue: 0.46)
    }
}
