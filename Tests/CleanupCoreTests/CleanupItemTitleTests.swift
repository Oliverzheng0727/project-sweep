import XCTest
import CSQLite
@testable import CleanupCore

final class CleanupItemTitleTests: XCTestCase {
    private var previousLanguage: Any?

    override func setUp() {
        super.setUp()
        previousLanguage = UserDefaults.standard.object(forKey: "language")
    }

    override func tearDown() {
        if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: "language") }
        else { UserDefaults.standard.removeObject(forKey: "language") }
        super.tearDown()
    }

    func testGeneratedTitlesFollowLanguageWithoutChangingStoredTitle() throws {
        let item = CleanupItem(path: "/fixture/session", rootPath: "/fixture", title: "会话 12345678",
            category: .session, reason: "fixture", sessionID: "12345678-1234-1234-1234-123456789abc",
            action: .deleteSession, metadata: ["generatedTitle": "session"])
        UserDefaults.standard.set("english", forKey: "language")
        XCTAssertEqual(item.displayTitle, "Session 12345678")
        XCTAssertEqual(item.title, "会话 12345678")
        let decoded = try JSONDecoder().decode(CleanupItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded.displayTitle, "Session 12345678")
        UserDefaults.standard.set("simplifiedChinese", forKey: "language")
        XCTAssertEqual(decoded.displayTitle, "会话 12345678")
    }

    func testUnmarkedUserTitlesAndLegacyItemsRemainVerbatim() throws {
        UserDefaults.standard.set("english", forKey: "language")
        for title in ["论文讨论", "会话 12345678", "未知格式的工作区会话存储", "English session"] {
            let item = CleanupItem(path: "/fixture/session", rootPath: "/fixture", title: title,
                category: .session, reason: "fixture", action: .deleteSession)
            let decoded = try JSONDecoder().decode(CleanupItem.self, from: JSONEncoder().encode(item))
            XCTAssertEqual(decoded.displayTitle, title)
        }
        let file = CleanupItem(path: "/fixture/会话.txt", rootPath: "/fixture", reason: "fixture")
        XCTAssertEqual(file.displayTitle, "会话.txt")
    }

    func testClaudeMarksFallbackButPreservesCustomTitles() throws {
        let root = try fixture()
        let untitled = UUID().uuidString
        let custom = UUID().uuidString
        let generated = UUID().uuidString
        for (id, titleKey, title) in [(untitled, "", ""), (custom, "customTitle", "会话 我的论文"),
                                     (generated, "aiTitle", "中文自动标题")] {
            var row = ["type": "user", "sessionId": id, "cwd": "/work/project"]
            if !titleKey.isEmpty { row[titleKey] = title }
            try write(root, "projects/p/\(id).jsonl", data: JSONSerialization.data(withJSONObject: row))
        }
        var warnings: [String] = []
        var status = ToolScanStatus()
        let items = try ClaudeAdapter.scan(ToolConfiguration(tool: .claude, root: root), warnings: &warnings, status: &status)
        UserDefaults.standard.set("english", forKey: "language")
        XCTAssertEqual(items.first { $0.sessionID == untitled }?.displayTitle, "Session \(untitled.prefix(8))")
        XCTAssertEqual(items.first { $0.sessionID == custom }?.displayTitle, "会话 我的论文")
        XCTAssertEqual(items.first { $0.sessionID == generated }?.displayTitle, "中文自动标题")
        XCTAssertNil(items.first { $0.sessionID == custom }?.metadata["generatedTitle"])
        XCTAssertNil(items.first { $0.sessionID == generated }?.metadata["generatedTitle"])
    }

    func testCursorFallbackTitlesTranslateWhileDeletionStaysDisabled() throws {
        let root = try fixture()
        try write(root, "User/workspaceStorage/unknown/state.vscdb", data: Data("unknown".utf8))
        let database = try write(root, "User/workspaceStorage/known/state.vscdb", data: Data())
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE ItemTable(key TEXT,value TEXT); INSERT INTO ItemTable VALUES ('composer.composerData','{\"allComposers\":[{\"composerId\":\"abcd1234xyz\"}]}');", nil, nil, nil), SQLITE_OK)
        var warnings: [String] = []
        var status = ToolScanStatus()
        let items = try CursorAdapter.scan(ToolConfiguration(tool: .cursor, root: root), warnings: &warnings, status: &status)
        UserDefaults.standard.set("english", forKey: "language")
        XCTAssertEqual(items.first { $0.sessionID == "abcd1234xyz" }?.displayTitle, "Session abcd1234")
        XCTAssertEqual(items.first { $0.sessionID == nil }?.displayTitle, "Workspace session storage has an unknown format")
        XCTAssertTrue(items.allSatisfy { !$0.isSelectable })
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-title-test-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func write(_ root: URL, _ path: String, data: Data) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
}
