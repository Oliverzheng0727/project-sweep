import Foundation

struct ProjectLibraryLocation: Identifiable, Equatable {
    enum Availability: Equatable { case available, unavailable }

    let id: String
    var path: String
    var availability: Availability = .unavailable
    var message: String?
    var title: String { path.isEmpty ? "原项目库" : URL(fileURLWithPath: path).lastPathComponent }
    var isAvailable: Bool { availability == .available }
    var grantKey: String { "library.\(id)" }
}

/// Stores only entry identity and its last known path. Bookmarks remain independently
/// managed by FolderGrants so an offline volume never removes its saved entry.
@MainActor
final class ProjectLibraryStore {
    private struct SavedLocation: Codable { let id: String; let path: String }
    private let defaults: UserDefaults
    private let locationsKey = "projectLibraryLocations"
    private let activeKey = "activeProjectLibraryID"

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load(using grants: FolderGrants) -> (locations: [ProjectLibraryLocation], activeID: String?) {
        let saved = defaults.data(forKey: locationsKey)
            .flatMap { try? JSONDecoder().decode([SavedLocation].self, from: $0) } ?? []
        var seen: Set<String> = []
        var locations = saved.filter { seen.insert($0.id).inserted }.map {
            ProjectLibraryLocation(id: $0.id, path: $0.path)
        }
        var activeID = defaults.string(forKey: activeKey)
        var migratedLegacy = false
        if locations.isEmpty, let legacy = defaults.data(forKey: "grant.library") {
            let id = UUID().uuidString
            defaults.set(legacy, forKey: "grant.library.\(id)")
            locations = [ProjectLibraryLocation(id: id, path: "")]
            activeID = id
            migratedLegacy = true
        }
        for index in locations.indices {
            do {
                guard let url = try grants.resolve(locations[index].grantKey) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                locations[index].path = url.path
                locations[index].availability = .available
            } catch {
                locations[index].message = "项目库暂不可用，请连接磁盘或重新授权。"
            }
        }
        if !locations.contains(where: { $0.id == activeID }) { activeID = locations.first?.id }
        save(locations, activeID: activeID)
        // The legacy bookmark is removed only after its replacement and entry exist.
        if migratedLegacy { grants.revoke("library") }
        return (locations, activeID)
    }

    func save(_ locations: [ProjectLibraryLocation], activeID: String?) {
        let saved = locations.map { SavedLocation(id: $0.id, path: $0.path) }
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: locationsKey) }
        if let activeID { defaults.set(activeID, forKey: activeKey) }
        else { defaults.removeObject(forKey: activeKey) }
    }
}
