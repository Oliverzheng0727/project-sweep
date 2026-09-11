import AppKit
import CleanupCore
import SwiftUI

struct SkillsView: View {
    @ObservedObject var state: SkillManagementState
    let execute: (SkillRemovalPlan) -> Void
    @State private var showSources = false

    var body: some View {
        GeometryReader { geometry in
            content.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .onAppear { state.activate() }
        .sheet(item: $state.review) { SkillReviewView(plan: $0, execute: execute) }
        .alert("无法完成技能操作", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            Button("好") { state.error = nil }
        } message: { Text(state.error ?? "") }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("技能管理").font(.largeTitle.weight(.semibold))
                    Text("自动检索本机技能，按 AI 分开管理。共享原文件保留。").foregroundStyle(.secondary)
                }
                Spacer()
                Button("重新扫描", systemImage: "arrow.clockwise", action: state.scan)
                    .disabled(state.scanning)
            }
            HStack(spacing: 12) {
                ForEach([ToolKind.claude, .codex]) { tool in
                    Button { state.tool = tool } label: {
                        HStack(spacing: 10) {
                            ToolLogo(tool: tool, size: 28)
                            Text(tool.title).font(.headline)
                            Text(state.countLabel(for: tool)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }.frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(state.tool == tool ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(state.tool == tool ? Color.accentColor : .clear))
                    }.buttonStyle(.plain).accessibilityLabel("\(tool.title) 技能")
                        .accessibilityAddTraits(state.tool == tool ? .isSelected : [])
                }
            }
            DisclosureGroup(isExpanded: $showSources) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(state.toolRoots) { root in
                        HStack(spacing: 10) {
                            Text(root.location.title).font(.caption.weight(.medium))
                            if state.isAutomatic(root) { Text("自动发现").font(.caption2).foregroundStyle(.secondary) }
                            Text(root.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(root.url.path)
                            Spacer()
                            if !state.isAutomatic(root) {
                                Button("断开") { state.disconnect(root) }.buttonStyle(.borderless).disabled(state.scanning)
                                    .accessibilityLabel("断开自定义来源 \(root.url.path)")
                            }
                        }
                    }
                    if state.toolRoots.isEmpty { Text(state.scanning ? "正在检索默认位置…" : "未在默认位置发现 \(state.tool.title) 的技能目录。").font(.callout).foregroundStyle(.secondary) }
                    HStack {
                        Menu("添加自定义目录", systemImage: "folder.badge.plus") {
                            ForEach(SkillLocation.allCases, id: \.self) { location in
                                Button("\(location.title)…") { state.choose(location) }
                            }
                        }.fixedSize().disabled(state.scanning)
                        Text("默认目录自动读取；插件、系统及共享原文件保持只读。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if state.toolRoots.contains(where: { $0.location == .plugins || $0.location == .shared }) {
                        Text("共享与插件目录按连接来源展示；不代表所有条目已在当前 AI 中启用。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 10)
            } label: { Text("技能来源 · \(state.toolRoots.count) 个目录").font(.callout.weight(.medium)) }

            if !state.warnings.isEmpty {
                Label(state.warnings.prefix(2).joined(separator: "\n") + (state.warnings.count > 2 ? "\n另有 \(state.warnings.count - 2) 项提示" : ""), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(4).help(state.warnings.joined(separator: "\n"))
            }
            HStack {
                TextField("搜索技能、简介或路径", text: $state.search).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索技能")
                Toggle("仅看已选", isOn: $state.onlySelected).toggleStyle(.checkbox).fixedSize()
                Button("选择可移除项", action: state.selectVisible).disabled(state.scanning || !state.visible.contains(where: \.selectable))
                    .help("只选择当前列表中可移除的技能，保留已有选择")
            }
            if state.scanning {
                VStack(spacing: 14) { ProgressView(); Text(state.status).foregroundStyle(.secondary); Button("取消扫描", action: state.cancel) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.visible.isEmpty {
                ContentUnavailableView(state.toolRoots.isEmpty ? "未发现技能目录" : "没有可显示的技能", systemImage: "puzzlepiece.extension",
                    description: Text(state.toolRoots.isEmpty ? "已检查默认位置。若技能保存在其他地方，可展开“技能来源”添加自定义目录。" : "检查搜索条件，或点击重新扫描。只识别 SKILL.md 技能目录和直接引用。"))
            } else {
                HStack(alignment: .top, spacing: 0) {
                    List(state.visible) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("选择 \(entry.name)", isOn: Binding(get: { state.selected.contains(entry.id) }, set: { _ in state.toggle(entry) }))
                                .labelsHidden().toggleStyle(.checkbox).disabled(!entry.selectable).padding(.top, 3)
                                .accessibilityLabel("选择 \(state.tool.title) 技能 \(entry.name)")
                            Button { state.inspectedID = entry.id } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(entry.name).font(.headline).lineLimit(1)
                                        Spacer()
                                        Image(systemName: entry.removal == .readOnly ? "lock" : entry.removal == .reference ? "link" : "folder")
                                            .foregroundStyle(.secondary).accessibilityHidden(true)
                                    }
                                    Text("\(entry.source) · \(entry.removal.title)").font(.caption).foregroundStyle(.secondary)
                                    Text(entry.summary.isEmpty ? entry.url.lastPathComponent : entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("查看 \(entry.name) 的来源与影响")
                        }.padding(.vertical, 7)
                            .listRowBackground(state.inspectedID == entry.id ? Color.accentColor.opacity(0.07) : Color.clear)
                    }.listStyle(.inset).frame(minHeight: 0, maxHeight: .infinity)
                    if let entry = state.inspected {
                        Divider()
                        SkillDetailView(entry: entry) { state.inspectedID = nil }.frame(width: 265)
                    }
                }.frame(minHeight: 0, maxHeight: .infinity).clipped()
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("已选 \(state.selected.count) 项 · \(SweepState.size(state.selectedBytes))").font(.callout.weight(.medium))
                    Text(state.hiddenSelectionCount > 0 ? "其中 \(state.hiddenSelectionCount) 项不在当前列表中" : state.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !state.selected.isEmpty { Button("取消选择") { state.selected = [] } }
                Button("查看移除清单", action: state.prepareReview).buttonStyle(.borderedProminent)
                    .disabled(state.selected.isEmpty || state.scanning)
            }
        }.padding(24)
    }
}
