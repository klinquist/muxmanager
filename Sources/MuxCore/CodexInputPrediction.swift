import Foundation

/// Local echo for a single Codex prompt row. Unsupported keys and wrapping hand
/// control back to the remote application instead of guessing its editing rules.
public struct CodexInputPrediction {
    public struct Projection {
        public let grid: [String]
        public let joined: String
        public let cursor: TerminalCursor
    }
    private struct Edit: Equatable {
        var text: String
        var column: Int
    }
    private struct Prompt {
        let row: Int
        let start: Int
        let joinedStart: Int
        let line: StyledTerminalText
        let placeholder: Bool
        let edit: Edit
    }
    private var grid: [String] = []
    private var joined = ""
    private var styledJoined = StyledTerminalText()
    private var columns = 0
    private var prompt: Prompt?
    private var pending: [Edit] = []
    public var hasPendingInput: Bool { !pending.isEmpty }
    public init() {}

    public mutating func reset() { prompt = nil; pending = [] }

    public mutating func observe(grid: [String], joined: String, cursor: TerminalCursor, columns: Int) {
        if self.columns != columns { reset() }
        self.grid = grid; self.joined = joined; self.columns = columns
        styledJoined = TerminalCaptureStyle.parse(joined)
        guard grid.indices.contains(cursor.row), let offset = cursor.smartOffset else { reset(); return }
        let line = TerminalCaptureStyle.parse(grid[cursor.row])
        var text = line.text
        let prefix = String(text.prefix(while: { $0 == " " })) + "› "
        guard text.hasPrefix(prefix), !line.style(at: prefix.utf16.count - 2).dim,
              cursor.column >= prefix.count, let caret = Self.index(in: text, column: cursor.column) else { reset(); return }
        // Full-screen TUIs often paint spaces to the right edge. Those cells
        // are padding, while spaces before the caret are part of the input.
        let caretPosition = text.distance(from: text.startIndex, to: caret)
        let suffixOffset = text[..<caret].utf16.count
        while text.count > caretPosition && text.last == " " { text.removeLast() }
        let edit = Edit(text: text, column: cursor.column)
        if let previous = prompt, previous.row == cursor.row {
            if let echoed = pending.lastIndex(of: edit) { pending.removeFirst(echoed + 1) }
            else if previous.edit != edit { pending = [] }
        } else { pending = [] }
        let suffix = line.runs.flatMap { run in run.text.map { ($0, run.style.dim) } }.dropFirst(caretPosition)
        let placeholder = cursor.column == prefix.count && !suffix.isEmpty && suffix.allSatisfy { $0.1 || $0.0 == " " }
        let start = offset - suffixOffset
        let joinedText = styledJoined.text as NSString
        guard start >= 0, start + line.text.utf16.count <= joinedText.length,
              joinedText.substring(with: NSRange(location: start, length: line.text.utf16.count)) == line.text else { reset(); return }
        prompt = Prompt(row: cursor.row, start: prefix.count, joinedStart: start, line: line, placeholder: placeholder, edit: edit)
    }

    /// Returns true only when the entire key event can be predicted safely.
    @discardableResult
    public mutating func type(_ bytes: Data) -> Bool {
        guard let prompt, var edit = pending.last ?? self.prompt?.edit else { reset(); return false }
        guard let caret = Self.index(in: edit.text, column: edit.column) else { reset(); return false }
        let prefixEnd = edit.text.index(edit.text.startIndex, offsetBy: prompt.start)
        switch Array(bytes) {
        case [127], [8]:
            guard caret > prefixEnd else { return true }
            let previous = edit.text.index(before: caret)
            edit.column -= ShellCompletionScreen.width(of: edit.text[previous])
            edit.text.removeSubrange(previous..<caret)
        case [27, 91, 68], [27, 79, 68]:
            guard caret > prefixEnd else { return true }
            edit.column -= ShellCompletionScreen.width(of: edit.text[edit.text.index(before: caret)])
        case [27, 91, 67], [27, 79, 67]:
            guard caret < edit.text.endIndex, !prompt.placeholder else { reset(); return false }
            edit.column += ShellCompletionScreen.width(of: edit.text[caret])
        case [27, 91, 51, 126]:
            guard caret < edit.text.endIndex, !prompt.placeholder else { reset(); return false }
            edit.text.remove(at: caret)
        default:
            guard let text = String(data: bytes, encoding: .utf8), !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { reset(); return false }
            let before = String(edit.text[..<caret])
            let after = pending.isEmpty && prompt.placeholder ? "" : String(edit.text[caret...])
            edit.text = before + text + after
            edit.column = ShellCompletionScreen.width(of: before + text)
        }
        // Leave room for the remote application's wrap and continuation gutter.
        guard ShellCompletionScreen.width(of: edit.text) < columns - 1, pending.count < 256 else { reset(); return false }
        pending.append(edit)
        return true
    }

    public var projection: Projection? {
        guard let prompt else { return nil }
        let edit = pending.last ?? prompt.edit
        guard let caret = Self.index(in: edit.text, column: edit.column) else { return nil }
        var projectedGrid = grid
        var projectedJoined = joined
        if !pending.isEmpty {
            // Preserve the surrounding capture's styles; only the edited row is
            // replaced, using the input's style for locally typed characters.
            let prefix = String(edit.text.prefix(prompt.start))
            var inputStyle = prompt.line.style(at: prefix.utf16.count)
            inputStyle.dim = false; inputStyle.inverse = false; inputStyle.hidden = false
            var input = StyledTerminalText()
            input.append(String(edit.text.dropFirst(prompt.start)), style: inputStyle)
            let line = prompt.line.replacing(NSRange(location: prefix.utf16.count,
                length: prompt.line.text.utf16.count - prefix.utf16.count), with: input)
            projectedGrid[prompt.row] = line.capture
            projectedJoined = styledJoined.replacing(
                NSRange(location: prompt.joinedStart, length: prompt.line.text.utf16.count), with: line).capture
        }
        return Projection(grid: projectedGrid, joined: projectedJoined,
                          cursor: TerminalCursor(row: prompt.row, column: edit.column, visible: true,
                                                 smartOffset: prompt.joinedStart + edit.text[..<caret].utf16.count))
    }

    private static func index(in text: String, column: Int) -> String.Index? {
        var cells = 0
        for index in text.indices {
            if cells == column { return index }
            cells += max(0, ShellCompletionScreen.width(of: text[index]))
            if cells > column { return nil }
        }
        return cells == column ? text.endIndex : nil
    }
}

private extension StyledTerminalText {
    func style(at offset: Int) -> TerminalTextStyle {
        var remaining = offset
        for run in runs {
            if remaining < run.text.utf16.count { return run.style }
            remaining -= run.text.utf16.count
        }
        return TerminalTextStyle()
    }

    func replacing(_ range: NSRange, with replacement: StyledTerminalText) -> StyledTerminalText {
        var result = StyledTerminalText(), offset = 0, inserted = false
        for run in runs {
            let length = run.text.utf16.count
            let before = max(0, min(length, range.location - offset))
            if before > 0 { result.append((run.text as NSString).substring(to: before), style: run.style) }
            if !inserted && offset + length >= range.location { result.append(replacement); inserted = true }
            let after = max(0, min(length, NSMaxRange(range) - offset))
            if offset + length > NSMaxRange(range) { result.append((run.text as NSString).substring(from: after), style: run.style) }
            offset += length
        }
        if !inserted { result.append(replacement) }
        return result
    }

    var capture: String {
        runs.map { run in
            let style = run.style
            var codes = ["0"]
            for (enabled, code) in [(style.bold, "1"), (style.dim, "2"), (style.italic, "3"), (style.underline, "4"), (style.inverse, "7"), (style.hidden, "8"), (style.strikethrough, "9")] where enabled { codes.append(code) }
            for (color, code) in [(style.foreground, "38"), (style.background, "48")] {
                switch color {
                case .indexed(let n): codes.append("\(code);5;\(n)")
                case .rgb(let r, let g, let b): codes.append("\(code);2;\(r);\(g);\(b)")
                case nil: break
                }
            }
            return "\u{1b}[" + codes.joined(separator: ";") + "m" + run.text
        }.joined() + "\u{1b}[0m"
    }
}
