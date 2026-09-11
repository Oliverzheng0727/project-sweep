import AppKit
import CleanupCore
import SwiftUI

struct ProjectFileRow: View {
    @ObservedObject var state: SweepState
    let row: ProjectTreeRow
    let tree: Bool

    var body: some View {
        HStack(spacing: 9) {
            if tree {
                if row.hasChildren {
                    Button { state.toggleProjectExpansion(row) } label: {
                        Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold)).frame(width: 18, height: 28)
                    }.buttonStyle(.borderless)
                        .accessibilityLabel("\(row.isExpanded ? "收起" : "展开")目录 \(row.item.title)")
                        .accessibilityValue(row.isExpanded ? "已展开" : "已收起")
                        .disabled(state.busy || state.executing)
                } else { Color.clear.frame(width: 18, height: 1).accessibilityHidden(true) }
            }
            if row.showsCheckbox(mode: state.mode) {
                Toggle("选择 \(row.item.title)", isOn: Binding(get: { state.selected.contains(row.id) }, set: { _ in state.toggleProjectSelection(row) }))
                    .labelsHidden().toggleStyle(.checkbox).disabled(!row.item.isSelectable || state.busy || state.executing)
                    .accessibilityLabel(row.isRoot && state.mode == .remove ? "移除整个项目：\(row.item.title)" : "清理选择：\(row.item.title)")
                    .help(row.item.isSelectable ? "勾选加入清理清单" : row.item.reason)
            } else { Color.clear.frame(width: 18, height: 1).accessibilityHidden(true) }
            Image(systemName: row.icon).font(.system(size: row.isRoot ? 22 : 17))
                .foregroundStyle(row.isRoot ? SweepPalette.accent : row.item.isDirectory ? .blue : SweepPalette.file(row.item.category))
                .frame(width: 24).accessibilityHidden(true)
            Button { state.inspect(row.item) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(row.item.title).font(row.isRoot ? .headline : .body.weight(.medium)).lineLimit(1)
                            .layoutPriority(1)
                        if row.isRoot { badge("项目根目录") }
                        if row.isContext { badge("所在目录") }
                    }
                    Text((row.isRoot && state.mode == .remove && !row.isContext ? "移除整个项目 · " : "") + row.explanation(mode: state.mode))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(state.inspectorVisible ? 2 : 3)
                    if !tree && !state.inspectorVisible {
                        Text(row.item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(row.item.path)
                .accessibilityLabel("查看\(row.isRoot ? "项目根目录" : row.isContext ? "所在目录" : row.item.isDirectory ? "文件夹" : "文件") \(row.item.title) 的详情")
            VStack(alignment: .trailing, spacing: 4) {
                Text(row.item.risk == .unavailable ? "未完整统计" : SweepState.size(row.item.bytes)).font(.callout).monospacedDigit()
                if !state.inspectorVisible { Text(row.status(mode: state.mode)).font(.caption).foregroundStyle(.secondary) }
            }.fixedSize(horizontal: true, vertical: false)
            Button { state.inspect(row.item) } label: { Image(systemName: "info.circle").frame(width: 24, height: 28) }
                .buttonStyle(.borderless).accessibilityLabel("查看 \(row.item.title) 的详情").disabled(state.busy)
        }.padding(.leading, tree ? CGFloat(row.depth) * 18 : 0).padding(.vertical, row.isRoot ? 10 : 5)
            .contentShape(Rectangle())
            .contextMenu {
                Button("查看详情") { state.inspect(row.item) }
                Button("快速查看") { state.preview(row.item) }.disabled(!PreviewSafety.isEligible(row.item) || state.busy)
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([row.item.url]) }
            }
    }

    private func badge(_ title: String) -> some View {
        Text(title).font(.caption2.weight(.medium)).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(SweepPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
    }
}
