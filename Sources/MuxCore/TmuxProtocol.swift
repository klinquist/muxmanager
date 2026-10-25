import Foundation

public enum ControlEvent: Equatable, Sendable {
    case response(token: String, lines: [String], failed: Bool)
    case output(pane: String, bytes: Data)
    case notification(String)
    case exit(String)
    case protocolError(String)
}

/// Incremental, byte-oriented parser: SSH packets need not end at UTF-8 or protocol boundaries.
public struct TmuxControlParser: Sendable {
    private var pending = Data()
    private var blockToken: String?
    private var blockLines: [String] = []
    private var blockBytes = 0
    public let limit: Int
    public init(limit: Int = 8 * 1024 * 1024) { self.limit = limit }

    public mutating func feed(_ data: Data) -> [ControlEvent] {
        pending.append(data)
        var events: [ControlEvent] = []
        var cursor = pending.startIndex
        while let end = pending[cursor...].firstIndex(of: 10) {
            let line = String(decoding: pending[cursor..<end], as: UTF8.self)
            cursor = pending.index(after: end)
            events.append(contentsOf: consume(line))
        }
        if cursor > pending.startIndex { pending.removeSubrange(..<cursor) }
        if pending.count > limit {
            pending.removeAll(); blockLines.removeAll(); blockToken = nil; blockBytes = 0
            events.append(.protocolError("tmux sent a protocol line larger than the safety limit."))
        }
        return events
    }

    private mutating func consume(_ line: String) -> [ControlEvent] {
        if let token = blockToken {
            if line == "%end \(token)" || line == "%error \(token)" {
                let event = ControlEvent.response(token: token, lines: blockLines, failed: line.hasPrefix("%error"))
                blockToken = nil; blockLines = []; blockBytes = 0
                return [event]
            }
            blockBytes += line.utf8.count + 1
            guard blockBytes <= limit else {
                blockToken = nil; blockLines = []; blockBytes = 0
                return [.protocolError("tmux response exceeded the safety limit.")]
            }
            blockLines.append(line)
            return []
        }
        if line.hasPrefix("%begin ") {
            blockToken = String(line.dropFirst(7)); blockLines = []; blockBytes = 0
            return []
        }
        if line.hasPrefix("%output ") {
            let body = line.dropFirst(8)
            guard let space = body.firstIndex(of: " ") else { return [] }
            return [.output(pane: String(body[..<space]), bytes: Self.unescape(String(body[body.index(after: space)...])))]
        }
        if line.hasPrefix("%extended-output "), let marker = line.range(of: " : ") {
            let fields = line.split(separator: " ", maxSplits: 3)
            guard fields.count >= 3 else { return [] }
            return [.output(pane: String(fields[1]), bytes: Self.unescape(String(line[marker.upperBound...])))]
        }
        if line.hasPrefix("%exit") { return [.exit(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))] }
        if line.hasPrefix("%") { return [.notification(line)] }
        return []
    }

    public static func unescape(_ value: String) -> Data {
        let input = Array(value.utf8)
        var result = Data(); var i = 0
        while i < input.count {
            if input[i] == 92, i + 3 < input.count,
               input[(i + 1)...(i + 3)].allSatisfy({ (48...55).contains($0) }) {
                let n = Int(input[i + 1] - 48) * 64 + Int(input[i + 2] - 48) * 8 + Int(input[i + 3] - 48)
                if n <= 255 { result.append(UInt8(n)); i += 4; continue }
            }
            result.append(input[i]); i += 1
        }
        return result
    }
}

public enum TmuxCommand {
    /// Quotes one tmux argument (not a shell argument).
    public static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    /// SSH exec channels often have LANG/LC_* unset. Without -u, tmux replaces
    /// tabs and non-ASCII output with underscores, corrupting discovery records.
    public static func invocation(executable: String, arguments: String) -> String {
        "\(shellQuote(executable)) -u \(arguments)"
    }
    public static func isID(_ value: String, prefix: Character) -> Bool {
        value.first == prefix && value.count > 1 && value.dropFirst().allSatisfy(\.isNumber)
    }
    public static func attach(session: String) throws -> String {
        guard isID(session, prefix: "$") else { throw MuxError.message("Invalid tmux session ID.") }
        return "-C attach-session -f ignore-size -t \(shellQuote(session))"
    }
    public static func capture(pane: String, joined: Bool, colors: Bool = false) throws -> String {
        guard isID(pane, prefix: "%") else { throw MuxError.message("Invalid pane ID.") }
        return "capture-pane -p\(joined ? "J" : "")\(colors ? "e" : "") -S -2000 -t \(quote(pane))"
    }
    public static func sendBytes(_ bytes: Data, pane: String) throws -> [String] {
        guard isID(pane, prefix: "%") else { throw MuxError.message("Invalid pane ID.") }
        // Hex input cannot inject tmux commands, even when pasted text contains newlines or semicolons.
        let array = Array(bytes)
        return stride(from: 0, to: array.count, by: 256).map { offset in
            let hex = array[offset..<min(offset + 256, array.count)].map { String(format: "%02x", $0) }.joined(separator: " ")
            return "send-keys -H -t \(quote(pane)) \(hex)"
        }
    }
    public static func pasteCommands(_ text: String, pane: String, buffer: String, submit: Bool) throws -> [String] {
        guard isID(pane, prefix: "%"), !buffer.isEmpty,
              buffer.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), !text.contains("\0") else {
            throw MuxError.message("The input contains an unsupported NUL character or invalid target.")
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var commands = ["set-buffer -b \(quote(buffer)) -- \(quote(normalized))",
                        "paste-buffer -p -r -d -b \(quote(buffer)) -t \(quote(pane))"]
        if submit { commands.append("send-keys -t \(quote(pane)) Enter") }
        return commands
    }
    public static let sessionFormat = "#{session_id}\t#{q:session_name}"
    public static let windowFormat = "#{window_id}\t#{window_index}\t#{q:window_name}\t#{pane_id}\t#{pane_width}\t#{pane_height}\t#{q:pane_current_command}"

    public static func sessions(_ lines: [String]) -> [RemoteSession] {
        lines.compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 2, isID(fields[0], prefix: "$") else { return nil }
            return RemoteSession(id: fields[0], name: unquoteFormat(fields[1]))
        }
    }
    public static func windows(_ lines: [String], session: String) -> [RemoteWindow] {
        lines.compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count == 7, isID(f[0], prefix: "@"), isID(f[3], prefix: "%"),
                  let index = Int(f[1]), let columns = Int(f[4]), let rows = Int(f[5]),
                  (1...10000).contains(columns), (1...10000).contains(rows) else { return nil }
            return RemoteWindow(id: f[0], sessionID: session, name: unquoteFormat(f[2]), index: index,
                                paneID: f[3], columns: columns, rows: rows, command: unquoteFormat(f[6]))
        }.sorted { $0.index < $1.index }
    }
    private static func unquoteFormat(_ text: String) -> String {
        var result = ""; var escaped = false
        for char in text {
            if escaped { result.append(char); escaped = false }
            else if char == "\\" { escaped = true }
            else { result.append(char) }
        }
        if escaped { result.append("\\") }
        return result
    }
}
