import CleanupCore
import Foundation

@main struct ProjectTreeChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("Sweep-project-tree-\(UUID())").standardizedFileURL
        let root = sandbox.appendingPathComponent("论文").standardizedFileURL
        let suite = "sweep-project-tree-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); try? fm.removeItem(at: sandbox) }
        for (path, content) in [("素材/子目录/同名.txt", "small"), ("作品/同名.txt", String(repeating: "large", count: 80)), (".DS_Store", "cache")] {
            let file = root.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file)
        }
        let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git"); git.arguments = ["init", "-q", root.path]
        try git.run(); git.waitUntilExit(); guard git.terminationStatus == 0 else { fatalError("Fixture Git setup failed") }
        let state = SweepState(store: RecordStore(directory: sandbox.appendingPathComponent("records")), restorePreferences: false, preferences: preferences, defaultToolRoots: [:])
        state.root = root; state.isProjectOpen = true
        state.items = try await ProjectScanner().scan(ScanRequest(root: root)).items
        func presentation() -> ProjectTree {
            ProjectTree(items: state.scopedItems(.projectFiles), matching: state.visibleItems(.projectFiles),
                        filters: state.filters(for: .projectFiles), expansion: state.projectTreeExpansion)
        }
        var tree = presentation()
        guard state.filters(for: .projectFiles).tree, !state.filters(for: .relatedRecords).tree,
              tree.rows.first?.isRoot == true, tree.rows.first?.isExpanded == true,
              tree.rows.first?.icon == "square.stack.3d.up.fill",
              tree.rows.dropFirst().allSatisfy({ $0.depth == 1 && !$0.isExpanded }),
              tree.rows.first(where: { $0.item.title == ".git" })?.hasChildren == false else { fatalError("Initial hierarchy does not identify root and direct contents") }
        print("PASS: project files default to a distinct expanded root; children start collapsed and opaque Git history stays opaque")

        let materials = tree.rows.first { $0.item.title == "素材" }!
        state.toggleProjectExpansion(materials)
        let nested = presentation().rows.first { $0.item.title == "子目录" }!
        state.toggleProjectExpansion(nested)
        tree = presentation()
        guard tree.rows.first(where: { $0.item.path == root.appendingPathComponent("素材/子目录/同名.txt").path })?.depth == 3,
              state.selected.isEmpty, state.inspectedID == nil else { fatalError("Expansion changed cleanup selection or inspector") }
        let siblingBytes = tree.rows.filter { $0.depth == 1 }.map { $0.item.bytes }
        guard siblingBytes == siblingBytes.sorted(by: >), tree.rows.first?.item.path == root.path else { fatalError("Size order escaped sibling scope") }
        print("PASS: expanding changes only hierarchy; indentation and size sorting follow actual parent relationships")

        let savedExpansion = state.projectTreeExpansion.expandedPaths
        var filters = state.filters(for: .projectFiles); filters.search = "同名.txt"
        state.setFilters(filters, for: .projectFiles); tree = presentation()
        guard tree.matchingIDs.count == 2, tree.rows.count == 6,
              tree.rows.filter(\.isContext).count == 4, tree.rows.first?.isRoot == true,
              tree.rows.filter({ !$0.isContext }).map({ $0.item.title }) == ["同名.txt", "同名.txt"] else { fatalError("Search lost ancestor context or counted it as matches") }
        for row in tree.rows where row.isContext { state.toggleProjectSelection(row) }
        guard state.selected.isEmpty else { fatalError("Context ancestors can be selected") }
        let matchingFile = tree.rows.first { !$0.isContext }!
        state.toggleProjectSelection(matchingFile)
        guard state.selected == [matchingFile.id] else { fatalError("Matching file cannot be selected") }
        print("PASS: search preserves both paths for same-name files; context ancestors neither count nor become selected")

        state.toggleProjectExpansion(tree.rows.first!)
        guard presentation().rows.count == 1, state.projectTreeExpansion.expandedPaths == savedExpansion else { fatalError("Filtered collapse changed the unfiltered tree") }
        filters.search = ""; state.setFilters(filters, for: .projectFiles)
        guard presentation().rows.count > 1, state.projectTreeExpansion.expandedPaths == savedExpansion else { fatalError("Clearing search did not restore expansion") }
        filters.onlySelected = true; state.setFilters(filters, for: .projectFiles); tree = presentation()
        guard tree.matchingIDs == [matchingFile.id], tree.rows.filter({ !$0.isContext }).count == 1,
              tree.rows.filter(\.isContext).allSatisfy({ !$0.showsCheckbox(mode: .organize) }) else { fatalError("Only-selected tree expanded the deletion scope") }
        print("PASS: temporary filter expansion restores correctly and only-selected excludes contextual ancestor actions")

        filters.onlySelected = false; filters.category = .cache; state.setFilters(filters, for: .projectFiles); tree = presentation()
        guard tree.rows.count == 2, tree.rows.first?.isContext == true, tree.rows.last?.item.title == ".DS_Store",
              state.selected == [matchingFile.id] else { fatalError("Category filter lost parent or changed selection") }
        filters.category = nil; filters.tree = false; state.setFilters(filters, for: .projectFiles); tree = presentation()
        guard tree.flatRoot?.isRoot == true, tree.flatContents.allSatisfy({ !$0.isRoot }),
              state.selected == [matchingFile.id], preferences.object(forKey: "projectFileTree") as? Bool == false else { fatalError("Flat view duplicates the root or loses preference/selection") }
        let relaunched = SweepState(store: RecordStore(directory: sandbox.appendingPathComponent("other-records")), restorePreferences: false, preferences: preferences, defaultToolRoots: [:])
        guard !relaunched.filters(for: .projectFiles).tree else { fatalError("Saved display preference was not restored") }
        print("PASS: category filtering keeps context; flat sections separate root and contents and persist only the view preference")

        filters.tree = true; state.setFilters(filters, for: .projectFiles)
        state.scanProject(); try await wait(state)
        guard state.projectTreeExpansion.expandedPaths == savedExpansion, state.selected.isEmpty else { fatalError("Rescan lost valid expansion or retained stale choices") }
        try fm.removeItem(at: root.appendingPathComponent("素材/子目录"))
        state.scanProject(); try await wait(state)
        guard !state.projectTreeExpansion.expandedPaths.contains(root.appendingPathComponent("素材/子目录").path),
              state.projectTreeExpansion.expandedPaths.contains(root.appendingPathComponent("素材").path) else { fatalError("Rescan did not prune missing paths") }
        print("PASS: rescan retains surviving expansion paths and removes missing paths without reusing old selections")

        state.mode = .remove; try await wait(state); tree = presentation()
        guard tree.rows.first?.showsCheckbox(mode: .remove) == true,
              tree.rows.dropFirst().allSatisfy({ !$0.showsCheckbox(mode: .remove) && $0.status(mode: .remove) == "项目内文件" }) else { fatalError("Remove mode exposes child deletion or labels everything protected") }
        for row in tree.rows.dropFirst() { state.toggleProjectSelection(row) }
        guard state.selected.isEmpty else { fatalError("A child entered whole-project cleanup") }
        state.toggleProjectSelection(tree.rows[0]); state.prepareReview()
        guard state.review?.items.count == 1, state.review?.items.first?.path == root.path else { fatalError("Whole-project review is not scoped to the root") }
        print("PASS: only the root can be selected in remove mode; reviewing it yields one entire-project operation")

        let another = sandbox.appendingPathComponent("另一个项目")
        try fm.createDirectory(at: another, withIntermediateDirectories: true)
        state.acceptProject(another); try await wait(state)
        guard state.projectTreeExpansion.rootPath == another.path,
              state.projectTreeExpansion.expandedPaths == [another.path], state.selected.isEmpty,
              state.review == nil, state.filters(for: .projectFiles).tree else { fatalError("Project switch reused prior paths or cleanup") }
        print("PASS: switching projects resets expansion and cleanup while retaining the chosen presentation")

        var many: [CleanupItem] = []
        let largeRoot = CleanupItem(path: "/fixture", rootPath: "/fixture", reason: "fixture", isDirectory: true)
        many.append(largeRoot)
        for folder in 0..<100 {
            let parent = "/fixture/folder-\(folder)"
            many.append(CleanupItem(path: parent, rootPath: "/fixture", reason: "fixture", isDirectory: true, parentPath: "/fixture"))
            for file in 0..<100 { many.append(CleanupItem(path: parent + "/file-\(file).txt", rootPath: "/fixture", reason: "fixture", bytes: Int64(file), parentPath: parent)) }
        }
        var expansion = ProjectTreeExpansion(); expansion.reset(rootPath: "/fixture")
        let large = ProjectTree(items: many, matching: many, filters: BrowserFilters(), expansion: expansion)
        guard large.rows.count == 101, large.matchingIDs.count == 10_101 else { fatalError("Collapsed large tree materialized all descendants") }
        print("PASS: a 10,101-item inventory renders only the expanded level without filesystem traversal")
    }

    @MainActor private static func wait(_ state: SweepState) async throws {
        for _ in 0..<1_000 where state.busy { try await Task.sleep(for: .milliseconds(10)) }
        guard !state.busy, state.error == nil else { fatalError("Scan did not finish: \(state.error ?? "")") }
    }
}
