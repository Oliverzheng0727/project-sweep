import CleanupCore
import Foundation

struct ProjectTreeExpansion {
    private(set) var rootPath: String?
    var expandedPaths: Set<String> = []
    var filteredCollapsedPaths: Set<String> = []

    mutating func reset(rootPath: String?) {
        self.rootPath = rootPath
        expandedPaths = Set(rootPath.map { [$0] } ?? [])
        filteredCollapsedPaths = []
    }

    mutating func reconcile(items: [CleanupItem]) {
        guard let root = items.first(where: { $0.tool == nil && $0.path == $0.rootPath }) else { return }
        if rootPath != root.path { reset(rootPath: root.path) }
        let directories = Set(items.filter { $0.tool == nil && $0.isDirectory }.map(\.path))
        expandedPaths.formIntersection(directories)
        filteredCollapsedPaths.formIntersection(directories)
    }

    mutating func toggle(_ row: ProjectTreeRow, filtering: Bool) {
        guard row.hasChildren else { return }
        if filtering {
            if row.isExpanded { filteredCollapsedPaths.insert(row.item.path) }
            else { filteredCollapsedPaths.remove(row.item.path) }
        } else {
            if row.isExpanded { expandedPaths.remove(row.item.path) }
            else { expandedPaths.insert(row.item.path) }
        }
    }
}

struct ProjectTreeRow: Identifiable {
    let item: CleanupItem
    var depth = 0
    var isContext = false
    var hasChildren = false
    var isExpanded = false
    var id: String { item.id }
    var isRoot: Bool { item.tool == nil && item.path == item.rootPath }
    var icon: String { isRoot ? "square.stack.3d.up.fill" : item.isDirectory ? "folder.fill" : "doc" }
    func showsCheckbox(mode: ProjectMode) -> Bool { !isContext && (mode != .remove || isRoot) }
    func explanation(mode: ProjectMode) -> String {
        if isContext { return "用于定位匹配内容，不加入清理选择。" }
        if mode == .remove && !isRoot { return "移除整个项目时，此项将一同移入废纸篓。" }
        return item.reason
    }
    func status(mode: ProjectMode) -> String {
        if isContext { return "所在目录" }
        if mode == .remove && !isRoot { return "项目内文件" }
        if mode == .organize && isRoot { return "根目录保留" }
        return item.risk.title
    }
}

/// A presentation of existing scan results only; never traverses the filesystem.
struct ProjectTree {
    let rows: [ProjectTreeRow]
    let flatRoot: ProjectTreeRow?
    let flatContents: [ProjectTreeRow]
    let matchingIDs: Set<String>
    var displayedIDs: Set<String> { Set(rows.filter { !$0.isContext }.map(\.id)) }

    init(items: [CleanupItem], matching: [CleanupItem], filters: BrowserFilters, expansion: ProjectTreeExpansion) {
        let project = items.filter { $0.tool == nil }
        let index = Dictionary(project.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(matching.map(\.id))
        matchingIDs = ids
        let root = project.first { $0.path == $0.rootPath }
        flatRoot = matching.isEmpty ? nil : root.map { ProjectTreeRow(item: $0, isContext: filters.hasQuery && !ids.contains($0.id)) }
        flatContents = matching.filter { $0.path != $0.rootPath }.map { ProjectTreeRow(item: $0) }

        var included = Set(matching.map(\.path))
        var ancestors: Set<String> = []
        for match in matching {
            var parent = match.parentPath
            while let path = parent, let ancestor = index[path], ancestors.insert(path).inserted {
                included.insert(path)
                parent = ancestor.parentPath
            }
        }
        let visible = project.filter { included.contains($0.path) }
        let children = Dictionary(grouping: visible) { $0.parentPath ?? "" }
            .mapValues { $0.sorted(by: filters.sortsBefore) }
        let roots = visible.filter { $0.parentPath == nil || !included.contains($0.parentPath!) }
            .sorted { left, right in
                if (left.path == left.rootPath) != (right.path == right.rootPath) { return left.path == left.rootPath }
                return filters.sortsBefore(left, right)
            }
        let expanded = filters.hasQuery
            ? expansion.expandedPaths.union(ancestors).subtracting(expansion.filteredCollapsedPaths)
            : expansion.expandedPaths
        var stack = roots.reversed().map { ($0, 0) }
        var visited: Set<String> = []; var output: [ProjectTreeRow] = []
        while let (item, depth) = stack.popLast() {
            guard visited.insert(item.path).inserted else { continue }
            let descendants = children[item.path] ?? []
            let isExpanded = !descendants.isEmpty && expanded.contains(item.path)
            output.append(ProjectTreeRow(item: item, depth: depth, isContext: !matchingIDs.contains(item.id),
                                         hasChildren: !descendants.isEmpty, isExpanded: isExpanded))
            if isExpanded { stack.append(contentsOf: descendants.reversed().map { ($0, depth + 1) }) }
        }
        rows = output
    }
}
