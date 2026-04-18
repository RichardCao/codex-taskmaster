import Foundation

@main
struct TaskMasterCoreRegressionRunner {
    static func main() {
        runLoopSnapshotAccessorChecks()
        runSessionSnapshotAccessorChecks()
        runMergeSessionSnapshotChecks()
        print("taskmaster_core_regression_ok")
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

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
