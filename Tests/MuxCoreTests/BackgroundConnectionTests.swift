import XCTest
@testable import MuxCore

final class BackgroundConnectionTests: XCTestCase {
    func testShortAppSwitchRetainsTheConnection() {
        let start = ContinuousClock().now
        let session = BackgroundConnectionSession(startedAt: start, intents: [:])
        XCTAssertEqual(session.remainingTime(at: start.advanced(by: .seconds(5 * 60))), .seconds(5 * 60))
        XCTAssertFalse(session.requiresReconnect(at: start.advanced(by: .seconds(599))))
    }

    func testExpiredRetentionUsesAReconnectEvenAfterProcessSuspension() {
        let start = ContinuousClock().now
        let session = BackgroundConnectionSession(startedAt: start, intents: [:])
        XCTAssertTrue(session.requiresReconnect(at: start.advanced(by: .seconds(600))))
        XCTAssertTrue(session.requiresReconnect(at: start.advanced(by: .seconds(3600))))
        XCTAssertEqual(session.remainingTime(at: start.advanced(by: .seconds(3600))), .zero)
    }

    func testUserDisconnectOrNewConnectionPreventsStaleAutomaticResume() {
        let host = UUID(), intent = UUID(), anotherHost = UUID()
        let session = BackgroundConnectionSession(intents: [host: intent])
        XCTAssertTrue(session.includes(host: host, intent: intent))
        XCTAssertFalse(session.includes(host: host, intent: UUID()))
        XCTAssertFalse(session.includes(host: anotherHost, intent: intent))
    }

    func testRepeatedBackgroundTransitionsHaveIndependentOwnership() {
        let host = UUID(), intent = UUID(), start = ContinuousClock().now
        let old = BackgroundConnectionSession(startedAt: start, intents: [host: intent])
        let new = BackgroundConnectionSession(startedAt: start.advanced(by: .seconds(590)), intents: [host: intent])
        XCTAssertNotEqual(old.id, new.id)
        XCTAssertTrue(old.requiresReconnect(at: start.advanced(by: .seconds(610))))
        XCTAssertFalse(new.requiresReconnect(at: start.advanced(by: .seconds(610))))
        XCTAssertEqual(new.remainingTime(at: start.advanced(by: .seconds(610))), .seconds(580))
    }
}
