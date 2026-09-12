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
                                Image(systemName: SweepPalette.riskIcon(risk)).foregroundStyle(SweepPalette.risk(risk)).accessibilityHidden(true)
                                Text(AppText.string(risk == .review ? "需人工检查" : risk.title)).font(.callout.weight(.medium))
                                Spacer()
                                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(SweepPalette.accent) }
                            }
                            Text(state.filesScanned
                                 ? AppText.itemCount(metric.count) + " · " + (metric.incomplete ? AppText.string("大小不完整") : SweepState.size(metric.bytes))
                                 : AppText.string(state.projectScanActive ? "扫描完成后统计" : "尚未完成扫描"))
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(SweepPalette.risk(risk).opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? SweepPalette.accent : SweepPalette.border.opacity(0.35)))
                    }.buttonStyle(.plain).disabled(state.busy).accessibilityValue(AppText.string(selected ? "正在筛选" : "未筛选"))
                }
            }
            if !state.projectOverview.isComplete {
                Button {
                    var filters = state.filters(for: .projectFiles); filters.risk = .unavailable
                    filters.search = ""; filters.category = nil; filters.onlySelected = false
                    state.setFilters(filters, for: .projectFiles)
                } label: {
                    Label(AppText.format("%lld 项无法完整校验，大小统计不完整 · 查看",
                                         Int64(state.projectOverview.summary(for: .unavailable).count)), systemImage: "exclamationmark.triangle")
                }.buttonStyle(.plain).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
