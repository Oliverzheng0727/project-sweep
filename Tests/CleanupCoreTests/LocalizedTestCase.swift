import XCTest
@testable import CleanupCore

/// Override language only in this test process. XCTest workers may share the same
/// persistent defaults domain, so writing a language preference there races with
/// other concurrently running suites and can leak test settings after failure.
class LocalizedTestCase: XCTestCase {
    private var previousArgumentDomain: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        previousArgumentDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }

    override func tearDown() {
        UserDefaults.standard.setVolatileDomain(previousArgumentDomain, forName: UserDefaults.argumentDomain)
        super.tearDown()
    }

    func setLanguage(_ language: AppLanguagePreference) {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["language"] = language.rawValue
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}
