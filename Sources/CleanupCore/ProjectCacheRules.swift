import Foundation
import Darwin

/// Default cache locations are meaningful only beside a manifest that declares their producer.
/// Configuration scripts are never executed and custom cache paths are never guessed.
enum ProjectCacheRules {
    struct Evidence {
        let producer: String
        let manifestPath: String
        let reason: String
        let details: [String]
    }

    static func evidence(for directory: URL, within root: URL, device: UInt64) throws -> Evidence? {
        try Task.checkCancellation()
        let parent = directory.deletingLastPathComponent()
        let owner: URL
        let dependency: String
        let producer: String
        let reason: String
        let impact: String
        switch (directory.lastPathComponent, parent.lastPathComponent) {
        case ("cache", ".next"):
            owner = parent.deletingLastPathComponent(); dependency = "next"; producer = "Next.js"
            reason = "Next.js 默认缓存目录；项目 package.json 明确声明了 next 依赖。"
            impact = "清理后 Next.js 需要重建缓存，首次构建或请求可能变慢，部分数据可能需要重新获取。"
        case (".parcel-cache", _):
            owner = parent; dependency = "parcel"; producer = "Parcel"
            reason = "Parcel 默认构建缓存；项目 package.json 明确声明了 parcel 依赖。"
            impact = "清理后 Parcel 会重新构建缓存，下一次构建可能变慢。"
        case (".vite", "node_modules"):
            owner = parent.deletingLastPathComponent(); dependency = "vite"; producer = "Vite"
            reason = "Vite 默认依赖缓存；项目 package.json 明确声明了 vite 依赖。"
            impact = "清理后 Vite 会重新预构建依赖，下一次启动可能变慢。"
        default:
            return nil
        }
        guard directory.path != root.path, PathSafety.isWithin(owner.path, root: root.path) else { return nil }
        let manifest = owner.appendingPathComponent("package.json")
        do {
            // Reuse the bounded, no-follow, local-only reader used by the tool adapters.
            // The manifest is the only body read by these rules; cache contents remain metadata-only.
            let before = try ToolFiles.regularFile(manifest, root: root, limit: 256 * 1024)
            guard before.device == device else { return nil }
            let data = try ToolFiles.read(manifest, root: root, limit: 256 * 1024)
            try Snapshotter.verify(manifest, matches: before)
            try Task.checkCancellation()
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            var overrides = [object["overrides"], object["resolutions"]].compactMap { $0 }
            if let pnpmConfiguration = object["pnpm"] {
                guard let pnpm = pnpmConfiguration as? [String: Any] else { return nil }
                if let replacement = pnpm["overrides"] { overrides.append(replacement) }
            }
            // Do not attempt package-manager-specific precedence or replacement resolution.
            // Even unrelated overrides stay manual; malformed fields are not equivalent to empty ones.
            guard overrides.allSatisfy({ ($0 as? [String: Any])?.isEmpty == true }) else { return nil }
            let specifications = ["dependencies", "devDependencies", "optionalDependencies"].compactMap { key in
                (object[key] as? [String: Any])?[dependency]
            }
            // A replacement in any section can override a normal registry dependency.
            // Ambiguous or unsupported specifications never establish producer identity.
            guard !specifications.isEmpty, specifications.allSatisfy({ specification in
                guard let text = specification as? String else { return false }
                return isRegistrySpecification(text)
            }) else { return nil }
            return Evidence(producer: producer, manifestPath: manifest.path, reason: reason,
                            details: [reason, impact, "请先停止正在使用此项目的开发服务器或构建任务，再清理缓存。"])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Missing, unreadable, linked, cloud-only, malformed or changing manifests
            // supply no evidence. Their cache-like folders keep the normal manual rule.
            try Task.checkCancellation()
            return nil
        }
    }

    private static func isRegistrySpecification(_ specification: String) -> Bool {
        let value = specification.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        // Dist-tags are accepted conservatively. Tarball-like names may resolve to local files.
        if ![".tgz", ".tar", ".tar.gz", ".zip"].contains(where: { value.lowercased().hasSuffix($0) }),
           value.range(of: #"\A[A-Za-z][A-Za-z0-9._-]*\z"#, options: .regularExpression) != nil { return true }

        // This intentionally recognizes common registry versions and ranges only. It is
        // not an npm resolver: aliases, URLs, Git and local/workspace paths are rejected.
        let number = #"(?:0|[1-9][0-9]*)"#
        let identifier = #"[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*"#
        let fullVersion = number + #"\."# + number + #"\."# + number + "(?:-" + identifier + ")?(?:\\+" + identifier + ")?"
        let partialVersion = number + "(?:\\." + number + "){0,2}"
        let wildcardVersion = #"(?:[xX*]|"# + number + #"\.[xX*]|"# + number + #"\."# + number + #"\.[xX*])"#
        let version = "[vV]?(?:" + fullVersion + "|" + partialVersion + "|" + wildcardVersion + ")"
        let comparator = #"(?:[~^]|[<>]=?|=)?\s*"# + version
        let group = "(?:" + version + #"\s+-\s+"# + version + "|" + comparator + "(?:\\s+" + comparator + ")*)"
        return value.range(of: #"\A"# + group + #"(?:\s*\|\|\s*"# + group + #")*\z"#, options: .regularExpression) != nil
    }
}
