import CleanupCore
import SwiftUI

struct BatchRestoreReviewView: View {
    @ObservedObject var state: SweepState
    let plan: RestorePlan
    @Environment(\.dismiss) private var dismiss
    private var excludedSessions: Int { plan.excludedRecords.filter { $0.action == .deleteSession }.count }
    private var otherExcluded: Int { plan.excludedRecords.count - excludedSessions }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认恢复文件").font(.title2.weight(.semibold))
            Text(AppText.format("%lld 项文件 · %@", Int64(plan.records.count), SweepState.size(plan.bytes)))
                .foregroundStyle(.secondary)
            Text("将以下文件从废纸篓恢复到列出的原位置。同名文件不会被覆盖，无法恢复的项目会逐项报告。")
                .font(.callout)
            List(plan.records) { record in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(URL(fileURLWithPath: record.originalPath).lastPathComponent, systemImage: "arrow.uturn.backward")
                            .font(.headline)
                        Spacer()
                        Text(SweepState.size(record.bytes)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(AppText.format("恢复到：%@", record.originalPath)).font(.caption).textSelection(.enabled)
                    if let trashPath = record.trashPath {
                        Text(AppText.format("废纸篓位置：%@", trashPath)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let tool = record.tool { Text(tool.title).font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 6)
            }.listStyle(.inset)
            if excludedSessions > 0 {
                Label(AppText.format("%lld 项会话记录未纳入恢复；历史会话没有备份。", Int64(excludedSessions)), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if otherExcluded > 0 {
                Text(AppText.format("另外 %lld 项已恢复、未完成清理或缺少恢复信息，未纳入此次恢复。", Int64(otherExcluded)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(AppText.format("恢复 %lld 项文件", Int64(plan.records.count))) { state.executeRestore(plan) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(state.executing || state.busy || plan.records.isEmpty)
            }
        }.padding(24).frame(width: 650, height: min(640, max(380, 290 + CGFloat(plan.records.count) * 90)))
    }
}
