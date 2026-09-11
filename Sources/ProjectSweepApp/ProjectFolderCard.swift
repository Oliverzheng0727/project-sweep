import CleanupCore
import SwiftUI

struct ProjectFolderCard: View {
    let project: ProjectDirectory
    let summary: ProjectScanSummary?
    let selected: Bool
    let select: () -> Void
    let open: () -> Void
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
                Text(project.title).font(.body.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                    .frame(height: 38, alignment: .top)
                Text("创建：\(project.createdAt?.formatted(date: .abbreviated, time: .omitted) ?? "未知")")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(project.createdAt.map { "文件夹创建时间：\($0.formatted(date: .complete, time: .standard))" } ?? "未能读取文件夹创建时间")
                if let summary {
                    Text("\(SweepState.size(summary.bytes)) · 缓存 \(SweepState.size(summary.cacheBytes))").font(.caption).foregroundStyle(.secondary)
                    Text("扫描于 \(summary.scannedAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(project.issue == nil ? "未扫描" : "暂不可打开").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity).padding(.vertical, 16).padding(.horizontal, 12)
                .background { RoundedRectangle(cornerRadius: 15).fill(SweepPalette.surface).shadow(color: .black.opacity(0.035), radius: 4, y: 2) }
                .overlay {
                    RoundedRectangle(cornerRadius: 15).fill(SweepPalette.accent.opacity(selected ? 0.10 : hovered ? 0.035 : 0)).allowsHitTesting(false)
                }
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(selected ? SweepPalette.accent : SweepPalette.border.opacity(hovered ? 0.8 : 0.4), lineWidth: selected ? 1.5 : 0.5))
                .contentShape(RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain).accessibilityLabel("选择项目 \(project.title)")
            .accessibilityValue(selected ? "已选中" : "未选中")
            .help(project.issue ?? "双击打开，或选中后按回车")
            .onHover { hovered = $0 }
            .simultaneousGesture(TapGesture(count: 2).onEnded { if project.isAvailable { open() } })
            .contextMenu { Button("深入整理", action: open).disabled(!project.isAvailable) }
    }
}
