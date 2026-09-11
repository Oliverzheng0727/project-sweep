import Foundation

public enum AppLanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case simplifiedChinese

    public var id: String { rawValue }

    public var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .simplifiedChinese: Locale(identifier: "zh-Hans")
        }
    }
}

public enum AppText {
    private static let englishBundle: Bundle? = {
        if let resourceURL = Bundle.main.url(forResource: "ProjectSweep_CleanupCore", withExtension: "bundle"),
           let resources = Bundle(url: resourceURL),
           let path = resources.path(forResource: "en", ofType: "lproj"),
           let localized = Bundle(path: path) {
            return localized
        }
        if let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
           let localized = Bundle(path: path) {
            return localized
        }
        #if SWIFT_PACKAGE
        if let path = Bundle.module.path(forResource: "en", ofType: "lproj") {
            return Bundle(path: path)
        }
        #endif
        return nil
    }()

    public static var preference: AppLanguagePreference {
        AppLanguagePreference(rawValue: UserDefaults.standard.string(forKey: "language") ?? "system") ?? .system
    }

    public static var usesEnglish: Bool {
        switch preference {
        case .english: true
        case .simplifiedChinese: false
        case .system:
            !(Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh")
        }
    }

    public static func string(_ source: String) -> String {
        guard usesEnglish else { return source }
        if let englishBundle {
            let translated = englishBundle.localizedString(forKey: source, value: source, table: nil)
            if translated != source { return translated }
        }
        return fallbackEnglish(for: source)
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: preference.locale, arguments: arguments)
    }

    public static func date(_ value: Date, dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style) -> String {
        let formatter = DateFormatter()
        formatter.locale = preference.locale
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: value)
    }

    public static func itemCount(_ count: Int) -> String {
        if usesEnglish { return count == 1 ? "1 item" : "\(count) items" }
        return "\(count) 项"
    }

    public static func fileCount(_ count: Int) -> String {
        if usesEnglish { return count == 1 ? "1 file or folder" : "\(count) files and folders" }
        return "\(count) 个文件与目录"
    }

    private static func fallbackEnglish(for source: String) -> String {
        guard source.range(of: #"\p{Han}"#, options: .regularExpression) != nil else { return source }
        if let values = captures(#"^(\d+) 项$"#, in: source) { return "\(values[0]) items" }
        if let values = captures(#"^找到 (\d+) 个项目文件夹 · .+$"#, in: source) {
            return "Found \(values[0]) project folders · Select one to begin a deep inspection"
        }
        if let values = captures(#"^已检查当前项目 (\d+) 项 · (.+)$"#, in: source) {
            return "Inspected \(values[0]) project items · \(string(values[1]))"
        }
        if let values = captures(#"^已检查 (\d+) 项 · .+$"#, in: source) {
            return "Inspected \(values[0]) items · Select what you want to clean"
        }
        if let values = captures(#"^(.+) · 已检查 (\d+) 项$"#, in: source) {
            return "\(values[0]) · \(values[1]) items inspected"
        }
        if let values = captures(#"^已找到 (\d+) 条 · 仍在检查$"#, in: source) {
            return "Found \(values[0]) · Inspection still running"
        }
        if let values = captures(#"^已找到 (\d+) 条 · 检查未完整完成$"#, in: source) {
            return "Found \(values[0]) · Inspection incomplete"
        }
        if let values = captures(#"^(\d+) 条关联会话$"#, in: source) { return "\(values[0]) related sessions" }
        if let values = captures(#"^已检查 (\d+) 个文件与目录$"#, in: source) { return "\(values[0]) files and folders inspected" }
        if let values = captures(#"^已用时 (\d+) 秒$"#, in: source) { return "Elapsed: \(values[0]) seconds" }
        if let values = captures(#"^已用时 (\d+) 分 (\d+) 秒$"#, in: source) { return "Elapsed: \(values[0])m \(values[1])s" }
        if let values = captures(#"^已找到 (\d+) 项 · (.+)$"#, in: source) { return "Found \(values[0]) items · \(string(values[1]))" }
        if let values = captures(#"^(.+) · 已检查 (\d+) 项$"#, in: source) { return "\(values[0]) · \(values[1]) items inspected" }
        if let values = captures(#"^(.+) · 已检查 (\d+) 项 · (.+)$"#, in: source) { return "\(string(values[0])) · \(values[1]) items inspected · \(values[2])" }
        if let values = captures(#"^处理完成：(\d+) 项成功，共 (\d+) 项$"#, in: source) { return "Completed: \(values[0]) of \(values[1]) items succeeded" }
        if let values = captures(#"^技能处理完成：(\d+) 项成功，共 (\d+) 项$"#, in: source) { return "Skills processed: \(values[0]) of \(values[1]) succeeded" }
        if let values = captures(#"^已断开 (.+)，原记录保持不变$"#, in: source) { return "Disconnected \(values[0]). Original records were not changed." }
        if let values = captures(#"^正在查找此项目的 (.+) 关联记录…$"#, in: source) { return "Looking for \(values[0]) records related to this project…" }
        if let values = captures(#"^(.+) 授权不可用，请重新选择文件夹。$"#, in: source) { return "Access to \(values[0]) is unavailable. Choose the folder again." }
        if let values = captures(#"^文件或目录正被其他程序使用，请关闭后再清理：(.+)$"#, in: source) { return "This item is in use by another app. Close it before cleaning: \(values[0])" }
        if let values = captures(#"^(.+) 在扫描后发生变化，请重新扫描。$"#, in: source) { return "\(values[0]) changed after the scan. Scan again." }
        if let values = captures(#"^无法访问 (.+)：(.+)$"#, in: source) { return "Could not access \(values[0]): \(values[1])" }
        if let values = captures(#"^无法读取文件状态：(.+)$"#, in: source) { return "Could not read file status: \(values[0])" }
        if let values = captures(#"^路径包含符号链接，请重新选择真实目录：(.+)$"#, in: source) { return "The path contains a symbolic link. Choose the real folder: \(values[0])" }
        if let values = captures(#"^路径超出已选择目录：(.+)$"#, in: source) { return "The path is outside the selected folder: \(values[0])" }
        if let values = captures(#"^目录包含已保护的内容：(.+)$"#, in: source) { return "The folder contains protected content: \(values[0])" }
        if let values = captures(#"^请完全退出 (.+) 及其后台进程后重试$"#, in: source) { return "Quit \(values[0]) and its background processes, then try again." }
        if let values = captures(#"^未知 JSONL 格式：(.+)$"#, in: source) { return "Unknown JSONL format: \(values[0])" }
        if let values = captures(#"^会话 (.+) 的记录文件缺失$"#, in: source) { return "The record file for session \(values[0]) is missing" }
        if let values = captures(#"^会话 (.+)$"#, in: source) { return "Session \(values[0])" }
        if let values = captures(#"^关联：(.+)$"#, in: source) { return "Related: \(values[0])" }
        if let values = captures(#"^(.+) 明确的缓存或日志目录$"#, in: source) { return "Verified \(values[0]) cache or log folder" }
        if let values = captures(#"^无法授权文件夹：(.+)$"#, in: source) { return "Could not authorize the folder: \(values[0])" }
        if let values = captures(#"^项目授权不可用，请重新选择：(.+)$"#, in: source) { return "Project access is unavailable. Choose it again: \(values[0])" }
        if let values = captures(#"^无法准备操作记录，未删除：(.+)$"#, in: source) { return "The operation record could not be prepared, so nothing was deleted: \(values[0])" }
        if let values = captures(#"^恢复失败，文件仍在废纸篓：(.+)$"#, in: source) { return "Restore failed and the item remains in Trash: \(values[0])" }
        if let values = captures(#"^；(?:操作)?记录保存失败：(.+)$"#, in: source) { return "; the operation record could not be saved: \(values[0])" }
        if source.contains("重新扫描") || source.contains("扫描后") || source.contains("已改变") || source.contains("发生变化") {
            return "The item changed or could not be verified. Scan again."
        }
        if source.contains("只读") || source.contains("禁止删除") || source.contains("不可清理") || source.contains("不能清理") {
            return "Read-only: the format, ownership, or related data could not be verified safely."
        }
        if source.contains("授权") {
            return "Folder access is unavailable or has changed. Choose the folder again."
        }
        if source.contains("废纸篓") && source.contains("恢复") {
            return "Moved to Trash. It can be restored unless another item now uses the original name."
        }
        if source.contains("取消") { return "The operation was cancelled." }
        if source.contains("权限") || source.contains("无法读取") || source.contains("无法访问") {
            return "The item could not be read safely. Check its permissions and try again."
        }
        if source.contains("会话") { return "This session could not be processed safely because its data or relationships are incomplete." }
        if source.contains("技能") { return "This skill could not be processed safely. Review its source and sharing status." }
        if source.contains("目录") || source.contains("文件") {
            return "This file or folder could not be processed safely. Review it and try again."
        }
        return "The operation could not be completed safely."
    }

    private static func captures(_ pattern: String, in source: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              match.range.location != NSNotFound else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: source) else { return nil }
            return String(source[range])
        }
    }
}
