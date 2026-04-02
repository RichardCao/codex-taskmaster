# 平台适配接口

本文档定义未来 macOS / Linux / Windows 共用的能力边界。

目标：

- 上层不再关心具体是 `Terminal.app`、`tmux` 还是别的宿主
- GUI 与 loop daemon 使用同一组语义

## 术语

- `thread_id`：Codex session 的唯一 thread id
- `name`：真正 rename 后的名称
- `target`：用户可输入的目标值，用于 resume / 发送匹配
- `terminal endpoint`：平台侧真正的发送目标，例如 macOS TTY、Linux tmux pane

## 核心数据结构

### SessionDescriptor

```text
thread_id
name
target
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

- `status` 不应只允许 `success` / `failed`
- 还应允许表示“平台已接手，但暂时还没验证到最终成功”的中间态，例如 `accepted`
- 平台层只返回发送与验证结果，不负责决定 loop 的并发占用策略

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

### 6. 发送后验证

建议接口：

```text
verify_delivery(target, previous_timestamp, timeout_seconds) -> SendResult
```

这层不一定完全平台相关，但平台通常会参与。

## Core 必须实现的能力

下面这些不应继续散落在 UI 层。

### Session 读取

- `thread-list`
- `probe-all`
- `session count`
- name 语义解释

### 状态映射

- `idle_stable`
- `interrupted_idle`
- `idle_with_residual_input`
- `busy`
- `unavailable`
- `archived`

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

## 上层调用原则

- 单次发送和循环发送必须走同一发送主路径
- GUI 不直接拼平台命令
- 平台适配器不负责 UI 展示文案
- 文案本地化放在 UI 或展示层
- 平台自动化如果可能阻塞较久，不应长期占用 GUI 主线程
- 如果平台实现需要临时借用系统剪贴板，必须负责恢复，避免污染用户当前剪贴板
