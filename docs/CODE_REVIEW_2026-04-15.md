# 代码审查记录（2026-04-15）

本文档整理了对当前仓库的一轮静态代码审查结论。目标是：

- 不改变现有功能
- 优先指出高风险运行时问题
- 给出可落地的修正方向
- 为后续分批修复提供顺序参考

本轮没有对业务代码做任何修改。

## 审查范围

重点查看了以下文件：

- `CodexTaskmasterApp.swift`
- `TaskMasterSendRuntime.swift`
- `TaskMasterCore.swift`
- `codex_terminal_sender.sh`
- `scripts/check.sh`
- `tests/test_helper_smoke.sh`

补充说明：

- 本地执行了 `bash ./scripts/check.sh`
- 结果为通过
- 但执行过程中出现了两次 `/bin/ps: Operation not permitted`

这说明当前检查更偏向“能编译、能构建”，对运行时可靠性、受限环境兼容性和并发安全的覆盖还不够。

## 总体结论

当前项目能继续演进，但代码层面已经出现几个非常明确的维护风险：

1. 子进程调用模式不安全，存在管道阻塞和界面冻结风险。
2. UI 主线程承担了过多同步工作，一旦 helper 或系统调用变慢，窗口会直接卡住。
3. 控制器内的跨线程状态管理不够严格，存在数据竞争和状态撕裂风险。
4. 本地状态修改路径分散在 UI、Swift runtime 和 shell helper 中，边界已经开始漂移。
5. 文本协议解析、字符串状态模型和超大控制器文件会持续放大维护成本。

下面按严重程度给出具体建议。

## 高优先级问题

### 1. 子进程 I/O 模式存在死锁风险

涉及位置：

- `CodexTaskmasterApp.swift:5409`
- `CodexTaskmasterApp.swift:5433`
- `CodexTaskmasterApp.swift:5612`
- `CodexTaskmasterApp.swift:3399`
- `TaskMasterSendRuntime.swift:160`
- `TaskMasterSendRuntime.swift:276`
- `TaskMasterSendRuntime.swift:317`
- `TaskMasterSendRuntime.swift:391`

现状：

- 多处 `Process` 调用采用“先 `waitUntilExit()`，再读 `stdout/stderr`”的模式。
- 这在输出较多时是经典死锁写法。
- 子进程可能因为管道缓冲区写满而阻塞，父进程则在等待它退出。

风险：

- helper 输出稍大时，窗口可能无响应。
- `osascript`、`python3`、shell helper 一旦输出异常信息较多，会把 UI 拖死。
- 这类问题很难通过平时的“功能看起来能用”发现，但会在边界条件下集中爆发。

建议：

- 抽一个统一的 `SubprocessRunner`。
- 标准输出和错误输出必须在进程运行期间持续消费，而不是退出后一次性读取。
- 可选方案包括：
  - `FileHandle.readabilityHandler`
  - `FileHandle.bytes`
  - 单独 reader queue 持续读取
- 把 `Process` 启动、超时、终止、输出收集和错误包装全部统一收口。

### 2. 多个 UI 操作仍在主线程同步执行 helper

涉及位置：

- `CodexTaskmasterApp.swift:592`
- `CodexTaskmasterApp.swift:3354`
- `CodexTaskmasterApp.swift:3360`
- `CodexTaskmasterApp.swift:3493`
- `CodexTaskmasterApp.swift:5171`
- `CodexTaskmasterApp.swift:6353`
- `CodexTaskmasterApp.swift:6502`
- `CodexTaskmasterApp.swift:6606`

现状：

- 一些预检查、计划读取、归档/删除前的查询、provider 迁移计划读取仍在主线程同步调用 helper。
- 这些调用有的还会触发 SQLite 查询、shell 逻辑、Python 逻辑或 AppleScript。

风险：

- 用户点击按钮后界面卡顿。
- 数据库忙、文件系统慢、helper 偶发阻塞时，窗口会直接冻结。
- 退出时同步调用 `stop --all`，有把应用退出流程拖死的风险。

建议：

- 统一规定：所有 helper 调用都在后台执行，主线程只负责展示状态和结果。
- 对“需要先拿计划再弹确认框”的场景，改成：
  - 后台获取计划
  - 主线程展示 alert
  - 用户确认后再后台执行实际变更
- 退出清理不要阻塞主线程等待 helper 完成。

### 3. 控制器跨线程共享可变状态，存在数据竞争风险

涉及位置：

- `CodexTaskmasterApp.swift:785`
- `CodexTaskmasterApp.swift:793`
- `CodexTaskmasterApp.swift:5562`
- `CodexTaskmasterApp.swift:5691`
- `CodexTaskmasterApp.swift:5737`
- `CodexTaskmasterApp.swift:5770`

现状：

- `loopSnapshots`、`sessionSnapshots`、`allSessionSnapshots`、扫描状态变量等都集中在主控制器里。
- 有些状态通过锁保护，有些没有。
- 有些后台队列直接读取控制器状态，再在稍后回主线程提交结果。

风险：

- race condition 不一定立刻崩溃，但会表现为：
  - 状态偶发不一致
  - 列表刷新丢数据
  - 停止扫描后仍有旧结果回写
  - UI 选择态、进度态和实际数据不同步

建议：

- 明确规则：UI 状态只能在主线程读写。
- 最稳妥的做法是把 `MainViewController` 的 UI 状态约束到 `@MainActor`。
- 必须跨线程共享的状态，单独放进 actor 或串行 `DispatchQueue` 管理。
- 后台任务只处理不可变输入快照，不直接依赖控制器当前可变状态。

### 4. 永久删除路径不是原子操作，失败后会留下半完成状态

涉及位置：

- `codex_terminal_sender.sh:1527`
- `codex_terminal_sender.sh:1582`
- `codex_terminal_sender.sh:1603`
- `codex_terminal_sender.sh:1610`
- `codex_terminal_sender.sh:1612`
- `CodexTaskmasterApp.swift:3499`
- `CodexTaskmasterApp.swift:6450`

现状：

- 删除逻辑会分阶段删除：
  - `state_5.sqlite`
  - 日志数据库
  - `session_index.jsonl`
  - rollout 文件
- 各阶段不是统一事务。
- UI 侧还会做递归删除，放大失败面。

风险：

- 主库删掉了，但日志还在。
- session index 删掉了，但 rollout 还在。
- rollout 删掉了，但其他本地扩展状态残留。
- 一旦中途失败，系统进入“半删除”状态，后续修复困难。

建议：

- 拆成“删除计划”“执行删除”“结果回收/修复提示”三个阶段。
- 执行阶段至少要输出更结构化的 per-step 结果。
- 失败时明确告诉 UI 哪一步已经做完、哪一步没做完。
- 如果短期不做完整补偿事务，至少要留下 repair 信息，避免静默半成功。

## 中高优先级问题

### 5. UI 中内嵌 Python 修改本地状态，破坏 helper 边界

涉及位置：

- `CodexTaskmasterApp.swift:3398`

现状：

- `thread-name-set` 走 helper。
- 但清空名称 `clearSessionName` 却直接在 UI 文件里内嵌 Python，自己操作 `session_index.jsonl` 和 SQLite。

风险：

- rename 语义分叉。
- 后续如果 helper 对 session name 规则做调整，这里很容易漏改。
- UI 层承担本地状态写入细节，边界已经不干净。

建议：

- 增加统一的 helper 子命令，例如 `thread-name-clear`。
- session index 更新、`updated_at` 变更等规则只保留一份实现。
- UI 层只处理结构化结果，不直接嵌 Python 脚本。

### 6. App 与 helper 之间的冒号文本协议过于脆弱

涉及位置：

- `TaskMasterCore.swift:118`
- `TaskMasterSendRuntime.swift:608`
- `CodexTaskmasterApp.swift:5232`
- `codex_terminal_sender.sh:1138`
- `codex_terminal_sender.sh:1651`
- `codex_terminal_sender.sh:1741`
- `codex_terminal_sender.sh:1766`

现状：

- helper 输出大量 `key: value` 文本。
- Swift 侧至少有三处单独解析器。
- stdout/stderr 中混入 warning、detail、多行文本时，很容易污染协议。

风险：

- 字段改名无法被编译器发现。
- 多行错误详情难以安全表达。
- 不同模块对同一个字段的理解容易漂移。
- 协议一旦扩展，回归成本很高。

建议：

- 给 helper 增加稳定的 `--json` 输出模式。
- Swift 侧统一保留一份 decoder。
- 文本输出仅用于人读，不再承担程序协议职责。
- 逐步把 `parseProbeAllOutput`、`parseStructuredHelperFields`、`parseProbeOutput` 收口。

### 7. `config.toml` 的 `model_provider` 读取实现过于脆弱

涉及位置：

- `CodexTaskmasterApp.swift:3337`

现状：

- 当前是手写逐行扫描字符串，只要看到 `model_provider` 就截取等号后面的内容。

风险：

- 遇到 section、注释、重复键、未来配置扩展时，容易误读。
- 配置文件语义本来属于数据层，不应该由 UI 文件手写弱解析。

建议：

- 不要在 UI 层自己解析 TOML。
- 方案优先级建议：
  - 最优：helper 提供“读取当前 provider”命令
  - 次优：引入轻量 TOML parser
- 至少不要继续扩展这种手写扫描逻辑。

## 中优先级问题

### 8. 主控制器职责过载，已经不是单纯的大文件问题

现状：

- `CodexTaskmasterApp.swift` 当前约 6891 行。
- 这个文件同时承担了：
  - UI 组装
  - helper 调用
  - session 合并
  - loop 刷新
  - provider 迁移
  - rename / archive / delete 流程
  - 结果解析
  - 状态文案映射

风险：

- 任意一个功能都可能影响整个控制器。
- 改一处容易牵动多处。
- 很难给局部逻辑补测试。

建议：

- 优先按职责拆出最小服务边界：
  - `HelperRunner`
  - `SessionService`
  - `LoopService`
  - `ProviderMigrationService`
- 拆分目标不是“好看”，而是减少运行时和协议逻辑对 UI 的反向污染。

### 9. 核心模型过度依赖字符串，类型系统没有发挥作用

涉及位置：

- `TaskMasterCore.swift:3`
- `TaskMasterCore.swift:20`
- `TaskMasterCore.swift:39`

现状：

- 布尔值、状态枚举、epoch 时间都大量用 `String` 表达。

风险：

- 非法状态进入系统后很难被发现。
- 代码里充斥 `"yes"`、`"no"`、`"0"`、`"unknown"` 这种脆弱约定。
- 排序、比较、格式化和空值处理都依赖调用方小心处理。

建议：

- 优先把以下字段类型化：
  - `stopped`
  - `paused`
  - `loopDaemonRunning`
  - `forceSend`
  - `updatedAtEpoch`
  - `nextRunEpoch`
- `status`、`reason`、`terminalState` 至少改为 enum + fallback raw value。

### 10. 状态与原因映射仍然分散

涉及位置：

- `TaskMasterCore.swift:237`
- `TaskMasterCore.swift:285`
- `TaskMasterCore.swift:306`
- `CodexTaskmasterApp.swift:1536`
- `CodexTaskmasterApp.swift:1565`
- `CodexTaskmasterApp.swift:1597`

现状：

- session 状态本地化、send reason 本地化、terminal state 本地化分散在多个文件。

风险：

- 不同视图、不同路径对同一状态可能展示不同中文文案。
- helper 协议新增状态后，漏改概率高。

建议：

- 收口到统一的 mapping 层。
- 最好让 session 相关映射、send 相关映射分别集中定义。
- UI 只调用统一 formatter，不自行补条件判断。

### 11. 轮询和刷新逻辑较多，缺少更明确的调度边界

涉及位置：

- `CodexTaskmasterApp.swift:977`
- `CodexTaskmasterApp.swift:978`
- `CodexTaskmasterApp.swift:979`
- `CodexTaskmasterApp.swift:980`
- `CodexTaskmasterApp.swift:5605`
- `CodexTaskmasterApp.swift:5659`

现状：

- loop 列表刷新、请求泵、session 状态刷新都有各自 timer 和异步流程。
- 逻辑能跑，但调度点分散。

风险：

- 多个刷新源叠加后难以追踪。
- 出现“为什么又刷新了一次”时定位困难。
- 后续增加更多自动动作时容易互相干扰。

建议：

- 至少把刷新入口统一收口，明确：
  - 谁负责触发
  - 谁负责去重
  - 谁负责调度节流
  - 谁负责取消

## 中低优先级问题

### 12. `sessionTypeLabel` 的实现可读性和扩展性不足

涉及位置：

- `TaskMasterCore.swift:75`

现状：

- `source == "cli"`、`source == "exec"`、`source.contains("\"subagent\"")` 混在一起。
- 默认分支无论是否为空都返回 `"Other"`。

建议：

- 先解析 `source` 的结构，再做类型映射。
- 默认分支直接写成单一返回即可，不要保留无意义的 `source.isEmpty ? "Other" : "Other"`。
- 如果未来扩展类型，避免继续堆字符串匹配。

### 13. `mergeSessionSnapshots`、解析逻辑和 UI 使用方之间边界不够清晰

涉及位置：

- `TaskMasterCore.swift:118`
- `TaskMasterCore.swift:170`
- `TaskMasterCore.swift:216`
- `CodexTaskmasterApp.swift:2403`
- `CodexTaskmasterApp.swift:5758`

建议：

- Core 只负责解析和结构化合并。
- UI 不应再补大量“如果刷新后某些字段为空则沿用旧值”的语义拼接。
- 尽量让“刷新后如何保留旧字段”的规则进入统一 service 层。

## 测试与质量门槛问题

### 14. 当前测试覆盖远低于代码复杂度

涉及位置：

- `scripts/check.sh`
- `tests/test_helper_smoke.sh`

现状：

- 当前主要是 shell 语法检查、helper smoke test、Swift typecheck 和构建。
- `tests/` 下只有一个 shell smoke 脚本。

不足：

- 没有 `TaskMasterCore.swift` 的单元测试。
- 没有 `TaskMasterSendRuntime.swift` 的发送判定测试。
- 没有删除、归档、迁移等关键失败路径测试。
- 没有受限环境下 `ps`、辅助功能权限、TTY 歧义等回归测试。

建议：

- 最少补三类测试：
  - parser / merge / localization 单测
  - send runtime 决策矩阵单测
  - helper 状态变更类回归测试
- 把 `/bin/ps: Operation not permitted` 这类受限环境行为纳入预期测试，而不是让它悄悄从 stderr 漏过去。

### 15. `check.sh` 无法阻止“检查通过但输出脏错误”

涉及位置：

- `scripts/check.sh:11`
- `codex_terminal_sender.sh:355`
- `codex_terminal_sender.sh:372`

现状：

- helper smoke test 会在当前环境下打印 `/bin/ps: Operation not permitted`
- 但 `check.sh` 仍然整体返回成功

建议：

- 要么让 helper 在这种情况下静默降级。
- 要么让测试明确断言这是已知可接受输出。
- 不要维持“有错误输出但 CI 仍算成功”的模糊状态。

## 建议的修复顺序

建议按照下面顺序处理，而不是一口气全面重构。

### 第一阶段：先处理运行时稳定性

- 统一修复 `Process` I/O 模式
- 移除主线程同步 helper 调用
- 给关键 subprocess 增加超时、终止和错误包装

### 第二阶段：收紧并发边界

- 明确 UI 状态只能主线程访问
- 用 actor 或串行队列托管跨线程状态
- 减少后台任务直接读取控制器可变属性

### 第三阶段：收口协议和状态写入边界

- helper 增加 JSON 输出
- 清理 UI 内嵌 Python
- 将 rename / delete / archive / migrate 统一归到 helper service

### 第四阶段：提升可维护性

- 拆分 `CodexTaskmasterApp.swift`
- 类型化 Core 模型
- 集中状态/原因映射

### 第五阶段：补足测试

- Core parser/merge 单测
- Send runtime 决策测试
- 删除/迁移/归档失败路径测试
- 受限环境兼容性测试

## 最后结论

这个项目当前的问题不是“完全不能用”，而是典型的“功能已经长出来，运行时边界和维护边界开始失控”。

如果只能优先修一批，建议优先处理以下四项：

1. 子进程读写与等待模式
2. 主线程同步 helper 调用
3. 跨线程共享状态
4. 永久删除的半完成风险

这四项解决后，项目的稳定性会明显提高，后面的分层和重构也会更安全。
