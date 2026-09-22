import XCTest
import Darwin
@testable import CleanupCore

final class ToolDirectoryDiscoveryTests: XCTestCase, @unchecked Sendable {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sweep-ToolDiscovery-\(UUID())").standardizedFileURL
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func directory(_ path: String) throws -> URL {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testOnlyRequestedDirectoriesAreDiscoveredAndContentsAreNotScanned() async throws {
        let codex = try directory("中文路径/.codex")
        let claude = try directory("中文路径/.claude")
        let blockedChild = try directory("中文路径/.codex/不应访问")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blockedChild.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blockedChild.path) }
        let result = try await ToolDirectoryDiscovery(roots: [.codex: codex]).discover()
        XCTAssertEqual(result.roots.mapValues(\.path), [.codex: codex.path])
        XCTAssertTrue(result.unavailable.isEmpty)
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: claude.path))
    }

    func testMissingCandidatesAreSeparateFromUnreadableAndAreNeverCreated() async throws {
        let missing = base.appendingPathComponent("not-installed/.codex")
        let claude = try directory(".claude")
        let result = try await ToolDirectoryDiscovery(roots: [.codex: missing, .claude: claude]).discover()
        XCTAssertEqual(result.roots.mapValues(\.path), [.claude: claude.path])
        XCTAssertEqual(result.missing, [.codex])
        XCTAssertTrue(result.unavailable.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }

    func testFinalAndAncestorSymlinksAreUnavailableEvenWhenDestinationIsMissing() async throws {
        let target = try directory("target")
        let directLink = base.appendingPathComponent(".codex")
        let ancestorLink = base.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: directLink, withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: target)
        let result = try await ToolDirectoryDiscovery(roots: [
            .codex: directLink, .claude: ancestorLink.appendingPathComponent("missing")
        ]).discover()
        XCTAssertTrue(result.roots.isEmpty)
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertEqual(Set(result.unavailable.keys), [.codex, .claude])
        XCTAssertTrue(result.unavailable.values.allSatisfy { $0.contains("符号链接") })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testUnreadableAncestorIsUnavailableRatherThanNotInstalled() async throws {
        let parent = try directory("unreadable")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        let result = try await ToolDirectoryDiscovery(roots: [.codex: parent.appendingPathComponent(".codex")]).discover()
        XCTAssertTrue(result.roots.isEmpty)
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertNotNil(result.unavailable[.codex])
    }

    func testUnsearchableDirectoryIsUnavailable() async throws {
        let candidate = try directory(".codex")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path) }
        let result = try await ToolDirectoryDiscovery(roots: [.codex: candidate]).discover()
        XCTAssertTrue(result.roots.isEmpty)
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertNotNil(result.unavailable[.codex])
    }

    func testPackageAndPackageAncestorAreUnavailableWithoutExpansion() async throws {
        let package = try directory("Document.app")
        let result = try await ToolDirectoryDiscovery(roots: [
            .codex: package, .claude: package.appendingPathComponent("Contents/.claude")
        ]).discover()
        XCTAssertTrue(result.roots.isEmpty)
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertEqual(Set(result.unavailable.keys), [.codex, .claude])
        XCTAssertTrue(result.unavailable.values.allSatisfy { $0.contains("包") })
    }

    func testNonDirectoryCandidatesAreUnavailable() async throws {
        let file = base.appendingPathComponent("ordinary-file")
        try Data("isolated fixture".utf8).write(to: file)
        let result = try await ToolDirectoryDiscovery(roots: [.codex: file]).discover()
        XCTAssertTrue(result.roots.isEmpty)
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertNotNil(result.unavailable[.codex])
        XCTAssertEqual(try Data(contentsOf: file), Data("isolated fixture".utf8))
    }

    func testCancellationPropagatesEvenWithNoCandidates() async throws {
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ToolDirectoryDiscovery(roots: [:]).discover()
        }
        do { _ = try await worker.value; XCTFail("Cancelled discovery returned a result") }
        catch is CancellationError { }
    }
}
