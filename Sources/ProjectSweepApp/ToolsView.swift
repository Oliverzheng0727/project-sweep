import CleanupCore
import SwiftUI

struct ToolsView: View {
    @ObservedObject var state: SweepState
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("AI 工具的本地足迹").font(.largeTitle.weight(.semibold))
            Text("为每个工具单独选择数据文件夹。会话按工具与项目分组，项目记忆独立保护。")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                ForEach(ToolKind.allCases) { tool in
                    ToolConnectionStatusView(state: state, tool: tool)
                }
            }
            HStack {
                Label("Cursor 会话删除未开放：尚未通过实际安装版本与数据库格式验证。", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("扫描已授权目录", systemImage: "magnifyingglass", action: state.scanTools)
                    .disabled(state.configurations.isEmpty || state.busy)
            }
            if state.claudeRecoveryAvailable {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("发现未完成的 Claude 清理事务", systemImage: "arrow.uturn.backward.circle")
                            .font(.callout.weight(.medium))
                        Text("请先退出 Claude。恢复仅回滚中断的操作，不会恢复已正常删除的历史会话；已提交事务只清理残留事务文件。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("恢复未完成事务", action: state.recoverClaudeTransaction)
                        .disabled(state.busy || state.executing)
                }.padding(12).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            ItemBrowser(state: state, toolMode: true)
        }.padding(28).disabled(state.executing)
    }
}

struct SweepSettingsView: View {
    @ObservedObject var state: SweepState
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }.pickerStyle(.segmented)
            }
            Section("Codex 命令行") {
                TextField("可执行文件完整路径", text: $state.codexExecutable, prompt: Text("使用系统默认路径"))
                Text("会话操作使用受支持的官方接口。可填写自定义 Codex 可执行文件路径。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("保留规则") {
                if state.keepPaths.isEmpty { Text("暂无自定义规则。在项目文件详情中选择“始终保留”。").foregroundStyle(.secondary) }
                ForEach(state.keepPaths.sorted(), id: \.self) { path in
                    HStack {
                        Label(path, systemImage: "shield").textSelection(.enabled)
                        Spacer()
                        Button("移除规则") {
                            state.keepPaths.remove(path)
                            UserDefaults.standard.set(Array(state.keepPaths), forKey: "keepPaths")
                            state.invalidate(); state.items = []
                        }
                    }
                }
            }
            Section("操作约定") {
                Label("文件移入系统废纸篓，可从清理记录恢复。", systemImage: "trash")
                Label("历史会话不备份，清理前需要单独确认不可恢复。", systemImage: "bubble.left")
                Label("项目与工具清理保护认证、配置、插件、技能和项目记忆。技能需到“技能管理”单独选择。", systemImage: "lock.shield")
                Text("移动到废纸篓不会立即释放磁盘空间。应用不会自动清空废纸篓，也不会删除云端历史。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(16).navigationTitle("设置").disabled(state.executing)
    }
}
