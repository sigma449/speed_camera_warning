import XCTest
@testable import SpeedCamCore

final class CameraAlertEngineTests: XCTestCase {

    /// 在起點正北方 distance 公尺處放一支照相機。
    private func camera(_ id: String = "cam", north distance: Double, heading: Double? = 0,
                        limit: Int? = 50, type: CameraType = .fixed) -> Camera {
        let p = GeoMath.destination(from: origin, bearing: 0, distance: distance)
        return Camera(id: id, type: type, lat: p.lat, lon: p.lon, heading: heading, speedLimit: limit, address: "測試路")
    }

    private func engine(_ cams: [Camera], settings: AlertSettings = AlertSettings()) -> CameraAlertEngine {
        CameraAlertEngine(index: SpatialIndex(cameras: cams), settings: settings)
    }

    func testGeneralRoadAlertsOncePerStageAndPasses() {
        let cam = camera(north: 2_000, limit: 50)
        let events = runAlerts(engine([cam]), straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 200))
        let pres = events.filter { $0.event.isPre }
        let nears = events.filter { $0.event.isNear }
        XCTAssertEqual(pres.count, 1)
        XCTAssertEqual(nears.count, 1)
        XCTAssertEqual(events.filter { $0.event.isPassed }.count, 1)
        XCTAssertEqual(pres[0].event.distance!, 300, accuracy: 15, "一般道路應在約 300 m 預告")
        XCTAssertEqual(nears[0].event.distance!, 100, accuracy: 15, "一般道路應在約 100 m 近距提醒")
        XCTAssertTrue(pres[0].time < nears[0].time)
        // 以速限內行駛，不應有超速事件
        XCTAssertFalse(events.contains { $0.event.isOverspeedStarted || $0.event.isBeep })
    }

    func testFastRoadUsesLongerThresholds() {
        let cam = camera(north: 3_000, limit: 100)
        let events = runAlerts(engine([cam]), straightTrack(from: origin, bearing: 0, speedKmh: 90, seconds: 140))
        let pre = events.first { $0.event.isPre }!
        let near = events.first { $0.event.isNear }!
        XCTAssertEqual(pre.event.distance!, 600, accuracy: 30)
        XCTAssertEqual(near.event.distance!, 200, accuracy: 30)
    }

    func testMissingLimitFallsBackToCurrentSpeed() {
        let fast = runAlerts(engine([camera(north: 3_000, limit: nil)]),
                             straightTrack(from: origin, bearing: 0, speedKmh: 90, seconds: 140))
        XCTAssertEqual(fast.first { $0.event.isPre }!.event.distance!, 600, accuracy: 30)

        let slow = runAlerts(engine([camera(north: 2_000, limit: nil)]),
                             straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 160))
        XCTAssertEqual(slow.first { $0.event.isPre }!.event.distance!, 300, accuracy: 15)
    }

    func testOppositeDirectionCameraIsIgnored() {
        let cam = camera(north: 1_000, heading: 180)
        let events = runAlerts(engine([cam]), straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 100))
        XCTAssertTrue(events.isEmpty, "取締南向車輛的照相，北上時不應提醒：\(events.map { $0.event })")
    }

    func testCameraBehindIsIgnored() {
        let p = GeoMath.destination(from: origin, bearing: 180, distance: 200)
        let cam = Camera(id: "behind", type: .fixed, lat: p.lat, lon: p.lon, heading: nil, speedLimit: 50)
        let events = runAlerts(engine([cam]), straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 60))
        XCTAssertTrue(events.isEmpty)
    }

    func testCameraWithoutHeadingAheadIsAlerted() {
        let cam = camera(north: 800, heading: nil)
        let events = runAlerts(engine([cam]), straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 80))
        XCTAssertEqual(events.filter { $0.event.isPre }.count, 1)
        XCTAssertEqual(events.filter { $0.event.isNear }.count, 1)
    }

    func testSlightlyCurvedRoadStillMatchesDirection() {
        // 照相取締方向 30°，車輛以 10° 前進（夾角 20°，在容許的 45° 內）
        let p = GeoMath.destination(from: origin, bearing: 10, distance: 900)
        let cam = Camera(id: "curve", type: .fixed, lat: p.lat, lon: p.lon, heading: 30, speedLimit: 60)
        let events = runAlerts(engine([cam]), straightTrack(from: origin, bearing: 10, speedKmh: 60, seconds: 70))
        XCTAssertEqual(events.filter { $0.event.isPre }.count, 1)
    }

    func testOverspeedBeepsEveryThreeSecondsUntilPassed() {
        let cam = camera(north: 1_000, limit: 50)
        let events = runAlerts(engine([cam]), straightTrack(from: origin, bearing: 0, speedKmh: 70, seconds: 80))
        let started = events.filter { $0.event.isOverspeedStarted }
        let beeps = events.filter { $0.event.isBeep }
        XCTAssertEqual(started.count, 1)
        // 從 300 m 到通過約 15.4 秒 → 3、6、9、12、15 秒各一聲
        XCTAssertTrue((4...5).contains(beeps.count), "beeps=\(beeps.count)")
        var last = started[0].time
        for b in beeps {
            XCTAssertEqual(b.time - last, 3, accuracy: 0.01)
            last = b.time
        }
        XCTAssertEqual(events.filter { $0.event.isOverspeedEnded }.count, 1)
        let ended = events.first { $0.event.isOverspeedEnded }!
        let passed = events.first { $0.event.isPassed }!
        XCTAssertLessThanOrEqual(ended.time, passed.time)
    }

    func testSlowingDownStopsBeeping() {
        let cam = camera(north: 1_000, limit: 50)
        // 70 km/h 開 41 秒（約 797 m，離照相約 203 m），之後降到 40 km/h
        let fixes = segmentedTrack(from: origin, segments: [(0, 70, 41), (0, 40, 40)])
        let events = runAlerts(engine([cam]), fixes)
        let ended = events.first { $0.event.isOverspeedEnded }!
        XCTAssertFalse(events.contains { $0.event.isBeep && $0.time > ended.time })
        XCTAssertEqual(events.filter { $0.event.isOverspeedStarted }.count, 1)
    }

    func testToleranceSuppressesSmallOverspeed() {
        var s = AlertSettings()
        s.overspeedToleranceKmh = 10
        let events = runAlerts(engine([camera(north: 1_000, limit: 50)], settings: s),
                               straightTrack(from: origin, bearing: 0, speedKmh: 58, seconds: 80))
        XCTAssertFalse(events.contains { $0.event.isOverspeedStarted })
    }

    func testRedLightCameraHasNoOverspeedWarning() {
        let cam = camera(north: 1_000, limit: 50, type: .redLight)
        let events = runAlerts(engine([cam]), straightTrack(from: origin, bearing: 0, speedKmh: 80, seconds: 60))
        XCTAssertEqual(events.filter { $0.event.isPre }.count, 1)
        XCTAssertFalse(events.contains { $0.event.isOverspeedStarted })
    }

    func testFirstSeenInsideNearZoneSkipsPreAlert() {
        let cam = camera(north: 80)
        let events = runAlerts(engine([cam]), straightTrack(from: origin, bearing: 0, speedKmh: 40, seconds: 20))
        XCTAssertEqual(events.filter { $0.event.isPre }.count, 0)
        XCTAssertEqual(events.filter { $0.event.isNear }.count, 1)
    }

    func testTwoCamerasInSeriesBothAlertedNoRepeat() {
        let cams = [camera("first", north: 600), camera("second", north: 1_600)]
        let events = runAlerts(engine(cams), straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 160))
        func ids(_ pred: (CameraAlertEvent) -> Bool) -> [String] {
            events.compactMap { e -> String? in
                guard pred(e.event) else { return nil }
                switch e.event {
                case let .preAlert(c, _), let .nearAlert(c, _), let .passed(c): return c.id
                default: return nil
                }
            }
        }
        XCTAssertEqual(ids { $0.isPre }, ["first", "second"])
        XCTAssertEqual(ids { $0.isNear }, ["first", "second"])
        XCTAssertEqual(ids { $0.isPassed }, ["first", "second"])
    }

    func testTargetReportsCountdownDistance() {
        let cam = camera(north: 500)
        let e = engine([cam])
        let fixes = straightTrack(from: origin, bearing: 0, speedKmh: 36, seconds: 30)  // 10 m/s
        var distances: [Double] = []
        for f in fixes {
            if let t = e.process(f).target { distances.append(t.distance) }
        }
        XCTAssertFalse(distances.isEmpty)
        // 距離應單調遞減（持續倒數）
        XCTAssertEqual(distances, distances.sorted(by: >))
    }

    func testNoCourseNoAlerts() {
        let cam = camera(north: 200)
        let e = engine([cam])
        let fix = VehicleFix(point: origin, speedMps: 0, course: nil, timestamp: t0)
        XCTAssertTrue(e.process(fix).events.isEmpty)
    }

    func testGPXReplay() throws {
        // north_drive.gpx：從 origin 以 50 km/h 往北開 120 秒
        let fixes = try GPXReplay.load(named: "north_drive")
        XCTAssertGreaterThan(fixes.count, 100)
        let cam = camera(north: 1_000, limit: 40)
        let events = runAlerts(engine([cam]), fixes)
        XCTAssertEqual(events.filter { $0.event.isPre }.count, 1)
        XCTAssertEqual(events.filter { $0.event.isNear }.count, 1)
        XCTAssertEqual(events.filter { $0.event.isPassed }.count, 1)
        XCTAssertEqual(events.filter { $0.event.isOverspeedStarted }.count, 1, "50 km/h 經過速限 40 的照相應該超速")
    }
}
