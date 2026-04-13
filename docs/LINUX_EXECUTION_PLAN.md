# Linux 详细移植计划

本文档给出一份可执行的 Linux 移植计划。目标不是泛泛而谈“以后可以移植”，而是把范围、阶段、代码边界、测试方式、风险和验收标准写清楚，方便后续直接照着推进。

## 1. 目标与约束

### 目标

Linux 第一版要做到：

- 读取本机 `~/.codex`
- 列出 session
- 扫描 session 状态
- rename / archive / unarchive / delete
- 向 `tmux` 中运行的 Codex session 单次发送
- 支持 loop daemon
- 保持和当前 macOS 版一致的核心发送语义

### 约束

- 不改变当前 macOS 程序的外部行为
- 不为了 Linux 迁移而把现有 macOS 逻辑做弱
- 不把“已受理待确认”混成“发送失败”
- 不允许模糊误发
- 不放开“同一真实 Session 同时多个运行态 loop”

### 第一版明确不做

- Linux GUI
- 多终端宿主兼容
- 桌面自动化按键发送
- 与 macOS App 完全一致的 UI
- 图标、打包、安装器

## 2. 调研结论

这一轮调研的重点不是“Linux 能不能自动化”，而是“哪个宿主最适合作为第一阶段稳定入口”。

### 2.1 `tmux` 是 Linux 第一阶段的正确宿主

原因：

- 有稳定的 pane / session 目标
- 能枚举 pane 和 tty
- 能抓取 pane 内容做状态判断
- 能直接发送文本和提交
- 不依赖 X11 / Wayland 焦点
- 更适合远程机、服务器、WSL、无头环境

这意味着 Linux 第一版的发送不应复用 macOS 的“窗口聚焦 + 粘贴 + 回车”思路，而应直接围绕：

- `tmux list-panes`
- `tmux capture-pane`
- `tmux send-keys -l`
- `tmux send-keys Enter`

来设计。

### 2.2 `screen` 可以作为后备宿主，但不应作为第一优先级

`screen` 具备一定输入注入能力，但目标定位、状态观测和后续维护性都不如 `tmux` 清晰。它更适合列在第二阶段候选，而不是一开始就并行支持。

### 2.3 `kitty` 和 `wezterm` 适合以后做“可编程 GUI 宿主”

这两个宿主都提供了更正规的程序化接口，理论上比通用桌面自动化更可靠。

但它们不适合作为 Linux 第一版的主路径，原因是：

- 第一版真正要解决的是“稳定投递到正在运行的 session”
- `tmux` 对这个目标更直接
- GUI 宿主支持会重新引入窗口、pane、宿主能力差异

所以正确顺序是：

1. 先把 `tmux` 路径做稳
2. 再考虑 `kitty` / `wezterm` 作为新增 Platform Adapter

### 2.4 不建议把 Linux 第一版建立在桌面自动化之上

不要把 Linux 第一版建立在这些能力上：

- X11 焦点切换
- Wayland 桌面自动化
- 系统剪贴板注入
- `xdotool` / `ydotool` 一类通用输入模拟

原因：

- 跨桌面环境差异太大
- 无头和远程场景很脆弱
- 很容易退化成“看起来发了，实际上误发或漏发”

## 3. 当前代码基线

经过这轮重构后，仓库里与 Linux 迁移最相关的边界已经比之前更清楚：

- [TaskMasterCore.swift](/Users/create/codex-terminal-app/TaskMasterCore.swift)
  - Foundation-only
  - 放共享语义的雏形
  - 已承载 session / loop 快照模型、probe/thread 解析、状态与 reason 映射、target 语义
  - 已显式承载 session provider / source / parent / type 元数据
- [TaskMasterSendRuntime.swift](/Users/create/codex-terminal-app/TaskMasterSendRuntime.swift)
  - 发送请求编排
  - 平台发送接口
  - macOS 发送实现
- [CodeTaskMasterApp.swift](/Users/create/codex-terminal-app/CodeTaskMasterApp.swift)
  - AppKit UI
  - session 展示、筛选、日志、用户交互
- [codex_terminal_sender.sh](/Users/create/codex-terminal-app/codex_terminal_sender.sh)
  - helper CLI
  - loop daemon
  - session 探测、session 操作、状态文件

这意味着后续迁移的正确方向不是“重写一个 Linux App”，而是继续把共享语义和平台适配边界拉直。

## 4. 目标分层

Linux 迁移按下面 4 层推进。

### 4.1 Core

应共享：

- SessionSnapshot / LoopSnapshot 等模型
- thread-list / probe-all 解析
- name / target / canonical session 语义
- provider / source / parent / type 语义
- status / terminal / reason 映射
- loop 互斥与重试退避语义
- local provider migrate 语义

当前落点：

- [TaskMasterCore.swift](/Users/create/codex-terminal-app/TaskMasterCore.swift)
- [codex_terminal_sender.sh](/Users/create/codex-terminal-app/codex_terminal_sender.sh)

### 4.2 Platform Adapter

应平台化：

- 解析 target 到具体 endpoint
- 探测 endpoint 输入状态
- 清理输入
- 发送消息
- 发送后验证

当前 macOS 落点：

- [TaskMasterSendRuntime.swift](/Users/create/codex-terminal-app/TaskMasterSendRuntime.swift)

Linux 目标落点：

- `platform/linux/tmux_adapter.sh`
- 或后续的 `platform/linux/*.py`

### 4.3 Queue / Orchestration

应保持统一：

- 单次发送与 loop 发送共用同一条发送主路径
- 统一输出 `success / accepted / failed`
- 统一 probe、验证、重试、结果归类

当前落点：

- [TaskMasterSendRuntime.swift](/Users/create/codex-terminal-app/TaskMasterSendRuntime.swift)

### 4.4 UI / CLI

Linux 第一版优先只做 CLI，不做 GUI。

## 5. 分阶段执行计划

### 阶段 0：冻结接口与语义

目标：

- 明确共享语义
- 明确 Linux 第一版只支持 `tmux`
- 明确错误分类和发送结果分类

产出：

- 当前这份计划文档
- 更新后的架构文档与平台接口文档

验收：

- 相关文档对 `success / accepted / failed`
- 对 `target / thread_id / canonical session`
- 对“单运行态 loop”这三组概念保持一致

### 阶段 1：继续抽离共享语义

目标：

- 让 UI 不再持有过多 Core 逻辑
- 为 Linux CLI 和后续平台适配提供稳定入口

本阶段应继续抽的内容：

- 进一步把 `codex_terminal_sender.sh` 中与平台无关的 session / loop 语义整理出来
- 继续收口状态文本、错误码、reason 映射
- 减少 `CodeTaskMasterApp.swift` 中的业务语义散落

建议文件方向：

- 扩展 [TaskMasterCore.swift](/Users/create/codex-terminal-app/TaskMasterCore.swift)
- 未来可继续拆成：
  - `TaskMasterSessionCore.swift`
  - `TaskMasterLoopCore.swift`
  - `TaskMasterReasonMap.swift`

验收：

- 新增或迁移的逻辑不依赖 AppKit
- 当前 UI 行为不变
- 现有检查脚本通过
- 不通过伪造 `source=cli` 来改变 session 类型

### 阶段 2：做 Linux `tmux` 适配器最小闭环

目标：

- 在 Linux CLI 下跑通“定位目标 -> 探测 -> 发送 -> 验证”

建议新建：

```text
platform/linux/
  tmux_adapter.sh
  probe_tmux_target.py

scripts/
  check_linux.sh
  smoke_linux_send.sh
```

本阶段任务：

1. 枚举 pane / tty / 当前命令
2. target 解析到唯一 pane
3. capture-pane 做 terminal_state 判断
4. send-keys 注入消息
5. send-keys Enter 提交
6. 验证 last_user_message 是否推进

验收：

- 找不到目标时给出明确错误
- 多匹配时给出明确错误
- 明确区分 `failed` 和 `accepted`
- 不依赖窗口焦点和剪贴板

### 阶段 3：复刻 Linux helper CLI

目标：

- 让 Linux 端具备和 macOS helper 类似的 CLI 行为

最低命令集：

- `thread-list`
- `probe`
- `probe-all`
- `send`
- `start`
- `stop`
- `status`

优先原则：

- 命令语义尽量和现有 helper 保持一致
- 不要求命令实现语言和 macOS 一致
- 但状态字段、reason 字段和日志语义要保持一致

验收：

- Linux CLI 输出能被现有共享语义层直接消费
- 至少支持 `success / accepted / failed`
- 至少支持 `ambiguous_target / target_not_found / not_sendable / send_unverified`

### 阶段 4：接回 loop daemon

目标：

- 把 Linux 侧的发送和当前 loop 语义接上

必须保留：

- 同一真实 Session 只有一个运行态 loop
- 可保留多个停止态历史 loop
- 忙碌或中间态失败时保守退避
- 连续失败时暂停而不是无限轰炸

验收：

- loop 不会因为模糊 target 误发
- loop 不会因为临时忙碌状态高频重试
- log 中能区分暂停、停止、互斥、延期、真实失败

### 阶段 5：补 Linux 专项测试

目标：

- 不把 Linux 验证完全依赖人工操作

建议测试层级：

1. 纯解析测试
2. helper smoke test
3. `tmux` 集成 smoke test
4. 手工真实工作流验证

建议新增：

- `scripts/check_linux.sh`
- `scripts/smoke_linux_send.sh`
- `tests/test_linux_probe_parsing.sh`

手工验证重点：

- 空闲 prompt 发送
- 残留输入 prompt 发送
- 目标不唯一
- pane 消失
- loop 冲突
- `accepted` 后稍晚成功

## 6. 详细工作拆分

建议按下面顺序推进，避免并行开太多面。

1. 保持 macOS 主功能稳定
2. 继续抽共享语义
3. 在 Linux 上实现 `tmux` 目标解析
4. 在 Linux 上实现单次发送
5. 在 Linux 上实现发送后验证
6. 让 Linux CLI 跑通 `probe-all` 和 `send`
7. 接回 loop daemon
8. 再考虑第二宿主或 GUI

## 7. 风险清单

### 高风险

- 目标定位错误导致误发
- `accepted` 和 `failed` 语义被混淆
- Linux 和 macOS 对同一 probe 结果给出不同状态解释

### 中风险

- `tmux capture-pane` 的状态解析过于脆弱
- 删除行为与 Codex 本地状态结构不完全兼容
- Linux helper 输出字段和现有 UI/日志口径不一致

### 低风险

- thread-list / probe-all 解析
- rename / archive / unarchive
- loop 状态文件与日志持久化

## 8. 验收标准

可以把 Linux 第一版“完成”定义成下面这些都成立：

- 能列出 session
- 能显示 name / thread id / status / terminal / tty
- 能 rename / archive / unarchive / delete
- 能对 `tmux` 中的目标 session 单次发送
- 能开始 / 停止 loop
- 能区分：
  - 成功发送
  - 已受理待确认
  - 拒绝发送
  - 真实失败
  - 发送后验证失败
  - loop 互斥暂停

## 9. 这一轮重构对计划的影响

这轮已经完成的一项 groundwork 是：

- 把共享语义雏形抽到了 [TaskMasterCore.swift](/Users/create/codex-terminal-app/TaskMasterCore.swift)

这会直接影响后续计划：

- 阶段 1 不再从零开始
- Linux CLI 可以优先围绕共享模型与解析语义对齐
- 后续重构应该继续沿“Foundation-only Core + 平台适配 + 队列 + UI”这个方向推进

## 10. 参考资料

下面这些资料支撑了“Linux 第一阶段优先 `tmux`、后续再考虑 GUI 宿主”的判断：

- `tmux` manual / wiki
  - https://man7.org/linux/man-pages/man1/tmux.1.html
  - https://github.com/tmux/tmux/wiki/Advanced-Use
- `kitty` remote control
  - https://sw.kovidgoyal.net/kitty/remote-control/
- `WezTerm` CLI
  - https://wezterm.org/cli/cli/send-text.html
  - https://wezterm.org/cli/cli/get-text.html
- GNU Screen manual
  - https://www.gnu.org/software/screen/manual/
