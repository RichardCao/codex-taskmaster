# Linux 迁移方案

本文档只讨论“把当前项目迁移到 Linux”，重点是目标范围、阶段顺序和风险判断。

结论：

- 可以迁移
- 不应该把当前 macOS App 原样搬过去
- Linux 第一阶段应优先做 `共享语义 + tmux adapter + CLI`
- 先把发送链路跑通，再考虑 GUI

## 迁移目标

第一阶段建议目标：

- 在 Linux 上读取本机 `~/.codex`
- 列出 session
- 扫描 session 状态
- rename / archive / unarchive / delete
- 向 `tmux` 中运行的 Codex session 发送消息
- 支持 loop daemon

第二阶段再考虑：

- Linux GUI
- 其他终端宿主
- 更复杂的自动化

文档关系：

- 架构边界看 [docs/ARCHITECTURE.md](/Users/create/codex-terminal-app/docs/ARCHITECTURE.md)
- 平台接口看 [docs/PLATFORM_API.md](/Users/create/codex-terminal-app/docs/PLATFORM_API.md)
- 交接清单看 [docs/LINUX_HANDOFF.md](/Users/create/codex-terminal-app/docs/LINUX_HANDOFF.md)
- 行动说明书看 [docs/LINUX_NEXT_STEPS.md](/Users/create/codex-terminal-app/docs/LINUX_NEXT_STEPS.md)

## 为什么优先支持 `tmux`

因为 `tmux` 比桌面终端更稳定、更可编程。

优点：

- 可枚举 pane / session
- 可直接向 pane 注入按键
- 不依赖桌面环境
- 不需要 AppleScript / 辅助功能权限
- 更适合服务器、远程机、WSL、容器附近的工作流

建议 Linux 第一版发送链路优先设计成：

1. 找到运行 `codex resume ...` 的 pane
2. 判定 pane 是否处于可发送状态
3. 必要时清空当前输入
4. 发送文本
5. 发送 `Enter`
6. 再次验证消息是否推进
7. 如果短时间内还不能确认成功，也要返回“已受理待确认”，而不是直接判定失败

## 当前 macOS 绑定点与 Linux 替代方案

### 1. Terminal 窗口聚焦

当前：

- `osascript`
- `Terminal.app`
- `System Events`

Linux 替代：

- 不做窗口聚焦
- 直接面向 `tmux` pane id / pane tty / session id 发送

### 2. TTY 到窗口的映射

当前：

- `ps -axo tty,command`
- AppleScript 验证 `selected tab`

Linux 替代：

- 以 `tmux list-panes` 和 pane tty 为主
- 如果未来支持非 tmux，再补宿主适配器

### 3. GUI 粘贴与回车

当前：

- 依赖剪贴板
- GUI paste
- Return

Linux 替代：

- `tmux send-keys -l`
- `tmux send-keys Enter`
- 默认不应污染用户当前剪贴板
- 如果未来 Linux GUI 需要借助系统剪贴板，发送前后也必须做完整恢复

### 4. UI

当前：

- AppKit

Linux 替代建议：

- 第一阶段不做 GUI
- 或做单独的 Web / Tauri / Qt 前端

## Linux 第一版要保留的行为语义

即使换平台，下列行为建议保持不变：

- 默认只在“可发送状态”才发送
- 强制发送仍然要有明确标记
- 发送成功 / 失败必须写日志
- “已受理但还没验证到最终成功”必须单独记录，不能和失败混淆
- loop 与单次发送走同一条发送主路径
- 同一 canonical session / thread id 同一时刻只允许一个运行态 loop
- 可以保留多个停止态 loop 配置，但不应放开多个运行态 loop
- session 名称语义尽量贴近 `codex resume`
- rename / archive / unarchive 优先走 Codex 原生能力
- 平台自动化不能长期阻塞 UI 主线程；如果 Linux 以后补 GUI，这条也必须保留

这些约束里，最重要的是两条：

1. 不允许模糊误发
2. 不把“已受理待确认”伪装成“已失败”

## Linux 适配器建议接口

建议 Linux adapter 最少实现下面这些命令。

### 探测

- `linux-target-list`
- `linux-probe-target --target ...`

### 发送

- `linux-send --target ... --message ... [--force]`

### 清输入

- `linux-clear-input --target ...`

### 聚合

- `linux-probe-all`

## 推荐开发路径

### 路径 A：继续用 shell

适合先快速验证。

建议做法：

- 保留现有 helper CLI 风格
- 先新增 `codex_terminal_sender_linux.sh`
- 把 Linux 发送逻辑放进去

优点：

- 上手快
- 与现有脚本风格接近

缺点：

- 长期可维护性一般
- 状态模型会继续分散

### 路径 B：逐步转成统一核心

更适合长期维护。

建议做法：

- 保留现有 shell 工具作为参考实现
- 抽出统一的 session / loop / status 核心
- macOS 与 Linux 都只做平台适配

优点：

- 未来更容易扩平台
- 行为更一致

缺点：

- 起步会比直接写 Linux shell 版本慢一些

建议：

- 如果目标是尽快在 Linux 上继续用，先走路径 A
- 如果目标是后面继续支持 Windows 或 Linux GUI，尽快往路径 B 靠

## 推荐的实际执行顺序

建议按下面顺序推进：

1. 在当前仓库里先冻结文档和接口边界
2. 把整个仓库带到 Linux
3. 在 Linux 上只做 CLI，不做 GUI
4. 新增 `tmux` 适配器
5. 让 `thread-list`、`probe-all`、`send`、`start/stop/status` 跑通
6. 再补更稳定的验证、日志和测试
7. 最后再决定是否引入 GUI

## 预估难点

### 低风险

- session 扫描
- thread-list 解析
- rename / archive / unarchive
- loop 文件持久化

### 中风险

- Linux 上的状态推断一致性
- 删除行为与 Codex 本地状态文件的兼容性

### 高风险

- “向正在运行的 Codex session 稳定发消息”
- 支持多个终端宿主
- 在非 tmux 场景下避免误发
- 与 macOS 现有状态分类保持一致

## Linux 第一版不建议做的事

- 不要先做 Linux GUI
- 不要先支持 GNOME Terminal / Konsole / Alacritty 全家桶
- 不要先追求与 macOS UI 完全一致
- 不要先处理图标和打包细节

## Linux 第一版完成标准

我建议把“完成”定义成下面这些都能通过：

- 能列出 session
- 能显示 name / thread id / status / terminal / tty
- 能 rename / archive / unarchive / delete
- 能对 `tmux` 里的目标 session 单次发送
- 能开始 / 停止循环
- 日志里能区分：
  - 成功发送
  - 已受理待确认
  - 拒绝发送
  - 强制发送
  - 发送失败
  - 发送后验证失败
  - 同一 Session loop 互斥导致的暂停或拒绝

如果这些都成立，就说明 Linux 第一版已经具备“可继续迭代”的基础，不需要等 GUI 先到位。
