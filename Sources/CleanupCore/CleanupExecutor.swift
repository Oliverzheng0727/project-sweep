import Foundation
import Darwin

public struct CleanupExecutor: Sendable {
    private let store: RecordStore
    private let deleteSessions: @Sendable ([CleanupItem], ToolConfiguration, UUID) async -> [CleanupRecord]
    private let ensureToolClosed: @Sendable (ToolKind) throws -> Void
    public init(store: RecordStore = RecordStore()) {
        self.store = store
        self.deleteSessions = { await ToolDataService().deleteSessions($0, configuration: $1, batchID: $2) }
        self.ensureToolClosed = { try ToolDataService.ensureClosed($0) }
    }

    // Internal fixture seam: public execution always uses the real adapters and process guard.
    init(store: RecordStore,
         deleteSessions: @escaping @Sendable ([CleanupItem], ToolConfiguration, UUID) async -> [CleanupRecord],
         ensureToolClosed: @escaping @Sendable (ToolKind) throws -> Void) {
        self.store = store; self.deleteSessions = deleteSessions; self.ensureToolClosed = ensureToolClosed
    }

    public func execute(_ plan: CleanupPlan, configurations: [ToolConfiguration],
                        progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [CleanupRecord] {
        var records: [CleanupRecord] = []
        var processedSessions = Set<String>()
        // Session batches verify their scanned tool root. Trash changes that root's
        // directory metadata, so finish selected sessions before moving selected caches.
        let ordered = plan.items.filter { $0.action == .deleteSession } + plan.items.filter { $0.action != .deleteSession }
        for item in ordered {
            if processedSessions.contains(item.id) { continue }
            if Task.isCancelled {
                let skipped = record(item, plan: plan, status: .skipped, message: "已取消，未处理此项。")
                try? await store.append([skipped]); records.append(skipped); continue
            }
            if item.action == .deleteSession {
                guard let tool = item.tool, let config = configurations.first(where: { $0.tool == tool }),
                      config.root.standardizedFileURL.resolvingSymlinksInPath().path == item.rootPath else {
                    let failed = record(item, plan: plan, status: .failed, message: "工具目录授权已变化，请重新扫描。")
                    try? await store.append([failed]); records.append(failed); continue
                }
                let group = plan.items.filter { $0.action == .deleteSession && $0.tool == tool }
                processedSessions.formUnion(group.map(\.id))
                do {
                    // A writable operation log is required before irreversible history operations.
                    let intent = group.map { record($0, plan: plan, status: .skipped, message: "会话清理准备执行；若应用中断，请重新扫描核实。") }
                    try await store.append(intent)
                    let result = await deleteSessions(group, config, plan.id)
                    var pending = intent
                    for outcome in result {
                        var saved = outcome
                        // Adapters may return child sessions first. Correlate by identity,
                        // never position, so partial completion updates the correct intent.
                        if let index = pending.firstIndex(where: {
                            $0.originalPath == outcome.originalPath && $0.tool == outcome.tool && $0.action == outcome.action
                        }) { saved.id = pending.remove(at: index).id }
                        do { try await store.replace(saved) }
                        catch { saved.message += "；操作记录保存失败：\(error.localizedDescription)" }
                        records.append(saved)
                    }
                } catch {
                    records += group.map { record($0, plan: plan, status: .failed, message: "无法准备操作记录，未删除：\(error.localizedDescription)") }
                }
            } else {
                var intent = record(item, plan: plan, status: .skipped, message: "准备移入废纸篓；若应用中断，可在系统废纸篓核实。")
                do {
                    try await store.append([intent])
                    if let tool = item.tool { try ensureToolClosed(tool) }
                    let worker = Task.detached(priority: .userInitiated) { try TrashService.move(item, batchID: plan.id) }
                    let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    let savedID = intent.id; intent = result; intent.id = savedID
                } catch {
                    intent.status = .failed; intent.message = error.localizedDescription
                }
                do { try await store.replace(intent) }
                catch { intent.message += "；记录保存失败：\(error.localizedDescription)" }
                records.append(intent)
            }
            progress?(records.count, plan.items.count)
        }
        return records
    }

    public func restore(_ record: CleanupRecord) async throws -> CleanupRecord {
        var restored = try await Task.detached(priority: .userInitiated) { try TrashService.restore(record) }.value
        // The physical restore has succeeded. A log failure must not re-offer a stale
        // restore action or imply that the file remains in Trash.
        do { try await store.replace(restored) }
        catch { restored.message += "；记录保存失败：\(error.localizedDescription)" }
        return restored
    }

    private func record(_ item: CleanupItem, plan: CleanupPlan, status: CleanupStatus, message: String) -> CleanupRecord {
        CleanupRecord(batchID: plan.id, originalPath: item.path, action: item.action, tool: item.tool, status: status, bytes: item.bytes, message: message)
    }
}

enum TrashService {
    static func move(_ item: CleanupItem, batchID: UUID) throws -> CleanupRecord {
        try Task.checkCancellation()
        guard item.isSelectable, item.action == .trash, let snapshot = item.snapshot else {
            throw CleanupError.unsafe("该项目缺少清理权限或扫描校验信息。")
        }
        let root = URL(fileURLWithPath: item.rootPath)
        try PathSafety.validate(item.url, within: root)
        if item.url.path == root.path, !PathSafety.canRemoveRoot(root) { throw CleanupError.unsafe("不能移除系统或通用资料目录。") }
        if let identity = item.metadata["rootIdentity"] {
            let current = try Snapshotter.capture(root)
            guard identity == "\(current.device):\(current.inode)" else { throw CleanupError.changed("项目根目录已被替换，请重新扫描。") }
        }
        if item.tool == nil, item.metadata["projectMode"] != "remove" {
            let tracked = try GitInventory.trackedFilesForSelection(item.url, isDirectory: item.isDirectory)
            guard !tracked.contains(where: { PathSafety.isWithin($0, root: item.path) }) else {
                throw CleanupError.changed("选择中出现 Git 已跟踪文件，请重新扫描。")
            }
        }
        try FileUseChecker.ensureUnused(item.url, isDirectory: item.isDirectory)
        try Snapshotter.verify(item.url, matches: snapshot)
        try PathSafety.validate(item.url, within: root)
        try Task.checkCancellation()
        var trashURL: NSURL?
        try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashURL)
        guard let destination = trashURL as URL? else {
            return CleanupRecord(batchID: batchID, originalPath: item.path, action: .trash, tool: item.tool, status: .succeeded,
                                 bytes: item.bytes, message: "已移入系统废纸篓，请在 Finder 中恢复。")
        }
        // Trash may update metadata, so capture its actual post-move state for restoration.
        let trashState = try? Snapshotter.capture(destination, recursive: snapshot.treeDigest != nil)
        return CleanupRecord(batchID: batchID, originalPath: item.path, trashPath: destination.path,
                             action: .trash, tool: item.tool, status: .succeeded, bytes: item.bytes,
                             message: "已移入废纸篓；清空废纸篓后才可能释放磁盘空间。", trashSnapshot: trashState)
    }

    static func restore(_ record: CleanupRecord) throws -> CleanupRecord {
        guard record.action == .trash, record.status == .succeeded, let path = record.trashPath, let snapshot = record.trashSnapshot else {
            throw CleanupError.unavailable("此记录不支持恢复。历史会话未保留备份。")
        }
        let source = URL(fileURLWithPath: path)
        let destination = URL(fileURLWithPath: record.originalPath)
        guard path.contains("/.Trash/") || path.contains("/.Trashes/") else { throw CleanupError.unsafe("记录中的废纸篓路径无效。") }
        if let target = record.skillLinkTarget {
            guard snapshot.mode & UInt32(S_IFMT) == UInt32(S_IFLNK), snapshot.treeDigest == nil else {
                throw CleanupError.unsafe("技能引用恢复信息无效。")
            }
            try PathSafety.validate(source.deletingLastPathComponent(), within: source.deletingLastPathComponent())
            guard try FileManager.default.destinationOfSymbolicLink(atPath: source.path) == target else {
                throw CleanupError.changed("废纸篓中的技能引用已变化，未恢复。")
            }
        } else {
            try PathSafety.validate(source, within: source.deletingLastPathComponent())
        }
        try Snapshotter.verify(source, matches: snapshot)
        try PathSafety.validate(destination.deletingLastPathComponent(), within: destination.deletingLastPathComponent())
        // Atomic no-replace rename. A newly-created destination is never overwritten.
        let result = renamex_np(source.path, destination.path, UInt32(RENAME_EXCL))
        guard result == 0 else {
            if errno == EEXIST { throw CleanupError.unsafe("原位置已有同名文件，未覆盖。请先在 Finder 中处理同名文件。") }
            throw CleanupError.io("恢复失败，文件仍在废纸篓：\(String(cString: strerror(errno)))")
        }
        var restored = record; restored.status = .restored; restored.message = "已恢复到原位置。"; return restored
    }
}

enum FileUseChecker {
    static func ensureUnused(_ url: URL, isDirectory: Bool) throws {
        try Task.checkCancellation()
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = isDirectory ? ["-t", "+D", url.path] : ["-t", "--", url.path]
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-file-use-" + UUID().uuidString)
        let descriptor = open(outputURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CleanupError.unavailable("无法准备文件占用检查。") }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        process.waitUntilExit(); timeout.cancel()
        try Task.checkCancellation()
        // lsof can print matching PIDs and still exit 1 when some +D entries or
        // process information are unavailable. Output is evidence of use regardless
        // of the exit status; exit 1 alone must never override a reported match.
        if try Snapshotter.capture(outputURL).size > 0 || process.terminationStatus == 0 {
            throw CleanupError.unavailable("文件或目录正被其他程序使用，请关闭后再清理：\(url.lastPathComponent)")
        }
        guard process.terminationReason == .exit, process.terminationStatus == 1 else {
            throw CleanupError.unavailable("无法确认文件占用状态，未执行清理。")
        }
    }
}
