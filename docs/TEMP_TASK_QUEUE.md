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

1. `done` 发送运行时剩余收口
   目标：继续压缩 `TaskMasterSendRuntime.swift` 中的 orchestration、重试和失败分支，减少重复逻辑，收紧 helper 边界。

2. `done` 主控制器继续拆分
   目标：继续把 `CodexTaskmasterApp.swift` 中的 session / loop / provider migration 业务编排从控制器下沉到 service / helper / formatter。

3. `done` 核心模型类型化
   目标：继续把布尔、时间和状态字段从字符串协议升级为更明确的类型。
   当前子任务：
   - `done` loop 布尔字段类型化
   - `done` session `updatedAtEpoch` 类型化
   - `done` loop `nextRunEpoch` 类型化
   - `done` session `terminalState` 过渡访问器
   - `done` session `status` 过渡访问器
   - `done` send / loop `status` 过渡访问器
   - `done` send / loop `reason` 过渡访问器
   - `done` session / loop typed accessor 覆盖剩余裸字符串判断
   - `done` 评估是否将存储字段进一步改为 enum，而非仅保留 accessor
     当前结论：先保留 raw storage + typed accessor，等第 4 项 parser / merge / fallback 规则进一步收口后，再决定是否把底层存储直接切成 enum，避免在协议边界仍未稳定时做双重迁移。
   - `done` 类型化回归测试补齐

4. `done` merge / parser / fallback 规则收口
   目标：继续把快照合并、字段保留和 fallback 规则从 UI 下沉到 core / service。
   当前子任务：
   - `done` loop snapshot merge fallback 下沉到 core
   - `done` session refresh merge fallback 下沉到 core
   - `done` parser 入口统一使用共享 helper
   - `done` rollout recent user message parser 下沉到 core
   - `done` session refresh 覆盖式快照合并 helper 下沉到 core
   - `done` 批量 loop 快照合并 helper 下沉到 core
   - `done` 移除旧 loop 状态文本 parser
   - `done` send helper 结构化结果 parser 下沉到 core
   - `done` recent send result JSON parser 下沉到 core
   - `done` UI 层只保留展示，不再携带 merge 语义

5. `in_progress` 刷新调度边界收口
   目标：统一 loop 刷新、request pump、session 状态自动刷新等调度入口，明确去重、节流和取消。
   当前子任务：
   - `done` loop 刷新触发源盘点与收口
   - `done` session 自动刷新触发源盘点与收口
   - `pending` request pump / timer 去重与取消边界收口

6. `pending` 测试补强
   目标：补 parser / merge / localization、send runtime 决策矩阵、helper 状态变更与受限环境预期测试。
   当前子任务：
   - `pending` parser / merge 回归测试
   - `pending` localization 回归测试
   - `pending` send runtime 决策矩阵测试
   - `pending` helper 状态变更与受限环境测试

7. `pending` 单 loop + 多策略模型
   目标：同一 session 保留多个停止态历史 loop 配置，但同一时刻只允许一个运行态 loop。
   当前子任务：
   - `pending` 运行态唯一约束下沉到 core/helper
   - `pending` 停止态历史 loop 存储模型梳理
   - `pending` UI 展示与操作路径适配
   - `pending` 互斥与迁移测试
