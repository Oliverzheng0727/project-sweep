import Foundation

/// Observed directories and explicit references at one exact path. This is not
/// an inventory of enabled skills, and an unobserved target may still exist.
public struct SkillRelationship: Identifiable, Sendable {
    public var id: String { originalPath }
    public let originalPath: String
    public let entries: [SkillEntry]
    public var directEntries: [SkillEntry] { entries.filter { $0.linkTarget == nil } }
    public var references: [SkillEntry] { entries.filter { $0.linkTarget != nil } }
    public var originalObserved: Bool { entries.contains { $0.linkTarget == nil } }
    public var name: String {
        if let observedName = directEntries.first?.name { return observedName }
        let component = URL(fileURLWithPath: originalPath).lastPathComponent
        return component.isEmpty ? originalPath : component
    }
}

/// A pure projection of one completed catalog attempt: no filesystem access,
/// target traversal, extra scanning or changes to skill removal permissions.
public struct SkillRelationshipInventory: Sendable {
    public let relationships: [SkillRelationship]
    /// Only describes the sources included in this catalog attempt.
    public let complete: Bool

    public init(scan: SkillScanResult) {
        complete = scan.complete
        relationships = Dictionary(grouping: scan.entries, by: Self.originalPath)
            .map { path, entries in
                SkillRelationship(originalPath: path, entries: entries.sorted {
                    if $0.root.tool != $1.root.tool { return $0.root.tool.rawValue < $1.root.tool.rawValue }
                    return $0.id < $1.id
                })
            }
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.originalPath < $1.originalPath : order == .orderedAscending
            }
    }

    public func relationship(for entry: SkillEntry) -> SkillRelationship? {
        let path = Self.originalPath(entry)
        return relationships.first { $0.originalPath == path }
    }

    private static func originalPath(_ entry: SkillEntry) -> String {
        let path: String
        if let target = entry.linkTarget {
            path = target.hasPrefix("/") ? target : entry.url.deletingLastPathComponent().path + "/" + target
        } else {
            path = entry.url.path
        }
        // Lexical normalization only; Foundation path resolution must not turn
        // a link into an authorized or verified original directory.
        var components: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(part) }
        }
        return "/" + components.joined(separator: "/")
    }
}
