import Foundation
import CleanupCore

@main struct PreviewChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sweep-preview-check-" + UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("作品.txt")
        try Data("safe local fixture".utf8).write(to: file)
        let rootState = try Snapshotter.capture(root)
        let item = CleanupItem(path: file.path, rootPath: root.path, category: .document, risk: .protected,
            reason: "fixture", snapshot: try Snapshotter.capture(file), metadata: ["rootIdentity": "\(rootState.device):\(rootState.inode)"])
        var passed = 0
        func rejects(_ name: String, _ operation: () throws -> Void) throws {
            do { try operation() } catch { print("PASS: \(name)"); passed += 1; return }
            throw NSError(domain: "PreviewChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected rejection: \(name)"])
        }
        _ = try PreviewSafety.validate(item, authorizedRoot: root)
        print("PASS: protected regular document preview"); passed += 1
        var unavailable = item; unavailable.risk = .unavailable
        try rejects("unavailable item") { _ = try PreviewSafety.validate(unavailable, authorizedRoot: root) }
        var session = item; session.action = .deleteSession
        try rejects("session item") { _ = try PreviewSafety.validate(session, authorizedRoot: root) }
        try rejects("unauthorized root") { _ = try PreviewSafety.validate(item, authorizedRoot: root.appendingPathComponent("other")) }
        try Data("changed content now differs".utf8).write(to: file)
        try rejects("changed file snapshot") { _ = try PreviewSafety.validate(item, authorizedRoot: root) }
        try fm.removeItem(at: file)
        try fm.createSymbolicLink(at: file, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        try rejects("replaced symlink escaping root") { _ = try PreviewSafety.validate(item, authorizedRoot: root) }
        let folder = root.appendingPathComponent("普通目录")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let folderItem = CleanupItem(path: folder.path, rootPath: root.path, category: .document, risk: .protected, reason: "fixture", isDirectory: true, snapshot: try Snapshotter.capture(folder), metadata: item.metadata)
        try rejects("ordinary directory") { _ = try PreviewSafety.validate(folderItem, authorizedRoot: root) }
        let package = root.appendingPathComponent("Fixture.app")
        try fm.createDirectory(at: package, withIntermediateDirectories: false)
        let packageItem = CleanupItem(path: package.path, rootPath: root.path, category: .document, risk: .protected, reason: "fixture", isDirectory: true, snapshot: try Snapshotter.capture(package, recursive: true), metadata: item.metadata)
        _ = try PreviewSafety.validate(packageItem, authorizedRoot: root)
        print("PASS: opaque local package preview"); passed += 1
        print("\(passed) preview boundary checks passed")
    }
}
