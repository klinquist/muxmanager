import Foundation

/// Cursor coordinates belong to the captured grid, including captured history.
public struct TerminalCursor: Equatable, Sendable {
    public let row: Int
    public let column: Int
    public let visible: Bool
    public let smartOffset: Int?
    public init(row: Int, column: Int, visible: Bool, smartOffset: Int?) {
        self.row = row; self.column = column; self.visible = visible; self.smartOffset = smartOffset
    }
}

public enum TerminalSnapshot {
    public static func trimmingBlankLines(_ lines: [String], keepingCursorAt offset: Int?) -> String {
        var count = lines.count
        var length = lines.reduce(0) { $0 + TerminalCaptureStyle.parse($1).text.utf16.count } + max(0, lines.count - 1)
        while count > 0, TerminalCaptureStyle.parse(lines[count - 1]).text.trimmingCharacters(in: .whitespaces).isEmpty {
            let next = length - TerminalCaptureStyle.parse(lines[count - 1]).text.utf16.count - (count > 1 ? 1 : 0)
            if let offset, next < offset { break }
            length = next; count -= 1
        }
        return lines.prefix(count).joined(separator: "\n")
    }
    public static func cursorRow(gridCount: Int, remoteRows: Int, cursorY: Int) -> Int {
        min(max(0, gridCount - 1), max(0, gridCount - remoteRows) + max(0, cursorY))
    }
    /// Render the bounded capture as one local screen. Viewport height must not
    /// move its cursor into a different line or reflow its scrollback.
    public static func capture(grid: [String], remoteRows: Int, x: Int, y: Int,
                               applicationCursor: Bool, keypad: Bool, visible: Bool) -> String {
        let row = cursorRow(gridCount: grid.count, remoteRows: remoteRows, cursorY: y)
        return "\u{1b}c" + grid.joined(separator: "\r\n") + "\u{1b}[\(row + 1);\(max(0, x) + 1)H" +
            (applicationCursor ? "\u{1b}[?1h" : "\u{1b}[?1l") + (keypad ? "\u{1b}=" : "\u{1b}>") +
            (visible ? "\u{1b}[?25h" : "\u{1b}[?25l")
    }

    /// Locate the captured cell in tmux's soft-wrap-joined text. A mismatched
    /// capture is rejected rather than drawing a cursor on an unrelated line.
    public static func smartCursorOffset(grid: [String], joined: String, row: Int, column: Int, columns: Int) -> Int? {
        guard grid.indices.contains(row), column >= 0 else { return nil }
        let text = TerminalCaptureStyle.parse(joined).text
        var index = text.startIndex
        for (number, raw) in grid.prefix(row + 1).enumerated() {
            let line = TerminalCaptureStyle.parse(raw).text
            if number == row {
                var cells = 0
                for character in line {
                    if cells >= column { break }
                    let width = ShellCompletionScreen.width(of: character)
                    if cells + width > column { break }
                    guard index < text.endIndex, text[index] == character else { return nil }
                    index = text.index(after: index); cells += width
                }
                guard cells == column else { return nil }
                return text[..<index].utf16.count
            }
            guard text[index...].hasPrefix(line) else { return nil }
            index = text.index(index, offsetBy: line.count)
            if index < text.endIndex, text[index] == "\n" { index = text.index(after: index) }
        }
        return nil
    }
}
