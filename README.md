# Codex Taskmaster

`Codex Taskmaster` 是一个原生 macOS 小工具，用来给 Terminal 里正在运行的 Codex 会话发消息，并管理循环发送任务。

它适合这样的使用场景：

- 你本地长期开着多个 Codex Terminal 会话
- 你想先看会话状态，再决定是否发送
- 你需要“每隔一段时间继续一次”这类循环任务
- 你希望在一个界面里查看会话、循环和日志，而不是手工切很多个 Terminal tab

## 下载

推荐直接下载 release 里的打包版 `.app`：

- [v1.0.0 Release](https://github.com/RichardCao/codex-taskmaster/releases/tag/v1.0.0)

下载后解压 `Codex-Taskmaster-v1.0.0-macos.zip`，即可得到 `Codex Taskmaster.app`。

## 系统要求

- macOS 13 或更高版本
- 使用 `Terminal.app`
- 本地已安装 Codex CLI
- 本地已有可用的 Codex 会话数据
- 如果要让 app 自动粘贴并回车发送，需要给它辅助功能权限

## 主要功能

- 查看本机 Codex 会话列表与状态
- 选中会话后发送一次消息
- 为会话创建循环发送任务
- 查看循环状态、失败原因和日志
- 改名、归档、恢复会话
- 执行本地彻底删除
- 查看会话的 provider、类型、父子关系、最近发送结果和提示词历史

## 第一次使用

1. 打开 `Codex Taskmaster.app`
2. 如果系统提示辅助功能权限，按提示去授权
3. 确保目标 Codex 会话已经在 `Terminal.app` 中打开
4. 在 `Session Status` 里点一次“检测会话”
5. 从列表里选择目标会话，再执行发送或开始循环

说明：

- app 按单实例运行处理
- 如果已经开着一个 `Codex Taskmaster`，再次打开时会切回现有窗口

## 你会看到什么

### Session Status

这里显示本机可见的 Codex 会话。

你可以在这里：

- 看会话当前是否像是可发送状态
- 看 `Provider`、`Type`
- 选择目标会话并填充到发送区
- 对会话执行改名、归档、恢复、删除等操作

### Active Loops

这里显示循环发送任务。

你可以在这里：

- 查看当前有哪些 loop
- 停止当前 loop
- 恢复停止态或暂停态 loop
- 删除旧 loop
- 看失败原因和下一次执行时间

### Activity Log

这里记录 app 的主要动作和结果。

它适合用来排查：

- 为什么没有发出去
- 为什么 loop 被暂停
- 为什么某个会话被判定为不可发送

## 发送规则

默认发送：

- 只有当目标会话看起来处于可发送状态时才会真正发送
- 这样更安全，能减少把消息插进错误时机的概率

强制发送：

- 会跳过“是否可发送”的状态判断
- 但仍然要求 app 能定位到唯一的 Terminal TTY
- 适合你明确知道自己要强行继续的场景

## Loop 规则

- 同一个真实会话，同一时刻只允许一个运行中的 loop
- 停止或开始失败的 loop 不会立刻消失，方便后续恢复或删除
- 关闭窗口或退出 app，不会自动停止后台 loop
- 如果你想停掉所有 loop，请显式点击“停止全部”

## 会话名称规则

界面里的 `Name` 和 `Target` 不是同一个概念。

- `Name`：真正 rename 过的名称
- `Target`：可用于恢复或发送的目标值

清空名称时，app 会把它恢复到“未 rename”状态，而不是保留一个空名字。

## 删除规则

“删除”是本地彻底删除，不是官方公开的云端删除接口。

它会尝试删除和该会话相关的本地数据，包括：

- 本地状态记录
- 本地 rename 记录
- rollout 文件
- 相关日志和扩展状态

如果你不确定，就不要点删除。优先使用“归档”更安全。

## 常见问题

### 1. 为什么点发送没有反应？

先检查这几项：

- 目标会话是否真的开在 `Terminal.app`
- app 是否拿到了辅助功能权限
- `Session Status` 里该会话是否被判定为可发送
- 当前是否其实需要用“强制发送”

### 2. 为什么 loop 启动了，但没有立刻发？

常见原因有：

- 目标会话当前忙碌
- 当前 Terminal 状态不适合发送
- 同一真实会话已经有别的运行中 loop

这些原因通常都能在 `Activity Log` 里看到。

### 3. 退出 app 之后 loop 还会继续吗？

会。

退出 `Codex Taskmaster.app` 只会关闭界面，不会自动执行 `stop --all`。

### 4. 为什么不能多开两个窗口？

当前版本按单实例处理。

再次打开时会激活已有窗口，而不是保留第二个常驻实例。

## 从源码构建

如果你是开发者，或者想自己本地打包：

```bash
./build_codex_taskmaster_app.sh
```

构建完成后可直接打开：

```bash
open "./Codex Taskmaster.app"
```

## 开发者文档

如果你关心实现、技术债、Linux 迁移或内部结构，请看这些文档，而不是把 README 当成设计文档：

- [ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [TECH_DEBT_PLAN.md](docs/TECH_DEBT_PLAN.md)
- [IMPROVEMENT_QUEUE.md](docs/IMPROVEMENT_QUEUE.md)
- [LINUX_PORTING.md](docs/LINUX_PORTING.md)
