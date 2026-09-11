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
