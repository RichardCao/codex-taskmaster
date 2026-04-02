# 改进任务队列

本文档用于跟踪当前确定要做的 8 个改进任务。

状态说明：

- `pending`：还未开始
- `in_progress`：当前正在做
- `done`：已完成并通过本轮验证

## 当前队列

1. `done` `tty_focus_failed` 分类与 live tty 自动重定位
   目标：把 Terminal 聚焦失败从普通发送中断里单独分离，并在失败后自动重探当前 live tty 再重试一次。

2. `done` loop 熔断 / 暂停机制
   目标：连续同类失败时暂停 loop，而不是长期无意义重试。

3. `pending` 自动重定位 live tty 的常态化兜底
   目标：不只在 focus fail 时触发，也要在 tty 失联等场景下主动刷新。

4. `pending` 发送结果可视化增强
   目标：把成功、已排队、待确认、TTY 失效、权限缺失等状态更明确地显示到 UI。

5. `pending` Session 详情区显示最近发送结果与失败统计
   目标：选中 session 后能直接看到近几次发送记录、失败原因和 loop 占用情况。

6. `pending` loop 发送频率保护与互斥增强
   目标：避免 force 模式或异常状态下高频重复发送。

7. `pending` 日志查看能力增强
   目标：支持按 target / session 过滤，只看失败，导出单条 session 相关日志。

8. `pending` 平台发送层继续抽象
   目标：把平台相关发送能力从 macOS UI 里进一步剥离，为 Linux 适配打基础。
