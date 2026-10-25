import Foundation

/// Best-effort decoding of a tmux -J capture, not a shell editing-buffer API.
public struct ShellCompletionScreen: Equatable, Sendable {
    public let beforeCursor: String
    public let afterCursor: String

    public init?(joinedLine: String, columns: Int, cursorX: Int) {
        guard columns > 0, cursorX >= 0, cursorX < columns - 1 else { return nil }
        let width = Self.width(of: joinedLine)
        let wrappedRows = max(0, (max(1, width) - 1) / columns)
        let end = wrappedRows * columns + cursorX
        guard end <= width else { return nil }
        var used = 0, prefix = "", suffix = ""
        for character in joinedLine {
            let size = Self.width(of: character)
            guard size >= 0 else { return nil }
            if used + size <= end {
                prefix.append(character)
            } else {
                guard used >= end else { return nil } // Cursor bisects a wide glyph.
                suffix.append(character)
            }
            used += size
        }
        beforeCursor = prefix
        afterCursor = suffix.trimmingCharacters(in: .whitespaces)
    }

    public var resemblesEmptyPrompt: Bool {
        let prompt = beforeCursor.trimmingCharacters(in: .whitespaces)
        guard let last = prompt.last else { return false }
        // Deliberately excludes a bare continuation prompt (>).
        return ["%", "$", "#", "❯", "➜", "λ"].contains(String(last))
    }

    public func completedText(after prompt: ShellCompletionScreen) -> String? {
        guard beforeCursor.hasPrefix(prompt.beforeCursor),
              afterCursor.isEmpty || afterCursor == prompt.afterCursor else { return nil }
        let text = String(beforeCursor.dropFirst(prompt.beforeCursor.count))
        guard !text.contains(where: { $0.isNewline }),
              text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { return nil }
        return text
    }

    private static func width(of text: String) -> Int {
        text.reduce(0) { $0 + max(0, width(of: $1)) }
    }
    private static func width(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        if scalars.contains(where: { $0.value < 32 || $0.value == 127 }) { return -1 }
        if scalars.allSatisfy({ [.nonspacingMark, .enclosingMark, .format].contains($0.properties.generalCategory) }) { return 0 }
        if scalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xfe0f }) { return 2 }
        return scalars.contains { scalar in
            let n = scalar.value
            return (0x1100...0x115f).contains(n) || (0x2329...0x232a).contains(n) ||
                (0x2e80...0xa4cf).contains(n) || (0xac00...0xd7a3).contains(n) ||
                (0xf900...0xfaff).contains(n) || (0xfe10...0xfe19).contains(n) ||
                (0xfe30...0xfe6f).contains(n) || (0xff00...0xff60).contains(n) ||
                (0xffe0...0xffe6).contains(n) || (0x20000...0x3fffd).contains(n)
        } ? 2 : 1
    }
}
