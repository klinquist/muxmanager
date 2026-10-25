import XCTest
@testable import MuxCore

final class ShellCompletionTests: XCTestCase {
    func testBashAndZshCopyCompletedCommandIncludingTrailingSpace() throws {
        for prompt in ["dev@build % ", "dev@build:~$ ", "root@build # "] {
            let baseline = try XCTUnwrap(ShellCompletionScreen(joinedLine: prompt, columns: 120, cursorX: prompt.count))
            let line = prompt + "ls Documents/ "
            let result = try XCTUnwrap(ShellCompletionScreen(joinedLine: line.padding(toLength: 120, withPad: " ", startingAt: 0), columns: 120, cursorX: line.count))
            XCTAssertTrue(baseline.resemblesEmptyPrompt)
            XCTAssertEqual(result.completedText(after: baseline), "ls Documents/ ")
        }
    }
    func testUnicodePromptAndFilenameUseTerminalColumns() throws {
        let prompt = try XCTUnwrap(ShellCompletionScreen(joinedLine: "🦊 ❯ ", columns: 80, cursorX: 5))
        let line = try XCTUnwrap(ShellCompletionScreen(joinedLine: "🦊 ❯ cat 界.txt", columns: 80, cursorX: 15))
        XCTAssertTrue(prompt.resemblesEmptyPrompt)
        XCTAssertEqual(line.completedText(after: prompt), "cat 界.txt")
    }
    func testJoinedWrappedInputAndPadding() throws {
        let baseline = try XCTUnwrap(ShellCompletionScreen(joinedLine: "$ ", columns: 10, cursorX: 2))
        let line = try XCTUnwrap(ShellCompletionScreen(joinedLine: "$ abcdefghijklmno   ", columns: 10, cursorX: 7))
        XCTAssertEqual(line.completedText(after: baseline), "abcdefghijklmno")
    }
    func testRejectsChangedPromptCursorInsideCommandAndContinuationPrompt() throws {
        let baseline = try XCTUnwrap(ShellCompletionScreen(joinedLine: "$ ", columns: 80, cursorX: 2))
        let changed = try XCTUnwrap(ShellCompletionScreen(joinedLine: "other % ls foo", columns: 80, cursorX: 13))
        XCTAssertNil(changed.completedText(after: baseline))
        let inside = try XCTUnwrap(ShellCompletionScreen(joinedLine: "$ ls Documents", columns: 80, cursorX: 5))
        XCTAssertNil(inside.completedText(after: baseline))
        XCTAssertFalse(try XCTUnwrap(ShellCompletionScreen(joinedLine: "> ", columns: 80, cursorX: 2)).resemblesEmptyPrompt)
        XCTAssertFalse(try XCTUnwrap(ShellCompletionScreen(joinedLine: "$ ls Doc", columns: 80, cursorX: 8)).resemblesEmptyPrompt)
    }
    func testKnownRightPromptIsNotCopiedIntoNativeInput() throws {
        let baseline = try XCTUnwrap(ShellCompletionScreen(joinedLine: "$       clock", columns: 20, cursorX: 2))
        let result = try XCTUnwrap(ShellCompletionScreen(joinedLine: "$ ls x  clock", columns: 20, cursorX: 6))
        XCTAssertEqual(result.completedText(after: baseline), "ls x")
    }
}
