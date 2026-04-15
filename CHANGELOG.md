# Changelog

## Unreleased

### Session 与界面

- `Session Status` 增加 `Provider` 列，并补齐 `Provider` / `类型` 两列的表头筛选能力
- Session 详情区补充 provider、parent、agent 等元数据的展示语义
- provider 迁移按钮统一为 `迁移当前会话` / `迁移全部会话`
- 目标 provider 与当前 provider 相同的场景，改为提示“无需迁移”
- 顶部按钮区和右侧 `Session Status` 面板的最小高度，改为按控件真实 `fittingSize` 推导，避免启动首帧和窗口缩放时出现按钮/详情区被压扁

### Session 操作

- 活跃 session 的归档和删除会被阻止，并给出更明确的弹窗说明
- 本地删除支持对子会话做向下递归规划；有父会话时只提示，不默认向上递归
- helper 新增 `thread-family-plan`，用于删除前的家族关系规划

### 发送与 loop

- 发送运行时继续沿着 `Core / Queue / Platform` 分层收口
- `.app` 名称与构建脚本统一为 `Codex Taskmaster`
- `发送一次`、`开始循环`、`恢复当前` 现在会先预检 `~/.codex-terminal-sender` 运行目录可写性
- 遇到 `runtime` / `loop-state` 权限问题时，UI 会直接弹出明确中文警告，而不再只显示泛化失败
- 最新本地验证已包含：
  - `bash -n codex_terminal_sender.sh`
  - `swiftc -parse CodexTaskmasterApp.swift TaskMasterCore.swift TaskMasterSendRuntime.swift main.swift`
  - `bash ./build_codex_taskmaster_app.sh`
  - `tests/test_helper_smoke.sh` 夹具已更新，跟上 helper 当前读取的 `threads` 字段

### 已知问题

- 如果旧的 `~/.codex-terminal-sender/runtime/loop-state` 目录仍由其他用户持有，旧 loop daemon 残留仍可能继续报权限错误
- 当前版本已能在操作前直接提示这类问题，但目录属主仍需要用户手工修正
