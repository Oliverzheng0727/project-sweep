import Foundation

public actor RecordStore {
    public let directory: URL
    private var file: URL { directory.appendingPathComponent("operations.json") }
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ProjectSweep")
    }
    public func load() throws -> [CleanupRecord] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        try PathSafety.validate(file, within: directory)
        return try JSONDecoder().decode([CleanupRecord].self, from: Data(contentsOf: file))
    }
    public func append(_ records: [CleanupRecord]) throws {
        var current = try load(); current.append(contentsOf: records); try save(current)
    }
    public func replace(_ record: CleanupRecord) throws {
        var current = try load()
        if let index = current.firstIndex(where: { $0.id == record.id }) { current[index] = record }
        else { current.append(record) }
        try save(current)
    }
    private func save(_ records: [CleanupRecord]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PathSafety.validate(directory, within: directory)
        let data = try JSONEncoder().encode(records)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
