# Codex Taskmaster

`Codex Taskmaster` 是一个原生 macOS 工具，用来向 Terminal 里运行的 Codex session 发送消息。它支持单次发送、循环发送、session 状态扫描、提示词历史查看，以及 session 的改名、归档、恢复、本地彻底删除和本地 provider 迁移。

这个项目面向本地 Codex CLI 工作流，核心目标有三点：

- 发送前尽量确认目标 session 处于可发送状态
- 支持可控的循环发送、停止和日志追踪
- 让 session 名称行为尽量贴近本机 `codex resume` 的实际表现

## 主要功能

- 原生 AppKit 单窗口界面
- `Session Status` 状态扫描与排序
- `Session Status` 显示 `Type` 列，区分 `CLI` / `Subagent` / `Exec` / `Other`
- `Active Loops` 循环任务列表与日志
- 选中 session 后查看完整信息、最近发送统计、最近发送结果、相关 Loop、提示词历史
- 单次发送与循环发送
- 可选 `强制发送` 模式
- `Activity Log` 支持关键词筛选、仅失败过滤、按当前 Session 过滤、导出当前 Session 日志
- session 改名
- session 归档与恢复
- 带风险提示的本地彻底删除
- 支持把当前 session 或全部 session 迁移到当前 `config.toml` 的 `model_provider`
- 按 session 状态决定是否允许发送
- 同一真实 Session 同一时刻只允许一个运行态 loop，避免重复轰炸

## 运行要求

- macOS 13 或更高版本
- Xcode Command Line Tools
- Terminal.app
- 本地已安装 Codex CLI，并且默认状态目录位于 `~/.codex`
- 如果要让应用代发按键，需要授予辅助功能权限

## 构建

在项目根目录执行：

```bash
./build_code_taskmaster_app.sh
```

这个脚本会完成：

- 用 `generate_icon.swift` 生成图标
- 构建 `Codex Taskmaster.app`
- 把 `codex_terminal_sender.sh` 打包进应用资源

如果你只想单独更新图标，不要直接裸跑 `swift generate_icon.swift`，请改用：

```bash
bash ./scripts/generate_icon.sh
```

如果需要指定 SDK，也同样走脚本：

```bash
MACOS_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk bash ./scripts/generate_icon.sh
```

SDK 选择策略：

- 默认优先使用本机已有的 macOS 15.x 或 14.x Command Line Tools SDK
- 如果需要强制指定 SDK，可设置 `MACOS_SDK_PATH`

例如：

```bash
MACOS_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk ./build_code_taskmaster_app.sh
```

## 启动

构建完成后可直接打开：

```bash
open -na "./Codex Taskmaster.app"
```

也可以在 Finder 里双击打开。

## 检查

执行项目自检：

```bash
bash ./scripts/check.sh
```

当前检查内容包括：

- shell 语法检查
- helper 冒烟测试
- Swift 类型检查
- app 构建

如果你想执行一轮更完整的本地回归检查，可以运行：

```bash
bash ./scripts/regression_check.sh
```

默认行为：

- 先执行 `scripts/check.sh`
- 不自动跑 UI smoke test

如果希望把 UI 启动烟雾测试也一起跑上，可以执行：

```bash
CODEX_TASKMASTER_RUN_UI_SMOKE=1 bash ./scripts/regression_check.sh
```

这个 UI smoke test 会：

- 启动 `Codex Taskmaster.app`
- 等待主窗口出现
- 通过 `System Events` 验证应用进程和窗口可见

注意：

- UI smoke test 依赖 macOS 辅助功能权限
- 它适合本机回归，不适合默认塞进所有无头或受限环境

## 工作方式

项目主要由四部分组成：

- `TaskMasterCore.swift`
  - 共享语义雏形
  - session / loop 快照模型
  - probe/thread 解析
  - 状态与 reason 映射
  - session 类型、provider、父子关系等元数据语义
- `CodeTaskMasterApp.swift`
  - 桌面界面
  - session 状态扫描
  - 表格、详情区、日志区和用户交互
- `TaskMasterSendRuntime.swift`
  - 发送请求排队与结果回收
  - 发送编排、probe、live tty recovery、结果归类
  - `PlatformSendAdapter` 与当前的 macOS 默认实现
- `codex_terminal_sender.sh`
  - helper CLI
  - session 探测
  - 循环状态持久化
  - 循环守护进程
  - session 归档、恢复、删除等辅助能力

应用会先排队发送请求，再探测目标 session 状态。默认模式下，只有目标看起来可发送时才会真正输入；强制模式会跳过这层 session 状态限制，但仍会返回发送成功或失败原因。

## Session 类型与 Provider

`Session Status` 现在会额外展示一列 `Type`，用于区分会话来源：

- `CLI`
- `Subagent`
- `Exec`
- `Other`

这个维度是为了让下面几类问题更容易判断：

- 为什么某条 session 能 `codex resume <id>`，但不一定会出现在默认 resume 列表里
- 为什么某条 session 更适合做人工维护主会话，而另一条更像内部执行线程
- 当前选中的 session 是不是某个父会话派生出来的子 agent

详情区还会显示：

- `Provider`
- `Parent Session ID`
- `Agent Nickname`
- `Agent Role`

其中 `Provider` 来自本地 `state_5.sqlite` 的 `threads.model_provider`，`Type` 则根据 `threads.source` 推断。

## Session 名称语义

这个项目不会把 `threads.title` 直接当成真正的 session 名称。

这里采用的判断逻辑是：

- 真正 rename 过的 session，以 `~/.codex/session_index.jsonl` 为准
- 如果那里没有对应记录，就视为“未 rename”
- 界面中：
  - `Name` 表示真正的 rename 名称
  - `Target` 表示可以用于 resume 或发送的目标值

这和本机 `codex resume` 的行为更接近。

非空 rename 会优先通过 Codex 原生 app-server API 的 `thread/name/set` 写回。清空名称时，由于原生 API 不接受空名称，所以仍然会回退到移除本地 `session_index.jsonl` 记录。

## 发送模式

默认模式：

- 只有当 session 看起来处于可发送状态时才发送
- 当前接受的状态包括：
  - `idle_stable`
  - `interrupted_idle`
- 同时还要求 Terminal 处于干净的 `prompt_ready` 状态

强制模式：

- 忽略 session 状态判断
- 但仍然要求能定位到唯一 Terminal TTY
- 发送后仍会检查用户消息是否真的推进

两种模式都会尽量返回：

- 成功或失败
- 失败原因
- 目标 session
- 是否强制发送
- probe 状态
- terminal 状态
- 具体细节

## Loop 语义

- 停止或开始失败的 loop 会保留在 `Active Loops` 里，便于后续恢复或删除
- 同一真实 Session 可以保留多个停止态历史配置
- 但同一时刻只允许一个运行态 loop 指向同一 canonical session / thread id
- 如果检测到同一 Session 已有其他运行中的 loop，新 loop 会被阻止或暂停，并记录 `loop_conflict_active_session`
- 对 `accepted`、`send_unverified`、force 模式下的典型忙碌失败，loop 会使用更保守的重试延迟，避免高频重复发送

## Session 操作语义

改名、归档和恢复归档优先走 Codex 原生 app-server API：

- 非空 rename：`thread/name/set`
- 归档：`thread/archive`
- 恢复：`thread/unarchive`

彻底删除不同于上面这三类操作：

- 目前 Codex 没有公开的原生永久删除 thread API
- 因此本项目里的“删除”是本地硬删除，不是公开原生语义
- 删除时会尝试移除：
  - `state_5.sqlite` 中的 thread 记录
  - 已知依赖的本地扩展状态
  - 结构化 thread 日志
  - `session_index.jsonl` 中对应的 rename/name 记录
  - rollout 文件本身
- 因为这不是公开原生 API，所以界面会弹出明显的风险提示

## Provider 迁移语义

界面中新增了两个按钮：

- `迁移当前到当前Provider`
- `全部迁移到当前Provider`

这里的“当前 Provider”指的是 `~/.codex/config.toml` 中当前配置的 `model_provider`。

当前迁移行为是本地状态迁移，不是 Codex 公开的原生 session API：

- 只修改 `state_5.sqlite` 里的 `threads.model_provider`
- 会同步刷新 `updated_at`
- 不修改 `source`
- 不重写 rollout 文件
- 不把子 agent 伪装成主 `CLI` 会话

如果选中的 session 是 `Subagent`，或者它拥有子 agent，会先弹确认框，让你选择：

- 只迁移当前这一条
- 递归迁移整组相关 session

“全部迁移”同样只做本地 provider 字段改写，不会改动 session 类型和 rollout 内容。

## 日志

界面中的 `Activity Log` 会记录：

- 执行了什么命令
- 发送成功
- 发送失败
- 因状态不满足而拒发
- 发送后验证失败
- session 操作结果

界面中的 `Activity Log` 还支持：

- 按 target / session / 关键词筛选
- 只看失败
- 只看当前选中 Session 的相关日志
- 保存当前筛选后的日志视图
- 单独导出当前 Session 的相关日志

每个循环任务的日志保存在：

```text
~/.codex-terminal-sender/runtime/loop-logs/
```

循环日志会记录：

- 循环开始
- 循环停止
- 实际发送结果
- 因忙碌或未就绪而延期的结果
- 因同一 Session 已存在其他运行态 loop 而触发的互斥暂停

## 仓库结构

- `CodeTaskMasterApp.swift`：主应用
- `TaskMasterCore.swift`：共享语义与解析逻辑
- `TaskMasterSendRuntime.swift`：请求队列与平台发送运行时
- `main.swift`：应用启动入口
- `codex_terminal_sender.sh`：helper CLI 与循环引擎
- `build_code_taskmaster_app.sh`：构建脚本
- `generate_icon.swift`：图标生成脚本
- `scripts/check.sh`：项目检查入口
- `scripts/regression_check.sh`：扩展回归入口，可选带 UI smoke test
- `scripts/ui_smoke_test.sh`：独立 UI 启动烟雾测试
- `tests/test_helper_smoke.sh`：helper 冒烟测试
- `docs/ARCHITECTURE.md`：架构边界与分层建议
- `docs/LINUX_EXECUTION_PLAN.md`：Linux 详细移植计划
- `docs/LINUX_PORTING.md`：Linux 迁移方案
- `docs/PLATFORM_API.md`：平台适配接口约定
- `docs/LINUX_HANDOFF.md`：迁移到 Linux 时的交接清单
- `docs/LINUX_NEXT_STEPS.md`：Linux 开发行动说明书
- `legacy/`：早期 AppleScript / JXA 原型

`.app` 包、图标输出等生成产物默认不纳入 Git。

## 说明

- 这是一个 macOS 专用项目
- 目前只针对 Terminal.app，不支持 iTerm2 等其他终端
- 默认使用当前用户 `~/.codex` 下的本地状态目录
- `session_index.jsonl` 的路径支持：
  - `CODEX_TASKMASTER_CODEX_SESSION_INDEX_PATH`
  - 兼容旧变量 `CODEX_TASKMASTER_SESSION_INDEX_PATH`

## 许可证

项目采用 MIT 许可证，见 [LICENSE](LICENSE)。
