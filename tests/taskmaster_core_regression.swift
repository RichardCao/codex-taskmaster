import Foundation

@main
struct TaskMasterCoreRegressionRunner {
    static func main() {
        runStructuredFieldParsingChecks()
        runCommandDetailChecks()
        runCompactProbeSummaryChecks()
        runSendRequestPayloadChecks()
        runSendVerificationDecisionChecks()
        runLoopSnapshotAccessorChecks()
        runSessionSnapshotAccessorChecks()
        runMergeSessionSnapshotChecks()
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
        expect(success.reason == "forced_sent", "expected forced successful verification to map to forced_sent")

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
        expect(queued.reason == "queued_pending_feedback", "expected queued verification to map to queued_pending_feedback")

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
        expect(pending.reason == "verification_pending", "expected unconfirmed verification to map to verification_pending")
        expect(pending.probeStatus == "busy_turn_open", "expected pending verification to preserve latest probe status")
    }

    private static func runLoopSnapshotAccessorChecks() {
        let snapshot = LoopSnapshot(
            target: "demo",
            loopDaemonRunning: "yes",
            intervalSeconds: "30",
            forceSend: "yes",
            message: "hello",
            nextRunEpoch: "1234",
            stopped: "no",
            stoppedReason: "",
            paused: "yes",
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
            status: "ready",
            reason: "",
            terminalState: "ready",
            tty: "ttys001",
            updatedAtEpoch: "4567",
            rolloutPath: "",
            preview: "",
            isArchived: false
        )

        expect(snapshot.updatedAtTimeInterval == 4567, "expected updated-at accessor to decode epoch")
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
            updatedAtEpoch: "100",
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
            updatedAtEpoch: "200",
            rolloutPath: "",
            preview: "",
            isArchived: false
        )

        let merged = mergeSessionSnapshots(existing: [older], newSnapshots: [newer])
        expect(merged.map(\.threadID) == ["thread-2", "thread-1"], "expected mergeSessionSnapshots to sort by newest updatedAt")
    }

    private static func runLocalizationChecks() {
        expect(localizedSendReason("missing_accessibility_permission") == "缺少辅助功能权限", "expected permission failure to localize consistently")
    }

    private static func runLoopStateLabelChecks() {
        let snapshot = LoopSnapshot(
            target: "demo",
            loopDaemonRunning: "yes",
            intervalSeconds: "30",
            forceSend: "no",
            message: "hello",
            nextRunEpoch: "1234",
            stopped: "yes",
            stoppedReason: "manual_stop",
            paused: "no",
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
