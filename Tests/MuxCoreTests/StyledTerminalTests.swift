import XCTest
@testable import MuxCore

final class StyledTerminalTests: XCTestCase {
    func testBasicColorsBackgroundsAndSelectiveResets() {
        let parsed = TerminalCaptureStyle.parse("\u{1b}[31;44;1;3;4mred\u{1b}[39;49;22;23;24mplain")
        XCTAssertEqual(parsed.text, "redplain")
        XCTAssertEqual(parsed.runs.count, 2)
        XCTAssertEqual(parsed.runs[0].style.foreground, .indexed(1))
        XCTAssertEqual(parsed.runs[0].style.background, .indexed(4))
        XCTAssertTrue(parsed.runs[0].style.bold)
        XCTAssertTrue(parsed.runs[0].style.italic)
        XCTAssertTrue(parsed.runs[0].style.underline)
        XCTAssertEqual(parsed.runs[1].style, TerminalTextStyle())
    }
    func testIndexedAndTrueColorIncludingColonSyntax() {
        let parsed = TerminalCaptureStyle.parse("\u{1b}[38;5;196;48;2;10;20;30mA\u{1b}[38:2::1:2:3mB\u{1b}[0mC")
        XCTAssertEqual(parsed.text, "ABC")
        XCTAssertEqual(parsed.runs[0].style.foreground, .indexed(196))
        XCTAssertEqual(parsed.runs[0].style.background, .rgb(10, 20, 30))
        XCTAssertEqual(parsed.runs[1].style.foreground, .rgb(1, 2, 3))
        XCTAssertEqual(parsed.runs[2].style, TerminalTextStyle())
    }
    func testStyleSurvivesReflowClassificationAndNewlines() {
        let input = "\u{1b}[32mparagraph 🦊\n```swift\nlet x = 1\n```\u{1b}[0m\nplain"
        let blocks = SmartPresentation.blocks(from: input)
        XCTAssertEqual(blocks.map(\.kind), [.prose, .fixed, .prose])
        XCTAssertEqual(blocks.map(\.text).joined(separator: "\n"), "paragraph 🦊\n```swift\nlet x = 1\n```\nplain")
        XCTAssertEqual(blocks[1].styledText.runs.first?.style.foreground, .indexed(2))
        XCTAssertEqual(blocks[2].styledText.runs.last?.style.foreground, nil)
        XCTAssertFalse(blocks.flatMap { $0.styledText.runs }.contains { $0.text.contains("\u{1b}") })
    }
    func testConversationMarkersAreRemovedWithoutDroppingStyle() {
        let blocks = CodexPresentation.blocks(from: "\u{1b}[36m› hello\u{1b}[0m\n\u{1b}[33m• answer\u{1b}[0m")
        XCTAssertEqual(blocks.map(\.text), ["hello", "answer"])
        XCTAssertEqual(blocks.map(\.role), [.user, .assistant])
        XCTAssertEqual(blocks[0].styledText.runs.first?.style.foreground, .indexed(6))
        XCTAssertEqual(blocks[1].styledText.runs.first?.style.foreground, .indexed(3))
    }
    func testOtherControlSequencesCannotLeakIntoDisplayedText() {
        let text = "\u{1b}]52;c;clipboard-data\u{7}safe \u{1b}]8;;https://example.com\u{1b}\\link\u{1b}]8;;\u{1b}\\\u{1b}[2J!"
        XCTAssertEqual(TerminalCaptureStyle.parse(text).text, "safe link!")
        XCTAssertEqual(TerminalCaptureStyle.parse("ok\u{1b}[38;2;255").text, "ok")
        let invalid = TerminalCaptureStyle.parse("\u{1b}[38;5;999mX\u{1b}[1mY")
        XCTAssertEqual(invalid.text, "XY")
        XCTAssertNil(invalid.runs.first?.style.foreground)
        XCTAssertTrue(invalid.runs.last!.style.bold)
    }
    func testInverseConcealAndFullReset() {
        let text = TerminalCaptureStyle.parse("\u{1b}[7;8;9;2mhidden\u{1b}[mplain")
        XCTAssertTrue(text.runs[0].style.inverse)
        XCTAssertTrue(text.runs[0].style.hidden)
        XCTAssertTrue(text.runs[0].style.strikethrough)
        XCTAssertTrue(text.runs[0].style.dim)
        XCTAssertEqual(text.runs[1].style, TerminalTextStyle())
    }
    func testLivePutsLastLineAtBottomAcrossViewportChanges() {
        for viewport in [300.0, 600.0, 900.0] {
            let offset = TerminalViewport.bottomOffset(contentHeight: 2000, viewportHeight: viewport)
            XCTAssertEqual(2000 - offset, viewport)
        }
        let shortOffset = TerminalViewport.bottomOffset(contentHeight: 100, viewportHeight: 600, topInset: 500)
        XCTAssertEqual(100 - shortOffset, 600, "Short output should also align its last line to the bottom")
        XCTAssertEqual(TerminalViewport.bottomOffset(contentHeight: 2000, viewportHeight: 600, bottomInset: 20), 1420)
    }
}
