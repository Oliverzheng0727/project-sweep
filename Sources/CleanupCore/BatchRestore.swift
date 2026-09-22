import Foundation
import Darwin

/// A cleanup operation is identified by its original batch ID, including partial failures.
public struct CleanupBatch: Identifiable, Sendable {
    public let id: UUID
    public let records: [CleanupRecord]
    public var date: Date { records.map(\.date).min() ?? .distantPast }
    public var restorableRecords: [CleanupRecord] { records.filter(\.canAttemptRestore) }
    public var restoredCount: Int { records.filter { $0.status == .restored }.count }
    public var failedCount: Int { records.filter { $0.status == .failed }.count }
    public var skippedCount: Int { records.filter { $0.status == .skipped }.count }
    public var processedBytes: Int64 {
        records.filter { $0.status == .succeeded || $0.status == .restored }.reduce(0) { $0 + max(0, $1.bytes) }
    }
    public var tools: [ToolKind] { ToolKind.allCases.filter { tool in records.contains { $0.tool == tool } } }
    public var contextPaths: [String] {
        Set(records.map { URL(fileURLWithPath: $0.originalPath).deletingLastPathComponent().path }).sorted()
    }

    public static func group(_ records: [CleanupRecord]) -> [CleanupBatch] {
        let unique = uniqueRecords(records)
        return Dictionary(grouping: unique, by: \.batchID).map { id, records in
            CleanupBatch(id: id, records: records.sorted { $0.originalPath.localizedStandardCompare($1.originalPath) == .orderedAscending })
        }.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
    }
}

extension CleanupRecord {
    /// Physical availability is checked at execution. This only describes recovery metadata.
    public var canAttemptRestore: Bool {
        action == .trash && status == .succeeded && trashPath != nil && trashSnapshot != nil
    }

    fileprivate func matchesRestoreReview(_ reviewed: CleanupRecord) -> Bool {
        id == reviewed.id && batchID == reviewed.batchID && action == reviewed.action &&
        status == reviewed.status && originalPath == reviewed.originalPath && trashPath == reviewed.trashPath &&
        trashSnapshot == reviewed.trashSnapshot && skillLinkTarget == reviewed.skillLinkTarget && tool == reviewed.tool && bytes == reviewed.bytes
    }
}

public struct RestorePlan: Identifiable, Sendable {
    public let id: UUID
    public let records: [CleanupRecord]
    public let excludedRecords: [CleanupRecord]
    public var bytes: Int64 { records.reduce(0) { $0 + max(0, $1.bytes) } }

    public init(records: [CleanupRecord]) {
        id = UUID()
        let unique = uniqueRecords(records)
        self.records = unique.filter(\.canAttemptRestore)
        excludedRecords = unique.filter { !$0.canAttemptRestore }
    }
}

public struct RestoreOutcome: Identifiable, Sendable {
    public enum Status: Sendable { case restored, failed, skipped }
    public var id: UUID { record.id }
    public let record: CleanupRecord
    public let status: Status
    public let message: String
}

public struct RestoreReport: Identifiable, Sendable {
    public let id: UUID
    public let outcomes: [RestoreOutcome]
    public var restoredCount: Int { outcomes.filter { $0.status == .restored }.count }
}

/// Serializes recovery of a given record across executor instances in this process.
/// Every physical move also uses TrashService's atomic no-overwrite rename.
private actor RestoreClaims {
    static let shared = RestoreClaims()
    private var active: Set<String> = []
    func acquire(_ keys: Set<String>) -> Bool {
        guard active.isDisjoint(with: keys) else { return false }
        active.formUnion(keys)
        return true
    }
    func release(_ keys: Set<String>) { active.subtract(keys) }
}

public struct RestoreExecutor: Sendable {
    private let store: RecordStore
    public init(store: RecordStore = RecordStore()) { self.store = store }

    public func execute(_ plan: RestorePlan) async -> RestoreReport {
        let prefix = store.directory.standardizedFileURL.resolvingSymlinksInPath().path
        let keys = Set(plan.records.map { prefix + "/" + $0.id.uuidString })
        guard await RestoreClaims.shared.acquire(keys) else {
            return RestoreReport(id: plan.id, outcomes: plan.records.map {
                RestoreOutcome(record: $0, status: .skipped, message: "这些文件正在恢复，请等待当前操作完成。")
            })
        }
        var outcomes: [RestoreOutcome] = []
        for reviewed in plan.records {
            if Task.isCancelled {
                outcomes.append(RestoreOutcome(record: reviewed, status: .skipped, message: "恢复已取消，此项未处理。"))
                continue
            }
            do {
                let persisted = try await store.load()
                let matches = persisted.filter { $0.id == reviewed.id }
                guard matches.count == 1, let current = matches.first,
                      current.canAttemptRestore, current.matchesRestoreReview(reviewed) else {
                    throw CleanupError.changed("清理记录已变化或不再支持恢复，请重新查看清理记录。")
                }
                try Task.checkCancellation()
                if let path = current.trashPath {
                    var info = stat()
                    if lstat(path, &info) != 0, errno == ENOENT {
                        throw CleanupError.unavailable("废纸篓中的文件已不存在，可能已被清空或移动。")
                    }
                }
                let restored = try await CleanupExecutor(store: store).restore(current)
                outcomes.append(RestoreOutcome(record: restored, status: .restored, message: restored.message))
            } catch is CancellationError {
                outcomes.append(RestoreOutcome(record: reviewed, status: .skipped, message: "恢复已取消，此项未处理。"))
            } catch {
                // A failed recovery does not change a successful cleanup into a failure.
                // The file can be retried after the conflict or permission issue is resolved.
                outcomes.append(RestoreOutcome(record: reviewed, status: .failed, message: error.localizedDescription))
            }
        }
        await RestoreClaims.shared.release(keys)
        return RestoreReport(id: plan.id, outcomes: outcomes)
    }
}

private func uniqueRecords(_ records: [CleanupRecord]) -> [CleanupRecord] {
    let current = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    var emitted: Set<UUID> = []
    return records.compactMap { emitted.insert($0.id).inserted ? current[$0.id] : nil }
}
