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
        runLoopSnapshotIdentityChecks()
        runTableCellFormattingChecks()
        runLoopConflictResolutionChecks()
        runLocalizationChecks()
        runStatusPresentationChecks()
        runAlertTemplateChecks()
        runSelectionAndBlockedCopyChecks()
        runLoopStateLabelChecks()
        runProbeStateRuleChecks()
        runQueuedAcceptanceRuleChecks()
        runAmbiguousTargetRuleChecks()
        runSendPreflightDecisionChecks()
        runSendRuntimeDecisionMatrixChecks()
        runRestrictedEnvironmentChecks()
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

    private static func runLoopSnapshotIdentityChecks() {
        let parsed = parseLoopStatusJSONOutput("""
        {
          "loops": [
            {
              "loop_id": "loop-1",
              "target": "demo",
              "loop_daemon_running": true,
              "interval_seconds": "30",
              "force_send": false,
              "message": "hello",
              "next_run_epoch": 100,
              "stopped": false,
              "paused": false,
              "failure_count": "0",
              "log": "/tmp/demo.log"
            }
          ],
          "warnings": []
        }
        """)
        expect(parsed?.loops.first?.loopID == "loop-1", "expected loop status parser to preserve loop_id")

        let previousStopped = LoopSnapshot(
            loopID: "stopped-history",
            target: "demo",
            loopDaemonRunning: false,
            intervalSeconds: "30",
            forceSend: false,
            message: "old",
            nextRunEpoch: 0,
            stopped: true,
            stoppedReason: "manual_stop",
            paused: false,
            failureCount: "0",
            failureReason: "",
            pauseReason: "",
            logPath: "-",
            lastLogLine: ""
        )
        let optimisticRunning = LoopSnapshot(
            loopID: "",
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
        let refreshedRunning = LoopSnapshot(
            loopID: "active-key",
            target: "demo",
            loopDaemonRunning: true,
            intervalSeconds: "30",
            forceSend: false,
            message: "hello",
            nextRunEpoch: 140,
            stopped: false,
            stoppedReason: "",
            paused: false,
            failureCount: "0",
            failureReason: "",
            pauseReason: "",
            logPath: "/tmp/active.log",
            lastLogLine: ""
        )

        let merged = mergeLoopSnapshots(previous: [previousStopped, optimisticRunning], incoming: [refreshedRunning, previousStopped])
        expect(merged.map(\.loopID) == ["active-key", "stopped-history"], "expected mergeLoopSnapshots to preserve distinct identities for active and historical loops")
    }

    private static func runTableCellFormattingChecks() {
        let duplicateLoop = LoopSnapshot(
            loopID: "loop-1234567890",
            target: "demo",
            loopDaemonRunning: true,
            intervalSeconds: "30",
            forceSend: true,
            message: "hello",
            nextRunEpoch: 123,
            stopped: false,
            stoppedReason: "",
            paused: false,
            failureCount: "0",
            failureReason: "",
            pauseReason: "",
            logPath: "-",
            lastLogLine: "last line"
        )
        let siblingLoop = LoopSnapshot(
            loopID: "loop-abcdef",
            target: "demo",
            loopDaemonRunning: false,
            intervalSeconds: "60",
            forceSend: false,
            message: "older",
            nextRunEpoch: 0,
            stopped: true,
            stoppedReason: "stopped_by_user",
            paused: false,
            failureCount: "0",
            failureReason: "",
            pauseReason: "",
            logPath: "-",
            lastLogLine: ""
        )
        let session = SessionSnapshot(
            name: "",
            target: "demo",
            threadID: "thread-1",
            provider: "",
            source: "exec",
            parentThreadID: "",
            agentNickname: "",
            agentRole: "",
            status: "busy_turn_open",
            reason: "a started turn has no later task_complete",
            terminalState: "unavailable",
            tty: "",
            updatedAtEpoch: 456,
            rolloutPath: "",
            preview: "",
            isArchived: false
        )

        expect(loopSelectionIdentifier(duplicateLoop) == "id:loop-1234567890", "expected loopSelectionIdentifier to prefer loop_id")
        expect(formattedLoopTargetDisplayValue(loop: duplicateLoop, allLoops: [duplicateLoop, siblingLoop]) == "demo #loop-123", "expected duplicate target display to include short loop id")
        expect(formattedLoopTargetToolTip(loop: duplicateLoop, allLoops: [duplicateLoop, siblingLoop]) == "demo\nloop_id: loop-1234567890", "expected duplicate target tooltip to preserve full loop id")
        expect(
            formattedLoopTableCellValue(
                identifier: "nextRun",
                loop: duplicateLoop,
                allLoops: [duplicateLoop, siblingLoop],
                formatEpoch: { "epoch:\(Int($0))" }
            ) == "epoch:123",
            "expected loop table formatter to delegate next-run formatting"
        )
        expect(
            formattedLoopTableCellValue(
                identifier: "target",
                loop: duplicateLoop,
                allLoops: [duplicateLoop, siblingLoop],
                formatEpoch: { _ in "-" }
            ) == "demo #loop-123",
            "expected loop table formatter to reuse duplicate target display rules"
        )
        expect(
            formattedSessionTableCellValue(
                identifier: "updatedAt",
                session: session,
                formatEpoch: { "epoch:\(Int($0))" }
            ) == "epoch:456",
            "expected session table formatter to delegate updated-at formatting"
        )
        expect(
            formattedSessionTableCellValue(
                identifier: "terminalState",
                session: session,
                formatEpoch: { _ in "-" }
            ) == "不可达",
            "expected session table formatter to localize terminal state"
        )
        expect(
            formattedSessionTableCellValue(
                identifier: "reason",
                session: session,
                formatEpoch: { _ in "-" }
            ) == "检测到已开始的回合，但后面没有看到 task_complete，当前可能仍在执行",
            "expected session table formatter to localize session reason"
        )
    }

    private static func runStatusPresentationChecks() {
        expect(resolvedStatusPresentationTone(text: "开始循环执行中…", key: "action") == .progress, "expected running action status to map to progress tone")
        expect(resolvedStatusPresentationTone(text: "开始循环失败", key: "action") == .failure, "expected failed action status to map to failure tone")
        expect(resolvedStatusPresentationTone(text: "请选择一个循环任务", key: "action") == .warning, "expected selection prompt to map to warning tone")
        expect(resolvedStatusPresentationTone(text: "开始循环完成", key: "action") == .success, "expected completed action status to map to success tone")
        expect(statusAutoClearDelay(text: "开始循环执行中…", key: "action") == nil, "expected progress status to disable auto clear")
        expect(statusAutoClearDelay(text: "开始循环失败", key: "action") == 10, "expected failure action status to keep failure delay")
        expect(
            resolvedVisibleStatusSegment(
                segments: [
                    "general": "General",
                    "scan": "Scan",
                    "action": "Action"
                ]
            ) == VisibleStatusSegment(key: "action", text: "Action"),
            "expected action segment to outrank scan and general"
        )
        expect(
            resolvedVisibleStatusSegment(
                segments: [
                    "zzz": "Fallback",
                    "aaa": "Earlier"
                ]
            ) == VisibleStatusSegment(key: "aaa", text: "Earlier"),
            "expected fallback segment resolution to stay stable by key order"
        )
        expect(defaultVisibleStatusText() == "Ready", "expected default visible status text to remain Ready")
    }

    private static func runAlertTemplateChecks() {
        let session = SessionSnapshot(
            name: "Friendly",
            target: "demo",
            threadID: "thread-1",
            provider: "openai",
            source: "cli",
            parentThreadID: "",
            agentNickname: "",
            agentRole: "",
            status: "active",
            reason: "",
            terminalState: "prompt_ready",
            tty: "ttys001",
            updatedAtEpoch: 1,
            rolloutPath: "",
            preview: "",
            isArchived: false
        )
        let conflictLoop = LoopSnapshot(
            target: "demo",
            loopDaemonRunning: true,
            intervalSeconds: "30",
            forceSend: false,
            message: "hello",
            nextRunEpoch: 0,
            stopped: false,
            stoppedReason: "",
            paused: false,
            failureCount: "0",
            failureReason: "",
            pauseReason: "",
            logPath: "-",
            lastLogLine: ""
        )

        expect(ambiguousTargetAlertTitle() == "目标不唯一", "expected ambiguous target alert title to stay stable")
        expect(
            ambiguousTargetAlertText(actionName: "开始循环", detail: "found multiple matching sessions").contains("无法直接开始循环"),
            "expected ambiguous target alert text to embed action name"
        )
        expect(
            runtimePermissionAlertText(
                actionName: "发送一次",
                runtimeDirectoryPath: "/tmp/runtime",
                userLoopStateDirectoryPath: "/tmp/user-loop",
                legacyLoopStateDirectoryPath: "/tmp/legacy-loop",
                detail: "permission denied"
            ).contains("permission denied"),
            "expected runtime permission alert text to preserve detail"
        )
        expect(
            sessionActionBlockedAlertText(actionLabel: "归档", session: session, detail: "", ambiguous: false).contains("Session ID: thread-1"),
            "expected session blocked alert text to include thread id"
        )
        expect(
            sessionActionBlockedAlertText(actionLabel: "归档", session: session, detail: "", ambiguous: true).contains("多个活跃 Terminal/Codex 目标"),
            "expected ambiguous session blocked alert text to preserve ambiguity guidance"
        )
        expect(
            loopConflictAlertText(target: "demo", conflicts: [conflictLoop]).contains("目标 demo 已存在运行中的循环"),
            "expected loop conflict alert text to include conflict target"
        )
    }

    private static func runSelectionAndBlockedCopyChecks() {
        expect(sessionSelectionRequiredStatusText() == "请选择一个 session", "expected session selection required text to stay stable")
        expect(loopSelectionRequiredLogText() == "请先在 Active Loops 中选择一条循环任务。", "expected loop selection required log text to stay stable")
        expect(loopSelectionRequiredStatusText() == "请选择一个循环任务", "expected loop selection required status text to stay stable")
        expect(stoppedLoopBlockedStatusText() == "当前循环已停止", "expected stopped loop blocked status text to stay stable")
        expect(resumeLoopBlockedStatusText() == "当前循环不可恢复", "expected resume loop blocked status text to stay stable")
        expect(accessibilityPermissionDeniedStatusText() == "缺少辅助功能权限", "expected permission denied status text to stay stable")
        expect(emptyMessageRequiredStatusText() == "请填写输出内容", "expected empty message status text to stay stable")
    }

    private static func runLoopConflictResolutionChecks() {
        let session = SessionSnapshot(
            name: "friendly-name",
            target: "session-target",
            threadID: "thread-1",
            provider: "openai",
            source: "cli",
            parentThreadID: "",
            agentNickname: "",
            agentRole: "",
            status: "idle_stable",
            reason: "",
            terminalState: "prompt_ready",
            tty: "ttys001",
            updatedAtEpoch: 1,
            rolloutPath: "",
            preview: "preview-name",
            isArchived: false
        )
        let runningAlias = LoopSnapshot(
            target: "friendly-name",
            loopDaemonRunning: true,
            intervalSeconds: "30",
            forceSend: false,
            message: "hello",
            nextRunEpoch: 0,
            stopped: false,
            stoppedReason: "",
            paused: false,
            failureCount: "0",
            failureReason: "",
            pauseReason: "",
            logPath: "-",
            lastLogLine: ""
        )
        let stoppedAlias = LoopSnapshot(
            target: "thread-1",
            loopDaemonRunning: false,
            intervalSeconds: "60",
            forceSend: false,
            message: "old",
            nextRunEpoch: 0,
            stopped: true,
            stoppedReason: "manual_stop",
            paused: false,
            failureCount: "0",
            failureReason: "",
            pauseReason: "",
            logPath: "-",
            lastLogLine: ""
        )
        let unrelated = LoopSnapshot(
            target: "other-session",
            loopDaemonRunning: true,
            intervalSeconds: "45",
            forceSend: false,
            message: "world",
            nextRunEpoch: 0,
            stopped: false,
            stoppedReason: "",
            paused: false,
            failureCount: "0",
            failureReason: "",
            pauseReason: "",
            logPath: "-",
            lastLogLine: ""
        )

        let targets = loopTargetsAffectingSession(session, loopSnapshots: [runningAlias, stoppedAlias, unrelated])
        expect(targets == ["friendly-name", "thread-1"], "expected loopTargetsAffectingSession to preserve matching target order")

        let conflicts = runningLoopConflicts(
            for: "thread-1",
            sessionSnapshots: [session],
            loopSnapshots: [runningAlias, stoppedAlias, unrelated]
        )
        expect(conflicts.map(\.target) == ["friendly-name"], "expected runningLoopConflicts to keep only running loops affecting the same session")

        let directConflicts = runningLoopConflicts(
            for: "other-session",
            sessionSnapshots: [session],
            loopSnapshots: [runningAlias, stoppedAlias, unrelated]
        )
        expect(directConflicts.map(\.target) == ["other-session"], "expected runningLoopConflicts to fall back to direct target matching")
    }

    private static func runLocalizationChecks() {
        expect(localizedSendReason("missing_accessibility_permission") == "缺少辅助功能权限", "expected permission failure to localize consistently")
        expect(localizedTerminalState("queued_messages_pending") == "消息排队中", "expected queued terminal state to localize consistently")
        expect(localizedTerminalState("footer_visible_only") == "仅见模型底栏", "expected footer-only terminal state to localize consistently")
        expect(localizedLoopTerminalState("footer_visible_only") == "仅看到模型底栏", "expected footer-only loop terminal state to localize consistently")
        expect(localizedProbeStatus("idle_with_queued_messages") == "空闲但消息排队", "expected queued idle probe status to localize consistently")
        expect(
            localizedSessionReason("a started turn has no later task_complete") == "检测到已开始的回合，但后面没有看到 task_complete，当前可能仍在执行",
            "expected known session reason to localize consistently"
        )
        expect(
            localizedSessionReason("osascript failed: not authorized") == "读取 Terminal 状态失败: not authorized",
            "expected osascript session reason to preserve detail with localized prefix"
        )
        let queuedIdle = SessionSnapshot(
            name: "queued",
            target: "queued",
            threadID: "thread-queued",
            provider: "openai",
            source: "cli",
            parentThreadID: "",
            agentNickname: "",
            agentRole: "",
            status: "idle_with_queued_messages",
            reason: "turn is complete, but queued messages are still visible in Terminal",
            terminalState: "queued_messages_pending",
            tty: "ttys001",
            updatedAtEpoch: 1,
            rolloutPath: "",
            preview: "",
            isArchived: false
        )
        expect(localizedSessionStatusLabel(queuedIdle) == "消息排队", "expected queued idle session status to map to 消息排队")
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
        expect(detailedNotSendableLabel(probeStatus: "idle_stable", terminalState: "footer_visible_only") == "仅见模型底栏", "expected footer-only terminal state to map to the new blocked label")
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

    private static func runSendRuntimeDecisionMatrixChecks() {
        expect(localizedSendReason("request_still_processing") == "请求仍在处理", "expected request_still_processing to localize consistently")
        expect(localizedSendReason("request_already_inflight") == "相同请求已在队列中", "expected request_already_inflight to localize consistently")

        let inflightReason = formattedLoopOutcomeReason(
            reason: "request_already_inflight",
            probeStatus: "busy_turn_open",
            terminalState: "prompt_with_input"
        )
        expect(
            inflightReason == "相同请求已在队列中 | 回合进行中 | 提示符上有输入",
            "expected formattedLoopOutcomeReason to preserve localized runtime context ordering"
        )

        let processingReason = formattedLoopOutcomeReason(
            reason: "request_still_processing",
            probeStatus: "post_finalizing",
            terminalState: "no_visible_prompt"
        )
        expect(
            processingReason == "请求仍在处理 | 正在收尾 | 未看到可用提示符",
            "expected formattedLoopOutcomeReason to preserve localized processing context"
        )
    }

    private static func runRestrictedEnvironmentChecks() {
        let disconnected = SessionSnapshot(
            name: "disconnected",
            target: "disconnected",
            threadID: "thread-disconnected",
            provider: "openai",
            source: "cli",
            parentThreadID: "",
            agentNickname: "",
            agentRole: "",
            status: "idle_stable",
            reason: "",
            terminalState: "unavailable",
            tty: "",
            updatedAtEpoch: 1,
            rolloutPath: "",
            preview: "",
            isArchived: false
        )
        let activeUnavailable = SessionSnapshot(
            name: "active",
            target: "active",
            threadID: "thread-active",
            provider: "openai",
            source: "cli",
            parentThreadID: "",
            agentNickname: "",
            agentRole: "",
            status: "busy_turn_open",
            reason: "",
            terminalState: "unavailable",
            tty: "",
            updatedAtEpoch: 1,
            rolloutPath: "",
            preview: "",
            isArchived: false
        )

        expect(localizedSessionStatusLabel(disconnected) == "断联", "expected unavailable idle session to collapse into disconnected status")
        expect(localizedSessionStatusLabel(activeUnavailable) == "运行中", "expected unavailable active session to keep active status")

        let coordinator = SessionStatusRefreshCoordinator(connectedRefreshInterval: 15, disconnectedRefreshInterval: 60)
        let initialClaim = coordinator.claim([disconnected, activeUnavailable], requireDue: false, referenceDate: Date())
        expect(initialClaim.map(\.threadID) == ["thread-disconnected", "thread-active"], "expected coordinator to claim both snapshots initially")

        let now = Date()
        for snapshot in initialClaim {
            coordinator.scheduleNext(for: snapshot, from: now)
        }

        let dueSoon = coordinator.claim([disconnected, activeUnavailable], requireDue: true, referenceDate: now.addingTimeInterval(20))
        expect(dueSoon.map(\.threadID) == ["thread-active"], "expected connected session to become due before disconnected session")

        for snapshot in dueSoon {
            coordinator.scheduleNext(for: snapshot, from: now.addingTimeInterval(20))
        }

        let dueLater = coordinator.claim([disconnected, activeUnavailable], requireDue: true, referenceDate: now.addingTimeInterval(90))
        expect(dueLater.count == 2, "expected both connected and disconnected sessions to become due eventually")

        let permissionLoop = LoopSnapshot(
            target: "demo",
            loopDaemonRunning: true,
            intervalSeconds: "30",
            forceSend: false,
            message: "hello",
            nextRunEpoch: 0,
            stopped: false,
            stoppedReason: "",
            paused: false,
            failureCount: "1",
            failureReason: "missing_accessibility_permission",
            pauseReason: "",
            logPath: "-",
            lastLogLine: ""
        )
        expect(loopResultLabel(permissionLoop) == "权限缺失", "expected permission-restricted loop to surface 权限缺失 result")
        expect(loopStateLabel(permissionLoop) == "失败", "expected permission-restricted loop to map to failure state")
        expect(loopResultReasonLabel(permissionLoop) == "缺少辅助功能权限", "expected permission-restricted loop to expose localized reason")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
