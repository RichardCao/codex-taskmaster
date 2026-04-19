# Code Review Findings (2026-04-19)

## Summary

本次 review 以 bug、行为回归风险、设计脆弱点、测试缺口为主，已确认的 findings 共 7 条。

核心结论：

- 存在 1 个高风险本地删除问题：`thread-delete` 直接信任数据库中的 `rollout_path`，可删除 `~/.codex` 之外的任意用户文件。
- 发送队列和状态模型各有明显一致性问题，会导致错误去重、状态显示退化和历史结果缺失。
- 自动化验证并未覆盖这些高风险分支；现有测试主要覆盖 happy path 和部分 loop 回归。

已执行的本地验证：

- `bash tests/test_helper_smoke.sh`，通过，但输出了多次 `ps: Operation not permitted` 噪声。
- `bash tests/test_loop_history_model.sh`，通过。
- `bash tests/test_taskmaster_core.sh`，通过。
- `swift test` 未能作为有效信号使用：当前机器上的 `swift-package`/`llbuild` 工具链本身损坏，报 dyld 符号缺失。

## Findings

### 1. High: `thread-delete` 会无条件删除数据库里记录的 `rollout_path`，没有把删除范围限制在 `~/.codex` 会话目录内

- File: `codex_terminal_sender.sh:1734-1813`
- 关键位置：
  - `codex_terminal_sender.sh:1734-1744` 从 `threads` 表读取 `rollout_path`
  - `codex_terminal_sender.sh:1805-1813` 直接执行 `os.remove(rollout_path)`
- 问题：
  - 删除逻辑完全信任数据库中的 `rollout_path`。
  - 即使该路径不在 `~/.codex/sessions` 或 `~/.codex/archived_sessions` 下，代码仍会先删文件，再决定是否做目录清理。
  - `prune_empty_parent_dirs()` 只限制目录清理范围，没有限制文件删除本身。
- 风险：
  - 只要本地状态库被污染、手工改写、导入异常数据，或者未来 helper/迁移脚本写错路径，`thread-delete` 就可能删除任意当前用户可写文件。
  - 这是 destructive path，属于高严重度。
- 建议：
  - 在删除前对 `rollout_path` 做 `realpath`/`abspath` 校验，只允许落在明确 allowlist 根目录下。
  - 对不在 allowlist 内的路径直接 fail closed。
- 测试缺口：
  - `tests/test_helper_smoke.sh` 只覆盖了位于 `~/.codex/...` 下的正常 rollout 文件，没有覆盖恶意/异常路径。

### 2. High: 发送请求去重只看 `target + message`，会把不同发送模式的请求错误合并

- File: `codex_terminal_sender.sh:594-639`, `codex_terminal_sender.sh:2407-2435`
- 关键位置：
  - `codex_terminal_sender.sh:619-627` 只按 `target` 和 `message` 找 inflight request
  - `codex_terminal_sender.sh:2417-2431` 命中后直接返回 `request_already_inflight`
- 问题：
  - `find_matching_inflight_request()` 没把 `force_send` 纳入判重键。
  - 结果是普通发送在队列里时，用户立刻改成 `force send` 重试，也会被当成“同一个请求”拒绝。
  - 反过来也一样：一个激进的 `force send` 请求会阻塞一个原本更保守的普通发送。
- 风险：
  - 直接改变用户语义，尤其是 UI 上“强制发送”本来是为绕过状态限制准备的，结果却可能被旧的普通请求卡住。
  - loop 与手动发送共用这条队列时，这个问题更容易被触发。
- 建议：
  - 把 `force_send` 纳入 inflight 去重键。
  - 最好把请求 identity 明确定义为 `target + message + force_send`，必要时再考虑 timeout/source_tag。
- 测试缺口：
  - 现有 smoke test 只验证“同 target/message 被识别为 inflight”，没有验证 force/non-force 之间应当允许并存或替换。

### 3. Medium: helper 产出的 session status 与 Swift 侧状态枚举不一致，UI 会退化成原始字符串

- File: `codex_terminal_sender.sh:1219-1224`, `TaskMasterCore.swift:1417-1466`, `TaskMasterCore.swift:1487-1502`, `TaskMasterCore.swift:1660-1682`
- 关键位置：
  - helper 在 `codex_terminal_sender.sh:1222-1224` 产出 `idle_with_queued_messages`
  - Swift 状态枚举 `TaskMasterCore.swift:1417-1466` 并没有这个 case
  - 本地化 `TaskMasterCore.swift:1660-1682` 也没有这个映射
- 问题：
  - helper 和 UI/Core 之间的状态协议已经分叉。
  - 这个状态最终会落入 `.other(rawValue)`，界面、过滤、日志语义都只能显示裸字符串。
- 风险：
  - UI 文案不一致只是表面问题，更深层是状态判断表开始漂移，后续新增状态更容易继续悄悄失配。
  - 这属于协议层脆弱点，后续回归概率很高。
- 建议：
  - 收口状态常量来源，至少保证 helper 可能输出的每个 status 都被 `SessionRuntimeStatus` 和本地化逻辑覆盖。
  - 给 helper/Core 状态协议加单元测试。
- 测试缺口：
  - `TaskMasterCoreLibTests` 覆盖了 `queued_messages_pending` 等分支，但没有覆盖 `idle_with_queued_messages`。

### 4. Medium: helper 产出的 terminal state 也与 Swift 侧模型不一致，`footer_visible_only` 在 UI 侧没有显式支持

- File: `codex_terminal_sender.sh:1089-1102`, `TaskMasterCore.swift:1402-1414`, `TaskMasterCore.swift:1516-1533`, `TaskMasterCore.swift:1686-1708`
- 关键位置：
  - helper 在 `codex_terminal_sender.sh:1100-1102` 产出 `footer_visible_only`
  - `SessionTerminalState`、`localizedTerminalState()`、`localizedLoopTerminalState()` 都没有这个值
- 问题：
  - terminal state 协议同样已经漂移。
  - 一旦命中该状态，UI 会回退成原始英文值，过滤与展示语义不完整。
- 风险：
  - 这个状态正处在“未见提示符”和“可见 footer”之间，本来就需要更精确解释；现在用户只能看到裸值，难以判断能否恢复或发送。
- 建议：
  - 统一 helper 与 Core 的 terminal state 常量。
  - 明确 `footer_visible_only` 是否应映射到新枚举值、已有状态，还是根本不该作为对外状态暴露。
- 测试缺口：
  - 没有测试验证 helper 输出的 terminal state 集合是否被 Swift 侧完整消费。

### 5. Medium: Session 详情里的“最近发送结果”只扫描全局最新 180 个结果文件，容易把当前 session 的旧结果误判成不存在

- File: `CodexTaskmasterApp.swift:3376-3416`
- 关键位置：
  - `CodexTaskmasterApp.swift:3381-3395` 先取整个结果目录并全量按修改时间排序
  - `CodexTaskmasterApp.swift:3398` 只扫描 `sortedFiles.prefix(scanLimit)`，默认 180
- 问题：
  - 这个上限是按“全局最新文件”裁剪，不是按“当前 session 的匹配结果”裁剪。
  - 如果最近 180 个结果大多属于其他 session，当前 session 仍然存在的历史发送结果会被直接跳过。
- 风险：
  - 详情区会出现“暂无匹配该 session 的发送记录”的假阴性。
  - 用户在排查某个不活跃 session 的发送历史时，会误以为历史丢失。
- 建议：
  - 要么维护按 session 索引的结果文件，要么在达到 `maxItems` 前继续扫描，而不是先做全局硬截断。
  - 若担心性能，应该先做存储层 retention 或索引，而不是牺牲正确性。
- 测试缺口：
  - 当前没有任何测试覆盖“结果目录很大，但当前 session 结果较旧”的场景。

### 6. Medium: prompt 搜索缓存只在完整扫描/切 scope 时清空，后台状态刷新后会继续使用过期的 rollout 文本

- File: `CodexTaskmasterApp.swift:1854-1868`, `CodexTaskmasterApp.swift:3046-3064`, `CodexTaskmasterApp.swift:3433-3448`
- 关键位置：
  - `CodexTaskmasterApp.swift:3433-3448` 按 `threadID` 缓存 prompt corpus
  - `CodexTaskmasterApp.swift:3046-3064` 后台 session refresh 只更新 snapshot，不会清空 prompt cache
  - `CodexTaskmasterApp.swift:1854-1868` 只有 `resetPromptCache: true` 时才清空缓存
- 问题：
  - session rollout 持续追加时，prompt 搜索缓存不会随着后台 refresh 自动失效。
  - 搜索结果可能长期停留在旧 prompt 语料上，直到用户重新全量扫描、切换 scope，或者触发显式 cache reset。
- 风险：
  - 搜索命中结果与详情区真实 rollout 内容不一致，属于静默错误。
  - 这类 stale cache 最难排查，因为 UI 不会提示它是过期数据。
- 建议：
  - 至少在 session 的 `updatedAtEpoch` 或 `rolloutPath` 变化时清掉对应 `threadID` 的 prompt cache。
  - 更稳妥的做法是把缓存 key 扩展到 `(threadID, updatedAtEpoch)`。
- 测试缺口：
  - 没有测试覆盖“同一 session rollout 更新后，prompt 搜索结果应随之变化”的场景。

### 7. Medium: `load_target_metadata()` 用未转义的 `|` 拼接多字段，再由 shell `IFS='|' read` 解析，用户内容里出现竖线会破坏整个协议

- File: `codex_terminal_sender.sh:838-878`, `codex_terminal_sender.sh:1003-1014`, `codex_terminal_sender.sh:2790-2796`
- 关键位置：
  - `codex_terminal_sender.sh:874-877` 直接 `print("|".join(values))`
  - `codex_terminal_sender.sh:1009` / `codex_terminal_sender.sh:2796` 用 `IFS='|' read -r ...` 还原
- 问题：
  - `title`、`first_user_message`、`cwd`、`session_name` 都可能来自用户输入或本地数据，代码只替换了换行，没有转义 `|`。
  - 一旦这些字段包含竖线，后续变量整体错位，TTY 解析、provider/source 推断、probe 输出都会被污染。
- 风险：
  - 这不是理论问题，prompt/title 本身就是用户可控字符串。
  - 这种“文本协议无转义”的错误非常脆弱，后续新增字段时只会更难维护。
- 建议：
  - 改成 JSON 作为 helper 内部协议，或者至少做 base64/长度前缀编码。
- 测试缺口：
  - 现有测试夹具没有任何包含 `|` 的 title/message/session name 样本。

## Residual Risk

虽然当前 findings 已经覆盖了最值得优先修的风险，但仍有残余风险：

- `Package.swift` 的 SwiftPM/XCTest 路径链路未在当前机器上得到有效验证，因为 `swift test` 受本机工具链损坏影响，不能作为可靠信号。
- helper / Swift / UI 之间仍有多处自定义文本协议，后续很容易继续出现“新增值只改一侧”的回归。
- `CodexTaskmasterApp.swift` 与 `TaskMasterCore.swift` 文件体量很大，后续修改依然有较高的局部回归概率。
