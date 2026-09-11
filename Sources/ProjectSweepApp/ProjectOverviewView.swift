import CleanupCore
import SwiftUI

struct ProjectOverviewView: View {
    @ObservedObject var state: SweepState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ForEach([CleanupRisk.recommended, .review, .protected], id: \.self) { risk in
                    let metric = state.projectOverview.summary(for: risk)
                    let selected = state.filters(for: .projectFiles).risk == risk
                    Button {
                        var filters = state.filters(for: .projectFiles)
                        filters.risk = selected ? nil : risk
                        filters.category = nil; filters.search = ""; filters.onlySelected = false
                        state.setFilters(filters, for: .projectFiles)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(risk == .review ? "需人工检查" : risk.title).font(.callout.weight(.medium))
                                Spacer()
                                if selected { Image(systemName: "checkmark.circle.fill") }
                            }
                            Text(state.filesScanned ? "\(metric.count) 项 · \(metric.incomplete ? "大小不完整" : SweepState.size(metric.bytes))" : state.projectScanActive ? "扫描完成后统计" : "尚未完成扫描")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selected ? Color.teal.opacity(0.14) : Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.teal : Color.clear))
                    }.buttonStyle(.plain).disabled(state.busy).accessibilityValue(selected ? "正在筛选" : "未筛选")
                }
            }
            if !state.projectOverview.isComplete {
                Button {
                    var filters = state.filters(for: .projectFiles); filters.risk = .unavailable
                    filters.search = ""; filters.category = nil; filters.onlySelected = false
                    state.setFilters(filters, for: .projectFiles)
                } label: {
                    Label("\(state.projectOverview.summary(for: .unavailable).count) 项无法完整校验，大小统计不完整 · 查看", systemImage: "exclamationmark.triangle")
                }.buttonStyle(.plain).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
