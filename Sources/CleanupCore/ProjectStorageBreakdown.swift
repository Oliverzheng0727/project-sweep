import Foundation

/// Describes occupied space only; a storage kind does not imply permission to clean it.
public enum StorageKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case cache, dependencies, documents, images, video, audio, source, build, other
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cache: "缓存"
        case .dependencies: "依赖与环境"
        case .documents: "文档"
        case .images: "图片"
        case .video: "视频"
        case .audio: "音频"
        case .source: "源码与脚本"
        case .build: "构建产物"
        case .other: "其他文件"
        }
    }
    public var systemImage: String {
        switch self {
        case .cache: "arrow.triangle.2.circlepath"
        case .dependencies: "shippingbox"
        case .documents: "doc.text"
        case .images: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .source: "chevron.left.forwardslash.chevron.right"
        case .build: "hammer"
        case .other: "doc"
        }
    }
}

public struct StorageSegment: Identifiable, Sendable {
    public var id: StorageKind { kind }
    public let kind: StorageKind
    public let bytes: Int64
    public let count: Int
    public let incomplete: Bool
}

public struct ProjectStorageBreakdown: Sendable {
    public let segments: [StorageSegment]
    public var totalBytes: Int64 { segments.reduce(0) { $0 + $1.bytes } }
    public var isComplete: Bool { !segments.contains(where: \.incomplete) }
    public init(items: [CleanupItem]) {
        let units = ProjectOverview(items: items).units
        let index = ProjectStorageIndex(items: items, units: units)
        var metrics: [StorageKind: OverviewMetric] = [:]
        for item in units {
            let kind = index.kind(for: item) ?? .other
            var value = metrics[kind] ?? OverviewMetric(count: 0, bytes: 0, incomplete: false)
            value.count += 1
            value.bytes += item.bytes
            value.incomplete = value.incomplete || item.risk == .unavailable || item.snapshot == nil
            metrics[kind] = value
        }
        segments = StorageKind.allCases.compactMap { kind in
            metrics[kind].map { StorageSegment(kind: kind, bytes: $0.bytes, count: $0.count, incomplete: $0.incomplete) }
        }
    }
}

/// Indexes an existing scan once. Parent context is propagated in depth order without filesystem access.
public struct ProjectStorageIndex: Sendable {
    private let kinds: [String: StorageKind]
    private let unitIDs: Set<String>

    public init(items: [CleanupItem]) {
        self.init(items: items, units: ProjectOverview(items: items).units)
    }

    fileprivate init(items: [CleanupItem], units: [CleanupItem]) {
        unitIDs = Set(units.map(\.id))
        let ordered = items.filter { $0.tool == nil }.sorted { $0.path.count < $1.path.count }
        var contexts: [String: StorageKind] = [:]
        var classifications: [String: StorageKind] = [:]
        for item in ordered {
            let inherited = item.parentPath.flatMap { contexts[$0] }
            let ownContext: StorageKind?
            switch item.category {
            case .cache: ownContext = .cache
            case .dependency: ownContext = .dependencies
            case .build: ownContext = .build
            default: ownContext = nil
            }
            if item.isDirectory, let context = ownContext ?? inherited { contexts[item.path] = context }
            classifications[item.id] = Self.classify(item, inherited: inherited)
        }
        kinds = classifications
    }

    public func kind(for item: CleanupItem) -> StorageKind? { kinds[item.id] }

    /// Ordinary containers become tree context, not additional matches or cleanup selections.
    public func filterKind(for item: CleanupItem) -> StorageKind? {
        guard item.tool == nil, item.path != item.rootPath,
              !item.isDirectory || unitIDs.contains(item.id) else { return nil }
        return kinds[item.id]
    }

    private static func classify(_ item: CleanupItem, inherited: StorageKind?) -> StorageKind {
        let ext = item.url.pathExtension.lowercased()
        let source = item.category == .source || ProjectFileTypes.sourceExtensions.contains(ext)
        if source && item.risk == .protected && item.metadata["projectMode"] != ProjectMode.remove.rawValue { return .source }
        switch item.category {
        case .cache: return .cache
        case .dependency: return .dependencies
        case .build: return .build
        default: break
        }
        if let inherited, inherited == .dependencies || inherited == .build { return inherited }
        if source { return .source }
        if ProjectFileTypes.imageExtensions.contains(ext) { return .images }
        if ProjectFileTypes.videoExtensions.contains(ext) { return .video }
        if ProjectFileTypes.audioExtensions.contains(ext) { return .audio }
        if item.category == .document || ProjectFileTypes.documentExtensions.contains(ext) { return .documents }
        if inherited == .cache { return .cache }
        return .other
    }

}
