import XCTest
@testable import SpeedCamCore

final class MapFollowTests: XCTestCase {
    func testModeCyclesThroughAllThree() {
        XCTAssertEqual(MapFollowMode.headingUp.next, .northUp)
        XCTAssertEqual(MapFollowMode.northUp.next, .headingUp3D)
        XCTAssertEqual(MapFollowMode.headingUp3D.next, .headingUp)
        XCTAssertFalse(MapFollowMode.northUp.rotatesWithHeading)
        XCTAssertEqual(MapFollowMode.headingUp.pitch, 0)
        XCTAssertGreaterThan(MapFollowMode.headingUp3D.pitch, 0)
    }

    func testZoomGrowsWithSpeedWithinBounds() {
        let stopped = MapFollowCamera.distance(forSpeedKmh: 0, mode: .headingUp)
        let city = MapFollowCamera.distance(forSpeedKmh: 40, mode: .headingUp)
        let highway = MapFollowCamera.distance(forSpeedKmh: 110, mode: .headingUp)
        XCTAssertEqual(stopped, 700)
        XCTAssertGreaterThan(city, stopped)
        XCTAssertGreaterThan(highway, city)
        XCTAssertEqual(MapFollowCamera.distance(forSpeedKmh: 200, mode: .headingUp), 3_000)
        XCTAssertLessThan(MapFollowCamera.distance(forSpeedKmh: 40, mode: .headingUp3D), city)
    }

    func testLookAheadOnlyWhenMovingAndHeadingUp() {
        XCTAssertEqual(MapFollowCamera.lookAhead(distance: 1_000, speedKmh: 5, mode: .headingUp), 0)
        XCTAssertEqual(MapFollowCamera.lookAhead(distance: 1_000, speedKmh: 50, mode: .northUp), 0)
        XCTAssertEqual(MapFollowCamera.lookAhead(distance: 1_000, speedKmh: 50, mode: .headingUp), 200)
    }

    private func fix(_ t: TimeInterval, kmh: Double, accuracy: Double = 5) -> VehicleFix {
        VehicleFix(point: GeoPoint(lat: 25, lon: 121.5), speedMps: kmh / 3.6, course: 0,
                   horizontalAccuracy: accuracy, timestamp: Date(timeIntervalSince1970: t))
    }

    func testRecenterAfterSustainedSpeedAndIdle() {
        var policy = AutoRecenterPolicy()
        let touched = Date(timeIntervalSince1970: 0)
        // 0～4 秒：速度夠但還沒持續 5 秒
        for t in 0..<5 {
            XCTAssertFalse(policy.shouldRecenter(fix: fix(Double(t), kmh: 30), isFollowing: false, lastInteraction: touched))
        }
        // 5～9 秒：持續夠久，但距離最後一次碰地圖還不到 10 秒
        for t in 5..<10 {
            XCTAssertFalse(policy.shouldRecenter(fix: fix(Double(t), kmh: 30), isFollowing: false, lastInteraction: touched))
        }
        XCTAssertTrue(policy.shouldRecenter(fix: fix(10, kmh: 30), isFollowing: false, lastInteraction: touched))
    }

    func testNoRecenterWhenSlowOrBadGPSOrAlreadyFollowing() {
        var policy = AutoRecenterPolicy()
        for t in 0..<30 {
            // 走路的速度
            XCTAssertFalse(policy.shouldRecenter(fix: fix(Double(t), kmh: 6), isFollowing: false, lastInteraction: nil))
        }
        for t in 30..<60 {
            // 地下捷運、隧道：GPS 精度很差
            XCTAssertFalse(policy.shouldRecenter(fix: fix(Double(t), kmh: 60, accuracy: 120), isFollowing: false,
                                                 lastInteraction: nil))
        }
        for t in 60..<90 {
            XCTAssertFalse(policy.shouldRecenter(fix: fix(Double(t), kmh: 60), isFollowing: true, lastInteraction: nil))
        }
    }

    func testSpeedDropResetsTheSustainTimer() {
        var policy = AutoRecenterPolicy()
        for t in 0..<4 {
            _ = policy.shouldRecenter(fix: fix(Double(t), kmh: 30), isFollowing: false, lastInteraction: nil)
        }
        XCTAssertFalse(policy.shouldRecenter(fix: fix(4, kmh: 3), isFollowing: false, lastInteraction: nil))
        for t in 5..<10 {
            XCTAssertFalse(policy.shouldRecenter(fix: fix(Double(t), kmh: 30), isFollowing: false, lastInteraction: nil))
        }
        XCTAssertTrue(policy.shouldRecenter(fix: fix(10, kmh: 30), isFollowing: false, lastInteraction: nil))
    }
}
