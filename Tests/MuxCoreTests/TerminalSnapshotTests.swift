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
        XCTAssertEqual(TerminalSnapshot.smartCursorOffset(grid: ["abc     ", "def"], joined: "abc     def", row: 1, column: 2, columns: 8), 10)
    }
    func testPromptTrailingSpacesAndEmptyCursorLine() {
        XCTAssertEqual(TerminalSnapshot.smartCursorOffset(grid: ["$ "], joined: "$ ", row: 0, column: 2, columns: 80), 2)
        XCTAssertEqual(TerminalSnapshot.smartCursorOffset(grid: ["output  ", "$ echo "], joined: "output  \n$ echo ", row: 1, column: 7, columns: 80), 16)
        let lines = ["output", "", "", ""]
        let offset = TerminalSnapshot.smartCursorOffset(grid: lines, joined: lines.joined(separator: "\n"), row: 1, column: 0, columns: 80)
        XCTAssertEqual(offset, 7)
        XCTAssertEqual(TerminalSnapshot.trimmingBlankLines(lines, keepingCursorAt: offset), "output\n")
        XCTAssertEqual(TerminalSnapshot.trimmingBlankLines(lines, keepingCursorAt: nil), "output")
    }
    func testPaintedPaddingAcrossResizeAndSoftWrapMapsCursor() {
        let history = String(repeating: "h", count: 200)
        let spaces: (Int) -> String = { String(repeating: " ", count: $0) }
        // Measured shape of a real Codex capture after a 100→200 column resize:
        // one soft-wrapped history row, shortened blank padding, then the prompt.
        let grid = [history, spaces(100), spaces(200), "› " + spaces(198), "footer" + spaces(194)]
        let before = history + spaces(62) + "\n" + spaces(91) + "\n"
        let joined = before + "› " + spaces(89) + "\nfooter" + spaces(194)
        XCTAssertEqual(TerminalSnapshot.smartCursorOffset(grid: grid, joined: joined, row: 3, column: 2, columns: 200), before.utf16.count + 2)
    }

    func testPaddingToleranceDoesNotHideChangedContent() {
        XCTAssertNil(TerminalSnapshot.smartCursorOffset(grid: ["old    ", "› "], joined: "different\n› ", row: 1, column: 2, columns: 80))
        XCTAssertNil(TerminalSnapshot.smartCursorOffset(grid: ["a    ", "› "], joined: "a b\n› ", row: 1, column: 2, columns: 80))
    }

    func testUnicodeCellsAndCaptureMismatch() {
        XCTAssertEqual(TerminalSnapshot.smartCursorOffset(grid: ["$ 界🙂a"], joined: "$ 界🙂a", row: 0, column: 6, columns: 80), 5)
        XCTAssertNil(TerminalSnapshot.smartCursorOffset(grid: ["old", "$ hi"], joined: "changed\n$ hi", row: 1, column: 4, columns: 80))
        XCTAssertNil(TerminalSnapshot.smartCursorOffset(grid: ["$ hi"], joined: "$ hi", row: 0, column: 20, columns: 80))
    }
}
