import XCTest
@testable import TaskMasterCoreLib

final class TaskMasterCoreLibTests: XCTestCase {
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
}
