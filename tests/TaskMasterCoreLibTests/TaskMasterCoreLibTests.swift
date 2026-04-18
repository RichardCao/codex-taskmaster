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
