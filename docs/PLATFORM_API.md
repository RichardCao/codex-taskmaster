# 平台适配接口

本文档定义未来 macOS / Linux / Windows 共用的发送能力边界，目标是让 UI、loop daemon 和 CLI 共享同一套发送主路径，而不是各自拼装平台细节。

更具体的 Linux 阶段拆分见 [docs/LINUX_EXECUTION_PLAN.md](/Users/create/codex-terminal-app/docs/LINUX_EXECUTION_PLAN.md)。

## 目标

- 上层不再关心具体是 `Terminal.app`、`tmux` 还是别的宿主
- GUI 与 loop daemon 使用同一组语义
- 请求队列编排层与平台执行层解耦

## 术语

- `thread_id`：Codex session 的唯一 thread id
- `name`：真正 rename 后的名称
- `target`：用户可输入的目标值，用于 resume / 发送匹配
- `canonical session`：同一真实 session 的稳定标识，通常就是 `thread_id`
- `terminal endpoint`：平台侧真正的发送目标，例如 macOS TTY、Linux tmux pane

## 核心数据结构

### SessionDescriptor

```text
thread_id
name
target
provider
source
parent_thread_id
agent_nickname
agent_role
session_type
first_user_message
rollout_path
archived
updated_at
```

### SessionProbe

```text
thread_id
target
status
reason
terminal_state
terminal_reason
endpoint_id
endpoint_type
can_send
last_user_message_at
last_user_message
detail
```

### SendRequest

```text
target
message
force_send
clear_existing_input
```

### SendResult

```text
status
reason
target
force_send
probe_status
terminal_state
detail
```

补充约束：

- `status` 至少支持 `success`、`accepted`、`failed`
- `accepted` 表示平台或队列已接手请求，但暂时还没验证到最终成功
- 平台层只返回发送与验证结果，不负责决定 loop 并发占用策略

## 平台必须实现的能力

### 1. 列出运行中的目标宿主

建议接口：

```text
list_running_endpoints()
```

输出最少应包含：

```text
endpoint_id
endpoint_type
tty
command
```

Linux `tmux` 版本可以是：

- `endpoint_id = tmux pane id`
- `endpoint_type = tmux-pane`

### 2. 解析 target 到具体 endpoint

建议接口：

```text
resolve_target(target) -> endpoint or error
```

要求：

- 找不到时返回明确错误
- 多匹配时返回明确错误
- 不允许模糊误发
- 如果平台能解析到 canonical session，也应一并返回

### 3. 探测 endpoint 当前输入状态

建议接口：

```text
probe_endpoint(endpoint_id) -> terminal_state
```

输出应至少包括：

```text
terminal_state
terminal_reason
raw_preview
```

### 4. 清空当前输入

建议接口：

```text
clear_endpoint_input(endpoint_id)
```

注意：

- 平台适配层必须定义“清空输入”的真实行为
- Linux `tmux` 可以优先尝试发送 `C-u`

### 5. 发送消息

建议接口：

```text
send_to_endpoint(endpoint_id, message, submit=true)
```

要求：

- 文本必须完整送达
- `submit=true` 时必须真正触发提交
- 返回平台侧执行结果
- 如果平台已确认“输入已提交到宿主，但最终是否被 Codex 接收还需稍后验证”，必须能返回中间态，而不是直接伪装成失败
- 如果平台发送依赖系统焦点或剪贴板，必须保证恢复逻辑是平台实现的一部分，而不是让 UI 层补洞

### 6. 发送后验证

建议接口：

```text
verify_delivery(target, previous_timestamp, timeout_seconds) -> SendResult
```

这层不一定完全平台相关，但平台通常会参与。

## 请求队列层

平台执行层之上，建议单独保留一个请求队列编排层，例如：

```text
SendRequestCoordinator
```

职责：

- 从 pending queue 取请求
- 串行处理，避免并发误发
- 先 probe，再决定是否发送
- 调用平台适配器执行真实发送
- 做发送后验证
- 统一产出 `success` / `accepted` / `failed`
- 把结果写回 result queue

这个层不应直接依赖某个平台的窗口聚焦、剪贴板或按键实现。

建议额外约束：

- 单次发送与 loop 发送都必须走这层
- “可发送 / 不可发送 / 已受理待确认”的判定口径要一致
- 日志 reason 与 UI 展示 reason 应由这层或 Core 统一，不要各平台自己发明一套

## Core 必须实现的能力

下面这些不应继续散落在 UI 层。

### Session 读取

- `thread-list`
- `probe-all`
- `session count`
- name 语义解释
- provider / source / parent / type 元数据解释

### 状态映射

- `idle_stable`
- `interrupted_idle`
- `idle_with_residual_input`
- `busy`
- `unavailable`
- `archived`

### Session 元数据操作

- rename
- archive
- unarchive
- delete
- local provider migrate

补充约束：

- local provider migrate 只改本地 `threads.model_provider`
- 不应隐式改写 `source`
- 不应把子 agent thread 伪装成 `CLI`

### 发送策略

- 默认模式是否允许发送
- 强制模式是否允许跳过 probe 限制
- 是否需要自动清残留输入

### Loop

- loop 文件读写
- next run 计算
- loop daemon 调度
- loop 日志写入
- 同一 canonical session / thread id 只允许一个运行态 loop
- 可以保留多个停止态 loop 历史配置
- 对 `accepted`、`send_unverified` 等中间态或忙碌失败，需要支持更保守的重试退避
- target 与 canonical session 的绑定策略

## Linux `tmux` 适配器建议

建议新增一个明确的 Linux 实现文档或模块，例如：

```text
platform/linux/tmux_adapter.*
```

它至少要做：

- `tmux list-panes`
- `tmux capture-pane`
- `tmux send-keys -l`
- `tmux send-keys Enter`
- `tmux display-message`
- 必要时解析 pane tty、pane title、pane 当前命令

## 错误语义要求

所有平台都建议统一成下面这一类 reason：

- `target_not_found`
- `target_ambiguous`
- `endpoint_unavailable`
- `not_sendable`
- `send_interrupted`
- `send_unverified`
- `verification_pending`
- `queued_pending_feedback`
- `probe_failed`
- `loop_conflict_active_session`

如果是平台私有原因，也要附带：

```text
detail
```

## 不应由平台层决定的事情

下面这些不应塞回平台层：

- loop 是否互斥
- 某个 target 是否已经有运行态 loop
- 是否要因为连续失败而暂停 loop
- Activity Log 如何展示
- UI 是否弹窗
