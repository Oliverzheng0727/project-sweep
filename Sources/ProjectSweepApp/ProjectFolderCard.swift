import CleanupCore
import SwiftUI

struct ProjectFolderCard: View {
    let project: ProjectDirectory
    let summary: ProjectScanSummary?
    let selected: Bool
    let pinned: Bool
    let select: () -> Void
    let open: () -> Void
    let togglePin: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: select) {
            VStack(spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    ProjectFolderIcon(size: 58, available: project.isAvailable)
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.title3).symbolRenderingMode(.palette)
                            .foregroundStyle(Color(nsColor: .selectedMenuItemTextColor), SweepPalette.accent).offset(x: 7, y: 3)
                    }
                    if !project.isAvailable { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                }.accessibilityHidden(true)
                HStack(spacing: 5) {
                    Text(project.title).font(.body.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                    if pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(SweepPalette.accent) }
                }.frame(height: 38, alignment: .top).accessibilityElement(children: .combine)
                Text(AppText.format("创建：%@", project.createdAt.map { AppText.date($0, dateStyle: .medium, timeStyle: .none) } ?? AppText.string("未知")))
                    .font(.caption).foregroundStyle(.secondary)
                    .help(project.createdAt.map { AppText.format("文件夹创建时间：%@", AppText.date($0, dateStyle: .full, timeStyle: .medium)) } ?? AppText.string("未能读取文件夹创建时间"))
                if let summary {
                    Text(AppText.format("%@ · 缓存 %@", SweepState.size(summary.bytes), SweepState.size(summary.cacheBytes))).font(.caption).foregroundStyle(.secondary)
                    Text(AppText.format("扫描于 %@", AppText.date(summary.scannedAt, dateStyle: .none, timeStyle: .short))).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(AppText.string(project.issue == nil ? "未扫描" : "暂不可打开")).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity).padding(.vertical, 16).padding(.horizontal, 12)
                .background { RoundedRectangle(cornerRadius: 15).fill(SweepPalette.surface).shadow(color: .black.opacity(0.035), radius: 4, y: 2) }
                .overlay {
                    RoundedRectangle(cornerRadius: 15).fill(SweepPalette.accent.opacity(selected ? 0.10 : hovered ? 0.035 : 0)).allowsHitTesting(false)
                }
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(selected ? SweepPalette.accent : SweepPalette.border.opacity(hovered ? 0.8 : 0.4), lineWidth: selected ? 1.5 : 0.5))
                .contentShape(RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain).accessibilityLabel(AppText.format("选择项目 %@", project.title))
            .accessibilityValue(AppText.string(selected ? "已选中" : "未选中"))
            .help(project.issue.map(AppText.string) ?? AppText.string("双击打开，或选中后按回车"))
            .onHover { hovered = $0 }
            .simultaneousGesture(TapGesture(count: 2).onEnded { if project.isAvailable { open() } })
            .contextMenu {
                Button("深入整理", action: open).disabled(!project.isAvailable)
                Button(AppText.string(pinned ? "取消置顶" : "置顶项目"), action: togglePin)
            }
    }
}
