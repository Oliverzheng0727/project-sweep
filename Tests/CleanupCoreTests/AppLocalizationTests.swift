import XCTest
@testable import CleanupCore

final class AppLocalizationTests: XCTestCase {
    private let languageKey = "language"
    private var previousLanguage: Any?

    override func setUp() {
        super.setUp()
        previousLanguage = UserDefaults.standard.object(forKey: languageKey)
    }

    override func tearDown() {
        if let previousLanguage {
            UserDefaults.standard.set(previousLanguage, forKey: languageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: languageKey)
        }
        super.tearDown()
    }

    func testEnglishPreferenceUsesBundledTranslation() {
        UserDefaults.standard.set(AppLanguagePreference.english.rawValue, forKey: languageKey)

        XCTAssertEqual(AppText.string("项目清理"), "Project Sweep")
        XCTAssertEqual(AppText.string("文件夹授权已失效，请重新选择。"), "Folder access has expired. Choose the folder again.")
        XCTAssertEqual(AppText.itemCount(1), "1 item")
        XCTAssertEqual(AppText.itemCount(2), "2 items")
        XCTAssertEqual(AppText.string("已检查当前项目 1 项 · 关联记录尚未检查"),
                       "Inspected 1 project item · Related Records Not Inspected")
    }

    func testSimplifiedChinesePreferencePreservesSourceText() {
        UserDefaults.standard.set(AppLanguagePreference.simplifiedChinese.rawValue, forKey: languageKey)

        XCTAssertEqual(AppText.string("项目清理"), "项目清理")
        XCTAssertEqual(AppText.itemCount(2), "2 项")
    }

    func testEnglishFallbackNeverLeaksUnknownChineseMessage() {
        UserDefaults.standard.set(AppLanguagePreference.english.rawValue, forKey: languageKey)

        let result = AppText.string("未登记的新错误消息")
        XCTAssertNil(result.range(of: #"\p{Han}"#, options: .regularExpression))
    }

    func testRestoreSummaryKeepsCountsWhenLanguageChanges() {
        let canonical = "恢复完成：2 项已恢复，1 项未恢复"
        UserDefaults.standard.set(AppLanguagePreference.english.rawValue, forKey: languageKey)
        XCTAssertEqual(AppText.string(canonical), "Restore complete: 2 restored, 1 not restored")
        UserDefaults.standard.set(AppLanguagePreference.simplifiedChinese.rawValue, forKey: languageKey)
        XCTAssertEqual(AppText.string(canonical), "恢复完成：2 项已恢复，1 项未恢复")
    }
}
