import CleanupCore
import SwiftUI

struct ProjectDetailView: View {
    @ObservedObject var state: SweepState
    let root: URL
    private var projectItems: [CleanupItem] { state.items.filter { $0.tool == nil } }
    private var projectBytes: Int64 { projectItems.first { $0.path == root.path }?.bytes ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Label(root.path, systemImage: "square.stack.3d.up.fill")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(root.path)
                Spacer()
                Text(state.filesScanned ? (state.projectOverview.isComplete ? SweepState.size(projectBytes) : AppText.string("大小不完整")) : state.projectScanActive ? AppText.string("扫描中") : AppText.string("尚未完成扫描"))
                    .font(.headline.monospacedDigit()).fixedSize()
            }.fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Picker("清理模式", selection: $state.mode) {
                    Text("整理项目").tag(ProjectMode.organize)
                    Text("移除整个项目").tag(ProjectMode.remove)
                }.pickerStyle(.segmented).labelsHidden().fixedSize().disabled(state.busy)
                Text(AppText.string(state.mode == .remove ? "项目放入废纸篓，关联记录单独勾选" : "保留成果，清理残留"))
                    .font(.caption).foregroundStyle(state.mode == .remove ? Color.orange : .secondary)
                Spacer(minLength: 0)
            }.fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Picker("项目内容", selection: $state.projectTab) {
                    ForEach(SweepState.ProjectTab.allCases) { Text(AppText.string($0.rawValue)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Spacer()
                Text(state.projectScanActive
                     ? AppText.format("已检查 %lld 项", Int64(state.projectScanProgress?.count ?? 0))
                     : AppText.fileCount(state.projectOverview.inventoryCount) + " · " + AppText.string(state.associationSummary))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.fixedSize(horizontal: false, vertical: true)
            if state.projectTab == .files {
                if state.mode == .organize { ProjectOverviewView(state: state) }
                ItemBrowser(state: state, toolMode: false, scope: .projectFiles)
            } else {
                ProjectConnectionsView(state: state)
                if state.configurations.isEmpty {
                    ToolDataEmptyView(title: state.associationEmptyTitle, message: state.associationEmptyMessage)
                } else {
                    ItemBrowser(state: state, toolMode: true, scope: .relatedRecords)
                }
            }
        }.padding(18)
    }
}
