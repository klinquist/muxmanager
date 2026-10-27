import Foundation

public enum TextBlockKind: String, Sendable { case prose, fixed, unknown }
public struct TextBlock: Identifiable, Equatable, Sendable {
    public let id: Int
    public let kind: TextBlockKind
    public let text: String
    public let styledText: StyledTerminalText
    public init(id: Int, kind: TextBlockKind, text: String, styledText: StyledTerminalText? = nil) {
        self.id = id; self.kind = kind; self.text = text; self.styledText = styledText ?? StyledTerminalText(text)
    }
}

/// Input is a tmux capture with -J: tmux, not a heuristic, joins soft-wrapped terminal rows.
/// Preserve hard newlines. Never join two arbitrary screen rows just because they look like prose.
public enum SmartPresentation {
    public static func blocks(from joinedCapture: String) -> [TextBlock] {
        let lines = TerminalCaptureStyle.parse(joinedCapture).lines
        var blocks: [TextBlock] = []
        var buffer: [StyledTerminalText] = []
        var current: TextBlockKind?
        var fenced = false
        func flush() {
            guard let kind = current, !buffer.isEmpty else { return }
            let styled = StyledTerminalText.joining(buffer)
            blocks.append(TextBlock(id: blocks.count, kind: kind, text: styled.text, styledText: styled))
            buffer.removeAll(keepingCapacity: true)
        }
        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            let fence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            let kind: TextBlockKind = (fenced || fence || isFixed(line.text)) ? .fixed : .prose
            if current != kind { flush(); current = kind }
            buffer.append(line)
            if fence { fenced.toggle() }
        }
        flush()
        return blocks
    }

    private static func isFixed(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return line.hasPrefix("    ") || line.hasPrefix("\t") ||
            trimmed.hasPrefix("diff --git ") || trimmed.hasPrefix("@@ ") ||
            trimmed.hasPrefix("+++ ") || trimmed.hasPrefix("--- ") ||
            line.contains("│") || line.contains("┌") || line.contains("└") ||
            line.contains(" | ") || line.range(of: "\\S {3,}\\S", options: .regularExpression) != nil
    }
}

public enum ConversationRole: String, Sendable { case user, assistant, terminal }
public struct ConversationBlock: Identifiable, Equatable, Sendable {
    public let id: Int
    public let role: ConversationRole
    public let text: String
    public let styledText: StyledTerminalText
    public init(id: Int, role: ConversationRole, text: String, styledText: StyledTerminalText? = nil) {
        self.id = id; self.role = role; self.text = text; self.styledText = styledText ?? StyledTerminalText(text)
    }
}

public enum CodexPresentation {
    /// Conservative screen projection. Every nonempty line survives, including approval dialogs.
    public static func blocks(from capture: String) -> [ConversationBlock] {
        var result: [ConversationBlock] = []
        var role: ConversationRole = .terminal
        var buffer: [StyledTerminalText] = []
        func flush() {
            while buffer.first?.text.isEmpty == true { buffer.removeFirst() }
            while buffer.last?.text.isEmpty == true { buffer.removeLast() }
            let styled = StyledTerminalText.joining(buffer)
            if !styled.text.isEmpty { result.append(ConversationBlock(id: result.count, role: role, text: styled.text, styledText: styled)) }
            buffer = []
        }
        for line in TerminalCaptureStyle.parse(capture).lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            let newRole: ConversationRole?
            let content: StyledTerminalText
            let leading = line.text.prefix(while: \.isWhitespace).count
            if trimmed.hasPrefix("› ") || trimmed.hasPrefix("> ") {
                newRole = .user; content = line.droppingFirst(leading + 2)
            } else if trimmed.hasPrefix("• ") {
                newRole = .assistant; content = line.droppingFirst(leading + 2)
            } else if isInteractive(trimmed) {
                newRole = .terminal; content = line
            } else { newRole = nil; content = line }
            if let newRole {
                // Adjacent assistant bullets belong to one selectable response.
                // User prompts and interactive terminal content retain boundaries.
                if newRole != role || newRole == .user { flush() }
                role = newRole
            }
            buffer.append(content)
        }
        flush()
        return result
    }
    public static func isInteractive(_ text: String) -> Bool {
        let value = text.lowercased()
        return ["would you like", "approve", "approval", "press enter", "esc to", "allow once", "yes, proceed", "1. yes", "run (once)"].contains { value.contains($0) }
    }
}
