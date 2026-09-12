import CleanupCore
import Foundation

enum BrowserScope: Hashable { case all, projectFiles, relatedRecords }

struct BrowserFilters: Equatable {
    var search = ""
    var category: CleanupCategory?
    var risk: CleanupRisk?
    var tree = false
    var largestFirst = true
    var onlySelected = false
    var hasQuery: Bool { !search.isEmpty || category != nil || risk != nil || onlySelected }

    func sameQuery(as other: Self) -> Bool {
        search == other.search && category == other.category && risk == other.risk && onlySelected == other.onlySelected
    }

    func sortsBefore(_ left: CleanupItem, _ right: CleanupItem) -> Bool {
        if largestFirst, left.bytes != right.bytes { return left.bytes > right.bytes }
        return left.path.localizedStandardCompare(right.path) == .orderedAscending
    }

    func apply(to items: [CleanupItem], selected: Set<String>) -> [CleanupItem] {
        items.filter { item in
            (category == nil || item.category == category) && (risk == nil || item.risk == risk) &&
            (!onlySelected || selected.contains(item.id)) &&
            (search.isEmpty || item.path.localizedStandardContains(search) || item.title.localizedStandardContains(search))
        }.sorted(by: sortsBefore)
    }
}

struct ProjectScanSummary {
    var bytes: Int64
    var cacheBytes: Int64
    var scannedAt: Date
    var snapshot: FileSnapshot
}

enum ProjectLibraryFilter: String, CaseIterable, Identifiable {
    case all, recent, scanned, withCache, unavailable

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部项目"
        case .recent: "最近打开"
        case .scanned: "已扫描"
        case .withCache: "包含缓存"
        case .unavailable: "不可用"
        }
    }
}

struct ProjectLibraryQuery {
    var search = ""
    var filter: ProjectLibraryFilter = .all
    var newestFirst = false

    func apply(to projects: [ProjectDirectory], summaries: [String: ProjectScanSummary],
               recentPaths: [String], pinnedPaths: Set<String>) -> [ProjectDirectory] {
        let recentRanks = Dictionary(uniqueKeysWithValues: recentPaths.enumerated().map { ($0.element, $0.offset) })
        func summary(for project: ProjectDirectory) -> ProjectScanSummary? {
            guard let value = summaries[project.path], value.snapshot.device == project.snapshot.device,
                  value.snapshot.inode == project.snapshot.inode else { return nil }
            return value
        }
        return projects.filter { project in
            let matchesSearch = search.isEmpty || project.title.localizedStandardContains(search)
                || project.path.localizedStandardContains(search)
            guard matchesSearch else { return false }
            switch filter {
            case .all: return true
            case .recent: return recentRanks[project.path] != nil
            case .scanned: return summary(for: project) != nil
            case .withCache: return (summary(for: project)?.cacheBytes ?? 0) > 0
            case .unavailable: return !project.isAvailable
            }
        }.sorted { left, right in
            let leftPinned = pinnedPaths.contains(left.path)
            let rightPinned = pinnedPaths.contains(right.path)
            if leftPinned != rightPinned { return leftPinned }
            if filter == .recent {
                let leftRank = recentRanks[left.path] ?? .max
                let rightRank = recentRanks[right.path] ?? .max
                if leftRank != rightRank { return leftRank < rightRank }
            }
            if newestFirst, left.createdAt != right.createdAt {
                return (left.createdAt ?? .distantPast) > (right.createdAt ?? .distantPast)
            }
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
    }
}
