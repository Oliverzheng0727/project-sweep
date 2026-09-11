import Foundation
import CSQLite
import Darwin

struct ToolFiles {
    static func children(_ url: URL) throws -> [URL] {
        try PathSafety.validate(url, within: url)
        let state = try Snapshotter.capture(url)
        guard state.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) else { throw CleanupError.unsafe("工具数据目录类型无效") }
        try Snapshotter.validateMetadata(url, state: state)
        guard try url.resourceValues(forKeys: [.isPackageKey]).isPackage != true else { throw CleanupError.unsafe("不进入工具目录中的文档或应用包") }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).map(\.standardizedFileURL).sorted { $0.path < $1.path }
    }
    static func exists(_ url: URL) -> Bool { var state = stat(); return lstat(url.path, &state) == 0 }
    static func isLocal(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded
    }
    static func regularFile(_ url: URL, root: URL, limit: Int? = nil) throws -> FileSnapshot {
        try PathSafety.validate(url, within: root)
        let snapshot = try Snapshotter.capture(url)
        guard snapshot.mode & UInt32(S_IFMT) == UInt32(S_IFREG) else { throw CleanupError.unsafe("只读取本地普通文件") }
        try Snapshotter.validateMetadata(url, state: snapshot)
        if let limit, snapshot.size > Int64(limit) { throw CleanupError.unavailable("索引或会话过大，保持只读") }
        return snapshot
    }
    static func read(_ url: URL, root: URL? = nil, limit: Int = 128 * 1024 * 1024,
                     locality: (URL) throws -> Bool = isLocal) throws -> Data {
        guard limit >= 0, limit < Int.max else { throw CleanupError.unsafe("读取大小限制无效") }
        let root = root ?? url.deletingLastPathComponent()
        let expected = try regularFile(url, root: root, limit: limit)
        guard try locality(url) else { throw CleanupError.unavailable("云端占位文件，不主动下载或读取") }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CleanupError.io("无法安全读取工具文件") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              UInt64(info.st_dev) == expected.device, info.st_ino == expected.inode,
              UInt32(info.st_mode) == expected.mode, info.st_size == expected.size,
              Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec) == expected.modifiedNanoseconds else {
            throw CleanupError.changed("工具文件在读取前发生变化")
        }
        var data = Data()
        while data.count <= limit {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(1024 * 1024, limit + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= limit else { throw CleanupError.unavailable("索引或会话过大，保持只读") }
        try PathSafety.validate(url, within: root)
        try Snapshotter.verify(url, matches: expected)
        return data
    }
    static func jsonLines(_ url: URL, root: URL? = nil) throws -> [(Data, [String: Any])] {
        let data = try read(url, root: root)
        return try data.split(separator: 10).map { line in
            guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                throw CleanupError.unavailable("未知 JSONL 格式：\(url.lastPathComponent)")
            }
            return (Data(line), object)
        }
    }
    static func make(_ url: URL, root: URL, tool: ToolKind, category: CleanupCategory, risk: CleanupRisk, reason: String) throws -> CleanupItem {
        try PathSafety.validate(url, within: root)
        let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let snapshot = directory ? try Snapshotter.capture(url, recursive: true) : try regularFile(url, root: root)
        var bytes: Int64 = directory ? 0 : snapshot.size
        if directory, let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsPackageDescendants]) {
            for case let child as URL in enumerator {
                try PathSafety.validate(child, within: root)
                let values = try child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
            }
        }
        return CleanupItem(path: url.path, rootPath: root.path, category: category, risk: risk, reason: reason, bytes: bytes,
            modifiedAt: Date(timeIntervalSince1970: Double(snapshot.modifiedNanoseconds) / 1_000_000_000), isDirectory: directory, tool: tool, snapshot: snapshot)
    }
    static func stamp(_ url: URL) throws -> String {
        String(decoding: try JSONEncoder().encode(Snapshotter.capture(url, recursive: true)), as: UTF8.self)
    }
    static func verifyStamp(_ url: URL, _ stamp: String?) throws {
        try Snapshotter.verify(url, matches: decodeStamp(stamp))
    }
    static func decodeStamp(_ stamp: String?) throws -> FileSnapshot {
        guard let stamp else { throw CleanupError.changed("缺少扫描快照") }
        return try JSONDecoder().decode(FileSnapshot.self, from: Data(stamp.utf8))
    }

}

/// Opens existing databases read-only; never creates a database or modifies its schema.
final class ToolDatabase {
    private var db: OpaquePointer?
    init(_ url: URL, root: URL) throws {
        _ = try ToolFiles.regularFile(url, root: root)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if ToolFiles.exists(sidecar) { _ = try ToolFiles.regularFile(sidecar, root: root) }
        }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw CleanupError.unavailable("无法只读打开工具数据库")
        }
        sqlite3_busy_timeout(db, 1000)
    }
    deinit { sqlite3_close(db) }
    func rows(_ sql: String) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CleanupError.unavailable("工具数据库结构不受支持") }
        defer { sqlite3_finalize(statement) }
        var result: [[String: String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw CleanupError.unavailable("读取工具数据库失败") }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                if let value = sqlite3_column_text(statement, index), let name = sqlite3_column_name(statement, index) {
                    row[String(cString: name)] = String(cString: value)
                }
            }
            result.append(row)
        }
    }
}

struct ToolCommand {
    /// File-backed output avoids pipe-capacity deadlocks. Commands have a bounded execution time.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval = 15) throws -> Data {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = handle; process.standardError = FileHandle.nullDevice
        if let environment { process.environment = environment }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); throw CleanupError.unavailable("工具响应超时") }
        guard process.terminationStatus == 0 else { throw CleanupError.unavailable("工具命令失败") }
        return try Data(contentsOf: output)
    }
}
