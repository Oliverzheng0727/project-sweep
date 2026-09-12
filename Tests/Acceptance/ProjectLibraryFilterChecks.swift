import CleanupCore
import Foundation

@main struct ProjectLibraryFilterChecks {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Sweep-library-filter-\(UUID())").standardizedFileURL
        defer { try? fm.removeItem(at: root) }
        let alpha = root.appendingPathComponent("Alpha")
        let beta = root.appendingPathComponent("Beta")
        try fm.createDirectory(at: alpha, withIntermediateDirectories: true)
        try fm.createDirectory(at: beta, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Linked"), withDestinationURL: alpha)

        let catalog = try await ProjectCatalog().list(root)
        let alphaProject = catalog.projects.first { $0.path == alpha.path }!
        let betaProject = catalog.projects.first { $0.path == beta.path }!
        let summaries = [beta.path: ProjectScanSummary(bytes: 200, cacheBytes: 80, scannedAt: Date(), snapshot: betaProject.snapshot)]

        var query = ProjectLibraryQuery()
        query.filter = .scanned
        guard query.apply(to: catalog.projects, summaries: summaries, recentPaths: [], pinnedPaths: []).map(\.path) == [beta.path] else {
            fatalError("Scanned filter included an unscanned project")
        }
        query.filter = .withCache
        guard query.apply(to: catalog.projects, summaries: summaries, recentPaths: [], pinnedPaths: []).map(\.path) == [beta.path] else {
            fatalError("Cache filter included a project without a cache summary")
        }
        query.filter = .unavailable
        guard query.apply(to: catalog.projects, summaries: summaries, recentPaths: [], pinnedPaths: []).map(\.title) == ["Linked"] else {
            fatalError("Unavailable filter did not isolate unavailable projects")
        }
        query.filter = .recent
        guard query.apply(to: catalog.projects, summaries: summaries, recentPaths: [alpha.path], pinnedPaths: []).map(\.path) == [alpha.path] else {
            fatalError("Recent filter ignored the recorded project")
        }
        query.filter = .all
        guard query.apply(to: catalog.projects, summaries: summaries, recentPaths: [], pinnedPaths: [beta.path]).first?.path == beta.path else {
            fatalError("Pinned project was not promoted")
        }
        query.search = "alpha"
        guard query.apply(to: catalog.projects, summaries: summaries, recentPaths: [], pinnedPaths: [beta.path]).map(\.path) == [alphaProject.path] else {
            fatalError("Search did not compose with pinning and filtering")
        }
        print("PASS: project library filters scanned, cached, recent and unavailable projects; pins sort first")
    }
}
