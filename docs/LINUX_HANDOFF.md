# Linux 开发交接清单

本文档只回答一个问题：

把当前项目迁移到 Linux 开发时，应该带哪些内容过去。

## 建议直接复制到 Linux 的内容

最简单、最稳妥的做法：

- 直接复制整个 Git 仓库

原因：

- 文档、脚本、测试、helper 都要参考
- `git history` 对迁移阶段排错有帮助
- 当前仓库已经通过 `.gitignore` 排除了主要生成产物

如果不方便整仓复制，至少要带下面这些文件。

## 最少必带文件

### 核心逻辑参考

- [codex_terminal_sender.sh](/Users/create/codex-terminal-app/codex_terminal_sender.sh)
- [CodeTaskMasterApp.swift](/Users/create/codex-terminal-app/CodeTaskMasterApp.swift)

说明：

- 前者是 helper / loop / session 操作的主要参考实现
- 后者虽然是 macOS UI，但里面有大量 session 解析、状态映射、结果解释逻辑
- 最近还补了 6 个和 Linux 迁移语义相关的点：
  - 发送结果新增“已受理待确认”中间态
  - 发送后焦点恢复
  - 避免发送链路卡住 UI 主线程
  - 发送前后恢复剪贴板，避免污染用户环境
  - 同一真实 Session 的 loop 互斥与保守重试退避
  - Activity Log 的失败过滤、按当前 Session 过滤、单 Session 导出

### 构建与测试参考

- [scripts/check.sh](/Users/create/codex-terminal-app/scripts/check.sh)
- [scripts/regression_check.sh](/Users/create/codex-terminal-app/scripts/regression_check.sh)
- [tests/test_helper_smoke.sh](/Users/create/codex-terminal-app/tests/test_helper_smoke.sh)

### 文档

- [README.md](/Users/create/codex-terminal-app/README.md)
- [docs/ARCHITECTURE.md](/Users/create/codex-terminal-app/docs/ARCHITECTURE.md)
- [docs/LINUX_PORTING.md](/Users/create/codex-terminal-app/docs/LINUX_PORTING.md)
- [docs/PLATFORM_API.md](/Users/create/codex-terminal-app/docs/PLATFORM_API.md)
- [docs/LINUX_HANDOFF.md](/Users/create/codex-terminal-app/docs/LINUX_HANDOFF.md)

### 许可证与仓库元信息

- [LICENSE](/Users/create/codex-terminal-app/LICENSE)
- [.github/workflows/ci.yml](/Users/create/codex-terminal-app/.github/workflows/ci.yml)

## 不必带去 Linux 的内容

下面这些是 macOS 构建或产物，不是 Linux 迁移首要材料。

- `Code TaskMaster.app`
- `CodeTaskMaster-1024.png`
- `CodeTaskMaster.iconset/`
- [build_code_taskmaster_app.sh](/Users/create/codex-terminal-app/build_code_taskmaster_app.sh)
- [generate_icon.swift](/Users/create/codex-terminal-app/generate_icon.swift)
- [scripts/ui_smoke_test.sh](/Users/create/codex-terminal-app/scripts/ui_smoke_test.sh)

这些可以保留在仓库里，但 Linux 侧不用围绕它们开发。

## Linux 端第一批应该新建的文件

建议到 Linux 后优先新增：

```text
platform/linux/
  tmux_adapter.sh
  probe_tmux_target.py

scripts/
  check_linux.sh
  smoke_linux_send.sh
```

如果继续用 shell 为主，这个结构就够开始了。

## Linux 端建议安装的依赖

最小建议：

- `bash`
- `python3`
- `sqlite3`
- `node`
- `tmux`
- `git`
- `codex`

可选：

- `jq`
- `ripgrep`

## Linux 端启动开发前的确认项

先确认：

1. Linux 上 `codex` 已可正常运行
2. `~/.codex` 目录存在
3. session / rollout / logs 数据结构与当前 macOS 上兼容
4. 目标环境里有 `tmux`
5. 你打算优先支持的发送宿主就是 `tmux`

## Linux 端的第一批开发任务

建议按这个顺序做：

1. 复刻 `thread-list` / `probe-all` 能力
2. 复刻 rename / archive / unarchive / delete
3. 实现 `tmux` target 解析
4. 实现 `tmux` 单次发送
5. 实现发送后验证和“已受理待确认”语义
6. 接回 loop daemon，并保留“同一 Session 同时只允许一个运行态 loop”的约束

## 交接建议

如果你要切到 Linux 机器上继续用 Codex 开发，最推荐的传输方式是：

1. 直接把整个仓库推到 GitHub
2. 在 Linux 上 `git clone`
3. 以 `docs/LINUX_PORTING.md` 和 `docs/PLATFORM_API.md` 为开发入口
4. 先无视 macOS `.app` 构建链路
