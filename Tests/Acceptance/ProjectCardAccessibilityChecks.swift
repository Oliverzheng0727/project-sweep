import CleanupCore
import Foundation

@main struct ProjectCardAccessibilityChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("Sweep-card-accessibility-\(UUID())").standardizedFileURL
        try fm.createDirectory(at: sandbox.appendingPathComponent("论文"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: sandbox.appendingPathComponent("外部引用"), withDestinationURL: sandbox.appendingPathComponent("论文"))
        defer { try? fm.removeItem(at: sandbox) }
        let previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        func useLanguage(_ preference: AppLanguagePreference) {
            var arguments = previousArguments
            arguments["language"] = preference.rawValue
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        let catalog = try await ProjectCatalog().list(sandbox)
        let project = catalog.projects.first { $0.title == "论文" }!
        let unavailable = catalog.projects.first { $0.title == "外部引用" }!
        let summary = ProjectScanSummary(bytes: 200_000, cacheBytes: 50_000,
            scannedAt: Date(timeIntervalSince1970: 1_600_000_000), snapshot: project.snapshot, isHistorical: true)

        // Replacing the AX value with selection alone must not hide historical size, date, or pin state.
        useLanguage(.english)
        let historical = ProjectCardAccessibility.value(project: project, summary: summary, selected: true, pinned: true)
        guard historical.contains("200 KB"), historical.contains("50 KB"), historical.contains("2020"),
              historical.contains("Historical"), historical.contains("Created"), historical.contains("Pinned") else {
            fatalError("Historical card AX value lost size, timestamps, pin state, or stale-data warning: \(historical)")
        }
        print("PASS: historical project cards expose sizes, creation and scan dates, pin state and verification warning")

        // A card that cannot open must expose the concrete problem, not claim it merely has no scan yet.
        let unavailableValue = ProjectCardAccessibility.value(project: unavailable, summary: nil, selected: false, pinned: false)
        guard unavailableValue.contains("Unavailable"), unavailableValue.contains("Symbolic link"),
              !unavailableValue.contains("Not Scanned") else {
            fatalError("Unavailable card AX value omitted the opening restriction: \(unavailableValue)")
        }
        let notScanned = ProjectCardAccessibility.value(project: project, summary: nil, selected: false, pinned: false)
        guard notScanned.contains("Not Scanned"), !notScanned.contains("Historical") else {
            fatalError("Unscanned card AX value claimed a stale scan or omitted its scan state")
        }
        print("PASS: unavailable and unscanned project cards announce distinct states and the opening restriction")

        // Switching language must localize the synthesized value without losing the historical warning.
        useLanguage(.simplifiedChinese)
        let chinese = ProjectCardAccessibility.value(project: project, summary: summary, selected: true, pinned: true)
        guard chinese.contains("已选中"), chinese.contains("已置顶"), chinese.contains("创建"),
              chinese.contains("历史统计，待校验"), !chinese.contains("Historical") else {
            fatalError("Chinese AX value contains mixed language or loses state: \(chinese)")
        }
        print("PASS: project card accessibility values follow the selected language")
    }
}
