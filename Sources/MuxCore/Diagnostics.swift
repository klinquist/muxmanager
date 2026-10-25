import Foundation

/// Bounded, in-memory metadata log. Callers must never submit terminal contents or credentials.
public struct DiagnosticBuffer: Sendable {
    public struct Entry: Identifiable, Sendable {
        public let id: Int
        public let date: Date
        public let category: String
        public let message: String
    }
    public private(set) var entries: [Entry] = []
    private var nextID = 0
    private var byteCount = 0
    private let maxEntries: Int
    private let maxBytes: Int

    public init(maxEntries: Int = 500, maxBytes: Int = 192 * 1024) {
        self.maxEntries = max(1, maxEntries); self.maxBytes = max(256, maxBytes)
    }
    public mutating func append(_ message: String, category: String, at date: Date = Date()) {
        let safe = Self.escaped(message, limit: min(2048, maxBytes - 64))
        let category = Self.escaped(category, limit: 32)
        let entry = Entry(id: nextID, date: date, category: category, message: safe)
        nextID += 1; entries.append(entry); byteCount += safe.utf8.count + category.utf8.count + 32
        while entries.count > maxEntries || byteCount > maxBytes {
            let removed = entries.removeFirst()
            byteCount -= removed.message.utf8.count + removed.category.utf8.count + 32
        }
    }
    public mutating func clear() { entries = []; byteCount = 0 }
    public var text: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries.map { "\(formatter.string(from: $0.date)) [\($0.category)] \($0.message)" }.joined(separator: "\n")
    }
    private static func escaped(_ text: String, limit: Int) -> String {
        var output = ""
        var size = 0
        for scalar in text.unicodeScalars {
            let fragment: String
            switch scalar.value {
            case 9: fragment = "\\t"
            case 10: fragment = "\\n"
            case 13: fragment = "\\r"
            case 0...31, 127...159: fragment = String(format: "\\u{%04X}", scalar.value)
            default: fragment = String(scalar)
            }
            if size + fragment.utf8.count > limit - 16 { output += "… [truncated]"; break }
            output += fragment; size += fragment.utf8.count
        }
        return output
    }
}
