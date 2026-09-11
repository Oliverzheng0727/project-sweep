import CleanupCore
import SwiftUI

struct ProjectScanProgressView: View {
    let progress: ScanProgress?
    let stageTitle: String
    let startedAt: Date?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(AppText.string(stageTitle)).font(.headline)
            Text(AppText.format("已检查 %lld 个文件与目录", Int64(progress?.count ?? 0))).monospacedDigit()
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    Text(seconds < 60
                         ? AppText.format("已用时 %lld 秒", Int64(seconds))
                         : AppText.format("已用时 %lld 分 %lld 秒", Int64(seconds / 60), Int64(seconds % 60)))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let path = progress?.path {
                Text(path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            Text("正在核对文件和保护规则，完整扫描后可勾选清理。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: 520)
    }
}
