import CleanupCore
import SwiftUI

struct ProjectView: View {
    @ObservedObject var state: SweepState
    var body: some View {
        Group {
            if state.isProjectOpen, let root = state.root {
                ProjectDetailView(state: state, root: root)
            } else {
                ProjectLibraryView(state: state)
            }
        }.disabled(state.executing)
            .searchable(text: search, placement: .toolbar,
                        prompt: Text(AppText.string(state.isProjectOpen ? "搜索名称或路径" : "搜索项目名称")))
    }

    private var search: Binding<String> {
        Binding(get: {
            state.isProjectOpen ? state.filters(for: state.projectTab == .files ? .projectFiles : .relatedRecords).search : state.librarySearch
        }, set: { value in
            if state.isProjectOpen {
                let scope: BrowserScope = state.projectTab == .files ? .projectFiles : .relatedRecords
                var filters = state.filters(for: scope); filters.search = value; state.setFilters(filters, for: scope)
            } else { state.librarySearch = value }
        })
    }
}
