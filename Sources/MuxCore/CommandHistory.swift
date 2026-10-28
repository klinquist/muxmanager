/// Session-local composer history. Callers keep a separate value per window;
/// commands are never persisted or synchronized.
public struct CommandHistory: Sendable {
    private var commands: [String] = []
    private var position: Int?
    private var savedDraft = ""
    private var recalledDraft: String?
    private let limit: Int

    public init(limit: Int = 100) { self.limit = max(1, limit) }

    public func isBrowsing(_ draft: String) -> Bool {
        position != nil && recalledDraft == draft
    }

    public mutating func record(_ command: String) {
        resetNavigation()
        guard command.contains(where: { !$0.isWhitespace }) else { return }
        if commands.last != command { commands.append(command) }
        if commands.count > limit { commands.removeFirst(commands.count - limit) }
    }

    public mutating func previous(from draft: String) -> String? {
        guard !commands.isEmpty else { return nil }
        if !isBrowsing(draft) { position = nil; savedDraft = draft }
        let index = max(0, (position ?? commands.count) - 1)
        position = index; recalledDraft = commands[index]
        return recalledDraft
    }

    public mutating func next(from draft: String) -> String? {
        guard isBrowsing(draft), let position else { resetNavigation(); return nil }
        if position + 1 < commands.count {
            self.position = position + 1; recalledDraft = commands[position + 1]
            return recalledDraft
        }
        let result = savedDraft
        resetNavigation()
        return result
    }

    public mutating func resetNavigation() {
        position = nil; recalledDraft = nil; savedDraft = ""
    }
}
