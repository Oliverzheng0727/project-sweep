import XCTest
@testable import CleanupCore

final class ProjectCacheRuleTests: XCTestCase, @unchecked Sendable {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Sweep-cache-中文-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    func testKnownProducerAndExactDefaultPathIdentifyRegenerableCaches() async throws {
        try file("package.json", #"{"dependencies":{"next":"16.0.0"},"devDependencies":{"parcel":"2.0.0","vite":"7.0.0"}}"#)
        for path in [".next/cache/webpack/pack.bin", ".parcel-cache/data.mdb", "node_modules/.vite/deps/cache.bin"] { try file(path) }
        let result = try await scan()
        for (path, producer) in [(".next/cache", "Next.js"), (".parcel-cache", "Parcel"), ("node_modules/.vite", "Vite")] {
            let entry = try item(path, in: result)
            XCTAssertEqual(entry.category, .cache)
            XCTAssertEqual(entry.risk, .recommended)
            XCTAssertEqual(entry.metadata["cacheProducer"], producer)
            XCTAssertFalse(entry.details.isEmpty, "The user needs the producer and rebuild impact before cleaning")
        }
        XCTAssertEqual(try item(".next", in: result).category, .build)
        XCTAssertEqual(try item("node_modules", in: result).category, .dependency)
    }

    func testCacheNamesWithoutMatchingManifestStayManual() async throws {
        try file("package.json", #"{"name":"vite","scripts":{"build":"next build"},"dependencies":{"unrelated":"1"}}"#)
        for path in [".next/cache/pack.bin", ".parcel-cache/data.mdb", "node_modules/.vite/cache.bin", ".cache/foo.bin", "temp/old.bin"] { try file(path) }
        let result = try await scan()
        for path in [".next/cache", ".parcel-cache", "node_modules/.vite", ".cache", "temp"] {
            XCTAssertEqual(try item(path, in: result).risk, .review)
            XCTAssertNil(try item(path, in: result).metadata["cacheProducer"])
        }
    }

    func testNestedProjectUsesOwnManifestWithoutInheritingParentDependency() async throws {
        try file("package.json", #"{"dependencies":{"next":"16"}}"#)
        try file("one/package.json", #"{"devDependencies":{"parcel":"2"}}"#)
        try file("one/.parcel-cache/data.mdb")
        try file("one/.next/cache/data.bin")
        try file("two/.parcel-cache/data.mdb")
        let result = try await scan()
        XCTAssertEqual(try item("one/.parcel-cache", in: result).risk, .recommended)
        XCTAssertEqual(try item("one/.next/cache", in: result).risk, .review)
        XCTAssertEqual(try item("two/.parcel-cache", in: result).risk, .review)
    }

    func testSourceAndArtworkAtAnyDepthPreventQuickCacheSelection() async throws {
        try file("package.json", #"{"devDependencies":{"parcel":"2","vite":"7"}}"#)
        try file("node_modules/.vite/deps/prebundled.js", "export const value = 1")
        try file(".parcel-cache/nested/原图.png")
        try file("__pycache__/nested/source.py")
        let result = try await scan()
        for path in ["node_modules/.vite", ".parcel-cache", "__pycache__"] {
            XCTAssertEqual(try item(path, in: result).category, .cache)
            XCTAssertEqual(try item(path, in: result).risk, .review, "A nested source or deliverable must not be bulk-selected")
        }
        XCTAssertEqual(try item("node_modules/.vite/deps/prebundled.js", in: result).category, .source)
        XCTAssertEqual(try item(".parcel-cache/nested/原图.png", in: result).category, .document)
    }

    func testTrackedKeptAndSkillContentStillBlocksCacheParents() async throws {
        try file("package.json", #"{"dependencies":{"next":"16"},"devDependencies":{"parcel":"2","vite":"7"}}"#)
        try file(".next/cache/tracked.bin")
        let kept = try file(".parcel-cache/keep.bin")
        try file("node_modules/.vite/.agents/skills/example/SKILL.md")
        try git(["init", "-q", root.path])
        try git(["-C", root.path, "add", ".next/cache/tracked.bin"])
        let result = try await ProjectScanner().scan(ScanRequest(root: root, protectedPaths: [kept.path]))
        for path in [".next/cache", ".parcel-cache", "node_modules/.vite"] {
            let entry = try item(path, in: result)
            XCTAssertEqual(entry.risk, .protected)
            XCTAssertThrowsError(try SelectionPlanner.makePlan(items: result.items, selectedIDs: [entry.id]))
        }
    }

    func testManifestOutsideSelectedScopeOrBehindLinkCannotSupplyEvidence() async throws {
        let manifest = try file("package.json", #"{"devDependencies":{"parcel":"2"}}"#)
        try file("child/.parcel-cache/data.mdb")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("child/package.json"), withDestinationURL: manifest)
        let child = try await ProjectScanner().scan(ScanRequest(root: root.appendingPathComponent("child")))
        XCTAssertEqual(child.items.first { $0.title == ".parcel-cache" }?.risk, .review)
        XCTAssertEqual(child.items.first { $0.title == "package.json" }?.risk, .unavailable)
        try file(".parcel-cache/data.mdb")
        let selectedCache = try await ProjectScanner().scan(ScanRequest(root: root.appendingPathComponent(".parcel-cache")))
        XCTAssertNil(selectedCache.items.first?.metadata["cacheProducer"])
    }

    func testInvalidOversizedAndUnreadableManifestsDoNotPromoteCaches() async throws {
        for (name, body) in [("invalid", "not JSON"), ("oversized", String(repeating: " ", count: 300_000) + #"{"dependencies":{"parcel":"2"}}"#),
                             ("wrongType", #"{"dependencies":{"parcel":true}}"#), ("emptyVersion", #"{"dependencies":{"parcel":""}}"#)] {
            try file(name + "/package.json", body)
            try file(name + "/.parcel-cache/data.mdb")
        }
        let locked = try file("locked/package.json", #"{"dependencies":{"parcel":"2"}}"#)
        try file("locked/.parcel-cache/data.mdb")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }
        let result = try await scan()
        for name in ["invalid", "oversized", "wrongType", "emptyVersion", "locked"] {
            let entry = try item(name + "/.parcel-cache", in: result)
            XCTAssertEqual(entry.risk, .review)
            XCTAssertNil(entry.metadata["cacheProducer"])
        }
    }

    func testReplacementPackageSpecificationsCannotSupplyProducerEvidence() async throws {
        let replacements = ["npm:other-package@2", "npm:parcel@2", "file:../replacement", "link:../replacement", "workspace:*",
                            "git+https://example.com/replacement.git", "git://example.com/replacement.git", "git@github.com:owner/repo.git",
                            "https://example.com/replacement.tgz", "http://example.com/replacement.tgz", "github:owner/repo", "owner/repo",
                            "../replacement", "./replacement", "/tmp/replacement", "~/replacement", "replacement.tgz"]
        for (index, version) in replacements.enumerated() {
            let body = try JSONSerialization.data(withJSONObject: ["dependencies": ["parcel": version]])
            try file("case-\(index)/package.json", String(decoding: body, as: UTF8.self))
            try file("case-\(index)/.parcel-cache/data.mdb")
        }
        try file("conflicting/package.json", #"{"dependencies":{"parcel":"2"},"optionalDependencies":{"parcel":"file:../replacement"}}"#)
        try file("conflicting/.parcel-cache/data.mdb")
        let result = try await scan()
        for path in replacements.indices.map({ "case-\($0)/.parcel-cache" }) + ["conflicting/.parcel-cache"] {
            let entry = try item(path, in: result)
            XCTAssertEqual(entry.risk, .review, path)
            XCTAssertNil(entry.metadata["cacheProducer"], path)
        }
    }

    func testRegistryVersionsRangesAndTagsRetainCacheEvidence() async throws {
        let versions = ["2.14.0", "^15", "~2.14.0", ">=2.0.0 <3", "2.x", "*", "2.0.0 - 2.14.0", "^2.0.0 || ^3.0.0",
                        "2.14.0-beta.1", "latest", "nextbeta"]
        for (index, version) in versions.enumerated() {
            let body = try JSONSerialization.data(withJSONObject: ["devDependencies": ["parcel": version]])
            try file("case-\(index)/package.json", String(decoding: body, as: UTF8.self))
            try file("case-\(index)/.parcel-cache/data.mdb")
        }
        let result = try await scan()
        for index in versions.indices {
            let entry = try item("case-\(index)/.parcel-cache", in: result)
            XCTAssertEqual(entry.risk, .recommended, versions[index])
            XCTAssertEqual(entry.metadata["cacheProducer"], "Parcel", versions[index])
        }
    }

    func testPackageManagerOverridesCannotEstablishUnambiguousProducer() async throws {
        let configurations: [[String: Any]] = [
            ["overrides": ["parcel": "npm:other-package@2"]],
            ["resolutions": ["parcel": "file:../replacement"]],
            ["pnpm": ["overrides": ["parcel": "link:../replacement"]]],
            ["overrides": ["unrelated": "1"]],
            ["resolutions": "unknown-format"],
            ["overrides": ["invalid-array"]],
            ["pnpm": "unknown-format"],
            ["pnpm": ["overrides": NSNull()]]
        ]
        for (index, configuration) in configurations.enumerated() {
            var manifest = configuration
            manifest["devDependencies"] = ["parcel": "^2"]
            let body = try JSONSerialization.data(withJSONObject: manifest)
            try file("case-\(index)/package.json", String(decoding: body, as: UTF8.self))
            try file("case-\(index)/.parcel-cache/data.mdb")
        }
        try file("empty/package.json", #"{"devDependencies":{"parcel":"^2"},"overrides":{},"resolutions":{},"pnpm":{"overrides":{}}}"#)
        try file("empty/.parcel-cache/data.mdb")
        let result = try await scan()
        for index in configurations.indices {
            let entry = try item("case-\(index)/.parcel-cache", in: result)
            XCTAssertEqual(entry.risk, .review)
            XCTAssertNil(entry.metadata["cacheProducer"])
        }
        XCTAssertEqual(try item("empty/.parcel-cache", in: result).risk, .recommended)
    }

    func testAdditionalSourceAndCreativeFormatsInsideCacheRemainManual() async throws {
        try file("package.json", #"{"devDependencies":{"parcel":"2"}}"#)
        for path in [".parcel-cache/nested/important.rb", ".parcel-cache/assets/original.avif",
                     ".parcel-cache/audio/recording.flac", ".parcel-cache/documents/manuscript.epub"] { try file(path) }
        let result = try await scan()
        XCTAssertEqual(try item(".parcel-cache/nested/important.rb", in: result).category, .source)
        for path in [".parcel-cache/assets/original.avif", ".parcel-cache/audio/recording.flac", ".parcel-cache/documents/manuscript.epub"] {
            XCTAssertEqual(try item(path, in: result).category, .document)
        }
        XCTAssertEqual(try item(".parcel-cache", in: result).risk, .review)
    }

    func testSymlinkInsideRecognizedCacheBlocksItWithoutFollowingTarget() async throws {
        try file("package.json", #"{"dependencies":{"parcel":"2"}}"#)
        let target = try file("outside/source.swift")
        try file(".parcel-cache/data.mdb")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".parcel-cache/link"), withDestinationURL: target)
        let result = try await scan()
        XCTAssertEqual(try item(".parcel-cache", in: result).category, .cache)
        XCTAssertEqual(try item(".parcel-cache", in: result).risk, .protected)
        XCTAssertEqual(try item(".parcel-cache/link", in: result).risk, .unavailable)
    }

    @discardableResult private func file(_ path: String, _ text: String = "fixture") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func scan() async throws -> ScanResult { try await ProjectScanner().scan(ScanRequest(root: root)) }
    private func item(_ path: String, in result: ScanResult) throws -> CleanupItem {
        try XCTUnwrap(result.items.first { $0.path == root.appendingPathComponent(path).path })
    }
    private func git(_ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = arguments
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }
}
