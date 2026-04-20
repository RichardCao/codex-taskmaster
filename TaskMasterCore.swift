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

    var primaryDetail: String? {
        let detail = trimmedStderr.isEmpty ? trimmedStdout : trimmedStderr
        return detail.isEmpty ? nil : detail
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

    var primaryDetail: String? {
        let detail = stderr.isEmpty ? stdout : stderr
        return detail.isEmpty ? nil : detail
    }

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
        return (false, result.primaryDetail ?? "迁移 provider 失败")
    }

    func migrateAllSessionsProvider(targetProvider: String) -> (success: Bool, detail: String) {
        let result = helperService.run(arguments: ["thread-provider-migrate-all", "-p", targetProvider])
        if result.status == 0 {
            return (true, result.stdout)
        }
        return (false, result.primaryDetail ?? "迁移全部 session provider 失败")
    }

    func updateSessionName(threadID: String, newName: String) -> (success: Bool, error: String) {
        let result = helperService.run(arguments: ["thread-name-set", "-t", threadID, "-n", newName])
        if result.status == 0 {
            return (true, "")
        }
        let detail = result.primaryDetail ?? (newName.isEmpty ? "清空名称失败" : "重命名失败")
        return (false, detail)
    }

    func archiveSession(threadID: String) -> (success: Bool, error: String) {
        let result = helperService.run(arguments: ["thread-archive", "-t", threadID])
        if result.status == 0 {
            return (true, "")
        }
        let detail = result.primaryDetail ?? "归档 session 失败"
        return (false, detail)
    }

    func unarchiveSession(threadID: String) -> (success: Bool, error: String) {
        let result = helperService.run(arguments: ["thread-unarchive", "-t", threadID])
        if result.status == 0 {
            return (true, "")
        }
        let detail = result.primaryDetail ?? "恢复归档失败"
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
            return .failure(Failure(detail: result.primaryDetail ?? "session-count 失败"))
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
            return .failure(Failure(detail: result.primaryDetail ?? "probe-all 失败"))
        }
        return .success(parseProbeAllJSONOutput(result.stdout))
    }

    func threadListArchived(processCallbacks: HelperCommandProcessCallbacks? = nil) -> Result<[SessionSnapshot], Failure> {
        let result = run(arguments: ["thread-list", "--archived"], processCallbacks: processCallbacks)
        guard result.status == 0 else {
            return .failure(Failure(detail: result.primaryDetail ?? "thread-list --archived 失败"))
        }
        return .success(parseThreadListOutput(result.stdout, archived: true))
    }

    func probeSession(threadID: String, processCallbacks: HelperCommandProcessCallbacks? = nil) -> Result<SessionSnapshot, Failure> {
        let result = run(arguments: ["probe", "-t", threadID], processCallbacks: processCallbacks)
        guard result.status == 0 else {
            return .failure(Failure(detail: result.primaryDetail ?? "probe 失败"))
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

struct ArchivedSessionLoadPlan {
    let snapshots: [SessionSnapshot]?
    let failureDetail: String
    let statusText: String
    let metaText: String?
    let completionLogText: String?

    var isSuccess: Bool {
        snapshots != nil
    }
}

func archivedSessionLoadPlan(
    _ result: Result<[SessionSnapshot], SessionScanService.Failure>
) -> ArchivedSessionLoadPlan {
    switch result {
    case let .success(snapshots):
        return ArchivedSessionLoadPlan(
            snapshots: snapshots,
            failureDetail: "",
            statusText: archivedSessionCompletionStatusText(),
            metaText: nil,
            completionLogText: archivedSessionCompletionLogText(count: snapshots.count)
        )
    case let .failure(error):
        return ArchivedSessionLoadPlan(
            snapshots: nil,
            failureDetail: error.detail,
            statusText: archivedSessionFailureStatusText(),
            metaText: archivedSessionFailureMetaText(detail: error.detail),
            completionLogText: nil
        )
    }
}

enum SessionScanCountOutcome {
    case failure
    case empty
    case progress
}

struct SessionScanCountPlan {
    let outcome: SessionScanCountOutcome
    let totalCount: Int
    let failureDetail: String
    let metaText: String
    let statusText: String?
}

func sessionScanCountPlan(
    _ result: Result<Int, SessionScanService.Failure>
) -> SessionScanCountPlan {
    switch result {
    case let .failure(error):
        return SessionScanCountPlan(
            outcome: .failure,
            totalCount: 0,
            failureDetail: error.detail,
            metaText: sessionScanFailureMetaText(detail: error.detail),
            statusText: sessionScanFailureStatusText()
        )
    case let .success(totalCount) where totalCount == 0:
        return SessionScanCountPlan(
            outcome: .empty,
            totalCount: 0,
            failureDetail: "",
            metaText: sessionScanEmptyMetaText(),
            statusText: sessionScanCompletionStatusText()
        )
    case let .success(totalCount):
        return SessionScanCountPlan(
            outcome: .progress,
            totalCount: totalCount,
            failureDetail: "",
            metaText: sessionScanProgressMetaText(scannedCount: 0, totalCount: totalCount),
            statusText: nil
        )
    }
}

enum SessionScanCompletionOutcome {
    case partialFailure
    case complete
}

struct SessionScanCompletionPlan {
    let outcome: SessionScanCompletionOutcome
    let statusText: String
    let metaSuffix: String
    let completionLogText: String?
}

func sessionScanCompletionPlan(
    encounteredFailure: Bool,
    renderedSessionCount: Int
) -> SessionScanCompletionPlan {
    if encounteredFailure {
        return SessionScanCompletionPlan(
            outcome: .partialFailure,
            statusText: sessionScanPartialFailureStatusText(),
            metaSuffix: sessionScanPartialFailureSuffix(),
            completionLogText: nil
        )
    }

    return SessionScanCompletionPlan(
        outcome: .complete,
        statusText: sessionScanCompletionStatusText(),
        metaSuffix: "",
        completionLogText: sessionScanCompletionLogText(count: renderedSessionCount)
    )
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
                completion(nil, result.primaryDetail ?? "Failed to load active loops.")
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

    private func loopSelectorArguments(target: String, loopID: String?) -> [String] {
        let trimmedLoopID = loopID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedLoopID.isEmpty {
            return ["-k", trimmedLoopID]
        }
        return ["-t", target]
    }

    func stopLoop(target: String, loopID: String? = nil) -> HelperCommandResult {
        helperService.run(arguments: ["stop"] + loopSelectorArguments(target: target, loopID: loopID))
    }

    func stopLoopAsync(
        target: String,
        loopID: String? = nil,
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping (HelperCommandResult) -> Void
    ) {
        helperService.runAsync(arguments: ["stop"] + loopSelectorArguments(target: target, loopID: loopID), qos: qos, completion: completion)
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

    func resumeLoop(target: String, loopID: String? = nil) -> HelperCommandResult {
        helperService.run(arguments: ["loop-resume"] + loopSelectorArguments(target: target, loopID: loopID))
    }

    func resumeLoopAsync(
        target: String,
        loopID: String? = nil,
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping (HelperCommandResult) -> Void
    ) {
        helperService.runAsync(arguments: ["loop-resume"] + loopSelectorArguments(target: target, loopID: loopID), qos: qos, completion: completion)
    }

    func deleteLoop(target: String, loopID: String? = nil) -> HelperCommandResult {
        helperService.run(arguments: ["loop-delete"] + loopSelectorArguments(target: target, loopID: loopID))
    }

    func deleteLoopAsync(
        target: String,
        loopID: String? = nil,
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping (HelperCommandResult) -> Void
    ) {
        helperService.runAsync(arguments: ["loop-delete"] + loopSelectorArguments(target: target, loopID: loopID), qos: qos, completion: completion)
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

func parseStructuredSendHelperResult(_ text: String) -> [String: String]? {
    guard let fields = parseStructuredKeyValueFields(text),
          fields["target"] != nil else {
        return nil
    }
    return fields
}

struct HelperExecutionPlan {
    struct FailurePresentation {
        let ambiguousTarget: (target: String, detail: String)?
        let permissionIssue: String?
    }

    let isAccepted: Bool
    let isSuccessful: Bool
    let shouldRecordHistory: Bool
    let optimisticLoopSnapshot: LoopSnapshot?
    let optimisticRefreshDelays: [TimeInterval]
    let deletedLoopTarget: String?
    let actionStatusText: String
    let failurePresentation: FailurePresentation?
}

func helperExecutionPlan(
    actionName: String,
    displayArguments: [String],
    result: HelperCommandResult,
    loopSnapshots: [LoopSnapshot],
    currentTarget: String
) -> HelperExecutionPlan {
    let isAccepted = (actionName == "发送一次") && result.status == 2
    let isSuccessful = result.status == 0 || isAccepted
    let structuredSendResult = actionName == "发送一次" ? parseStructuredSendHelperResult(result.stderr) : nil

    if isSuccessful {
        let shouldRecordHistory = actionName == "发送一次" || actionName == "开始循环"
        var optimisticLoopSnapshotValue: LoopSnapshot?
        var optimisticRefreshDelays: [TimeInterval] = []
        var deletedLoopTarget: String?

        if actionName == "开始循环",
           let target = taskMasterHelperTargetArgument(from: displayArguments) {
            optimisticLoopSnapshotValue = optimisticLoopSnapshot(
                target: target,
                interval: taskMasterHelperArgumentValue(flag: "-i", from: displayArguments),
                message: taskMasterHelperArgumentValue(flag: "-m", from: displayArguments),
                forceSend: taskMasterHelperArgumentHasFlag("-f", in: displayArguments),
                existingSnapshots: loopSnapshots
            )
            optimisticRefreshDelays = [1.5, 5.0]
        } else if actionName == "恢复当前",
                  let target = taskMasterHelperTargetArgument(from: displayArguments) {
            let existingSnapshot = loopSnapshots.first(where: { $0.target == target })
            optimisticLoopSnapshotValue = optimisticLoopSnapshot(
                target: target,
                interval: existingSnapshot?.intervalSeconds,
                message: existingSnapshot?.message,
                forceSend: existingSnapshot?.isForceSendEnabled,
                existingSnapshots: loopSnapshots
            )
            optimisticRefreshDelays = [1.5, 5.0]
        }

        if actionName == "删除当前" {
            deletedLoopTarget = taskMasterHelperTargetArgument(from: displayArguments)
        }

        return HelperExecutionPlan(
            isAccepted: isAccepted,
            isSuccessful: true,
            shouldRecordHistory: shouldRecordHistory,
            optimisticLoopSnapshot: optimisticLoopSnapshotValue,
            optimisticRefreshDelays: optimisticRefreshDelays,
            deletedLoopTarget: deletedLoopTarget,
            actionStatusText: isAccepted ? "\(actionName)已受理" : "\(actionName)完成",
            failurePresentation: nil
        )
    }

    let combinedErrorDetail = result.combinedText
    let failurePresentation: HelperExecutionPlan.FailurePresentation
    if let structuredSendResult,
       structuredSendResult["reason"] == "ambiguous_target" {
        failurePresentation = .init(
            ambiguousTarget: (
                target: structuredSendResult["target"] ?? currentTarget,
                detail: structuredSendResult["detail"] ?? result.stderr
            ),
            permissionIssue: nil
        )
    } else {
        failurePresentation = .init(
            ambiguousTarget: nil,
            permissionIssue: taskMasterHelperPermissionIssueDetail(combinedErrorDetail)
        )
    }

    return HelperExecutionPlan(
        isAccepted: false,
        isSuccessful: false,
        shouldRecordHistory: false,
        optimisticLoopSnapshot: nil,
        optimisticRefreshDelays: [],
        deletedLoopTarget: nil,
        actionStatusText: "\(actionName)失败",
        failurePresentation: failurePresentation
    )
}

func preferredCommandDetail(stdout: String, stderr: String) -> String? {
    let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr
    let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func parseSessionCountOutput(_ output: String) -> Int? {
    Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
}

func compactProbeSummary(status: Int32, values: [String: String], stdout: String, stderr: String) -> String {
    if status != 0 {
        return preferredCommandDetail(stdout: stdout, stderr: stderr) ?? ""
    }

    let keys = [
        "target",
        "thread_id",
        "tty",
        "status",
        "reason",
        "terminal_state",
        "terminal_reason",
        "last_user_message_at",
        "last_user_message"
    ]

    return keys.compactMap { key in
        guard let value = values[key], !value.isEmpty else { return nil }
        return "\(key): \(value)"
    }.joined(separator: " | ")
}

func normalizeTTYIdentifier(_ tty: String) -> String {
    let trimmed = tty.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "-" {
        return ""
    }
    if trimmed.hasPrefix("/dev/") {
        return String(trimmed.dropFirst("/dev/".count))
    }
    return trimmed
}

struct LoopSnapshot {
    let loopID: String
    let target: String
    let loopDaemonRunning: Bool
    let intervalSeconds: String
    let forceSend: Bool
    let message: String
    let nextRunEpoch: TimeInterval
    let stopped: Bool
    let stoppedReason: String
    let paused: Bool
    let failureCount: String
    let failureReason: String
    let pauseReason: String
    let logPath: String
    let lastLogLine: String

    init(
        loopID: String = "",
        target: String,
        loopDaemonRunning: Bool,
        intervalSeconds: String,
        forceSend: Bool,
        message: String,
        nextRunEpoch: TimeInterval,
        stopped: Bool,
        stoppedReason: String,
        paused: Bool,
        failureCount: String,
        failureReason: String,
        pauseReason: String,
        logPath: String,
        lastLogLine: String
    ) {
        self.loopID = loopID
        self.target = target
        self.loopDaemonRunning = loopDaemonRunning
        self.intervalSeconds = intervalSeconds
        self.forceSend = forceSend
        self.message = message
        self.nextRunEpoch = nextRunEpoch
        self.stopped = stopped
        self.stoppedReason = stoppedReason
        self.paused = paused
        self.failureCount = failureCount
        self.failureReason = failureReason
        self.pauseReason = pauseReason
        self.logPath = logPath
        self.lastLogLine = lastLogLine
    }

    var isLoopDaemonRunning: Bool {
        loopDaemonRunning
    }

    var isForceSendEnabled: Bool {
        forceSend
    }

    var isStopped: Bool {
        stopped
    }

    var isPaused: Bool {
        paused
    }

    var nextRunTimeInterval: TimeInterval? {
        nextRunEpoch > 0 ? nextRunEpoch : nil
    }

    var stoppedReasonKind: SendOutcomeReason {
        SendOutcomeReason(rawValue: stoppedReason.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase)
    }

    var pauseReasonKind: SendOutcomeReason {
        SendOutcomeReason(rawValue: pauseReason.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase)
    }

    var failureReasonKind: SendOutcomeReason {
        SendOutcomeReason(rawValue: failureReason.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase)
    }

    var mergeIdentity: String {
        let trimmedLoopID = loopID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedLoopID.isEmpty ? target : trimmedLoopID
    }
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
    let updatedAtEpoch: TimeInterval
    let rolloutPath: String
    let preview: String
    let isArchived: Bool

    var updatedAtTimeInterval: TimeInterval? {
        updatedAtEpoch
    }

    var terminalStateKind: SessionTerminalState {
        SessionTerminalState(rawValueOrUnknown: terminalState)
    }

    var statusKind: SessionRuntimeStatus {
        SessionRuntimeStatus(rawValue: status)
    }
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

    var statusKind: SendOutcomeStatus {
        SendOutcomeStatus(rawValue: status)
    }

    var reasonKind: SendOutcomeReason {
        SendOutcomeReason(rawValue: reason)
    }
}

struct RecentUserMessageEntry: Equatable {
    let timestamp: String
    let message: String
}

func parseStoredSendResultSnapshot(data: Data, updatedAtEpoch: TimeInterval) -> SendResultSnapshot? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }

    let target = (object["target"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return nil }

    return SendResultSnapshot(
        target: target,
        status: object["status"] as? String ?? "",
        reason: object["reason"] as? String ?? "",
        forceSend: object["force_send"] as? Bool ?? false,
        detail: object["detail"] as? String ?? "",
        probeStatus: object["probe_status"] as? String ?? "",
        terminalState: object["terminal_state"] as? String ?? "",
        updatedAtEpoch: updatedAtEpoch
    )
}

func parseRecentUserMessageEntries(from rolloutText: String, limit: Int? = nil) -> [RecentUserMessageEntry] {
    var entries: [RecentUserMessageEntry] = []

    for rawLine in rolloutText.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let lineData = rawLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let type = object["type"] as? String,
              type == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String,
              payloadType == "user_message" else {
            continue
        }

        let timestamp = object["timestamp"] as? String ?? "-"
        let message = (payload["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            entries.append(RecentUserMessageEntry(timestamp: timestamp, message: message))
        }
    }

    if let limit, entries.count > limit {
        return Array(entries.suffix(limit))
    }
    return entries
}

enum SendOutcomeStatus: Equatable {
    case success
    case accepted
    case failed
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "success":
            self = .success
        case "accepted":
            self = .accepted
        case "failed":
            self = .failed
        default:
            self = .other(rawValue)
        }
    }
}

enum SendOutcomeReason: Equatable {
    case sent
    case forcedSent
    case queuedPendingFeedback
    case verificationPending
    case requestStillProcessing
    case requestAlreadyInflight
    case ambiguousTarget
    case ttyUnavailable
    case ttyFocusFailed
    case terminalFocusScriptLaunchFailed
    case keyboardEventSourceFailed
    case keyboardEventCreationFailed
    case probeFailed
    case notSendable
    case sendInterrupted
    case sendUnverified
    case sendUnverifiedAfterTTYFallback
    case invalidRequest
    case missingAccessibilityPermission
    case stoppedByUser
    case startFailed
    case loopConflictActiveSession
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "sent":
            self = .sent
        case "forced_sent":
            self = .forcedSent
        case "queued_pending_feedback":
            self = .queuedPendingFeedback
        case "verification_pending":
            self = .verificationPending
        case "request_still_processing":
            self = .requestStillProcessing
        case "request_already_inflight":
            self = .requestAlreadyInflight
        case "ambiguous_target":
            self = .ambiguousTarget
        case "tty_unavailable":
            self = .ttyUnavailable
        case "tty_focus_failed":
            self = .ttyFocusFailed
        case "terminal_focus_script_launch_failed":
            self = .terminalFocusScriptLaunchFailed
        case "keyboard_event_source_failed":
            self = .keyboardEventSourceFailed
        case "keyboard_event_creation_failed":
            self = .keyboardEventCreationFailed
        case "probe_failed":
            self = .probeFailed
        case "not_sendable":
            self = .notSendable
        case "send_interrupted":
            self = .sendInterrupted
        case "send_unverified":
            self = .sendUnverified
        case "send_unverified_after_tty_fallback":
            self = .sendUnverifiedAfterTTYFallback
        case "invalid_request":
            self = .invalidRequest
        case "missing_accessibility_permission":
            self = .missingAccessibilityPermission
        case "stopped_by_user":
            self = .stoppedByUser
        case "start_failed":
            self = .startFailed
        case "loop_conflict_active_session":
            self = .loopConflictActiveSession
        default:
            self = .other(rawValue)
        }
    }
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
            loopID: item["loop_id"] as? String ?? "",
            target: target,
            loopDaemonRunning: parsedLoopSnapshotBool(item["loop_daemon_running"]),
            intervalSeconds: item["interval_seconds"] as? String ?? "unknown",
            forceSend: parsedLoopSnapshotBool(item["force_send"]),
            message: item["message"] as? String ?? "unknown",
            nextRunEpoch: parsedEpochTimeInterval(item["next_run_epoch"]),
            stopped: parsedLoopSnapshotBool(item["stopped"]),
            stoppedReason: item["stopped_reason"] as? String ?? "",
            paused: parsedLoopSnapshotBool(item["paused"]),
            failureCount: item["failure_count"] as? String ?? "0",
            failureReason: item["failure_reason"] as? String ?? "",
            pauseReason: item["pause_reason"] as? String ?? "",
            logPath: item["log"] as? String ?? "-",
            lastLogLine: item["last_log_line"] as? String ?? ""
        )
    }

    return (loops, warnings)
}

func parsedLoopSnapshotBool(_ rawValue: Any?) -> Bool {
    switch rawValue {
    case let value as Bool:
        return value
    case let value as String:
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return normalized == "yes" || normalized == "true" || normalized == "1"
    case let value as NSNumber:
        return value.boolValue
    default:
        return false
    }
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

func loopTargetsAffectingSession(_ session: SessionSnapshot, loopSnapshots: [LoopSnapshot]) -> [String] {
    let candidates = Set(sessionPossibleTargets(session))
    guard !candidates.isEmpty else { return [] }
    return loopSnapshots
        .map(\.target)
        .filter { candidates.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

func runningLoopConflicts(for target: String, sessionSnapshots: [SessionSnapshot], loopSnapshots: [LoopSnapshot]) -> [LoopSnapshot] {
    let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTarget.isEmpty else { return [] }

    if let session = sessionSnapshots.first(where: { sessionPossibleTargets($0).contains(trimmedTarget) }) {
        let targets = Set(loopTargetsAffectingSession(session, loopSnapshots: loopSnapshots))
        return loopSnapshots.filter { targets.contains($0.target) && !$0.isStopped }
    }

    return loopSnapshots.filter { $0.target == trimmedTarget && !$0.isStopped }
}

struct RuntimePermissionPaths {
    let stateDirectoryPath: String
    let pendingRequestDirectoryPath: String
    let processingRequestDirectoryPath: String
    let resultRequestDirectoryPath: String
    let runtimeDirectoryPath: String
    let loopsDirectoryPath: String
    let loopLogDirectoryPath: String
    let userLoopStateDirectoryPath: String
    let legacyLoopStateDirectoryPath: String
}

func taskMasterEnsureWritableDirectory(at path: String, fileManager: FileManager = .default) -> String? {
    var isDirectory: ObjCBool = false

    if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
            return "\(path) 已存在，但它不是目录。"
        }
        guard fileManager.isWritableFile(atPath: path) else {
            return "\(path) 当前不可写。请检查属主或权限设置。"
        }
        return nil
    }

    do {
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        return nil
    } catch {
        return "无法创建目录 \(path)：\(error.localizedDescription)"
    }
}

func taskMasterRuntimePermissionIssueForAction(
    paths: RuntimePermissionPaths,
    requiresLoopState: Bool,
    fileManager: FileManager = .default
) -> String? {
    var checkedPaths = [
        paths.stateDirectoryPath,
        "\(paths.stateDirectoryPath)/requests",
        paths.pendingRequestDirectoryPath,
        paths.processingRequestDirectoryPath,
        paths.resultRequestDirectoryPath,
        paths.runtimeDirectoryPath
    ]

    if requiresLoopState {
        checkedPaths.append(contentsOf: [
            paths.loopsDirectoryPath,
            paths.loopLogDirectoryPath,
            paths.userLoopStateDirectoryPath
        ])
    }

    for path in checkedPaths {
        if let issue = taskMasterEnsureWritableDirectory(at: path, fileManager: fileManager) {
            return issue
        }
    }

    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: paths.legacyLoopStateDirectoryPath, isDirectory: &isDirectory),
       isDirectory.boolValue,
       !fileManager.isWritableFile(atPath: paths.legacyLoopStateDirectoryPath) {
        return "\(paths.legacyLoopStateDirectoryPath) 当前不可写。这个旧目录可能会让旧 loop daemon 或旧状态文件持续报权限错误。"
    }

    return nil
}

func taskMasterHelperPermissionIssueDetail(_ detail: String) -> String? {
    let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lowercased = trimmed.lowercased()
    guard lowercased.contains("permission denied") || lowercased.contains("operation not permitted") else {
        return nil
    }
    return trimmed
}

func taskMasterHelperTargetArgument(from arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: "-t"), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

func taskMasterHelperArgumentValue(flag: String, from arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

func taskMasterHelperArgumentHasFlag(_ flag: String, in arguments: [String]) -> Bool {
    arguments.contains(flag)
}

func taskMasterHelperDisplayArguments(base: [String], forceSend: Bool) -> [String] {
    var arguments = base
    if forceSend {
        arguments.append("-f")
    }
    return arguments
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
                updatedAtEpoch: parsedEpochTimeInterval(current["updated_at_epoch"]),
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
            updatedAtEpoch: parsedEpochTimeInterval(item["updated_at_epoch"]),
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
            updatedAtEpoch: parsedEpochTimeInterval(item["updatedAt"]),
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
        updatedAtEpoch: refreshed.updatedAtEpoch == 0 ? previous.updatedAtEpoch : refreshed.updatedAtEpoch,
        rolloutPath: refreshed.rolloutPath.isEmpty ? previous.rolloutPath : refreshed.rolloutPath,
        preview: refreshed.preview.isEmpty ? previous.preview : refreshed.preview,
        isArchived: previous.isArchived || refreshed.isArchived
    )
}

func mergeLoopSnapshot(previous: LoopSnapshot?, incoming: LoopSnapshot) -> LoopSnapshot {
    guard let previous else { return incoming }

    let incomingIsUnderspecified = !incoming.isStopped
        && !incoming.isPaused
        && incoming.failureReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && incoming.lastLogLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    guard incomingIsUnderspecified else { return incoming }

    return LoopSnapshot(
        loopID: incoming.loopID,
        target: incoming.target,
        loopDaemonRunning: incoming.loopDaemonRunning,
        intervalSeconds: incoming.intervalSeconds,
        forceSend: incoming.forceSend,
        message: incoming.message,
        nextRunEpoch: incoming.nextRunEpoch,
        stopped: incoming.stopped,
        stoppedReason: incoming.stoppedReason,
        paused: incoming.paused,
        failureCount: incoming.failureCount == "0" ? previous.failureCount : incoming.failureCount,
        failureReason: previous.failureReason,
        pauseReason: incoming.pauseReason.isEmpty ? previous.pauseReason : incoming.pauseReason,
        logPath: incoming.logPath == "-" ? previous.logPath : incoming.logPath,
        lastLogLine: previous.lastLogLine
    )
}

func mergeLoopSnapshots(previous: [LoopSnapshot], incoming: [LoopSnapshot]) -> [LoopSnapshot] {
    guard !incoming.isEmpty else { return [] }

    let previousByIdentity = Dictionary(uniqueKeysWithValues: previous.map { ($0.mergeIdentity, $0) })
    let previousActiveByTarget = Dictionary(
        uniqueKeysWithValues: previous
            .filter { !$0.isStopped && !$0.isPaused }
            .map { ($0.target, $0) }
    )
    return incoming.map { snapshot in
        let previous = previousByIdentity[snapshot.mergeIdentity]
            ?? (!snapshot.isStopped && !snapshot.isPaused ? previousActiveByTarget[snapshot.target] : nil)
        return mergeLoopSnapshot(previous: previous, incoming: snapshot)
    }
}

struct LoopSnapshotPresentation {
    let mergedSnapshots: [LoopSnapshot]
    let warnings: [String]
    let warningText: String
    let metaText: String
}

func loopSnapshotPresentation(
    previous: [LoopSnapshot],
    incoming: [LoopSnapshot],
    warnings: [String],
    failureMessage: String? = nil
) -> LoopSnapshotPresentation {
    let warningText = warnings
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let metaText: String
    if let failureMessage,
       !failureMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        metaText = failureMessage
    } else {
        metaText = incoming.isEmpty ? "循环: 0" : "循环: \(incoming.count)"
    }

    return LoopSnapshotPresentation(
        mergedSnapshots: mergeLoopSnapshots(previous: previous, incoming: incoming),
        warnings: warnings,
        warningText: warningText,
        metaText: metaText
    )
}

func optimisticLoopSnapshot(
    target: String,
    interval: String?,
    message: String?,
    forceSend: Bool?,
    existingSnapshots: [LoopSnapshot],
    now: TimeInterval = Date().timeIntervalSince1970
) -> LoopSnapshot {
    let existingSnapshot = existingSnapshots.first(where: { $0.target == target && !$0.isStopped && !$0.isPaused })
        ?? existingSnapshots.first(where: { $0.target == target })

    return LoopSnapshot(
        loopID: existingSnapshot?.loopID ?? "",
        target: target,
        loopDaemonRunning: true,
        intervalSeconds: interval ?? existingSnapshot?.intervalSeconds ?? "unknown",
        forceSend: forceSend ?? existingSnapshot?.isForceSendEnabled ?? false,
        message: message ?? existingSnapshot?.message ?? "",
        nextRunEpoch: now,
        stopped: false,
        stoppedReason: "",
        paused: false,
        failureCount: "0",
        failureReason: "",
        pauseReason: "",
        logPath: existingSnapshot?.logPath ?? "-",
        lastLogLine: ""
    )
}

func applyingOptimisticLoopSnapshot(
    _ snapshot: LoopSnapshot,
    to existingSnapshots: [LoopSnapshot]
) -> [LoopSnapshot] {
    var updatedSnapshots = existingSnapshots
    if let index = updatedSnapshots.firstIndex(where: { $0.target == snapshot.target && !$0.isStopped && !$0.isPaused }) {
        updatedSnapshots[index] = snapshot
    } else {
        updatedSnapshots.append(snapshot)
    }
    return updatedSnapshots
}

func parsedEpochTimeInterval(_ rawValue: Any?) -> TimeInterval {
    switch rawValue {
    case let value as TimeInterval:
        return value
    case let value as Int:
        return TimeInterval(value)
    case let value as Double:
        return value
    case let value as String:
        return TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    case let value as NSNumber:
        return value.doubleValue
    default:
        return 0
    }
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
        let lhsEpoch = lhs.updatedAtTimeInterval ?? 0
        let rhsEpoch = rhs.updatedAtTimeInterval ?? 0
        if lhsEpoch == rhsEpoch {
            return lhs.threadID < rhs.threadID
        }
        return lhsEpoch > rhsEpoch
    }
}

func overlaySessionSnapshots(existing: [SessionSnapshot], refreshed: [SessionSnapshot]) -> [SessionSnapshot] {
    guard !existing.isEmpty, !refreshed.isEmpty else { return existing }

    let refreshedByThreadID = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.threadID, $0) })
    return existing.map { refreshedByThreadID[$0.threadID] ?? $0 }
}

func resolveClaimedSessionRefreshSnapshots(claimed: [SessionSnapshot], refreshed: [SessionSnapshot]) -> [SessionSnapshot] {
    guard !claimed.isEmpty else { return [] }
    guard !refreshed.isEmpty else { return claimed }

    let refreshedByThreadID = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.threadID, $0) })
    return claimed.map { refreshedByThreadID[$0.threadID] ?? $0 }
}

func threadIDsNeedingPromptCacheInvalidation(previous: [SessionSnapshot], refreshed: [SessionSnapshot]) -> [String] {
    guard !refreshed.isEmpty else { return [] }

    let previousByThreadID = Dictionary(uniqueKeysWithValues: previous.map { ($0.threadID, $0) })
    var invalidated: [String] = []

    for snapshot in refreshed {
        guard let previousSnapshot = previousByThreadID[snapshot.threadID] else {
            invalidated.append(snapshot.threadID)
            continue
        }
        if previousSnapshot.updatedAtEpoch != snapshot.updatedAtEpoch || previousSnapshot.rolloutPath != snapshot.rolloutPath {
            invalidated.append(snapshot.threadID)
        }
    }

    return invalidated
}

struct SessionRefreshApplication {
    let resolvedClaimedSnapshots: [SessionSnapshot]
    let promptCacheInvalidationThreadIDs: [String]
    let overlaidSnapshots: [SessionSnapshot]
}

func sessionRefreshApplication(
    previous: [SessionSnapshot],
    claimed: [SessionSnapshot],
    refreshed: [SessionSnapshot]
) -> SessionRefreshApplication {
    SessionRefreshApplication(
        resolvedClaimedSnapshots: resolveClaimedSessionRefreshSnapshots(claimed: claimed, refreshed: refreshed),
        promptCacheInvalidationThreadIDs: threadIDsNeedingPromptCacheInvalidation(previous: previous, refreshed: refreshed),
        overlaidSnapshots: overlaySessionSnapshots(existing: previous, refreshed: refreshed)
    )
}

enum SessionTerminalState: String {
    case promptReady = "prompt_ready"
    case promptWithInput = "prompt_with_input"
    case queuedMessagesPending = "queued_messages_pending"
    case footerVisibleOnly = "footer_visible_only"
    case noVisiblePrompt = "no_visible_prompt"
    case busy = "busy"
    case unavailable = "unavailable"
    case archived = "archived"
    case unknown

    init(rawValueOrUnknown rawValue: String) {
        self = SessionTerminalState(rawValue: rawValue) ?? .unknown
    }
}

enum SessionRuntimeStatus: Equatable {
    case active
    case idleStable
    case interruptedIdle
    case idleWithResidualInput
    case idleWithQueuedMessages
    case busyTurnOpen
    case postFinalizing
    case busyWithStreamIssue
    case interruptedOrAborting
    case rolloutStale
    case idlePromptVisibleRolloutStale
    case queuedMessagesVisible
    case queuedMessagesPending
    case unknown
    case other(String)

    init(rawValue: String) {
        if rawValue.hasPrefix("active") {
            self = .active
            return
        }

        switch rawValue {
        case "idle_stable":
            self = .idleStable
        case "interrupted_idle":
            self = .interruptedIdle
        case "idle_with_residual_input":
            self = .idleWithResidualInput
        case "idle_with_queued_messages":
            self = .idleWithQueuedMessages
        case "busy_turn_open":
            self = .busyTurnOpen
        case "post_finalizing":
            self = .postFinalizing
        case "busy_with_stream_issue":
            self = .busyWithStreamIssue
        case "interrupted_or_aborting":
            self = .interruptedOrAborting
        case "rollout_stale":
            self = .rolloutStale
        case "idle_prompt_visible_rollout_stale":
            self = .idlePromptVisibleRolloutStale
        case "queued_messages_visible":
            self = .queuedMessagesVisible
        case "queued_messages_pending":
            self = .queuedMessagesPending
        case "unknown":
            self = .unknown
        default:
            self = .other(rawValue)
        }
    }
}

func localizedSessionStatusLabel(_ session: SessionSnapshot) -> String {
    if session.isArchived {
        return "已归档"
    }
    if session.terminalStateKind == .unavailable && shouldCollapseUnavailableTerminalIntoDisconnectedStatus(session) {
        return "断联"
    }

    switch session.statusKind {
    case .active:
        return "运行中"
    case .idleStable:
        return "空闲"
    case .interruptedIdle:
        return "中断后空闲"
    case .idleWithResidualInput:
        return "残留输入"
    case .idleWithQueuedMessages:
        return "消息排队"
    case .busyTurnOpen:
        return "运行中"
    case .postFinalizing:
        return "状态收尾"
    case .busyWithStreamIssue:
        return "流异常"
    case .interruptedOrAborting:
        return "中断中"
    case .rolloutStale, .idlePromptVisibleRolloutStale:
        return "状态滞后"
    case .queuedMessagesVisible, .queuedMessagesPending:
        return "消息排队"
    case .unknown:
        return "未知"
    case let .other(rawValue):
        return rawValue
    }
}

func shouldCollapseUnavailableTerminalIntoDisconnectedStatus(_ session: SessionSnapshot) -> Bool {
    guard session.terminalStateKind == .unavailable else { return false }
    switch session.statusKind {
    case .active, .busyTurnOpen, .postFinalizing, .busyWithStreamIssue, .interruptedOrAborting:
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
    case "footer_visible_only":
        return "仅见模型底栏"
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
    switch SendOutcomeStatus(rawValue: status) {
    case .success:
        return "成功"
    case .accepted:
        return "已受理"
    case .failed:
        return "失败"
    case let .other(rawValue):
        let status = rawValue
        return status.isEmpty ? "-" : status
    }
}

func localizedSendReason(_ reason: String) -> String {
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    switch SendOutcomeReason(rawValue: trimmed) {
    case .sent:
        return "已发送"
    case .forcedSent:
        return "强制发送成功"
    case .queuedPendingFeedback:
        return "消息已排队"
    case .verificationPending:
        return "等待确认"
    case .requestStillProcessing:
        return "请求仍在处理"
    case .requestAlreadyInflight:
        return "相同请求已在队列中"
    case .ambiguousTarget:
        return "目标对应多个同名 Session"
    case .ttyUnavailable:
        return "TTY 不可用"
    case .ttyFocusFailed:
        return "TTY 聚焦失败"
    case .terminalFocusScriptLaunchFailed:
        return "Terminal 聚焦脚本启动失败"
    case .keyboardEventSourceFailed:
        return "键盘事件源创建失败"
    case .keyboardEventCreationFailed:
        return "键盘事件创建失败"
    case .probeFailed:
        return "状态探测失败"
    case .notSendable:
        return "当前状态不可发送"
    case .sendInterrupted:
        return "发送过程被中断"
    case .sendUnverified:
        return "发送后未看到确认"
    case .sendUnverifiedAfterTTYFallback:
        return "TTY 回退后仍未确认"
    case .invalidRequest:
        return "请求内容无效"
    case .missingAccessibilityPermission:
        return "缺少辅助功能权限"
    case .stoppedByUser:
        return "已手动停止"
    case .startFailed:
        return "启动失败"
    case .loopConflictActiveSession:
        return "同一 Session 已有其他运行中的 Loop"
    case let .other(rawValue):
        return rawValue
    }
}

func localizedProbeStatus(_ status: String) -> String {
    switch status.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase {
    case "idle_stable":
        return "空闲稳定"
    case "interrupted_idle":
        return "中断后空闲"
    case "idle_with_residual_input":
        return "空闲但有残留输入"
    case "idle_with_queued_messages":
        return "空闲但消息排队"
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
    case "footer_visible_only":
        return "仅看到模型底栏"
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

func shouldAutoClearResidualInput(probeStatus: String, terminalState: String) -> Bool {
    probeStatus == "idle_with_residual_input" && terminalState == "prompt_with_input"
}

func isSendableProbeState(probeStatus: String, terminalState: String) -> Bool {
    if terminalState == "prompt_ready" && (probeStatus == "idle_stable" || probeStatus == "interrupted_idle") {
        return true
    }
    if shouldAutoClearResidualInput(probeStatus: probeStatus, terminalState: terminalState) {
        return true
    }
    return false
}

func shouldTreatAsQueuedAcceptance(probeStatus: Int32, terminalState: String, reason: String) -> Bool {
    guard probeStatus == 0 else { return false }
    if terminalState == "queued_messages_pending" {
        return true
    }
    return reason == "turn is complete, but queued messages are still visible in Terminal"
}

func isAmbiguousTargetDetail(_ detail: String) -> Bool {
    detail.contains("found multiple matching sessions for target") ||
    detail.contains("found multiple matching thread titles for target") ||
    detail.contains("found multiple matching Terminal ttys for target")
}

struct SendPreflightDecision {
    let canSend: Bool
    let failureReason: String
    let shouldClearResidualInput: Bool
}

struct UniqueTargetValidationPlan {
    let isValid: Bool
    let failureReason: String?
    let failureDetail: String
    let shouldShowAmbiguousAlert: Bool
    let shouldBeep: Bool
    let blockedLogText: String?
    let statusText: String?
}

func uniqueTargetValidationPlan(
    result: HelperCommandResult,
    target: String,
    actionName: String
) -> UniqueTargetValidationPlan {
    guard result.status != 0 else {
        return UniqueTargetValidationPlan(
            isValid: true,
            failureReason: nil,
            failureDetail: "",
            shouldShowAmbiguousAlert: false,
            shouldBeep: false,
            blockedLogText: nil,
            statusText: nil
        )
    }

    let detail = result.primaryDetail ?? ""
    if isAmbiguousTargetDetail(detail) {
        return UniqueTargetValidationPlan(
            isValid: false,
            failureReason: "ambiguous_target",
            failureDetail: detail,
            shouldShowAmbiguousAlert: true,
            shouldBeep: false,
            blockedLogText: "已阻止\(actionName)：目标 \(target) 匹配到多个 Session。",
            statusText: "目标不唯一"
        )
    }

    return UniqueTargetValidationPlan(
        isValid: false,
        failureReason: "start_failed",
        failureDetail: detail,
        shouldShowAmbiguousAlert: false,
        shouldBeep: true,
        blockedLogText: nil,
        statusText: "\(actionName)前校验失败"
    )
}

func evaluateSendPreflight(forceSend: Bool, tty: String, probeStatus: String, terminalState: String, detail: String) -> SendPreflightDecision {
    let normalizedTTY = tty.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedTTY.isEmpty else {
        return SendPreflightDecision(
            canSend: false,
            failureReason: isAmbiguousTargetDetail(detail) ? "ambiguous_target" : "tty_unavailable",
            shouldClearResidualInput: false
        )
    }

    let shouldClearResidualInput = !forceSend && shouldAutoClearResidualInput(probeStatus: probeStatus, terminalState: terminalState)
    if forceSend || isSendableProbeState(probeStatus: probeStatus, terminalState: terminalState) {
        return SendPreflightDecision(
            canSend: true,
            failureReason: "",
            shouldClearResidualInput: shouldClearResidualInput
        )
    }

    return SendPreflightDecision(
        canSend: false,
        failureReason: "not_sendable",
        shouldClearResidualInput: false
    )
}

func sendProbeFailureReason(detail: String) -> String {
    isAmbiguousTargetDetail(detail) ? "ambiguous_target" : "probe_failed"
}

struct ParsedSendRequestPayload {
    let target: String
    let message: String
    let timeoutSeconds: NSNumber
    let forceSend: Bool
}

func parseSendRequestPayload(_ payload: [String: Any]) -> ParsedSendRequestPayload? {
    guard let target = payload["target"] as? String,
          let message = payload["message"] as? String,
          let timeoutSeconds = payload["timeout_seconds"] as? NSNumber else {
        return nil
    }

    return ParsedSendRequestPayload(
        target: target,
        message: message,
        timeoutSeconds: timeoutSeconds,
        forceSend: payload["force_send"] as? Bool ?? false
    )
}

func makeSendRequestResultPayload(
    status: String,
    reason: String,
    target: String,
    forceSend: Bool,
    detail: String,
    probeStatus: String? = nil,
    terminalState: String? = nil
) -> [String: Any] {
    var payload: [String: Any] = [
        "status": status,
        "reason": reason,
        "target": target,
        "force_send": forceSend,
        "detail": detail
    ]
    if let probeStatus {
        payload["probe_status"] = probeStatus
    }
    if let terminalState {
        payload["terminal_state"] = terminalState
    }
    return payload
}

struct SendVerificationDecision {
    let status: String
    let reason: String
    let probeStatus: String
    let terminalState: String

    var statusKind: SendOutcomeStatus {
        SendOutcomeStatus(rawValue: status)
    }

    var reasonKind: SendOutcomeReason {
        SendOutcomeReason(rawValue: reason)
    }
}

func evaluateSendVerificationDecision(
    verificationSucceeded: Bool,
    forceSend: Bool,
    initialProbeStatus: String,
    initialTerminalState: String,
    verificationProbeStatusCode: Int32,
    verificationProbeStatus: String,
    verificationReason: String,
    verificationTerminalState: String
) -> SendVerificationDecision {
    if verificationSucceeded {
        return SendVerificationDecision(
            status: "success",
            reason: forceSend ? "forced_sent" : "sent",
            probeStatus: initialProbeStatus,
            terminalState: initialTerminalState
        )
    }

    if shouldTreatAsQueuedAcceptance(
        probeStatus: verificationProbeStatusCode,
        terminalState: verificationTerminalState,
        reason: verificationReason
    ) {
        return SendVerificationDecision(
            status: "accepted",
            reason: "queued_pending_feedback",
            probeStatus: verificationProbeStatus,
            terminalState: verificationTerminalState
        )
    }

    return SendVerificationDecision(
        status: "accepted",
        reason: "verification_pending",
        probeStatus: verificationProbeStatus,
        terminalState: verificationTerminalState
    )
}

struct ParsedLoopOutcome {
    let status: String
    let reason: String
    let probeStatus: String
    let terminalState: String
    let line: String

    var statusKind: SendOutcomeStatus {
        SendOutcomeStatus(rawValue: status)
    }

    var reasonKind: SendOutcomeReason {
        SendOutcomeReason(rawValue: reason)
    }
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
    switch loop.failureReasonKind {
    case let .other(rawValue):
        return rawValue
    default:
        return loop.failureReason.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
    }
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
    case "idle_with_queued_messages":
        return "消息排队中"
    default:
        break
    }

    switch terminalState {
    case "queued_messages_pending":
        return "消息排队中"
    case "footer_visible_only":
        return "仅见模型底栏"
    case "no_visible_prompt":
        return "未看到可用提示符"
    case "unavailable":
        return "TTY 不可用"
    default:
        return "当前状态不可发送"
    }
}

func loopResultLabel(_ loop: LoopSnapshot) -> String {
    if loop.isStopped {
        return "已停止"
    }
    if loop.isPaused {
        return "已暂停"
    }

    let outcome = loopLastOutcome(loop)
    let normalizedLine = outcome.line.localizedLowercase
    let fallbackFailureReason = loopFailureReasonFallback(loop)

    if outcome.statusKind == .success {
        return "成功"
    }
    if outcome.statusKind == .accepted {
        if outcome.reasonKind == .verificationPending {
            return "等待确认"
        }
        if outcome.reasonKind == .queuedPendingFeedback {
            return "消息排队中"
        }
        return "已受理"
    }
    if outcome.reasonKind == .notSendable {
        return detailedNotSendableLabel(probeStatus: outcome.probeStatus, terminalState: outcome.terminalState)
    }
    if outcome.reasonKind == .ttyUnavailable {
        return "TTY 不可用"
    }
    if outcome.reasonKind == .ttyFocusFailed {
        return "TTY 聚焦失败"
    }
    if outcome.reasonKind == .ambiguousTarget {
        return "目标不唯一"
    }
    if normalizedLine.contains("辅助功能权限") || outcome.reasonKind == .missingAccessibilityPermission {
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
    if outcome.statusKind == .failed || normalizedLine.contains("status=failed") {
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
    if loop.isStopped {
        return "停止"
    }
    if loop.isPaused {
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
    if loop.isStopped {
        return localizedSendReason(loop.stoppedReason)
    }
    if loop.isPaused {
        let reason = loop.pauseReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? loop.failureReason : loop.pauseReason
        return localizedSendReason(reason)
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

func loopSelectionIdentifier(_ loop: LoopSnapshot) -> String {
    let trimmedLoopID = loop.loopID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedLoopID.isEmpty {
        return "id:\(trimmedLoopID)"
    }
    return "target:\(loop.target)"
}

func formattedLoopTargetDisplayValue(loop: LoopSnapshot, allLoops: [LoopSnapshot]) -> String {
    guard allLoops.filter({ $0.target == loop.target }).count > 1 else {
        return loop.target
    }
    let trimmedLoopID = loop.loopID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedLoopID.isEmpty else {
        return loop.target
    }
    return "\(loop.target) #\(trimmedLoopID.prefix(8))"
}

func formattedLoopTargetToolTip(loop: LoopSnapshot, allLoops: [LoopSnapshot]) -> String {
    let trimmedLoopID = loop.loopID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedLoopID.isEmpty else {
        return loop.target
    }
    guard allLoops.filter({ $0.target == loop.target }).count > 1 else {
        return loop.target
    }
    return "\(loop.target)\nloop_id: \(trimmedLoopID)"
}

func formattedLoopTableCellValue(
    identifier: String,
    loop: LoopSnapshot,
    allLoops: [LoopSnapshot],
    formatEpoch: (TimeInterval) -> String
) -> String {
    switch identifier {
    case "state":
        return "● \(loopStateLabel(loop))"
    case "result":
        return "● \(loopResultLabel(loop))"
    case "reason":
        return loopResultReasonLabel(loop)
    case "target":
        return formattedLoopTargetDisplayValue(loop: loop, allLoops: allLoops)
    case "interval":
        return "\(loop.intervalSeconds)s"
    case "forceSend":
        return loop.isForceSendEnabled ? "force" : "idle"
    case "nextRun":
        if loop.isStopped {
            return "-"
        }
        return formatEpoch(loop.nextRunEpoch)
    case "message":
        return loop.message
    case "lastLog":
        return loop.lastLogLine
    default:
        return ""
    }
}

func formattedSessionTableCellValue(
    identifier: String,
    session: SessionSnapshot,
    formatEpoch: (TimeInterval) -> String
) -> String {
    switch identifier {
    case "name":
        return sessionActualName(session)
    case "type":
        return sessionTypeLabel(session)
    case "provider":
        return sessionProviderDisplayValue(session)
    case "threadID":
        return session.threadID
    case "status":
        return "● \(localizedSessionStatusLabel(session))"
    case "terminalState":
        return sessionTerminalDisplayValue(session)
    case "tty":
        return sessionTTYDisplayValue(session)
    case "updatedAt":
        return formatEpoch(session.updatedAtEpoch)
    case "reason":
        return localizedSessionReason(session.reason)
    default:
        return ""
    }
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

    let successCount = results.filter { $0.statusKind == .success }.count
    let acceptedCount = results.filter { $0.statusKind == .accepted }.count
    let failedResults = results.filter { $0.statusKind == .failed }
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

func formattedLoopOccupancyText(loops: [LoopSnapshot], formatEpoch: (TimeInterval) -> String) -> String {
    guard !loops.isEmpty else {
        return "相关 Loop\n无"
    }

    return (["相关 Loop"] + loops.map { loop in
        let nextRun = loop.isStopped ? "-" : formatEpoch(loop.nextRunEpoch)
        let reason = loopResultReasonLabel(loop)
        var lines = [
            "Target: \(loop.target)",
            "状态: \(loopStateLabel(loop)) | 结果: \(loopResultLabel(loop))",
            "间隔: \(loop.intervalSeconds)s | 模式: \(loop.isForceSendEnabled ? "force" : "idle") | 下次: \(nextRun)"
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

enum StatusPresentationTone: Equatable {
    case neutralPrimary
    case neutralSecondary
    case progress
    case failure
    case warning
    case success
}

struct VisibleStatusSegment: Equatable {
    let key: String
    let text: String
}

func resolvedStatusPresentationTone(text: String, key: String) -> StatusPresentationTone {
    if isProgressStatusText(text) {
        return .progress
    }
    if isFailureStatusText(text) {
        return .failure
    }
    if isWarningStatusText(text) {
        return .warning
    }
    if isSuccessStatusText(text) {
        return .success
    }
    return key == "general" ? .neutralPrimary : .neutralSecondary
}

func statusAutoClearDelay(text: String, key: String) -> TimeInterval? {
    if isProgressStatusText(text) {
        return nil
    }

    switch key {
    case "send":
        if isFailureStatusText(text) {
            return 12
        }
        if text.contains("待确认") || text.contains("已受理") || text.contains("已排队") {
            return 9
        }
        if isSuccessStatusText(text) {
            return 5
        }
        return 7
    case "action":
        if isFailureStatusText(text) {
            return 10
        }
        if isWarningStatusText(text) {
            return 7
        }
        if isSuccessStatusText(text) {
            return 4
        }
        return 6
    case "scan":
        if isFailureStatusText(text) {
            return 10
        }
        if isSuccessStatusText(text) {
            return 4
        }
        return 6
    case "general":
        if isFailureStatusText(text) {
            return 10
        }
        if isWarningStatusText(text) {
            return 8
        }
        return 4
    default:
        if isFailureStatusText(text) {
            return 10
        }
        if isSuccessStatusText(text) {
            return 4
        }
        return 6
    }
}

func resolvedVisibleStatusSegment(segments: [String: String]) -> VisibleStatusSegment? {
    let orderedKeys = ["send", "action", "scan", "general"]
    if let winningKey = orderedKeys.first(where: { segments[$0]?.isEmpty == false }),
       let winningText = segments[winningKey] {
        return VisibleStatusSegment(key: winningKey, text: winningText)
    }

    if let fallback = segments
        .filter({ !$0.value.isEmpty && !orderedKeys.contains($0.key) })
        .sorted(by: { $0.key < $1.key })
        .first {
        return VisibleStatusSegment(key: fallback.key, text: fallback.value)
    }

    return nil
}

func defaultVisibleStatusText() -> String {
    "Ready"
}

private func isProgressStatusText(_ text: String) -> Bool {
    text.contains("执行中") || text.contains("保存名称中") || text.contains("归档 Session 中") ||
    text.contains("恢复归档中") || text.contains("彻底删除中") || text.contains("读取已归档 session 中")
}

private func isFailureStatusText(_ text: String) -> Bool {
    text.contains("失败") || text.contains("缺少辅助功能权限") || text.contains("目标不唯一")
}

private func isWarningStatusText(_ text: String) -> Bool {
    text.contains("已受理") || text.contains("待确认") || text.contains("已排队") ||
    text.contains("已取消") || text.contains("请选择") || text.contains("无效")
}

private func isSuccessStatusText(_ text: String) -> Bool {
    text.contains("完成") || text.contains("已加载") || text.contains("已保存") ||
    text.contains("已清空") || text.contains("已填入") || text.contains("Ready") ||
    text.contains("已停止")
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

enum SessionStatusRefreshResultKind {
    case success
    case failure
    case partialFailure

    var text: String {
        switch self {
        case .success:
            return "刷新状态完成"
        case .failure:
            return "刷新状态失败"
        case .partialFailure:
            return "刷新状态部分失败"
        }
    }
}

func sessionStatusRefreshResultKind(failedCount: Int, totalCount: Int) -> SessionStatusRefreshResultKind {
    if failedCount == 0 {
        return .success
    }
    if failedCount == totalCount {
        return .failure
    }
    return .partialFailure
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

func sessionStatusInitialMetaText() -> String {
    "点击“检测会话”加载 session 列表。"
}

func detectSessionButtonTitle(isRunning: Bool) -> String {
    isRunning ? "停止检测" : "检测会话"
}

func sessionStatusFillTargetStatusText(value: String) -> String {
    "已从 Session Status 填入 \(value)"
}

func sessionStatusFillTargetLogText(value: String, usedName: Bool) -> String {
    usedName ? "Session Status 双击填入 Name: \(value)" : "Session Status 双击填入 ID: \(value)"
}

func archivedSessionRestoreTooltipText() -> String {
    "恢复当前已归档 session"
}

func archivedSessionRenamePlaceholderText() -> String {
    "已归档 session 需先恢复后再改名"
}

func archivedSessionRenameBlockedLogText() -> String {
    "已归档 session 不能直接改名，请先恢复归档。"
}

func archivedSessionCompletionLogText(threadID: String) -> String {
    "已归档 session: \(threadID)"
}

func archivedSessionRestoreSelectionRequiredLogText() -> String {
    "请先选择一条已归档 session，再恢复。"
}

func archivedSessionRestoreSelectionRequiredStatusText() -> String {
    "请选择已归档 session"
}

func sessionRenameTooltipText() -> String {
    "保存当前 session 的名称"
}

func sessionRenamePlaceholderText(isArchived: Bool) -> String {
    isArchived ? archivedSessionRenamePlaceholderText() : "输入新名称，留空可恢复为未 rename 状态"
}

func sessionRenameSelectionRequiredLogText() -> String {
    "请先选择一条 session，再保存名称。"
}

func sessionRenameArchivedBlockedStatusText() -> String {
    "请先恢复归档"
}

func sessionRenameRunningStatusText() -> String {
    "保存名称中…"
}

func sessionRenameStartLogText(threadID: String, newName: String) -> String {
    "执行 保存名称: thread_id=\(threadID) name=\(newName.isEmpty ? "<empty>" : newName)"
}

func sessionRenameCompletionStatusText() -> String {
    "保存名称完成"
}

func sessionRenameCompletionLogText(newName: String) -> String {
    newName.isEmpty ? "已清空名称，恢复为未 rename 状态。" : "已保存名称: \(newName)"
}

func sessionRenameFailureStatusText() -> String {
    "保存名称失败"
}

func sessionArchiveSelectionRequiredLogText() -> String {
    "请先选择一条 session，再归档。"
}

func sessionArchiveAlreadyArchivedLogText() -> String {
    "这条 session 已经归档。"
}

func sessionArchiveAlreadyArchivedStatusText() -> String {
    "该 session 已归档"
}

func sessionArchiveAlertTitle() -> String {
    "归档这个 Session？"
}

func sessionArchiveAlertText(threadID: String, target: String, matchingLoopTargets: [String]) -> String {
    var informativeText = """
    这会调用 Codex 原生的 thread/archive。
    归档后该 session 会从当前非归档列表中消失，但后续仍可恢复。

    Session ID: \(threadID)
    Target: \(target)
    """
    if !matchingLoopTargets.isEmpty {
        informativeText += """

        
        警告：当前有循环任务仍可能指向这个 session：
        \(matchingLoopTargets.joined(separator: ", "))
        归档后这些循环不会自动停止。
        """
    }
    return informativeText
}

func sessionArchiveRunningStatusText() -> String {
    "归档 Session 中…"
}

func sessionArchiveStartLogText(threadID: String) -> String {
    "执行 归档 Session: thread_id=\(threadID)"
}

func sessionArchiveCompletionStatusText() -> String {
    "归档 Session 完成"
}

func sessionArchiveFailureStatusText() -> String {
    "归档 Session 失败"
}

func sessionRestoreNonArchivedSelectionLogText() -> String {
    "当前选择的 session 不在已归档列表中。"
}

func sessionRestoreAlertTitle() -> String {
    "恢复这个已归档 Session？"
}

func sessionRestoreAlertText(threadID: String, name: String) -> String {
    """
    这会调用 Codex 原生的 thread/unarchive。
    恢复后该 session 会重新回到普通 session 列表中。

    Session ID: \(threadID)
    Name: \(name)
    """
}

func sessionRestoreRunningStatusText() -> String {
    "恢复归档中…"
}

func sessionRestoreStartLogText(threadID: String) -> String {
    "执行 恢复归档: thread_id=\(threadID)"
}

func sessionRestoreCompletionStatusText() -> String {
    "恢复归档完成"
}

func sessionRestoreCompletionLogText(threadID: String) -> String {
    "已恢复归档 session: \(threadID)"
}

func sessionRestoreFailureStatusText() -> String {
    "恢复归档失败"
}

func sessionDeleteAlertTitle() -> String {
    "彻底删除这个 Session？"
}

func sessionDeleteAlertText(
    threadID: String,
    name: String,
    rolloutPath: String,
    stateLogRows: Int,
    dynamicToolRows: Int,
    stage1OutputRows: Int,
    logsDBRows: Int,
    sessionIndexEntries: Int,
    rolloutExists: Bool,
    parentThreadID: String,
    directChildCount: Int,
    descendantCount: Int,
    matchingLoopTargets: [String]
) -> String {
    var informativeText = """
    这是本地不可恢复删除，不是 Codex 当前公开的原生 archive/unarchive 语义。
    本次删除计划会按固定步骤处理：
    1. 删除 state_5.sqlite 中的 thread 主记录与相关扩展状态
    2. 删除日志数据库中的 thread 日志
    3. 删除 session_index.jsonl 中对应的 rename/name 记录
    4. 删除当前 rollout 文件并尝试清理空目录

    已知风险：
    - 目前没有公开的 Codex 原生永久删除 API，这是一种本地硬删除
    - 删除后通常无法恢复
    - 如果中途失败，界面会显示失败步骤和 repair 提示，不再静默半成功

    Session ID: \(threadID)
    Name: \(name)
    当前路径: \(rolloutPath.isEmpty ? "-" : rolloutPath)

    本次预计删除内容：
    - state_5.sqlite thread 日志行: \(stateLogRows)
    - state_5.sqlite 动态工具行: \(dynamicToolRows)
    - state_5.sqlite stage1 输出行: \(stage1OutputRows)
    - logs 数据库日志行: \(logsDBRows)
    - session_index 记录数: \(sessionIndexEntries)
    - rollout 文件存在: \(rolloutExists ? "是" : "否")
    """
    if parentThreadID != "-" {
        informativeText += """


        提示：这条 session 有父 agent：
        \(parentThreadID)
        默认不会删除父 agent。
        """
    }
    if directChildCount > 0 || descendantCount > 0 {
        informativeText += """


        这条 session 下还有子 agent 会话。
        直接子会话数: \(directChildCount)
        递归子会话总数: \(descendantCount)
        """
    }
    if !matchingLoopTargets.isEmpty {
        informativeText += """

        
        警告：当前有循环任务仍可能指向这个 session：
        \(matchingLoopTargets.joined(separator: ", "))
        删除后这些循环不会自动停止，后续只会继续失败或延期。
        """
    }
    return informativeText
}

func ambiguousTargetAlertTitle() -> String {
    "目标不唯一"
}

func ambiguousTargetAlertText(actionName: String, detail: String) -> String {
    let normalizedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    return "存在多个同名 Session，无法直接\(actionName)。请改用 Session ID，或先为它们设置不同名称。\n\n\(normalizedDetail)"
}

func runtimePermissionAlertTitle(actionName: String) -> String {
    "\(actionName)前发现本地权限问题"
}

func runtimePermissionAlertText(
    actionName: String,
    runtimeDirectoryPath: String,
    userLoopStateDirectoryPath: String,
    legacyLoopStateDirectoryPath: String,
    detail: String
) -> String {
    """
    Codex Taskmaster 无法正常读写本地运行目录，因此这次\(actionName)不会继续执行。

    建议检查这些目录是否属于当前用户并且可写：
    - `\(runtimeDirectoryPath)`
    - `\(userLoopStateDirectoryPath)`
    - `\(legacyLoopStateDirectoryPath)`

    如果之前曾用 `sudo` 或其他用户启动过相关脚本，最常见的修复方式是把 `~/.codex-terminal-sender` 重新改回当前用户属主。

    底层错误：
    \(detail.trimmingCharacters(in: .whitespacesAndNewlines))
    """
}

func sessionActionBlockedAlertTitle(actionLabel: String, ambiguous: Bool) -> String {
    ambiguous ? "无法\(actionLabel)目标不唯一的活跃 Session" : "无法\(actionLabel)仍在运行的 Session"
}

func sessionActionBlockedAlertText(actionLabel: String, session: SessionSnapshot, detail: String, ambiguous: Bool) -> String {
    let sessionName = sessionActualName(session)
    let nameLine = sessionName.isEmpty ? "-" : sessionName
    let cleanedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    let defaultDetail = ambiguous
        ? "这个 session 仍然对应多个活跃 Terminal/Codex 目标，当前无法安全\(actionLabel)。请先关闭重复打开的 session，再重试。"
        : "这个 session 仍然有活跃的 Terminal/Codex 进程，当前不允许\(actionLabel)。请先关闭对应 Terminal 标签页或结束该 session，再重试。"
    return """
    Session ID: \(session.threadID)
    Name: \(nameLine)

    \(cleanedDetail.isEmpty ? defaultDetail : cleanedDetail)
    """
}

func loopConflictAlertTitle() -> String {
    "检测到已有循环"
}

func loopConflictAlertText(target: String, conflicts: [LoopSnapshot]) -> String {
    let conflictList = conflicts.map(\.target).joined(separator: "、")
    return "目标 \(target) 已存在运行中的循环：\(conflictList)。为避免重复发送，只能保留一个循环。是否先停止旧循环，再启动新的循环？"
}

func sessionDeleteSelectionRequiredLogText() -> String {
    "请先选择一条 session，再删除。"
}

func sessionDeletePlanLoadingStatusText() -> String {
    "读取删除计划中…"
}

func sessionDeletePlanLoadingFailureStatusText() -> String {
    "读取删除计划失败"
}

func sessionDeletePlanLoadingFailureLogText() -> String {
    "读取删除计划失败：helper 未返回 thread-delete-plan。"
}

func sessionDeleteCancelledStatusText() -> String {
    "彻底删除已取消"
}

func sessionDeleteRunningStatusText() -> String {
    "彻底删除中…"
}

func sessionDeleteStartLogText(threadIDs: [String]) -> String {
    "执行 彻底删除: thread_ids=\(threadIDs.joined(separator: ","))"
}

func sessionDeleteCompletionStatusText() -> String {
    "彻底删除完成"
}

func sessionDeleteCompletionLogText(detail: String, deletedThreadIDs: [String]) -> String {
    detail.isEmpty ? "已彻底删除 session: \(deletedThreadIDs.joined(separator: ","))" : "已彻底删除 session: \(detail)"
}

func sessionDeleteFailureStatusText() -> String {
    "彻底删除失败"
}

func sessionProviderMigrationSelectionRequiredLogText() -> String {
    "请先选择一条 session，再迁移 provider。"
}

func sessionProviderLoadingStatusText() -> String {
    "读取当前 Provider 中…"
}

func sessionProviderMissingLogText() -> String {
    "未能从 ~/.codex/config.toml 读取当前 model_provider。"
}

func sessionProviderMissingStatusText() -> String {
    "当前 provider 未配置"
}

func sessionProviderMigrationPlanLoadingStatusText() -> String {
    "读取迁移计划中…"
}

func sessionProviderMigrationPlanFailureLogText() -> String {
    "读取 session provider 迁移计划失败。"
}

func sessionProviderMigrationPlanFailureStatusText() -> String {
    "读取迁移计划失败"
}

func sessionProviderMigrationNoopAlertTitle() -> String {
    "无需迁移"
}

func sessionProviderMigrationNoopAlertText(
    currentProviderDisplay: String,
    targetProvider: String,
    familyCount: Int
) -> String {
    """
    当前选中会话及其相关会话的 Provider 已经是目标值。

    当前 Provider: \(currentProviderDisplay)
    目标 Provider: \(targetProvider)
    相关会话数: \(familyCount)
    """
}

func sessionProviderMigrationNoopLogText(targetProvider: String) -> String {
    "迁移已取消：当前会话及相关会话的 provider 已经是 \(targetProvider)。"
}

func noMigrationNeededStatusText() -> String {
    "无需迁移"
}

func sessionProviderMigrationRelatedAlertTitle() -> String {
    "迁移相关 Session 到当前 Provider？"
}

func sessionProviderMigrationRelatedAlertText(
    targetProvider: String,
    currentProviderDisplay: String,
    threadID: String,
    typeLabel: String,
    isSubagent: Bool,
    familyCount: Int,
    familyMigrateNeeded: Int
) -> String {
    """
    当前 Provider: \(targetProvider)
    选中 Session 当前 Provider: \(currentProviderDisplay)
    Session ID: \(threadID)
    Type: \(typeLabel)

    这条 session \(isSubagent ? "属于子 agent 会话" : "存在子 agent 会话")。
    相关会话总数: \(familyCount)
    需要迁移的相关会话数: \(familyMigrateNeeded)

    你可以只迁移当前这一条，也可以递归迁移整组相关 session。
    """
}

func sessionProviderMigrationCurrentAlertTitle() -> String {
    "迁移当前 Session 到当前 Provider？"
}

func sessionProviderMigrationCurrentAlertText(
    targetProvider: String,
    currentProviderDisplay: String,
    threadID: String,
    typeLabel: String
) -> String {
    """
    当前 Provider: \(targetProvider)
    选中 Session 当前 Provider: \(currentProviderDisplay)
    Session ID: \(threadID)
    Type: \(typeLabel)
    """
}

func sessionProviderMigrationCancelledStatusText() -> String {
    "迁移 Session Provider 已取消"
}

func sessionProviderMigrationRunningStatusText() -> String {
    "迁移 Session Provider 中…"
}

func sessionProviderMigrationStartLogText(threadID: String, targetProvider: String, includeFamily: Bool) -> String {
    "执行 迁移 Session Provider: thread_id=\(threadID) target_provider=\(targetProvider) scope=\(includeFamily ? "family" : "current")"
}

func sessionProviderMigrationCompletionStatusText() -> String {
    "迁移 Session Provider 完成"
}

func sessionProviderMigrationFailureStatusText() -> String {
    "迁移 Session Provider 失败"
}

func allSessionProviderMigrationPlanFailureLogText() -> String {
    "读取全部 session provider 迁移计划失败。"
}

func allSessionProviderMigrationNoopAlertText(targetProvider: String, totalThreads: Int) -> String {
    """
    本地所有会话的 Provider 已经是目标值。

    目标 Provider: \(targetProvider)
    会话总数: \(totalThreads)
    """
}

func allSessionProviderMigrationNoopLogText(targetProvider: String) -> String {
    "全部迁移已取消：所有 session 的 provider 已经是 \(targetProvider)。"
}

func allSessionProviderMigrationAlertTitle() -> String {
    "将所有 Session 迁移到当前 Provider？"
}

func allSessionProviderMigrationAlertText(targetProvider: String, totalThreads: Int, migrateNeeded: Int) -> String {
    """
    当前 Provider: \(targetProvider)
    本地 Session 总数: \(totalThreads)
    需要迁移的 Session 数: \(migrateNeeded)

    这会直接改写本地 state_5.sqlite 中的 threads.model_provider。
    不会改写 source，也不会重写 rollout 文件。
    """
}

func allSessionProviderMigrationCancelledStatusText() -> String {
    "迁移全部 Session Provider 已取消"
}

func allSessionProviderMigrationRunningStatusText() -> String {
    "迁移全部 Session Provider 中…"
}

func allSessionProviderMigrationStartLogText(targetProvider: String) -> String {
    "执行 全部迁移 Session Provider: target_provider=\(targetProvider)"
}

func allSessionProviderMigrationCompletionStatusText() -> String {
    "迁移全部 Session Provider 完成"
}

func allSessionProviderMigrationFailureStatusText() -> String {
    "迁移全部 Session Provider 失败"
}

func sessionProviderMigrationButtonTitle() -> String {
    "迁移当前会话"
}

func allSessionProviderMigrationButtonTitle() -> String {
    "迁移全部会话"
}

func sessionProviderMigrationTooltipText() -> String {
    "将当前选中 session 迁移到当前 config.toml 中的 model_provider"
}

func allSessionProviderMigrationTooltipText() -> String {
    "将本地所有 session 迁移到当前 config.toml 中的 model_provider"
}

func sessionSelectionRequiredStatusText() -> String {
    "请选择一个 session"
}

func loopSelectionRequiredLogText() -> String {
    "请先在 Active Loops 中选择一条循环任务。"
}

func loopSelectionRequiredStatusText() -> String {
    "请选择一个循环任务"
}

func stoppedLoopBlockedLogText() -> String {
    "当前选中的循环已经是停止状态。"
}

func stoppedLoopBlockedStatusText() -> String {
    "当前循环已停止"
}

func resumeLoopBlockedLogText() -> String {
    "当前选中的循环既不是暂停状态，也不是停止状态。"
}

func resumeLoopBlockedStatusText() -> String {
    "当前循环不可恢复"
}

func accessibilityPermissionDeniedStatusText() -> String {
    "缺少辅助功能权限"
}

func emptyMessageRequiredLogText() -> String {
    "输出内容不能为空。"
}

func emptyMessageRequiredStatusText() -> String {
    "请填写输出内容"
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
