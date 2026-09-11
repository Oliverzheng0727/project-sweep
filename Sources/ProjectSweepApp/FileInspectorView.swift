import AppKit
import CleanupCore
import QuickLookUI
import SwiftUI

struct FileInspectorView: View {
    @ObservedObject var state: SweepState
    let item: CleanupItem
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("文件详情").font(.headline)
                Spacer()
                if state.inspectorURL != nil {
                    Button { state.preview(item) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).accessibilityLabel("放大预览")
                }
                Button(action: state.closeInspector) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).accessibilityLabel("收起详情")
            }
            HStack(spacing: 8) {
                if item.tool == nil {
                    Button(state.keepPaths.contains(item.path) ? "取消个人保留" : "始终保留", systemImage: "shield") { state.keep(item) }
                        .disabled(state.busy || state.executing)
                }
                Button("Finder 定位", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    .accessibilityLabel("在 Finder 中显示 \(item.title)")
            }.controlSize(.small)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    if let url = state.inspectorURL {
                        LocalQuickLookView(url: url).frame(height: 140).clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("\(item.title) 的本地预览")
                    } else if let message = state.inspectorMessage {
                        Label(message, systemImage: "doc.text.magnifyingglass").font(.callout).foregroundStyle(.secondary)
                    } else { ProgressView("正在校验预览…").controlSize(.small) }
                    Text(item.risk.title).font(.callout.weight(.semibold))
                    Text(item.reason).font(.callout).textSelection(.enabled)
                    if item.metadata["systemProtection"] == "true" {
                        Label("系统保护不会被个人保留标记解除", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("大小：\(item.risk == .unavailable ? "未完整统计" : SweepState.size(item.bytes))").font(.callout)
                    Text(item.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    ForEach(Array(item.details.enumerated()), id: \.offset) { _, detail in Text(detail).font(.caption).textSelection(.enabled) }
                    if item.action == .deleteSession { Label("历史不备份，删除后不能从本应用恢复", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.vertical, 8)
    }
}

private struct LocalQuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
