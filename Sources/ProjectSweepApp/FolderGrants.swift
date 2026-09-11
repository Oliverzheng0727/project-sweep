import AppKit
import Foundation

@MainActor
final class FolderGrants {
    private var active: [String: URL] = [:]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func revoke(_ key: String) {
        active.removeValue(forKey: key)?.stopAccessingSecurityScopedResource()
        defaults.removeObject(forKey: "grant.\(key)")
    }

    func grant(_ url: URL, key: String) throws -> URL {
        let url = url.standardizedFileURL
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let started = url.startAccessingSecurityScopedResource()
        do {
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            let canonical = url.resolvingSymlinksInPath()
            let data = try canonical.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            if let old = active[key] { old.stopAccessingSecurityScopedResource() }
            active[key] = url
            defaults.set(data, forKey: "grant.\(key)")
            return canonical
        } catch {
            if started { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func resolve(_ key: String) throws -> URL? {
        guard let data = defaults.data(forKey: "grant.\(key)") else { return nil }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw NSError(domain: "FolderGrant", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件夹授权已失效，请重新选择。"] ) }
        _ = url.startAccessingSecurityScopedResource()
        do {
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
        }
        catch { url.stopAccessingSecurityScopedResource(); throw error }
        if let old = active[key] { old.stopAccessingSecurityScopedResource() }
        active[key] = url
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
