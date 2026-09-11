import CleanupCore
import SwiftUI

struct ProjectScanProgressView: View {
    let progress: ScanProgress?
    let stageTitle: String
    let startedAt: Date?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(stageTitle).font(.headline)
            Text("已检查 \(progress?.count ?? 0) 个文件与目录").monospacedDigit()
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    Text(seconds < 60 ? "已用时 \(seconds) 秒" : "已用时 \(seconds / 60) 分 \(seconds % 60) 秒")
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
