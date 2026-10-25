import XCTest
@testable import MuxCore

final class DiagnosticTests: XCTestCase {
    func testControlCharactersAreVisibleWithoutForgingLogLines() {
        var buffer = DiagnosticBuffer()
        buffer.append("$1\tmain\nforged\r\u{1b}[2J", category: "tmux", at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(buffer.entries.first?.message, "$1\\tmain\\nforged\\r\\u{001B}[2J")
        XCTAssertEqual(buffer.text.components(separatedBy: "\n").count, 1)
        XCTAssertTrue(buffer.text.contains("1970-01-01T00:00:00.000Z [tmux]"))
    }
    func testBoundedLogEvictsOldestEntriesAndLimitsUnicodeBytes() {
        var buffer = DiagnosticBuffer(maxEntries: 3, maxBytes: 1024)
        for n in 0..<5 { buffer.append("entry \(n)", category: "test") }
        XCTAssertEqual(buffer.entries.map(\.message), ["entry 2", "entry 3", "entry 4"])
        buffer.append(String(repeating: "🦊", count: 5000), category: "large")
        XCTAssertLessThanOrEqual(buffer.entries.reduce(0) { $0 + $1.message.utf8.count + $1.category.utf8.count + 32 }, 1024)
        XCTAssertTrue(buffer.entries.last!.message.hasSuffix("[truncated]"))
        buffer.clear()
        XCTAssertTrue(buffer.entries.isEmpty)
    }
}
