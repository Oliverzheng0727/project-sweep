import Foundation
import Darwin

public struct ToolDirectoryDiscoveryResult: Sendable {
    public let roots: [ToolKind: URL]
    public let unavailable: [ToolKind: String]
    public let missing: Set<ToolKind>

    public init(roots: [ToolKind: URL], unavailable: [ToolKind: String], missing: Set<ToolKind>) {
        self.roots = roots
        self.unavailable = unavailable
        self.missing = missing
    }
}

/// Checks only the supplied directories and their ancestor metadata. It never enumerates
/// directory contents, reads configuration or session files, or creates missing locations.
public struct ToolDirectoryDiscovery: Sendable {
    private let candidates: [ToolKind: URL]

    public init(roots: [ToolKind: URL]? = nil) {
        candidates = roots ?? Dictionary(uniqueKeysWithValues: ToolKind.allCases.map { ($0, $0.defaultRoot) })
    }

    public func discover() async throws -> ToolDirectoryDiscoveryResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { try discoverNow() }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    private func discoverNow() throws -> ToolDirectoryDiscoveryResult {
        var roots: [ToolKind: URL] = [:]
        var unavailable: [ToolKind: String] = [:]
        var missing: Set<ToolKind> = []
        for tool in ToolKind.allCases {
            try Task.checkCancellation()
            guard let candidate = candidates[tool] else { continue }
            do {
                if try isAvailable(candidate) { roots[tool] = candidate.standardizedFileURL }
                else { missing.insert(tool) }
            } catch is CancellationError { throw CancellationError() }
            catch { unavailable[tool] = error.localizedDescription }
        }
        try Task.checkCancellation()
        return ToolDirectoryDiscoveryResult(roots: roots, unavailable: unavailable, missing: missing)
    }

    private func isAvailable(_ url: URL) throws -> Bool {
        guard url.isFileURL, url.path != "/" else {
            throw CleanupError.unsafe("工具数据位置必须是本地文件夹。")
        }
        guard !url.pathComponents.contains("..") else {
            throw CleanupError.unsafe("路径包含父目录跳转，必须重新扫描。")
        }
        var current = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            try Task.checkCancellation()
            current.appendPathComponent(component)
            var info = stat()
            guard lstat(current.path, &info) == 0 else {
                if errno == ENOENT { return false }
                throw CleanupError.unavailable("无法检查目录：\(String(cString: strerror(errno)))")
            }
            // Validate before looking at descendants. Only PathSafety's verified system
            // aliases (/var, /tmp and /etc) may be traversed; user-created links are refused.
            try PathSafety.validate(current, within: current)
            if ["/var", "/tmp", "/etc"].contains(current.path) { continue }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw CleanupError.unsafe("工具数据目录类型无效")
            }
            guard info.st_mode & (S_IRUSR | S_IRGRP | S_IROTH) != 0,
                  info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0,
                  access(current.path, R_OK | X_OK) == 0 else {
                throw CleanupError.unavailable("无法读取或进入工具数据目录，请检查访问权限。")
            }
            let snapshot = try Snapshotter.capture(current)
            try Snapshotter.validateMetadata(current, state: snapshot)
            guard try current.resourceValues(forKeys: [.isPackageKey]).isPackage != true else {
                throw CleanupError.unavailable("工具数据目录位于文档或应用包中，未展开读取。")
            }
            try PathSafety.validate(current, within: current)
            try Snapshotter.verify(current, matches: snapshot)
        }
        return true
    }
}
