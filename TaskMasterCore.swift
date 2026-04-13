import Foundation

struct LoopSnapshot {
    let target: String
    let loopDaemonRunning: String
    let intervalSeconds: String
    let forceSend: String
    let message: String
    let nextRunEpoch: String
    let stopped: String
    let stoppedReason: String
    let paused: String
    let failureCount: String
    let failureReason: String
    let pauseReason: String
    let logPath: String
    let lastLogLine: String
}

struct SessionSnapshot {
    let name: String
    let target: String
    let threadID: String
    let provider: String
    let source: String
    let parentThreadID: String
    let agentNickname: String
    let agentRole: String
    let status: String
    let reason: String
    let terminalState: String
    let tty: String
    let updatedAtEpoch: String
    let rolloutPath: String
    let preview: String
    let isArchived: Bool
}

struct SendResultSnapshot {
    let target: String
    let status: String
    let reason: String
    let forceSend: Bool
    let detail: String
    let probeStatus: String
    let terminalState: String
    let updatedAtEpoch: TimeInterval
}

func sessionActualName(_ session: SessionSnapshot) -> String {
    session.name.trimmingCharacters(in: .whitespacesAndNewlines)
}

func sessionEffectiveTarget(_ session: SessionSnapshot) -> String {
    let target = session.target.trimmingCharacters(in: .whitespacesAndNewlines)
    return target.isEmpty ? session.threadID : target
}

func sessionPossibleTargets(_ session: SessionSnapshot) -> [String] {
    var ordered: [String] = []

    func append(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !ordered.contains(trimmed) else { return }
        ordered.append(trimmed)
    }

    append(session.threadID)
    append(sessionActualName(session))
    append(sessionEffectiveTarget(session))
    append(session.preview)
    return ordered
}

func sessionTypeLabel(_ session: SessionSnapshot) -> String {
    let source = session.source.trimmingCharacters(in: .whitespacesAndNewlines)
    if source == "cli" {
        return "CLI"
    }
    if source == "exec" {
        return "Exec"
    }
    if source.contains("\"subagent\"") {
        return "Subagent"
    }
    return source.isEmpty ? "Other" : "Other"
}

func sessionIsCLIPrimary(_ session: SessionSnapshot) -> Bool {
    sessionTypeLabel(session) == "CLI"
}

func parentThreadIDFromSource(_ source: String) -> String {
    guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let data = source.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let subagent = object["subagent"] as? [String: Any],
          let spawn = subagent["thread_spawn"] as? [String: Any],
          let parentThreadID = spawn["parent_thread_id"] as? String else {
        return ""
    }
    return parentThreadID
}

func parseThreadRuntimeStatus(_ raw: Any?) -> String {
    guard let object = raw as? [String: Any],
          let type = object["type"] as? String else {
        return "unknown"
    }
    if type == "active",
       let flags = object["activeFlags"] as? [String],
       !flags.isEmpty {
        return "active(\(flags.joined(separator: ",")))"
    }
    return type
}

func parseProbeAllOutput(_ output: String) -> [SessionSnapshot] {
    var sessions: [SessionSnapshot] = []
    var current: [String: String] = [:]

    func flushCurrent() {
        guard let threadID = current["thread_id"] else {
            current.removeAll()
            return
        }
        sessions.append(
            SessionSnapshot(
                name: current["name"] ?? "",
                target: current["target"] ?? threadID,
                threadID: threadID,
                provider: current["provider"] ?? "",
                source: current["source"] ?? "",
                parentThreadID: current["parent_thread_id"] ?? "",
                agentNickname: current["agent_nickname"] ?? "",
                agentRole: current["agent_role"] ?? "",
                status: current["status"] ?? "unknown",
                reason: current["reason"] ?? "",
                terminalState: current["terminal_state"] ?? "unavailable",
                tty: current["tty"] ?? "",
                updatedAtEpoch: current["updated_at_epoch"] ?? "0",
                rolloutPath: current["rollout_path"] ?? "",
                preview: "",
                isArchived: false
            )
        )
        current.removeAll()
    }

    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty {
            continue
        }
        if line == "---" {
            flushCurrent()
            continue
        }
        if let range = line.range(of: ": ") {
            let key = String(line[..<range.lowerBound])
            let value = String(line[range.upperBound...])
            current[key] = value
        }
    }

    flushCurrent()
    return sessions
}

func parseThreadListOutput(_ output: String, archived: Bool) -> [SessionSnapshot] {
    guard let data = output.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = object["data"] as? [[String: Any]] else {
        return []
    }

    return items.compactMap { item in
        guard let threadID = item["id"] as? String else {
            return nil
        }

        let updatedAtValue = item["updatedAt"]
        let updatedAtEpoch: String
        if let intValue = updatedAtValue as? Int {
            updatedAtEpoch = String(intValue)
        } else if let doubleValue = updatedAtValue as? Double {
            updatedAtEpoch = String(Int(doubleValue))
        } else if let stringValue = updatedAtValue as? String {
            updatedAtEpoch = stringValue
        } else {
            updatedAtEpoch = "0"
        }

        let source = item["source"] as? String ?? ""
        return SessionSnapshot(
            name: item["name"] as? String ?? "",
            target: threadID,
            threadID: threadID,
            provider: item["modelProvider"] as? String ?? item["model_provider"] as? String ?? "",
            source: source,
            parentThreadID: item["parentThreadId"] as? String ?? item["parent_thread_id"] as? String ?? parentThreadIDFromSource(source),
            agentNickname: item["agentNickname"] as? String ?? item["agent_nickname"] as? String ?? "",
            agentRole: item["agentRole"] as? String ?? item["agent_role"] as? String ?? "",
            status: archived ? "archived" : parseThreadRuntimeStatus(item["status"]),
            reason: archived ? "session is archived and can be restored" : "",
            terminalState: archived ? "archived" : "unavailable",
            tty: "",
            updatedAtEpoch: updatedAtEpoch,
            rolloutPath: item["path"] as? String ?? "",
            preview: item["preview"] as? String ?? "",
            isArchived: archived
        )
    }
}

func mergeSessionSnapshots(existing: [SessionSnapshot], newSnapshots: [SessionSnapshot]) -> [SessionSnapshot] {
    guard !newSnapshots.isEmpty else { return existing }

    var mergedByID: [String: SessionSnapshot] = [:]
    for snapshot in existing {
        mergedByID[snapshot.threadID] = snapshot
    }
    for snapshot in newSnapshots {
        mergedByID[snapshot.threadID] = snapshot
    }

    return mergedByID.values.sorted { lhs, rhs in
        let lhsEpoch = TimeInterval(lhs.updatedAtEpoch) ?? 0
        let rhsEpoch = TimeInterval(rhs.updatedAtEpoch) ?? 0
        if lhsEpoch == rhsEpoch {
            return lhs.threadID < rhs.threadID
        }
        return lhsEpoch > rhsEpoch
    }
}

func localizedSessionStatusLabel(_ session: SessionSnapshot) -> String {
    if session.isArchived {
        return "已归档"
    }
    if session.terminalState == "unavailable" && shouldCollapseUnavailableTerminalIntoDisconnectedStatus(session) {
        return "断联"
    }

    switch session.status {
    case let status where status.hasPrefix("active"):
        return "运行中"
    case "idle_stable":
        return "空闲"
    case "interrupted_idle":
        return "中断后空闲"
    case "idle_with_residual_input":
        return "残留输入"
    case "busy_turn_open":
        return "运行中"
    case "post_finalizing":
        return "状态收尾"
    case "busy_with_stream_issue":
        return "流异常"
    case "interrupted_or_aborting":
        return "中断中"
    case "idle_prompt_visible_rollout_stale":
        return "状态滞后"
    case "queued_messages_visible", "queued_messages_pending":
        return "消息排队"
    case "unknown":
        return "未知"
    default:
        return session.status
    }
}

func shouldCollapseUnavailableTerminalIntoDisconnectedStatus(_ session: SessionSnapshot) -> Bool {
    guard session.terminalState == "unavailable" else { return false }
    switch session.status {
    case let status where status.hasPrefix("active"):
        return false
    case "busy_turn_open", "post_finalizing", "busy_with_stream_issue", "interrupted_or_aborting":
        return false
    default:
        return true
    }
}

func localizedTerminalState(_ state: String) -> String {
    switch state {
    case "prompt_ready":
        return "可发送"
    case "prompt_with_input":
        return "有残留输入"
    case "queued_messages_pending":
        return "消息排队中"
    case "no_visible_prompt":
        return "未见提示符"
    case "busy":
        return "忙碌"
    case "unavailable":
        return "不可达"
    case "archived":
        return "已归档"
    default:
        return state
    }
}

func localizedSessionReason(_ reason: String) -> String {
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    let exactMappings: [String: String] = [
        "session is archived and can be restored": "该 session 已归档，可在当前列表中恢复",
        "insufficient local events": "本地事件不足，暂时无法可靠判断状态",
        "last completed turn is newer than the last started turn": "最近一次完成回合晚于最近一次开始回合，当前看起来已空闲",
        "a started turn has no later task_complete": "检测到已开始的回合，但后面没有看到 task_complete，当前可能仍在执行",
        "final answer emitted but task_complete not seen yet": "已经看到最终回答，但还没有看到 task_complete，可能仍在收尾",
        "open turn with a recent interrupt log": "当前回合未闭合，且最近有中断日志",
        "open turn with recent stream disconnect warnings": "当前回合未闭合，且最近有流断开告警",
        "a newer turn_aborted event is present and terminal is ready again": "检测到更新的 turn_aborted，且 Terminal 已恢复到可输入状态",
        "a newer turn_aborted event is present": "检测到更新的 turn_aborted 事件",
        "turn is complete, but terminal still shows unsent input": "回合已完成，但 Terminal 输入框里仍残留未发送内容",
        "turn is complete, but queued messages are still visible in Terminal": "回合已完成，但 Terminal 里仍能看到排队中的消息",
        "message appears queued in terminal but no fresh acknowledgment was observed yet": "消息看起来已经进入终端排队区，但暂时还没有看到新的确认反馈",
        "terminal is back at a ready prompt while rollout still looks open": "Terminal 已回到可输入提示，但 rollout 记录看起来仍未闭合",
        "terminal is ready and a fresh interrupt log was recorded": "Terminal 已恢复可输入，且最近记录到新的中断日志",
        "tty not found": "未找到对应的终端 TTY",
        "prompt/footer not visible in terminal tail": "终端尾部没有看到明确的提示符或底栏",
        "queued messages are visible in the terminal tail": "终端尾部能看到排队中的消息",
        "placeholder prompt and model footer are visible": "终端中能看到占位提示符和模型底栏",
        "prompt line and model footer are visible with non-placeholder input": "终端中能看到带实际输入内容的提示符和模型底栏",
        "model footer is visible without a clear prompt line": "只能看到模型底栏，没有看到清晰的提示符行"
    ]

    if let mapped = exactMappings[trimmed] {
        return mapped
    }
    if trimmed.hasPrefix("osascript failed:") {
        let prefix = "osascript failed:"
        let detail = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return "读取 Terminal 状态失败: \(detail)"
    }
    return trimmed
}
