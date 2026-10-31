import XCTest
@testable import MuxCore

final class CodexAttentionPollingTests: XCTestCase {
    private func pane(_ command: String = "codex", id: String = "%1", window: String = "@1") -> CodexPaneTarget {
        CodexPaneTarget(sessionID: "$1", windowID: window, windowName: "project", paneID: id, command: command)
    }
    func testOnlyCodexAndOneTimeNodeProbesAreEligible() {
        var polling = CodexAttentionPolling()
        let codex = pane(), node = pane("node", id: "%2", window: "@2"), shell = pane("zsh", id: "%3", window: "@3")
        polling.reconcile([codex, node, shell], at: 0)
        XCTAssertTrue(polling.shouldPoll(codex, at: 0))
        XCTAssertTrue(polling.shouldPoll(node, at: 0))
        XCTAssertFalse(polling.shouldPoll(shell, at: 0))
        polling.observe(node, state: .unknown, at: 1)
        polling.reconcile([codex, node, shell], at: 6)
        XCTAssertFalse(polling.shouldPoll(node, at: 6))
        polling.viewed(windowID: "@2", at: 7)
        XCTAssertTrue(polling.shouldPoll(node, at: 7))
    }
    func testIdlePanesStopAfterTwoMinutesAndInteractionRestartsThem() {
        for state in [CodexAttentionState.ready, .needsInput, .unknown] {
            var polling = CodexAttentionPolling()
            let target = pane()
            polling.reconcile([target], at: 0)
            polling.observe(target, state: state, at: 1)
            polling.observe(target, state: state, at: 100)
            XCTAssertTrue(polling.shouldPoll(target, at: 120))
            XCTAssertFalse(polling.shouldPoll(target, at: 121))
            polling.viewed(windowID: "@1", at: 122)
            XCTAssertTrue(polling.shouldPoll(target, at: 122))
            polling.observe(target, state: .working, at: 123)
            XCTAssertTrue(polling.shouldPoll(target, at: 300))
        }
    }
    func testWorkingStateIsNotIdleButUnvisitedWindowsExpire() {
        var polling = CodexAttentionPolling()
        let target = pane()
        polling.reconcile([target], at: 0)
        polling.observe(target, state: .working, at: 1)
        polling.reconcile([target], at: 1799)
        XCTAssertTrue(polling.shouldPoll(target, at: 1799))
        XCTAssertFalse(polling.shouldPoll(target, at: 1800))
        polling.viewed(windowID: "@1", at: 1801)
        XCTAssertTrue(polling.shouldPoll(target, at: 1801))
        XCTAssertFalse(polling.shouldPoll(target, at: 3601))
    }
    func testWorkingResetsIdleTimerAndConfirmedNodeCanReadUnbrandedDialogs() {
        var polling = CodexAttentionPolling()
        let target = pane("nodejs")
        polling.reconcile([target], at: 0)
        polling.observe(target, state: .ready, at: 1)
        polling.observe(target, state: .working, at: 100)
        XCTAssertTrue(polling.shouldPoll(target, at: 200))
        let dialog = "Would you like to run this command?\n1. Yes, proceed\nEnter to confirm"
        XCTAssertEqual(CodexAttention.state(screen: dialog, command: polling.classificationCommand(for: target)), .needsInput)
        polling.observe(target, state: .needsInput, at: 201)
        XCTAssertTrue(polling.shouldPoll(target, at: 320))
        XCTAssertFalse(polling.shouldPoll(target, at: 321))
    }
    func testCommandChangesAndClosedPanesResetEligibility() {
        var polling = CodexAttentionPolling()
        let node = pane("node"), codex = pane()
        polling.reconcile([node], at: 0)
        polling.observe(node, state: .unknown, at: 1)
        XCTAssertEqual(polling.reconcile([codex], at: 2), ["%1"])
        XCTAssertTrue(polling.shouldPoll(codex, at: 2))
        polling.observe(codex, state: .ready, at: 3)
        polling.reconcile([pane("zsh")], at: 5)
        XCTAssertFalse(polling.shouldPoll(codex, at: 5))
        polling.reconcile([codex], at: 2000)
        XCTAssertTrue(polling.shouldPoll(codex, at: 2000))
        polling.reconcile([], at: 2001)
        XCTAssertFalse(polling.shouldPoll(codex, at: 2001))
    }
    func testWindowsAreIndependentAndMetadataDoesNotReactivateIdlePanes() {
        var polling = CodexAttentionPolling()
        let first = pane(), second = pane(id: "%2", window: "@2")
        polling.reconcile([first, second], at: 0)
        polling.observe(first, state: .ready, at: 1)
        polling.observe(second, state: .working, at: 1)
        XCTAssertTrue(polling.reconcile([first, second], at: 200).isEmpty)
        XCTAssertFalse(polling.shouldPoll(first, at: 200))
        XCTAssertTrue(polling.shouldPoll(second, at: 200))
        polling.viewed(windowID: "@1", at: 201)
        XCTAssertTrue(polling.shouldPoll(first, at: 201))
        XCTAssertFalse(polling.shouldPoll(second, at: 1800))
        XCTAssertTrue(polling.shouldPoll(first, at: 1800))
    }
}
