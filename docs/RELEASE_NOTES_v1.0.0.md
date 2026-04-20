# v1.0.0 Release Notes

`Codex Taskmaster` 的首个正式版本。

## 这是什么

这是一个面向本地 Codex CLI 工作流的 macOS 工具，主要用来：

- 查看本机 Codex 会话状态
- 给指定会话发送消息
- 创建和管理循环发送任务
- 查看相关日志、失败原因和最近发送结果

## 本次发布包含

- 打包好的 macOS 应用：
  - `Codex-Taskmaster-v1.0.0-macos.zip`
- 对应校验文件：
  - `Codex-Taskmaster-v1.0.0-macos.zip.sha256`

## v1.0.0 重点

- 循环任务状态一致性已收口：
  - 修复了 stop/delete 与后台 loop worker 的竞态
  - 修复了 failed start 残留 orphan loop 的问题
  - 修复了 `loop-resume -k LOOP_ID`
- app 生命周期语义已收口：
  - 退出 app 不会隐式停止全部 loop
  - app 当前按单实例运行处理
- 会话名称行为已收口：
  - 清空 rename 会恢复为未 rename 状态

## 使用前请确认

- 你在 macOS 13 或更高版本上运行
- 你使用的是 `Terminal.app`
- 本地已安装 Codex CLI
- 如果需要自动粘贴并发送，请为 app 打开辅助功能权限

## 下载与启动

1. 下载 release 里的 `Codex-Taskmaster-v1.0.0-macos.zip`
2. 解压得到 `Codex Taskmaster.app`
3. 双击打开，或执行：

```bash
open "./Codex Taskmaster.app"
```

## 已知约束

- 当前仅支持 macOS
- 当前按单实例运行处理
- 退出 app 不会自动停止后台 loop；如需停止，请在界面中显式执行“停止全部”
