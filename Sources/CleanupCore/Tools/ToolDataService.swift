import Foundation
import Darwin

public struct ToolDataService: Sendable {
    public init() {}
    public func recoverInterruptedClaudeTransaction(configuration: ToolConfiguration) async throws {
        guard configuration.tool == .claude else { throw CleanupError.unavailable("此恢复操作仅适用于 Claude") }
        try Self.ensureClosed(.claude)
        let root = configuration.root.standardizedFileURL.resolvingSymlinksInPath()
        try PathSafety.validate(root, within: root)
        try ClaudeTransaction.recover(root: root, ensureClosed: { try Self.ensureClosed(.claude) })
    }
    public static func ensureClosed(_ tool: ToolKind) throws { try ensureClosed(tool, excluding: []) }
    static func ensureClosed(_ tool: ToolKind, excluding excludedPIDs: Set<Int32>) throws {
        let data = try ToolCommand.run("/bin/ps", ["-ww", "-u", String(geteuid()), "-o", "pid=,comm="])
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, let pid = Int32(fields[0]), pid != ownPID, !excludedPIDs.contains(pid) else { continue }
            let command = String(fields[1])
            var running = ToolProcessIdentity.matches(tool, executable: command, arguments: [])
            if !running, ToolProcessIdentity.isInterpreter(command) {
                if let arguments = try ToolProcessIdentity.arguments(pid: pid) {
                    running = ToolProcessIdentity.matches(tool, executable: command, arguments: arguments)
                }
            }
            if running { throw CleanupError.unavailable("请完全退出 \(tool.title) 及其后台进程后重试") }
        }
    }
    public func scan(_ configuration: ToolConfiguration, progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanResult {
        try Task.checkCancellation()
        var configuration = configuration
        configuration.root = configuration.root.standardizedFileURL.resolvingSymlinksInPath()
        let root = configuration.root
        try PathSafety.validate(root, within: root)
        let rootSnapshot = String(decoding: try JSONEncoder().encode(Snapshotter.capture(root)), as: UTF8.self)
        var items: [CleanupItem] = []; var warnings: [String] = []
        let paths: [(String, CleanupCategory, CleanupRisk)]
        switch configuration.tool {
        case .codex: paths = [("cache", .toolCache, .recommended), ("log", .toolLog, .review), ("memories", .projectMemory, .protected)]
        case .claude: paths = [("cache", .toolCache, .recommended), ("debug", .toolLog, .review)]
        case .cursor: paths = [("Cache", .toolCache, .recommended), ("Code Cache", .toolCache, .recommended), ("GPUCache", .toolCache, .recommended), ("logs", .toolLog, .review)]
        }
        var toolStatus = ToolScanStatus()
        for (path, category, risk) in paths where ToolFiles.exists(root.appendingPathComponent(path)) {
            do { items.append(try ToolFiles.make(root.appendingPathComponent(path), root: root, tool: configuration.tool, category: category, risk: risk, reason: category == .projectMemory ? "项目记忆单独保护" : "\(configuration.tool.title) 明确的缓存或日志目录")) }
            catch { toolStatus.filesIncomplete = true; warnings.append(error.localizedDescription) }
        }
        do {
            switch configuration.tool {
            case .codex: items += try CodexAdapter.scan(configuration, warnings: &warnings, status: &toolStatus)
            case .claude: items += try ClaudeAdapter.scan(configuration, warnings: &warnings, status: &toolStatus)
            case .cursor: items += try CursorAdapter.scan(configuration, warnings: &warnings, status: &toolStatus)
            }
        } catch {
            try Task.checkCancellation()
            toolStatus.sessionRead = .failed; toolStatus.sessionDeletion = .unavailable
            toolStatus.message = error.localizedDescription
            warnings.append(error.localizedDescription)
        }
        if toolStatus.filesIncomplete, toolStatus.message == nil {
            toolStatus.message = "部分缓存或日志无法检查；会话读取状态单独统计"
        }
        try Task.checkCancellation()
        for index in items.indices {
            items[index].metadata["rootSnapshot"] = rootSnapshot
            progress?(ScanProgress(count: index + 1, path: items[index].path))
        }
        return ScanResult(rootPath: root.path, items: items, warnings: warnings, toolStatus: toolStatus)
    }
    public func deleteSessions(_ items: [CleanupItem], configuration: ToolConfiguration, batchID: UUID) async -> [CleanupRecord] {
        guard !items.isEmpty else { return [] }
        do {
            try Self.ensureClosed(configuration.tool)
            let root = configuration.root.standardizedFileURL.resolvingSymlinksInPath()
            for item in items {
                guard item.tool == configuration.tool, item.rootPath == root.path, item.action == .deleteSession,
                      item.isSelectable, let snapshot = item.snapshot else { throw CleanupError.unsafe("会话不属于当前授权范围或不支持删除") }
                try PathSafety.validate(item.url, within: root)
                try ToolFiles.verifyStamp(root, item.metadata["rootSnapshot"])
                try Snapshotter.verify(item.url, matches: snapshot)
            }
            let selected = Set(items.map(\.id))
            guard items.allSatisfy({ Set($0.relatedIDs).isSubset(of: selected) }) else { throw CleanupError.unsafe("必须一并选择关联会话") }
            var canonical = configuration; canonical.root = root
            switch configuration.tool {
            case .codex: return try CodexAdapter.delete(items, configuration: canonical, batchID: batchID)
            case .claude: try ClaudeAdapter.delete(items, configuration: canonical)
            case .cursor: throw CleanupError.unavailable("尚未验证本机 Cursor 版本，会话删除已禁用")
            }
            return items.map { CleanupRecord(batchID: batchID, originalPath: $0.path, action: .deleteSession, tool: $0.tool, status: .succeeded, bytes: $0.bytes, message: "已永久删除选定会话及已确认的关联数据") }
        } catch {
            return items.map { CleanupRecord(batchID: batchID, originalPath: $0.path, action: .deleteSession, tool: $0.tool, status: .failed, message: error.localizedDescription) }
        }
    }
}

struct CursorAdapter {
    static func scan(_ configuration: ToolConfiguration, warnings: inout [String], status: inout ToolScanStatus) throws -> [CleanupItem] {
        status.sessionRead = .unsupported; status.sessionDeletion = .unavailable
        status.message = "Cursor 会话格式尚未完成实际版本验证，只展示可读取的记录"
        warnings.append("未完成实际 Cursor 版本验证：会话仅供查看，禁止写入数据库")
        let root = configuration.root
        let storage = root.appendingPathComponent("User/workspaceStorage")
        guard ToolFiles.exists(storage) else { return [] }
        try PathSafety.validate(storage, within: root)
        return try ToolFiles.children(storage).flatMap { workspace -> [CleanupItem] in
            try PathSafety.validate(workspace, within: root)
            let database = workspace.appendingPathComponent("state.vscdb")
            guard ToolFiles.exists(database) else { return [] }
            var item = try ToolFiles.make(database, root: root, tool: .cursor, category: .session, risk: .unavailable, reason: "工作区会话存储；未知会话结构，保持只读")
            let metadata = workspace.appendingPathComponent("workspace.json")
            if ToolFiles.exists(metadata) {
                try PathSafety.validate(metadata, within: root)
                if let object = try JSONSerialization.jsonObject(with: ToolFiles.read(metadata, root: root, limit: 8 * 1024 * 1024)) as? [String: Any],
                   let folder = object["folder"] as? String, let url = URL(string: folder), url.isFileURL { item.projectPath = url.standardizedFileURL.path }
            }
            item.action = .deleteSession
            if let db = try? ToolDatabase(database, root: root),
               let rows = try? db.rows("SELECT value FROM ItemTable WHERE key = 'composer.composerData'"),
               let value = rows.first?["value"], value.utf8.count < 8 * 1024 * 1024,
               let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
               let composers = object["allComposers"] as? [[String: Any]], !composers.isEmpty,
               composers.allSatisfy({ $0["composerId"] is String }),
               Set(composers.compactMap { $0["composerId"] as? String }).count == composers.count {
                return composers.map { composer in
                    var session = item
                    let id = composer["composerId"] as! String
                    session.id = "cursor:session:\(workspace.lastPathComponent):\(id)"
                    session.sessionID = id; session.title = "会话 \(id.prefix(8))"
                    session.bytes = 0; session.reason = "读取 Composer 会话标识；未验证实际版本，禁止删除"
                    session.details = ["共享工作区数据库，无法单独计算会话磁盘占用"]
                    return session
                }
            }
            item.title = "未知格式的工作区会话存储"
            return [item]
        }
    }
}

/// Only executable identity and the interpreter's script operand are inspected.
/// Prompt text, eval source and later command arguments are never tool identities.
enum ToolProcessIdentity {
    static func isInterpreter(_ executable: String) -> Bool {
        ["node", "nodejs", "bun", "deno"].contains(URL(fileURLWithPath: executable).lastPathComponent.lowercased())
    }
    static func matches(_ tool: ToolKind, executable: String, arguments: [String]) -> Bool {
        if nativeMatch(tool, path: executable) { return true }
        guard isInterpreter(executable), let script = scriptOperand(arguments, interpreter: executable) else { return false }
        return nativeMatch(tool, path: script)
    }
    private static func nativeMatch(_ tool: ToolKind, path: String) -> Bool {
        let command = path.lowercased()
        let name = URL(fileURLWithPath: command).lastPathComponent
        switch tool {
        case .codex: return name == "codex" || command.contains("codex.app/") || name.hasPrefix("codex-") || name.hasPrefix("codex (") || command.contains("/@openai/codex/")
        case .claude: return name == "claude" || command.contains("claude.app/") || name.hasPrefix("claude-") || name == "claude.exe" || command.contains("/@anthropic-ai/claude-code/") || command.contains("/claude/versions/")
        case .cursor: return name == "cursor" || command.contains("cursor.app/") || name.hasPrefix("cursor helper")
        }
    }
    static func scriptOperand(_ arguments: [String], interpreter: String = "node") -> String? {
        let valueFlags: Set<String> = ["-r", "--require", "--import", "--loader", "--experimental-loader", "--input-type", "--inspect-port", "--conditions", "-C", "--title", "--icu-data-dir", "--openssl-config"]
        let runtime = URL(fileURLWithPath: interpreter).lastPathComponent.lowercased()
        var index = 1
        if ["bun", "deno"].contains(runtime), arguments.count > 1, arguments[1] == "run" { index = 2 }
        while index < arguments.count {
            let argument = arguments[index]
            // Eval/print source and everything after it can contain arbitrary prompt text.
            if argument == "-e" || argument == "--eval" || argument == "-p" || argument == "--print" || argument.hasPrefix("--eval=") || argument.hasPrefix("--print=") || argument.hasPrefix("-e") || argument.hasPrefix("-p") { return nil }
            if argument == "--" { return index + 1 < arguments.count ? arguments[index + 1] : nil }
            if valueFlags.contains(argument) { index += 2; continue }
            if argument.hasPrefix("-") { index += 1; continue }
            return argument
        }
        return nil
    }
    static func arguments(pid: Int32) throws -> [String]? {
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&query, UInt32(query.count), nil, &size, nil, 0) == 0 else {
            if errno == ESRCH { return nil }
            throw CleanupError.unavailable("无法检查解释器进程，未执行清理")
        }
        guard size > MemoryLayout<Int32>.size, size < 4 * 1024 * 1024 else { throw CleanupError.unavailable("进程参数格式未知，未执行清理") }
        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { sysctl(&query, UInt32(query.count), $0.baseAddress, &size, nil, 0) }
        guard result == 0 else {
            if errno == ESRCH { return nil }
            throw CleanupError.unavailable("无法检查解释器进程，未执行清理")
        }
        let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count >= 0, count < 100_000 else { throw CleanupError.unavailable("进程参数格式未知，未执行清理") }
        var cursor = MemoryLayout<Int32>.size
        while cursor < size && buffer[cursor] != 0 { cursor += 1 } // kernel executable path
        while cursor < size && buffer[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            let start = cursor
            while cursor < size && buffer[cursor] != 0 { cursor += 1 }
            guard cursor < size else { throw CleanupError.unavailable("进程参数读取不完整，未执行清理") }
            arguments.append(String(decoding: buffer[start..<cursor], as: UTF8.self)); cursor += 1
        }
        return arguments
    }
}
