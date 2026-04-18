import Foundation

@main
struct TaskMasterCoreRegressionRunner {
    static func main() {
        runStructuredFieldParsingChecks()
        runTTYNormalizationChecks()
        runCommandDetailChecks()
        runCompactProbeSummaryChecks()
        runSendRequestPayloadChecks()
        runSendVerificationDecisionChecks()
        runSendProbeFailureReasonChecks()
        runSendRequestParsingChecks()
        runStoredSendResultParsingChecks()
        runRecentUserMessageEntryParsingChecks()
        runLoopSnapshotAccessorChecks()
        runSessionSnapshotAccessorChecks()
        runMergeSessionSnapshotChecks()
        runOverlaySessionSnapshotChecks()
        runMergeLoopSnapshotChecks()
        runMergeLoopSnapshotListChecks()
        runLocalizationChecks()
        runLoopStateLabelChecks()
        runProbeStateRuleChecks()
        runQueuedAcceptanceRuleChecks()
        runAmbiguousTargetRuleChecks()
        runSendPreflightDecisionChecks()
        print("taskmaster_core_regression_ok")
    }

    private static func runStructuredFieldParsingChecks() {
        let text = """
        status: failed
        reason: not_sendable
        detail: target busy
        """

        let fields = parseStructuredKeyValueFields(text)
        expect(fields?["status"] == "failed", "expected parser to read status field")
        expect(fields?["reason"] == "not_sendable", "expected parser to read reason field")
        expect(fields?["detail"] == "target busy", "expected parser to preserve detail field")
    }

    private static func runTTYNormalizationChecks() {
        expect(normalizeTTYIdentifier("/dev/ttys001") == "ttys001", "expected /dev prefix to be stripped")
        expect(normalizeTTYIdentifier("ttys002") == "ttys002", "expected plain tty to remain unchanged")
        expect(normalizeTTYIdentifier("-").isEmpty, "expected placeholder tty to normalize to empty")
        expect(normalizeTTYIdentifier("  ").isEmpty, "expected blank tty to normalize to empty")
    }

    private static func runCommandDetailChecks() {
        expect(preferredCommandDetail(stdout: "stdout detail", stderr: "") == "stdout detail", "expected stdout fallback when stderr is empty")
        expect(preferredCommandDetail(stdout: "stdout detail", stderr: "stderr detail") == "stderr detail", "expected stderr to override stdout detail")
    }

    private static func runCompactProbeSummaryChecks() {
        let summary = compactProbeSummary(
            status: 0,
            values: [
                "target": "demo",
                "thread_id": "thread-1",
                "tty": "ttys001",
                "status": "idle_stable",
                "reason": "ready",
                "terminal_state": "prompt_ready"
            ],
            stdout: "",
            stderr: ""
        )

        expect(summary == "target: demo | thread_id: thread-1 | tty: ttys001 | status: idle_stable | reason: ready | terminal_state: prompt_ready", "expected compact probe summary to preserve known keys in order")
    }

    private static func runSendRequestPayloadChecks() {
        let payload = makeSendRequestResultPayload(
            status: "accepted",
            reason: "verification_pending",
            target: "demo",
            forceSend: true,
            detail: "detail",
            probeStatus: "idle_stable",
            terminalState: "prompt_ready"
        )

        expect(payload["status"] as? String == "accepted", "expected payload to preserve status")
        expect(payload["reason"] as? String == "verification_pending", "expected payload to preserve reason")
        expect(payload["target"] as? String == "demo", "expected payload to preserve target")
        expect(payload["force_send"] as? Bool == true, "expected payload to preserve force-send flag")
        expect(payload["detail"] as? String == "detail", "expected payload to preserve detail")
        expect(payload["probe_status"] as? String == "idle_stable", "expected payload to preserve probe status")
        expect(payload["terminal_state"] as? String == "prompt_ready", "expected payload to preserve terminal state")
    }

    private static func runSendVerificationDecisionChecks() {
        let success = evaluateSendVerificationDecision(
            verificationSucceeded: true,
            forceSend: true,
            initialProbeStatus: "idle_stable",
            initialTerminalState: "prompt_ready",
            verificationProbeStatusCode: 0,
            verificationProbeStatus: "idle_stable",
            verificationReason: "",
            verificationTerminalState: "prompt_ready"
        )
        expect(success.status == "success", "expected successful verification to map to success")
        expect(success.statusKind == .success, "expected successful verification accessor to map to success")
        expect(success.reason == "forced_sent", "expected forced successful verification to map to forced_sent")
        expect(success.reasonKind == .forcedSent, "expected forced successful verification reason accessor to map to forced_sent")

        let queued = evaluateSendVerificationDecision(
            verificationSucceeded: false,
            forceSend: false,
            initialProbeStatus: "idle_stable",
            initialTerminalState: "prompt_ready",
            verificationProbeStatusCode: 0,
            verificationProbeStatus: "unknown",
            verificationReason: "turn is complete, but queued messages are still visible in Terminal",
            verificationTerminalState: "queued_messages_pending"
        )
        expect(queued.status == "accepted", "expected queued verification to remain accepted")
        expect(queued.statusKind == .accepted, "expected queued verification accessor to remain accepted")
        expect(queued.reason == "queued_pending_feedback", "expected queued verification to map to queued_pending_feedback")
        expect(queued.reasonKind == .queuedPendingFeedback, "expected queued verification reason accessor to map to queued_pending_feedback")

        let pending = evaluateSendVerificationDecision(
            verificationSucceeded: false,
            forceSend: false,
            initialProbeStatus: "idle_stable",
            initialTerminalState: "prompt_ready",
            verificationProbeStatusCode: 0,
            verificationProbeStatus: "busy_turn_open",
            verificationReason: "",
            verificationTerminalState: "prompt_with_input"
        )
        expect(pending.status == "accepted", "expected unconfirmed verification to remain accepted")
        expect(pending.statusKind == .accepted, "expected unconfirmed verification accessor to remain accepted")
        expect(pending.reason == "verification_pending", "expected unconfirmed verification to map to verification_pending")
        expect(pending.reasonKind == .verificationPending, "expected unconfirmed verification reason accessor to map to verification_pending")
        expect(pending.probeStatus == "busy_turn_open", "expected pending verification to preserve latest probe status")
    }

    private static func runSendProbeFailureReasonChecks() {
        expect(sendProbeFailureReason(detail: "found multiple matching sessions for target demo") == "ambiguous_target", "expected ambiguity detail to map to ambiguous_target")
        expect(sendProbeFailureReason(detail: "tty unavailable") == "probe_failed", "expected generic probe failure detail to map to probe_failed")
    }

    private static func runSendRequestParsingChecks() {
        let parsed = parseSendRequestPayload([
            "target": "demo",
            "message": "hello",
            "timeout_seconds": NSNumber(value: 12),
            "force_send": true
        ])
        expect(parsed?.target == "demo", "expected parsed request to preserve target")
        expect(parsed?.message == "hello", "expected parsed request to preserve message")
        expect(parsed?.timeoutSeconds == 12, "expected parsed request to preserve timeout")
        expect(parsed?.forceSend == true, "expected parsed request to preserve force-send")
        expect(parseSendRequestPayload(["target": "demo"]) == nil, "expected parser to reject missing required fields")
    }

    private static func runStoredSendResultParsingChecks() {
        let json = """
        {
          "target": "demo",
          "status": "accepted",
          "reason": "verification_pending",
          "force_send": true,
          "detail": "detail",
          "probe_status": "busy_turn_open",
          "terminal_state": "prompt_with_input"
        }
        """
        let parsed = parseStoredSendResultSnapshot(
            data: Data(json.utf8),
            updatedAtEpoch: 42
        )

        expect(parsed?.target == "demo", "expected stored send result parser to preserve target")
        expect(parsed?.statusKind == .accepted, "expected stored send result parser to preserve status")
        expect(parsed?.reasonKind == .verificationPending, "expected stored send result parser to preserve reason")
        expect(parsed?.forceSend == true, "expected stored send result parser to preserve force-send flag")
        expect(parsed?.updatedAtEpoch == 42, "expected stored send result parser to preserve supplied timestamp")
        expect(parseStoredSendResultSnapshot(data: Data("{}".utf8), updatedAtEpoch: 1) == nil, "expected stored send result parser to reject missing target")
    }

    private static func runRecentUserMessageEntryParsingChecks() {
        let rollout = """
        {"type":"event_msg","timestamp":"2026-04-19T00:00:00Z","payload":{"type":"assistant_message","message":"ignore"}}
        {"type":"event_msg","timestamp":"2026-04-19T00:00:01Z","payload":{"type":"user_message","message":" first "}}

        {"type":"event_msg","timestamp":"2026-04-19T00:00:02Z","payload":{"type":"user_message","message":"second"}}
        {"type":"event_msg","timestamp":"2026-04-19T00:00:03Z","payload":{"type":"user_message","message":"   "}}
        """

        let parsed = parseRecentUserMessageEntries(from: rollout)
        expect(parsed == [
            RecentUserMessageEntry(timestamp: "2026-04-19T00:00:01Z", message: "first"),
            RecentUserMessageEntry(timestamp: "2026-04-19T00:00:02Z", message: "second")
        ], "expected rollout parser to keep only non-empty user messages in order")

        let limited = parseRecentUserMessageEntries(from: rollout, limit: 1)
        expect(limited == [
            RecentUserMessageEntry(timestamp: "2026-04-19T00:00:02Z", message: "second")
        ], "expected rollout parser limit to keep trailing entries")
    }

    private static func runLoopSnapshotAccessorChecks() {
        let snapshot = LoopSnapshot(
            target: "demo",
            loopDaemonRunning: true,
            intervalSeconds: "30",
            forceSend: true,
            message: "hello",
            nextRunEpoch: 1234,
            stopped: false,
            stoppedReason: "",
            paused: true,
            failureCount: "0",
            failureReason: "",
            pauseReason: "",
            logPath: "-",
            lastLogLine: ""
        )

        expect(snapshot.isLoopDaemonRunning, "expected loop daemon running accessor to decode yes")
        expect(snapshot.isForceSendEnabled, "expected force-send accessor to decode yes")
        expect(!snapshot.isStopped, "expected stopped accessor to decode no")
        expect(snapshot.isPaused, "expected paused accessor to decode yes")
        expect(snapshot.nextRunTimeInterval == 1234, "expected next-run accessor to decode epoch")
    }

    private static func runSessionSnapshotAccessorChecks() {
        let snapshot = SessionSnapshot(
            name: "demo",
            target: "demo",
            threadID: "thread-1",
            provider: "openai",
            source: "cli",
            parentThreadID: "",
            agentNickname: "",
            agentRole: "",
            status: "busy_turn_open",
            reason: "",
            terminalState: "unavailable",
            tty: "ttys001",
            updatedAtEpoch: 4567,
            rolloutPath: "",
            preview: "",
            isArchived: false
        )

        expect(snapshot.updatedAtTimeInterval == 4567, "expected updated-at accessor to decode epoch")
        expect(snapshot.terminalStateKind == .unavailable, "expected terminal state accessor to decode unavailable")
        expect(snapshot.statusKind == .busyTurnOpen, "expected runtime status accessor to decode busy_turn_open")
    }

    private static func runMergeSessionSnapshotChecks() {
        let older = SessionSnapshot(
            name: "older",
            target: "older",
            threadID: "thread-1",
            provider: "openai",
            source: "cli",
            parentThreadID: "",
            agentNickname: "",
            agentRole: "",
            status: "ready",
            reason: "",
            terminalState: "ready",
            tty: "ttys001",
            updatedAtEpoch: 100,
            rolloutPath: "",
            preview: "",
            isArchived: false
        )
        let newer = SessionSnapshot(
            name: "newer",
            target: "newer",
            threadID: "thread-2",
            provider: "openai",
            source: "cli",
            parentThreadID: "",
            agentNickname: "",
            agentRole: "",
            status: "ready",
            reason: "",
            terminalState: "ready",
            tty: "ttys002",
            updatedAtEpoch: 200,
            rolloutPath: "",
            preview: "",
            isArchived: false
        )

        let merged = mergeSessionSnapshots(existing: [older], newSnapshots: [newer])
        expect(merged.map(\.threadID) == ["thread-2", "thread-1"], "expected mergeSessionSnapshots to sort by newest updatedAt")
    }

    private static func runOverlaySessionSnapshotChecks() {
        let existingA = SessionSnapshot(
            name: "a-old",
            target: "a",
            threadID: "thread-a",
            provider: "openai",
            source: "cli",
            parentThreadID: "",
            agentNickname: "",
            agentRole: "",
            status: "ready",
            reason: "",
            terminalState: "prompt_ready",
            tty: "ttys001",
            updatedAtEpoch: 100,
            rolloutPath: "",
            preview: "",
            isArchived: false
        )
        let existingB = SessionSnapshot(
            name: "b-old",
            target: "b",
            threadID: "thread-b",
            provider: "openai",
            source: "cli",
            parentThreadID: "",
            agentNickname: "",
            agentRole: "",
            status: "ready",
            reason: "",
            terminalState: "prompt_ready",
            tty: "ttys002",
            updatedAtEpoch: 90,
            rolloutPath: "",
            preview: "",
            isArchived: false
        )
        let refreshedB = SessionSnapshot(
            name: "b-new",
            target: "b",
            threadID: "thread-b",
            provider: "openai",
            source: "cli",
            parentThreadID: "",
            agentNickname: "",
            agentRole: "",
            status: "busy_turn_open",
            reason: "",
            terminalState: "prompt_with_input",
            tty: "ttys009",
            updatedAtEpoch: 120,
            rolloutPath: "",
            preview: "",
            isArchived: false
        )

        let overlaid = overlaySessionSnapshots(existing: [existingA, existingB], refreshed: [refreshedB])
        expect(overlaid.map(\.threadID) == ["thread-a", "thread-b"], "expected overlaySessionSnapshots to preserve existing order")
        expect(overlaid[0].name == "a-old", "expected overlaySessionSnapshots to preserve untouched entries")
        expect(overlaid[1].name == "b-new", "expected overlaySessionSnapshots to replace matching entries")

        let resolved = resolveClaimedSessionRefreshSnapshots(claimed: [existingB, existingA], refreshed: [refreshedB])
        expect(resolved.map(\.name) == ["b-new", "a-old"], "expected resolveClaimedSessionRefreshSnapshots to resolve refreshed entries and preserve claimed order")
    }

    private static func runMergeLoopSnapshotChecks() {
        let previous = LoopSnapshot(
            target: "demo",
            loopDaemonRunning: true,
            intervalSeconds: "30",
            forceSend: false,
            message: "hello",
            nextRunEpoch: 100,
            stopped: false,
            stoppedReason: "",
            paused: false,
            failureCount: "3",
            failureReason: "tty_unavailable",
            pauseReason: "verification_pending",
            logPath: "/tmp/previous.log",
            lastLogLine: "status=failed"
        )
        let incoming = LoopSnapshot(
            target: "demo",
            loopDaemonRunning: true,
            intervalSeconds: "30",
            forceSend: false,
            message: "hello",
            nextRunEpoch: 200,
            stopped: false,
            stoppedReason: "",
            paused: false,
            failureCount: "0",
            failureReason: "",
            pauseReason: "",
            logPath: "-",
            lastLogLine: ""
        )

        let merged = mergeLoopSnapshot(previous: previous, incoming: incoming)
        expect(merged.failureCount == "3", "expected loop merge to preserve prior failure count when incoming is underspecified")
        expect(merged.failureReason == "tty_unavailable", "expected loop merge to preserve prior failure reason when incoming is underspecified")
        expect(merged.pauseReason == "verification_pending", "expected loop merge to preserve prior pause reason when incoming is underspecified")
        expect(merged.logPath == "/tmp/previous.log", "expected loop merge to preserve prior log path placeholder fallback")
        expect(merged.lastLogLine == "status=failed", "expected loop merge to preserve prior last log line when incoming is underspecified")
    }

    private static func runMergeLoopSnapshotListChecks() {
        let previous = LoopSnapshot(
            target: "demo",
            loopDaemonRunning: true,
            intervalSeconds: "30",
            forceSend: false,
            message: "hello",
            nextRunEpoch: 100,
            stopped: false,
            stoppedReason: "",
            paused: false,
            failureCount: "2",
            failureReason: "tty_unavailable",
            pauseReason: "",
            logPath: "/tmp/demo.log",
            lastLogLine: "failed"
        )
        let incomingMerged = LoopSnapshot(
            target: "demo",
            loopDaemonRunning: true,
            intervalSeconds: "30",
            forceSend: false,
            message: "hello",
            nextRunEpoch: 120,
            stopped: false,
            stoppedReason: "",
            paused: false,
            failureCount: "0",
            failureReason: "",
            pauseReason: "",
            logPath: "-",
            lastLogLine: ""
        )
        let incomingFresh = LoopSnapshot(
            target: "demo-2",
            loopDaemonRunning: true,
            intervalSeconds: "60",
            forceSend: true,
            message: "world",
            nextRunEpoch: 150,
            stopped: false,
            stoppedReason: "",
            paused: false,
            failureCount: "0",
            failureReason: "",
            pauseReason: "",
            logPath: "/tmp/demo-2.log",
            lastLogLine: ""
        )

        let merged = mergeLoopSnapshots(previous: [previous], incoming: [incomingMerged, incomingFresh])
        expect(merged.map(\.target) == ["demo", "demo-2"], "expected mergeLoopSnapshots to preserve incoming order")
        expect(merged[0].failureReason == "tty_unavailable", "expected mergeLoopSnapshots to reuse per-target fallback merge")
        expect(merged[1].target == "demo-2", "expected mergeLoopSnapshots to keep brand new entries untouched")
    }

    private static func runLocalizationChecks() {
        expect(localizedSendReason("missing_accessibility_permission") == "缺少辅助功能权限", "expected permission failure to localize consistently")
        expect(localizedTerminalState("queued_messages_pending") == "消息排队中", "expected queued terminal state to localize consistently")
        expect(
            localizedSessionReason("a started turn has no later task_complete") == "检测到已开始的回合，但后面没有看到 task_complete，当前可能仍在执行",
            "expected known session reason to localize consistently"
        )
        expect(
            localizedSessionReason("osascript failed: not authorized") == "读取 Terminal 状态失败: not authorized",
            "expected osascript session reason to preserve detail with localized prefix"
        )
    }

    private static func runLoopStateLabelChecks() {
        let snapshot = LoopSnapshot(
            target: "demo",
            loopDaemonRunning: true,
            intervalSeconds: "30",
            forceSend: false,
            message: "hello",
            nextRunEpoch: 1234,
            stopped: true,
            stoppedReason: "manual_stop",
            paused: false,
            failureCount: "0",
            failureReason: "",
            pauseReason: "",
            logPath: "-",
            lastLogLine: ""
        )

        expect(loopStateLabel(snapshot) == "停止", "expected stopped loop to map to 停止 state")
        expect(loopResultLabel(snapshot) == "已停止", "expected stopped loop to map to 已停止 result")
    }

    private static func runProbeStateRuleChecks() {
        expect(shouldAutoClearResidualInput(probeStatus: "idle_with_residual_input", terminalState: "prompt_with_input"), "expected residual input rule to match runtime")
        expect(isSendableProbeState(probeStatus: "idle_stable", terminalState: "prompt_ready"), "expected idle stable prompt-ready to be sendable")
        expect(isSendableProbeState(probeStatus: "idle_with_residual_input", terminalState: "prompt_with_input"), "expected residual input case to remain sendable")
        expect(!isSendableProbeState(probeStatus: "busy_turn_open", terminalState: "prompt_with_input"), "expected busy prompt-with-input to remain blocked")
    }

    private static func runQueuedAcceptanceRuleChecks() {
        expect(shouldTreatAsQueuedAcceptance(probeStatus: 0, terminalState: "queued_messages_pending", reason: ""), "expected queued terminal state to map to accepted")
        expect(shouldTreatAsQueuedAcceptance(probeStatus: 0, terminalState: "unknown", reason: "turn is complete, but queued messages are still visible in Terminal"), "expected queued reason text to map to accepted")
        expect(!shouldTreatAsQueuedAcceptance(probeStatus: 1, terminalState: "queued_messages_pending", reason: ""), "expected failed probe status to block queued acceptance")
    }

    private static func runAmbiguousTargetRuleChecks() {
        expect(isAmbiguousTargetDetail("found multiple matching sessions for target demo"), "expected session ambiguity text to be recognized")
        expect(isAmbiguousTargetDetail("found multiple matching Terminal ttys for target demo"), "expected tty ambiguity text to be recognized")
        expect(!isAmbiguousTargetDetail("tty unavailable"), "expected unrelated detail to stay non-ambiguous")
    }

    private static func runSendPreflightDecisionChecks() {
        let ttyUnavailable = evaluateSendPreflight(
            forceSend: false,
            tty: "",
            probeStatus: "idle_stable",
            terminalState: "prompt_ready",
            detail: "tty unavailable"
        )
        expect(!ttyUnavailable.canSend, "expected empty tty to block send")
        expect(ttyUnavailable.failureReason == "tty_unavailable", "expected empty tty to map to tty_unavailable")

        let ambiguous = evaluateSendPreflight(
            forceSend: false,
            tty: "",
            probeStatus: "idle_stable",
            terminalState: "prompt_ready",
            detail: "found multiple matching sessions for target demo"
        )
        expect(!ambiguous.canSend, "expected ambiguous empty tty to block send")
        expect(ambiguous.failureReason == "ambiguous_target", "expected ambiguity detail to win over tty_unavailable")

        let notSendable = evaluateSendPreflight(
            forceSend: false,
            tty: "ttys001",
            probeStatus: "busy_turn_open",
            terminalState: "prompt_with_input",
            detail: "busy"
        )
        expect(!notSendable.canSend, "expected busy prompt-with-input to remain blocked")
        expect(notSendable.failureReason == "not_sendable", "expected blocked sendable state to map to not_sendable")

        let residualInput = evaluateSendPreflight(
            forceSend: false,
            tty: "ttys001",
            probeStatus: "idle_with_residual_input",
            terminalState: "prompt_with_input",
            detail: "residual"
        )
        expect(residualInput.canSend, "expected residual input case to stay sendable")
        expect(residualInput.shouldClearResidualInput, "expected residual input case to request clear-existing-input")

        let forcedSend = evaluateSendPreflight(
            forceSend: true,
            tty: "ttys001",
            probeStatus: "busy_turn_open",
            terminalState: "prompt_with_input",
            detail: "forced"
        )
        expect(forcedSend.canSend, "expected force-send to bypass sendability gate")
        expect(!forcedSend.shouldClearResidualInput, "expected force-send to skip residual-input clearing")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
