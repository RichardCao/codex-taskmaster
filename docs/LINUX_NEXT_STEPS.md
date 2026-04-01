# Linux 下一步

这份文档只写“接下来怎么做”，不展开解释。

## 现在就做什么

1. 把整个仓库带到 Linux
2. 在 Linux 上安装依赖
3. 先不要尝试构建 macOS App
4. 先实现 CLI 和 `tmux` 发送链路

## 建议带到 Linux 的方式

优先做法：

1. 推到 GitHub
2. 在 Linux 上 `git clone`

不要只复制零散脚本，容易漏文档和测试。

## Linux 上先安装这些

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

## 开发顺序

第一阶段只做这 6 件事：

1. 复刻 `thread-list`
2. 复刻 `probe-all`
3. 复刻 `rename / archive / unarchive / delete`
4. 做 `tmux` target 解析
5. 做 `tmux` 单次发送
6. 接回 loop daemon

## 第一版范围

第一版目标：

- 能列出 session
- 能看状态
- 能改名 / 归档 / 恢复 / 删除
- 能向 `tmux` 中的 Codex session 发送
- 能开始和停止循环

第一版不要做：

- Linux GUI
- GNOME Terminal / Konsole / Alacritty 兼容
- 图标和打包
- 和 macOS UI 一致

## 开发入口

先读这几份文档：

- [docs/LINUX_PORTING.md](/Users/create/codex-terminal-app/docs/LINUX_PORTING.md)
- [docs/PLATFORM_API.md](/Users/create/codex-terminal-app/docs/PLATFORM_API.md)
- [docs/LINUX_HANDOFF.md](/Users/create/codex-terminal-app/docs/LINUX_HANDOFF.md)

## 到 Linux 后建议先新建

```text
platform/linux/
  tmux_adapter.sh
  probe_tmux_target.py

scripts/
  check_linux.sh
  smoke_linux_send.sh
```

## 判断是否走在正确方向上

如果你在 Linux 上的第一周工作里，主要在做下面这些事，方向就是对的：

- 读 `~/.codex`
- 解析 session
- 调 `tmux list-panes`
- 调 `tmux capture-pane`
- 调 `tmux send-keys`
- 验证发送后是否真的推进

如果你主要在做下面这些事，说明顺序错了：

- 设计 Linux GUI
- 改图标
- 研究桌面自动化
- 兼容多个 Linux 终端
