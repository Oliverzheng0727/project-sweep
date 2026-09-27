import CleanupCore
import SwiftUI

struct ProjectStorageView: View {
    @ObservedObject var state: SweepState
    @AppStorage("storageBreakdownExpanded") private var expanded = false
    private var breakdown: ProjectStorageBreakdown { state.projectStorage }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 10)
                    Text("空间分布").font(.caption.weight(.medium)).fixedSize()
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            ForEach(breakdown.segments.filter { $0.bytes > 0 }) { segment in
                                color(segment.kind)
                                    .frame(width: geometry.size.width * CGFloat(segment.bytes) / CGFloat(max(1, breakdown.totalBytes)))
                            }
                        }
                    }.frame(height: 8).background(.quaternary, in: Capsule()).clipShape(Capsule())
                        .accessibilityHidden(true)
                    Text(breakdown.isComplete ? SweepState.size(breakdown.totalBytes) : AppText.string("大小不完整"))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(AppText.string("空间分布"))
                .accessibilityValue(AppText.string(expanded ? "已展开" : "已收起"))
            if expanded {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(breakdown.segments) { segment in
                            segmentButton(segment).fixedSize()
                        }
                    }.padding(.vertical, 2)
                }.frame(height: 32).scrollIndicators(.hidden).font(.caption)
                Text("按本次扫描的文件大小统计，父子目录不重复累计；占用大小不代表可清理空间。")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.disabled(state.busy).fixedSize(horizontal: false, vertical: true)
    }

    private func segmentButton(_ segment: StorageSegment) -> some View {
        Button { select(segment.kind) } label: {
            HStack(spacing: 6) {
                Image(systemName: segment.kind.systemImage).foregroundStyle(color(segment.kind)).frame(width: 18)
                Text(AppText.string(segment.kind.title)).lineLimit(1)
                Text(segment.incomplete ? AppText.string("不完整") : SweepState.size(segment.bytes))
                    .foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                if state.filters(for: .projectFiles).storageKind == segment.kind {
                    Image(systemName: "checkmark").foregroundStyle(SweepPalette.accent)
                }
            }.padding(6).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(AppText.format("筛选%@，%@", AppText.string(segment.kind.title), segment.incomplete ? AppText.string("大小不完整") : SweepState.size(segment.bytes)))
            .accessibilityValue(AppText.string(state.filters(for: .projectFiles).storageKind == segment.kind ? "正在筛选" : "未筛选"))
    }

    private func select(_ kind: StorageKind) {
        var filters = state.filters(for: .projectFiles)
        filters.storageKind = filters.storageKind == kind ? nil : kind
        state.setFilters(filters, for: .projectFiles)
    }

    private func color(_ kind: StorageKind) -> Color {
        switch kind {
        case .cache: .green
        case .dependencies: .orange
        case .documents: .blue
        case .images: .pink
        case .video: .purple
        case .audio: .indigo
        case .source: .teal
        case .build: .brown
        case .other: .gray
        }
    }
}
