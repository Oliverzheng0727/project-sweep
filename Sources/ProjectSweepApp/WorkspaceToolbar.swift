import CleanupCore
import SwiftUI

struct WorkspaceToolbar: ToolbarContent {
    @ObservedObject var state: SweepState

    var body: some ToolbarContent {
        if state.page == .project {
            if state.isProjectOpen {
                ToolbarItem(placement: .navigation) {
                    Button("返回项目库", systemImage: "chevron.left", action: state.backToLibrary)
                        .disabled(state.executing)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if !state.isProjectOpen {
                    Picker("浏览方式", selection: $state.libraryListMode) {
                        Image(systemName: "square.grid.2x2").accessibilityLabel("网格").tag(false)
                        Image(systemName: "list.bullet").accessibilityLabel("列表").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 72)
                }
                Button("刷新", systemImage: "arrow.clockwise") {
                    if state.isProjectOpen { state.scanProject() } else { state.loadLibrary() }
                }.disabled(state.busy || state.executing || (!state.isProjectOpen && state.libraryRoot == nil))
                Menu {
                    Button("添加项目库…", action: state.chooseLibrary)
                    Button("直接打开单个项目…", action: state.chooseProject)
                    if let id = state.activeLibraryID {
                        Divider()
                        Button("重新连接此项目库…") { state.reconnectLibrary(id: id) }
                        Button("移除项目库入口（保留文件）", action: state.forgetLibrary)
                    }
                } label: { Label("项目库操作", systemImage: "folder.badge.plus") }
                    .disabled(state.executing)
            }
        } else if state.page == .tools {
            ToolbarItem(placement: .primaryAction) {
                Button("重新检索并扫描", systemImage: "arrow.clockwise") { state.discoverDefaultTools() }
                    .disabled(state.busy || state.executing)
            }
        }
    }
}
