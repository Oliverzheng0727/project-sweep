import Foundation
import Darwin

/// Checks fixed local locations, without searching the home directory or reading tool configuration.
public struct SkillDiscovery: Sendable {
    public let home: URL
    public let environment: [String: String]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home.standardizedFileURL
        self.environment = environment
    }

    public func discover() async throws -> SkillDiscoveryResult {
        let worker = Task.detached(priority: .userInitiated) { try discoverNow() }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func discoverNow() throws -> SkillDiscoveryResult {
        var candidates: [SkillRoot] = []
        func add(_ tool: ToolKind, base: URL) {
            for (suffix, location) in [("skills", SkillLocation.personal), ("plugins/cache", .plugins)] {
                let url = base.appendingPathComponent(suffix).standardizedFileURL
                candidates.append(SkillRoot(id: "auto:\(tool.rawValue):\(url.path)", tool: tool, url: url, location: location))
            }
        }
        for (tool, key) in [(ToolKind.claude, "CLAUDE_CONFIG_DIR"), (.codex, "CODEX_HOME")] {
            add(tool, base: home.appendingPathComponent(".\(tool.rawValue)"))
            if let configured = environment[key], configured.hasPrefix("/") {
                add(tool, base: URL(fileURLWithPath: configured))
            }
        }
        let shared = home.appendingPathComponent(".agents/skills")
        candidates.append(SkillRoot(id: "auto:codex:\(shared.path)", tool: .codex, url: shared, location: .shared))

        var roots: [SkillRoot] = []; var warnings: [String] = []; var seen: Set<String> = []
        for candidate in candidates where seen.insert(candidate.id).inserted {
            try Task.checkCancellation()
            do {
                guard try existsWithoutFollowingLinks(candidate.url) else { continue }
                try SkillCatalog.validateRoot(candidate)
                roots.append(candidate)
            } catch is CancellationError { throw CancellationError() }
            catch { warnings.append("\(candidate.tool.title) · \(candidate.url.path)：\(error.localizedDescription) 可通过“添加自定义目录”选择真实位置或重新授权。") }
        }
        return SkillDiscoveryResult(roots: roots, warnings: warnings)
    }

    private func existsWithoutFollowingLinks(_ url: URL) throws -> Bool {
        var current = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            try Task.checkCancellation()
            current.appendPathComponent(component)
            var info = stat()
            guard lstat(current.path, &info) == 0 else {
                if errno == ENOENT { return false }
                throw CleanupError.unavailable("无法检查目录：\(String(cString: strerror(errno)))")
            }
            // PathSafety permits only macOS's verified /var, /tmp and /etc aliases.
            try PathSafety.validate(current, within: current)
            if ["/var", "/tmp", "/etc"].contains(current.path) { continue }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw CleanupError.unsafe("技能来源不是文件夹。") }
            try Snapshotter.validateMetadata(current, state: Snapshotter.capture(current))
            guard try current.resourceValues(forKeys: [.isPackageKey]).isPackage != true else {
                throw CleanupError.unavailable("技能来源位于文档包中，未展开读取。")
            }
        }
        return true
    }
}

public struct SkillDiscoveryResult: Sendable {
    public let roots: [SkillRoot]
    public let warnings: [String]
}
