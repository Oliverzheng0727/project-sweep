import CleanupCore
import CryptoKit
import Foundation

/// Opt-in Release benchmark. The caller supplies an isolated generated fixture.
@main struct ScanBenchmark {
    struct Report: Encodable {
        let scanSeconds: Double
        let overviewSeconds: Double
        let itemCount: Int
        let protectedCount: Int
        let recommendedCount: Int
        let warningCount: Int
        let inventorySHA256: String
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw CleanupError.io("Usage: scan-benchmark /path/to/generated/fixture")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await ProjectScanner().scan(ScanRequest(root: root,
            protectedPaths: [root.appendingPathComponent("exports/成品.pdf").path]))
        let scanned = clock.now
        let overview = ProjectOverview(items: result.items)
        let finished = clock.now
        guard overview.isComplete, result.warnings.isEmpty else {
            throw CleanupError.io("Benchmark fixture must be fully readable")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let inventory = try encoder.encode(result.items.sorted { $0.path < $1.path })
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let report = Report(scanSeconds: seconds(started.duration(to: scanned)),
            overviewSeconds: seconds(scanned.duration(to: finished)), itemCount: result.items.count,
            protectedCount: result.items.filter { $0.risk == .protected }.count,
            recommendedCount: result.items.filter { $0.risk == .recommended }.count,
            warningCount: result.warnings.count,
            inventorySHA256: SHA256.hash(data: inventory).map { String(format: "%02x", $0) }.joined())
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
        if let raw = ProcessInfo.processInfo.environment["SWEEP_SCAN_BUDGET_SECONDS"], let budget = Double(raw),
           report.scanSeconds > budget {
            FileHandle.standardError.write(Data("FAIL: scan exceeded opt-in budget of \(budget) seconds\n".utf8))
            exit(1)
        }
    }
}
