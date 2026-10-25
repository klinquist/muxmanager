import Foundation

public enum AuthenticationKind: String, Codable, CaseIterable, Sendable {
    case key, password
}

public struct ConnectionProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var authentication: AuthenticationKind
    public var keyID: UUID?
    public var bastionID: UUID?
    public var modifiedAt: Date
    public var deleted: Bool

    public init(id: UUID = UUID(), name: String = "", hostname: String = "", port: Int = 22,
                username: String = "", authentication: AuthenticationKind = .key,
                keyID: UUID? = nil, bastionID: UUID? = nil, modifiedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.name = name; self.hostname = hostname; self.port = port
        self.username = username; self.authentication = authentication; self.keyID = keyID
        self.bastionID = bastionID; self.modifiedAt = modifiedAt; self.deleted = deleted
    }

    public func validate(in profiles: [ConnectionProfile]) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !hostname.isEmpty, !hostname.contains(where: { $0.isWhitespace }),
              !username.isEmpty, (1...65535).contains(port) else {
            throw MuxError.message("Enter a name, hostname, username, and a port from 1 to 65535.")
        }
        if authentication == .key && keyID == nil { throw MuxError.message("Choose an SSH key.") }
        if let bastionID {
            guard bastionID != id,
                  let bastion = profiles.first(where: { $0.id == bastionID && !$0.deleted }),
                  bastion.bastionID == nil else {
                throw MuxError.message("Choose a direct connection as the bastion. Only one jump is supported.")
            }
        }
    }
}

public struct SSHKeyRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var publicKey: String
    public var modifiedAt: Date
    public var deleted: Bool
    public init(id: UUID = UUID(), name: String, publicKey: String, modifiedAt: Date = Date(), deleted: Bool = false) {
        self.id = id; self.name = name; self.publicKey = publicKey
        self.modifiedAt = modifiedAt; self.deleted = deleted
    }
}

public struct RemoteSession: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct RemoteWindow: Identifiable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let name: String
    public let index: Int
    public let paneID: String
    public let columns: Int
    public let rows: Int
    public let command: String
    public init(id: String, sessionID: String, name: String, index: Int, paneID: String,
                columns: Int, rows: Int, command: String) {
        self.id = id; self.sessionID = sessionID; self.name = name; self.index = index
        self.paneID = paneID; self.columns = columns; self.rows = rows; self.command = command
    }
}

public enum DisplayMode: String, Codable, CaseIterable, Sendable {
    case smart = "Smart", fit = "Fit device", original = "Original"
}

public enum MuxError: LocalizedError, Equatable, Sendable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public struct TmuxVersion: Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public init?(_ text: String) {
        let parts = text.split(whereSeparator: { !$0.isNumber })
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        self.major = major; self.minor = minor
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.major == rhs.major ? lhs.minor < rhs.minor : lhs.major < rhs.major
    }
    public var isSupported: Bool { major > 3 || (major == 3 && minor >= 2) }
}
