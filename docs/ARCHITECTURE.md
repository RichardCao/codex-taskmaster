# 架构说明

本文档把当前仓库梳理成一套更稳定的分层视角，目标不是“立刻重写”，而是让后续 macOS 继续演进、Linux 迁移、Windows 评估时都沿着同一套边界做事。

当前实现事实：

- 仓库仍是单仓结构，但关键边界已经开始形成
- macOS UI 主入口是 [CodeTaskMasterApp.swift](/Users/create/codex-terminal-app/CodeTaskMasterApp.swift)
- 发送请求排队、平台发送适配、发送后验证主路径已经拆到 [TaskMasterSendRuntime.swift](/Users/create/codex-terminal-app/TaskMasterSendRuntime.swift)
- helper CLI、loop daemon、session 扫描与 session 操作主逻辑仍主要在 [codex_terminal_sender.sh](/Users/create/codex-terminal-app/codex_terminal_sender.sh)
- 当前平台实现默认面向 macOS `Terminal.app`

## 推荐分层

建议稳定成下面 4 层。

### 1. Core

平台无关，Linux / Windows / macOS 理论上都应共享同一套语义。

职责：

- 读取 Codex 本地 session 元数据
- 解析 `thread-list`、`probe`、`probe-all`
- 维护 name / target / canonical session 语义
- 维护 loop 配置、状态文件、日志与互斥约束
- 维护发送结果分类、错误码、原因文本

当前主要分布：

- [codex_terminal_sender.sh](/Users/create/codex-terminal-app/codex_terminal_sender.sh)
  - loop 状态与日志目录
  - `probe_session_status`
  - `probe_all_sessions`
  - `find_conflicting_running_loop_target`
  - 重试退避相关逻辑
  - `thread_archive` / `thread_unarchive` / `thread_delete`
  - `start_loop` / `stop_loop` / `status_loop`
- [CodeTaskMasterApp.swift](/Users/create/codex-terminal-app/CodeTaskMasterApp.swift)
  - `SessionSnapshot`
  - `parseProbeAllOutput`
  - `parseThreadListOutput`
  - `mergeSessionSnapshots`
  - 本地化状态 / terminal / reason 映射

后续原则：

- Core 不依赖具体窗口聚焦、剪贴板、按键注入
- 同一 canonical session / thread id 只允许一个运行态 loop 的规则放在 Core
- `accepted`、`send_unverified` 这类中间态的重试语义也应放在 Core

### 2. Platform Adapter

平台相关能力层，负责“把消息交给正确宿主”。

职责：

- 解析 target 到具体终端宿主
- 探测宿主当前输入状态
- 必要时清理残留输入
- 发送消息并提交
- 参与发送后验证
- 向上层暴露统一的 `success / accepted / failed` 结果

当前 macOS 相关实现：

- [TaskMasterSendRuntime.swift](/Users/create/codex-terminal-app/TaskMasterSendRuntime.swift)
  - `PlatformSendAdapter`
  - `MacOSTerminalSendAdapter`
  - `SendRequestCoordinator`
- [codex_terminal_sender.sh](/Users/create/codex-terminal-app/codex_terminal_sender.sh)
  - TTY 解析
  - AppleScript / `osascript` / `System Events`

后续原则：

- 平台层只做“发送到哪里、怎么发、发完怎么验”
- 不负责 loop 并发互斥
- 如果借助系统剪贴板，必须自带恢复逻辑
- 平台自动化不应长期阻塞 GUI 主线程

### 3. Queue / Orchestration

这是发送编排层，逻辑上应独立于平台层与 UI 层。

职责：

- 串行消费发送请求
- 先 probe，再决定默认模式是否允许发送
- 调用平台适配器执行真实发送
- 做发送后验证与结果归类
- 产出统一结果给 UI、loop daemon、日志系统

当前主要实现在：

- [TaskMasterSendRuntime.swift](/Users/create/codex-terminal-app/TaskMasterSendRuntime.swift)

后续原则：

- 单次发送与 loop 发送共用同一条发送主路径
- UI 不应该直接拼接平台细节
- Linux 版本即使先做 CLI，也应复用这层语义，而不是重新定义一套状态

### 4. UI / Packaging

负责交互、展示、构建与打包。

UI 职责：

- 表单输入
- 列表、排序、筛选、搜索
- Session 详情
- Activity Log 展示与导出
- 告警与状态提示

当前主要实现在：

- [CodeTaskMasterApp.swift](/Users/create/codex-terminal-app/CodeTaskMasterApp.swift)

打包与工具链当前主要在：

- [build_code_taskmaster_app.sh](/Users/create/codex-terminal-app/build_code_taskmaster_app.sh)
- [generate_icon.swift](/Users/create/codex-terminal-app/generate_icon.swift)
- [scripts/check.sh](/Users/create/codex-terminal-app/scripts/check.sh)
- [scripts/regression_check.sh](/Users/create/codex-terminal-app/scripts/regression_check.sh)

后续原则：

- UI 不直接承载平台自动化细节
- Linux 如果先做 CLI，可以暂时没有 UI
- macOS `.app` 打包链路不应直接迁移到 Linux

## 对 Linux 迁移最重要的边界

如果只看 Linux，最该稳定的不是界面，而是下面 3 个边界。

### A. Session 数据边界

要明确哪些逻辑属于共享语义：

- 读 `thread-list`
- 读 `probe-all`
- 合并 session 快照
- 解释真正的 `name`
- 维护 `target` 与 canonical session 的对应关系

### B. Send Engine 边界

建议统一成下面这条主路径：

- `resolveTarget`
- `probeTarget`
- `sendMessage`
- `verifyDelivery`

这样单次发送、loop daemon、未来 Linux GUI 才能复用。

### C. Session Mutation 边界

要单独稳定：

- rename
- archive
- unarchive
- delete

这样 macOS UI、Linux CLI、未来其他平台都能复用一套行为定义。

## Linux 推荐迁移顺序

### 第一步：先移植共享语义

先让下面能力在 Linux CLI 下跑通：

- session 扫描
- status 推断
- rename / archive / unarchive / delete
- loop 文件读写与状态语义

### 第二步：只支持一个宿主

建议第一优先级只支持 `tmux`：

1. `tmux`
2. `screen`
3. 某一个可编程 GUI 终端，例如 `kitty`

不建议一开始就支持：

- 任意桌面终端
- 任意 shell
- 任意窗口管理器

### 第三步：最后再决定 UI

推荐顺序：

1. `core + linux adapter + CLI`
2. 用真实工作流验证
3. 再决定是否需要 Linux GUI

## Linux 第一版建议目标

建议 Linux 第一版只追求：

- 读取本机 `~/.codex`
- 列出 session
- 做状态探测
- rename / archive / unarchive / delete
- 向 `tmux` 中运行的 Codex session 单次发送
- 支持 loop daemon

第一版不建议追求：

- 任意 GUI terminal 自动聚焦
- 桌面级按键自动化
- 多终端通用兼容
- 与 macOS UI 完全一致

## 当前不建议直接移植的内容

下面这些仍是强绑定 macOS 的，Linux 应视为参考，而不是直接复用：

- [CodeTaskMasterApp.swift](/Users/create/codex-terminal-app/CodeTaskMasterApp.swift)
- [build_code_taskmaster_app.sh](/Users/create/codex-terminal-app/build_code_taskmaster_app.sh)
- [generate_icon.swift](/Users/create/codex-terminal-app/generate_icon.swift)
- [scripts/ui_smoke_test.sh](/Users/create/codex-terminal-app/scripts/ui_smoke_test.sh)

## 建议目录演进方向

后续如果继续拆分，建议逐步演进成：

```text
docs/
  ARCHITECTURE.md
  PLATFORM_API.md
  LINUX_PORTING.md
  LINUX_HANDOFF.md
  LINUX_NEXT_STEPS.md

core/
  session_model.*
  session_status.*
  session_store.*
  loop_store.*

platform/
  macos/
  linux/

queue/

ui/
  macos/
  linux/
```

这里的 `*` 只是占位，具体语言后续再定。
