import Darwin
import Foundation

public struct ProjectDirectory: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let title: String
    public let createdAt: Date?
    public let modifiedAt: Date
    public let snapshot: FileSnapshot
    public let issue: String?
    public var url: URL { URL(fileURLWithPath: path) }
    public var isAvailable: Bool { issue == nil }
}

public struct ProjectCatalogResult: Sendable {
    public let rootPath: String
    public let rootSnapshot: FileSnapshot
    public let projects: [ProjectDirectory]
    public let looseFileCount: Int
}

/// Lists immediate project folders. It never recursively scans every project in a library.
public struct ProjectCatalog: Sendable {
    public init() {}

    public func list(_ directory: URL) async throws -> ProjectCatalogResult {
        let worker = Task.detached(priority: .userInitiated) { try Self.read(directory) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static func read(_ directory: URL) throws -> ProjectCatalogResult {
        try Task.checkCancellation()
        let root = try PathSafety.prepareRoot(directory)
        let before = try Snapshotter.capture(root)
        try Snapshotter.validateMetadata(root, state: before)
        guard try root.resourceValues(forKeys: [.isPackageKey]).isPackage != true else {
            throw CleanupError.unsafe("请选择存放多个项目的文件夹，不能将文档包作为项目总目录。")
        }
        var projects: [ProjectDirectory] = []
        var looseFiles = 0
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for child in children {
            try Task.checkCancellation()
            let child = child.standardizedFileURL
            let state = try Snapshotter.capture(child)
            let kind = state.mode & UInt32(S_IFMT)
            guard kind == UInt32(S_IFDIR) || kind == UInt32(S_IFLNK) else { looseFiles += 1; continue }
            var issue: String?
            var createdAt: Date?
            if kind == UInt32(S_IFLNK) { issue = "符号链接：请选择真实项目文件夹" }
            else if state.device != before.device { issue = "其他挂载卷：请单独选择该目录" }
            else {
                do {
                    try Snapshotter.validateMetadata(child, state: state)
                    let values = try child.resourceValues(forKeys: [.isPackageKey, .creationDateKey])
                    if values.isPackage == true { looseFiles += 1; continue }
                    createdAt = values.creationDate
                } catch { issue = error.localizedDescription }
            }
            projects.append(ProjectDirectory(path: child.path, title: child.lastPathComponent, createdAt: createdAt,
                modifiedAt: Date(timeIntervalSince1970: Double(state.modifiedNanoseconds) / 1e9), snapshot: state, issue: issue))
        }
        try Snapshotter.verify(root, matches: before)
        return ProjectCatalogResult(rootPath: root.path, rootSnapshot: before,
            projects: projects.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }, looseFileCount: looseFiles)
    }

    public static func validateOpening(_ project: ProjectDirectory, from catalog: ProjectCatalogResult) throws -> URL {
        let root = URL(fileURLWithPath: catalog.rootPath)
        guard project.isAvailable, catalog.projects.contains(project), project.url.deletingLastPathComponent().path == root.path else {
            throw CleanupError.unsafe("此文件夹不属于当前项目库，请刷新后重试。")
        }
        try PathSafety.validate(project.url, within: root)
        let rootNow = try Snapshotter.capture(root)
        let current = try Snapshotter.capture(project.url)
        guard rootNow.device == catalog.rootSnapshot.device, rootNow.inode == catalog.rootSnapshot.inode,
              current.device == project.snapshot.device, current.inode == project.snapshot.inode,
              current.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) else {
            throw CleanupError.changed("项目文件夹已被替换，请刷新项目库。")
        }
        try Snapshotter.validateMetadata(project.url, state: current)
        guard try project.url.resourceValues(forKeys: [.isPackageKey]).isPackage != true else {
            throw CleanupError.unsafe("文档包不作为项目目录打开。")
        }
        return project.url
    }
}
