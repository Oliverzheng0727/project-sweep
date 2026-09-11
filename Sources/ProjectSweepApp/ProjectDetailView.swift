import CleanupCore
import SwiftUI

struct ProjectDetailView: View {
    @ObservedObject var state: SweepState
    let root: URL
    private var projectItems: [CleanupItem] { state.items.filter { $0.tool == nil } }
    private var projectBytes: Int64 { projectItems.first { $0.path == root.path }?.bytes ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("返回项目库", systemImage: "chevron.left", action: state.backToLibrary).buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("重新深入扫描", systemImage: "arrow.clockwise", action: state.scanProject).disabled(state.busy)
            }
            HStack(alignment: .top, spacing: 17) {
                Image(systemName: "folder.fill").font(.system(size: 42, weight: .light)).foregroundStyle(.teal).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(root.lastPathComponent).font(.largeTitle.weight(.semibold))
                    Text(root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(state.filesScanned ? (state.projectOverview.isComplete ? SweepState.size(projectBytes) : "大小不完整") : state.projectScanActive ? "扫描中" : "尚未完成扫描").font(.title2.monospacedDigit())
                    Text(state.projectScanActive ? "已检查 \(state.projectScanProgress?.count ?? 0) 项" : "\(projectItems.count) 个文件与目录 · \(state.associationSummary)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                ProjectModeCard(title: "保留成果，清理残留", subtitle: "查看缓存、制作过程文件和关联记录", icon: "slider.horizontal.3", selected: state.mode == .organize) { state.mode = .organize }
                ProjectModeCard(title: "移除整个项目", subtitle: "项目放入废纸篓，关联记录单独勾选", icon: "trash", selected: state.mode == .remove) { state.mode = .remove }
            }.disabled(state.busy)
            HStack {
                Picker("项目内容", selection: $state.projectTab) {
                    ForEach(SweepState.ProjectTab.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 260)
                Spacer()
                if state.mode == .remove {
                    Text("包括源码和成果，请核对最终清单。").font(.caption).foregroundStyle(.orange)
                }
            }
            if state.projectTab == .files {
                if state.mode == .organize { ProjectOverviewView(state: state) }
                ItemBrowser(state: state, toolMode: false, scope: .projectFiles)
            } else {
                ProjectConnectionsView(state: state)
                ItemBrowser(state: state, toolMode: true, scope: .relatedRecords)
            }
        }.padding(28)
    }
}

private struct ProjectModeCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(selected ? .teal : .secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? .teal : .secondary)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.teal.opacity(0.08) : Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.teal.opacity(0.4) : Color.clear))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(selected ? "已选择" : "未选择")
    }
}
