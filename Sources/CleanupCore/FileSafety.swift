import Foundation
import CryptoKit
import Darwin

public enum PathSafety {
    public static func isWithin(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    public static func validate(_ url: URL, within root: URL) throws {
        guard !url.pathComponents.contains(".."), !root.pathComponents.contains("..") else {
            throw CleanupError.unsafe("路径包含父目录跳转，必须重新扫描。")
        }
        let rootPath = root.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard rootPath != "/", isWithin(target, root: rootPath) else {
            throw CleanupError.unsafe("路径超出已选择目录：\(target)")
        }
        // Never resolve the target before checking: doing so would silently follow a replaced link.
        var current = URL(fileURLWithPath: target)
        while true {
            var info = stat()
            guard lstat(current.path, &info) == 0 else {
                throw CleanupError.io("无法访问 \(current.lastPathComponent)：\(String(cString: strerror(errno)))")
            }
            // Foundation standardizes /private/var back to /var. Permit only the three
            // immutable macOS root aliases, after verifying their exact physical destination.
            let systemAlias: Bool
            if ["/var", "/tmp", "/etc"].contains(current.path), let physical = realpath(current.path, nil) {
                systemAlias = String(cString: physical) == "/private" + current.path
                free(physical)
            } else { systemAlias = false }
            guard info.st_mode & S_IFMT != S_IFLNK || systemAlias else {
                throw CleanupError.unsafe("路径包含符号链接，请重新选择真实目录：\(current.path)")
            }
            if current.path == "/" { break }
            current.deleteLastPathComponent()
        }
    }

    public static func prepareRoot(_ url: URL) throws -> URL {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CleanupError.unsafe("请选择一个真实的项目文件夹。")
        }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path != "/", canonical != FileManager.default.homeDirectoryForCurrentUser else {
            throw CleanupError.unsafe("请选择具体项目，不能扫描磁盘根目录或整个个人目录。")
        }
        try validate(canonical, within: canonical)
        return canonical
    }

    public static func canRemoveRoot(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let protected = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes", "/private", "/usr", "/bin", "/sbin", "/opt", home,
                         home + "/Desktop", home + "/Documents", home + "/Downloads", home + "/Library", home + "/.Trash",
                         home + "/.codex", home + "/.claude", home + "/.cursor"]
        return !protected.contains(url.path)
            && !PathSafety.isWithin(url.path, root: "/System")
            && !PathSafety.isWithin(url.path, root: "/usr")
    }
}

public enum Snapshotter {
    public static func capture(_ url: URL, recursive: Bool = false) throws -> FileSnapshot {
        try Task.checkCancellation()
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw CleanupError.io("无法读取文件状态：\(url.lastPathComponent)")
        }
        var result = FileSnapshot(device: UInt64(info.st_dev), inode: info.st_ino, size: info.st_size,
                                  modifiedNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec), mode: UInt32(info.st_mode))
        if recursive {
            try validateMetadata(url, state: result)
            if info.st_mode & S_IFMT == S_IFDIR {
                result.treeDigest = try captureDigest(url, depth: 0, device: UInt64(info.st_dev))
                guard try capture(url) == FileSnapshot(device: result.device, inode: result.inode, size: result.size,
                    modifiedNanoseconds: result.modifiedNanoseconds, mode: result.mode) else {
                    throw CleanupError.changed("目录在校验中发生变化，请重新扫描。")
                }
            }
        }
        return result
    }

    public static func verify(_ url: URL, matches snapshot: FileSnapshot) throws {
        let current = try capture(url, recursive: snapshot.treeDigest != nil)
        guard current == snapshot else {
            throw CleanupError.changed("\(url.lastPathComponent) 在扫描后发生变化，请重新扫描。")
        }
    }

    static func digest(_ entries: [(String, FileSnapshot)]) -> String {
        var hash = SHA256()
        for (name, entry) in entries.sorted(by: { $0.0 < $1.0 }) {
            let string = "\(name.utf8.count):\(name)|\(entry.device):\(entry.inode):\(entry.size):\(entry.modifiedNanoseconds):\(entry.mode):\(entry.treeDigest ?? "")\n"
            hash.update(data: Data(string.utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // Metadata only: never open document bodies or expose package children as choices.
    static func validateMetadata(_ url: URL, state: FileSnapshot) throws {
        let kind = state.mode & UInt32(S_IFMT)
        guard kind == UInt32(S_IFDIR) || kind == UInt32(S_IFREG) else {
            throw CleanupError.unsafe("目录包含符号链接或特殊文件，无法整体清理。")
        }
        let values = try url.resourceValues(forKeys: [.isReadableKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values.isReadable != false, state.mode & UInt32(S_IRUSR | S_IRGRP | S_IROTH) != 0 else {
            throw CleanupError.unavailable("无法读取完整目录元数据，未执行清理。")
        }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current,
           values.ubiquitousItemDownloadingStatus != .downloaded {
            throw CleanupError.unavailable("包含云端占位文件，不主动下载或清理。")
        }
    }

    // Logical file lengths only; no file bodies are opened or read.
    static func logicalBytes(_ url: URL) throws -> Int64 {
        let device = try capture(url).device
        func count(_ current: URL, depth: Int) throws -> Int64 {
            try Task.checkCancellation()
            guard depth < 256 else { throw CleanupError.unsafe("目录嵌套过深，无法统计大小。") }
            let before = try capture(current)
            try validateMetadata(current, state: before)
            guard before.device == device else { throw CleanupError.unsafe("目录包含其他挂载卷。") }
            guard before.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) else { return max(0, before.size) }
            var total: Int64 = 0
            for child in try FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: nil) {
                let (sum, overflow) = total.addingReportingOverflow(try count(child, depth: depth + 1))
                guard !overflow else { throw CleanupError.unsafe("目录大小超出可统计范围。") }
                total = sum
            }
            guard try capture(current) == before else { throw CleanupError.changed("目录在统计中发生变化，请重新扫描。") }
            return total
        }
        return try count(url, depth: 0)
    }

    private static func captureDigest(_ url: URL, depth: Int, device: UInt64) throws -> String {
        guard depth < 256 else { throw CleanupError.unsafe("目录嵌套过深，无法安全校验。") }
        try Task.checkCancellation()
        let before = try capture(url)
        try validateMetadata(url, state: before)
        let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        var entries: [(String, FileSnapshot)] = []
        for child in children {
            var state = try capture(child)
            guard state.device == device else { throw CleanupError.unsafe("目录包含其他挂载卷，无法清理。") }
            try validateMetadata(child, state: state)
            if state.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) {
                state.treeDigest = try captureDigest(child, depth: depth + 1, device: device)
            }
            entries.append((child.lastPathComponent, state))
        }
        guard try capture(url) == before else { throw CleanupError.changed("目录在校验中发生变化，请重新扫描。") }
        return digest(entries)
    }
}
