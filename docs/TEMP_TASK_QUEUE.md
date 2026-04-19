# 当前临时任务队列

状态说明：

- `pending`：未开始
- `in_progress`：正在执行
- `done`：已完成并验证

执行规则：

- 按顺序逐项推进
- 每个切片都执行 `.app` 构建与启动验证
- 每个切片保留独立 commit
- 不等待额外确认，直接推进到当前队列完成

## 当前队列

1. `done` `thread-delete` rollout 删除边界收口
   目标：对 `thread-delete` 使用的 `rollout_path` 做严格 allowlist 校验，只允许删除 `~/.codex/sessions` 与 `~/.codex/archived_sessions` 下的真实文件路径；对越界路径直接 fail closed，并补 helper smoke 覆盖。

2. `done` inflight request 去重键修正
   目标：把发送请求 identity 明确为 `target + message + force_send`，避免普通发送与强制发送互相错误去重，并补 helper 覆盖。

3. `in_progress` session runtime status 协议对齐
   目标：让 helper 与 Swift/Core 的 session status 集合保持一致，补上 `idle_with_queued_messages` 等缺失映射，并补 core 回归。

4. `pending` terminal state 协议对齐
   目标：让 helper 与 Swift/Core 的 terminal state 集合保持一致，显式支持 `footer_visible_only`，避免 UI 退化成原始字符串。

5. `pending` 最近发送结果扫描正确性修复
   目标：修正 session 详情区“最近发送结果”的扫描逻辑，不再因为全局最新文件裁剪而漏掉当前 session 的较旧结果。

6. `pending` prompt 搜索缓存失效修复
   目标：后台 refresh 更新 session 快照时，同步失效受影响 session 的 prompt cache，避免搜索使用陈旧 rollout 文本。

7. `pending` helper metadata 协议安全化
   目标：替换 `load_target_metadata()` 及相关调用点当前未转义的 `|` 拼接协议，改成安全 JSON/编码协议，并补包含 `|` 的测试样例。
