import Foundation

public enum ProjectMode: String, Codable, CaseIterable, Sendable {
    case organize, remove
    public var title: String { self == .organize ? "整理项目" : "移除项目" }
}

public enum ToolKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, cursor
    public var id: String { rawValue }
    public var title: String {
        switch self { case .codex: "Codex"; case .claude: "Claude Code"; case .cursor: "Cursor" }
    }
    public var defaultRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .codex: return home.appendingPathComponent(".codex")
        case .claude: return home.appendingPathComponent(".claude")
        case .cursor: return home.appendingPathComponent("Library/Application Support/Cursor")
        }
    }
}

public enum CleanupCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case cache, build, dependency, temporary, document, source, other, toolCache, toolLog, session, projectMemory, project
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cache: "项目缓存"
        case .build: "构建产物"
        case .dependency: "依赖与环境"
        case .temporary: "临时文件"
        case .document: "文档与作品"
        case .source: "源码与脚本"
        case .other: "其他文件"
        case .toolCache: "工具缓存"
        case .toolLog: "工具日志"
        case .session: "历史会话"
        case .projectMemory: "项目记忆"
        case .project: "项目文件夹"
        }
    }
}

public enum CleanupRisk: String, Codable, Sendable {
    case recommended, review, protected, unavailable
    public var title: String {
        switch self { case .recommended: "明确缓存"; case .review: "需要查看"; case .protected: "已保护"; case .unavailable: "暂不可清理" }
    }
    public var selectable: Bool { self == .recommended || self == .review }
}

public enum CleanupAction: String, Codable, Sendable { case trash, deleteSession }

public struct FileSnapshot: Codable, Hashable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var size: Int64
    public var modifiedNanoseconds: Int64
    public var mode: UInt32
    public var treeDigest: String?
    public init(device: UInt64, inode: UInt64, size: Int64, modifiedNanoseconds: Int64, mode: UInt32, treeDigest: String? = nil) {
        self.device = device; self.inode = inode; self.size = size
        self.modifiedNanoseconds = modifiedNanoseconds; self.mode = mode; self.treeDigest = treeDigest
    }
}

public struct CleanupItem: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var path: String
    public var rootPath: String
    public var title: String
    public var category: CleanupCategory
    public var risk: CleanupRisk
    public var reason: String
    public var bytes: Int64
    public var modifiedAt: Date?
    public var isDirectory: Bool
    public var parentPath: String?
    public var tool: ToolKind?
    public var sessionID: String?
    public var projectPath: String?
    public var relatedIDs: [String]
    public var details: [String]
    public var action: CleanupAction
    public var snapshot: FileSnapshot?
    /// Adapter metadata only. Never put transcript bodies or credentials here.
    public var metadata: [String: String]
    public var url: URL { URL(fileURLWithPath: path) }
    public var isSelectable: Bool { risk.selectable }
    public init(id: String? = nil, path: String, rootPath: String, title: String? = nil,
                category: CleanupCategory = .other, risk: CleanupRisk = .review, reason: String,
                bytes: Int64 = 0, modifiedAt: Date? = nil, isDirectory: Bool = false,
                parentPath: String? = nil, tool: ToolKind? = nil, sessionID: String? = nil,
                projectPath: String? = nil, relatedIDs: [String] = [], details: [String] = [],
                action: CleanupAction = .trash, snapshot: FileSnapshot? = nil, metadata: [String: String] = [:]) {
        self.id = id ?? "\(tool?.rawValue ?? "project"):\(path)"
        self.path = path; self.rootPath = rootPath
        self.title = title ?? URL(fileURLWithPath: path).lastPathComponent
        self.category = category; self.risk = risk; self.reason = reason; self.bytes = bytes
        self.modifiedAt = modifiedAt; self.isDirectory = isDirectory; self.parentPath = parentPath
        self.tool = tool; self.sessionID = sessionID; self.projectPath = projectPath
        self.relatedIDs = relatedIDs; self.details = details; self.action = action
        self.snapshot = snapshot; self.metadata = metadata
    }
}

public struct ScanRequest: Sendable {
    public var root: URL
    public var mode: ProjectMode
    public var protectedPaths: Set<String>
    public init(root: URL, mode: ProjectMode = .organize, protectedPaths: Set<String> = []) {
        self.root = root; self.mode = mode; self.protectedPaths = protectedPaths
    }
}

public enum ScanPhase: Sendable { case protection, files, verification }

public struct ScanProgress: Sendable {
    public var count: Int
    public var path: String
    public var phase: ScanPhase
    public init(count: Int, path: String, phase: ScanPhase = .files) {
        self.count = count; self.path = path; self.phase = phase
    }
}

public struct ScanResult: Sendable {
    public var rootPath: String
    public var items: [CleanupItem]
    public var warnings: [String]
    public var scannedAt: Date
    public var toolStatus: ToolScanStatus?
    public init(rootPath: String, items: [CleanupItem], warnings: [String] = [], scannedAt: Date = Date(), toolStatus: ToolScanStatus? = nil) {
        self.rootPath = rootPath; self.items = items; self.warnings = warnings; self.scannedAt = scannedAt; self.toolStatus = toolStatus
    }
}

public struct ToolConfiguration: Codable, Sendable, Identifiable {
    public var tool: ToolKind
    public var root: URL
    public var executablePath: String?
    public var extraRoots: [URL]
    public var id: String { tool.rawValue }
    public init(tool: ToolKind, root: URL, executablePath: String? = nil, extraRoots: [URL] = []) {
        self.tool = tool; self.root = root; self.executablePath = executablePath; self.extraRoots = extraRoots
    }
}

public struct CleanupPlan: Identifiable, Sendable {
    public let id: UUID
    public let items: [CleanupItem]
    public let createdAt: Date
    public var trashBytes: Int64 { items.filter { $0.action == .trash }.reduce(0) { $0 + $1.bytes } }
    public var sessionBytes: Int64 { items.filter { $0.action == .deleteSession }.reduce(0) { $0 + $1.bytes } }
    public init(items: [CleanupItem]) { id = UUID(); self.items = items; createdAt = Date() }
}

public enum CleanupStatus: String, Codable, Sendable {
    case succeeded, failed, skipped, restored
    public var title: String {
        switch self { case .succeeded: "已完成"; case .failed: "失败"; case .skipped: "已跳过"; case .restored: "已恢复" }
    }
}

public struct CleanupRecord: Identifiable, Codable, Sendable {
    public var id: UUID
    public var batchID: UUID
    public var date: Date
    public var originalPath: String
    public var trashPath: String?
    public var action: CleanupAction
    public var tool: ToolKind?
    public var status: CleanupStatus
    public var bytes: Int64
    public var message: String
    public var trashSnapshot: FileSnapshot?
    /// Present only when the dedicated skill manager trashed a link itself.
    public var skillLinkTarget: String?
    public init(id: UUID = UUID(), batchID: UUID = UUID(), date: Date = Date(), originalPath: String,
                trashPath: String? = nil, action: CleanupAction, tool: ToolKind? = nil,
                status: CleanupStatus, bytes: Int64 = 0, message: String, trashSnapshot: FileSnapshot? = nil, skillLinkTarget: String? = nil) {
        self.id = id; self.batchID = batchID; self.date = date; self.originalPath = originalPath
        self.trashPath = trashPath; self.action = action; self.tool = tool
        self.status = status; self.bytes = bytes; self.message = message; self.trashSnapshot = trashSnapshot
        self.skillLinkTarget = skillLinkTarget
    }
}

public enum CleanupError: LocalizedError, Sendable {
    case unsafe(String), changed(String), unavailable(String), io(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .unsafe(let text), .changed(let text), .unavailable(let text), .io(let text): text
        case .cancelled: "操作已取消"
        }
    }
}
