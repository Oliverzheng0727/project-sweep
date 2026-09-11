import Foundation
import Darwin

/// Skill removal is deliberately separate from project and history cleanup. Its only
/// symbolic-link operation is to trash the authorized directory entry, never its target.
public struct SkillCleanupExecutor: Sendable {
    private let store: RecordStore
    public init(store: RecordStore = RecordStore()) { self.store = store }

    public func execute(_ plan: SkillRemovalPlan, authorizedRoots: [SkillRoot]) async -> [CleanupRecord] {
        var outcomes: [CleanupRecord] = []
        for entry in plan.entries {
            var record = CleanupRecord(batchID: plan.id, originalPath: entry.url.path, action: .trash,
                                       tool: entry.root.tool, status: .skipped, bytes: entry.bytes ?? 0,
                                       message: "准备移除技能；若操作中断，请在废纸篓中核实。")
            do {
                guard !Task.isCancelled, plan.roots == authorizedRoots else { throw CleanupError.changed("技能来源授权已变化，请重新扫描。") }
                try await store.append([record])
                let worker = Task.detached(priority: .userInitiated) {
                    try Self.move(entry, plan: plan)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                let intentID = record.id; record = result; record.id = intentID
            } catch { record.status = .failed; record.message = error.localizedDescription }
            do { try await store.replace(record) } catch { record.message += "；记录保存失败：\(error.localizedDescription)" }
            outcomes.append(record)
        }
        return outcomes
    }

    static func move(_ entry: SkillEntry, plan: SkillRemovalPlan) throws -> CleanupRecord {
        try Task.checkCancellation()
        for root in plan.roots {
            try SkillCatalog.validateRoot(root)
            let current = try Snapshotter.capture(root.url)
            guard let prior = plan.rootSnapshots[root.id], prior.device == current.device, prior.inode == current.inode else {
                throw CleanupError.changed("已连接的来源被替换，请重新扫描。")
            }
        }
        try SkillCatalog.validateRoot(entry.root)
        guard entry.selectable, entry.url.deletingLastPathComponent().path == entry.root.url.path,
              let snapshot = entry.snapshot else { throw CleanupError.unsafe("仅能移除已确认的个人技能或当前 AI 的直接引用。") }
        let currentRoot = try Snapshotter.capture(entry.root.url)
        guard currentRoot.device == entry.rootSnapshot.device, currentRoot.inode == entry.rootSnapshot.inode else {
            throw CleanupError.changed("技能来源目录已被替换，请重新扫描。")
        }
        let fresh = try SkillCatalog.inspect(entry.url, root: entry.root, rootSnapshot: currentRoot)
        guard fresh.removal == entry.removal, fresh.snapshot == snapshot, fresh.linkTarget == entry.linkTarget else {
            throw CleanupError.changed("技能或引用在扫描后发生变化，请重新扫描。")
        }
        if entry.removal == .directory {
            // Recheck all authorized references before moving an original directory.
            let inventory = try SkillCatalog.scanNow(plan.roots)
            guard inventory.complete, inventory.entries.first(where: { $0.id == entry.id })?.removal == .directory else {
                throw CleanupError.changed("技能共享关系无法完整核实或已改变，未移除原文件。")
            }
            try FileUseChecker.ensureUnused(entry.url, isDirectory: true)
            try PathSafety.validate(entry.url, within: entry.root.url)
        } else {
            // Never pass a link to lsof or to a recursive walker, both could follow it.
            try PathSafety.validate(entry.url.deletingLastPathComponent(), within: entry.root.url)
            guard try FileManager.default.destinationOfSymbolicLink(atPath: entry.url.path) == entry.linkTarget else {
                throw CleanupError.changed("技能引用已变化。")
            }
        }
        try Snapshotter.verify(entry.url, matches: snapshot)
        try Task.checkCancellation()
        var trashURL: NSURL?
        try FileManager.default.trashItem(at: entry.url, resultingItemURL: &trashURL)
        let destination = trashURL as URL?
        let trashState = destination.flatMap { try? Snapshotter.capture($0, recursive: entry.removal == .directory) }
        return CleanupRecord(batchID: plan.id, originalPath: entry.url.path, trashPath: destination?.path,
            action: .trash, tool: entry.root.tool, status: .succeeded, bytes: entry.bytes ?? 0,
            message: entry.removal == .reference ? "已移除 \(entry.root.tool.title) 的技能引用，共享原文件保留。重新启动工具后生效。"
                : "已将 \(entry.root.tool.title) 技能移入废纸篓，可从清理记录恢复。已加载的技能可能在当前会话中保留。",
            trashSnapshot: trashState, skillLinkTarget: entry.removal == .reference ? entry.linkTarget : nil)
    }
}
