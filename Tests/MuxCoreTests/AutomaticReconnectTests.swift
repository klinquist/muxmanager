import XCTest
@testable import MuxCore

final class AutomaticReconnectTests: XCTestCase {
    func testOnlyPreviouslyHealthyConnectionsRetryWithCappedBackoff() {
        var policy = AutomaticReconnect()
        policy.requested(); policy.failed(retryable: true)
        XCTAssertNil(policy.nextDelay(isBackgrounded: false))
        policy.connected(); policy.lostConnection()
        XCTAssertEqual((0..<9).compactMap { _ in policy.nextDelay(isBackgrounded: false) }, [0, 2, 4, 8, 16, 30, 30, 30, 30])
        policy.connected()
        XCTAssertNil(policy.nextDelay(isBackgrounded: false))
        policy.lostConnection()
        XCTAssertEqual(policy.nextDelay(isBackgrounded: false), 0)
    }
    func testExplicitDisconnectAndOldSocketEventsCannotRestartRetries() {
        var policy = AutomaticReconnect()
        policy.requested(); policy.connected(); policy.lostConnection(); policy.stopped()
        policy.lostConnection()
        XCTAssertFalse(policy.wantsConnection)
        XCTAssertFalse(policy.recovering)
        XCTAssertNil(policy.nextDelay(isBackgrounded: false))
    }
    func testBackgroundPausesWithoutConsumingRetryAttempts() {
        var policy = AutomaticReconnect()
        policy.requested(); policy.connected(); policy.lostConnection()
        XCTAssertNil(policy.nextDelay(isBackgrounded: true))
        XCTAssertEqual(policy.nextDelay(isBackgrounded: false), 0)
        XCTAssertNil(policy.nextDelay(isBackgrounded: true))
        XCTAssertEqual(policy.nextDelay(isBackgrounded: false), 2)
    }
    func testAuthenticationOrTrustFailuresWaitForAnExplicitNewRequest() {
        var policy = AutomaticReconnect()
        policy.requested(); policy.connected(); policy.lostConnection(); policy.failed(retryable: false)
        policy.lostConnection()
        XCTAssertTrue(policy.needsAttention)
        XCTAssertNil(policy.nextDelay(isBackgrounded: false))
        policy.requested(); policy.connected(); policy.lostConnection()
        XCTAssertFalse(policy.needsAttention)
        XCTAssertEqual(policy.nextDelay(isBackgrounded: false), 0)
    }
}
