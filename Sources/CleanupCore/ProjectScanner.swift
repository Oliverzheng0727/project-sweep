import Foundation
import Darwin

public struct ProjectScanner: Sendable {
    public init() {}
    public func scan(_ request: ScanRequest, progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanResult {
        let worker = Task.detached(priority: .userInitiated) { try ScanWorker(request: request, progress: progress).run() }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

private final class ScanWorker {
    let request: ScanRequest
    let progress: (@Sendable (ScanProgress) -> Void)?
    var items: [CleanupItem] = []
    var warnings: [String] = []
    var tracked: Set<String> = []
    var trackedAncestors: Set<String> = []
    var gitFailed = false
    var root: URL!
    var rootState: FileSnapshot!
    var visited = 0
    init(request: ScanRequest, progress: (@Sendable (ScanProgress) -> Void)?) { self.request = request; self.progress = progress }

    func run() throws -> ScanResult {
        try Task.checkCancellation()
        root = try PathSafety.prepareRoot(request.root)
        rootState = try Snapshotter.capture(root)
        if request.mode == .remove, !PathSafety.canRemoveRoot(root) {
            throw CleanupError.unsafe("此目录属于系统或通用资料目录，不能作为整个项目移除。")
        }
        progress?(ScanProgress(count: 0, path: root.path, phase: .protection))
        do { try includeTracked(GitInventory.trackedFiles(at: root)) }
        catch { gitFailed = true; warnings.append("Git 跟踪状态读取失败，整理模式已禁止选择文件：\(error.localizedDescription)") }
        progress?(ScanProgress(count: 0, path: root.path))
        _ = try visit(root, depth: 0)
        if request.mode == .remove {
            let unsafe = items.contains { $0.risk == .unavailable }
            let kept = request.protectedPaths.contains { PathSafety.isWithin($0, root: root.path) }
            for index in items.indices {
                if items[index].path == root.path {
                    items[index].category = .project
                    items[index].risk = unsafe || kept ? .unavailable : .review
                    items[index].reason = kept ? "包含“始终保留”项，请先取消保留标记。" : unsafe ? "包含无法校验的内容，不能整体移除。" : "整个项目文件夹将移入废纸篓，包括源码和作品。"
                    if items[index].isSelectable {
                        progress?(ScanProgress(count: visited, path: root.path, phase: .verification))
                        items[index].snapshot = try Snapshotter.capture(root, recursive: true)
                    }
                } else {
                    if items[index].risk != .unavailable { items[index].risk = .protected }
                    items[index].reason = "移除模式以整个项目为单位。"
                }
            }
        }
        try Task.checkCancellation()
        progress?(ScanProgress(count: visited, path: root.path))
        return ScanResult(rootPath: root.path, items: items, warnings: warnings)
    }

    // Build exact lookup keys once per scan, extending them for nested repositories
    // and opaque packages. Shared ancestors are inserted only once.
    func includeTracked(_ paths: Set<String>) throws {
        for path in paths {
            try Task.checkCancellation()
            guard tracked.insert(path).inserted else { continue }
            var ancestor = path
            while true {
                guard trackedAncestors.insert(ancestor).inserted, ancestor != "/" else { break }
                guard let slash = ancestor.lastIndex(of: "/") else { break }
                ancestor = slash == ancestor.startIndex ? "/" : String(ancestor[..<slash])
            }
        }
    }

    @discardableResult func visit(_ url: URL, depth: Int) throws -> CleanupItem {
        try Task.checkCancellation()
        let path = url.path
        visited += 1
        if visited % 100 == 0 { progress?(ScanProgress(count: visited, path: path)) }
        let state: FileSnapshot
        do { state = try Snapshotter.capture(url) }
        catch { return unavailable(url, "无法读取文件状态。") }
        let dir = state.mode & UInt32(S_IFMT) == UInt32(S_IFDIR)
        let rule = FileRules.classify(url, isDirectory: dir)
        var item = CleanupItem(path: path, rootPath: root.path, category: rule.0, risk: rule.1, reason: rule.2,
                               bytes: dir ? 0 : state.size, modifiedAt: Date(timeIntervalSince1970: Double(state.modifiedNanoseconds) / 1e9),
                               isDirectory: dir, parentPath: url == root ? nil : url.deletingLastPathComponent().path,
                               snapshot: state, metadata: ["projectMode": request.mode.rawValue, "rootIdentity": "\(rootState.device):\(rootState.inode)"])
        guard depth < 256 else { return unavailable(url, "目录嵌套过深。", state: state) }
        guard state.device == rootState.device else { return unavailable(url, "其他挂载卷不进入扫描。", state: state) }
        guard state.mode & UInt32(S_IFMT) != UInt32(S_IFLNK) else { return unavailable(url, "符号链接不进入扫描或清理。", state: state) }
        guard dir || state.mode & UInt32(S_IFMT) == UInt32(S_IFREG) else { return unavailable(url, "特殊设备或通信文件不属于清理范围。", state: state) }
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isPackageKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .isReadableKey]) }
        catch { return unavailable(url, "无法读取文件属性。", state: state) }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current, values.ubiquitousItemDownloadingStatus != .downloaded {
            return unavailable(url, "云端占位文件，不主动下载或清理。", state: state)
        }
        guard values.isReadable != false else { return unavailable(url, "没有读取权限。", state: state) }
        let special = [".git", ".svn", ".hg"].contains(url.lastPathComponent)
        if dir, !special, values.isPackage != true {
            if url != root, FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                progress?(ScanProgress(count: visited, path: path, phase: .protection))
                do { try includeTracked(GitInventory.trackedFiles(at: url)) }
                catch { gitFailed = true; warnings.append("嵌套项目 Git 状态无法读取：\(url.lastPathComponent)：\(error.localizedDescription)") }
                progress?(ScanProgress(count: visited, path: path))
            }
            let children: [URL]
            do { children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).map(\.standardizedFileURL).sorted { $0.lastPathComponent < $1.lastPathComponent } }
            catch { return unavailable(url, "无法读取目录内容。", state: state) }
            var childItems: [CleanupItem] = []
            for child in children { childItems.append(try visit(child, depth: depth + 1)) }
            item.bytes = childItems.reduce(0) { $0 + $1.bytes }
            let snapshots = childItems.compactMap { child -> (String, FileSnapshot)? in
                guard let snapshot = child.snapshot else { return nil }; return (child.title, snapshot)
            }
            item.snapshot?.treeDigest = Snapshotter.digest(snapshots)
            if childItems.contains(where: { !$0.isSelectable }) {
                item.risk = .protected
                item.reason = "包含已保护或无法校验的内容，不能整目录清理。"
            } else if item.risk == .recommended, childItems.contains(where: { $0.category == .source || $0.category == .document }) {
                item.risk = .review; item.reason = "缓存目录中包含源码或作品，需要逐项查看。"
            }
            if childItems.contains(where: { $0.metadata["systemProtection"] == "true" }) {
                item.metadata["systemProtection"] = "true"
            }
            let after = try Snapshotter.capture(url)
            guard after == state else { throw CleanupError.changed("目录在扫描中发生变化，请重新扫描：\(url.lastPathComponent)") }
        } else if dir, values.isPackage == true {
            progress?(ScanProgress(count: visited, path: path, phase: .verification))
            item.category = .document; item.risk = .review; item.reason = "文档或应用包，作为完整文件预览，不展开内部内容。"
            do {
                item.snapshot = try Snapshotter.capture(url, recursive: true)
                item.bytes = try Snapshotter.logicalBytes(url)
            }
            catch { return unavailable(url, "文档包内部元数据无法完整校验，不能清理。", state: state) }
            if request.mode == .organize {
                do { try includeTracked(GitInventory.trackedFilesForSelection(url, isDirectory: true)) }
                catch { gitFailed = true; warnings.append("文档包 Git 状态无法确认，已保护。") }
            }
            progress?(ScanProgress(count: visited, path: path))
        } else if dir, special {
            progress?(ScanProgress(count: visited, path: path, phase: .verification))
            do { item.bytes = try Snapshotter.logicalBytes(url) }
            catch { return unavailable(url, "版本历史内部元数据无法完整校验，不能整体清理。", state: state) }
            progress?(ScanProgress(count: visited, path: path))
        }
        let kept = request.protectedPaths.contains { PathSafety.isWithin(path, root: $0) || (dir && PathSafety.isWithin($0, root: path)) }
        let configDirectories = [".agents", ".claude", ".codex", ".cursor"]
        let withinConfig = configDirectories.contains(root.lastPathComponent)
            || url.pathComponents.dropFirst(root.pathComponents.count).contains(where: configDirectories.contains)
        let protectedConfig = withinConfig || [".env", ".git", ".svn", ".hg", ".mcp.json"].contains(url.lastPathComponent) || url.lastPathComponent.hasPrefix(".env.")
        let gitProtected = trackedAncestors.contains(path)
        if request.mode == .organize, protectedConfig || gitFailed || gitProtected || url == root {
            item.metadata["systemProtection"] = "true"
        }
        if request.mode == .organize, gitFailed || gitProtected || kept || protectedConfig || url == root {
            item.risk = .protected
            item.reason = kept ? "已设为始终保留。" : tracked.contains(path) ? "Git 已跟踪文件，整理模式保留。" : url == root ? "整理模式保留项目根目录。" : "项目配置、版本历史或无法确认的 Git 状态，默认保护。"
        }
        if request.mode == .remove, special { item.risk = .review }
        items.append(item)
        return item
    }

    func unavailable(_ url: URL, _ reason: String, state: FileSnapshot? = nil) -> CleanupItem {
        let item = CleanupItem(path: url.path, rootPath: root.path, risk: .unavailable, reason: reason,
                               isDirectory: state.map { $0.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) } ?? false,
                               parentPath: url == root ? nil : url.deletingLastPathComponent().path, snapshot: state)
        items.append(item); warnings.append("\(url.lastPathComponent)：\(reason)"); return item
    }
}

enum FileRules {
    static func classify(_ url: URL, isDirectory: Bool) -> (CleanupCategory, CleanupRisk, String) {
        let name = url.lastPathComponent
        if !isDirectory, name == ".DS_Store" || name == "Thumbs.db" {
            return (.cache, .recommended, "系统生成的文件夹显示缓存，可重新生成。")
        }
        if isDirectory, ["__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"].contains(name) {
            return (.cache, .recommended, "按工具约定识别的运行或检查缓存；清理后工具可能重新生成。")
        }
        if isDirectory, ["node_modules", ".venv", "venv", "vendor"].contains(name) {
            return (.dependency, .review, "依赖或运行环境；清理后可能需要重新安装，离线时未必能恢复。")
        }
        if isDirectory, ["dist", "build", "target", ".build", ".next", ".nuxt", "out", "output", "exports"].contains(name) {
            return (.build, .review, "可能包含构建结果或最终作品，请查看内容后决定。")
        }
        if isDirectory, ["tmp", "temp", ".tmp", ".cache"].contains(name) {
            return (.temporary, .review, "目录名称仅用于分类，不代表文件已经无用。")
        }
        let ext = url.pathExtension.lowercased()
        if ["ppt", "pptx", "pdf", "doc", "docx", "xls", "xlsx", "key", "pages", "numbers", "png", "jpg", "jpeg", "gif", "svg", "heic", "webp", "mp4", "mov", "mkv", "mp3", "wav", "psd", "ai", "fig", "blend"].contains(ext) {
            return (.document, .review, "文档、素材或作品，需要人工确认是否保留。")
        }
        if ["swift", "py", "js", "ts", "tsx", "jsx", "rs", "c", "cpp", "h", "java", "go", "sh", "ipynb", "r", "tex", "html", "css", "md"].contains(ext) {
            return (.source, .review, "源码、脚本或项目说明；不会自动判定为临时文件。")
        }
        return (.other, .review, "尚无明确清理规则，请预览后自行决定。")
    }
}

enum GitInventory {
    // Refresh the owning repository and every nested repository under a directory.
    static func trackedFilesForSelection(_ url: URL, isDirectory: Bool) throws -> Set<String> {
        var tracked = try trackedFiles(at: isDirectory ? url : url.deletingLastPathComponent())
        guard isDirectory else { return tracked }
        let device = try Snapshotter.capture(url).device
        func visit(_ directory: URL, depth: Int) throws {
            try Task.checkCancellation()
            guard depth < 256 else { throw CleanupError.unsafe("Git 仓库嵌套过深，无法确认跟踪状态。") }
            let state = try Snapshotter.capture(directory)
            try Snapshotter.validateMetadata(directory, state: state)
            guard state.device == device else { throw CleanupError.unsafe("目录包含其他挂载卷。") }
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            if children.contains(where: { $0.lastPathComponent == ".git" }) {
                tracked.formUnion(try trackedFiles(at: directory))
            }
            for child in children where child.lastPathComponent != ".git" {
                let childState = try Snapshotter.capture(child)
                try Snapshotter.validateMetadata(child, state: childState)
                if childState.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) { try visit(child, depth: depth + 1) }
            }
        }
        try visit(url, depth: 0)
        return tracked
    }

    static func trackedFiles(at root: URL) throws -> Set<String> {
        let top = try git(["-C", root.path, "rev-parse", "--show-toplevel"])
        guard top.0 == 0 else {
            var ancestor = root
            while ancestor.path != "/" {
                if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
                    throw CleanupError.unavailable("Git rev-parse 退出码 \(top.0)。")
                }
                ancestor.deleteLastPathComponent()
            }
            return []
        }
        let topPath = String(decoding: top.1, as: UTF8.self).trimmingCharacters(in: .newlines)
        // Normalize the existing repository root before appending paths. Missing
        // tracked files otherwise retain /private/var while scanned parents use /var.
        let topURL = URL(fileURLWithPath: topPath).standardizedFileURL
        let result = try git(["-C", topPath, "ls-files", "--cached", "-z"])
        guard result.0 == 0 else { throw CleanupError.unavailable("Git ls-files 退出码 \(result.0)。") }
        return Set(result.1.split(separator: 0).map { topURL.appendingPathComponent(String(decoding: $0, as: UTF8.self)).standardizedFileURL.path })
    }
    private static func git(_ args: [String]) throws -> (Int32, Data) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"; environment["GIT_CONFIG_NOSYSTEM"] = "1"; environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); timeout.cancel()
        guard process.terminationReason == .exit else {
            throw CleanupError.unavailable("Git 进程被信号 \(process.terminationStatus) 终止（10 秒超时会强制终止）。")
        }
        return (process.terminationStatus, data)
    }
}
