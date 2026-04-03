# Linux 下一步

这份文档只写行动说明，不展开背景解释。

## 现在就做什么

1. 把整个仓库推到 GitHub
2. 在 Linux 上 `git clone`
3. 安装依赖
4. 先不碰 macOS `.app` 构建
5. 只做 CLI + `tmux` 发送链路

## Linux 上先安装

- `bash`
- `python3`
- `sqlite3`
- `node`
- `tmux`
- `git`
- `codex`
- 可选：`jq`
- 可选：`rg`

## 到 Linux 后先确认

1. `codex` 命令可用
2. `~/.codex` 存在
3. `tmux` 可用
4. 能在 `tmux` pane 里正常运行 `codex resume ...`

## 阅读顺序

1. [docs/ARCHITECTURE.md](/Users/create/codex-terminal-app/docs/ARCHITECTURE.md)
2. [docs/PLATFORM_API.md](/Users/create/codex-terminal-app/docs/PLATFORM_API.md)
3. [docs/LINUX_PORTING.md](/Users/create/codex-terminal-app/docs/LINUX_PORTING.md)
4. [docs/LINUX_HANDOFF.md](/Users/create/codex-terminal-app/docs/LINUX_HANDOFF.md)

## 第一阶段只做这 6 件事

1. 复刻 `thread-list`
2. 复刻 `probe-all`
3. 复刻 `rename / archive / unarchive / delete`
4. 做 `tmux` target 解析
5. 做 `tmux` 单次发送
6. 接回 loop daemon

## 先新建这些文件

```text
platform/linux/
  tmux_adapter.sh
  probe_tmux_target.py

scripts/
  check_linux.sh
  smoke_linux_send.sh
```

## 第一版必须达到

- 能列出 session
- 能看状态
- 能改名 / 归档 / 恢复 / 删除
- 能向 `tmux` 中的 Codex session 发送
- 能开始和停止循环
- 能区分“成功 / 已受理待确认 / 真失败”
- 能保证同一真实 Session 同一时刻只有一个运行态 loop

## 第一版不要做

- Linux GUI
- 多终端兼容
- 图标和打包
- 和 macOS UI 对齐

## 自查方向

如果第一周主要在做这些，方向是对的：

- 读 `~/.codex`
- 解析 session
- 调 `tmux list-panes`
- 调 `tmux capture-pane`
- 调 `tmux send-keys`
- 验证发送后是否真的推进
- 保持 loop 互斥与退避

如果主要在做这些，说明顺序错了：

- 设计 Linux GUI
- 改图标
- 研究桌面自动化
- 同时兼容多个 Linux 终端
