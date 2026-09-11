import Foundation
import CryptoKit
import Darwin

struct ClaudeAdapter {
    static let journalName = ".project-sweep-transaction"
    static func scan(_ configuration: ToolConfiguration, warnings: inout [String], status: inout ToolScanStatus) throws -> [CleanupItem] {
        let root = configuration.root
        status.sessionDeletion = .available
        guard !ToolFiles.exists(root.appendingPathComponent(journalName)) else {
            status.requiresRecovery = true
            status.sessionDeletion = .unavailable
            throw CleanupError.unavailable("发现未完成的 Claude 清理事务，请先恢复事务后重新扫描")
        }
        let projects = root.appendingPathComponent("projects")
        guard ToolFiles.exists(projects) else {
            status.sessionRead = .unsupported; status.sessionDeletion = .unavailable
            status.message = "未找到 Claude 项目记录目录，请检查授权位置"
            return []
        }
        try PathSafety.validate(projects, within: root)
        let history = root.appendingPathComponent("history.jsonl")
        var historyValid = true
        if ToolFiles.exists(history) {
            try PathSafety.validate(history, within: root)
            historyValid = (try? ToolFiles.jsonLines(history, root: root).allSatisfy { $0.1["sessionId"] is String }) == true
        }
        var containerSnapshots: [String: String] = [:]
        for container in ["file-history", "session-env", "tasks", "todos"] {
            let path = root.appendingPathComponent(container)
            if ToolFiles.exists(path) { try PathSafety.validate(path, within: root) }
            containerSnapshots["container:" + container] = ToolFiles.exists(path) ? try ToolFiles.stamp(path) : "absent"
        }
        var items: [CleanupItem] = []
        for project in try ToolFiles.children(projects) {
            try Task.checkCancellation()
            try PathSafety.validate(project, within: root)
            guard (try project.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { continue }
            let projectStamp = try ToolFiles.stamp(project)
            let index = project.appendingPathComponent("sessions-index.json")
            var indexValid = true
            if ToolFiles.exists(index) { indexValid = (try? validatedIndex(index, root: root)) != nil }
            if !indexValid || !historyValid { status.sessionRead = .partial }
            for transcript in try ToolFiles.children(project) where transcript.pathExtension == "jsonl" {
                do {
                    let sessionID = transcript.deletingPathExtension().lastPathComponent
                    guard UUID(uuidString: sessionID) != nil else { throw CleanupError.unavailable("未知 Claude 会话文件名") }
                    var item = try ToolFiles.make(transcript, root: root, tool: .claude, category: .session, risk: .review, reason: "永久删除会话、关联快照及该会话的历史索引条目")
                    item.id = "claude:session:\(sessionID)"; item.sessionID = sessionID; item.action = .deleteSession; item.title = "会话 \(sessionID.prefix(8))"
                    let rows = try ToolFiles.jsonLines(transcript, root: root)
                    let identifiers = Set(rows.compactMap { $0.1["sessionId"] as? String })
                    let directories = Set(rows.compactMap { $0.1["cwd"] as? String })
                    let knownTypes: Set<String> = ["user", "assistant", "system", "progress", "summary", "file-history-snapshot", "queue-operation", "last-prompt", "custom-title", "tag", "agent-name", "pr-link", "saved_hook_context", "attribution-snapshot", "attachment", "mode", "permission-mode", "atis-latch", "ai-title", "bridge-session", "file-history-delta", "cost-state"]
                    guard !rows.isEmpty, identifiers == [sessionID], directories.count == 1,
                          let cwd = directories.first, cwd.hasPrefix("/"),
                          rows.allSatisfy({ ($0.1["type"] as? String).map(knownTypes.contains) == true }) else {
                        throw CleanupError.unavailable("会话项目路径或记录格式未验证")
                    }
                    item.projectPath = URL(fileURLWithPath: cwd).standardizedFileURL.path
                    if let title = rows.reversed().compactMap({ ($0.1["customTitle"] as? String) ?? ($0.1["aiTitle"] as? String) }).first, !title.isEmpty {
                        item.title = title
                    }
                    var associated: [URL] = []
                    for base in [project, root.appendingPathComponent("file-history"), root.appendingPathComponent("session-env"), root.appendingPathComponent("tasks")] {
                        let path = base.appendingPathComponent(sessionID)
                        if ToolFiles.exists(path) { try PathSafety.validate(path, within: root); associated.append(path) }
                    }
                    // Standalone subagent transcripts in older formats cannot be safely assigned by name.
                    if try ToolFiles.children(project).contains(where: { $0.lastPathComponent.hasPrefix("agent-") && $0.pathExtension == "jsonl" }) {
                        item.risk = .unavailable; item.reason = "旧版独立子代理文件无法完整关联，保持只读"
                    }
                    let todos = root.appendingPathComponent("todos")
                    if ToolFiles.exists(todos) {
                        try PathSafety.validate(todos, within: root)
                        associated += try ToolFiles.children(todos).filter { $0.lastPathComponent.hasPrefix(sessionID + "-agent-") && $0.pathExtension == "json" }
                    }
                    // Plans can be shared across sessions. Do not mutate sessions with plan-file references.
                    if rows.contains(where: { containsKey("planFilePath", in: $0.1) }) { item.risk = .unavailable; item.reason = "会话引用计划文件，无法确认共享依赖，保持只读" }
                    item.metadata["associated"] = String(decoding: try JSONEncoder().encode(associated.map(\.path)), as: UTF8.self)
                    for (offset, path) in associated.enumerated() {
                        let linked = try ToolFiles.make(path, root: root, tool: .claude, category: .session, risk: .review, reason: "会话关联数据")
                        item.bytes += linked.bytes; item.metadata["associatedSnapshot\(offset)"] = try ToolFiles.stamp(path)
                        item.details.append("关联：\(path.path)")
                    }
                    item.metadata.merge(containerSnapshots) { _, new in new }
                    item.metadata["projectSnapshot"] = projectStamp
                    item.metadata["indexSnapshot"] = ToolFiles.exists(index) ? try ToolFiles.stamp(index) : "absent"
                    item.metadata["historySnapshot"] = ToolFiles.exists(history) ? try ToolFiles.stamp(history) : "absent"
                    if !historyValid || !indexValid { item.risk = .unavailable; item.reason = "历史索引格式未知或损坏，保持只读" }
                    items.append(item)
                } catch {
                    status.sessionRead = .partial
                    warnings.append("\(transcript.lastPathComponent)：\(error.localizedDescription)")
                    if var item = try? ToolFiles.make(transcript, root: root, tool: .claude, category: .session, risk: .unavailable, reason: "会话格式或关联关系未验证") {
                        item.action = .deleteSession; items.append(item)
                    }
                }
            }
            let memory = project.appendingPathComponent("memory")
            if ToolFiles.exists(memory) {
                var memoryItem = try ToolFiles.make(memory, root: root, tool: .claude, category: .projectMemory, risk: .protected, reason: "项目记忆独立保护，不随会话删除")
                let knownProjects = Set(items.filter { $0.url.deletingLastPathComponent().path == project.path }.compactMap(\.projectPath))
                if knownProjects.count == 1 { memoryItem.projectPath = knownProjects.first }
                items.append(memoryItem)
            }
        }
        let duplicateIDs = Set(Dictionary(grouping: items.compactMap(\.sessionID), by: { $0 }).filter { $0.value.count > 1 }.keys)
        for index in items.indices where items[index].sessionID.map(duplicateIDs.contains) == true {
            items[index].risk = .unavailable; items[index].reason = "跨项目重复会话标识，无法安全划分历史索引"
        }
        if !historyValid || items.contains(where: { $0.action == .deleteSession && $0.risk == .unavailable }) { status.sessionRead = .partial }
        if status.sessionRead == .partial { status.message = "部分会话、索引或关联关系无法完整检查" }
        return items
    }
    private static func containsKey(_ key: String, in object: Any) -> Bool {
        if let dictionary = object as? [String: Any] { return dictionary[key] != nil || dictionary.values.contains { containsKey(key, in: $0) } }
        if let array = object as? [Any] { return array.contains { containsKey(key, in: $0) } }
        return false
    }
    static func validatedIndex(_ url: URL, root: URL) throws -> [String: Any] {
        try PathSafety.validate(url, within: root)
        guard let object = try JSONSerialization.jsonObject(with: ToolFiles.read(url, root: root)) as? [String: Any],
              object["version"] as? Int == 1, let entries = object["entries"] as? [[String: Any]],
              entries.allSatisfy({ ($0["sessionId"] as? String).flatMap(UUID.init(uuidString:)) != nil }),
              Set(entries.compactMap { $0["sessionId"] as? String }).count == entries.count else { throw CleanupError.unavailable("不支持的 Claude 会话索引") }
        return object
    }
    static func delete(_ items: [CleanupItem], configuration: ToolConfiguration, ensureClosed: () throws -> Void = { try ToolDataService.ensureClosed(.claude) }) throws {
        let root = configuration.root
        guard !ToolFiles.exists(root.appendingPathComponent(journalName)) else { throw CleanupError.unavailable("存在未完成事务，必须先恢复") }
        var paths: [URL] = []; var replacements: [String: Data] = [:]
        var expectedSnapshots: [String: FileSnapshot] = [:]
        let ids = Set(items.compactMap(\.sessionID))
        guard ids.count == items.count else { throw CleanupError.unsafe("会话标识不完整或重复") }
        for item in items {
            guard let snapshot = item.snapshot else { throw CleanupError.changed("缺少会话快照") }
            expectedSnapshots[item.path] = snapshot
            for container in ["file-history", "session-env", "tasks", "todos"] {
                let path = root.appendingPathComponent(container)
                if item.metadata["container:" + container] == "absent" {
                    guard !ToolFiles.exists(path) else { throw CleanupError.changed("关联数据目录已改变，请重新扫描") }
                } else {
                    try PathSafety.validate(path, within: root)
                    try ToolFiles.verifyStamp(path, item.metadata["container:" + container])
                }
            }
            let project = item.url.deletingLastPathComponent()
            try ToolFiles.verifyStamp(project, item.metadata["projectSnapshot"])
            guard let text = item.metadata["associated"] else { throw CleanupError.changed("缺少关联快照") }
            let associated = try JSONDecoder().decode([String].self, from: Data(text.utf8))
            for (offset, path) in associated.enumerated() {
                let url = URL(fileURLWithPath: path); try PathSafety.validate(url, within: root)
                let expected = try ToolFiles.decodeStamp(item.metadata["associatedSnapshot\(offset)"])
                try Snapshotter.verify(url, matches: expected)
                expectedSnapshots[path] = expected
                paths.append(url)
            }
            paths.append(item.url)
            let index = project.appendingPathComponent("sessions-index.json")
            if item.metadata["indexSnapshot"] == "absent" {
                guard !ToolFiles.exists(index) else { throw CleanupError.changed("会话索引已改变") }
            } else {
                let expected = try ToolFiles.decodeStamp(item.metadata["indexSnapshot"])
                try Snapshotter.verify(index, matches: expected)
                expectedSnapshots[index.path] = expected
            }
            if ToolFiles.exists(index), replacements[index.path] == nil {
                var object = try validatedIndex(index, root: root)
                object["entries"] = (object["entries"] as! [[String: Any]]).filter { !ids.contains($0["sessionId"] as! String) }
                replacements[index.path] = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            }
            let history = root.appendingPathComponent("history.jsonl")
            if item.metadata["historySnapshot"] == "absent" {
                guard !ToolFiles.exists(history) else { throw CleanupError.changed("历史索引已改变") }
            } else {
                let expected = try ToolFiles.decodeStamp(item.metadata["historySnapshot"])
                try Snapshotter.verify(history, matches: expected)
                expectedSnapshots[history.path] = expected
            }
        }
        let history = root.appendingPathComponent("history.jsonl")
        if ToolFiles.exists(history) {
            let rows = try ToolFiles.jsonLines(history, root: root)
            guard rows.allSatisfy({ $0.1["sessionId"] is String }) else { throw CleanupError.unavailable("未知历史索引格式") }
            var output = Data()
            for (line, object) in rows where !ids.contains(object["sessionId"] as! String) { output.append(line); output.append(10) }
            replacements[history.path] = output
        }
        try ensureClosed()
        try ClaudeTransaction.apply(root: root, removals: paths, replacements: replacements, expectedSnapshots: expectedSnapshots, ensureClosed: ensureClosed)
    }
}

/// A temporary rollback journal, removed on success; never copied to the operation record.
/// Recovery only rolls back interrupted, uncommitted operations and refuses collisions.
struct ClaudeTransaction {
    struct Entry: Codable { var path: String; var slot: String; var replacement: Bool; var replacementDigest: String?; var snapshot: FileSnapshot }
    struct Manifest: Codable { var entries: [Entry]; var committed: Bool }
    static func apply(root: URL, removals: [URL], replacements: [String: Data], expectedSnapshots: [String: FileSnapshot]? = nil, ensureClosed: () throws -> Void = {}) throws {
        let fm = FileManager.default; let journal = root.appendingPathComponent(ClaudeAdapter.journalName)
        guard !ToolFiles.exists(journal) else { throw CleanupError.unavailable("存在未完成事务") }
        let paths = Array(Set(removals.map(\.path) + replacements.keys)).sorted()
        for path in paths { try PathSafety.validate(URL(fileURLWithPath: path), within: root) }
        guard !paths.contains(where: { parent in paths.contains { $0 != parent && $0.hasPrefix(parent + "/") } }) else { throw CleanupError.unsafe("关联数据路径重叠") }
        let entries = try paths.enumerated().map { offset, path in
            let original = URL(fileURLWithPath: path)
            let snapshot: FileSnapshot
            if let expectedSnapshots {
                guard let expected = expectedSnapshots[path] else { throw CleanupError.changed("缺少事务原始快照") }
                snapshot = expected
            } else { snapshot = try Snapshotter.capture(original, recursive: true) }
            try Snapshotter.verify(original, matches: snapshot)
            return Entry(path: path, slot: String(offset), replacement: replacements[path] != nil,
                         replacementDigest: replacements[path].map { digest($0) }, snapshot: snapshot)
        }
        let manifestURL = journal.appendingPathComponent("manifest.json")
        try fm.createDirectory(at: journal, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var committed = false
        do {
            try JSONEncoder().encode(Manifest(entries: entries, committed: false)).write(to: manifestURL, options: .atomic)
            for entry in entries {
                try ensureClosed()
                let original = URL(fileURLWithPath: entry.path)
                try PathSafety.validate(original, within: root)
                try Snapshotter.verify(original, matches: entry.snapshot)
                try fm.moveItem(at: original, to: journal.appendingPathComponent(entry.slot))
                if let data = replacements[entry.path] { try data.write(to: original, options: .atomic) }
            }
            try JSONEncoder().encode(Manifest(entries: entries, committed: true)).write(to: manifestURL, options: .atomic)
            committed = true
            try cleanupCommitted(root: root, journal: journal, manifest: Manifest(entries: entries, committed: true))
        } catch {
            do { try recover(root: root, ensureClosed: ensureClosed) } catch { throw CleanupError.io("清理中断且自动回滚未完成；保留临时事务以便恢复") }
            if committed { return }
            throw CleanupError.io("清理失败，原会话已回滚")
        }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func recover(root: URL, ensureClosed: () throws -> Void = {}) throws {
        let fm = FileManager.default; let journal = root.appendingPathComponent(ClaudeAdapter.journalName)
        try PathSafety.validate(journal, within: root)
        let manifestURL = journal.appendingPathComponent("manifest.json")
        if !ToolFiles.exists(manifestURL) {
            // A crash can occur just before initial manifest creation or after final removal.
            guard try fm.contentsOfDirectory(atPath: journal.path).isEmpty else { throw CleanupError.unsafe("事务缺少清单，保留待人工检查") }
            guard rmdir(journal.path) == 0 else { throw CleanupError.io("无法清理空事务目录") }
            return
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: ToolFiles.read(manifestURL, root: root, limit: 16 * 1024 * 1024))
        guard Set(manifest.entries.map(\.path)).count == manifest.entries.count,
              Set(manifest.entries.map(\.slot)).count == manifest.entries.count,
              manifest.entries.allSatisfy({ entry in
                  guard let slot = Int(entry.slot), slot >= 0, String(slot) == entry.slot else { return false }
                  let path = URL(fileURLWithPath: entry.path)
                  return entry.path.hasPrefix("/") && !path.pathComponents.contains("..")
                      && PathSafety.isWithin(path.path, root: root.path) && path.path != root.path
                      && !PathSafety.isWithin(path.path, root: journal.path)
              }) else { throw CleanupError.unsafe("事务清单无效") }
        if manifest.committed {
            try cleanupCommitted(root: root, journal: journal, manifest: manifest)
            return
        }
        for entry in manifest.entries {
            try PathSafety.validate(URL(fileURLWithPath: entry.path).deletingLastPathComponent(), within: root)
            if ToolFiles.exists(journal.appendingPathComponent(entry.slot)) {
                try PathSafety.validate(journal.appendingPathComponent(entry.slot), within: root)
                try Snapshotter.verify(journal.appendingPathComponent(entry.slot), matches: entry.snapshot)
            }
        }
        for entry in manifest.entries.reversed() {
            try ensureClosed()
            let saved = journal.appendingPathComponent(entry.slot); let original = URL(fileURLWithPath: entry.path)
            guard ToolFiles.exists(saved) else { continue }
            if ToolFiles.exists(original) {
                guard entry.replacement else { throw CleanupError.changed("回滚目标已有文件，禁止覆盖") }
                guard try digest(ToolFiles.read(original, root: root)) == entry.replacementDigest else { throw CleanupError.changed("回滚索引已被其他程序修改，禁止覆盖") }
                try fm.removeItem(at: original)
            }
            try fm.moveItem(at: saved, to: original)
        }
        // Slots have all been restored; leave only the manifest until the final step.
        try fm.removeItem(at: manifestURL)
        guard rmdir(journal.path) == 0 else { throw CleanupError.io("事务目录仍有未知内容，未移除") }
    }
    static func cleanupCommitted(root: URL, journal: URL, manifest: Manifest,
                                 afterSlot: () throws -> Void = {}) throws {
        let fm = FileManager.default
        try PathSafety.validate(journal, within: root)
        let allowed = Set(manifest.entries.map(\.slot) + ["manifest.json"])
        guard try Set(fm.contentsOfDirectory(atPath: journal.path)).isSubset(of: allowed) else { throw CleanupError.unsafe("事务目录包含未知文件，保留待检查") }
        for entry in manifest.entries {
            let saved = journal.appendingPathComponent(entry.slot)
            guard ToolFiles.exists(saved) else { continue }
            try PathSafety.validate(saved, within: root)
            // Committed slots may already be partially removed. Validate safety, not old digest.
            _ = try Snapshotter.capture(saved, recursive: true)
            try fm.removeItem(at: saved)
            try afterSlot()
        }
        let manifestURL = journal.appendingPathComponent("manifest.json")
        if ToolFiles.exists(manifestURL) { try PathSafety.validate(manifestURL, within: root); try fm.removeItem(at: manifestURL) }
        guard rmdir(journal.path) == 0 else { throw CleanupError.io("事务目录仍有未知内容，未移除") }
    }
}
