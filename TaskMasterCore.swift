import Darwin
import Foundation

struct SubprocessResult {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String
    let didTimeOut: Bool

    var trimmedStdout: String {
        stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedStderr: String {
        stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SubprocessRunnerError: LocalizedError {
    case launchFailed(String)
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            return "启动失败: \(message)"
        case let .timedOut(seconds):
            return "执行超时: \(Int(seconds.rounded())) 秒"
        }
    }
}

enum SubprocessRunner {
    static func run(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        standardInputData: Data? = nil,
        timeout: TimeInterval? = nil,
        onProcessStarted: ((Process) -> Void)? = nil,
        onProcessFinished: ((Process) -> Void)? = nil
    ) throws -> SubprocessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let readGroup = DispatchGroup()
        let bufferLock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()

        func installReader(for handle: FileHandle, append: @escaping (Data) -> Void) {
            readGroup.enter()
            handle.readabilityHandler = { readableHandle in
                let chunk = readableHandle.availableData
                if chunk.isEmpty {
                    readableHandle.readabilityHandler = nil
                    readGroup.leave()
                    return
                }
                append(chunk)
            }
        }

        installReader(for: stdoutHandle) { chunk in
            bufferLock.lock()
            stdoutData.append(chunk)
            bufferLock.unlock()
        }

        installReader(for: stderrHandle) { chunk in
            bufferLock.lock()
            stderrData.append(chunk)
            bufferLock.unlock()
        }

        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdinHandle: FileHandle?
        if standardInputData != nil {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            stdinHandle = stdinPipe.fileHandleForWriting
        }

        let terminationSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminationSemaphore.signal()
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            throw SubprocessRunnerError.launchFailed(error.localizedDescription)
        }

        onProcessStarted?(process)

        if let standardInputData, let stdinHandle {
            stdinHandle.write(standardInputData)
            try? stdinHandle.close()
        }

        let didTimeOut: Bool
        if let timeout {
            let waitResult = terminationSemaphore.wait(timeout: .now() + timeout)
            didTimeOut = waitResult == .timedOut
            if didTimeOut {
                if process.isRunning {
                    process.terminate()
                    if terminationSemaphore.wait(timeout: .now() + 0.5) == .timedOut, process.processIdentifier > 0 {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                        _ = terminationSemaphore.wait(timeout: .now() + 0.5)
                    }
                }
            }
        } else {
            terminationSemaphore.wait()
            didTimeOut = false
        }

        onProcessFinished?(process)

        if readGroup.wait(timeout: .now() + 1) == .timedOut {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
        }

        let stdoutText = String(decoding: stdoutData, as: UTF8.self)
        let stderrText = String(decoding: stderrData, as: UTF8.self)

        if didTimeOut {
            throw SubprocessRunnerError.timedOut(timeout ?? 0)
        }

        return SubprocessResult(
            terminationStatus: process.terminationStatus,
            stdout: stdoutText,
            stderr: stderrText,
            didTimeOut: false
        )
    }
}

struct HelperCommandResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var combinedText: String {
        [stdout, stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

final class HelperCommandService {
    private let helperURL: URL

    init(helperPath: String) {
        self.helperURL = URL(fileURLWithPath: helperPath)
    }

    func run(
        arguments: [String],
        onProcessStarted: ((Process) -> Void)? = nil,
        onProcessFinished: ((Process) -> Void)? = nil
    ) -> HelperCommandResult {
        do {
            let result = try SubprocessRunner.run(
                executableURL: helperURL,
                arguments: arguments,
                onProcessStarted: onProcessStarted,
                onProcessFinished: onProcessFinished
            )
            return HelperCommandResult(
                status: result.terminationStatus,
                stdout: result.trimmedStdout,
                stderr: result.trimmedStderr
            )
        } catch {
            return HelperCommandResult(
                status: 1,
                stdout: "",
                stderr: "启动失败: \(error.localizedDescription)"
            )
        }
    }

    func runAsync(
        arguments: [String],
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping (HelperCommandResult) -> Void
    ) {
        DispatchQueue.global(qos: qos).async {
            let result = self.run(arguments: arguments)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}

final class SessionCommandService {
    private let helperService: HelperCommandService

    init(helperService: HelperCommandService) {
        self.helperService = helperService
    }

    func configuredModelProviderAsync(
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping (String?) -> Void
    ) {
        helperService.runAsync(arguments: ["config-model-provider"], qos: qos) { result in
            guard result.status == 0,
                  let fields = parseStructuredKeyValueFields(result.stdout),
                  let modelProvider = fields["model_provider"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !modelProvider.isEmpty else {
                completion(nil)
                return
            }
            completion(modelProvider)
        }
    }

    func sessionProviderPlanAsync(
        threadID: String,
        targetProvider: String,
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping ([String: String]?) -> Void
    ) {
        helperService.runAsync(arguments: ["thread-provider-plan", "-t", threadID, "-p", targetProvider], qos: qos) { result in
            guard result.status == 0 else {
                completion(nil)
                return
            }
            completion(parseStructuredKeyValueFields(result.stdout))
        }
    }

    func allSessionProviderPlanAsync(
        targetProvider: String,
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping ([String: String]?) -> Void
    ) {
        helperService.runAsync(arguments: ["thread-provider-plan-all", "-p", targetProvider], qos: qos) { result in
            guard result.status == 0 else {
                completion(nil)
                return
            }
            completion(parseStructuredKeyValueFields(result.stdout))
        }
    }

    func migrateSessionProvider(threadID: String, targetProvider: String, includeFamily: Bool) -> (success: Bool, detail: String) {
        var arguments = ["thread-provider-migrate", "-t", threadID, "-p", targetProvider]
        if includeFamily {
            arguments.append("--family")
        }
        let result = helperService.run(arguments: arguments)
        if result.status == 0 {
            return (true, result.stdout)
        }
        return (false, [result.stderr, result.stdout].first { !$0.isEmpty } ?? "迁移 provider 失败")
    }

    func migrateAllSessionsProvider(targetProvider: String) -> (success: Bool, detail: String) {
        let result = helperService.run(arguments: ["thread-provider-migrate-all", "-p", targetProvider])
        if result.status == 0 {
            return (true, result.stdout)
        }
        return (false, [result.stderr, result.stdout].first { !$0.isEmpty } ?? "迁移全部 session provider 失败")
    }

    func updateSessionName(threadID: String, newName: String) -> (success: Bool, error: String) {
        let result = helperService.run(arguments: ["thread-name-set", "-t", threadID, "-n", newName])
        if result.status == 0 {
            return (true, "")
        }
        let detail = [result.stderr, result.stdout].first { !$0.isEmpty } ?? (newName.isEmpty ? "清空名称失败" : "重命名失败")
        return (false, detail)
    }

    func archiveSession(threadID: String) -> (success: Bool, error: String) {
        let result = helperService.run(arguments: ["thread-archive", "-t", threadID])
        if result.status == 0 {
            return (true, "")
        }
        let detail = [result.stderr, result.stdout].first { !$0.isEmpty } ?? "归档 session 失败"
        return (false, detail)
    }

    func unarchiveSession(threadID: String) -> (success: Bool, error: String) {
        let result = helperService.run(arguments: ["thread-unarchive", "-t", threadID])
        if result.status == 0 {
            return (true, "")
        }
        let detail = [result.stderr, result.stdout].first { !$0.isEmpty } ?? "恢复归档失败"
        return (false, detail)
    }

    func deleteSession(threadID: String) -> (success: Bool, fields: [String: String]?, detail: String) {
        let result = helperService.run(arguments: ["thread-delete", "-t", threadID])
        let combinedText = result.combinedText
        let fields = parseStructuredKeyValueFields(combinedText)
        if result.status == 0 {
            return (true, fields, result.stdout)
        }
        return (false, fields, combinedText.isEmpty ? "彻底删除失败" : combinedText)
    }

    func sessionDeletePlanAsync(
        threadID: String,
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping ([String: String]?) -> Void
    ) {
        helperService.runAsync(arguments: ["thread-delete-plan", "-t", threadID], qos: qos) { result in
            guard result.status == 0 else {
                completion(nil)
                return
            }
            completion(parseStructuredKeyValueFields(result.stdout))
        }
    }

    func sessionFamilyPlanAsync(
        threadID: String,
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping ([String: String]?) -> Void
    ) {
        helperService.runAsync(arguments: ["thread-family-plan", "-t", threadID], qos: qos) { result in
            guard result.status == 0 else {
                completion(nil)
                return
            }
            completion(parseStructuredKeyValueFields(result.stdout))
        }
    }
}

final class LoopCommandService {
    private let helperService: HelperCommandService

    init(helperService: HelperCommandService) {
        self.helperService = helperService
    }

    func saveStoppedLoopEntry(target: String, interval: String, message: String, forceSend: Bool, reason: String) -> Bool {
        var arguments = ["loop-save-stopped", "-t", target, "-i", interval, "-m", message, "-r", reason]
        if forceSend {
            arguments.append("-f")
        }
        let result = helperService.run(arguments: arguments)
        return result.status == 0
    }

    func saveStoppedLoopEntryAsync(
        target: String,
        interval: String,
        message: String,
        forceSend: Bool,
        reason: String,
        qos: DispatchQoS.QoSClass = .utility,
        completion: ((Bool) -> Void)? = nil
    ) {
        helperService.runAsync(
            arguments: {
                var arguments = ["loop-save-stopped", "-t", target, "-i", interval, "-m", message, "-r", reason]
                if forceSend {
                    arguments.append("-f")
                }
                return arguments
            }(),
            qos: qos
        ) { result in
            completion?(result.status == 0)
        }
    }

    func validateUniqueTargetAsync(
        target: String,
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping (HelperCommandResult) -> Void
    ) {
        helperService.runAsync(arguments: ["resolve-thread-id", "-t", target], qos: qos, completion: completion)
    }

    func loopStatusAsync(
        qos: DispatchQoS.QoSClass = .utility,
        completion: @escaping ((loops: [LoopSnapshot], warnings: [String])?, String?) -> Void
    ) {
        helperService.runAsync(arguments: ["status", "--json"], qos: qos) { result in
            guard result.status == 0 else {
                completion(nil, result.stderr.isEmpty ? "Failed to load active loops." : result.stderr)
                return
            }
            guard let decoded = parseLoopStatusJSONOutput(result.stdout) else {
                completion(nil, "Failed to decode active loops.")
                return
            }
            completion((decoded.loops, decoded.warnings), nil)
        }
    }

    func runCommand(arguments: [String]) -> HelperCommandResult {
        helperService.run(arguments: arguments)
    }

    func runCommandAsync(
        arguments: [String],
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping (HelperCommandResult) -> Void
    ) {
        helperService.runAsync(arguments: arguments, qos: qos, completion: completion)
    }
}

func parseStructuredKeyValueFields(_ text: String, requireStatusAndReason: Bool = true) -> [String: String]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var fields: [String: String] = [:]
    for rawLine in trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = line.range(of: ": ") else { continue }
        let key = String(line[..<range.lowerBound])
        let value = String(line[range.upperBound...])
        fields[key] = value
    }

    if requireStatusAndReason,
       (fields["status"] == nil || fields["reason"] == nil) {
        return nil
    }

    return fields.isEmpty ? nil : fields
}

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

func parseLoopStatusJSONOutput(_ output: String) -> (loops: [LoopSnapshot], warnings: [String])? {
    guard let data = output.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }

    let warnings = (object["warnings"] as? [String]) ?? []
    let loopObjects = (object["loops"] as? [[String: Any]]) ?? []
    let loops = loopObjects.compactMap { item -> LoopSnapshot? in
        guard let target = item["target"] as? String else {
            return nil
        }

        return LoopSnapshot(
            target: target,
            loopDaemonRunning: item["loop_daemon_running"] as? String ?? "unknown",
            intervalSeconds: item["interval_seconds"] as? String ?? "unknown",
            forceSend: item["force_send"] as? String ?? "no",
            message: item["message"] as? String ?? "unknown",
            nextRunEpoch: item["next_run_epoch"] as? String ?? "unknown",
            stopped: item["stopped"] as? String ?? "no",
            stoppedReason: item["stopped_reason"] as? String ?? "",
            paused: item["paused"] as? String ?? "no",
            failureCount: item["failure_count"] as? String ?? "0",
            failureReason: item["failure_reason"] as? String ?? "",
            pauseReason: item["pause_reason"] as? String ?? "",
            logPath: item["log"] as? String ?? "-",
            lastLogLine: item["last_log_line"] as? String ?? ""
        )
    }

    return (loops, warnings)
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

func parseProbeAllJSONOutput(_ output: String, archived: Bool = false) -> [SessionSnapshot] {
    guard let data = output.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = object["sessions"] as? [[String: Any]] else {
        return []
    }

    return items.compactMap { item in
        guard let threadID = item["thread_id"] as? String else {
            return nil
        }

        return SessionSnapshot(
            name: item["name"] as? String ?? "",
            target: item["target"] as? String ?? threadID,
            threadID: threadID,
            provider: item["provider"] as? String ?? "",
            source: item["source"] as? String ?? "",
            parentThreadID: item["parent_thread_id"] as? String ?? "",
            agentNickname: item["agent_nickname"] as? String ?? "",
            agentRole: item["agent_role"] as? String ?? "",
            status: item["status"] as? String ?? "unknown",
            reason: item["reason"] as? String ?? "",
            terminalState: item["terminal_state"] as? String ?? "unavailable",
            tty: item["tty"] as? String ?? "",
            updatedAtEpoch: item["updated_at_epoch"] as? String ?? "0",
            rolloutPath: item["rollout_path"] as? String ?? "",
            preview: "",
            isArchived: archived
        )
    }
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

func localizedSendStatusLabel(_ status: String) -> String {
    switch status {
    case "success":
        return "成功"
    case "accepted":
        return "已受理"
    case "failed":
        return "失败"
    default:
        return status.isEmpty ? "-" : status
    }
}

func localizedSendReason(_ reason: String) -> String {
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    let mappings: [String: String] = [
        "sent": "已发送",
        "forced_sent": "强制发送成功",
        "queued_pending_feedback": "消息已排队",
        "verification_pending": "等待确认",
        "request_still_processing": "请求仍在处理",
        "request_already_inflight": "相同请求已在队列中",
        "ambiguous_target": "目标对应多个同名 Session",
        "tty_unavailable": "TTY 不可用",
        "tty_focus_failed": "TTY 聚焦失败",
        "terminal_focus_script_launch_failed": "Terminal 聚焦脚本启动失败",
        "keyboard_event_source_failed": "键盘事件源创建失败",
        "keyboard_event_creation_failed": "键盘事件创建失败",
        "probe_failed": "状态探测失败",
        "not_sendable": "当前状态不可发送",
        "send_interrupted": "发送过程被中断",
        "send_unverified": "发送后未看到确认",
        "send_unverified_after_tty_fallback": "TTY 回退后仍未确认",
        "invalid_request": "请求内容无效",
        "missing_accessibility_permission": "缺少辅助功能权限",
        "stopped_by_user": "已手动停止",
        "start_failed": "启动失败",
        "loop_conflict_active_session": "同一 Session 已有其他运行中的 Loop"
    ]

    return mappings[trimmed] ?? trimmed
}

func localizedLoopTerminalState(_ state: String) -> String {
    switch state.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase {
    case "prompt_ready":
        return "提示符就绪"
    case "prompt_with_input":
        return "提示符上有输入"
    case "queued_messages_pending":
        return "消息已排队待处理"
    case "no_visible_prompt":
        return "未看到可用提示符"
    case "busy":
        return "忙碌"
    case "unavailable":
        return "TTY 不可达"
    case "archived":
        return "已归档"
    case "unknown":
        return "未知"
    case "":
        return ""
    default:
        return state
    }
}
