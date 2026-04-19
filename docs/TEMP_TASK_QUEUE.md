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

5. `in_progress` 默认检查链路补齐核心回归
   目标：把 `test_taskmaster_core.sh`、`test_loop_history_model.sh` 与可选 `swift test` 策略纳入默认或严格检查链路，避免误导性绿灯。

6. `pending` loop `STATE_TAG` 平台无关化
   目标：替换 BSD `stat -f '%m:%z'` 依赖，改用跨平台实现，为 Linux 迁移扫清明确阻断点。

7. `pending` loop daemon 实例隔离
   目标：让 daemon 生命周期至少绑定到 `STATE_DIR` 或实例 id，避免多个隔离实例互相踩踏。

8. `pending` loop 调度去全局串行阻塞
   目标：拆开“扫描到期 loop”和“执行单次发送”，避免一个慢 target 拖住所有其他 loop。

9. `pending` `probe-all --json` / `status --json` 去除 `ARG_MAX` 脆弱点
   目标：避免把大文本结果塞进单个 argv，改成 stdin 或原生 JSON 流。

10. `pending` loop/state 数据文件执行边界收紧
   目标：减少 `source` 直接执行数据文件的风险，至少先把读取边界校验收紧，再评估后续 JSON 化迁移。

11. `pending` `CodexTaskmasterApp.swift` 继续瘦身
   目标：继续把展示编排、状态回写和 helper 调用细节从 UI 控制器下沉到 core/service。

12. `pending` merge / refresh / fallback 规则继续收口
   目标：把刷新后保留旧字段、快照合并和回退语义进一步从 UI 中移出，避免控制器继续膨胀。

13. `pending` 默认与严格检查链路文档同步
   目标：把实际验证入口、默认检查覆盖范围、严格检查覆盖范围同步到文档，避免后续使用者误判。
