import CleanupCore
import SwiftUI

struct SkillReviewView: View {
    let plan: SkillRemovalPlan
    let execute: (SkillRemovalPlan) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("确认移除技能").font(.title.weight(.semibold))
            Text(AppText.format("%lld 项 · 移入废纸篓 %@", Int64(plan.entries.count), SweepState.size(plan.bytes))).foregroundStyle(.secondary)
            Label("共享引用只移除链接，原文件保留。", systemImage: "link")
                .foregroundStyle(SweepPalette.accent)
            List(plan.entries) { entry in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        ToolLogo(tool: entry.root.tool, size: 22)
                        Text("\(entry.root.tool.title) · \(entry.name)").font(.headline)
                        Spacer()
                        Text(AppText.string(entry.removal.title)).font(.caption.weight(.medium))
                    }
                    Text(entry.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let target = entry.linkTarget { Text(AppText.format("保留原文件：%@", target)).font(.caption).textSelection(.enabled) }
                    Text(AppText.string(entry.impact)).font(.callout)
                }.padding(.vertical, 8)
            }
            Text("技能已经加载到当前会话时，可能需要新建会话或重启 AI 工具才会生效。可以从清理记录恢复；恢复不覆盖同名文件。废纸篓仍占用空间。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("返回检查") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认移入废纸篓", role: .destructive) { dismiss(); execute(plan) }.buttonStyle(.borderedProminent)
            }
        }.padding(26).frame(width: 680, height: min(650, 300 + CGFloat(plan.entries.count) * 155))
    }
}
