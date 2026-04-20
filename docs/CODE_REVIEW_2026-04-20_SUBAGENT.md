# Code Review Findings (2026-04-20 Subagent)

本次 review 只基于仓库当前内容自行探索，没有依赖对话上下文。重点放在 bug、行为回归风险、状态一致性、并发/线程问题、边界条件、测试缺口、平台兼容和文档实现不一致。

## Follow-up Status

本文件中的 6 条 findings 后续均已按独立切片修复并验证，相关提交如下：

- Finding 1 已修复：
  - `839ce2e Prevent loop worker writeback after stop or delete`
- Finding 2 已修复：
  - `4d7273c Avoid orphan active loop state after failed start`
- Finding 3 已修复：
  - `3c9a49d Fix loop resume by saved loop id`
- Finding 4 已修复：
  - `d209774 Restore empty rename fallback to session index`
- Finding 5 已修复：
  - `915b8f3 Enforce single-instance app startup`
- Finding 6 已修复：
  - `663ef20 Keep loops running when the app quits`

对应的执行状态也已同步到：

- `/Users/create/codex-terminal-app/docs/TEMP_TASK_QUEUE.md`
- `/Users/create/codex-terminal-app/README.md`

保留本 review 的目的主要是记录当时的发现过程、风险判断和修复优先级，而不是表示这些问题仍未处理。

## Verification

- 已执行：`bash ./scripts/check.sh`
  - 结果：通过。
  - 观察：`tests/test_helper_smoke.sh` 通过，但输出里仍有一条 `Terminated: 15` 的 daemon 终止噪声；这不构成失败，但说明测试日志还不够干净。
- 已执行：`swift test`
  - 结果：不能作为有效项目信号。
  - 原因：本机 Command Line Tools / SwiftPM 自身损坏，`swift-package` 启动时就报 `llbuild` 符号缺失的 `dyld` 错误。
- 额外做了 3 个最小化动态复现，均在临时目录中完成：
  - failed `start` 会留下一个“假活跃” orphan loop。
  - `loop-resume -k LOOP_ID` 会解析空 target 并失败。
  - `loop-once` 的 worker 运行中执行 `stop -t`，最终状态会被 worker 改回未停止。

## Findings

### 1. High: `stop` / `stop --all` / `loop-delete` 没有和正在运行的 loop worker 做同步，用户停止后的状态会被后台 worker 覆盖

- 文件/位置：
  - `/Users/create/codex-terminal-app/codex_terminal_sender.sh:3275-3398`
  - `/Users/create/codex-terminal-app/codex_terminal_sender.sh:3613-3673`
- 涉及函数：
  - `dispatch_loop_if_due`
  - `run_loop_iteration_for_key`
  - `stop_one`
  - `stop_all`
  - `delete_loop`
- 问题描述：
  - `dispatch_loop_if_due()` 会异步 fork 一个 loop runner，runner 在 `run_loop_iteration_for_key()` 里执行发送，然后无条件把状态写回 `.state`。
  - `stop_one()` / `stop_all()` 只是把状态文件改成 `STOPPED=1`；`delete_loop()` 只是删掉 loop/state/log 文件。
  - 这些路径都不会取消正在运行的 worker，也不会在 worker 最终写回前做二次校验。
  - 结果是：用户已经点了停止/删除，但后台 worker 仍可在数秒后把状态改回 `stopped: no`、重写 `next_run_epoch`，甚至重新生成刚删掉的状态/日志文件。
- 已确认复现：
  - 用一个 `sleep 2` 后返回成功的 send stub 触发 `loop-once`。
  - 在 worker 运行期间立即执行 `stop -t demo`。
  - worker 结束后，`status -t demo` 显示 `stopped: no`，并且存在新的 `next_run_epoch`。
- 风险：
  - “停止当前”并不可靠，属于直接的状态一致性 bug。
  - 用户会误以为 loop 已停止，但它实际上仍会继续调度下一轮。
  - `loop-delete` 同样受影响，意味着删除后仍可能被在途 worker 重新留下状态痕迹。
- 建议：
  - 把 runner PID 当成真正的可取消 job；在 `stop`/`delete` 时显式终止对应 worker，并等待它退出。
  - 或者至少在 worker 最终写回前重新读取一次 loop 文件 / 状态文件，若发现已被标记停止或已删除，则直接丢弃本次写回。
  - 更稳妥的做法是增加 cancellation token 或 generation/version 字段，写回前先比较版本。
- 测试缺口：
  - 当前测试没有覆盖“worker 正在执行时 stop/delete”的竞态场景。
  - `tests/test_helper_smoke.sh` 虽覆盖了 `loop-once` 和慢 stub，但没有覆盖中途 stop/delete。

### 2. High: `start_loop()` 在校验前先落盘 loop 定义，失败时又额外保存一条 stopped history，导致失败启动会留下一个“假活跃” orphan loop

- 文件/位置：
  - `/Users/create/codex-terminal-app/codex_terminal_sender.sh:3460-3537`
  - `/Users/create/codex-terminal-app/codex_terminal_sender.sh:395-414`
  - `/Users/create/codex-terminal-app/codex_terminal_sender.sh:416-487`
  - `/Users/create/codex-terminal-app/codex_terminal_sender.sh:3798-3804`
- 涉及函数：
  - `start_loop`
  - `mark_loop_stopped_entry`
  - `resolve_loop_key`
  - `status_one_text`
- 问题描述：
  - `start_loop()` 一开始就对 `hash_target(target)` 对应的 key 执行 `write_loop_definition()`。
  - 后续只要 `resolve_live_thread_id()`、`resolve_target_tty()`、`ensure_loop_daemon()` 等步骤失败，代码不是把同一条 loop 标记为 stopped，而是调用 `mark_loop_stopped_entry()` 再生成一条新的 stopped loop history。
  - 原先那条 hashed loop 不会被删除，也不会写入 stopped state。
  - `resolve_loop_key()` 在 `status -t target` 时会优先命中这条 orphan hashed loop，于是用户看到的是一条“未停止、unknown next_run”的假活跃 loop，而不是实际失败留下的 stopped history。
- 已确认复现：
  - 在一个没有可用 Codex state DB 的临时目录执行 `start -t missing-target -i 30 -m hello`。
  - helper 会同时留下两条 `.loop` 文件：一条 stopped history，一条没有 `.state` 的 orphan hashed loop。
  - `status -t missing-target` 返回的是 orphan loop，并显示 `stopped: no`。
- 风险：
  - 启动失败后 UI / CLI 看到的 loop 状态是错的。
  - `stop_loop_daemon_if_idle()` 和后续的 selector 逻辑都会把 orphan loop 当成活跃 loop 处理。
  - 这会污染 `Active Loops` 列表，用户很难判断哪一条才是有效历史。
- 建议：
  - 所有校验都通过之前，不要写任何最终 loop 定义。
  - 如果产品设计确实需要保留失败历史，应该复用同一个 key 把它标记为 stopped，而不是额外生成第二条记录。
  - 每个失败分支都应显式清理启动前写下的 hashed loop。
- 测试缺口：
  - 当前没有测试覆盖“`start` 失败后 `status -t` 应该返回 stopped history”的场景。
  - `tests/test_helper_smoke.sh` 目前只验证 `loop-save-stopped`，没有验证失败的 `start` 主路径。

### 3. Medium: `loop-resume -k LOOP_ID` 会忽略 loop 文件里已经保存的 target，转而解析空字符串 target

- 文件/位置：
  - `/Users/create/codex-terminal-app/codex_terminal_sender.sh:3550-3599`
- 涉及函数：
  - `resume_loop`
- 问题描述：
  - `resume_loop()` 先从 loop 文件里读取 `TARGET`、`INTERVAL`、`MESSAGE`、`FORCE_SEND`。
  - 但真正恢复时，仍然调用 `resolve_live_thread_id "$target"` 和 `resolve_target_tty "$target" ...`。
  - 当用户是按帮助文档允许的 `-k LOOP_ID` 方式恢复时，函数入口参数 `target` 为空，因此这里会去解析空字符串，而不是刚从 loop 文件读出来的 `TARGET`。
- 已确认复现：
  - 在临时 state DB 中创建一个可解析的 live session。
  - `loop-save-stopped -t alpha ...` 后拿返回的 `loop_id` 执行 `loop-resume -k "$loop_id"`。
  - 结果直接失败，报 `could not resolve live Codex thread id for target ''`。
- 风险：
  - `loop-resume -k LOOP_ID` 这条 selector 路径实际不可用。
  - 历史 loop 只能靠 `-t TARGET` 恢复，和 CLI 帮助的接口承诺不一致。
  - 一旦同 target 下保留多条 stopped history，用户就失去按 loop id 精确恢复的能力。
- 建议：
  - 在 `load_kv_file` 之后派生一个 `resolved_target="${TARGET:-$target}"`，后续恢复逻辑统一使用它。
  - 输出日志和成功结果时，也应使用这个 resolved target，避免继续打印空 target。
- 测试缺口：
  - `tests/test_helper_smoke.sh` 覆盖了 `loop-resume -t duplicate` 的错误路径，但没有覆盖 `loop-resume -k LOOP_ID`。

### 4. Medium: README 明确承诺“清空名称”会 fallback 到删除 `session_index.jsonl` 记录，但当前实现已经不存在这条 fallback

- 文件/位置：
  - `/Users/create/codex-terminal-app/README.md:254-255`
  - `/Users/create/codex-terminal-app/TaskMasterCore.swift:304-309`
  - `/Users/create/codex-terminal-app/codex_terminal_sender.sh:1853-1858`
- 涉及函数：
  - `SessionCommandService.updateSessionName`
  - `thread_name_set`
- 问题描述：
  - README 明确写着：因为原生 API 不接受空名称，所以“清空名称”时会回退到移除本地 `session_index.jsonl` 记录。
  - 但当前实现里，UI/service/helper 都只是把 `newName` 原样传给 `thread-name-set`。
  - helper 的 `thread_name_set()` 也只是直接调用 `codex_app_server_thread_rpc "name-set"`，没有任何空字符串特判或 `session_index.jsonl` 清理逻辑。
- 风险：
  - 文档承诺的功能现在很可能失效，至少已经是明确的实现/文档不一致。
  - 如果后端继续拒绝空名称，用户在 UI 中“清空名称”会直接失败。
  - 即使后端版本后来放开空值，这里也变成了依赖外部行为变化的隐式兼容，而不是仓库自己声明的稳定语义。
- 建议：
  - 要么恢复空名称 fallback：显式删除对应的 `session_index.jsonl` 记录。
  - 要么更新 README 和 UI 文案，明确说明当前不支持清空名称。
  - 最好把非空 rename 与清空 rename 分成两个 helper 子命令，避免在同一路径里做隐式分支。
- 测试缺口：
  - 当前没有任何自动化覆盖“rename to empty string”。

### 5. Medium: 请求队列和 Terminal 自动化只在单进程内串行化；README 的启动命令却显式使用 `open -na`，会鼓励多实例并发运行

- 文件/位置：
  - `/Users/create/codex-terminal-app/README.md:79-80`
  - `/Users/create/codex-terminal-app/CodexTaskmasterApp.swift:4941-4944`
  - `/Users/create/codex-terminal-app/TaskMasterSendRuntime.swift:503-571`
  - `/Users/create/codex-terminal-app/TaskMasterSendRuntime.swift:1183-1263`
  - `/Users/create/codex-terminal-app/TaskMasterSendRuntime.swift:38-89`
- 涉及函数：
  - `startRequestPump`
  - `SendRequestCoordinator.processPendingRequests`
  - `sendViaResolvedTTY`
  - `MacOSTerminalSendAdapter.sendMessage`
- 问题描述：
  - 每个 app 进程都启动自己的 request timer，每 0.5 秒扫描同一个 `requests/pending` 目录。
  - 进程内只有一个 `processingLock` 和一个 `terminalAutomationQueue`；这两个约束都不跨进程。
  - 同时，README 用 `open -na "./Codex Taskmaster.app"` 作为推荐启动方式，这会显式允许再开一个新的 app 进程。
  - 发送路径又会操作全局剪贴板、切前台窗口并发按键；这些资源天然是跨进程共享的。
- 风险：
  - 两个实例可以同时消费共享请求队列，也可以同时尝试自动化 Terminal。
  - 结果可能是焦点争用、剪贴板相互覆盖、按键串扰，最终把消息发错 tab 或恢复错误的剪贴板内容。
  - 这类 bug 出现时表面现象会非常随机，排查成本高。
- 状态：
  - 待确认。我这轮没有直接拉起双实例 UI 做黑盒复现，但代码层面确实没有任何跨进程互斥。
- 建议：
  - 最直接的做法是强制单实例运行。
  - 如果必须支持多实例，则请求处理和 Terminal 自动化至少要各加一层跨进程文件锁/OS 级锁。
  - README 也应避免继续使用 `open -na` 作为默认启动说明，除非已经明确支持多实例。
- 测试缺口：
  - 当前没有多实例并发发送测试，也没有跨进程 queue/clipboard/focus 竞争测试。

### 6. Medium: 关闭最后一个窗口会直接退出 app，并且在退出时无条件执行 `stop --all`，这让 loop daemon 的存活语义悄悄依赖于 UI 是否还开着

- 文件/位置：
  - `/Users/create/codex-terminal-app/CodexTaskmasterApp.swift:718-730`
  - `/Users/create/codex-terminal-app/README.md:288-294`
- 涉及函数：
  - `applicationShouldTerminateAfterLastWindowClosed`
  - `performTerminationCleanupIfNeeded`
- 问题描述：
  - App 关闭最后一个窗口时会直接终止进程。
  - 终止前的 cleanup 又同步执行一次 helper `stop --all`。
  - README 对 loop 的描述强调“运行态 loop”“停止态历史”“loop daemon”，但没有任何地方提醒用户“只要把窗口关掉，所有 loop 都会被强制停掉”。
- 风险：
  - 用户可能只是想暂时把 UI 关掉，却意外停止所有后台 loop。
  - 这和 helper/daemon 设计出来的“脱离单个发送动作独立运行”的语义相冲突，至少是严重的产品行为 surprise。
  - 退出时同步跑 helper 还有把 app 终止流程拖慢或拖挂的风险。
- 建议：
  - 如果这真是产品决策，就必须在 UI 和 README 里显式写明。
  - 如果不是，就不要在 `applicationWillTerminate` 里无条件 `stop --all`；把“退出前停止全部 loop”做成显式按钮或确认选项。
  - 另一个折中方案是保留 loop daemon，让 app 退出只影响界面，不影响后台 loop。
- 测试缺口：
  - 当前没有任何测试覆盖 app 退出语义。

## Residual Risks

- `swift test` 目前被本机 SwiftPM / Command Line Tools 运行时损坏阻断，所以 SwiftPM 维度的信号仍不完整。
- `CodexTaskmasterApp.swift` 和 `codex_terminal_sender.sh` 仍然承担了大量跨层职责；类似“UI 生命周期影响后台 loop”“helper 文本协议和状态文件协议耦合”这类问题，后续仍有较高回归概率。
- loop runtime 目前主要依赖文件系统状态和后台 worker 协作，缺少真正的 job/cancellation model；这意味着任何新的 stop/resume/delete 功能都很容易再次踩到状态竞争。

## 建议优先级

1. 先修复 loop 状态一致性问题：`stop/delete` 与在途 worker 的竞态，以及 `start` 失败留下 orphan loop。这两项会直接破坏用户对 loop 状态的信任。
2. 再修 `loop-resume -k` 和“清空名称”这两条接口/文档失配路径，因为它们已经影响到现有命令的可用性。
3. 然后决定产品层语义：是否允许多实例，退出 app 是否应该停止所有 loop。这里需要明确行为契约，再决定是加锁还是改文档/交互。
4. 最后补测试：至少为 failed start、resume by loop id、in-flight stop/delete、empty rename、多实例/退出语义各补一条回归。
