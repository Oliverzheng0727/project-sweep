# 参与开发

开发环境为 Apple Silicon Mac、macOS 14 或以上和 Swift 6 工具链。克隆后运行：

```sh
swift build
swift test
bash scripts/verify-ui-boundaries.sh
bash scripts/build-app.sh
```

`swift test` 使用生成的隔离数据。实际 Codex 协议测试需要额外提供 `PROJECT_SWEEP_TEST_CODEX`，未配置时会跳过该项；详见 [README](README.md)。原生窗口操作的验收范围见 [验收记录](docs/acceptance.md)。

## 问题反馈

请注明系统、应用和相关 AI 工具版本，给出能在生成项目上重现的步骤、预期行为和实际结果。截图与日志请先移除个人路径、项目名称、会话正文、凭据和登录信息，不要上传真实工具数据库。

## 提交修改

说明解决的问题、用户可见的变化以及完成的验证。修改扫描、选择、清理或恢复规则时，补充能验证数据边界的隔离回归；只使用自行生成的文件测试删除与恢复。

请保留执行前复核、用户确认、系统保护与恢复不覆盖规则。无法明确归属或未验证的工具格式继续保持只读。Cursor 会话删除目前禁用，模拟测试不能代替实际工具版本的兼容性验收。
