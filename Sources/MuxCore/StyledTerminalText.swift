import Foundation

public enum TerminalTextColor: Equatable, Sendable {
    case indexed(Int)
    case rgb(Int, Int, Int)
}

public struct TerminalTextStyle: Equatable, Sendable {
    public var foreground: TerminalTextColor?
    public var background: TerminalTextColor?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public var inverse = false
    public var hidden = false
    public init() {}
}

public struct TerminalTextRun: Equatable, Sendable {
    public var text: String
    public let style: TerminalTextStyle
    public init(text: String, style: TerminalTextStyle = TerminalTextStyle()) { self.text = text; self.style = style }
}

public struct StyledTerminalText: Equatable, Sendable {
    public private(set) var runs: [TerminalTextRun] = []
    public init(_ text: String = "") { append(text, style: TerminalTextStyle()) }
    public var text: String { runs.map(\.text).joined() }
    public mutating func append(_ text: String, style: TerminalTextStyle) {
        guard !text.isEmpty else { return }
        if runs.last?.style == style { runs[runs.count - 1].text += text }
        else { runs.append(TerminalTextRun(text: text, style: style)) }
    }
    public mutating func append(_ other: StyledTerminalText) {
        for run in other.runs { append(run.text, style: run.style) }
    }
    public var lines: [StyledTerminalText] {
        var result: [StyledTerminalText] = [], line = StyledTerminalText()
        for run in runs {
            let pieces = run.text.components(separatedBy: "\n")
            for (index, piece) in pieces.enumerated() {
                line.append(piece, style: run.style)
                if index < pieces.count - 1 { result.append(line); line = StyledTerminalText() }
            }
        }
        result.append(line)
        return result
    }
    public static func joining(_ lines: [StyledTerminalText]) -> StyledTerminalText {
        var text = StyledTerminalText()
        for (index, line) in lines.enumerated() {
            if index > 0 { text.append("\n", style: TerminalTextStyle()) }
            text.append(line)
        }
        return text
    }
    public func droppingFirst(_ count: Int) -> StyledTerminalText {
        var remaining = count, result = StyledTerminalText()
        for run in runs {
            if remaining >= run.text.count { remaining -= run.text.count; continue }
            result.append(String(run.text.dropFirst(remaining)), style: run.style)
            remaining = 0
        }
        return result
    }
}

/// Interprets SGR styling from tmux's reconstructed capture, not raw terminal cursor output.
/// Other escape sequences are discarded; OSC sequences cannot trigger clipboard/link actions.
public enum TerminalCaptureStyle {
    public static func parse(_ capture: String) -> StyledTerminalText {
        let bytes = Array(capture.utf8)
        var result = StyledTerminalText(), style = TerminalTextStyle()
        var index = 0, start = 0
        func flush(_ end: Int) {
            if end > start { result.append(String(decoding: bytes[start..<end], as: UTF8.self), style: style) }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 27 {
                flush(index)
                if index + 1 < bytes.count && bytes[index + 1] == 91 {
                    var end = index + 2
                    while end < bytes.count && !(64...126).contains(bytes[end]) { end += 1 }
                    if end < bytes.count && bytes[end] == 109 {
                        apply(String(decoding: bytes[(index + 2)..<end], as: UTF8.self), to: &style)
                    }
                    index = min(bytes.count, end + 1)
                } else if index + 1 < bytes.count && bytes[index + 1] == 93 {
                    index += 2
                    while index < bytes.count {
                        if bytes[index] == 7 { index += 1; break }
                        if bytes[index] == 27 && index + 1 < bytes.count && bytes[index + 1] == 92 { index += 2; break }
                        index += 1
                    }
                } else { index = min(bytes.count, index + 2) }
                start = index
            } else if byte < 32 && byte != 10 && byte != 9 {
                flush(index); index += 1; start = index
            } else { index += 1 }
        }
        flush(bytes.count)
        return result
    }

    private static func apply(_ sequence: String, to style: inout TerminalTextStyle) {
        let groups = sequence.components(separatedBy: ";")
        var index = 0
        while index < groups.count {
            let sub = groups[index].components(separatedBy: ":")
            guard let code = Int(sub[0].isEmpty ? "0" : sub[0]) else { index += 1; continue }
            if code == 38 || code == 48 || code == 58 {
                let parts: [String]
                if sub.count > 1 { parts = Array(sub.dropFirst()) }
                else {
                    let mode = index + 1 < groups.count ? Int(groups[index + 1]) : nil
                    let count = mode == 5 ? 2 : mode == 2 ? 4 : 1
                    parts = Array(groups.dropFirst(index + 1).prefix(count))
                    index += parts.count
                }
                var color: TerminalTextColor?
                if parts.first == "5", parts.count >= 2, let value = Int(parts[1]), (0...255).contains(value) {
                    color = .indexed(value)
                } else if parts.first == "2", parts.count >= 4 {
                    let rgb = parts.suffix(3).compactMap(Int.init)
                    if rgb.count == 3 && rgb.allSatisfy({ (0...255).contains($0) }) { color = .rgb(rgb[0], rgb[1], rgb[2]) }
                }
                if let color {
                    if code == 38 { style.foreground = color }
                    if code == 48 { style.background = color }
                }
            } else {
                switch code {
                case 0: style = TerminalTextStyle()
                case 1: style.bold = true
                case 2: style.dim = true
                case 3: style.italic = true
                case 4, 21: style.underline = true
                case 7: style.inverse = true
                case 8: style.hidden = true
                case 9: style.strikethrough = true
                case 22: style.bold = false; style.dim = false
                case 23: style.italic = false
                case 24: style.underline = false
                case 27: style.inverse = false
                case 28: style.hidden = false
                case 29: style.strikethrough = false
                case 30...37: style.foreground = .indexed(code - 30)
                case 39: style.foreground = nil
                case 40...47: style.background = .indexed(code - 40)
                case 49: style.background = nil
                case 90...97: style.foreground = .indexed(code - 90 + 8)
                case 100...107: style.background = .indexed(code - 100 + 8)
                default: break
                }
            }
            index += 1
        }
    }
}

public enum TerminalViewport {
    public static func bottomOffset(contentHeight: Double, viewportHeight: Double, topInset: Double = 0, bottomInset: Double = 0) -> Double {
        max(-topInset, contentHeight - max(0, viewportHeight) + bottomInset)
    }
}
