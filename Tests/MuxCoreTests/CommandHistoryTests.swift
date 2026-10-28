import XCTest
@testable import MuxCore

final class CommandHistoryTests: XCTestCase {
    func testRecallRestoresUnsubmittedDraftAndStopsAtOldest() {
        var history = CommandHistory()
        history.record("ls"); history.record("git status")
        XCTAssertEqual(history.previous(from: "unfinished"), "git status")
        XCTAssertEqual(history.previous(from: "git status"), "ls")
        XCTAssertEqual(history.previous(from: "ls"), "ls")
        XCTAssertEqual(history.next(from: "ls"), "git status")
        XCTAssertEqual(history.next(from: "git status"), "unfinished")
        XCTAssertNil(history.next(from: "unfinished"))
    }

    func testEditingRecallStartsFreshNavigationWithoutLosingEdit() {
        var history = CommandHistory()
        history.record("echo hello")
        XCTAssertEqual(history.previous(from: ""), "echo hello")
        XCTAssertFalse(history.isBrowsing("echo edited"))
        XCTAssertNil(history.next(from: "echo edited"))
        XCTAssertEqual(history.previous(from: "echo edited"), "echo hello")
        XCTAssertEqual(history.next(from: "echo hello"), "echo edited")
    }

    func testBoundedDeduplicatedMultilineHistoryIsIndependentPerWindow() {
        var first = CommandHistory(limit: 2)
        var second = CommandHistory()
        first.record("old"); first.record("echo 🙂\nsecond line")
        first.record("echo 🙂\nsecond line"); first.record("  \n")
        XCTAssertEqual(first.previous(from: ""), "echo 🙂\nsecond line")
        XCTAssertEqual(first.previous(from: "echo 🙂\nsecond line"), "old")
        first.record("latest")
        XCTAssertEqual(first.previous(from: ""), "latest")
        XCTAssertEqual(first.previous(from: "latest"), "echo 🙂\nsecond line")
        XCTAssertEqual(first.previous(from: "echo 🙂\nsecond line"), "echo 🙂\nsecond line")
        XCTAssertNil(second.previous(from: ""))
        second.record("other window")
        XCTAssertEqual(second.previous(from: ""), "other window")
        first.resetNavigation()
        XCTAssertEqual(first.previous(from: "new draft"), "latest")
        XCTAssertEqual(first.next(from: "latest"), "new draft")
    }
}
