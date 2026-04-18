import XCTest
@testable import TaskMasterCoreLib

final class TaskMasterCoreLibTests: XCTestCase {
    func testParseStructuredKeyValueFieldsReadsStructuredOutput() {
        let text = """
        status: failed
        reason: not_sendable
        detail: target busy
        """

        let fields = parseStructuredKeyValueFields(text)

        XCTAssertEqual(fields?["status"], "failed")
        XCTAssertEqual(fields?["reason"], "not_sendable")
        XCTAssertEqual(fields?["detail"], "target busy")
    }

    func testPreferredCommandDetailPrefersStderrThenStdout() {
        XCTAssertEqual(preferredCommandDetail(stdout: "stdout detail", stderr: ""), "stdout detail")
        XCTAssertEqual(preferredCommandDetail(stdout: "stdout detail", stderr: "stderr detail"), "stderr detail")
    }

    func testCompactProbeSummaryFormatsExpectedKeys() {
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

        XCTAssertEqual(summary, "target: demo | thread_id: thread-1 | tty: ttys001 | status: idle_stable | reason: ready | terminal_state: prompt_ready")
    }

    func testMakeSendRequestResultPayloadBuildsExpectedFields() {
        let payload = makeSendRequestResultPayload(
            status: "accepted",
            reason: "verification_pending",
            target: "demo",
            forceSend: true,
            detail: "detail",
            probeStatus: "idle_stable",
            terminalState: "prompt_ready"
        )

        XCTAssertEqual(payload["status"] as? String, "accepted")
        XCTAssertEqual(payload["reason"] as? String, "verification_pending")
        XCTAssertEqual(payload["target"] as? String, "demo")
        XCTAssertEqual(payload["force_send"] as? Bool, true)
        XCTAssertEqual(payload["detail"] as? String, "detail")
        XCTAssertEqual(payload["probe_status"] as? String, "idle_stable")
        XCTAssertEqual(payload["terminal_state"] as? String, "prompt_ready")
    }

    func testEvaluateSendVerificationDecisionMatchesRuntimeRules() {
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
        XCTAssertEqual(success.status, "success")
        XCTAssertEqual(success.reason, "forced_sent")
        XCTAssertEqual(success.probeStatus, "idle_stable")

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
        XCTAssertEqual(queued.status, "accepted")
        XCTAssertEqual(queued.reason, "queued_pending_feedback")
        XCTAssertEqual(queued.terminalState, "queued_messages_pending")

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
        XCTAssertEqual(pending.status, "accepted")
        XCTAssertEqual(pending.reason, "verification_pending")
        XCTAssertEqual(pending.probeStatus, "busy_turn_open")
    }

    func testLoopSnapshotTypedAccessors() {
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

        XCTAssertTrue(snapshot.isLoopDaemonRunning)
        XCTAssertTrue(snapshot.isForceSendEnabled)
        XCTAssertFalse(snapshot.isStopped)
        XCTAssertTrue(snapshot.isPaused)
        XCTAssertEqual(snapshot.nextRunTimeInterval, 1234)
    }

    func testSessionSnapshotUpdatedAtTimeInterval() {
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

        XCTAssertEqual(snapshot.updatedAtTimeInterval, 4567)
    }

    func testMergeSessionSnapshotsSortsByNewestUpdatedAt() {
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

        XCTAssertEqual(merged.map(\.threadID), ["thread-2", "thread-1"])
    }

    func testLocalizedSendReasonMapsPermissionFailure() {
        XCTAssertEqual(localizedSendReason("missing_accessibility_permission"), "缺少辅助功能权限")
    }

    func testLoopStateAndResultLabelsForStoppedLoop() {
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

        XCTAssertEqual(loopStateLabel(snapshot), "停止")
        XCTAssertEqual(loopResultLabel(snapshot), "已停止")
    }

    func testProbeStateHelpersMatchRuntimeRules() {
        XCTAssertTrue(shouldAutoClearResidualInput(probeStatus: "idle_with_residual_input", terminalState: "prompt_with_input"))
        XCTAssertTrue(isSendableProbeState(probeStatus: "idle_stable", terminalState: "prompt_ready"))
        XCTAssertTrue(isSendableProbeState(probeStatus: "idle_with_residual_input", terminalState: "prompt_with_input"))
        XCTAssertFalse(isSendableProbeState(probeStatus: "busy_turn_open", terminalState: "prompt_with_input"))
    }

    func testQueuedAcceptanceHelperMatchesRuntimeRules() {
        XCTAssertTrue(shouldTreatAsQueuedAcceptance(probeStatus: 0, terminalState: "queued_messages_pending", reason: ""))
        XCTAssertTrue(shouldTreatAsQueuedAcceptance(probeStatus: 0, terminalState: "unknown", reason: "turn is complete, but queued messages are still visible in Terminal"))
        XCTAssertFalse(shouldTreatAsQueuedAcceptance(probeStatus: 1, terminalState: "queued_messages_pending", reason: ""))
    }

    func testAmbiguousTargetDetailHelperMatchesRuntimeRules() {
        XCTAssertTrue(isAmbiguousTargetDetail("found multiple matching sessions for target demo"))
        XCTAssertTrue(isAmbiguousTargetDetail("found multiple matching Terminal ttys for target demo"))
        XCTAssertFalse(isAmbiguousTargetDetail("tty unavailable"))
    }

    func testEvaluateSendPreflightMatchesRuntimeRules() {
        let ttyUnavailable = evaluateSendPreflight(
            forceSend: false,
            tty: "",
            probeStatus: "idle_stable",
            terminalState: "prompt_ready",
            detail: "tty unavailable"
        )
        XCTAssertFalse(ttyUnavailable.canSend)
        XCTAssertEqual(ttyUnavailable.failureReason, "tty_unavailable")

        let ambiguous = evaluateSendPreflight(
            forceSend: false,
            tty: "",
            probeStatus: "idle_stable",
            terminalState: "prompt_ready",
            detail: "found multiple matching sessions for target demo"
        )
        XCTAssertFalse(ambiguous.canSend)
        XCTAssertEqual(ambiguous.failureReason, "ambiguous_target")

        let notSendable = evaluateSendPreflight(
            forceSend: false,
            tty: "ttys001",
            probeStatus: "busy_turn_open",
            terminalState: "prompt_with_input",
            detail: "busy"
        )
        XCTAssertFalse(notSendable.canSend)
        XCTAssertEqual(notSendable.failureReason, "not_sendable")

        let residualInput = evaluateSendPreflight(
            forceSend: false,
            tty: "ttys001",
            probeStatus: "idle_with_residual_input",
            terminalState: "prompt_with_input",
            detail: "residual"
        )
        XCTAssertTrue(residualInput.canSend)
        XCTAssertTrue(residualInput.shouldClearResidualInput)

        let forcedSend = evaluateSendPreflight(
            forceSend: true,
            tty: "ttys001",
            probeStatus: "busy_turn_open",
            terminalState: "prompt_with_input",
            detail: "forced"
        )
        XCTAssertTrue(forcedSend.canSend)
        XCTAssertFalse(forcedSend.shouldClearResidualInput)
    }
}
