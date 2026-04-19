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

1. `done` 表格展示 formatter 收口
   目标：把 loop / session 表格列值、重复 target 展示、tooltip 与相关展示判断从 `CodexTaskmasterApp.swift` 下沉到 core formatter/helper。

2. `done` 顶部状态条规则收口
   目标：把状态条的颜色判定、优先级、自动清理时机与默认文案从控制器下沉到 core 纯规则。

3. `done` loop / send 交互提示模板收口
   目标：把剩余的 loop conflict、ambiguous target、runtime permission 等提示框文案与交互模板从控制器中抽离。

4. `in_progress` 主控制器残余展示编排清理
   目标：继续压缩 `CodexTaskmasterApp.swift` 中的展示性 helper、重复 UI 收尾逻辑和零散状态判断，为 Linux 迁移前做最后一轮收口。
   当前子任务：
   - `done` 重复 alert 执行 helper 收口
   - `pending` session / provider migration 交互状态收口
   - `pending` loop / session 选择与 blocked 提示收口
