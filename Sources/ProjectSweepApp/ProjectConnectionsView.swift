import CleanupCore
import SwiftUI

struct ProjectConnectionsView: View {
    @ObservedObject var state: SweepState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(ToolKind.allCases) { tool in
                    ToolConnectionStatusView(state: state, tool: tool)
                }
            }
            Text("连接的是工具记录目录（例如 ~/.claude），与存放作品的 Claude 文件夹分开授权。历史不备份，项目记忆保留。")
                .font(.caption).foregroundStyle(.secondary)
        }
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
            Text(inspection.title).font(.caption).foregroundStyle(inspection.checkedAllSessions ? Color.secondary : .orange)
            if let report = inspection.report {
                Text(report.sessionDeletion == .available ? "支持已验证会话的删除" : "会话删除不可用")
                    .font(.caption).foregroundStyle(.secondary)
            } else if tool == .cursor { Text("会话删除未开放").font(.caption).foregroundStyle(.secondary) }
            if let message = inspection.message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(message) }
            HStack {
                Button(connected ? "更换目录…" : "连接目录…") { state.chooseTool(tool) }
                    .accessibilityLabel("\(tool.title)：\(connected ? "更换" : "连接")记录目录")
                if connected { Button("断开") { state.disconnectTool(tool) }.accessibilityLabel("断开 \(tool.title)") }
            }.controlSize(.small).disabled(state.busy || state.executing)
        }.padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.teal.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
    }
}
