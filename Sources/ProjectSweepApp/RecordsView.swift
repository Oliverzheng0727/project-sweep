import AppKit
import CleanupCore
import SwiftUI

struct RecordsView: View {
    @ObservedObject var state: SweepState
    @State private var expandedBatches: Set<UUID> = []
    @State private var latestBatchID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !state.records.isEmpty {
                Text(AppText.format("%lld 次操作 · %lld 项记录", Int64(state.recordBatches.count), Int64(state.records.count)))
                    .font(.headline)
            }
            Text("按每次操作查看结果，可一起恢复仍在废纸篓中的文件。不记录对话正文。")
                .font(.callout).foregroundStyle(.secondary)
            if !state.records.isEmpty { totals }
            if let warning = state.recordWarning {
                Label(AppText.string(warning), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if state.executing { ProgressView(AppText.string(state.status)).controlSize(.small) }
            if let report = state.restoreReport { restoreResult(report) }
            if state.records.isEmpty {
                ContentUnavailableView("还没有清理记录", systemImage: "clock.arrow.circlepath", description: Text("完成第一次清理后，操作结果会出现在这里。"))
            } else {
                List {
                    ForEach(state.recordBatches) { batch in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expandedBatches.contains(batch.id) },
                            set: { if $0 { expandedBatches.insert(batch.id) } else { expandedBatches.remove(batch.id) } }
                        )) {
                            ForEach(batch.records) { record in recordRow(record) }
                        } label: {
                            batchHeader(batch)
                        }
                    }
                }.listStyle(.inset)
            }
        }
        .padding(24)
        .task { await state.loadRecords(); expandLatestBatch() }
        .onChange(of: state.recordBatches.first?.id) { expandLatestBatch() }
        .sheet(item: $state.restoreReview) {
            BatchRestoreReviewView(state: state, plan: $0).environment(\.locale, AppText.preference.locale)
        }
    }

    private var totals: some View {
        let completed = state.records.filter { $0.status == .succeeded || $0.status == .restored }
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 24) {
                Label(AppText.format("累计处理 %@", SweepState.size(completed.reduce(0) { $0 + $1.bytes })), systemImage: "checkmark.circle")
                Label(AppText.format("累计移入废纸篓 %@", SweepState.size(completed.filter { $0.action == .trash }.reduce(0) { $0 + $1.bytes })), systemImage: "trash")
            }.font(.callout).foregroundStyle(.secondary)
            Text("按成功操作累计，包含已恢复项目；不代表当前空闲磁盘空间。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func batchHeader(_ batch: CleanupBatch) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(batch.date, format: .dateTime.year().month().day().hour().minute()).font(.headline)
                    ForEach(batch.tools, id: \.self) { tool in ToolLogo(tool: tool, size: 17).help(tool.title) }
                }
                HStack(spacing: 10) {
                    Text(AppText.format("%lld 项 · %@ 已处理", Int64(batch.records.count), SweepState.size(batch.processedBytes)))
                    if batch.restoredCount > 0 { Text(AppText.format("%lld 项已恢复", Int64(batch.restoredCount))) }
                    if batch.failedCount > 0 { Text(AppText.format("%lld 项失败", Int64(batch.failedCount))).foregroundStyle(.red) }
                    if batch.skippedCount > 0 { Text(AppText.format("%lld 项已跳过", Int64(batch.skippedCount))) }
                }.font(.caption).foregroundStyle(.secondary)
                if let path = batch.contextPaths.first {
                    Text(path + (batch.contextPaths.count > 1 ? AppText.format(" · 另 %lld 个位置", Int64(batch.contextPaths.count - 1)) : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(batch.contextPaths.joined(separator: "\n"))
                }
            }
            Spacer(minLength: 8)
            if !batch.restorableRecords.isEmpty {
                Button(AppText.format("恢复 %lld 项…", Int64(batch.restorableRecords.count))) { state.prepareRestore(records: batch.records) }
                    .buttonStyle(.bordered).controlSize(.small).disabled(state.busy || state.executing)
                    .accessibilityLabel(AppText.format("查看本次操作的 %lld 项恢复清单", Int64(batch.restorableRecords.count)))
            }
        }.padding(.vertical, 8)
    }

    private func recordRow(_ record: CleanupRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: recordIcon(record.status)).foregroundStyle(recordColor(record.status))
                .padding(.top, 3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(URL(fileURLWithPath: record.originalPath).lastPathComponent).font(.headline)
                    if let tool = record.tool { Text(tool.title).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(AppText.string(record.status.title)).font(.caption).foregroundStyle(.secondary)
                }
                Text(record.originalPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(AppText.string(record.message)).font(.caption).textSelection(.enabled)
                HStack {
                    Text(AppText.string(record.action == .trash ? "文件处理量" : "会话处理量") + " · " + SweepState.size(record.bytes))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if record.action == .trash, record.status == .succeeded, let path = record.trashPath {
                        Button("在废纸篓中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(AppText.format("在废纸篓中显示 %@", URL(fileURLWithPath: record.originalPath).lastPathComponent))
                        if record.canAttemptRestore {
                            Button("恢复原位置") { state.restore(record) }.disabled(state.busy || state.executing)
                                .buttonStyle(.borderless)
                                .accessibilityLabel(AppText.format("恢复 %@ 到原位置", URL(fileURLWithPath: record.originalPath).lastPathComponent))
                        }
                    }
                    if record.action == .deleteSession, record.status == .succeeded {
                        Text("无备份，不可恢复").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if record.action == .trash, record.status == .succeeded, !record.canAttemptRestore {
                    Text("缺少恢复信息，请在 Finder 中核实。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 8).accessibilityElement(children: .contain)
    }

    private func restoreResult(_ report: RestoreReport) -> some View {
        let unfinished = report.outcomes.filter { $0.status != .restored }
        return VStack(alignment: .leading, spacing: 8) {
            Label(AppText.format("恢复完成：%lld 项已恢复，%lld 项未恢复", Int64(report.restoredCount), Int64(unfinished.count)),
                  systemImage: unfinished.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                .font(.callout).foregroundStyle(unfinished.isEmpty ? Color.green : Color.orange)
            if !unfinished.isEmpty {
                DisclosureGroup("查看未恢复项") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(unfinished) { outcome in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(outcome.record.originalPath).textSelection(.enabled)
                                    Text(AppText.string(outcome.message)).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                    }.frame(maxHeight: 150)
                }.font(.caption)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func expandLatestBatch() {
        guard let id = state.recordBatches.first?.id, id != latestBatchID else { return }
        expandedBatches.insert(id); latestBatchID = id
    }
    private func recordIcon(_ status: CleanupStatus) -> String {
        switch status {
        case .succeeded: "checkmark.circle"
        case .restored: "arrow.uturn.backward.circle"
        case .skipped: "minus.circle"
        case .failed: "exclamationmark.circle"
        }
    }
    private func recordColor(_ status: CleanupStatus) -> Color {
        switch status {
        case .succeeded: .green
        case .restored: .blue
        case .skipped: .secondary
        case .failed: .red
        }
    }
}
