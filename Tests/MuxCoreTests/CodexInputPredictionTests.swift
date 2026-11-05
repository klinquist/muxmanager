import XCTest
@testable import MuxCore

final class CodexInputPredictionTests: XCTestCase {
    private func observe(_ prediction: inout CodexInputPrediction, line: String = "› ", column: Int = 2, visible: Bool = false, columns: Int = 80) {
        let grid = ["\u{1b}[32mEarlier output\u{1b}[0m", line, "footer"]
        let joined = grid.joined(separator: "\n")
        let offset = TerminalSnapshot.smartCursorOffset(grid: grid, joined: joined, row: 1, column: column, columns: columns)
        prediction.observe(grid: grid, joined: joined, cursor: TerminalCursor(row: 1, column: column, visible: visible, smartOffset: offset), columns: columns)
    }
    private func text(_ prediction: CodexInputPrediction) -> String? {
        prediction.projection.map { TerminalCaptureStyle.parse($0.grid[1]).text }
    }
    private func type(_ text: String, into prediction: inout CodexInputPrediction) {
        XCTAssertTrue(prediction.type(Data(text.utf8)))
    }

    func testTypingIsImmediateAndShowsHiddenCodexCursor() {
        var prediction = CodexInputPrediction()
        observe(&prediction)
        XCTAssertEqual(prediction.projection?.cursor.visible, true)
        type("hello", into: &prediction)
        XCTAssertEqual(text(prediction), "› hello")
        XCTAssertEqual(prediction.projection?.cursor.column, 7)
        XCTAssertEqual(prediction.projection?.cursor.smartOffset, "Earlier output\n› hello".utf16.count)
        XCTAssertTrue(prediction.hasPendingInput)
    }

    func testUnchangedAndPartialEchoNeverDuplicateOrRollBackTyping() {
        var prediction = CodexInputPrediction()
        observe(&prediction)
        for letter in "abc" { type(String(letter), into: &prediction) }
        observe(&prediction) // A capture already in flight when typing began.
        XCTAssertEqual(text(prediction), "› abc")
        observe(&prediction, line: "› a", column: 3)
        XCTAssertEqual(text(prediction), "› abc")
        XCTAssertTrue(prediction.hasPendingInput)
        observe(&prediction, line: "› abc", column: 5)
        XCTAssertEqual(text(prediction), "› abc")
        XCTAssertFalse(prediction.hasPendingInput)
    }

    func testEditingInMiddleAndDeletingUnicodeCharacters() {
        var prediction = CodexInputPrediction()
        observe(&prediction, line: "› a🙂界", column: 7)
        type("\u{7f}", into: &prediction)
        XCTAssertEqual(text(prediction), "› a🙂")
        XCTAssertEqual(prediction.projection?.cursor.column, 5)
        type("\u{1b}[D", into: &prediction)
        type("x", into: &prediction)
        XCTAssertEqual(text(prediction), "› ax🙂")
        type("\u{1b}[3~", into: &prediction)
        XCTAssertEqual(text(prediction), "› ax")
        type("\u{1b}OD", into: &prediction)
        type("\u{1b}OC", into: &prediction)
        XCTAssertEqual(prediction.projection?.cursor.column, 4)
    }

    func testDimPlaceholderIsReplacedByInput() {
        var prediction = CodexInputPrediction()
        observe(&prediction, line: "› \u{1b}[2mAsk Codex anything\u{1b}[0m")
        type("hi", into: &prediction)
        XCTAssertEqual(text(prediction), "› hi")
        XCTAssertFalse(TerminalCaptureStyle.parse(prediction.projection!.grid[1]).runs.contains { $0.style.dim })
    }

    func testRealSuffixIsPreservedAndSurroundingStylesRemain() {
        var prediction = CodexInputPrediction()
        observe(&prediction, line: "› world")
        type("hello ", into: &prediction)
        XCTAssertEqual(text(prediction), "› hello world")
        let joined = TerminalCaptureStyle.parse(prediction.projection!.joined)
        XCTAssertEqual(joined.text, "Earlier output\n› hello world\nfooter")
        XCTAssertEqual(joined.runs.first?.style.foreground, .indexed(2))
    }

    func testRemoteCorrectionAndNewPromptDiscardPredictions() {
        var prediction = CodexInputPrediction()
        observe(&prediction)
        type("abc", into: &prediction)
        observe(&prediction, line: "› remote edit", column: 13)
        XCTAssertEqual(text(prediction), "› remote edit")
        XCTAssertFalse(prediction.hasPendingInput)
        observe(&prediction, line: "Working…", column: 0)
        XCTAssertNil(prediction.projection)
    }

    func testUnsupportedControlsAndPasteDoNotEchoLocally() {
        for key in ["\r", "\n", "\t", "\u{3}", "\u{1b}[A", "first\nsecond"] {
            var prediction = CodexInputPrediction()
            observe(&prediction)
            type("a", into: &prediction)
            XCTAssertFalse(prediction.type(Data(key.utf8)))
            XCTAssertNil(prediction.projection)
        }
    }

    func testShellAndWrappingAreNeverPredicted() {
        var prediction = CodexInputPrediction()
        observe(&prediction, line: "$ ")
        XCTAssertFalse(prediction.type(Data("secret".utf8)))
        XCTAssertNil(prediction.projection)
        observe(&prediction, columns: 8)
        XCTAssertFalse(prediction.type(Data("abcdef".utf8)))
        XCTAssertNil(prediction.projection)
    }

    func testPaintedPaddingDoesNotDisablePrediction() {
        var prediction = CodexInputPrediction()
        observe(&prediction, line: "› " + String(repeating: " ", count: 78))
        type("hello ", into: &prediction)
        XCTAssertEqual(text(prediction), "› hello ")
        observe(&prediction, line: "› hello " + String(repeating: " ", count: 72), column: 8)
        XCTAssertFalse(prediction.hasPendingInput)
    }

    func testCombiningCharactersKeepCursorAtGraphemeBoundary() {
        var prediction = CodexInputPrediction()
        observe(&prediction)
        type("e", into: &prediction)
        type("\u{301}", into: &prediction)
        XCTAssertEqual(text(prediction), "› e\u{301}")
        XCTAssertEqual(prediction.projection?.cursor.column, 3)
        type("\u{7f}", into: &prediction)
        XCTAssertEqual(text(prediction), "› ")
    }

    func testDisabledPromptDoesNotPredictOrForceCursorVisible() {
        var prediction = CodexInputPrediction()
        observe(&prediction, line: "\u{1b}[2m› Input disabled.\u{1b}[0m")
        XCTAssertNil(prediction.projection)
        XCTAssertFalse(prediction.type(Data("a".utf8)))
    }

    func testPromptStyleDoesNotMakeTypedTextBold() {
        var prediction = CodexInputPrediction()
        observe(&prediction, line: "\u{1b}[1m›\u{1b}[0m \u{1b}[2mAsk Codex anything\u{1b}[0m")
        type("hello", into: &prediction)
        let runs = TerminalCaptureStyle.parse(prediction.projection!.grid[1]).runs
        XCTAssertTrue(runs.first!.style.bold)
        XCTAssertFalse(runs.last!.style.bold)
        XCTAssertFalse(runs.last!.style.dim)
    }

    func testRemoteResizeDropsPredictions() {
        var prediction = CodexInputPrediction()
        observe(&prediction)
        type("pending", into: &prediction)
        observe(&prediction, columns: 40)
        XCTAssertFalse(prediction.hasPendingInput)
        XCTAssertEqual(text(prediction), "› ")
    }

    func testResetDropsUnconfirmedInput() {
        var prediction = CodexInputPrediction()
        observe(&prediction)
        type("pending", into: &prediction)
        prediction.reset()
        XCTAssertNil(prediction.projection)
        XCTAssertFalse(prediction.hasPendingInput)
        observe(&prediction)
        XCTAssertEqual(text(prediction), "› ")
    }
}
