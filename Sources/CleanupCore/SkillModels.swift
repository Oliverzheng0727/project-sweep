import Foundation

public enum SkillLocation: String, Codable, CaseIterable, Sendable {
    case personal, project, shared, plugins
    public var title: String {
        switch self { case .personal: "个人技能"; case .project: "项目技能"; case .shared: "共享目录"; case .plugins: "插件技能" }
    }
}

/// A skill-specific container, discovered at a known location or explicitly connected.
public struct SkillRoot: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var tool: ToolKind
    public var url: URL
    public var location: SkillLocation
    public init(id: String = UUID().uuidString, tool: ToolKind, url: URL, location: SkillLocation) {
        self.id = id; self.tool = tool; self.url = url; self.location = location
    }
}

public enum SkillRemoval: String, Sendable {
    case directory, reference, readOnly
    public var title: String {
        switch self { case .directory: "移除技能文件夹"; case .reference: "仅移除引用"; case .readOnly: "只读" }
    }
}

public struct SkillEntry: Identifiable, Sendable {
    public var id: String { root.id + ":" + url.path }
    public let root: SkillRoot
    public let url: URL
    public var name: String
    public var summary: String
    public var source: String
    public var removal: SkillRemoval
    public var impact: String
    public var bytes: Int64?
    public var snapshot: FileSnapshot?
    public var rootSnapshot: FileSnapshot
    /// Raw link text. Reading it does not follow or authorize its destination.
    public var linkTarget: String?
    public var selectable: Bool { removal != .readOnly && snapshot != nil }
}

public struct SkillScanResult: Sendable {
    public var entries: [SkillEntry]
    public var warnings: [String]
    public var complete: Bool { warnings.isEmpty }
}

public struct SkillRemovalPlan: Identifiable, Sendable {
    public let id = UUID()
    public let entries: [SkillEntry]
    public let roots: [SkillRoot]
    let rootSnapshots: [String: FileSnapshot]
    public var bytes: Int64 { entries.reduce(0) { $0 + ($1.bytes ?? 0) } }
    public static func make(entries: [SkillEntry], selected: Set<String>, roots: [SkillRoot]) throws -> Self {
        let chosen = entries.filter { selected.contains($0.id) }
        guard !chosen.isEmpty, Set(chosen.map(\.id)) == selected,
              chosen.allSatisfy(\.selectable), chosen.allSatisfy({ roots.contains($0.root) }) else {
            throw CleanupError.unsafe("选择已过期或包含只读技能，请重新检查。")
        }
        guard Set(chosen.map { $0.url.path }).count == chosen.count else {
            throw CleanupError.unsafe("同一技能路径被多个来源重复选中，请只保留一项。")
        }
        var rootSnapshots: [String: FileSnapshot] = [:]
        for root in roots {
            try SkillCatalog.validateRoot(root)
            let snapshot = try Snapshotter.capture(root.url)
            if let scanned = entries.first(where: { $0.root.id == root.id })?.rootSnapshot {
                guard scanned.device == snapshot.device, scanned.inode == snapshot.inode else {
                    throw CleanupError.changed("来源在扫描后被替换，请重新扫描。")
                }
            }
            rootSnapshots[root.id] = snapshot
        }
        return Self(entries: chosen, roots: roots, rootSnapshots: rootSnapshots)
    }
}
