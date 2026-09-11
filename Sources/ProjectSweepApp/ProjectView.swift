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
    }
}
