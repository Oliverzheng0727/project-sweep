import CleanupCore
import Foundation

/// A bounded display cache, never an inventory or an authorization to clean.
/// Persisting only root identity and aggregates also keeps filenames and content out.
@MainActor
final class ProjectScanSummaryStore {
    struct LoadResult {
        var summaries: [String: ProjectScanSummary]
        var discardedInvalidData: Bool
    }
    private struct SavedSummary: Codable {
        let path: String
        let bytes: Int64
        let cacheBytes: Int64
        let scannedAt: Date
        let device: UInt64
        let inode: UInt64
    }
    private struct Envelope: Codable {
        let version: Int
        let summaries: [SavedSummary]
    }
    private let defaults: UserDefaults
    private let key: String
    private let maximumRecords: Int
    private let maximumBytes: Int

    init(defaults: UserDefaults, key: String = "projectScanSummaryMetadata",
         maximumRecords: Int = 1_000, maximumBytes: Int = 1_048_576) {
        self.defaults = defaults; self.key = key
        self.maximumRecords = max(1, maximumRecords); self.maximumBytes = max(128, maximumBytes)
    }

    func load() -> LoadResult {
        guard let data = defaults.data(forKey: key) else { return LoadResult(summaries: [:], discardedInvalidData: false) }
        guard data.count <= maximumBytes, let saved = try? JSONDecoder().decode(Envelope.self, from: data),
              saved.version == 1, saved.summaries.count <= maximumRecords,
              saved.summaries.allSatisfy(Self.isValid), Set(saved.summaries.map(\.path)).count == saved.summaries.count else {
            defaults.removeObject(forKey: key)
            return LoadResult(summaries: [:], discardedInvalidData: true)
        }
        let summaries = saved.summaries.map { record in
            (record.path, ProjectScanSummary(bytes: record.bytes, cacheBytes: record.cacheBytes,
                scannedAt: record.scannedAt, snapshot: FileSnapshot(device: record.device, inode: record.inode,
                    size: 0, modifiedNanoseconds: 0, mode: 0), isHistorical: true))
        }
        return LoadResult(summaries: Dictionary(uniqueKeysWithValues: summaries), discardedInvalidData: false)
    }

    func save(_ summaries: [String: ProjectScanSummary]) {
        var records = summaries.map { path, summary in
            SavedSummary(path: path, bytes: summary.bytes, cacheBytes: summary.cacheBytes,
                         scannedAt: summary.scannedAt, device: summary.snapshot.device, inode: summary.snapshot.inode)
        }.filter(Self.isValid).sorted { left, right in
            left.scannedAt == right.scannedAt ? left.path < right.path : left.scannedAt > right.scannedAt
        }
        records = Array(records.prefix(maximumRecords))
        while !records.isEmpty {
            if let data = try? JSONEncoder().encode(Envelope(version: 1, summaries: records)), data.count <= maximumBytes {
                defaults.set(data, forKey: key)
                return
            }
            records.removeLast(max(1, records.count / 2))
        }
        defaults.removeObject(forKey: key)
    }

    private static func isValid(_ record: SavedSummary) -> Bool {
        record.path.hasPrefix("/") && record.path.utf8.count <= 16_384 && !record.path.contains("\0")
            && URL(fileURLWithPath: record.path).standardizedFileURL.path == record.path
            && record.bytes >= 0 && record.cacheBytes >= 0 && record.cacheBytes <= record.bytes
            && record.scannedAt.timeIntervalSince1970.isFinite && record.scannedAt.timeIntervalSince1970 >= 0
            && record.device != 0 && record.inode != 0
    }
}
