# Changelog

## Unreleased

### Session 与界面

- `Session Status` 增加 `Provider` 列，并补齐 `Provider` / `类型` 两列的表头筛选能力
- Session 详情区补充 provider、parent、agent 等元数据的展示语义
- provider 迁移按钮统一为 `迁移当前会话` / `迁移全部会话`
- 目标 provider 与当前 provider 相同的场景，改为提示“无需迁移”

### Session 操作

- 活跃 session 的归档和删除会被阻止，并给出更明确的弹窗说明
- 本地删除支持对子会话做向下递归规划；有父会话时只提示，不默认向上递归
- helper 新增 `thread-family-plan`，用于删除前的家族关系规划

### 发送与 loop

- 发送运行时继续沿着 `Core / Queue / Platform` 分层收口
- `.app` 名称与构建脚本统一为 `Codex Taskmaster`
- 最新本地验证已包含：
  - `bash -n codex_terminal_sender.sh`
  - `swiftc -parse CodexTaskmasterApp.swift TaskMasterCore.swift TaskMasterSendRuntime.swift main.swift`
  - `bash ./build_codex_taskmaster_app.sh`

### 已知问题

- `bash ./scripts/check.sh` 当前仍会失败在既有 helper smoke case：
  - `could not find rollout path for target 'alpha'`
- 这更像测试夹具或本地 smoke 前提未满足，当前未看到与本轮文档整理直接相关的新编译回归
