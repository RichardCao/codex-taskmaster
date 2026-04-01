# 架构说明

本文档用于把 `Codex Taskmaster` 从“单个 macOS App 工程”梳理成“可移植的核心逻辑 + 平台适配层”。

当前项目的实现事实：

- UI、发送、session 扫描、循环、日志、session 管理都还在同一仓库内
- App 端主入口是 [CodexBianCeZheApp.swift](/Users/create/codex-terminal-app/CodexBianCeZheApp.swift)
- helper CLI 与循环引擎是 [codex_terminal_sender.sh](/Users/create/codex-terminal-app/codex_terminal_sender.sh)
- 当前发送链路默认面向 macOS `Terminal.app`

## 目标分层

建议按下面 4 层重构。

### 1. Core

平台无关，未来 Linux / Windows / macOS 都应共享。

职责：

- 读取 Codex 本地 session 元数据
- 解析 `probe` / `probe-all` / `thread-list` 结果
- 维护 session 名称语义
- 维护循环任务状态文件
- 维护日志输出格式
- 统一错误码、状态码、原因文本

当前对应的主要代码：

- [codex_terminal_sender.sh](/Users/create/codex-terminal-app/codex_terminal_sender.sh) 中：
  - loop 状态文件与日志目录常量
  - `append_loop_log_line`
  - `probe_session_status`
  - `thread_archive`
  - `thread_unarchive`
  - `thread_delete`
  - `probe_all_sessions`
  - `start_loop` / `stop_loop` / `status_loop`
- [CodexBianCeZheApp.swift](/Users/create/codex-terminal-app/CodexBianCeZheApp.swift) 中：
  - `SessionSnapshot`
  - `parseProbeAllOutput`
  - `parseThreadListOutput`
  - `mergeSessionSnapshots`
  - `localizedSessionStatusLabel`
  - `localizedTerminalState`
  - `localizedSessionReason`

### 2. Platform Adapter

平台相关能力层。重点是“定位 session 所在终端”和“向目标终端注入输入”。

职责：

- 找到目标 session 对应的终端宿主
- 聚焦目标宿主
- 清空残留输入
- 发送消息
- 发送后验证是否推进
- 枚举运行中的 session 终端

当前 macOS 实现：

- [codex_terminal_sender.sh](/Users/create/codex-terminal-app/codex_terminal_sender.sh)
  - `find_unique_tty`
  - `send_message_via_terminal_gui`
  - AppleScript / `osascript` / `System Events`
- [CodexBianCeZheApp.swift](/Users/create/codex-terminal-app/CodexBianCeZheApp.swift)
  - `focusTerminalWindow`
  - `sendViaAppKeystrokes`

Linux 迁移时，这一层应改为新的适配器，不要直接复用 macOS 逻辑。

### 3. Desktop UI

图形界面层，不应该再直接承载平台发送逻辑。

职责：

- 表单输入
- 列表呈现
- 排序 / 筛选 / 搜索
- 触发动作
- 展示日志

当前实现：

- [CodexBianCeZheApp.swift](/Users/create/codex-terminal-app/CodexBianCeZheApp.swift)

Linux 如果继续做 GUI，建议改成：

- Qt
- Tauri
- Electron
- 或先不做 GUI，只保留 CLI

### 4. Packaging / Tooling

构建、打包、图标、CI。

当前 macOS 绑定点：

- [build_codex_biancezhe_app.sh](/Users/create/codex-terminal-app/build_codex_biancezhe_app.sh)
- [generate_icon.swift](/Users/create/codex-terminal-app/generate_icon.swift)
- `.app` bundle
- `sips`
- `iconutil`
- macOS SDK / AppKit

Linux 上这部分需要重建，不能沿用。

## 推荐的 Linux 迁移顺序

### 第一步：先只移植 Core

先确保下面能力在 Linux 能无 GUI 地运行：

- session 扫描
- status 推断
- thread rename / archive / unarchive / delete
- loop 状态读写

这一步不要求发送消息。

### 第二步：做 Linux 发送适配层

建议优先限定一个终端宿主，而不是直接支持所有终端。

推荐顺序：

1. `tmux`
2. `screen`
3. 某一个可编程 GUI 终端，例如 `kitty`

不建议一开始就支持：

- 任意桌面终端
- 任意 shell
- 任意窗口管理器

### 第三步：再决定是否需要 Linux GUI

如果 Linux 侧只是自己使用，先做 CLI 往往更稳。

推荐顺序：

1. `core + linux helper`
2. CLI 验证
3. 再补 GUI

## 当前最应该拆出的边界

最值得优先抽离的边界有 3 个。

### A. Session 数据源边界

需要从 UI 和发送逻辑里分离出来的能力：

- 读取 `thread-list`
- 读取 `probe-all`
- 合并 session 快照
- 解释真正的 `Name`

### B. Send Engine 边界

建议统一成单一接口：

- `probeTarget`
- `locateTarget`
- `sendMessage`
- `verifyDelivery`

这样 GUI、loop daemon、单次发送就都能复用同一套发送管线。

### C. Session Mutation 边界

抽出：

- rename
- archive
- unarchive
- delete

保证未来 Linux CLI 和 GUI 都共用同一行为。

## Linux 端建议的最小版本目标

建议 Linux 第一版只追求下面能力：

- 支持读取本机 `~/.codex`
- 支持列出 session
- 支持状态探测
- 支持 rename / archive / unarchive / delete
- 支持 `tmux` 中运行的 Codex session 单次发送
- 支持 loop daemon

不建议 Linux 第一版就追求：

- 任意 GUI terminal 自动聚焦
- 桌面级 GUI 自动化按键
- 多终端通用兼容
- 和 macOS 图形界面完全一致

## 当前不建议直接移植的文件

下面这些文件是强绑定 macOS 的，应视为参考，不应直接作为 Linux 版本主实现：

- [CodexBianCeZheApp.swift](/Users/create/codex-terminal-app/CodexBianCeZheApp.swift)
- [build_codex_biancezhe_app.sh](/Users/create/codex-terminal-app/build_codex_biancezhe_app.sh)
- [generate_icon.swift](/Users/create/codex-terminal-app/generate_icon.swift)
- [scripts/ui_smoke_test.sh](/Users/create/codex-terminal-app/scripts/ui_smoke_test.sh)

## 建议的新目录结构

Linux 迁移时建议逐步演进成：

```text
docs/
  ARCHITECTURE.md
  LINUX_PORTING.md
  PLATFORM_API.md
  LINUX_HANDOFF.md

core/
  session_model.*
  session_status.*
  session_store.*
  loop_store.*

platform/
  macos/
  linux/

ui/
  macos/
  linux/
```

这里的 `*` 只是占位，语言可以后续再定。
