import Foundation

public enum ProjectAssociations {
    /// Match recorded paths, then include every inseparable related session in the review scope.
    /// Global tool caches and sessions without any known relationship are not project candidates.
    public static func items(for project: URL, from inventory: [CleanupItem]) -> [CleanupItem] {
        let root = project.standardizedFileURL.path
        func belongs(_ item: CleanupItem) -> Bool {
            guard let path = item.projectPath, path.hasPrefix("/") else { return false }
            return PathSafety.isWithin(URL(fileURLWithPath: path).standardizedFileURL.path, root: root)
        }
        let index = Dictionary(inventory.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let knownIDs = Set(index.keys)
        let direct = Set(inventory.filter(belongs).map(\.id))
        var included = direct
        var pending = Array(direct)
        while let id = pending.popLast(), let item = index[id] {
            for related in item.relatedIDs where !included.contains(related) {
                included.insert(related)
                if index[related] != nil { pending.append(related) }
            }
        }
        return inventory.filter { included.contains($0.id) }.map { source in
            var item = source
            if !direct.contains(item.id) {
                item.details.insert("必须同时处理的关联会话；记录的项目：\(item.projectPath ?? "无法确定")", at: 0)
            }
            if !Set(item.relatedIDs).isSubset(of: knownIDs) {
                item.risk = .unavailable
                item.reason = "缺少关联会话，无法完整确认清理范围。"
            }
            return item
        }
    }
}
