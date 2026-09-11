import Foundation

public enum SelectionPlanner {
    public static func makePlan(items: [CleanupItem], selectedIDs: Set<String>) throws -> CleanupPlan {
        let index = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var selected = selectedIDs
        var queue = Array(selectedIDs)
        while let id = queue.popLast() {
            guard let item = index[id], item.isSelectable else { throw CleanupError.unsafe("选择中包含已保护、不可用或过期的项目，请重新选择。") }
            for related in item.relatedIDs where !selected.contains(related) { selected.insert(related); queue.append(related) }
        }
        let chosen = selected.compactMap { index[$0] }.sorted { a, b in
            if a.path.count == b.path.count { return a.id < b.id }; return a.path.count < b.path.count
        }
        var result: [CleanupItem] = []
        for item in chosen {
            if item.action == .trash {
                if result.contains(where: { $0.action == .trash && $0.isDirectory && PathSafety.isWithin(item.path, root: $0.path) }) { continue }
                // Protected descendants cannot be hidden by selecting their parent.
                if item.isDirectory, items.contains(where: { child in
                    child.id != item.id && PathSafety.isWithin(child.path, root: item.path) && !child.isSelectable && item.metadata["projectMode"] != "remove"
                }) { throw CleanupError.unsafe("目录包含已保护的内容：\(item.title)") }
                guard item.snapshot != nil else { throw CleanupError.unsafe("缺少文件校验信息，请重新扫描。") }
            }
            result.append(item)
        }
        guard !result.isEmpty else { throw CleanupError.unsafe("请先选择需要清理的项目。") }
        for file in result where file.action == .trash {
            if result.contains(where: { session in
                session.action == .deleteSession && (session.path == file.path || (file.isDirectory && PathSafety.isWithin(session.path, root: file.path)))
            }) {
                throw CleanupError.unsafe("项目文件与会话记录的路径重叠。请先单独处理会话，再重新扫描项目，避免重复处理同一份数据。")
            }
        }
        return CleanupPlan(items: result)
    }
}
