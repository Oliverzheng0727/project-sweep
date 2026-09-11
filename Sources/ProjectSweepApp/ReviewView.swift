import CleanupCore
import SwiftUI

struct ReviewView: View {
    @ObservedObject var state: SweepState
    let plan: CleanupPlan
    @State private var acknowledged = false
    @State private var closedTools = false
    @Environment(\.dismiss) private var dismiss
    private var hasSessions: Bool { plan.items.contains { $0.action == .deleteSession } }
    private var hasTools: Bool { plan.items.contains { $0.tool != nil } }
    private var expanded: [CleanupItem] { plan.items.filter { !state.selected.contains($0.id) } }
    private var sheetHeight: CGFloat {
        let detailLines = plan.items.reduce(0) { $0 + $1.details.count }
        return min(680, max(hasSessions ? 600 : 400, 270 + CGFloat(plan.items.count) * 110 + CGFloat(detailLines) * 25 + (hasTools ? 35 : 0) + (hasSessions ? 40 : 0)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("确认这次清理").font(.title.weight(.semibold))
            Text(AppText.format("最终执行清单 · %lld 项", Int64(plan.items.count))).foregroundStyle(.secondary)
            HStack(spacing: 30) {
                VStack(alignment: .leading, spacing: 5) { Text("移入废纸篓").font(.caption).foregroundStyle(.secondary); Text(SweepState.size(plan.trashBytes)).font(.title2.monospacedDigit()) }
                if hasSessions { VStack(alignment: .leading, spacing: 5) { Text("会话处理量").font(.caption).foregroundStyle(.secondary); Text(SweepState.size(plan.sessionBytes)).font(.title2.monospacedDigit()) } }
            }
            if !expanded.isEmpty {
                Label(AppText.format("已纳入 %lld 个关联项；共享数据与子会话必须一起处理。请核对下方“关联纳入”标记。", Int64(expanded.count)), systemImage: "link")
                    .font(.callout).foregroundStyle(.orange)
            }
            List {
                ForEach([CleanupAction.trash, .deleteSession], id: \.self) { action in
                    let members = plan.items.filter { $0.action == action }
                    if !members.isEmpty {
                        Section(AppText.string(action == .trash ? "文件 · 移入废纸篓，可尝试恢复" : "历史会话 · 永久删除，无备份")) {
                            ForEach(members) { item in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(item.title).font(.headline)
                                        if !state.selected.contains(item.id) { Text("关联纳入").font(.caption).foregroundStyle(.orange) }
                                    }
                                    Text(item.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    Text(AppText.string(item.reason)).font(.caption).foregroundStyle(.secondary)
                                    ForEach(Array(item.details.enumerated()), id: \.offset) { _, detail in
                                        Text(AppText.string(detail)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }.padding(.vertical, 5)
                            }
                        }
                    }
                }
            }.frame(minHeight: 100)
            Text("废纸篓中的文件仍占用磁盘空间。恢复不会覆盖现有文件。执行前会重新校验文件与工具状态；发生变化时将中止对应操作。")
                .font(.caption).foregroundStyle(.secondary)
            if hasTools { Toggle("我已退出涉及的 AI 工具和命令行会话", isOn: $closedTools) }
            if hasSessions {
                Toggle("我理解：历史会话不备份，删除后无法从本应用恢复", isOn: $acknowledged)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("返回检查") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(AppText.string(hasSessions ? "确认清理并永久删除会话" : "确认移入废纸篓"), role: .destructive) { state.execute(plan) }
                    .buttonStyle(.borderedProminent).tint(hasSessions ? .red : SweepPalette.accent)
                    .disabled((hasSessions && !acknowledged) || (hasTools && !closedTools))
            }
        }.padding(28).frame(width: 680, height: sheetHeight)
    }
}
