# 当前临时任务队列

状态说明：

- `pending`：未开始
- `in_progress`：正在执行
- `done`：已完成并验证

执行规则：

- 按顺序逐项推进
- 每个切片都执行 `.app` 构建与启动验证
- 每个切片保留独立 commit
- 不等待额外确认，直接推进到当前队列完成

## 当前队列

1. `done` Terminal probe 后台 tab 误判修复
   目标：修复 `probe` 只读取 `selected tab` 的问题，避免后台 tab 被误判为 `unavailable` 并阻断默认发送。

2. `done` live-only target 解析排除 archived session
   目标：让 `send`、`start`、`probe`、`resolve-live-tty` 等 live-only 路径默认只命中 `archived = 0` 的 session。

3. `done` delete allowlist 与自定义 Codex 根目录对齐
   目标：让 `thread-delete` / `thread-delete-plan` 的 rollout allowlist 根目录从实际配置推导，不再硬编码 `~/.codex/...`。

4. `done` `Package.swift` 测试路径大小写修复
   目标：修正 SwiftPM test target 路径大小写问题，清除 Linux / case-sensitive 文件系统上的直接阻断点。

5. `done` 默认检查链路补齐核心回归
   目标：把 `test_taskmaster_core.sh`、`test_loop_history_model.sh` 与可选 `swift test` 策略纳入默认或严格检查链路，避免误导性绿灯。

6. `done` loop `STATE_TAG` 平台无关化
   目标：替换 BSD `stat -f '%m:%z'` 依赖，改用跨平台实现，为 Linux 迁移扫清明确阻断点。

7. `done` loop daemon 实例隔离
   目标：让 daemon 生命周期至少绑定到 `STATE_DIR` 或实例 id，避免多个隔离实例互相踩踏。

8. `done` loop 调度去全局串行阻塞
   目标：拆开“扫描到期 loop”和“执行单次发送”，避免一个慢 target 拖住所有其他 loop。

9. `done` `probe-all --json` / `status --json` 去除 `ARG_MAX` 脆弱点
   目标：避免把大文本结果塞进单个 argv，改成 stdin 或原生 JSON 流。

10. `done` loop/state 数据文件执行边界收紧
   目标：减少 `source` 直接执行数据文件的风险，至少先把读取边界校验收紧，再评估后续 JSON 化迁移。

11. `done` `CodexTaskmasterApp.swift` 继续瘦身
   目标：继续把展示编排、状态回写和 helper 调用细节从 UI 控制器下沉到 core/service。

12. `done` merge / refresh / fallback 规则继续收口
   目标：把刷新后保留旧字段、快照合并和回退语义进一步从 UI 中移出，避免控制器继续膨胀。

13. `done` 默认与严格检查链路文档同步
   目标：把实际验证入口、默认检查覆盖范围、严格检查覆盖范围同步到文档，避免后续使用者误判。

14. `done` loop worker 与 stop/delete 竞态修复
   目标：避免用户已停止或删除 loop 后，在途 worker 仍把状态写回并“复活” loop。

15. `in_progress` failed start orphan loop 清理
   目标：避免 `start` 失败后同时留下 stopped history 和一条假活跃 orphan loop。

16. `pending` `loop-resume -k LOOP_ID` 修复
   目标：恢复时优先使用 loop 文件内的 target，而不是错误解析空 target。

17. `pending` app 退出是否默认 stop all 语义收口
   目标：明确并实现“关闭窗口/退出 app 是否应停止全部 loop”的产品契约。

18. `pending` 多实例运行语义收口
   目标：明确是否允许多开；若允许，补跨进程请求队列与 Terminal 自动化互斥。

19. `pending` 清空 rename 的文档/实现一致性修复
   目标：补回 empty rename fallback，或收正文档与 UI 语义。
