import XCTest
@testable import MuxCore

final class CodexAttentionTests: XCTestCase {
    private let ready = "OpenAI Codex\n• Updated the tests.\n›\n100% context left"
    private let working = "OpenAI Codex\n• Working (5s • esc to interrupt)\n›\n100% context left"
    private let question = "OpenAI Codex\nWhich branch should I use?\n›\n100% context left"
    private let approval = "Would you like to run the following command?\n› 1. Yes, proceed\n2. No, and tell Codex what to do differently\nEnter to confirm · esc to cancel"

    func testRecognizesWorkingReadyQuestionAndApproval() {
        XCTAssertEqual(CodexAttention.state(screen: working, command: "codex"), .working)
        XCTAssertEqual(CodexAttention.state(screen: ready, command: "codex"), .ready)
        XCTAssertEqual(CodexAttention.state(screen: question, command: "codex"), .needsInput)
        XCTAssertEqual(CodexAttention.state(screen: approval, command: "codex"), .needsInput)
        XCTAssertEqual(CodexAttention.state(screen: "\u{1b}[32m" + ready, command: "node"), .ready)
    }
    func testSilencePlainShellAndOldQuestionAreNotCompletion() {
        XCTAssertEqual(CodexAttention.state(screen: "", command: "codex"), .unknown)
        XCTAssertEqual(CodexAttention.state(screen: "$ echo hello\nhello\n$", command: "bash"), .unknown)
        XCTAssertEqual(CodexAttention.state(screen: "Would you like help?", command: "node"), .unknown)
        XCTAssertEqual(CodexAttention.state(screen: question + "\nWorking (10s · esc to interrupt)", command: "codex"), .working)
        XCTAssertEqual(CodexAttention.state(screen: approval + "\nWorking (10s · esc to interrupt)", command: "codex"), .working)
        XCTAssertEqual(CodexAttention.state(screen: "Working (10s · esc to interrupt)\n" + approval, command: "codex"), .needsInput)
        XCTAssertEqual(CodexAttention.state(screen: "• This example asks: approve the request?", command: "codex"), .unknown)
    }
    func testSelectionDialogDoesNotNeedOrdinaryPrompt() {
        let screen = "Which approach?\n› 1. Keep existing setup\n2. Add a helper\ntab to add notes · enter to submit"
        XCTAssertEqual(CodexAttention.state(screen: screen, command: "codex"), .needsInput)
    }
    func testNewIdleWindowsAndInitialDialogsDoNotNotify() {
        var tracker = CodexAttentionTracker()
        for time in [0.0, 2, 10] {
            XCTAssertNil(tracker.observe(pane: "%1", state: .ready, at: time))
            XCTAssertNil(tracker.observe(pane: "%2", state: .needsInput, at: time))
        }
    }
    func testCompletionMustBeStableAndIsDeliveredOncePerCycle() {
        var tracker = CodexAttentionTracker()
        XCTAssertNil(tracker.observe(pane: "%1", state: .working, at: 0))
        XCTAssertNil(tracker.observe(pane: "%1", state: .ready, at: 1))
        XCTAssertNil(tracker.observe(pane: "%1", state: .ready, at: 2))
        XCTAssertEqual(tracker.observe(pane: "%1", state: .ready, at: 3), .ready)
        XCTAssertNil(tracker.observe(pane: "%1", state: .ready, at: 10))
        XCTAssertNil(tracker.observe(pane: "%1", state: .working, at: 11))
        XCTAssertNil(tracker.observe(pane: "%1", state: .needsInput, at: 12))
        XCTAssertEqual(tracker.observe(pane: "%1", state: .needsInput, at: 14), .needsInput)
        XCTAssertNil(tracker.observe(pane: "%1", state: .needsInput, at: 20))
    }
    func testTransientReadyScreenDoesNotNotifyAndPanesAreIndependent() {
        var tracker = CodexAttentionTracker()
        XCTAssertNil(tracker.observe(pane: "%1", state: .working, at: 0))
        XCTAssertNil(tracker.observe(pane: "%1", state: .ready, at: 1))
        XCTAssertNil(tracker.observe(pane: "%1", state: .working, at: 2))
        XCTAssertNil(tracker.observe(pane: "%2", state: .ready, at: 3))
        XCTAssertNil(tracker.observe(pane: "%1", state: .unknown, at: 4))
        XCTAssertNil(tracker.observe(pane: "%1", state: .needsInput, at: 5))
        XCTAssertEqual(tracker.observe(pane: "%1", state: .needsInput, at: 7), .needsInput)
    }
    func testSuspensionGapReconnectAndClosedPanesResetBaselines() {
        var tracker = CodexAttentionTracker()
        XCTAssertNil(tracker.observe(pane: "%1", state: .working, at: 0))
        XCTAssertNil(tracker.observe(pane: "%1", state: .ready, at: 120))
        XCTAssertNil(tracker.observe(pane: "%1", state: .ready, at: 125))
        XCTAssertNil(tracker.observe(pane: "%1", state: .working, at: 130))
        tracker.retain(panes: [])
        XCTAssertNil(tracker.observe(pane: "%1", state: .ready, at: 131))
        tracker = CodexAttentionTracker()
        XCTAssertNil(tracker.observe(pane: "%1", state: .needsInput, at: 132))
    }
    func testAllSessionTargetParsingUsesIDsAndPreservesQuotedNames() {
        let rows = ["$1\t@3\tapi\\ refactor\t%4\tcodex", "$2\t@3\tlinked\\ 名前\t%4\tcodex", "$9\t@12\tnode-app\t%20\tnode", "bad\tdata"]
        let targets = TmuxCommand.attentionTargets(rows)
        XCTAssertEqual(targets.count, 3)
        XCTAssertEqual(targets[0].windowName, "api refactor")
        XCTAssertEqual(targets[1].sessionID, "$2")
        XCTAssertEqual(targets[1].windowName, "linked 名前")
        XCTAssertEqual(targets[2].paneID, "%20")
        XCTAssertTrue(CodexAttention.isCandidate(command: "/usr/bin/codex-aarch64"))
        XCTAssertFalse(CodexAttention.isCandidate(command: "zsh"))
    }
}
