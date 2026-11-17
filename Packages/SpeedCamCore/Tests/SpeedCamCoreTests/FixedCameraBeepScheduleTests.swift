import Foundation
import XCTest
@testable import SpeedCamCore

final class FixedCameraBeepScheduleTests: XCTestCase {
    private let camera = Camera(id: "fixed", type: .fixed, lat: 25, lon: 121, heading: 0, speedLimit: 50)

    private func target(overspeed: Bool = true) -> CameraTarget {
        CameraTarget(camera: camera, distance: 200, phase: .pre, isOverspeed: overspeed)
    }

    private func fix(_ seconds: Double, accuracy: Double = 5) -> VehicleFix {
        VehicleFix(point: camera.point, speedMps: 70 / 3.6, course: 0,
            horizontalAccuracy: accuracy, timestamp: t0.addingTimeInterval(seconds))
    }

    func testTenSecondsUsesExactHalfOneThreeAndTenSecondAudioCadencesWithOneHzFixes() {
        for interval in [0.5, 1, 3, 10] {
            var schedule = FixedCameraBeepSchedule()
            var beeps: [Double] = []
            var starts = 0
            for step in 0..<40 {
                let second = Double(step) / 4
                let now = t0.addingTimeInterval(second)
                if step.isMultiple(of: 4) {
                    if case .start = schedule.update(target: target(), fix: fix(second),
                        interval: interval, now: now) { starts += 1 }
                }
                if let beep = schedule.lastBeep(at: now)?.timeIntervalSince(t0), beeps.last != beep {
                    beeps.append(beep)
                }
            }
            XCTAssertEqual(beeps, stride(from: 0.0, to: 10, by: interval).map { $0 })
            XCTAssertEqual(beeps.count, interval == 0.5 ? 20 : interval == 1 ? 10 : interval == 3 ? 4 : 1)
            XCTAssertEqual(starts, 1, "每秒定位只延長有效期，不可重啟音訊節拍")
            XCTAssertEqual(schedule.update(target: target(overspeed: false), fix: fix(10),
                interval: interval, now: t0.addingTimeInterval(10)), .stop)
            for second in stride(from: 10.0, through: 12, by: 0.25) {
                XCTAssertNil(schedule.lastBeep(at: t0.addingTimeInterval(second)))
            }
        }
    }

    func testEndSlowPassHideEditAndStopCancelAllFutureBeeps() {
        var noLimit = target()
        noLimit.camera.speedLimit = nil
        let endedTargets: [CameraTarget?] = [target(overspeed: false), nil, noLimit]
        for ended in endedTargets {
            var schedule = FixedCameraBeepSchedule()
            _ = schedule.update(target: target(), fix: fix(0), interval: 0.5, now: t0)
            XCTAssertEqual(schedule.update(target: ended, fix: fix(0.25), interval: 0.5,
                now: t0.addingTimeInterval(0.25)), .stop)
            XCTAssertNil(schedule.playback)
            XCTAssertNil(schedule.lastBeep(at: t0.addingTimeInterval(0.5)))
        }
        var stopped = FixedCameraBeepSchedule()
        _ = stopped.update(target: target(), fix: fix(0), interval: 0.5, now: t0)
        XCTAssertEqual(stopped.stop(), .stop)
        XCTAssertEqual(stopped.stop(), .unchanged)
        XCTAssertNil(stopped.lastBeep(at: t0.addingTimeInterval(0.5)))
    }

    func testOldFixCannotRenewAudioLeaseAndUnreliableFixStopsImmediately() throws {
        var schedule = FixedCameraBeepSchedule()
        _ = schedule.update(target: target(), fix: fix(0), interval: 0.5, now: t0)
        XCTAssertEqual(schedule.update(target: target(), fix: fix(0), interval: 0.5,
            now: t0.addingTimeInterval(2)), .unchanged)
        XCTAssertEqual(schedule.expiresAt, t0.addingTimeInterval(2.5))
        XCTAssertEqual(schedule.expire(at: t0.addingTimeInterval(2.5)), .stop)
        XCTAssertNil(schedule.lastBeep(at: t0.addingTimeInterval(2.5)))
        XCTAssertEqual(schedule.update(target: target(), fix: fix(0), interval: 0.5,
            now: t0.addingTimeInterval(3)), .unchanged)
        _ = schedule.update(target: target(), fix: fix(3), interval: 0.5, now: t0.addingTimeInterval(3))
        XCTAssertEqual(schedule.expire(at: t0.addingTimeInterval(2.5)), .unchanged)
        XCTAssertEqual(schedule.update(target: target(), fix: fix(3.1, accuracy: 101),
            interval: 0.5, now: t0.addingTimeInterval(3.1)), .stop)
        XCTAssertNil(schedule.playback)
    }

    func testChangingIntervalAppliesImmediatelyFromLastBeepWithoutDuplicatingOrCatchingUp() throws {
        var schedule = FixedCameraBeepSchedule()
        _ = schedule.update(target: target(), fix: fix(0), interval: 3, now: t0)
        let faster = schedule.update(target: target(), fix: fix(1), interval: 0.5,
            now: t0.addingTimeInterval(1))
        XCTAssertEqual(faster, .start(try XCTUnwrap(schedule.playback)))
        XCTAssertEqual(schedule.playback?.firstBeepAt, t0.addingTimeInterval(1))
        XCTAssertEqual(schedule.lastBeep(at: t0.addingTimeInterval(1.75)), t0.addingTimeInterval(1.5))
        XCTAssertEqual(schedule.update(target: target(), fix: fix(2), interval: 10,
            now: t0.addingTimeInterval(2.1)), .start(
                .init(firstBeepAt: t0.addingTimeInterval(12), interval: 10)))
        XCTAssertEqual(schedule.lastBeep(at: t0.addingTimeInterval(2.1)), t0.addingTimeInterval(2))
        XCTAssertEqual(schedule.update(target: target(), fix: fix(2), interval: 10,
            now: t0.addingTimeInterval(2.2)), .unchanged)
        XCTAssertEqual(schedule.update(target: target(), fix: fix(2), interval: 1,
            now: t0.addingTimeInterval(2.3)), .start(
                .init(firstBeepAt: t0.addingTimeInterval(3), interval: 1)))
        XCTAssertEqual(schedule.lastBeep(at: t0.addingTimeInterval(2.75)), t0.addingTimeInterval(2))
        XCTAssertEqual(schedule.lastBeep(at: t0.addingTimeInterval(3)), t0.addingTimeInterval(3))
    }

    func testChangingExactlyAtBeepBoundaryOrBeforePendingStartDoesNotAddAnExtraBeep() {
        var schedule = FixedCameraBeepSchedule()
        _ = schedule.update(target: target(), fix: fix(0), interval: 0.5, now: t0)
        _ = schedule.update(target: target(), fix: fix(0.5), interval: 1, now: t0.addingTimeInterval(0.5))
        XCTAssertEqual(schedule.playback?.firstBeepAt, t0.addingTimeInterval(1.5))
        XCTAssertEqual(schedule.lastBeep(at: t0.addingTimeInterval(0.5)), t0.addingTimeInterval(0.5))
        _ = schedule.update(target: target(), fix: fix(0.6), interval: 3, now: t0.addingTimeInterval(0.6))
        XCTAssertEqual(schedule.playback?.firstBeepAt, t0.addingTimeInterval(3.5))
        _ = schedule.update(target: target(), fix: fix(0.7), interval: 1, now: t0.addingTimeInterval(0.7))
        XCTAssertEqual(schedule.playback?.firstBeepAt, t0.addingTimeInterval(1.5))
        XCTAssertEqual(schedule.lastBeep(at: t0.addingTimeInterval(1.49)), t0.addingTimeInterval(0.5))
    }

    func testFreshFixAfterExpiryStartsNowInsteadOfPlayingMissedBeeps() {
        var schedule = FixedCameraBeepSchedule()
        _ = schedule.update(target: target(), fix: fix(0), interval: 0.5, now: t0)
        XCTAssertNil(schedule.lastBeep(at: t0.addingTimeInterval(5)))
        _ = schedule.update(target: target(), fix: fix(5), interval: 0.5, now: t0.addingTimeInterval(5))
        XCTAssertEqual(schedule.playback?.firstBeepAt, t0.addingTimeInterval(5))
        XCTAssertEqual(schedule.lastBeep(at: t0.addingTimeInterval(5)), t0.addingTimeInterval(5))
    }

    func testNonSpeedCameraCannotStartLoopEvenWithErroneousOverspeedFlag() {
        for type in [CameraType.redLight, .mobile, .noise, .tech] {
            var value = target()
            value.camera.type = type
            var schedule = FixedCameraBeepSchedule()
            XCTAssertEqual(schedule.update(target: value, fix: fix(0), interval: 0.5, now: t0), .unchanged)
            XCTAssertNil(schedule.playback)
        }
    }
}
