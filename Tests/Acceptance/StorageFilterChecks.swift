import CleanupCore
import Foundation

@main struct StorageFilterChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("Sweep-storage-filter-\(UUID())").standardizedFileURL
        let root = sandbox.appendingPathComponent("混合项目")
        let suite = "sweep-storage-filter-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); try? fm.removeItem(at: sandbox) }
        for (path, content) in [("素材/作品.pdf", "1234567890"), ("素材/作品.png", "12345"), ("__pycache__/file.pyc", "12345678901234567890"), ("Sources/main.swift", "123456789012345") ] {
            let file = root.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file)
        }
        let state = SweepState(store: RecordStore(directory: sandbox.appendingPathComponent("records")), restorePreferences: false,
                               preferences: preferences, defaultToolRoots: [:], skillDiscovery: nil)
        state.root = root; state.isProjectOpen = true
        state.items = try await ProjectScanner().scan(ScanRequest(root: root)).items
        let pdf = state.items.first { $0.title == "作品.pdf" }!
        let image = state.items.first { $0.title == "作品.png" }!
        state.selected = [pdf.id, image.id]
        var filters = state.filters(for: .projectFiles)
        filters.storageKind = .documents; filters.minimumBytes = 10
        state.setFilters(filters, for: .projectFiles)
        guard state.visibleItems(.projectFiles).map(\.id) == [pdf.id], state.selected == [pdf.id, image.id] else {
            fatalError("Storage/size filter ignored file identity, threshold boundary, or cleared selection")
        }
        let tree = ProjectTree(items: state.scopedItems(.projectFiles), matching: state.visibleItems(.projectFiles),
                               filters: filters, expansion: state.projectTreeExpansion)
        guard tree.matchingIDs == [pdf.id], tree.rows.count == 3, tree.rows.filter(\.isContext).count == 2,
              tree.rows.filter(\.isContext).allSatisfy({ !$0.showsCheckbox(mode: .organize) }) else {
            fatalError("Storage filter lost tree ancestors or promoted them into selectable matches")
        }
        print("PASS: storage and size filters preserve selection and restore non-selectable tree ancestors")

        filters.category = .source
        state.setFilters(filters, for: .projectFiles)
        guard state.visibleItems(.projectFiles).isEmpty else { fatalError("Storage/category filtering used OR instead of AND") }
        filters.category = .document; filters.search = "不存在"
        state.setFilters(filters, for: .projectFiles)
        guard state.visibleItems(.projectFiles).isEmpty else { fatalError("Storage filter bypassed search") }
        filters.search = "作品"; filters.onlySelected = true; filters.risk = .review
        state.setFilters(filters, for: .projectFiles)
        guard state.visibleItems(.projectFiles).map(\.id) == [pdf.id] else { fatalError("Combined filters lost matching selection") }
        filters.minimumBytes = 11
        state.setFilters(filters, for: .projectFiles)
        guard state.visibleItems(.projectFiles).isEmpty else { fatalError("Larger minimum accepted smaller file") }
        print("PASS: category, risk, search, selection, storage and minimum size combine with AND")

        var reset = BrowserFilters(); reset.tree = true; reset.minimumBytes = 16
        state.setFilters(reset, for: .projectFiles)
        let matches = state.visibleItems(.projectFiles)
        guard Set(matches.map(\.title)) == ["__pycache__", "file.pyc"], !matches.contains(where: { $0.path == root.path }) else {
            fatalError("Size filter matched ordinary parent aggregates or missed atomic cache directory")
        }
        var changed = reset; changed.storageKind = .cache
        guard reset.hasQuery, !reset.sameQuery(as: changed) else { fatalError("Storage change did not invalidate temporary expansion") }
        reset.storageKind = .cache; changed.minimumBytes = 100
        guard !reset.sameQuery(as: changed) else { fatalError("Size change did not invalidate temporary expansion") }
        changed.minimumBytes = reset.minimumBytes; changed.tree = false
        guard reset.sameQuery(as: changed) else { fatalError("View preference was treated as a filter change") }
        state.setFilters(changed, for: .projectFiles)
        guard state.selected == [pdf.id, image.id] else { fatalError("Presentation change cleared hidden selected files") }
        print("PASS: size matching excludes mixed parent totals; filter changes and presentation preferences remain distinct")

        for path in ["node_modules/package/index.js", "build/index.js"] {
            let file = root.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture source syntax".utf8).write(to: file)
        }
        state.items = try await ProjectScanner().scan(ScanRequest(root: root)).items
        let expectedByKind: [(StorageKind, String)] = [(.dependencies, "node_modules/package/index.js"),
                                                      (.build, "build/index.js"), (.source, "Sources/main.swift")]
        let selectedPaths = Set(expectedByKind.map { root.appendingPathComponent($0.1).path })
        state.selected = Set(state.items.filter { selectedPaths.contains($0.path) }.map(\.id))
        let expectedSelection = state.selected
        for (kind, relativePath) in expectedByKind {
            let expectedPath = root.appendingPathComponent(relativePath).path
            for treeView in [true, false] {
                for onlySelected in [false, true] {
                    var query = BrowserFilters()
                    query.tree = treeView; query.onlySelected = onlySelected; query.storageKind = kind
                    state.setFilters(query, for: .projectFiles)
                    guard state.visibleItems(.projectFiles).map(\.path) == [expectedPath], state.selected == expectedSelection else {
                        fatalError("Storage classification changed between tree, flat, or only-selected view: \(kind), tree=\(treeView), selected=\(onlySelected)")
                    }
                }
            }
        }
        print("PASS: dependency, build and source classifications remain stable across tree, flat and only-selected views")
    }
}
