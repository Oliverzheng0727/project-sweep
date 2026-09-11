import Foundation
import Darwin

public struct SkillCatalog: Sendable {
    public init() {}
    public func scan(_ roots: [SkillRoot], priorWarnings: [String] = []) async throws -> SkillScanResult {
        let worker = Task.detached(priority: .userInitiated) { try Self.scanNow(roots, priorWarnings: priorWarnings) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func scanNow(_ roots: [SkillRoot], priorWarnings: [String] = []) throws -> SkillScanResult {
        var entries: [SkillEntry] = []; var warnings = priorWarnings
        for root in roots {
            try Task.checkCancellation()
            do {
                try validateRoot(root)
                let baseline = try Snapshotter.capture(root.url)
                var visited = 0
                func list(_ directory: URL, depth: Int, inheritedSource: String? = nil) throws {
                    try Task.checkCancellation()
                    guard depth < 12, visited < 20_000 else { throw CleanupError.unavailable("目录层级或数量超出技能扫描范围。") }
                    try PathSafety.validate(directory, within: root.url)
                    try Snapshotter.validateMetadata(directory, state: Snapshotter.capture(directory))
                    let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        .map { directory.appendingPathComponent($0.lastPathComponent) }
                    for child in children.sorted(by: { $0.path < $1.path }) {
                        try Task.checkCancellation(); visited += 1
                        guard visited < 20_000 else { throw CleanupError.unavailable("技能目录过大，扫描未完整完成。") }
                        do {
                            let stamp = try Snapshotter.capture(child)
                            let kind = stamp.mode & UInt32(S_IFMT)
                            if kind == UInt32(S_IFLNK), depth == 0, root.location != .plugins, !child.lastPathComponent.hasPrefix(".") {
                                entries.append(try inspect(child, root: root, rootSnapshot: baseline))
                            } else if kind == UInt32(S_IFDIR) {
                                try Snapshotter.validateMetadata(child, state: stamp)
                                guard try child.resourceValues(forKeys: [.isPackageKey]).isPackage != true else { continue }
                                let reserved = child.lastPathComponent == ".system" ? "系统内置" : child.lastPathComponent == "synced" ? "云端同步" : inheritedSource
                                if ToolFiles.exists(child.appendingPathComponent("SKILL.md")) {
                                    entries.append(try inspect(child, root: root, rootSnapshot: baseline, sourceOverride: reserved))
                                } else if root.location == .plugins || reserved != nil {
                                    try list(child, depth: depth + 1, inheritedSource: reserved)
                                }
                            }
                        } catch is CancellationError { throw CancellationError() }
                        catch { warnings.append("\(root.tool.title) · \(child.lastPathComponent)：\(error.localizedDescription)") }
                    }
                }
                try list(root.url, depth: 0)
                guard try Snapshotter.capture(root.url) == baseline else { throw CleanupError.changed("目录在扫描中变化，请重新扫描。") }
            } catch is CancellationError { throw CancellationError() }
            catch {
                entries.removeAll { $0.root.id == root.id }
                warnings.append("\(root.tool.title) · \(root.url.path)：\(error.localizedDescription)")
            }
        }
        // Only explicit paths/links establish sharing. Never infer sharing from the skill name.
        let references = entries.compactMap { entry -> String? in
            guard let target = entry.linkTarget else { return nil }
            return linkDestination(target, at: entry.url).path
        }
        for index in entries.indices where entries[index].removal == .directory {
            if references.contains(where: { PathSafety.isWithin($0, root: entries[index].url.path) || PathSafety.isWithin(entries[index].url.path, root: $0) })
                || roots.contains(where: { $0.id != entries[index].root.id && PathSafety.isWithin(entries[index].url.path, root: $0.url.path) }) {
                entries[index].removal = .readOnly; entries[index].source = "共享原文件"
                entries[index].impact = "其他已连接来源使用此目录；保留原文件，请到对应 AI 下移除引用。"
            }
        }
        if !warnings.isEmpty {
            // An unreadable authorized source could conceal a reference to a physical skill.
            for index in entries.indices where entries[index].removal == .directory {
                entries[index].removal = .readOnly
                entries[index].impact = "来源检查未完整完成，无法排除共享引用。请处理提示后重新扫描。"
            }
        }
        return SkillScanResult(entries: entries, warnings: warnings)
    }

    public static func validateRoot(_ root: SkillRoot) throws {
        guard root.tool == .codex || root.tool == .claude else { throw CleanupError.unsafe("目前仅支持 Codex 和 Claude Code 技能。") }
        let canonical = try PathSafety.prepareRoot(root.url)
        guard canonical.path == root.url.path else { throw CleanupError.changed("技能授权目录已变化。") }
        guard root.location == .plugins || root.url.lastPathComponent == "skills" else {
            throw CleanupError.unsafe("请选择包含各个技能文件夹的 skills 目录。")
        }
        if root.location == .plugins {
            guard ["plugins", "cache"].contains(root.url.lastPathComponent) else { throw CleanupError.unsafe("请选择插件的 plugins 或 cache 目录。") }
        }
        let parts = root.url.pathComponents
        if parts.contains(".agents"), root.location != .shared { throw CleanupError.unsafe(".agents/skills 是共享来源，请使用“共享目录”连接。") }
        if parts.contains(".claude"), root.tool != .claude { throw CleanupError.unsafe("这是 Claude Code 的目录，请切换到 Claude Code。") }
        if parts.contains(".codex"), root.tool != .codex { throw CleanupError.unsafe("这是 Codex 的目录，请切换到 Codex。") }
    }

    static func inspect(_ url: URL, root: SkillRoot, rootSnapshot: FileSnapshot, sourceOverride: String? = nil) throws -> SkillEntry {
        let before = try Snapshotter.capture(url)
        let isLink = before.mode & UInt32(S_IFMT) == UInt32(S_IFLNK)
        let source = sourceOverride ?? root.location.title
        var entry = SkillEntry(root: root, url: url, name: url.lastPathComponent, summary: "", source: source,
                               removal: .readOnly, impact: "", bytes: nil, snapshot: nil, rootSnapshot: rootSnapshot)
        if isLink {
            guard url.deletingLastPathComponent().path == root.url.path else { throw CleanupError.unsafe("仅处理技能目录的直接引用。") }
            try PathSafety.validate(root.url, within: root.url)
            entry.linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            entry.snapshot = before; entry.bytes = max(0, before.size)
            entry.source = "共享引用"; entry.summary = "仅读取链接信息，未读取目标文件。"
            let managed = root.location == .shared || root.location == .plugins
                || root.url.pathComponents.contains(where: { [".agents", ".system", "synced", "plugins"].contains($0) })
            entry.removal = managed ? .readOnly : .reference
            entry.impact = entry.removal == .reference ? "只移除 \(root.tool.title) 此位置的引用。共享原文件保留，其他 AI 的引用不变。" : "共享目录中的引用也可能被多个 AI 使用，保持只读。"
            try Snapshotter.verify(url, matches: before)
            return entry
        }
        try PathSafety.validate(url, within: root.url)
        try Snapshotter.validateMetadata(url, state: before)
        let file = url.appendingPathComponent("SKILL.md")
        let metadata = try readHeader(file, root: root.url)
        entry.name = metadata.name ?? url.lastPathComponent; entry.summary = metadata.summary ?? "未提供可识别的技能简介"
        let parts = url.pathComponents
        let system = sourceOverride != nil || parts.contains(".system") || parts.contains("synced")
        let plugin = root.location == .plugins || parts.contains("plugins") || ToolFiles.exists(url.appendingPathComponent(".claude-plugin")) || ToolFiles.exists(url.appendingPathComponent(".codex-plugin"))
        if system {
            entry.impact = source == "云端同步" ? "在 Claude 的同步来源中停用；删除本地缓存后会再次同步。" : "系统或管理的技能，不能作为个人技能删除。"
        } else if plugin {
            entry.source = "插件技能"; entry.impact = "属于插件，请在 \(root.tool.title) 的插件管理中停用或卸载所属插件。"
        } else if root.location == .shared || parts.contains(".agents") {
            entry.source = "共享原文件"; entry.impact = "保留共享原文件。Codex 直接读取此目录，没有可单独删除的本地引用；如需停用，请在 Codex 中管理。"
        } else if url.deletingLastPathComponent().path == root.url.path {
            entry.removal = .directory
            entry.impact = "将此技能及其脚本、模板移入废纸篓。仅核对已连接来源的共享关系；未连接的自定义引用无法检查。"
        }
        if entry.removal == .directory {
            do {
                entry.snapshot = try Snapshotter.capture(url, recursive: true)
                entry.bytes = try Snapshotter.logicalBytes(url)
                try Snapshotter.verify(url, matches: entry.snapshot!)
            } catch is CancellationError { throw CancellationError() }
            catch { entry.removal = .readOnly; entry.impact = error.localizedDescription }
        }
        return entry
    }

    static func linkDestination(_ target: String, at url: URL) -> URL {
        target.hasPrefix("/") ? URL(fileURLWithPath: target).standardizedFileURL
            : url.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
    }

    private static func readHeader(_ url: URL, root: URL) throws -> (name: String?, summary: String?) {
        let state = try ToolFiles.regularFile(url, root: root)
        guard state.size <= 2 * 1024 * 1024 else { throw CleanupError.unavailable("SKILL.md 过大，未读取。") }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CleanupError.io("无法安全读取技能简介。") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, UInt64(info.st_dev) == state.device, info.st_ino == state.inode,
              UInt32(info.st_mode) == state.mode, info.st_size == state.size,
              Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec) == state.modifiedNanoseconds else {
            throw CleanupError.changed("技能文件在读取前变化。")
        }
        let data = try handle.read(upToCount: 16 * 1024) ?? Data()
        try Snapshotter.verify(url, matches: state)
        try PathSafety.validate(url, within: root)
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return (nil, nil) }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            for key in ["name", "description"] where line.hasPrefix(key + ":") {
                let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !["", ">", "|", ">-", "|-"].contains(value) { fields[key] = String(value.prefix(key == "name" ? 160 : 500)) }
            }
        }
        return (fields["name"], fields["description"])
    }
}
