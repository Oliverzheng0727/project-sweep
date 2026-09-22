import AppKit
import CleanupCore
import SwiftUI

struct SkillDetailView: View {
    let entry: SkillEntry
    let relationship: SkillRelationship?
    let relationshipsComplete: Bool
    let close: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    ToolLogo(tool: entry.root.tool, size: 24)
                    Text(entry.root.tool.title).font(.headline)
                    Spacer()
                    Button("收起详情", systemImage: "xmark", action: close).labelStyle(.iconOnly).buttonStyle(.plain)
                }
                Text(entry.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text(AppText.string(entry.source)).font(.caption).foregroundStyle(.secondary)
                if !entry.summary.isEmpty { Text(entry.summary).font(.callout).textSelection(.enabled) }
                Divider()
                field("位置", entry.url.path)
                if let target = entry.linkTarget { field("引用目标（保留）", target) }
                field(entry.removal == .reference ? "引用大小" : "可处理大小", entry.bytes.map(SweepState.size) ?? AppText.string("未统计 · 只读"))
                field("实际影响", AppText.string(entry.impact))
                Button("在 Finder 中显示", systemImage: "folder") {
                    // Reveal the entry, never open its target or execute skill content.
                    NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                }
                if entry.source == "插件技能" {
                    Text("请使用原 AI 工具的插件管理入口。卸载插件还可能影响其其他技能或连接器。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let relationship {
                    Divider()
                    Text("观察到的关联").font(.headline)
                    field(relationship.originalObserved ? "原文件目录" : "引用目标（未校验）", relationship.originalPath)
                    Text(AppText.string(relationshipsComplete ? "仅汇总已连接来源，不代表技能已启用。" : "来源检查未完整完成，以下仅为已发现的关联。"))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(relationship.entries) { related in SkillRelationshipSourceRow(entry: related) }
                }
            }.padding(16)
        }
    }
    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(AppText.string(title)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }
}
