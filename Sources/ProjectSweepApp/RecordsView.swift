import AppKit
import CleanupCore
import SwiftUI

struct RecordsView: View {
    @ObservedObject var state: SweepState
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("每一次清理，都有记录").font(.largeTitle.weight(.semibold))
            Text("保留操作结果与文件位置，不记录对话正文。移入废纸篓的文件可尝试恢复。")
                .foregroundStyle(.secondary)
            if !state.records.isEmpty {
                let completed = state.records.filter { $0.status == .succeeded || $0.status == .restored }
                HStack(spacing: 24) {
                    Label("累计处理 \(SweepState.size(completed.reduce(0) { $0 + $1.bytes }))", systemImage: "checkmark.circle")
                    Label("累计移入废纸篓 \(SweepState.size(completed.filter { $0.action == .trash }.reduce(0) { $0 + $1.bytes }))", systemImage: "trash")
                }.font(.callout).foregroundStyle(.secondary)
                Text("按成功操作累计，包含已恢复项目；不代表当前空闲磁盘空间。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let warning = state.recordWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if state.records.isEmpty {
                ContentUnavailableView("还没有清理记录", systemImage: "clock.arrow.circlepath", description: Text("完成第一次清理后，操作结果会出现在这里。"))
            } else {
                List(state.records) { record in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: recordIcon(record.status))
                            .foregroundStyle(recordColor(record.status)).padding(.top, 3).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(URL(fileURLWithPath: record.originalPath).lastPathComponent).font(.headline)
                                if let tool = record.tool { ToolLogo(tool: tool, size: 18); Text(tool.title).font(.caption).foregroundStyle(.secondary) }
                                Text(record.status.title).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(record.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(record.originalPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(record.message).font(.caption).textSelection(.enabled)
                            HStack {
                                Text("\(record.action == .trash ? "文件处理量" : "会话处理量") · \(SweepState.size(record.bytes))").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if record.action == .trash, record.status == .succeeded, let path = record.trashPath {
                                    Button("在废纸篓中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("在废纸篓中显示 \(URL(fileURLWithPath: record.originalPath).lastPathComponent)")
                                    Button("恢复原位置") { state.restore(record) }.disabled(state.executing)
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("恢复 \(URL(fileURLWithPath: record.originalPath).lastPathComponent) 到原位置")
                                }
                                if record.action == .deleteSession { Text("无备份，不可恢复").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }.padding(.vertical, 10)
                        .accessibilityElement(children: .contain)
                }.listStyle(.inset)
            }
        }.padding(28).task { await state.loadRecords() }
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
