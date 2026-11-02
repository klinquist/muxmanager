import XCTest
@testable import MuxCore

final class TerminalSnapshotTests: XCTestCase {
    func testCursorIncludesCapturedHistory() {
        XCTAssertEqual(TerminalSnapshot.cursorRow(gridCount: 2036, remoteRows: 36, cursorY: 10), 2010)
        let grid = (0..<2036).map { "line \($0)" }
        let capture = TerminalSnapshot.capture(grid: grid, remoteRows: 36, x: 7, y: 10, applicationCursor: false, keypad: false, visible: true)
        XCTAssertTrue(capture.contains("\u{1b}[2011;8H"))
        XCTAssertTrue(capture.hasSuffix("\u{1b}[?25h"))
    }
    func testCursorOnScreenWithoutHistory() {
        XCTAssertEqual(TerminalSnapshot.cursorRow(gridCount: 36, remoteRows: 36, cursorY: 10), 10)
        XCTAssertEqual(TerminalSnapshot.cursorRow(gridCount: 0, remoteRows: 36, cursorY: 10), 0)
    }
    func testSmartCursorAtShellPromptAndInsideCommand() {
        let grid = ["old output", "$ echo hello", ""]
        XCTAssertEqual(TerminalSnapshot.smartCursorOffset(grid: grid, joined: "old output\n$ echo hello", row: 1, column: 12, columns: 80), 23)
        XCTAssertEqual(TerminalSnapshot.smartCursorOffset(grid: grid, joined: "old output\n$ echo hello", row: 1, column: 4, columns: 80), 15)
    }
    func testSmartCursorAcrossSoftWrapAndExplicitNewlines() {
        XCTAssertEqual(TerminalSnapshot.smartCursorOffset(grid: ["abcdefgh", "ijk", "", "$ hi"], joined: "abcdefghijk\n\n$ hi", row: 3, column: 4, columns: 8), 17)
        XCTAssertEqual(TerminalSnapshot.smartCursorOffset(grid: ["abc", "def"], joined: "abc     def", row: 1, column: 2, columns: 8), 10)
    }
    func testUnicodeCellsAndCaptureMismatch() {
        XCTAssertEqual(TerminalSnapshot.smartCursorOffset(grid: ["$ 界🙂a"], joined: "$ 界🙂a", row: 0, column: 6, columns: 80), 5)
        XCTAssertNil(TerminalSnapshot.smartCursorOffset(grid: ["old", "$ hi"], joined: "changed\n$ hi", row: 1, column: 4, columns: 80))
        XCTAssertNil(TerminalSnapshot.smartCursorOffset(grid: ["$ hi"], joined: "$ hi", row: 0, column: 20, columns: 80))
    }
}
