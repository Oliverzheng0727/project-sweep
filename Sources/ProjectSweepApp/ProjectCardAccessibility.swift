import CleanupCore
import Foundation

@MainActor enum ProjectCardAccessibility {
    static func value(project: ProjectDirectory, summary: ProjectScanSummary?, selected: Bool, pinned: Bool) -> String {
        var parts = [AppText.string(selected ? "已选中" : "未选中")]
        if pinned { parts.append(AppText.string("已置顶")) }
        parts.append(AppText.format("创建：%@", project.createdAt.map {
            AppText.date($0, dateStyle: .medium, timeStyle: .none)
        } ?? AppText.string("未知")))
        if let issue = project.issue {
            parts.append(AppText.string("暂不可打开"))
            parts.append(AppText.string(issue))
        } else if let summary {
            parts.append(AppText.format("%@ · 缓存 %@", SweepState.size(summary.bytes), SweepState.size(summary.cacheBytes)))
            parts.append(AppText.format("扫描于 %@", AppText.date(summary.scannedAt, dateStyle: .medium, timeStyle: .short)))
            if summary.isHistorical { parts.append(AppText.string("历史统计，待校验")) }
        } else {
            parts.append(AppText.string("未扫描"))
        }
        return parts.joined(separator: "; ")
    }
}
