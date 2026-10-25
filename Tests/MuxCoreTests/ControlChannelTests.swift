import XCTest
@testable import MuxCore

private actor Recorder {
    var writes: [Data] = []
    var events: [ControlEvent] = []
    func record(_ bytes: Data) { writes.append(bytes) }
    func record(_ event: ControlEvent) { events.append(event) }
}

final class ControlChannelTests: XCTestCase {
    private func waitForWrites(_ count: Int, recorder: Recorder) async throws {
        for _ in 0..<100 {
            if await recorder.writes.count >= count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Command was not sent")
    }
    func testCommandsWaitForAttachAndSerializeWhileOutputContinues() async throws {
        let recorder = Recorder()
        let channel = ControlChannel(writer: { await recorder.record($0) }, onEvent: { await recorder.record($0) })
        let first = Task { try await channel.command("list-sessions") }
        try await Task.sleep(nanoseconds: 5_000_000)
        let beforeAttach = await recorder.writes
        XCTAssertTrue(beforeAttach.isEmpty)
        await channel.receive(Data("%begin 1 1 0\n%end 1 1 0\n".utf8))
        try await waitForWrites(1, recorder: recorder)
        let second = Task { try await channel.command("list-windows") }
        await channel.receive(Data("%output %1 a\\012\n%begin 2 2 1\n$0\tmain\n%end 2 2 1\n".utf8))
        let firstResult = try await first.value
        XCTAssertEqual(firstResult, ["$0\tmain"])
        try await waitForWrites(2, recorder: recorder)
        await channel.receive(Data("%begin 3 3 1\n@1\n%end 3 3 1\n".utf8))
        let secondResult = try await second.value
        XCTAssertEqual(secondResult, ["@1"])
        let output = await recorder.events
        XCTAssertEqual(output, [.output(pane: "%1", bytes: Data("a\n".utf8))])
        await channel.close()
    }
    func testTimeoutClosesChannelAndRejectsLaterInput() async throws {
        let recorder = Recorder()
        let channel = ControlChannel(timeoutNanoseconds: 10_000_000, writer: { await recorder.record($0) }, onEvent: { await recorder.record($0) })
        await channel.receive(Data("%begin 1 1 0\n%end 1 1 0\n".utf8))
        do { _ = try await channel.command("send-keys -t %1 Enter"); XCTFail("Expected timeout") } catch {}
        do { _ = try await channel.command("send-keys -t %1 Enter"); XCTFail("Expected closed channel") } catch {}
        let writes = await recorder.writes
        XCTAssertEqual(writes.count, 1, "Never replay an input operation after timeout")
    }
    func testStartupTimeoutDoesNotHangWaitingForInitialResponse() async {
        let channel = ControlChannel(timeoutNanoseconds: 5_000_000, writer: { _ in XCTFail("Must wait for attach") }, onEvent: { _ in })
        do { _ = try await channel.command("list-windows"); XCTFail("Expected startup timeout") } catch {}
    }
    func testDisconnectResumesOutstandingRequests() async throws {
        let recorder = Recorder()
        let channel = ControlChannel(writer: { await recorder.record($0) }, onEvent: { _ in })
        await channel.receive(Data("%begin 1 1 0\n%end 1 1 0\n".utf8))
        let task = Task { try await channel.command("capture-pane -p") }
        try await waitForWrites(1, recorder: recorder)
        await channel.close()
        do { _ = try await task.value; XCTFail("Expected disconnection") } catch {}
    }
    func testCancelInFlightReadDrainsBeforeRestorationCommand() async throws {
        let recorder = Recorder()
        let channel = ControlChannel(writer: { await recorder.record($0) }, onEvent: { _ in })
        await channel.receive(Data("%begin 1 1 0\n%end 1 1 0\n".utf8))
        let read = Task { try await channel.command("capture-pane -p") }
        try await waitForWrites(1, recorder: recorder)
        read.cancel()
        let restore = Task { try await channel.command("set-option -wu -t @1 window-size") }
        await channel.receive(Data("%begin 2 2 1\nsnapshot\n%end 2 2 1\n".utf8))
        _ = try await read.value
        try await waitForWrites(2, recorder: recorder)
        await channel.receive(Data("%begin 3 3 1\n%end 3 3 1\n".utf8))
        let restored = try await restore.value
        XCTAssertTrue(restored.isEmpty)
        await channel.close()
    }
}
