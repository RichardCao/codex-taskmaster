# Code Review Findings (2026-04-19 Round 2)

本轮 review 以 bug、行为回归风险、设计脆弱点、协议不一致、测试缺口、潜在安全问题和 Linux 迁移风险为重点。

结论：

- 已确认 findings 共 10 条。
- 其中 1 条为 `High`，8 条为 `Medium`，1 条为 `Low`。
- 当前仓库最明显的问题集中在 Terminal tab 探测、target 解析边界、loop runtime 隔离性、默认测试链路和 Linux 可移植性。

## Verification

本轮实际执行了以下验证：

- `bash tests/test_taskmaster_core.sh`
  - 结果：通过，输出 `taskmaster_core_regression_ok`
- `bash tests/test_loop_history_model.sh`
  - 结果：通过，输出 `test_loop_history_model_ok`
- `swift test`
  - 结果：未能作为有效项目信号使用
  - 原因：本机 `swift-package` / `llbuild` 工具链损坏，报 `dyld` 符号缺失
- `bash tests/test_helper_smoke.sh`
  - 结果：当前环境下 40 秒内未完成，无稳定结论
  - 观察：单独重跑时没有稳定输出，无法把它当作通过信号

## Findings

### 1. High: session probe 只读取每个 Terminal 窗口的选中 tab，后台 tab 会被误判成 `unavailable`，进而阻断默认发送

- 文件/位置：
  - `codex_terminal_sender.sh:1071-1104`
  - `TaskMasterCore.swift:1806-1829`
- 问题：
  - `read_terminal_snapshot()` 只检查 `selected tab of w`，没有遍历 `tabs of w`。
  - 这意味着只要目标 session 所在 tab 不是当前窗口选中的那个 tab，即使该 session 的 TTY 已经被正确解析，probe 仍会返回 `terminal_state: unavailable` / `reason: tty not found`。
  - `evaluateSendPreflight()` 在非 `force_send` 模式下要求 probe 状态必须是可发送态，因此这种误判会直接把正常可发送的 session 拦下。
- 风险：
  - 用户把 Codex session 放在后台 tab 时，UI 会把它显示成断联或不可发送。
  - 普通发送和 loop 发送会出现假阴性，只剩 `force send` 能绕过去。
  - 这是直接影响核心行为的 runtime bug，不是单纯的展示问题。
- 建议：
  - probe 侧应和发送侧的聚焦逻辑保持一致，遍历 `tabs of w` 并按 TTY 精确匹配。
  - 至少要区分三种状态：`tty 不存在`、`tty 存在但 tab 未选中`、`tty tab 可直接读取状态`。
  - 最稳妥的修法是把 Terminal tab 解析和 Terminal 状态采样统一到一套平台适配逻辑里，避免 probe 和 send 各维护一套 AppleScript 假设。
- 测试缺口：
  - 当前没有任何测试覆盖“目标 TTY 在非选中 tab 中，但 session 实际仍然在线”的场景。
  - 也没有测试验证这种 probe 结果是否会导致默认发送被错误阻断。

### 2. Medium: `resolve_thread_id()` 没有排除 archived session，live-only 操作可能先命中归档会话

- 文件/位置：
  - `codex_terminal_sender.sh:783-835`
- 问题：
  - 目标解析先查 `session_index.jsonl` 的 rename 名称，再查 `threads.title`，但这两条路径都没有过滤 `archived = 0`。
  - `send`、`start`、`probe`、`resolve-live-tty` 这类 live-only 操作会复用这个解析器。
  - 一旦 archived session 保留了同名 rename 或同名 title，live-only 操作就可能优先解析到 archived thread。
- 风险：
  - 用户输入一个看起来“存在”的 target，但后续却落到归档 rollout 上，表现成 `tty_unavailable`、`not_sendable` 或 loop 启动失败。
  - 如果活跃 session 和 archived session 重名，行为会变得不可预测，且用户很难从表面现象定位到“命中归档对象”。
- 建议：
  - 拆分“live resolver”和“archived-capable resolver”。
  - 对 `send`、`start`、`probe`、`resolve-live-tty` 默认只允许 `archived = 0`。
  - 只有 restore / delete-plan / family-plan 这类明确允许操作归档对象的路径，才应显式 opt in 到 archived 解析。
- 测试缺口：
  - 当前没有测试覆盖“archived session 与 active session 同名”的 target 解析。
  - 也没有验证 live-only helper 命令是否应该拒绝 archived 命中。

### 3. Medium: permanent delete 的 rollout allowlist 写死为 `~/.codex/...`，和已支持的自定义 state 根目录不一致

- 文件/位置：
  - `codex_terminal_sender.sh:1737-1755`
  - `codex_terminal_sender.sh:1889-1892`
  - `codex_terminal_sender.sh:1912-1975`
- 问题：
  - `thread_delete()` 和 `thread_delete_plan()` 的安全校验都把合法 rollout 根目录硬编码成 `~/.codex/sessions` 与 `~/.codex/archived_sessions`。
  - 但同一个 helper 顶部已经支持通过环境变量改写状态数据库、日志数据库、session index 和 config 路径。
  - 结果是：非默认 Codex 根目录下的合法 rollout 会被拒绝删除。
- 风险：
  - 用户一旦把 Codex 状态目录迁到别处，`thread-delete` / `thread-delete-plan` 就会出现假阳性安全拒绝。
  - 这既是行为回归风险，也会直接阻碍 Linux 或自定义目录布局场景的迁移。
- 建议：
  - allowlist 根目录应从已配置的状态根目录推导，而不是重新硬编码一个默认值。
  - `rollout_path` 校验和 `prune_empty_parent_dirs()` 的 stop root 也必须共用同一套根目录来源，避免“校验和清理边界不是同一个根”的二次漂移。
- 测试缺口：
  - 当前没有 delete/delete-plan 测试覆盖“自定义 Codex 根目录”的合法 rollout。
  - 现有测试只覆盖默认 `HOME/.codex` 布局。

### 4. Medium: `Package.swift` 的测试 target 路径大小写与仓库实际目录不一致，Linux / case-sensitive 文件系统上 SwiftPM 会直接失效

- 文件/位置：
  - `Package.swift:22-26`
  - 实际目录：`tests/TaskMasterCoreLibTests`
- 问题：
  - `Package.swift` 把测试目录写成了 `Tests/TaskMasterCoreLibTests`。
  - 仓库里的真实目录名是小写的 `tests/TaskMasterCoreLibTests`。
  - 在默认 macOS 大小写不敏感文件系统上这个问题会被掩盖，但在 Linux 或 case-sensitive APFS 上会直接导致 SwiftPM 测试链路找不到路径。
- 风险：
  - Linux CI 无法正常跑 `swift test`。
  - 后续如果把 Core 抽出来做跨平台验证，这个路径问题会成为最早爆炸的基础设施阻断点。
- 建议：
  - 修正 `Package.swift` 的 `path` 为仓库真实路径。
  - 增加至少一个 case-sensitive 环境上的 SwiftPM 校验任务，防止这类问题继续被 macOS 默认文件系统掩盖。
- 测试缺口：
  - 当前没有 Linux CI，也没有 case-sensitive 文件系统上的 package 验证。
  - 本机 `swift test` 还被 Command Line Tools 损坏掩盖了，导致这个问题没有得到自动反馈。

### 5. Medium: 默认检查脚本没有执行核心回归测试，`all checks passed` 不能代表核心语义稳定

- 文件/位置：
  - `scripts/check.sh:12-48`
  - `scripts/regression_check.sh:6-14`
  - 被遗漏的测试：
    - `tests/test_taskmaster_core.sh`
    - `tests/test_loop_history_model.sh`
    - `tests/TaskMasterCoreLibTests/TaskMasterCoreLibTests.swift`
- 问题：
  - `scripts/check.sh` 只跑 shell 语法、helper smoke、Swift typecheck 和 app build。
  - `scripts/regression_check.sh` 只是包了一层 `check.sh`，外加一个默认关闭的 UI smoke。
  - Core regression runner、loop history regression 和 XCTest suite 都不在默认检查链路里。
- 风险：
  - `TaskMasterCore.swift` 的状态映射、发送判定、loop 状态模型等核心规则即使回归，开发者仍可能看到“all checks passed”。
  - 这类误导性绿灯会放大后续行为回归和协议漂移风险。
- 建议：
  - 把 `tests/test_taskmaster_core.sh` 和 `tests/test_loop_history_model.sh` 纳入默认检查。
  - 本机工具链修复后，把 `swift test` 也纳入默认回归路径。
  - 如果担心耗时，至少应新增一个“严格检查”脚本并在文档中明确默认回归与严格回归的差异。
- 测试缺口：
  - 缺口就是当前默认检查脚本本身。
  - 我本轮手动执行了前两项 shell 回归，它们通过；但这些通过结果当前不会自动进入默认检查链路。

### 6. Medium: loop 状态一致性依赖 BSD `stat -f '%m:%z'`，这是明确的 Linux 迁移阻断点

- 文件/位置：
  - `codex_terminal_sender.sh:168-169`
  - `codex_terminal_sender.sh:3007`
  - `codex_terminal_sender.sh:3267`
- 问题：
  - `STATE_TAG` 依赖 `stat -f '%m:%z'` 来判断 loop 定义文件是否发生变化。
  - 这是 BSD/macOS 语法；GNU/Linux 的 `stat -f` 语义不同，不能稳定返回同一类文件级元数据。
  - 结果是 loop state 文件的新旧匹配逻辑在 Linux 上不可移植。
- 风险：
  - Linux 端会出现 `STOPPED/PAUSED/FAILURE_COUNT` 被错误当成旧状态或新状态的情况。
  - loop state 可能表现成“状态经常丢失”“暂停状态不生效”“停止后又复活”等难排查问题。
- 建议：
  - 用 `python3` 的 `os.stat()` 统一生成 source tag，或显式区分 BSD / GNU `stat`。
  - 这类状态标签生成逻辑应该抽成一处平台无关函数，而不是在多个 shell 位置直接拼平台命令。
- 测试缺口：
  - 当前没有任何 Linux loop 状态持久化测试。
  - 也没有测试覆盖 source tag 在不同平台命令实现上的一致性。

### 7. Medium: loop daemon 启动前会无差别杀掉同一脚本路径下的所有用户 daemon，多个隔离实例会互相踩踏

- 文件/位置：
  - `codex_terminal_sender.sh:474-520`
  - `codex_terminal_sender.sh:3107-3115`
- 问题：
  - `ensure_loop_daemon()` 每次启动前都会调用 `stop_user_owned_sender_daemons()`。
  - 后者按“同一脚本路径 + 当前用户”枚举并 `kill`，并不区分 `STATE_DIR` 或具体实例。
  - 也就是说，只要两个实例复用同一 helper 路径，即使它们状态目录完全不同，启动其中一个也会把另一个停掉。
- 风险：
  - 多实例开发、A/B 测试、隔离状态目录调试都会互相干扰。
  - 这会让 loop 行为出现“刚启动就莫名被别的实例停掉”的静默错误。
- 建议：
  - daemon 身份应至少绑定到 `STATE_DIR` 或单独的实例 id。
  - pid 文件和进程枚举逻辑都应按实例范围收敛，而不是按脚本路径全局扫描。
- 测试缺口：
  - 当前没有“同一 helper 路径 + 不同 `CODEX_TASKMASTER_STATE_DIR` 并行运行”的测试。
  - 也没有覆盖 daemon 互斥边界是否只应限制在单个 runtime 实例内。

### 8. Medium: loop 调度是串行阻塞的，一个慢 target 会拖住所有其他 loop

- 文件/位置：
  - `codex_terminal_sender.sh:2517-2545`
  - `codex_terminal_sender.sh:3047-3054`
- 问题：
  - `process_loops_once()` 在遍历 loop 文件时，会同步调用 `send_message_when_ready()`。
  - `send_message_when_ready()` 本身会等待 probe、排队发送和结果回收，最长可阻塞到 `timeout_seconds + 10`。
  - 成功发送后，当前循环还会额外 `sleep "$LOOP_POST_SEND_COOLDOWN_SECONDS"`，并且这段 sleep 发生在整个扫描主循环中。
- 风险：
  - 只要某个 target 很慢、很忙，其他本来已经到期的 loop 都会被整批拖后。
  - 多个 loop 并存时会出现全局调度漂移，而不是单个 loop 的局部延迟。
- 建议：
  - 把“扫描哪些 loop 到期”和“执行某个 loop 的一次发送”拆开。
  - 至少不要在全局扫描循环里直接 sleep。
  - 更稳妥的方案是：到期时把执行任务入队，然后立刻返回继续扫描其他 loop。
- 测试缺口：
  - 当前没有任何多 loop 调度公平性测试。
  - 也没有覆盖“一个 loop 长时间 busy，另一个 loop 仍应按时推进”的场景。

### 9. Medium: `probe-all --json` 和 `status --json` 把整段文本结果塞进单个 argv 参数，规模一大就会撞上 `ARG_MAX`

- 文件/位置：
  - `codex_terminal_sender.sh:2112-2142`
  - `codex_terminal_sender.sh:3394-3429`
- 问题：
  - `probe_all_sessions_json()` 先把完整文本输出存进 shell 变量，再通过 `python3 - "$probe_output"` 作为单个命令行参数传递。
  - `status_json_from_text()` 也用了同样的模式。
  - 这在小规模数据下没问题，但随着 session / loop 数量增长，会把协议上限绑定到操作系统的命令行长度限制。
- 风险：
  - `probe-all --json` 或 `status --json` 会在规模变大后无预警失败，且失败点离真实数据生成点很远，排查困难。
  - UI 当前分批调用 `probe-all --json`，风险被部分缓解；但 CLI 路径仍然脆弱。
- 建议：
  - 改为通过 stdin 传递文本，或直接让上游命令原生输出 JSON。
  - 如果必须经 shell 变量中转，也应在进入 Python 前做长度保护并给出明确错误。
- 测试缺口：
  - 没有任何规模测试覆盖“几百个 session / 大量 loop 状态”的 JSON 转换路径。

### 10. Low: loop/state 数据文件通过 `source` 解释执行，数据层和代码层边界过于脆弱

- 文件/位置：
  - `codex_terminal_sender.sh:172-176`
  - 主要调用点：
    - `codex_terminal_sender.sh:227`
    - `codex_terminal_sender.sh:300`
    - `codex_terminal_sender.sh:329`
    - `codex_terminal_sender.sh:373`
    - `codex_terminal_sender.sh:2989`
    - `codex_terminal_sender.sh:3266`
    - `codex_terminal_sender.sh:3320`
    - `codex_terminal_sender.sh:3339`
    - `codex_terminal_sender.sh:3443`
- 问题：
  - `.loop` 和 `.state` 文件本质上是数据文件，但当前是通过 `source "$file"` 直接执行。
  - 这意味着一旦文件被损坏、手工误改，或者被导入了不可信内容，helper 在读取状态时会执行其中的 shell 片段。
- 风险：
  - 从严格意义上说，这是把数据文件当成代码执行，安全边界非常弱。
  - 即使只考虑同一用户上下文，这也会放大状态损坏的破坏范围，让“修复数据”变成“执行任意 shell”。
- 建议：
  - 把 loop/state 改成 JSON 或最简单的显式 key/value 解析器。
  - 如果短期仍保留 shell 格式，至少先校验 `^[A-Z0-9_]+=...$` 这类严格语法，再决定是否加载。
- 测试缺口：
  - 当前没有任何损坏文件、恶意内容或非法 key/value 的负面测试。

## Residual Risks

即使以上 findings 都成立，当前仍有一些无法完全消除的残余风险：

- `swift test` 目前被本机 Command Line Tools / `llbuild` 动态库损坏阻断，因此 SwiftPM 维度的验证结论仍然不完整。
- `tests/test_helper_smoke.sh` 在当前环境下未能在 40 秒内完成，说明默认检查链路的可靠性本身还需要额外观察。
- 项目中仍然有大量 macOS `Terminal.app`、`osascript`、`sips`、`xcrun`、BSD `stat` 假设；Linux 相关结论中，仍有一部分属于高置信度静态风险，而不是已在 Linux 实机上动态验证过的结果。
