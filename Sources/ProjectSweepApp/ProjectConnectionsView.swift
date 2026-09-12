import CleanupCore
import SwiftUI

struct ProjectConnectionsView: View {
    @ObservedObject var state: SweepState
    @State private var showingSetup = false
    private var detectedCount: Int {
        ToolKind.allCases.filter { FileManager.default.fileExists(atPath: $0.defaultRoot.path) }.count
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if state.configurations.isEmpty {
                    Label(AppText.format("检测到 %lld 个工具数据目录", Int64(detectedCount)), systemImage: "sparkle.magnifyingglass")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("设置工具数据…", systemImage: "gearshape.2") { showingSetup = true }
                    .controlSize(.small).disabled(state.busy || state.executing)
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(ToolKind.allCases) { tool in
                    ToolConnectionStatusView(state: state, tool: tool)
                }
            }
            Text("连接的是工具记录目录（例如 ~/.claude），与存放作品的 Claude 文件夹分开授权。历史不备份，项目记忆保留。")
                .font(.caption).foregroundStyle(.secondary)
        }.sheet(isPresented: $showingSetup) { ToolDataSetupView(state: state) }
            .onAppear {
                if state.configurations.isEmpty {
                    state.discoverDefaultTools(scanAfterDiscovery: true)
                }
            }
    }
}

struct ToolDataEmptyView: View {
    let title: String
    let message: String
    var body: some View {
        ContentUnavailableView(AppText.string(title), systemImage: "externaldrive.badge.questionmark",
                               description: Text(AppText.string(message)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SweepPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SweepPalette.border.opacity(0.4), lineWidth: 0.5))
    }
}

private struct ToolDataSetupView: View {
    @ObservedObject var state: SweepState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppText.string("工具数据设置")).font(.title2.weight(.semibold))
                Text(AppText.string("标准位置会自动连接；也可以为每个 AI 选择自定义位置。"))
                    .foregroundStyle(.secondary)
            }
            ForEach(ToolKind.allCases) { tool in
                let detected = FileManager.default.fileExists(atPath: tool.defaultRoot.path)
                let connected = state.configurations.first { $0.tool == tool }
                HStack(spacing: 12) {
                    ToolLogo(tool: tool, size: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tool.title).font(.headline)
                        Text(connected?.root.path ?? tool.defaultRoot.path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Label(AppText.string(connected != nil ? "已连接" : detected ? "已检测到默认目录" : "未检测到默认目录"),
                              systemImage: connected != nil ? "checkmark.circle.fill" : detected ? "folder.badge.checkmark" : "questionmark.folder")
                            .font(.caption).foregroundStyle(connected != nil ? Color.green : Color.secondary)
                    }
                    Spacer()
                    Button(AppText.string(connected == nil ? "连接此目录…" : "更换目录…")) { state.chooseTool(tool) }
                        .disabled(state.busy || state.executing)
                }.padding(12).background(SweepPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SweepPalette.border.opacity(0.4), lineWidth: 0.5))
            }
            HStack {
                Text(AppText.string("手动更换或连接自定义目录时，系统会打开文件夹选择器。")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(AppText.string("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 560)
    }
}

struct ToolConnectionStatusView: View {
    @ObservedObject var state: SweepState
    let tool: ToolKind
    private var inspection: ToolInspection { state.inspection(for: tool) }
    private var connected: Bool { state.configurations.contains { $0.tool == tool } }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ToolLogo(tool: tool)
                Text(tool.title).font(.callout.weight(.semibold))
                Spacer()
                if inspection.phase == .scanning { ProgressView().controlSize(.mini) }
            }
            Text(AppText.string(inspection.title)).font(.caption).foregroundStyle(inspection.checkedAllSessions ? Color.secondary : .orange)
            if let report = inspection.report {
                Text(AppText.string(report.sessionDeletion == .available ? "支持已验证会话的删除" : "会话删除不可用"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if tool == .cursor { Text("会话删除未开放").font(.caption).foregroundStyle(.secondary) }
            if let message = inspection.message { Text(AppText.string(message)).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(AppText.string(message)) }
            HStack {
                Button(AppText.string(connected ? "更换目录…" : "连接目录…")) { state.chooseTool(tool) }
                    .accessibilityLabel(AppText.format("%@：%@记录目录", tool.title, AppText.string(connected ? "更换" : "连接")))
                if connected {
                    Button("断开") { state.disconnectTool(tool) }
                        .accessibilityLabel(AppText.format("断开 %@", tool.title))
                }
            }.controlSize(.small).disabled(state.busy || state.executing)
        }.padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(SweepPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SweepPalette.border.opacity(0.4), lineWidth: 0.5))
            .accessibilityElement(children: .contain)
    }
}
