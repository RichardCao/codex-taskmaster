# 技术债执行计划

本文档把 [CODE_REVIEW_2026-04-15.md](/Users/create/codex-terminal-app/docs/CODE_REVIEW_2026-04-15.md) 中的审查结论整理成一份可执行清单，目标是：

- 先压低高风险运行时问题
- 再收口协议、边界和状态模型
- 最后处理控制器拆分、类型化和测试补强

原则：

- 不在一个批次里同时做“功能开发 + 大重构”
- 优先处理会导致 UI 卡死、状态撕裂、协议漂移的问题
- 每一批都要有明确验收标准

## 当前执行方式

- 按批次顺序推进，不并行展开多个高风险重构
- 每完成一项任务，都执行一次 `.app` 构建与启动级验证
- 每完成一项任务，都保留一个独立 commit，便于回滚和 bisect
- 当前执行顺序：
  1. `done` `SubprocessRunner`
  2. `done` helper 后台化
  3. `done` UI 状态线程模型收口
  4. `done` 本地状态写路径统一走 helper
  5. `done` helper `--json` 协议与统一 decoder
  6. `done` 状态 / 原因 / 文案映射收口
  7. `done` `config.toml` 读取从 UI 层移出
  8. `done` 删除流程结构化
  9. `in_progress` 控制器拆分

## 执行顺序

推荐按下面顺序推进：

1. `SubprocessRunner` + helper 后台化
2. UI 状态线程模型收口
3. 本地状态写路径统一走 helper
4. helper `--json` 协议与统一 decoder
5. 状态 / 原因 / 文案映射收口
6. 删除流程结构化
7. 控制器拆分
8. 核心模型类型化
9. 测试体系补强

## P0

### 1. 统一子进程执行器

目标：

- 建立统一的 `SubprocessRunner`
- 统一 `Process` 启动、stdout/stderr 持续读取、超时、终止和错误包装

原因：

- 当前多处仍是“先 `waitUntilExit()`，再读输出”的模式
- 这会带来经典管道阻塞风险
- 一旦 helper 输出较多，最坏会把 UI 卡死

建议范围：

- [CodexTaskmasterApp.swift](/Users/create/codex-terminal-app/CodexTaskmasterApp.swift)
- [TaskMasterSendRuntime.swift](/Users/create/codex-terminal-app/TaskMasterSendRuntime.swift)

验收标准：

- 所有 `Process` 调用统一收口
- 不再出现“退出后一次性读 stdout/stderr”的模式
- 执行器支持超时、取消和结构化错误

### 2. helper 调用全部后台化

目标：

- UI 主线程只负责展示状态和结果
- 所有 helper / shell / SQLite / AppleScript 相关工作都移到后台

原因：

- 当前按钮卡顿、窗口冻结的主要风险来自同步 helper 调用
- 退出时同步执行 `stop --all` 也有拖死退出流程的风险

建议范围：

- 迁移、删除、归档、恢复、provider 计划读取
- session 扫描预检查
- loop 相关预检查和状态读取

验收标准：

- 主线程不再直接阻塞等待 helper
- “先拿计划再弹确认框”的流程改为后台读取计划，主线程只弹确认框
- 退出流程不再等待 helper 完成

### 3. 收紧 UI 状态线程模型

目标：

- UI 状态只在主线程读写
- 跨线程共享状态单独隔离

原因：

- `loopSnapshots`、`sessionSnapshots`、扫描状态、刷新状态目前边界不够严格
- 后台结果回写与用户操作交错时容易出现状态撕裂

建议范围：

- 给 `MainViewController` UI 状态增加明确主线程约束
- 必要时把共享状态放进 actor 或串行队列

验收标准：

- 后台任务只接收不可变输入快照
- 不再直接依赖控制器当前可变状态
- 停止扫描、切换视图、刷新列表时不会出现旧结果回写

### 4. 本地状态修改路径统一走 helper

目标：

- UI 层不再直接修改本地 SQLite / 文件

原因：

- 当前本地状态写路径分散在 UI、Swift runtime 和 shell helper 中
- 尤其是 UI 内嵌 Python 修改 session 状态，会破坏边界一致性

建议范围：

- rename / clear name
- archive / unarchive
- delete
- provider migration

验收标准：

- 所有状态变更都有对应 helper 子命令
- UI 只消费结构化结果
- 语义规则只保留一份实现

## P1

### 5. helper 协议增加 `--json`

目标：

- 给 helper 增加稳定的 `--json` 输出模式
- Swift 侧统一保留一套 decoder

原因：

- 当前 `key: value` 文本协议容易被 warning、多行 stderr、detail 混入污染
- 解析器已经分散在多个文件中

建议范围：

- `probe-all`
- loop `status`
- 删除计划 / 删除结果
- provider 迁移计划 / 执行结果

验收标准：

- 关键 helper 命令支持 `--json`
- Swift 侧不再维持多套文本解析器
- 文本输出只用于人读，不再承担程序协议

### 6. 收口状态 / 原因 / 文案映射

目标：

- session 状态、send reason、terminal state 的展示文案统一管理

原因：

- 当前中文映射分散在多个文件里
- 同一状态在不同视图里可能出现不同文案

建议范围：

- session 相关 formatter
- send / terminal 相关 formatter

验收标准：

- UI 只调用统一 formatter
- 业务逻辑不再自己拼接状态文案

### 7. `config.toml` 读取从 UI 层移出

目标：

- UI 不再手写弱解析 TOML

原因：

- 当前 `model_provider` 读取方式对 section、注释、重复键都比较脆弱

建议范围：

- 优先做 helper 子命令：读取当前 provider
- 次优引入轻量 TOML parser

验收标准：

- UI 文件里不再出现逐行扫描 TOML 的实现
- provider 获取有统一入口

### 8. 删除流程结构化

目标：

- 删除分为“删除计划”“执行删除”“结果回收/修复提示”三个阶段

原因：

- 当前删除不是原子操作，失败后容易留下半删除状态
- 之后排查很困难

建议范围：

- `state_5.sqlite`
- 日志数据库
- `session_index.jsonl`
- rollout / 扩展状态

验收标准：

- helper 返回 per-step 结果
- UI 能明确展示哪些步骤成功、哪些失败
- 失败时能给出 repair 信息

## P2

### 9. 拆分主控制器

目标：

- 把 [CodexTaskmasterApp.swift](/Users/create/codex-terminal-app/CodexTaskmasterApp.swift) 中非 UI 语义继续抽走

建议最小拆分目标：

- `HelperRunner`
- `SessionService`
- `LoopService`
- `ProviderMigrationService`
- `SessionStatusFormatter`
- `LoopStatusFormatter`

当前建议的首刀：

- 先把 helper 子进程执行抽成独立 `HelperCommandService`
- 再把 session / loop 命令 helper 调用分别下沉到 `SessionCommandService` / `LoopCommandService`
- 再继续把 session / loop / provider migration 语义从控制器中拆出

当前已完成：

- `HelperCommandService`
- `SessionCommandService`
- `LoopCommandService`
- `SessionScanService`
- session 刷新 merge / fallback 规则下沉到 core
- session 状态自动刷新调度边界下沉到独立 coordinator
- send / loop 结果展示文案拼装继续下沉到 core formatter
- session provider / terminal / tty 显示值 fallback 下沉到 core formatter
- session 详情区基础文案与最近发送统计文案继续下沉到 core formatter
- loop 状态 / 结果 / 原因标签与排序 rank 下沉到 core formatter
- session 详情区的 loop 占用文案下沉到 core formatter
- session 详情区预览/完整段落拼装下沉到 core formatter
- session 详情区剩余包装函数从控制器中移除，直接消费 core formatter
- session scope / empty state / search summary / meta label 文案下沉到 core formatter
- session 快速搜索、筛选匹配与筛选选项生成规则下沉到 core
- session scope 相关控制器包装函数移除，直接消费 core formatter
- session filter 面板哨兵项、标题和选中切换规则下沉到 core
- session filter kind 类型、列映射与按 kind 取筛选项规则下沉到 core
- session filter 选中状态收口为 core `SessionFilterSelections`
- session 扫描 meta label 文案下沉到 core formatter
- session 扫描流程中的状态栏 / 日志文案下沉到 core formatter
- session 状态刷新与 session scope 切换提示文案下沉到 core formatter
- session 状态刷新结果分类收口为 core `SessionStatusRefreshResultKind`
- session 状态刷新结果的 UI 状态应用收口为控制器单点 helper
- session 扫描 UI 收尾状态收口为控制器单点 helper
- session 扫描流程 stderr 输出保护收口为控制器单点 helper
- session 扫描入口默认文案与按钮标题下沉到 core formatter
- Session Status 双击填充目标提示文案下沉到 core formatter
- 已归档 session 的 rename/restore 提示文案下沉到 core formatter
- archive / restore session 的 action 文案与确认框文案下沉到 core formatter
- delete session 的 action 文案与确认框文案下沉到 core formatter
- 当前 session provider 迁移动作文案与确认框文案下沉到 core formatter
- 全部 session provider 迁移动作文案与确认框文案下沉到 core formatter
- session provider 迁移按钮标题与 tooltip 下沉到 core formatter
- session action 通用选择提示与操作区禁用状态收口到 core formatter / 控制器 helper
- session action 失败 stderr 输出收口到控制器单点 helper
- session action 成功后的列表移除与重渲染收口到控制器单点 helper
- provider migration 缺失 provider 与计划加载失败 UI 分支收口到控制器 helper
- provider migration 执行结果回写收口到控制器 helper
- provider migration loading 与计划完成按钮态收口到控制器 helper
- provider migration 计划加载中文案回写收口到控制器 helper
- provider migration 计划读取结果的按钮恢复与失败分支收口到控制器 helper
- provider migration 目标 provider 解析前置流程收口到控制器 helper
- provider migration 进入执行态的按钮/状态/日志切换收口到控制器 helper
- provider migration 执行态后台调度与主线程结果回写收口到控制器 helper
- session action 未选中 session 的日志/状态/beep 分支收口到控制器 helper
- session action 进入执行态的按钮/状态/日志切换收口到控制器 helper
- session action 失败状态的状态栏/stderr/beep 收口到控制器 helper
- session action 失败时的按钮恢复与失败态回写收口到控制器 helper
- session 删除/归档/恢复成功后的移除列表与完成态刷新收口到控制器 helper
- session archive/restore 的后台执行与成功失败回写收口到控制器 helper
- session delete 计划加载的按钮态、状态与失败提示收口到控制器 helper
- session delete 取消状态回写收口到控制器 helper
- session delete 的展示/执行线程 ID 计算收口到控制器 helper
- session delete live-session 阻止告警分支收口到控制器 helper
- session delete 失败时的告警、详情刷新与失败态回写收口到控制器 helper
- session delete 执行态后台调度与结果回写收口到控制器 helper
- session archive live-session 阻止告警分支收口到控制器 helper
- session archive 失败时的阻止告警与失败态回写收口到控制器 helper
- session action 被当前 session 状态阻止时的日志/状态/beep 收口到控制器 helper
- loop action 的辅助功能权限检查与失败回写收口到控制器 helper
- session rename 成功后的 snapshot 重建收口到控制器 helper
- session rename 成功后的列表刷新与完成态回写收口到控制器 helper
- provider migration noop 提示框/日志/状态收口到控制器 helper
- loop action 未选中循环任务的日志/状态/beep 分支收口到控制器 helper
- loop action 的选中循环前置判断收口到控制器 helper
- loop action 被当前 loop 状态阻止时的日志/状态/beep 收口到控制器 helper
- 辅助功能权限缺失时的 general/action 状态与日志分支收口到控制器 helper
- 发送一次/开始循环的空消息提示分支收口到控制器 helper
- 发送一次/开始循环的空消息失败回写收口到控制器 helper
- 发送一次/开始循环/恢复当前进入校验态的按钮/状态切换收口到控制器 helper
- 开始循环/恢复当前的目标校验失败分支收口到控制器 helper
- 开始循环/恢复当前的目标校验失败回写收口到 `performValidatedLoopAction` 重载
- 发送一次/开始循环/冲突替换启动的 force-send 展示参数拼装收口到控制器 helper
- 开始循环失败分支里“按当前输入保存停止态 loop”收口到控制器 helper
- stop/delete loop 的 target 填充与 helper 调用收口到控制器 helper
- resume loop 的 target 填充与 helper 调用收口到控制器 helper
- `HelperCommandResult` 的首选错误详情访问收口到 core accessor
- 控制器内目标校验与循环替换停止失败详情改为复用 `HelperCommandResult.primaryDetail`
- 控制器内 helper 失败详情拼接改为复用 `HelperCommandResult.combinedText`
- runtime 内 send coordinator 的首选失败详情读取收口到本地 helper
- 发送一次/开始循环/恢复当前的“进入校验态并执行目标校验”模板收口到控制器 helper
- 控制器内当前 loop message/force-send 输入快照收口到单点 helper
- 开始循环失败分支里“按当前输入保存停止态 loop 并刷新”收口到控制器 helper
- runtime 内 `SubprocessResult` 的首选错误详情访问收口到 core accessor
- loop status 加载失败详情改为复用 `HelperCommandResult.primaryDetail`
- rename/archive/restore/delete 的 session 选择读取统一复用 `selectedSessionSnapshot()`
- session detail 面板的选中 session 读取统一复用 `selectedSessionSnapshot()`
- 导出当前 Session 日志的未选中分支复用 `handleSessionSelectionRequired`
- rename/archive/restore 失败后的 session 操作区按钮恢复收口到控制器 helper
- session detail 面板的操作区按钮恢复复用同一组 session action controls helper
- session action 按钮置灰列表收口到控制器 helper，并保留 `renameField` 单独控制
- session 选中态布尔判断收口到 `hasSelectedSession()` helper
- provider migration 退出 loading / 执行态时的按钮恢复收口到控制器 helper
- provider migration 的取消状态回写收口到控制器 helper

下一步建议：

- 继续把 session / loop formatter 与展示文案边界继续收口
- 再把 loop / send 的 UI 编排模板继续收口

验收标准：

- UI 文件不再直接承担 helper 调用细节
- session / loop / migration 语义分别有稳定边界

### 10. 核心模型类型化

目标：

- 逐步减少 `"yes"`、`"no"`、`"unknown"`、`"0"` 这类字符串协议

优先字段：

- `stopped`
- `paused`
- `loopDaemonRunning`
- `forceSend`
- `updatedAtEpoch`
- `nextRunEpoch`
- `status`
- `reason`
- `terminalState`

验收标准：

- 布尔、时间和状态字段逐步变成更明确的类型
- 非法状态更早被发现

### 11. merge / parser / fallback 规则收口

目标：

- 把“刷新后如何保留旧字段”“如何合并快照”的语义从 UI 中移出去

原因：

- 当前 UI 层已经开始承担 merge fallback 的业务规则

验收标准：

- Core 或 service 层统一定义 merge 规则
- UI 只消费结果

### 12. 刷新调度边界收口

目标：

- 统一 loop 刷新、request pump、session 状态刷新等调度入口

原因：

- 当前 timer 和异步刷新源分散，排查“为什么又刷新了一次”很困难

验收标准：

- 明确谁负责触发、去重、节流和取消
- 自动刷新之间不再互相干扰

## 测试补强

### 13. parser / merge / localization 单测

目标：

- 为 [TaskMasterCore.swift](/Users/create/codex-terminal-app/TaskMasterCore.swift) 补基础单测

建议覆盖：

- parser
- merge
- 状态 / 原因本地化

### 14. send runtime 决策矩阵单测

目标：

- 为 [TaskMasterSendRuntime.swift](/Users/create/codex-terminal-app/TaskMasterSendRuntime.swift) 补发送判定测试

建议覆盖：

- `not_sendable`
- `accepted`
- `send_unverified`
- TTY 失效
- 权限缺失
- 歧义 target

### 15. helper 状态变更回归测试

目标：

- 为 helper 的状态变更类行为补回归测试

建议覆盖：

- 删除
- 归档 / 恢复
- provider 迁移
- 读取 provider
- 受限环境行为

### 16. 受限环境预期测试

目标：

- 把 `/bin/ps: Operation not permitted` 之类的受限环境行为纳入预期

原因：

- 现在这些行为只是从 stderr 漏过去
- 没有进入测试语义

验收标准：

- smoke / regression 测试能识别并允许受限环境的预期输出
- 不再把这类平台差异当成静默噪音

## 建议工作方式

- 不建议把 P0 和 P2 混在一个分支里做
- 每完成一项高优先级工作，都补对应测试或最小回归验证
- 文档更新顺序建议：
  1. 更新本文件
  2. 更新 [IMPROVEMENT_QUEUE.md](/Users/create/codex-terminal-app/docs/IMPROVEMENT_QUEUE.md)
  3. 再更新 README / CHANGELOG 中与行为变化相关的部分

## 当前结论

当前最值得优先投入的不是继续扩 UI，而是先解决三件事：

- 子进程执行模型统一
- helper 全部后台化
- 本地状态修改边界统一

这三件事做完之后，再继续加功能，回归成本和定位成本都会明显下降。
