import Foundation

/// Recovery belongs to the user's connection intent, not to a socket. A failed
/// initial login never starts unattended retries; a previously healthy link can.
public struct AutomaticReconnect: Sendable {
    public private(set) var wantsConnection = false
    public private(set) var hasConnected = false
    public private(set) var recovering = false
    public private(set) var needsAttention = false
    private var attempts = 0
    public init() {}
    public mutating func requested() {
        wantsConnection = true; needsAttention = false; recovering = false; attempts = 0
    }
    public mutating func connected() {
        hasConnected = true; recovering = false; needsAttention = false; attempts = 0
    }
    public mutating func lostConnection() {
        if wantsConnection && hasConnected && !needsAttention { recovering = true }
    }
    public mutating func failed(retryable: Bool) {
        if !retryable { needsAttention = true; recovering = false }
    }
    public mutating func stopped() { self = AutomaticReconnect() }
    public mutating func nextDelay(isBackgrounded: Bool) -> TimeInterval? {
        guard wantsConnection, recovering, !needsAttention, !isBackgrounded else { return nil }
        let delay = [0.0, 2, 4, 8, 16, 30][min(attempts, 5)]
        attempts = min(attempts + 1, 5)
        return delay
    }
}
