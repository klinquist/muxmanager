import Foundation

public struct WindowSizing: Codable, Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    /// nil represents an inherited window-size option.
    public var localPolicy: String?
    public init(columns: Int, rows: Int, localPolicy: String?) {
        self.columns = columns; self.rows = rows; self.localPolicy = localPolicy
    }
}

public struct ResizeLease: Codable, Equatable, Sendable {
    public let hostID: UUID
    public let serverIdentity: String
    public let windowID: String
    public let previous: WindowSizing
    public var applied: WindowSizing
    /// Last acknowledged app size while a new resize is in flight.
    public var fallbackApplied: WindowSizing?

    public init(hostID: UUID, serverIdentity: String, windowID: String, previous: WindowSizing, applied: WindowSizing, fallbackApplied: WindowSizing? = nil) {
        self.hostID = hostID; self.serverIdentity = serverIdentity; self.windowID = windowID
        self.previous = previous; self.applied = applied; self.fallbackApplied = fallbackApplied
    }

    public func mayRestore(current: WindowSizing, serverIdentity: String) -> Bool {
        self.serverIdentity == serverIdentity && (current == applied || current == fallbackApplied)
    }

    public func restorationCommands(current: WindowSizing, serverIdentity: String) -> [String] {
        guard mayRestore(current: current, serverIdentity: serverIdentity),
              TmuxCommand.isID(windowID, prefix: "@") else { return [] }
        let target = TmuxCommand.quote(windowID)
        let dimensions = "resize-window -t \(target) -x \(previous.columns) -y \(previous.rows)"
        let policy = previous.localPolicy.map { "set-option -w -t \(target) window-size \(TmuxCommand.quote($0))" }
            ?? "set-option -wu -t \(target) window-size"
        return [dimensions, policy]
    }
}

/// Last-writer-wins records include tombstones, preventing offline deletes from resurrecting.
public enum ProfileMerge {
    public static func merge(local: [ConnectionProfile], remote: [ConnectionProfile]) -> [ConnectionProfile] {
        var merged = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for value in remote where merged[value.id].map({ $0.modifiedAt < value.modifiedAt }) ?? true {
            merged[value.id] = value
        }
        return merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func keys(local: [SSHKeyRecord], remote: [SSHKeyRecord]) -> [SSHKeyRecord] {
        var merged = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for value in remote where merged[value.id].map({ $0.modifiedAt < value.modifiedAt }) ?? true {
            merged[value.id] = value
        }
        return merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
