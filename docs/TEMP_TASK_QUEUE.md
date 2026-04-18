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

3. `in_progress` 核心模型类型化
   目标：继续把布尔、时间和状态字段从字符串协议升级为更明确的类型。

4. `pending` merge / parser / fallback 规则收口
   目标：继续把快照合并、字段保留和 fallback 规则从 UI 下沉到 core / service。

5. `pending` 刷新调度边界收口
   目标：统一 loop 刷新、request pump、session 状态自动刷新等调度入口，明确去重、节流和取消。

6. `pending` 测试补强
   目标：补 parser / merge / localization、send runtime 决策矩阵、helper 状态变更与受限环境预期测试。

7. `pending` 单 loop + 多策略模型
   目标：同一 session 保留多个停止态历史 loop 配置，但同一时刻只允许一个运行态 loop。
