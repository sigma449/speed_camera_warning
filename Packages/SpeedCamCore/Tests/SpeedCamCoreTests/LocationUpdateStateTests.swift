import XCTest
@testable import SpeedCamCore

final class LocationUpdateStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testExitRequiresFiveSecondIntervalBeforeRestarting() throws {
        var state = LocationUpdateState()
        state.request()
        let first = try XCTUnwrap(state.beginIfNeeded(now: now, isAuthorized: true))
        XCTAssertNil(state.beginIfNeeded(now: now, isAuthorized: true))
        XCTAssertTrue(state.finish(first, now: now))
        XCTAssertNil(state.generation)
        state.request()
        XCTAssertNil(state.beginIfNeeded(now: now.addingTimeInterval(4.99), isAuthorized: true))
        XCTAssertNotNil(state.beginIfNeeded(now: now.addingTimeInterval(5), isAuthorized: true))
    }

    func testOldExitCannotClearOrDelayTheReplacement() throws {
        var state = LocationUpdateState()
        state.request()
        let first = try XCTUnwrap(state.beginIfNeeded(now: now, isAuthorized: true))
        state.stop()
        state.request()
        let current = try XCTUnwrap(state.beginIfNeeded(now: now, isAuthorized: true))
        XCTAssertFalse(state.finish(first, now: now.addingTimeInterval(100)))
        XCTAssertEqual(state.generation, current)
        XCTAssertTrue(state.finish(current, now: now))
        XCTAssertNotNil(state.beginIfNeeded(now: now.addingTimeInterval(5), isAuthorized: true))
    }

    func testStoppedDemandCannotRestartEvenAfterAnOldExit() throws {
        var state = LocationUpdateState()
        state.request()
        let first = try XCTUnwrap(state.beginIfNeeded(now: now, isAuthorized: true))
        state.stop()
        XCTAssertFalse(state.finish(first, now: now))
        XCTAssertNil(state.beginIfNeeded(now: now.addingTimeInterval(100), isAuthorized: true))
    }

    func testAuthorizationIsRecheckedForEveryRestart() throws {
        var state = LocationUpdateState()
        XCTAssertNil(state.beginIfNeeded(now: now, isAuthorized: true))
        state.request()
        XCTAssertNil(state.beginIfNeeded(now: now, isAuthorized: false))
        let first = try XCTUnwrap(state.beginIfNeeded(now: now, isAuthorized: true))
        XCTAssertTrue(state.finish(first, now: now))
        XCTAssertNil(state.beginIfNeeded(now: now.addingTimeInterval(5), isAuthorized: false))
        XCTAssertNotNil(state.beginIfNeeded(now: now.addingTimeInterval(6), isAuthorized: true))
    }
}
