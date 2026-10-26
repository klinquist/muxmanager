import Foundation

/// A monotonic deadline and the user's connection intentions at backgrounding.
/// Losing iOS background runtime does not itself invalidate parked SSH sockets.
public struct BackgroundConnectionSession: Sendable {
    public static let retentionInterval: Duration = .seconds(10 * 60)
    public let id = UUID()
    public let startedAt: ContinuousClock.Instant
    public let intents: [UUID: UUID]

    public init(startedAt: ContinuousClock.Instant = ContinuousClock().now, intents: [UUID: UUID]) {
        self.startedAt = startedAt
        self.intents = intents
    }

    public func remainingTime(at instant: ContinuousClock.Instant = ContinuousClock().now) -> Duration {
        min(Self.retentionInterval, max(.zero, instant.duration(to: startedAt.advanced(by: Self.retentionInterval))))
    }

    public func requiresReconnect(at instant: ContinuousClock.Instant = ContinuousClock().now) -> Bool {
        instant >= startedAt.advanced(by: Self.retentionInterval)
    }

    public func includes(host: UUID, intent: UUID) -> Bool { intents[host] == intent }
}
