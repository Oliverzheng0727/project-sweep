import Foundation

struct CodexAdapter {
    static func resolveExecutable(_ requested: String?) -> String? {
        if let requested, !requested.isEmpty { return requested }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", home + "/.npm-global/bin", home + "/.local/bin", home + "/.volta/bin"]
        return directories.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent("codex").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func capability(_ requested: String?) -> Bool {
        guard let executable = resolveExecutable(requested), FileManager.default.isExecutableFile(atPath: executable) else { return false }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-protocol-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = temporary.path
            _ = try ToolCommand.run(executable, ["app-server", "generate-json-schema", "--experimental", "--out", temporary.appendingPathComponent("schema").path], environment: environment)
            let requestData = try Data(contentsOf: temporary.appendingPathComponent("schema/ClientRequest.json"))
            let request = try JSONSerialization.jsonObject(with: requestData) as? [String: Any]
            let definitions = request?["definitions"] as? [String: Any]
            let params = definitions?["ThreadDeleteParams"] as? [String: Any]
            let required = params?["required"] as? [String]
            return required == ["threadId"] && String(decoding: requestData, as: UTF8.self).contains("\"thread/delete\"")
        } catch { return false }
    }
    static func scan(_ configuration: ToolConfiguration, warnings: inout [String], status: inout ToolScanStatus) throws -> [CleanupItem] {
        let root = configuration.root
        let databases = try ToolFiles.children(root).filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
        guard databases.count == 1, let database = databases.first else {
            status.sessionRead = .unsupported
            status.message = "Codex 状态数据库缺失或版本不唯一，未能完整检查会话"
            warnings.append("Codex 状态数据库缺失或版本不唯一，会话保持只读")
            return []
        }
        let supported = capability(resolveExecutable(configuration.executablePath))
        status.sessionDeletion = supported ? .available : .unavailable
        if !supported { warnings.append("当前 Codex 可执行程序未验证 thread/delete 能力，会话保持只读") }
        let inventory = try readInventory(database, root: root)
        let rows = inventory.rows
        let databaseStamp = inventory.databaseStamp
        let walStamp = inventory.walStamp
        var items: [CleanupItem] = []; var incomplete = false
        for row in rows {
            guard let id = row["id"], UUID(uuidString: id) != nil, let path = row["rollout_path"],
                  let cwd = row["cwd"], cwd.hasPrefix("/"), let rawSource = row["source"] else { throw CleanupError.unavailable("Codex 会话元数据不完整，禁止删除") }
            let url = URL(fileURLWithPath: path)
            guard ToolFiles.exists(url) else { warnings.append("会话 \(id) 的记录文件缺失"); incomplete = true; continue }
            var item = try ToolFiles.make(url, root: root, tool: .codex, category: .session, risk: supported ? .review : .unavailable, reason: "通过官方 thread/delete 永久删除本地会话")
            item.id = "codex:session:\(id)"; item.sessionID = id; item.projectPath = URL(fileURLWithPath: cwd).standardizedFileURL.path
            item.title = row["title"].flatMap { $0.isEmpty ? nil : $0 } ?? "会话 \(id.prefix(8))"; item.action = .deleteSession
            if let value = row["updated_at"].flatMap(Double.init) { item.modifiedAt = Date(timeIntervalSince1970: value) }
            item.metadata["database"] = database.path; item.metadata["databaseSnapshot"] = databaseStamp
            item.metadata["walSnapshot"] = walStamp
            let source = (try? JSONSerialization.jsonObject(with: Data(rawSource.utf8), options: [.fragmentsAllowed])) as? String ?? rawSource
            if source.hasPrefix("{") {
                guard let object = try JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any] else { throw CleanupError.unavailable("未知 Codex 关联结构") }
                if let parent = parentID(object) { item.metadata["parentID"] = parent }
                else { incomplete = true; item.risk = .unavailable; item.reason = "未知会话来源或依赖格式，保持只读" }
            } else if !["cli", "vscode", "exec", "appServer", "app-server"].contains(source) {
                incomplete = true; item.risk = .unavailable; item.reason = "未知会话来源，保持只读"
            }
            items.append(item)
        }
        if incomplete {
            for index in items.indices { items[index].risk = .unavailable; items[index].reason = "会话库存不完整，无法确认全部依赖，保持只读" }
        }
        let ids = Set(items.compactMap(\.sessionID))
        for i in items.indices {
            if let parent = items[i].metadata["parentID"] {
                guard ids.contains(parent) else { incomplete = true; items[i].risk = .unavailable; items[i].reason = "父会话缺失，无法确认依赖"; continue }
                // Treat a parent and all spawned descendants as an inseparable group.
                items[i].relatedIDs.append("codex:session:\(parent)")
                if let index = items.firstIndex(where: { $0.sessionID == parent }) { items[index].relatedIDs.append(items[i].id) }
            }
        }
        if incomplete { status.sessionRead = .partial; status.message = "部分会话或关联关系无法完整检查" }
        return items
    }
    /// Baseline the complete inventory before any query and refuse a mixed-version result.
    static func readInventory(_ database: URL, root: URL, afterRead: () throws -> Void = {}) throws
        -> (rows: [[String: String]], databaseStamp: String, walStamp: String) {
        _ = try ToolFiles.regularFile(database, root: root)
        let databaseStamp = try ToolFiles.stamp(database)
        let wal = URL(fileURLWithPath: database.path + "-wal")
        let walStamp: String
        if ToolFiles.exists(wal) {
            _ = try ToolFiles.regularFile(wal, root: root)
            walStamp = try ToolFiles.stamp(wal)
        } else { walStamp = "absent" }
        let db = try ToolDatabase(database, root: root)
        let columns = Set(try db.rows("PRAGMA table_info(threads)").compactMap { $0["name"] })
        let titleColumn = columns.contains("title") ? ", title" : ""
        let rows = try db.rows("SELECT id, rollout_path, cwd, source, updated_at" + titleColumn + " FROM threads")
        try afterRead()
        try PathSafety.validate(database, within: root)
        try ToolFiles.verifyStamp(database, databaseStamp)
        if walStamp == "absent" {
            guard !ToolFiles.exists(wal) else { throw CleanupError.changed("Codex 数据库在扫描中发生变化，请重新扫描") }
        } else {
            try PathSafety.validate(wal, within: root)
            try ToolFiles.verifyStamp(wal, walStamp)
        }
        return (rows, databaseStamp, walStamp)
    }
    static func parentID(_ object: [String: Any]) -> String? {
        // SQLite's stored enum uses subagent; the published app-server representation uses subAgent.
        guard object.count == 1,
              let source = (object["subagent"] ?? object["subAgent"]) as? [String: Any], source.count == 1,
              let spawn = source["thread_spawn"] as? [String: Any],
              let parent = spawn["parent_thread_id"] as? String, UUID(uuidString: parent) != nil,
              let depth = spawn["depth"] as? Int, depth >= 0,
              Set(spawn.keys).isSubset(of: ["parent_thread_id", "depth", "agent_nickname", "agent_role", "agent_path"]) else { return nil }
        return parent
    }
    static func delete(_ items: [CleanupItem], configuration: ToolConfiguration, batchID: UUID) throws -> [CleanupRecord] {
        guard let executable = resolveExecutable(configuration.executablePath), capability(executable) else { throw CleanupError.unavailable("Codex 未提供已验证的 thread/delete") }
        for item in items {
            guard let path = item.metadata["database"] else { throw CleanupError.changed("缺少数据库快照") }
            let database = URL(fileURLWithPath: path)
            try PathSafety.validate(database, within: configuration.root)
            try ToolFiles.verifyStamp(database, item.metadata["databaseSnapshot"])
            let wal = URL(fileURLWithPath: path + "-wal")
            if item.metadata["walSnapshot"] == "absent" {
                guard !ToolFiles.exists(wal) else { throw CleanupError.changed("Codex 数据库已改变，请重新扫描") }
            } else { try PathSafety.validate(wal, within: configuration.root); try ToolFiles.verifyStamp(wal, item.metadata["walSnapshot"]) }
        }
        try ToolDataService.ensureClosed(.codex)
        let rpc = try CodexRPC(executable: executable, root: configuration.root)
        defer { rpc.close() }
        _ = try rpc.request("initialize", params: ["clientInfo": ["name": "project_sweep", "version": "1.0"], "capabilities": ["experimentalApi": true]])
        try rpc.notify("initialized")
        let parents = Dictionary(uniqueKeysWithValues: items.compactMap { item in item.sessionID.map { ($0, item.metadata["parentID"]) } })
        func depth(_ item: CleanupItem) throws -> Int {
            var seen = Set<String>(); var cursor = item.sessionID; var count = 0
            while let id = cursor {
                guard seen.insert(id).inserted else { throw CleanupError.unsafe("会话依赖存在循环") }
                cursor = parents[id] ?? nil; count += 1
            }
            return count
        }
        let ordered = try items.map { ($0, try depth($0)) }.sorted { $0.1 > $1.1 }.map(\.0)
        var records: [CleanupRecord] = []
        for item in ordered {
            do {
                try ToolDataService.ensureClosed(.codex, excluding: [rpc.process.processIdentifier])
                try PathSafety.validate(item.url, within: configuration.root)
                guard let snapshot = item.snapshot, let id = item.sessionID else { throw CleanupError.changed("缺少会话快照") }
                try Snapshotter.verify(item.url, matches: snapshot)
                _ = try rpc.request("thread/delete", params: ["threadId": id])
                records.append(CleanupRecord(batchID: batchID, originalPath: item.path, action: .deleteSession, tool: .codex, status: .succeeded, bytes: item.bytes, message: "官方 thread/delete 已完成本地会话删除"))
            } catch {
                records.append(CleanupRecord(batchID: batchID, originalPath: item.path, action: .deleteSession, tool: .codex, status: .failed, message: "删除未确认完成；请重新扫描核对状态"))
                // Stop after uncertainty; no blind retries or raw protocol errors containing content.
                for pending in ordered.dropFirst(records.count) { records.append(CleanupRecord(batchID: batchID, originalPath: pending.path, action: .deleteSession, tool: .codex, status: .skipped, message: "前一会话删除未确认，已停止")) }
                break
            }
        }
        return records
    }
}

final class CodexRPC {
    let process = Process()
    let input = Pipe()
    let outputURL: URL
    let output: FileHandle
    var nextID = 0
    init(executable: String, root: URL) throws {
        outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-rpc-" + UUID().uuidString)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        output = try FileHandle(forWritingTo: outputURL)
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment; environment["CODEX_HOME"] = root.path
        process.environment = environment; process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { try? output.close(); try? FileManager.default.removeItem(at: outputURL); throw error }
    }
    func close() { try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() }; try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
    func send(_ object: [String: Any]) throws { var data = try JSONSerialization.data(withJSONObject: object); data.append(10); try input.fileHandleForWriting.write(contentsOf: data) }
    func notify(_ method: String) throws { try send(["method": method]) }
    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        nextID += 1; let id = nextID
        try send(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline {
            let data = try Data(contentsOf: outputURL)
            guard data.count < 4 * 1024 * 1024 else { throw CleanupError.unavailable("工具响应异常") }
            for line in data.split(separator: 10) {
                if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], object["id"] as? Int == id {
                    guard object["error"] == nil, let result = object["result"] as? [String: Any] else { throw CleanupError.unavailable("官方会话删除未完成") }
                    return result
                }
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        throw CleanupError.unavailable("官方工具响应超时，请重新扫描以核对状态")
    }
}
