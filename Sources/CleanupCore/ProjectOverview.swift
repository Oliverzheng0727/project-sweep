import Foundation

public struct OverviewMetric: Sendable {
    public var count: Int
    public var bytes: Int64
    public var incomplete: Bool
}

/// Non-overlapping file units; ordinary parent directory totals are never added again.
public struct ProjectOverview: Sendable {
    public let units: [CleanupItem]
    public var totalBytes: Int64 { units.reduce(0) { $0 + $1.bytes } }
    public var isComplete: Bool { !units.contains { $0.risk == .unavailable || $0.snapshot == nil } }

    public init(items: [CleanupItem]) {
        let project = items.filter { $0.tool == nil }
        let parents = Set(project.compactMap(\.parentPath))
        let ordered = project.sorted { $0.path.count < $1.path.count }
        var absorbing: Set<String> = []
        var result: [CleanupItem] = []
        for item in ordered {
            // Root is an artificial protected container, except when nothing can be read.
            if item.path == item.rootPath && item.risk != .unavailable { continue }
            var ancestor = item.parentPath
            var covered = false
            while let path = ancestor, path.count >= item.rootPath.count {
                if absorbing.contains(path) { covered = true; break }
                if path == item.rootPath { break }
                ancestor = URL(fileURLWithPath: path).deletingLastPathComponent().path
            }
            if covered { continue }
            let opaque = !parents.contains(item.path)
            if !item.isDirectory || opaque || item.risk == .unavailable || item.risk == .recommended {
                result.append(item)
                if item.isDirectory { absorbing.insert(item.path) }
            }
        }
        units = result
    }

    public func summary(for risk: CleanupRisk) -> OverviewMetric {
        let members = units.filter { $0.risk == risk }
        return OverviewMetric(count: members.count, bytes: members.reduce(0) { $0 + $1.bytes },
                              incomplete: members.contains { $0.risk == .unavailable || $0.snapshot == nil })
    }
}
