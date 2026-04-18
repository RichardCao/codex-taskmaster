import AppKit
import ApplicationServices

struct SendRequestProcessorCallbacks {
    let logActivity: (String) -> Void
    let updateSendStatus: (_ kind: String, _ target: String, _ reason: String, _ probeStatus: String?, _ terminalState: String?, _ color: NSColor) -> Void
    let requestDidFinish: () -> Void
}

protocol PlatformSendAdapter {
    func ensurePermission(prompt: Bool) -> Bool
    func sendMessage(toTTYPath ttyPath: String, message: String, clearExistingInput: Bool, logger: ((String) -> Void)?) throws
}

private struct FrontmostAppContext {
    let bundleID: String
    let terminalTTY: String?
    let capturedAt: Date?
}

private struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
    let changeCount: Int
}

private struct LiveTTYResolution {
    let tty: String?
    let detail: String
    let changed: Bool
}

final class MacOSTerminalSendAdapter: PlatformSendAdapter {
    func ensurePermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func sendMessage(toTTYPath ttyPath: String, message: String, clearExistingInput: Bool, logger: ((String) -> Void)?) throws {
        guard ensurePermission(prompt: true) else {
            throw NSError(
                domain: "CodexTaskmaster",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey: "Codex Taskmaster 没有辅助功能权限，无法发送按键",
                    "sendReason": "missing_accessibility_permission"
                ]
            )
        }

        let currentAppBundleID = Bundle.main.bundleIdentifier ?? ""
        let previousContext = captureFrontmostContext(currentAppBundleID: currentAppBundleID)
        let contextAgeSeconds: String
        if let capturedAt = previousContext.capturedAt {
            contextAgeSeconds = String(Int(max(0, Date().timeIntervalSince(capturedAt))))
        } else {
            contextAgeSeconds = "-"
        }
        logger?(
            "focus-debug: send-begin target_tty=\(normalizeTTYIdentifier(ttyPath)) previous_bundle=\(previousContext.bundleID.isEmpty ? "-" : previousContext.bundleID) previous_terminal_tty=\(normalizeTTYIdentifier(previousContext.terminalTTY ?? "").isEmpty ? "-" : normalizeTTYIdentifier(previousContext.terminalTTY ?? "")) previous_context_age_seconds=\(contextAgeSeconds)"
        )
        try focusTerminalWindow(for: ttyPath)
        defer {
            restoreFocusAfterTerminalSend(
                previousContext: previousContext,
                targetTTY: ttyPath,
                logger: logger
            )
        }

        if clearExistingInput {
            try clearPromptInputIfNeeded()
        }

        let pasteboardSnapshot = snapshotGeneralPasteboard()
        var temporaryPasteboardChangeCount: Int?
        defer {
            _ = restoreGeneralPasteboard(pasteboardSnapshot, expectedChangeCount: temporaryPasteboardChangeCount)
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
        temporaryPasteboardChangeCount = NSPasteboard.general.changeCount

        usleep(70_000)
        try postKey(9, flags: .maskCommand)
        usleep(110_000)
        try postKey(36)
        usleep(180_000)
    }

    private func focusDebugLog(_ logger: ((String) -> Void)?, _ message: String) {
        logger?("focus-debug: \(message)")
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw NSError(
                domain: "CodexTaskmaster",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "无法创建键盘事件源",
                    "sendReason": "keyboard_event_source_failed"
                ]
            )
        }
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw NSError(
                domain: "CodexTaskmaster",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "无法创建键盘事件",
                    "sendReason": "keyboard_event_creation_failed"
                ]
            )
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func snapshotGeneralPasteboard() -> PasteboardSnapshot {
        let pasteboard = NSPasteboard.general
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var snapshot: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    snapshot[type] = data
                }
            }
            return snapshot
        }
        return PasteboardSnapshot(items: items, changeCount: pasteboard.changeCount)
    }

    @discardableResult
    private func restoreGeneralPasteboard(_ snapshot: PasteboardSnapshot, expectedChangeCount: Int?) -> Bool {
        let pasteboard = NSPasteboard.general
        if let expectedChangeCount, pasteboard.changeCount != expectedChangeCount {
            return false
        }

        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else {
            return true
        }

        let restoredItems = snapshot.items.map { dataByType -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dataByType {
                item.setData(data, forType: type)
            }
            return item
        }
        return pasteboard.writeObjects(restoredItems)
    }

    private func focusTerminalWindow(for ttyPath: String) throws {
        let script = """
        on run argv
          set targetTTY to item 1 of argv
          repeat with attempt from 1 to 6
            tell application "Terminal" to activate
            delay 0.05

            tell application "Terminal"
              repeat with w in windows
                try
                  repeat with t in tabs of w
                    if (tty of t) is equal to targetTTY then
                      set selected tab of w to t
                      set index of w to 1
                      exit repeat
                    end if
                  end repeat
                end try
              end repeat
            end tell

            delay 0.10

            tell application "System Events"
              try
                set frontAppName to name of first application process whose frontmost is true
              on error
                set frontAppName to ""
              end try
            end tell

            if frontAppName is equal to "Terminal" then
              tell application "Terminal"
                try
                  if (tty of selected tab of front window) is equal to targetTTY then
                    return "ok"
                  end if
                end try
              end tell
            end if
          end repeat
          error "could not focus Terminal window for " & targetTTY
        end run
        """

        do {
            let result = try SubprocessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-", ttyPath],
                standardInputData: script.data(using: .utf8)
            )
            guard result.terminationStatus == 0 else {
                let errText = result.primaryDetail ?? "聚焦 Terminal 失败"
                throw NSError(
                    domain: "CodexTaskmaster",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey: errText,
                        "sendReason": "tty_focus_failed"
                    ]
                )
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == "CodexTaskmaster" {
                throw nsError
            }
            throw NSError(
                domain: "CodexTaskmaster",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "启动 Terminal 聚焦脚本失败: \(error.localizedDescription)",
                    "sendReason": "terminal_focus_script_launch_failed"
                ]
            )
        }

        usleep(120_000)
    }

    private func clearPromptInputIfNeeded() throws {
        try postKey(53)
        usleep(100_000)
        try postKey(32, flags: .maskControl)
        usleep(220_000)
    }

    private func captureFrontmostContext(currentAppBundleID: String) -> FrontmostAppContext {
        let preferredContext = AppFocusTracker.shared.preferredReturnContext(
            fallbackBundleID: currentAppBundleID,
            maxAge: 60
        )
        return FrontmostAppContext(
            bundleID: preferredContext.bundleID,
            terminalTTY: preferredContext.terminalTTY,
            capturedAt: preferredContext.capturedAt
        )
    }

    private func currentFrontTerminalTTY() -> String? {
        let tty = AppFocusTracker.shared.preferredTerminalTTY() ?? ""
        let trimmed = normalizeTTYIdentifier(tty)
        if !trimmed.isEmpty {
            return trimmed
        }

        do {
            let result = try SubprocessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", """
                tell application "Terminal"
                  try
                    return tty of selected tab of front window
                  on error
                    return ""
                  end try
                end tell
                """]
            )
            let normalized = normalizeTTYIdentifier(result.trimmedStdout)
            return normalized.isEmpty ? nil : normalized
        } catch {
            return nil
        }
    }

    private func currentFrontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func runOnMainSync<T>(_ block: () -> T) -> T {
        if Thread.isMainThread {
            return block()
        }
        return DispatchQueue.main.sync(execute: block)
    }

    @discardableResult
    private func hideTerminal() -> Bool {
        do {
            let result = try SubprocessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", """
                tell application "Terminal"
                  try
                    hide
                    return "ok"
                  on error
                    return "failed"
                  end try
                end tell
                """]
            )
            return result.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func activateBundleID(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        let activated = runOnMainSync { () -> Bool in
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { !$0.isTerminated }
            guard let app = runningApps.first else { return false }
            return app.activate(options: [.activateAllWindows])
        }
        guard activated else { return false }
        usleep(180_000)
        return currentFrontmostBundleID() == bundleID
    }

    private func activateTaskMasterApp() -> Bool {
        let currentBundleID = Bundle.main.bundleIdentifier ?? ""
        let activated = runOnMainSync { () -> Bool in
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: currentBundleID)
                .filter { !$0.isTerminated }
            let runningApp = runningApps.first ?? NSRunningApplication.current

            let visibleWindows = NSApp.windows.filter { $0.isVisible }
            if let keyCandidate = visibleWindows.first {
                keyCandidate.makeKeyAndOrderFront(nil)
                keyCandidate.orderFrontRegardless()
            } else {
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                NSApp.windows.first?.orderFrontRegardless()
            }

            let activatedApp = runningApp.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            if let keyWindow = NSApp.keyWindow {
                keyWindow.makeKeyAndOrderFront(nil)
                keyWindow.orderFrontRegardless()
            } else if let firstVisibleWindow = visibleWindows.first {
                firstVisibleWindow.makeKeyAndOrderFront(nil)
                firstVisibleWindow.orderFrontRegardless()
            }
            return activatedApp
        }

        guard activated else { return false }
        usleep(220_000)
        return currentFrontmostBundleID() == currentBundleID
    }

    private func restorePreviousTerminalTTY(_ preferredTTY: String, targetTTY: String) -> String? {
        let normalizedPreferredTTY = normalizeTTYIdentifier(preferredTTY)
        let normalizedTargetTTY = normalizeTTYIdentifier(targetTTY)
        guard !normalizedPreferredTTY.isEmpty, normalizedPreferredTTY != normalizedTargetTTY else {
            return nil
        }

        let script = """
        on run argv
          set preferredTTY to item 1 of argv
          try
            tell application "Terminal" to activate
            delay 0.05
            tell application "Terminal"
              repeat with w in windows
                try
                  repeat with t in tabs of w
                    if (tty of t) is equal to preferredTTY then
                      set selected tab of w to t
                      set index of w to 1
                      return tty of selected tab of front window
                    end if
                  end repeat
                end try
              end repeat
            end tell
          on error
            return ""
          end try
          return ""
        end run
        """

        do {
            let result = try SubprocessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-", normalizedPreferredTTY],
                standardInputData: script.data(using: .utf8)
            )
            usleep(120_000)
            guard result.terminationStatus == 0, currentFrontmostBundleID() == "com.apple.Terminal" else {
                return nil
            }
            let restoredTTY = normalizeTTYIdentifier(result.trimmedStdout)
            return restoredTTY.isEmpty ? nil : restoredTTY
        } catch {
            return nil
        }
    }

    private func restoreFocusAfterTerminalSend(previousContext: FrontmostAppContext, targetTTY: String, logger: ((String) -> Void)?) {
        let currentAppBundleID = Bundle.main.bundleIdentifier ?? ""
        let preferredBundleID = previousContext.bundleID.isEmpty ? currentAppBundleID : previousContext.bundleID
        let preferredTerminalTTY = normalizeTTYIdentifier(previousContext.terminalTTY ?? "")
        let normalizedTargetTTY = normalizeTTYIdentifier(targetTTY)

        focusDebugLog(
            logger,
            "restore-begin preferred_bundle=\(preferredBundleID.isEmpty ? "-" : preferredBundleID) preferred_terminal_tty=\(preferredTerminalTTY.isEmpty ? "-" : preferredTerminalTTY) target_tty=\(normalizedTargetTTY.isEmpty ? "-" : normalizedTargetTTY) current_frontmost=\(currentFrontmostBundleID() ?? "-")"
        )

        if preferredBundleID == "com.apple.Terminal" {
            let restoredTTY = restorePreviousTerminalTTY(preferredTerminalTTY, targetTTY: normalizedTargetTTY)
            let success = (restoredTTY == preferredTerminalTTY)
            focusDebugLog(
                logger,
                "restore-result mode=terminal_tty success=\(success ? "yes" : "no") restored_tty=\((restoredTTY?.isEmpty == false) ? restoredTTY! : "-") expected_tty=\(preferredTerminalTTY.isEmpty ? "-" : preferredTerminalTTY) frontmost=\(currentFrontmostBundleID() ?? "-")"
            )
            if success {
                return
            }
            let hideResult = hideTerminal()
            focusDebugLog(logger, "hide-terminal success=\(hideResult ? "yes" : "no") frontmost=\(currentFrontmostBundleID() ?? "-")")

            if activateTaskMasterApp() {
                focusDebugLog(logger, "restore-result mode=taskmaster_fallback_after_terminal_failure success=yes bundle=\(currentAppBundleID) frontmost=\(currentFrontmostBundleID() ?? "-")")
                return
            }

            focusDebugLog(logger, "restore-result mode=taskmaster_fallback_after_terminal_failure success=no bundle=\(currentAppBundleID) frontmost=\(currentFrontmostBundleID() ?? "-")")
            _ = activateTaskMasterApp()
            focusDebugLog(logger, "restore-result mode=taskmaster_force_activate_after_terminal_failure frontmost=\(currentFrontmostBundleID() ?? "-")")
            return
        }

        let hideResult = hideTerminal()
        focusDebugLog(logger, "hide-terminal success=\(hideResult ? "yes" : "no") frontmost=\(currentFrontmostBundleID() ?? "-")")

        if preferredBundleID != currentAppBundleID,
           activateBundleID(preferredBundleID) {
            focusDebugLog(logger, "restore-result mode=preferred_bundle success=yes bundle=\(preferredBundleID) frontmost=\(currentFrontmostBundleID() ?? "-")")
            return
        }
        if preferredBundleID != currentAppBundleID {
            focusDebugLog(logger, "restore-result mode=preferred_bundle success=no bundle=\(preferredBundleID) frontmost=\(currentFrontmostBundleID() ?? "-")")
        }

        if activateTaskMasterApp() {
            focusDebugLog(logger, "restore-result mode=taskmaster_fallback success=yes bundle=\(currentAppBundleID) frontmost=\(currentFrontmostBundleID() ?? "-")")
            return
        }

        focusDebugLog(logger, "restore-result mode=taskmaster_fallback success=no bundle=\(currentAppBundleID) frontmost=\(currentFrontmostBundleID() ?? "-")")
        _ = activateTaskMasterApp()
        focusDebugLog(logger, "restore-result mode=taskmaster_force_activate frontmost=\(currentFrontmostBundleID() ?? "-")")
    }

}

final class SendRequestCoordinator {
    typealias HelperCommandResult = (status: Int32, stdout: String, stderr: String)
    typealias ProbeResult = (status: Int32, values: [String: String], stdout: String, stderr: String)

    private struct QueuedSendRequestExecution {
        let target: String
        let message: String
        let timeoutSeconds: NSNumber
        let forceSend: Bool
        let context: QueuedSendExecutionContext
    }

    private struct QueuedSendExecutionContext {
        let activeProbe: ProbeResult
        let resolution: LiveTTYResolution?
        let probeStatus: String
        let terminalState: String
        let tty: String
        let previousUserTimestamp: String
        let preflightDetail: String
        let preflightDecision: SendPreflightDecision
        let clearResidualInputBeforeSend: Bool
    }

    private struct QueuedSendVerificationContext {
        let verification: (success: Bool, probe: ProbeResult)
        let decision: SendVerificationDecision
    }

    private let pendingRequestDirectoryPath: String
    private let processingRequestDirectoryPath: String
    private let resultRequestDirectoryPath: String
    private let sendAdapter: PlatformSendAdapter
    private let terminalAutomationQueue: DispatchQueue
    private let runHelper: ([String]) -> HelperCommandResult
    private let callbacks: SendRequestProcessorCallbacks
    private let processingLock = NSLock()
    private var isProcessingSendRequest = false

    init(
        pendingRequestDirectoryPath: String,
        processingRequestDirectoryPath: String,
        resultRequestDirectoryPath: String,
        sendAdapter: PlatformSendAdapter,
        terminalAutomationQueue: DispatchQueue,
        runHelper: @escaping ([String]) -> HelperCommandResult,
        callbacks: SendRequestProcessorCallbacks
    ) {
        self.pendingRequestDirectoryPath = pendingRequestDirectoryPath
        self.processingRequestDirectoryPath = processingRequestDirectoryPath
        self.resultRequestDirectoryPath = resultRequestDirectoryPath
        self.sendAdapter = sendAdapter
        self.terminalAutomationQueue = terminalAutomationQueue
        self.runHelper = runHelper
        self.callbacks = callbacks
    }

    func ensurePermission(prompt: Bool) -> Bool {
        sendAdapter.ensurePermission(prompt: prompt)
    }

    func processPendingRequests() {
        processingLock.lock()
        if isProcessingSendRequest {
            processingLock.unlock()
            return
        }
        isProcessingSendRequest = true
        processingLock.unlock()

        let pendingDirectoryURL = URL(fileURLWithPath: pendingRequestDirectoryPath, isDirectory: true)
        let processingDirectoryURL = URL(fileURLWithPath: processingRequestDirectoryPath, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: pendingDirectoryURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: processingDirectoryURL, withIntermediateDirectories: true)
        } catch {
            finishProcessingRequest()
            return
        }

        guard let nextRequestURL = nextPendingRequestURL(in: pendingDirectoryURL) else {
            finishProcessingRequest()
            return
        }

        guard let processingURL = movePendingRequestToProcessing(
            nextRequestURL: nextRequestURL,
            processingDirectoryURL: processingDirectoryURL
        ) else {
            finishProcessingRequest()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            self.handleQueuedSendRequest(at: processingURL)
        }
    }

    private func nextPendingRequestURL(in pendingDirectoryURL: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(
            at: pendingDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    private func movePendingRequestToProcessing(nextRequestURL: URL, processingDirectoryURL: URL) -> URL? {
        let processingURL = processingDirectoryURL.appendingPathComponent(nextRequestURL.lastPathComponent)

        do {
            if FileManager.default.fileExists(atPath: processingURL.path) {
                try FileManager.default.removeItem(at: processingURL)
            }
            try FileManager.default.moveItem(at: nextRequestURL, to: processingURL)
            return processingURL
        } catch {
            return nil
        }
    }

    private func finishProcessingRequest() {
        processingLock.lock()
        isProcessingSendRequest = false
        processingLock.unlock()
        callbacks.requestDidFinish()
    }

    private func probeResult(for target: String) -> ProbeResult {
        let result = runHelper(["probe", "-t", target])
        return (
            result.status,
            parseStructuredKeyValueFields(result.stdout, requireStatusAndReason: false) ?? [:],
            result.stdout,
            result.stderr
        )
    }

    private func readJSONFile(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        return object as? [String: Any] ?? [:]
    }

    private func writeJSONFile(at url: URL, object: [String: Any]) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        let tempURL = parent.appendingPathComponent(UUID().uuidString).appendingPathExtension("tmp")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tempURL, to: url)
    }

    private func resultURL(for processingURL: URL) -> URL {
        URL(fileURLWithPath: resultRequestDirectoryPath, isDirectory: true)
            .appendingPathComponent(processingURL.deletingPathExtension().deletingPathExtension().lastPathComponent + ".result.json")
    }

    private func finishQueuedSendRequest(processingURL: URL, resultURL: URL, result: [String: Any]) {
        do {
            try writeJSONFile(at: resultURL, object: result)
        } catch {}
        try? FileManager.default.removeItem(at: processingURL)
        finishProcessingRequest()
    }

    private func makeQueuedSendRequestFinisher(processingURL: URL, resultURL: URL) -> ([String: Any]) -> Void {
        { [self] result in
            finishQueuedSendRequest(processingURL: processingURL, resultURL: resultURL, result: result)
        }
    }

    private func loadQueuedSendRequest(at processingURL: URL, finish: ([String: Any]) -> Void) -> ParsedSendRequestPayload? {
        let payload: [String: Any]
        do {
            payload = try readJSONFile(at: processingURL)
        } catch {
            finishFailedSendRequest(
                target: "-",
                forceSend: false,
                reason: "invalid_request",
                detail: "failed to read request: \(error.localizedDescription)",
                finish: finish
            )
            return nil
        }

        guard let request = parseSendRequestPayload(payload) else {
            finishFailedSendRequest(
                target: "-",
                forceSend: false,
                reason: "invalid_request",
                detail: "request file is missing target, message, or timeout_seconds",
                finish: finish
            )
            return nil
        }

        return request
    }

    private func loadInitialQueuedSendProbe(target: String, forceSend: Bool, finish: ([String: Any]) -> Void) -> ProbeResult? {
        let initialProbe = probeResult(for: target)
        guard initialProbe.status == 0 else {
            let detail = compactProbeSummary(status: initialProbe.status, values: initialProbe.values, stdout: initialProbe.stdout, stderr: initialProbe.stderr)
            let failureReason = sendProbeFailureReason(detail: detail)
            finishFailedSendRequest(
                target: target,
                forceSend: forceSend,
                reason: failureReason,
                detail: detail,
                finish: finish
            )
            return nil
        }
        return initialProbe
    }

    private func finishQueuedSendPreflightFailure(
        target: String,
        forceSend: Bool,
        probeStatus: String,
        terminalState: String,
        detail: String,
        failureReason: String,
        finish: ([String: Any]) -> Void
    ) {
        finishFailedSendRequest(
            target: target,
            forceSend: forceSend,
            reason: failureReason,
            detail: detail,
            probeStatus: probeStatus,
            terminalState: terminalState,
            finish: finish
        )
    }

    private func finishQueuedSendDeliveryFailure(
        target: String,
        forceSend: Bool,
        probeStatus: String,
        terminalState: String,
        error: Error,
        resolution: LiveTTYResolution?,
        finish: ([String: Any]) -> Void
    ) {
        let failureReason = sendFailureReason(for: error)
        let detail = appendLiveTTYResolutionDetail(error.localizedDescription, resolution: resolution)
        finishFailedSendRequest(
            target: target,
            forceSend: forceSend,
            reason: failureReason,
            detail: detail,
            probeStatus: probeStatus,
            terminalState: terminalState,
            finish: finish
        )
    }

    private func finishQueuedSendVerification(
        target: String,
        forceSend: Bool,
        usedTTY: String,
        clearExistingInput: Bool,
        verification: (success: Bool, probe: ProbeResult),
        verificationDecision: SendVerificationDecision,
        resolution: LiveTTYResolution?,
        finish: ([String: Any]) -> Void
    ) {
        if verificationDecision.status == "success" {
            let baseDetail = "sent message via app sender to target=\(target) tty=\(usedTTY) clear_existing_input=\(clearExistingInput ? "yes" : "no")"
            let detail = appendLiveTTYResolutionDetail(baseDetail, resolution: resolution)
            finishCompletedSendRequest(
                logPrefix: "发送请求完成:",
                status: "success",
                target: target,
                forceSend: forceSend,
                reason: verificationDecision.reason,
                detail: detail,
                probeStatus: verificationDecision.probeStatus,
                terminalState: verificationDecision.terminalState,
                color: .systemGreen,
                finish: finish
            )
            return
        }

        let detail = probeDetail(verification.probe, resolution: resolution)
        if verificationDecision.reason == "queued_pending_feedback" {
            finishCompletedSendRequest(
                logPrefix: "发送请求已排队:",
                status: "accepted",
                target: target,
                forceSend: forceSend,
                reason: verificationDecision.reason,
                detail: detail,
                probeStatus: verificationDecision.probeStatus,
                terminalState: verificationDecision.terminalState,
                color: .systemOrange,
                finish: finish
            )
            return
        }

        finishCompletedSendRequest(
            logPrefix: "发送请求待确认:",
            status: "accepted",
            target: target,
            forceSend: forceSend,
            reason: verificationDecision.reason,
            detail: detail,
            probeStatus: verificationDecision.probeStatus,
            terminalState: verificationDecision.terminalState,
            color: .systemOrange,
            finish: finish
        )
    }

    private func finishFailedSendRequest(
        target: String,
        forceSend: Bool,
        reason: String,
        detail: String,
        probeStatus: String? = nil,
        terminalState: String? = nil,
        finish: ([String: Any]) -> Void
    ) {
        let targetText = target.isEmpty ? "-" : target
        var logParts = [
            "发送请求失败:",
            "status=failed",
            "reason=\(reason)",
            "target=\(targetText)",
            "force_send=\(forceSend ? "yes" : "no")"
        ]
        if let probeStatus, !probeStatus.isEmpty {
            logParts.append("probe_status=\(probeStatus)")
        }
        if let terminalState, !terminalState.isEmpty {
            logParts.append("terminal_state=\(terminalState)")
        }
        logParts.append("detail=\(detail)")
        callbacks.logActivity(logParts.joined(separator: " "))
        callbacks.updateSendStatus("failed", targetText, reason, probeStatus, terminalState, .systemRed)
        finish(makeSendRequestResultPayload(
            status: "failed",
            reason: reason,
            target: targetText,
            forceSend: forceSend,
            detail: detail,
            probeStatus: probeStatus,
            terminalState: terminalState
        ))
    }

    private func finishCompletedSendRequest(
        logPrefix: String,
        status: String,
        target: String,
        forceSend: Bool,
        reason: String,
        detail: String,
        probeStatus: String? = nil,
        terminalState: String? = nil,
        color: NSColor,
        finish: ([String: Any]) -> Void
    ) {
        let targetText = target.isEmpty ? "-" : target
        var logParts = [
            logPrefix,
            "status=\(status)",
            "reason=\(reason)",
            "target=\(targetText)",
            "force_send=\(forceSend ? "yes" : "no")"
        ]
        if let probeStatus, !probeStatus.isEmpty {
            logParts.append("probe_status=\(probeStatus)")
        }
        if let terminalState, !terminalState.isEmpty {
            logParts.append("terminal_state=\(terminalState)")
        }
        logParts.append("detail=\(detail)")
        callbacks.logActivity(logParts.joined(separator: " "))
        callbacks.updateSendStatus(status, targetText, reason, probeStatus, terminalState, color)
        finish(makeSendRequestResultPayload(
            status: status,
            reason: reason,
            target: targetText,
            forceSend: forceSend,
            detail: detail,
            probeStatus: probeStatus,
            terminalState: terminalState
        ))
    }

    private func verifyUserMessageAdvanced(target: String, previousTimestamp: String, timeoutSeconds: TimeInterval) -> (success: Bool, probe: ProbeResult) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var latestProbe = probeResult(for: target)

        while Date() < deadline {
            latestProbe = probeResult(for: target)
            let currentTimestamp = latestProbe.values["last_user_message_at"] ?? ""
            if !currentTimestamp.isEmpty && currentTimestamp != previousTimestamp {
                return (true, latestProbe)
            }
            Thread.sleep(forTimeInterval: 0.4)
        }

        latestProbe = probeResult(for: target)
        return (false, latestProbe)
    }

    private func ttyPath(from tty: String) -> String {
        let normalized = normalizeTTYIdentifier(tty)
        return normalized.hasPrefix("/dev/") ? normalized : "/dev/\(normalized)"
    }

    private func isTTYFocusFailure(_ error: Error) -> Bool {
        error.localizedDescription.contains("could not focus Terminal window for ")
    }

    private func sendFailureReason(for error: Error) -> String {
        let nsError = error as NSError
        if let reason = nsError.userInfo["sendReason"] as? String, !reason.isEmpty {
            return reason
        }
        return "send_interrupted"
    }

    private func resolveLiveTTY(target: String) -> (tty: String?, detail: String) {
        let result = runHelper(["resolve-live-tty", "-t", target])
        let detail = preferredCommandDetail(stdout: result.stdout, stderr: result.stderr) ?? "failed to resolve live tty"
        guard result.status == 0 else {
            return (nil, detail)
        }
        let tty = normalizeTTYIdentifier(result.stdout)
        return (tty.isEmpty ? nil : tty, detail)
    }

    private func recoverLiveTTY(target: String, previousTTY: String?) -> LiveTTYResolution {
        let previous = normalizeTTYIdentifier(previousTTY ?? "")
        let resolved = resolveLiveTTY(target: target)
        guard let tty = resolved.tty, !tty.isEmpty else {
            return LiveTTYResolution(tty: nil, detail: resolved.detail, changed: false)
        }
        return LiveTTYResolution(tty: tty, detail: resolved.detail, changed: tty != previous)
    }

    private func shouldAttemptPreflightTTYRecovery(initialTTY: String, terminalState: String) -> Bool {
        normalizeTTYIdentifier(initialTTY).isEmpty || terminalState == "unavailable"
    }

    private func prepareProbeForSend(target: String, initialProbe: ProbeResult) -> (probe: ProbeResult, tty: String, resolution: LiveTTYResolution?) {
        let rawInitialTTY = initialProbe.values["tty"] ?? ""
        let initialTTY = rawInitialTTY == "-" ? "" : normalizeTTYIdentifier(rawInitialTTY)
        let initialTerminalState = initialProbe.values["terminal_state"] ?? "unknown"

        guard shouldAttemptPreflightTTYRecovery(initialTTY: initialTTY, terminalState: initialTerminalState) else {
            return (initialProbe, initialTTY, nil)
        }

        let resolution = recoverLiveTTY(target: target, previousTTY: initialTTY)
        guard let resolvedTTY = resolution.tty, !resolvedTTY.isEmpty else {
            return (initialProbe, initialTTY, resolution)
        }

        let refreshedProbe = probeResult(for: target)
        if refreshedProbe.status == 0 {
            let refreshedRawTTY = refreshedProbe.values["tty"] ?? ""
            let refreshedTTY = refreshedRawTTY == "-" ? "" : normalizeTTYIdentifier(refreshedRawTTY)
            if !refreshedTTY.isEmpty {
                return (refreshedProbe, refreshedTTY, resolution)
            }
        }

        return (initialProbe, resolvedTTY, resolution)
    }

    private func prepareQueuedSendExecutionContext(
        target: String,
        forceSend: Bool,
        initialProbe: ProbeResult
    ) -> QueuedSendExecutionContext {
        let preparedProbe = prepareProbeForSend(target: target, initialProbe: initialProbe)
        let activeProbe = preparedProbe.probe
        let probeStatus = activeProbe.values["status"] ?? "unknown"
        let terminalState = activeProbe.values["terminal_state"] ?? "unknown"
        let previousUserTimestamp = activeProbe.values["last_user_message_at"] ?? ""
        let preflightDetail = probeDetail(activeProbe, resolution: preparedProbe.resolution)
        let preflightDecision = evaluateSendPreflight(
            forceSend: forceSend,
            tty: preparedProbe.tty,
            probeStatus: probeStatus,
            terminalState: terminalState,
            detail: preflightDetail
        )

        return QueuedSendExecutionContext(
            activeProbe: activeProbe,
            resolution: preparedProbe.resolution,
            probeStatus: probeStatus,
            terminalState: terminalState,
            tty: preparedProbe.tty,
            previousUserTimestamp: previousUserTimestamp,
            preflightDetail: preflightDetail,
            preflightDecision: preflightDecision,
            clearResidualInputBeforeSend: preflightDecision.shouldClearResidualInput
        )
    }

    private func loadQueuedSendRequestExecution(
        request: ParsedSendRequestPayload,
        finish: ([String: Any]) -> Void
    ) -> QueuedSendRequestExecution? {
        guard let initialProbe = loadInitialQueuedSendProbe(target: request.target, forceSend: request.forceSend, finish: finish) else {
            return nil
        }

        return QueuedSendRequestExecution(
            target: request.target,
            message: request.message,
            timeoutSeconds: request.timeoutSeconds,
            forceSend: request.forceSend,
            context: prepareQueuedSendExecutionContext(
                target: request.target,
                forceSend: request.forceSend,
                initialProbe: initialProbe
            )
        )
    }

    private func performQueuedSendVerification(
        target: String,
        forceSend: Bool,
        timeoutSeconds: NSNumber,
        context: QueuedSendExecutionContext
    ) -> QueuedSendVerificationContext {
        let verification = verifyUserMessageAdvanced(
            target: target,
            previousTimestamp: context.previousUserTimestamp,
            timeoutSeconds: max(8, min(timeoutSeconds.doubleValue, 14))
        )
        let decision = evaluateSendVerificationDecision(
            verificationSucceeded: verification.success,
            forceSend: forceSend,
            initialProbeStatus: context.probeStatus,
            initialTerminalState: context.terminalState,
            verificationProbeStatusCode: verification.probe.status,
            verificationProbeStatus: verification.probe.values["status"] ?? "unknown",
            verificationReason: verification.probe.values["reason"] ?? "",
            verificationTerminalState: verification.probe.values["terminal_state"] ?? "unknown"
        )

        return QueuedSendVerificationContext(
            verification: verification,
            decision: decision
        )
    }

    private func performQueuedSendDelivery(
        target: String,
        message: String,
        forceSend: Bool,
        context: QueuedSendExecutionContext,
        finish: ([String: Any]) -> Void
    ) -> String? {
        do {
            return try sendWithLiveTTYRecovery(
                target: target,
                initialTTY: context.tty,
                message: message,
                clearExistingInput: context.clearResidualInputBeforeSend
            )
        } catch {
            finishQueuedSendDeliveryFailure(
                target: target,
                forceSend: forceSend,
                probeStatus: context.probeStatus,
                terminalState: context.terminalState,
                error: error,
                resolution: context.resolution,
                finish: finish
            )
            return nil
        }
    }

    private func performQueuedSendPreflight(
        target: String,
        forceSend: Bool,
        context: QueuedSendExecutionContext,
        finish: ([String: Any]) -> Void
    ) -> Bool {
        guard context.preflightDecision.canSend else {
            finishQueuedSendPreflightFailure(
                target: target,
                forceSend: forceSend,
                probeStatus: context.probeStatus,
                terminalState: context.terminalState,
                detail: context.preflightDetail,
                failureReason: context.preflightDecision.failureReason,
                finish: finish
            )
            return false
        }

        return true
    }

    private func appendLiveTTYResolutionDetail(_ baseDetail: String, resolution: LiveTTYResolution?) -> String {
        guard let resolution else { return baseDetail }

        var parts = [baseDetail]
        if let tty = resolution.tty, !tty.isEmpty {
            parts.append("live_tty_resolved=\(tty)")
            parts.append("live_tty_changed=\(resolution.changed ? "yes" : "no")")
        } else {
            parts.append("live_tty_resolved=-")
        }
        if !resolution.detail.isEmpty {
            parts.append("live_tty_detail=\(resolution.detail)")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " | ")
    }

    private func probeDetail(_ probe: ProbeResult, resolution: LiveTTYResolution?) -> String {
        appendLiveTTYResolutionDetail(
            compactProbeSummary(status: probe.status, values: probe.values, stdout: probe.stdout, stderr: probe.stderr),
            resolution: resolution
        )
    }

    private func makeTTYFocusFailureError(target: String, initialTTY: String, resolvedTTY: String?, resolveDetail: String) -> NSError {
        var detailParts = [
            "target=\(target)",
            "initial_tty=\(initialTTY.isEmpty ? "-" : initialTTY)"
        ]
        if let resolvedTTY, !resolvedTTY.isEmpty {
            detailParts.append("resolved_live_tty=\(resolvedTTY)")
        } else {
            detailParts.append("resolved_live_tty=-")
        }
        if !resolveDetail.isEmpty {
            detailParts.append("resolve_detail=\(resolveDetail)")
        }
        return NSError(
            domain: "CodexTaskmaster",
            code: 6,
            userInfo: [
                NSLocalizedDescriptionKey: detailParts.joined(separator: " | "),
                "sendReason": "tty_focus_failed"
            ]
        )
    }

    private func sendViaResolvedTTY(target: String, initialTTY: String, message: String, clearExistingInput: Bool) throws -> String {
        let startingTTY = normalizeTTYIdentifier(initialTTY)
        try terminalAutomationQueue.sync {
            try sendAdapter.sendMessage(
                toTTYPath: ttyPath(from: startingTTY),
                message: message,
                clearExistingInput: clearExistingInput,
                logger: callbacks.logActivity
            )
        }
        return startingTTY
    }

    private func sendWithLiveTTYRecovery(target: String, initialTTY: String, message: String, clearExistingInput: Bool) throws -> String {
        let startingTTY = normalizeTTYIdentifier(initialTTY)

        do {
            return try sendViaResolvedTTY(
                target: target,
                initialTTY: startingTTY,
                message: message,
                clearExistingInput: clearExistingInput
            )
        } catch {
            guard isTTYFocusFailure(error) else {
                throw error
            }

            let resolved = recoverLiveTTY(target: target, previousTTY: startingTTY)
            guard let liveTTY = resolved.tty, !liveTTY.isEmpty, resolved.changed else {
                throw makeTTYFocusFailureError(
                    target: target,
                    initialTTY: startingTTY,
                    resolvedTTY: resolved.tty,
                    resolveDetail: resolved.detail
                )
            }

            do {
                return try sendViaResolvedTTY(
                    target: target,
                    initialTTY: liveTTY,
                    message: message,
                    clearExistingInput: clearExistingInput
                )
            } catch {
                if isTTYFocusFailure(error) {
                    throw makeTTYFocusFailureError(
                        target: target,
                        initialTTY: startingTTY,
                        resolvedTTY: liveTTY,
                        resolveDetail: resolved.detail
                    )
                }
                throw error
            }
        }
    }

    private func handleQueuedSendRequest(at processingURL: URL) {
        let resultURL = resultURL(for: processingURL)
        let finishQueuedRequest = makeQueuedSendRequestFinisher(processingURL: processingURL, resultURL: resultURL)

        guard let request = loadQueuedSendRequest(at: processingURL, finish: finishQueuedRequest) else {
            return
        }

        guard let execution = loadQueuedSendRequestExecution(request: request, finish: finishQueuedRequest) else {
            return
        }

        let target = execution.target
        let message = execution.message
        let timeoutSeconds = execution.timeoutSeconds
        let forceSend = execution.forceSend
        let context = execution.context

        guard performQueuedSendPreflight(
            target: target,
            forceSend: forceSend,
            context: context,
            finish: finishQueuedRequest
        ) else {
            return
        }

        guard let usedTTY = performQueuedSendDelivery(
            target: target,
            message: message,
            forceSend: forceSend,
            context: context,
            finish: finishQueuedRequest
        ) else {
            return
        }

        let verificationContext = performQueuedSendVerification(
            target: target,
            forceSend: forceSend,
            timeoutSeconds: timeoutSeconds,
            context: context
        )
        finishQueuedSendVerification(
            target: target,
            forceSend: forceSend,
            usedTTY: usedTTY,
            clearExistingInput: context.clearResidualInputBeforeSend,
            verification: verificationContext.verification,
            verificationDecision: verificationContext.decision,
            resolution: context.resolution,
            finish: finishQueuedRequest
        )
    }
}
