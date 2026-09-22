import CleanupCore
import SwiftUI

/// Read-only counterpart to the AI-specific removal list. No rows in this view
/// bind to the cleanup selection or open the unverified target of a reference.
struct SkillRelationshipsView: View {
    let relationships: [SkillRelationship]
    let inventory: SkillRelationshipInventory?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("汇总 Claude Code 与 Codex 本次扫描发现的目录和引用，不代表技能已启用。未连接来源无法检查。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let inventory {
                Label(AppText.string(inventory.complete ? "已连接来源检查完成" : "已找到部分关联，来源检查未完整完成"),
                      systemImage: inventory.complete ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(inventory.complete ? Color.secondary : Color.orange)
            }
            if relationships.isEmpty {
                ContentUnavailableView("没有可显示的关联", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text(AppText.string(inventory == nil ? "请重新扫描技能来源。" : "检查搜索条件，或到技能列表添加来源后重新扫描。")))
            } else {
                List(relationships) { relationship in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(AppText.string(relationship.originalObserved
                                 ? "原文件目录出现在本次扫描中；引用目标仍未跟随访问。"
                                 : "仅发现指向此路径的引用，未检查目标是否存在或可用。"))
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(relationship.entries) { entry in
                                SkillRelationshipSourceRow(entry: entry)
                            }
                        }.padding(.vertical, 10).padding(.leading, 6)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Image(systemName: relationship.originalObserved ? "folder" : "link").foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(relationship.name).font(.headline).lineLimit(1)
                                Spacer()
                                Text(AppText.format("%lld 个来源条目", Int64(relationship.entries.count)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(relationship.originalPath).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(relationship.originalPath)
                            HStack(spacing: 10) {
                                ForEach([ToolKind.claude, .codex].filter { tool in relationship.entries.contains { $0.root.tool == tool } }) { tool in
                                    HStack(spacing: 4) { ToolLogo(tool: tool, size: 16); Text(tool.title).font(.caption) }
                                }
                                Text(AppText.string(relationship.originalObserved ? "已发现原文件目录" : "目标未校验"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5).accessibilityElement(children: .combine)
                    }
                }.listStyle(.inset)
            }
        }.frame(minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SkillRelationshipSourceRow: View {
    let entry: SkillEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                ToolLogo(tool: entry.root.tool, size: 18)
                Text(entry.root.tool.title).font(.callout.weight(.medium))
                Text(AppText.string(entry.linkTarget == nil ? "目录条目" : "直接引用"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(entry.name).font(.callout).textSelection(.enabled)
            Text(AppText.string(entry.source)).font(.caption).foregroundStyle(.secondary)
            Text(entry.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}
