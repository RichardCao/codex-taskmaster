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

struct HelperCommandProcessCallbacks {
    let onProcessStarted: ((Process) -> Void)?
    let onProcessFinished: ((Process) -> Void)?
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

final class SessionScanService {
    struct Failure: Error {
        let detail: String
    }

    private let helperService: HelperCommandService

    init(helperService: HelperCommandService) {
        self.helperService = helperService
    }

    func sessionCount(processCallbacks: HelperCommandProcessCallbacks? = nil) -> Result<Int, Failure> {
        let result = run(arguments: ["session-count"], processCallbacks: processCallbacks)
        guard result.status == 0 else {
            return .failure(Failure(detail: result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        guard let totalCount = parseSessionCountOutput(result.stdout) else {
            return .failure(Failure(detail: result.stdout.isEmpty ? "无法解析 session-count 输出" : result.stdout))
        }
        return .success(totalCount)
    }

    func probeAllBatch(limit: Int, offset: Int, processCallbacks: HelperCommandProcessCallbacks? = nil) -> Result<[SessionSnapshot], Failure> {
        let result = run(
            arguments: ["probe-all", "--json", "-l", String(limit), "-o", String(offset)],
            processCallbacks: processCallbacks
        )
        guard result.status == 0 else {
            return .failure(Failure(detail: result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        return .success(parseProbeAllJSONOutput(result.stdout))
    }

    func threadListArchived(processCallbacks: HelperCommandProcessCallbacks? = nil) -> Result<[SessionSnapshot], Failure> {
        let result = run(arguments: ["thread-list", "--archived"], processCallbacks: processCallbacks)
        guard result.status == 0 else {
            return .failure(Failure(detail: result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        return .success(parseThreadListOutput(result.stdout, archived: true))
    }

    func probeSession(threadID: String, processCallbacks: HelperCommandProcessCallbacks? = nil) -> Result<SessionSnapshot, Failure> {
        let result = run(arguments: ["probe", "-t", threadID], processCallbacks: processCallbacks)
        guard result.status == 0 else {
            return .failure(Failure(detail: result.stderr.isEmpty ? result.stdout : result.stderr))
        }
        guard let snapshot = parseProbeAllOutput(result.stdout).first else {
            return .failure(Failure(detail: result.stdout.isEmpty ? "无法解析 session probe 输出" : result.stdout))
        }
        return .success(snapshot)
    }

    private func run(arguments: [String], processCallbacks: HelperCommandProcessCallbacks?) -> HelperCommandResult {
        helperService.run(
            arguments: arguments,
            onProcessStarted: processCallbacks?.onProcessStarted,
            onProcessFinished: processCallbacks?.onProcessFinished
        )
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

    func startLoop(target: String, interval: String, message: String, forceSend: Bool) -> HelperCommandResult {
        var arguments = ["start", "-t", target, "-i", interval, "-m", message]
        if forceSend {
            arguments.append("-f")
        }
        return helperService.run(arguments: arguments)
    }

    func startLoopAsync(
        target: String,
        interval: String,
        message: String,
        forceSend: Bool,
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping (HelperCommandResult) -> Void
    ) {
        var arguments = ["start", "-t", target, "-i", interval, "-m", message]
        if forceSend {
            arguments.append("-f")
        }
        helperService.runAsync(arguments: arguments, qos: qos, completion: completion)
    }

    func stopLoop(target: String) -> HelperCommandResult {
        helperService.run(arguments: ["stop", "-t", target])
    }

    func stopLoopAsync(
        target: String,
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping (HelperCommandResult) -> Void
    ) {
        helperService.runAsync(arguments: ["stop", "-t", target], qos: qos, completion: completion)
    }

    func stopAllLoops() -> HelperCommandResult {
        helperService.run(arguments: ["stop", "--all"])
    }

    func stopAllLoopsAsync(
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping (HelperCommandResult) -> Void
    ) {
        helperService.runAsync(arguments: ["stop", "--all"], qos: qos, completion: completion)
    }

    func resumeLoop(target: String) -> HelperCommandResult {
        helperService.run(arguments: ["loop-resume", "-t", target])
    }

    func resumeLoopAsync(
        target: String,
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping (HelperCommandResult) -> Void
    ) {
        helperService.runAsync(arguments: ["loop-resume", "-t", target], qos: qos, completion: completion)
    }

    func deleteLoop(target: String) -> HelperCommandResult {
        helperService.run(arguments: ["loop-delete", "-t", target])
    }

    func deleteLoopAsync(
        target: String,
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping (HelperCommandResult) -> Void
    ) {
        helperService.runAsync(arguments: ["loop-delete", "-t", target], qos: qos, completion: completion)
    }

    func sendMessageAsync(
        target: String,
        message: String,
        forceSend: Bool,
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping (HelperCommandResult) -> Void
    ) {
        var arguments = ["send", "-t", target, "-m", message]
        if forceSend {
            arguments.append("-f")
        }
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

func parseSessionCountOutput(_ output: String) -> Int? {
    Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
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

func mergeSessionSnapshotAfterStatusRefresh(previous: SessionSnapshot, refreshed: SessionSnapshot) -> SessionSnapshot {
    SessionSnapshot(
        name: refreshed.name.isEmpty ? previous.name : refreshed.name,
        target: refreshed.target.isEmpty ? previous.target : refreshed.target,
        threadID: previous.threadID,
        provider: refreshed.provider.isEmpty ? previous.provider : refreshed.provider,
        source: refreshed.source.isEmpty ? previous.source : refreshed.source,
        parentThreadID: refreshed.parentThreadID.isEmpty ? previous.parentThreadID : refreshed.parentThreadID,
        agentNickname: refreshed.agentNickname.isEmpty ? previous.agentNickname : refreshed.agentNickname,
        agentRole: refreshed.agentRole.isEmpty ? previous.agentRole : refreshed.agentRole,
        status: refreshed.status,
        reason: refreshed.reason,
        terminalState: refreshed.terminalState,
        tty: refreshed.tty,
        updatedAtEpoch: refreshed.updatedAtEpoch == "0" ? previous.updatedAtEpoch : refreshed.updatedAtEpoch,
        rolloutPath: refreshed.rolloutPath.isEmpty ? previous.rolloutPath : refreshed.rolloutPath,
        preview: refreshed.preview.isEmpty ? previous.preview : refreshed.preview,
        isArchived: previous.isArchived || refreshed.isArchived
    )
}

final class SessionStatusRefreshCoordinator {
    private let connectedRefreshInterval: TimeInterval
    private let disconnectedRefreshInterval: TimeInterval
    private let lock = NSLock()
    private var inFlightThreadIDs: Set<String> = []
    private var nextAllowedAt: [String: Date] = [:]

    init(connectedRefreshInterval: TimeInterval, disconnectedRefreshInterval: TimeInterval) {
        self.connectedRefreshInterval = connectedRefreshInterval
        self.disconnectedRefreshInterval = disconnectedRefreshInterval
    }

    func prune(to snapshots: [SessionSnapshot]) {
        let activeThreadIDs = Set(snapshots.filter { !$0.isArchived }.map(\.threadID))
        lock.lock()
        inFlightThreadIDs = inFlightThreadIDs.filter { activeThreadIDs.contains($0) }
        nextAllowedAt = nextAllowedAt.filter { activeThreadIDs.contains($0.key) }
        lock.unlock()
    }

    func clear() {
        lock.lock()
        inFlightThreadIDs.removeAll()
        nextAllowedAt.removeAll()
        lock.unlock()
    }

    func scheduleNext(for snapshot: SessionSnapshot, from completionDate: Date) {
        let nextAllowed = completionDate.addingTimeInterval(refreshInterval(for: snapshot))
        lock.lock()
        nextAllowedAt[snapshot.threadID] = nextAllowed
        inFlightThreadIDs.remove(snapshot.threadID)
        lock.unlock()
    }

    func claim(_ snapshots: [SessionSnapshot], requireDue: Bool, referenceDate: Date) -> [SessionSnapshot] {
        guard !snapshots.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }

        var claimed: [SessionSnapshot] = []
        for snapshot in snapshots {
            let threadID = snapshot.threadID
            guard !threadID.isEmpty else { continue }
            guard !inFlightThreadIDs.contains(threadID) else { continue }
            if requireDue,
               let nextAllowed = nextAllowedAt[threadID],
               nextAllowed > referenceDate {
                continue
            }
            inFlightThreadIDs.insert(threadID)
            claimed.append(snapshot)
        }
        return claimed
    }

    private func refreshInterval(for snapshot: SessionSnapshot) -> TimeInterval {
        localizedSessionStatusLabel(snapshot) == "断联"
            ? disconnectedRefreshInterval
            : connectedRefreshInterval
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

func sessionProviderDisplayValue(_ session: SessionSnapshot) -> String {
    let provider = session.provider.trimmingCharacters(in: .whitespacesAndNewlines)
    return provider.isEmpty ? "-" : provider
}

func sessionTerminalDisplayValue(_ session: SessionSnapshot) -> String {
    localizedTerminalState(session.terminalState)
}

func sessionTTYDisplayValue(_ session: SessionSnapshot) -> String {
    let tty = session.tty.trimmingCharacters(in: .whitespacesAndNewlines)
    return tty.isEmpty ? "-" : tty
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

func localizedProbeStatus(_ status: String) -> String {
    switch status.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase {
    case "idle_stable":
        return "空闲稳定"
    case "interrupted_idle":
        return "中断后空闲"
    case "idle_with_residual_input":
        return "空闲但有残留输入"
    case "busy_turn_open":
        return "回合进行中"
    case "post_finalizing":
        return "正在收尾"
    case "busy_with_stream_issue":
        return "忙碌且流异常"
    case "interrupted_or_aborting":
        return "中断或终止中"
    case "idle_prompt_visible_rollout_stale":
        return "提示符已回到可见但回合状态滞后"
    case "archived":
        return "已归档"
    case "unknown":
        return "未知"
    case "":
        return ""
    default:
        return status
    }
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

func formattedSendStatusContextText(probeStatus: String?, terminalState: String?) -> String {
    let probeLabel = localizedProbeStatus(probeStatus ?? "")
    let terminalLabel = localizedLoopTerminalState(terminalState ?? "")
    return [probeLabel, terminalLabel].filter { !$0.isEmpty }.joined(separator: " | ")
}

func formattedSendOutcomeStatusText(kind: String, target: String, reason: String, probeStatus: String?, terminalState: String?) -> String {
    let localizedReason = localizedSendReason(reason)
    let contextText = formattedSendStatusContextText(probeStatus: probeStatus, terminalState: terminalState)
    let suffix = [localizedReason, contextText].filter { !$0.isEmpty }.joined(separator: " | ")

    switch kind {
    case "success":
        return suffix.isEmpty ? "发送成功: \(target)" : "发送成功: \(target) | \(suffix)"
    case "accepted":
        return suffix.isEmpty ? "发送已受理: \(target)" : "发送已受理: \(target) | \(suffix)"
    case "failed":
        return suffix.isEmpty ? "发送失败: \(target)" : "发送失败: \(target) | \(suffix)"
    default:
        return "发送状态更新: \(target)"
    }
}

func formattedLoopOutcomeReason(reason: String, probeStatus: String, terminalState: String) -> String {
    let baseReason = localizedSendReason(reason)
    let probeLabel = localizedProbeStatus(probeStatus)
    let terminalLabel = localizedLoopTerminalState(terminalState)
    return [baseReason, probeLabel, terminalLabel].filter { !$0.isEmpty }.joined(separator: " | ")
}

struct ParsedLoopOutcome {
    let status: String
    let reason: String
    let probeStatus: String
    let terminalState: String
    let line: String
}

func loopLastOutcome(_ loop: LoopSnapshot) -> ParsedLoopOutcome {
    let line = loop.lastLogLine
    return ParsedLoopOutcome(
        status: loopLogField(line, key: "status")?.localizedLowercase ?? "",
        reason: loopLogField(line, key: "reason")?.localizedLowercase ?? "",
        probeStatus: loopLogField(line, key: "probe_status")?.localizedLowercase ?? "",
        terminalState: loopLogField(line, key: "terminal_state")?.localizedLowercase ?? "",
        line: line
    )
}

func loopFailureReasonFallback(_ loop: LoopSnapshot) -> String {
    loop.failureReason.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
}

func loopFallbackResultLabel(for failureReason: String) -> String {
    switch failureReason {
    case "not_sendable":
        return "待重试"
    case "tty_unavailable":
        return "TTY 不可用"
    case "tty_focus_failed":
        return "TTY 聚焦失败"
    case "ambiguous_target":
        return "目标不唯一"
    case "missing_accessibility_permission":
        return "权限缺失"
    case "":
        return ""
    default:
        let localized = localizedSendReason(failureReason)
        return localized.isEmpty ? "失败" : localized
    }
}

func detailedNotSendableLabel(probeStatus: String, terminalState: String) -> String {
    switch probeStatus {
    case "busy_turn_open":
        return "会话忙碌"
    case "post_finalizing":
        return "会话收尾中"
    case "busy_with_stream_issue":
        return "会话忙碌且流异常"
    case "interrupted_or_aborting":
        return "会话中断处理中"
    case "idle_prompt_visible_rollout_stale":
        return "回合状态滞后"
    case "idle_with_residual_input":
        return terminalState == "prompt_with_input" ? "提示符残留输入" : "残留输入"
    default:
        break
    }

    switch terminalState {
    case "queued_messages_pending":
        return "消息排队中"
    case "no_visible_prompt":
        return "未看到可用提示符"
    case "unavailable":
        return "TTY 不可用"
    default:
        return "当前状态不可发送"
    }
}

func loopResultLabel(_ loop: LoopSnapshot) -> String {
    if loop.stopped == "yes" {
        return "已停止"
    }
    if loop.paused == "yes" {
        return "已暂停"
    }

    let outcome = loopLastOutcome(loop)
    let normalizedLine = outcome.line.localizedLowercase
    let fallbackFailureReason = loopFailureReasonFallback(loop)

    if outcome.status == "success" {
        return "成功"
    }
    if outcome.status == "accepted" {
        if outcome.reason == "verification_pending" {
            return "等待确认"
        }
        if outcome.reason == "queued_pending_feedback" {
            return "消息排队中"
        }
        return "已受理"
    }
    if outcome.reason == "not_sendable" {
        return detailedNotSendableLabel(probeStatus: outcome.probeStatus, terminalState: outcome.terminalState)
    }
    if outcome.reason == "tty_unavailable" {
        return "TTY 不可用"
    }
    if outcome.reason == "tty_focus_failed" {
        return "TTY 聚焦失败"
    }
    if outcome.reason == "ambiguous_target" {
        return "目标不唯一"
    }
    if normalizedLine.contains("辅助功能权限") || outcome.reason == "missing_accessibility_permission" {
        return "权限缺失"
    }
    if normalizedLine.hasPrefix("deferred:") {
        return "待重试"
    }
    if !outcome.reason.isEmpty {
        let localized = localizedSendReason(outcome.reason)
        if localized != outcome.reason || !localized.isEmpty {
            return localized
        }
    }
    if outcome.status == "failed" || normalizedLine.contains("status=failed") {
        return "失败"
    }
    if !fallbackFailureReason.isEmpty {
        let fallbackResult = loopFallbackResultLabel(for: fallbackFailureReason)
        if !fallbackResult.isEmpty {
            return fallbackResult
        }
    }
    if !outcome.line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "未知"
    }
    return "等待"
}

func loopStateLabel(_ loop: LoopSnapshot) -> String {
    if loop.stopped == "yes" {
        return "停止"
    }
    if loop.paused == "yes" {
        return "暂停"
    }

    let result = loopResultLabel(loop)
    switch result {
    case "成功":
        return "健康"
    case "等待确认":
        return "待确认"
    case "消息排队中", "已受理":
        return "排队"
    case "待重试":
        return "待重试"
    case "会话忙碌", "会话收尾中", "会话忙碌且流异常", "会话中断处理中", "回合状态滞后":
        return "忙碌"
    case "提示符残留输入", "残留输入":
        return "待清理"
    case "TTY 不可用", "TTY 聚焦失败", "权限缺失", "目标不唯一", "失败":
        return "失败"
    default:
        if !loopFailureReasonFallback(loop).isEmpty {
            return "待重试"
        }
        if !loop.lastLogLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "未知"
        }
        return "等待"
    }
}

func loopResultReasonLabel(_ loop: LoopSnapshot) -> String {
    if loop.stopped == "yes" {
        return localizedSendReason(loop.stoppedReason)
    }
    if loop.paused == "yes" {
        return localizedSendReason(loop.pauseReason.isEmpty ? loop.failureReason : loop.pauseReason)
    }
    let outcome = loopLastOutcome(loop)
    let outcomeReason = formattedLoopOutcomeReason(
        reason: outcome.reason,
        probeStatus: outcome.probeStatus,
        terminalState: outcome.terminalState
    )
    if !outcomeReason.isEmpty {
        return outcomeReason
    }
    let fallbackReason = loopFailureReasonFallback(loop)
    if !fallbackReason.isEmpty {
        return localizedSendReason(fallbackReason)
    }
    if loop.lastLogLine.localizedCaseInsensitiveContains("辅助功能权限") {
        return localizedSendReason("missing_accessibility_permission")
    }
    return ""
}

func loopStateSortRank(_ loop: LoopSnapshot) -> Int {
    switch loopStateLabel(loop) {
    case "健康":
        return 0
    case "排队":
        return 1
    case "待重试":
        return 2
    case "等待":
        return 3
    case "未知":
        return 4
    case "暂停":
        return 5
    case "停止":
        return 6
    case "失败":
        return 7
    default:
        return 8
    }
}

private func loopLogField(_ line: String, key: String) -> String? {
    let pattern = "\(key): "
    guard let range = line.range(of: pattern) else { return nil }
    let suffix = line[range.upperBound...]
    let value = suffix.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
}

func formattedSessionDetailText(session: SessionSnapshot, updatedText: String) -> String {
    let name = sessionActualName(session)
    var lines = [
        "Name: \(name.isEmpty ? "-" : name)",
        "Session ID: \(session.threadID)",
        "Type: \(sessionTypeLabel(session))",
        "Provider: \(sessionProviderDisplayValue(session))",
        "Archived: \(session.isArchived ? "yes" : "no")",
        "Status: \(localizedSessionStatusLabel(session))",
        "Terminal: \(sessionTerminalDisplayValue(session))",
        "TTY: \(sessionTTYDisplayValue(session))",
        "Updated: \(updatedText)",
        "原因: \(localizedSessionReason(session.reason))"
    ]
    if !session.parentThreadID.isEmpty {
        lines.append("Parent Session ID: \(session.parentThreadID)")
    }
    if !session.agentNickname.isEmpty {
        lines.append("Agent Nickname: \(session.agentNickname)")
    }
    if !session.agentRole.isEmpty {
        lines.append("Agent Role: \(session.agentRole)")
    }
    let rolloutPath = session.rolloutPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if !rolloutPath.isEmpty {
        lines.append("Rollout: \(rolloutPath)")
    }
    let preview = session.preview.trimmingCharacters(in: .whitespacesAndNewlines)
    if !preview.isEmpty {
        lines.append("Preview: \(preview)")
    }
    return lines.joined(separator: "\n")
}

func formattedRecentSendStatsText(results: [SendResultSnapshot], formatEpoch: (String) -> String) -> String {
    guard !results.isEmpty else {
        return "最近发送统计\n暂无匹配该 session 的发送结果。"
    }

    let successCount = results.filter { $0.status == "success" }.count
    let acceptedCount = results.filter { $0.status == "accepted" }.count
    let failedResults = results.filter { $0.status == "failed" }
    let failedCount = failedResults.count

    var reasonCounts: [String: Int] = [:]
    for result in failedResults {
        let key = localizedSendReason(result.reason)
        reasonCounts[key, default: 0] += 1
    }

    let topReasons = reasonCounts
        .sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            return lhs.value > rhs.value
        }
        .prefix(3)
        .map { "\($0.key) (\($0.value))" }
        .joined(separator: "，")

    let latest = results[0]
    var lines = [
        "最近发送统计",
        "共 \(results.count) 次 | 成功 \(successCount) | 已受理 \(acceptedCount) | 失败 \(failedCount)",
        "最近一次: \(localizedSendStatusLabel(latest.status)) | \(localizedSendReason(latest.reason)) | \(formatEpoch(String(Int(latest.updatedAtEpoch))))"
    ]
    if !topReasons.isEmpty {
        lines.append("失败原因: \(topReasons)")
    }
    return lines.joined(separator: "\n")
}

func formattedRecentSendResultsText(results: [SendResultSnapshot], formatEpoch: (String) -> String) -> String {
    guard !results.isEmpty else {
        return "最近发送结果\n暂无匹配该 session 的发送记录。"
    }

    return results.enumerated().map { index, result in
        var lines = [
            "结果 \(index + 1)",
            "时间: \(formatEpoch(String(Int(result.updatedAtEpoch))))",
            "Target: \(result.target)",
            "状态: \(localizedSendStatusLabel(result.status))",
            "原因: \(localizedSendReason(result.reason))",
            "模式: \(result.forceSend ? "force" : "idle")"
        ]
        if !result.probeStatus.isEmpty {
            lines.append("Probe: \(result.probeStatus)")
        }
        if !result.terminalState.isEmpty {
            lines.append("Terminal: \(localizedTerminalState(result.terminalState))")
        }
        if !result.detail.isEmpty {
            lines.append("Detail: \(result.detail)")
        }
        return lines.joined(separator: "\n")
    }.joined(separator: "\n\n")
}

func formattedLoopOccupancyText(loops: [LoopSnapshot], formatEpoch: (String) -> String) -> String {
    guard !loops.isEmpty else {
        return "相关 Loop\n无"
    }

    return (["相关 Loop"] + loops.map { loop in
        let nextRun = loop.stopped == "yes" ? "-" : formatEpoch(loop.nextRunEpoch)
        let reason = loopResultReasonLabel(loop)
        var lines = [
            "Target: \(loop.target)",
            "状态: \(loopStateLabel(loop)) | 结果: \(loopResultLabel(loop))",
            "间隔: \(loop.intervalSeconds)s | 模式: \(loop.forceSend == "yes" ? "force" : "idle") | 下次: \(nextRun)"
        ]
        if !reason.isEmpty {
            lines.append("原因: \(reason)")
        }
        return lines.joined(separator: "\n")
    }).joined(separator: "\n\n")
}

func formattedSessionDetailPreviewDocument(
    sessionDetailText: String,
    sendStatsText: String,
    loopOccupancyText: String
) -> String {
    [
        sessionDetailText,
        sendStatsText,
        loopOccupancyText,
        "最近发送结果\n加载中…",
        "提示词历史\n加载中…"
    ].joined(separator: "\n\n")
}

func formattedSessionDetailDocument(
    sessionDetailText: String,
    sendStatsText: String,
    loopOccupancyText: String,
    sendResultsText: String,
    historyText: String
) -> String {
    [
        sessionDetailText,
        sendStatsText,
        loopOccupancyText,
        sendResultsText,
        "提示词历史\n\(historyText)"
    ].joined(separator: "\n\n")
}

func sessionScopeDisplayText(isArchived: Bool) -> String {
    isArchived ? "已归档" : "普通"
}

func sessionEmptyStateText(isArchived: Bool) -> String {
    isArchived
        ? "视图: 已归档 | 未加载归档 session。点击“检测会话”读取列表。"
        : "视图: 普通 | 未加载 session 状态。点击“检测会话”开始扫描。"
}

func formattedSessionSearchSummary(
    query: String,
    hitCount: Int,
    promptSearchEnabled: Bool,
    sessionScanRunning: Bool,
    promptSearchRunning: Bool,
    promptSearchCompleted: Bool,
    promptSearchProgressCompleted: Int,
    promptSearchProgressTotal: Int
) -> String? {
    guard !query.isEmpty else { return nil }

    var parts = ["搜索: \(query)", "命中: \(hitCount)"]
    if promptSearchEnabled {
        if sessionScanRunning {
            parts.append("近提示词检索待扫描完成后继续")
        } else if promptSearchRunning {
            parts.append("近提示词检索: \(promptSearchProgressCompleted)/\(promptSearchProgressTotal)")
        } else if promptSearchCompleted {
            parts.append("近提示词已检索")
        }
    }
    return parts.joined(separator: " | ")
}

func formattedSessionStatusMetaText(
    allSessionCount: Int,
    scopeText: String,
    emptyStateText: String,
    sessionScanRunning: Bool,
    scannedCount: Int?,
    totalCount: Int?,
    isComplete: Bool,
    searchSummary: String?,
    refreshText: String
) -> String {
    if allSessionCount == 0 {
        if sessionScanRunning, let scannedCount, let totalCount {
            return (["视图: \(scopeText)", "正在扫描 \(scannedCount)/\(totalCount)…"] + [searchSummary].compactMap { $0 })
                .joined(separator: " | ")
        }
        return emptyStateText
    }

    var parts = ["视图: \(scopeText)", "已加载: \(allSessionCount)"]
    if let scannedCount, let totalCount {
        let progressText = isComplete ? "已扫描: \(scannedCount)/\(totalCount)" : "扫描中: \(scannedCount)/\(totalCount)"
        parts.append(progressText)
        parts.append("总数: \(totalCount)")
    }
    if let searchSummary {
        parts.append(searchSummary)
    }
    parts.append("刷新: \(refreshText)")
    return parts.joined(separator: " | ")
}

func sessionScanStoppedMetaText(isArchived: Bool) -> String {
    "视图: \(sessionScopeDisplayText(isArchived: isArchived)) | 检测已停止。"
}

func sessionScanPreparingMetaText() -> String {
    "视图: 普通 | 正在准备扫描…"
}

func sessionScanFailureMetaText(detail: String) -> String {
    "视图: 普通 | 检测会话失败: \(detail)"
}

func sessionScanEmptyMetaText() -> String {
    "视图: 普通 | 没有可扫描的 session。"
}

func sessionScanProgressMetaText(scannedCount: Int, totalCount: Int) -> String {
    "视图: 普通 | 正在扫描 \(scannedCount)/\(totalCount)…"
}

func sessionScanPartialFailureSuffix() -> String {
    " | 部分失败"
}

func archivedSessionLoadingMetaText() -> String {
    "视图: 已归档 | 正在读取列表…"
}

func archivedSessionFailureMetaText(detail: String) -> String {
    "视图: 已归档 | 读取失败: \(detail)"
}

func sessionScanStoppedStatusText() -> String {
    "检测会话已停止"
}

func sessionScanStoppedLogText() -> String {
    "已请求停止检测会话。"
}

func sessionScanRunningStatusText() -> String {
    "检测会话执行中…"
}

func sessionScanStartLogText() -> String {
    "执行 检测会话: session-count + probe-all batches"
}

func sessionScanFailureStatusText() -> String {
    "检测会话失败"
}

func sessionScanCompletionStatusText() -> String {
    "检测会话完成"
}

func sessionScanProgressStatusText(scannedCount: Int, totalCount: Int) -> String {
    "检测会话执行中… \(scannedCount)/\(totalCount)"
}

func sessionScanPartialFailureStatusText() -> String {
    "检测会话部分失败"
}

func sessionScanCompletionLogText(count: Int) -> String {
    "检测到 \(count) 个 session 状态。"
}

func archivedSessionLoadingStatusText() -> String {
    "读取已归档 session 中…"
}

func archivedSessionStartLogText() -> String {
    "执行 检测会话: thread-list --archived"
}

func archivedSessionFailureStatusText() -> String {
    "读取已归档 session 失败"
}

func archivedSessionCompletionStatusText() -> String {
    "已加载已归档 session"
}

func archivedSessionCompletionLogText(count: Int) -> String {
    "检测到 \(count) 个已归档 session。"
}

func sessionStatusRefreshBlockedByScanText() -> String {
    "检测会话进行中，请稍后再刷新状态"
}

func sessionStatusRefreshAlreadyRunningText() -> String {
    "当前会话状态刷新仍在进行中"
}

func sessionStatusRefreshRunningText() -> String {
    "刷新状态执行中…"
}

func sessionStatusRefreshCompletionText(failedCount: Int, totalCount: Int) -> String {
    if failedCount == 0 {
        return "刷新状态完成"
    }
    if failedCount == totalCount {
        return "刷新状态失败"
    }
    return "刷新状态部分失败"
}

func sessionScopeChangeBlockedStatusText() -> String {
    "请等待当前检测完成或手动停止后再切换"
}

func sessionScopeChangeBlockedLogText(activeScopeText: String) -> String {
    "检测会话仍在进行中，已保持当前视图为\(activeScopeText)。"
}

func sessionScopeAlreadySelectedStatusText(scopeText: String) -> String {
    "当前视图切换为\(scopeText)"
}

func sessionScopeChangedStatusText(requestedScopeText: String) -> String {
    "已切换到\(requestedScopeText)视图，点击“检测会话”刷新"
}

func sessionScopeChangedLogText(requestedScopeText: String, displayedScopeText: String) -> String {
    "已切换 Session Status 视图到\(requestedScopeText)；当前列表仍显示上次\(displayedScopeText)检测结果，点击“检测会话”后刷新。"
}

func sessionFastMatchesQuery(_ session: SessionSnapshot, normalizedQuery: String) -> Bool {
    guard !normalizedQuery.isEmpty else { return true }
    let candidates = [
        sessionActualName(session),
        sessionTypeLabel(session),
        session.provider,
        session.threadID,
        sessionEffectiveTarget(session),
        session.preview,
        localizedSessionStatusLabel(session),
        localizedSessionReason(session.reason)
    ]
    return candidates.contains { candidate in
        candidate.localizedLowercase.contains(normalizedQuery)
    }
}

func sessionMatchesFilterValues(
    _ session: SessionSnapshot,
    providerFilters: Set<String>,
    typeFilters: Set<String>,
    statusFilters: Set<String>,
    terminalFilters: Set<String>,
    ttyFilters: Set<String>
) -> Bool {
    if !providerFilters.isEmpty && !providerFilters.contains(sessionProviderDisplayValue(session)) {
        return false
    }
    if !typeFilters.isEmpty && !typeFilters.contains(sessionTypeLabel(session)) {
        return false
    }
    if !statusFilters.isEmpty && !statusFilters.contains(localizedSessionStatusLabel(session)) {
        return false
    }
    if !terminalFilters.isEmpty && !terminalFilters.contains(sessionTerminalDisplayValue(session)) {
        return false
    }
    if !ttyFilters.isEmpty && !ttyFilters.contains(sessionTTYDisplayValue(session)) {
        return false
    }
    return true
}

enum SessionFilterKind: String {
    case provider
    case type
    case status
    case terminal
    case tty

    init?(columnIdentifier: String) {
        switch columnIdentifier {
        case "provider":
            self = .provider
        case "type":
            self = .type
        case "status":
            self = .status
        case "terminalState":
            self = .terminal
        case "tty":
            self = .tty
        default:
            return nil
        }
    }

    var title: String {
        switch self {
        case .provider:
            return "Provider"
        case .type:
            return "类型"
        case .status:
            return "Status"
        case .terminal:
            return "Terminal"
        case .tty:
            return "TTY"
        }
    }
}

struct SessionFilterSelections {
    var provider = Set<String>()
    var type = Set<String>()
    var status = Set<String>()
    var terminal = Set<String>()
    var tty = Set<String>()

    func values(for kind: SessionFilterKind) -> Set<String> {
        switch kind {
        case .provider:
            return provider
        case .type:
            return type
        case .status:
            return status
        case .terminal:
            return terminal
        case .tty:
            return tty
        }
    }

    mutating func setValues(_ values: Set<String>, for kind: SessionFilterKind) {
        switch kind {
        case .provider:
            provider = values
        case .type:
            type = values
        case .status:
            status = values
        case .terminal:
            terminal = values
        case .tty:
            tty = values
        }
    }
}

func sessionFilterOptionsForKind(_ kind: SessionFilterKind, from snapshots: [SessionSnapshot]) -> [String] {
    switch kind {
    case .provider:
        return sessionProviderFilterOptions(from: snapshots)
    case .type:
        return sessionTypeFilterOptions(from: snapshots)
    case .status:
        return sessionStatusFilterOptions(from: snapshots)
    case .terminal:
        return sessionTerminalFilterOptions(from: snapshots)
    case .tty:
        return sessionTTYFilterOptions(from: snapshots)
    }
}

func sessionProviderFilterOptions(from snapshots: [SessionSnapshot]) -> [String] {
    var values = Set(snapshots.map(sessionProviderDisplayValue(_:)))
    values.insert("-")
    return values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

func sessionTypeFilterOptions(from snapshots: [SessionSnapshot]) -> [String] {
    let base = ["CLI", "Subagent", "Exec", "Other"]
    guard !snapshots.isEmpty else { return base }
    let seen = Set(snapshots.map(sessionTypeLabel(_:)))
    let extras = seen.subtracting(base).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    return base + extras
}

func sessionStatusFilterOptions(from snapshots: [SessionSnapshot]) -> [String] {
    let base = ["空闲", "中断后空闲", "运行中", "状态滞后", "残留输入", "消息排队", "未知", "断联", "已归档"]
    guard !snapshots.isEmpty else { return base }
    let seen = Set(snapshots.map(localizedSessionStatusLabel(_:)))
    let extras = seen.subtracting(base).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    return base + extras
}

func sessionTerminalFilterOptions(from snapshots: [SessionSnapshot]) -> [String] {
    let base = ["可发送", "忙碌", "有残留输入", "不可达", "已归档", "未知"]
    guard !snapshots.isEmpty else { return base }
    let seen = Set(snapshots.map(sessionTerminalDisplayValue(_:)))
    let extras = seen.subtracting(base).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    return base + extras
}

func sessionTTYFilterOptions(from snapshots: [SessionSnapshot]) -> [String] {
    var ttyValues = Set(snapshots.map(sessionTTYDisplayValue(_:)))
    ttyValues.insert("-")
    return ttyValues.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

let sessionFilterAllToken = "__all__"

func sessionFilterPanelItems(options: [String]) -> [String] {
    [sessionFilterAllToken] + options
}

func sessionFilterItemTitle(_ item: String) -> String {
    item == sessionFilterAllToken ? "全部" : item
}

func toggledSessionFilterValues(_ values: Set<String>, item: String) -> Set<String> {
    guard item != sessionFilterAllToken else { return [] }

    var updatedValues = values
    if updatedValues.contains(item) {
        updatedValues.remove(item)
    } else {
        updatedValues.insert(item)
    }
    return updatedValues
}

func isSessionFilterItemSelected(_ item: String, selectedValues: Set<String>) -> Bool {
    item == sessionFilterAllToken ? selectedValues.isEmpty : selectedValues.contains(item)
}
