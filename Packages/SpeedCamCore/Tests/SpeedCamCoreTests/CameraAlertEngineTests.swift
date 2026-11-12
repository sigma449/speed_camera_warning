import XCTest
@testable import SpeedCamCore

final class CameraAlertEngineTests: XCTestCase {

    func testYinheReportedCameraOnlyAlertsTowardXindianWithoutOverspeed() {
        let camera = Camera(id: "yinhe", type: .fixed, lat: 24.9555732, lon: 121.5698732,
                            heading: 240.6, speedLimit: nil, address: "北宜路過銀河社區（往新店）")
        for heading in [240.6, 60.6] {
            let start = GeoMath.destination(from: camera.point, bearing: heading + 180, distance: 400)
            let engine = CameraAlertEngine(index: SpatialIndex(cameras: [camera]))
            let events = runAlerts(engine, straightTrack(from: start, bearing: heading, speedKmh: 60, seconds: 45))
            XCTAssertEqual(events.contains { $0.event.isPre }, heading == 240.6)
            XCTAssertEqual(events.contains { $0.event.isNear }, heading == 240.6)
            XCTAssertFalse(events.contains { $0.event.isOverspeedStarted || $0.event.isBeep })
        }
    }

    /// 在起點正北方 distance 公尺處放一支照相機。
    private func camera(_ id: String = "cam", north distance: Double, heading: Double? = 0,
                        limit: Int? = 50, type: CameraType = .fixed, address: String = "測試路") -> Camera {
        let p = GeoMath.destination(from: origin, bearing: 0, distance: distance)
        return Camera(id: id, type: type, lat: p.lat, lon: p.lon, heading: heading, speedLimit: limit, address: address)
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

    func testCorrected279KDoesNotAlertInTaipei() {
        let camera = Camera(id: "13940-279", type: .fixed, lat: 23.373209, lon: 120.350715,
                            heading: 180, speedLimit: 110, address: "國道一號南向279公里")
        let track = straightTrack(from: GeoPoint(lat: 25.046651, lon: 121.536622),
                                  bearing: 181.6, speedKmh: 60, seconds: 100)
        XCTAssertTrue(runAlerts(engine([camera]), track).isEmpty)
    }

    func testCorrected279KAndRealYuanshanStillAlertSouthbound() {
        let cameras = [
            Camera(id: "279", type: .fixed, lat: 23.373209, lon: 120.350715,
                   heading: 180, speedLimit: 110, address: "國道一號南向279公里"),
            Camera(id: "22.7", type: .fixed, lat: 25.07305, lon: 121.536862,
                   heading: 180, speedLimit: 100, address: "國道一號南向22.7公里"),
        ]
        for camera in cameras {
            let before = GeoMath.destination(from: camera.point, bearing: 0, distance: 1_000)
            let events = runAlerts(engine([camera]), straightTrack(from: before, bearing: 180, speedKmh: 100, seconds: 60))
            XCTAssertEqual(events.filter { $0.event.isPre }.count, 1, camera.address)
            XCTAssertEqual(events.filter { $0.event.isNear }.count, 1, camera.address)
        }
    }

    func testOfficialSectionAssociationCoversZhongrenButNotParallelCamera() throws {
        let start = GeoMath.destination(from: origin, bearing: 0, distance: 200)
        let section = SpeedSection(id: "zhongren-tunnel-f", name: "中仁隧道", start: start,
            end: GeoMath.destination(from: start, bearing: 0, distance: 4_831), lengthMeters: 4_831, speedLimit: 70)
        let middle = GeoMath.destination(from: start, bearing: 0, distance: 2_000)
        let curved = GeoMath.destination(from: middle, bearing: 90, distance: 640)
        let linked = Camera(id: "zhongren", type: .section, lat: curved.lat, lon: curved.lon,
                            speedLimit: 70, address: "蘇花改中仁隧道", sectionGroupID: "zhongren-tunnel")
        let parallel = Camera(id: "parallel", type: .section, lat: curved.lat, lon: curved.lon,
                              speedLimit: 70, address: "旁邊沒有查核雙端的道路")
        let engine = engine([linked, parallel])
        engine.sections = [section]
        XCTAssertTrue(engine.isCoveredBySection(linked))
        XCTAssertFalse(engine.isCoveredBySection(parallel))
        XCTAssertEqual(try JSONDecoder().decode(Camera.self, from: JSONEncoder().encode(linked)).sectionGroupID,
                       "zhongren-tunnel")
        engine.sections = []
        XCTAssertFalse(engine.isCoveredBySection(linked), "關聯的區間真的存在時才可取代固定提醒")
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

    func testAxisCameraAlertsBothDirectionsOnItsRoad() {
        // 南北雙向的照相：往北、往南經過都要提醒
        let north = GeoMath.destination(from: origin, bearing: 0, distance: 800)
        let cam = Camera(id: "axis", type: .fixed, lat: north.lat, lon: north.lon, speedLimit: 50, axis: 0)
        let up = runAlerts(engine([cam]), straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 80))
        XCTAssertEqual(up.filter { $0.event.isPre }.count, 1)

        let farNorth = GeoMath.destination(from: origin, bearing: 0, distance: 1_600)
        let down = runAlerts(engine([cam]), straightTrack(from: farNorth, bearing: 180, speedKmh: 50, seconds: 80))
        XCTAssertEqual(down.filter { $0.event.isPre }.count, 1)
    }

    func testAxisCameraIgnoresCrossRoadTraffic() {
        // 南北雙向的照相位於東邊路口；車輛沿東西向道路往東開，照相在正前方但不該提醒
        let east = GeoMath.destination(from: origin, bearing: 90, distance: 800)
        let cam = Camera(id: "cross", type: .fixed, lat: east.lat, lon: east.lon, speedLimit: 50, axis: 0)
        let events = runAlerts(engine([cam]), straightTrack(from: origin, bearing: 90, speedKmh: 50, seconds: 80))
        XCTAssertTrue(events.isEmpty, "橫向道路不應提醒：\(events.map { $0.event })")

        // 同樣位置但沒有軸向資料：沿用「在前方就提醒」
        let unknown = Camera(id: "unknown", type: .fixed, lat: east.lat, lon: east.lon, speedLimit: 50)
        let events2 = runAlerts(engine([unknown]), straightTrack(from: origin, bearing: 90, speedKmh: 50, seconds: 80))
        XCTAssertEqual(events2.filter { $0.event.isPre }.count, 1)
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

    func testSectionCameraUsesSectionTolerance() {
        var settings = AlertSettings()
        settings.sectionToleranceKmh = 10
        let cam = camera(north: 1_000, limit: 40, type: .section)
        // 48 km/h：超過 40 但在 50 以內 → 不嗶
        let ok = runAlerts(engine([cam], settings: settings), straightTrack(from: origin, bearing: 0, speedKmh: 48, seconds: 90))
        XCTAssertEqual(ok.filter { $0.event.isPre }.count, 1)
        XCTAssertFalse(ok.contains { $0.event.isOverspeedStarted })
        // 55 km/h：超過 50 → 嗶
        let over = runAlerts(engine([cam], settings: settings), straightTrack(from: origin, bearing: 0, speedKmh: 55, seconds: 90))
        XCTAssertEqual(over.filter { $0.event.isOverspeedStarted }.count, 1)
        // 一般測速照相不受區間容許值影響：48 km/h 經過速限 40 的固定測速 → 嗶
        let fixed = runAlerts(engine([camera(north: 1_000, limit: 40)], settings: settings),
                              straightTrack(from: origin, bearing: 0, speedKmh: 48, seconds: 90))
        XCTAssertEqual(fixed.filter { $0.event.isOverspeedStarted }.count, 1)
    }

    /// 區間照相機在區間路線上：由 SectionSpeedTracker 預告和倒數，這裡不再當成一支固定照相提醒。
    /// 否則自強隧道中段那支會在隧道裡才跳出來，也會和倒數重複。
    func testSectionCameraOnKnownSectionIsNotAlertedAsFixedCamera() {
        let cam = camera(north: 1_000, limit: 50, type: .section)
        let start = GeoMath.destination(from: origin, bearing: 0, distance: 600)
        let end = GeoMath.destination(from: origin, bearing: 0, distance: 1_500)
        let sec = SpeedSection(id: "tunnel-f", name: "隧道（往北）", start: start, end: end,
                               lengthMeters: 900, speedLimit: 50)
        let covered = engine([cam])
        covered.sections = [sec]
        XCTAssertTrue(covered.isCoveredBySection(cam))
        XCTAssertTrue(runAlerts(covered, straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 120)).isEmpty)

        // 沒有對應區間的區間照相機（資料解析不了的那些）仍然要提醒
        let alone = engine([cam])
        let events = runAlerts(alone, straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 120))
        XCTAssertEqual(events.filter { $0.event.isPre }.count, 1)

        // 一般照相不受影響
        let fixed = camera("fixed", north: 1_000, limit: 50)
        let withFixed = engine([fixed])
        withFixed.sections = [sec]
        XCTAssertFalse(withFixed.isCoveredBySection(fixed))
        XCTAssertEqual(runAlerts(withFixed, straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 120))
            .filter { $0.event.isPre }.count, 1)
    }

    func testNearAlertSaysWhetherPreAlertWasGiven() {
        // 正常接近：預告過了
        let normal = runAlerts(engine([camera(north: 1_000)]), straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 90))
        guard case let .nearAlert(_, _, afterPre)? = normal.first(where: { $0.event.isNear })?.event else { return XCTFail() }
        XCTAssertTrue(afterPre)
        // 第一次看到就在近距內：沒有預告過，語音要念完整的句子
        let sudden = runAlerts(engine([camera(north: 80)]), straightTrack(from: origin, bearing: 0, speedKmh: 40, seconds: 20))
        guard case let .nearAlert(_, _, afterPre2)? = sudden.first(where: { $0.event.isNear })?.event else { return XCTFail() }
        XCTAssertFalse(afterPre2)
    }

    func testSectionCameraUsesNearbySectionOverride() {
        // 照相機在區間起點外 400 m（超過 300 m 的範圍，不算在區間路線上），但還是套用那一段的容許值
        let cam = camera(north: 1_000, limit: 40, type: .section)
        let start = GeoMath.destination(from: cam.point, bearing: 0, distance: 400)
        let end = GeoMath.destination(from: start, bearing: 0, distance: 4_000)
        let sec = SpeedSection(id: "s9-f", name: "測試（往北）", start: start, end: end,
                               lengthMeters: 4_000, speedLimit: 40)
        var settings = AlertSettings()      // 預設 +10 → 門檻 50
        let e1 = engine([cam], settings: settings)
        e1.sections = [sec]
        let beepDefault = runAlerts(e1, straightTrack(from: origin, bearing: 0, speedKmh: 55, seconds: 90))
        XCTAssertEqual(beepDefault.filter { $0.event.isOverspeedStarted }.count, 1)

        settings.sectionToleranceOverrides = ["s9": 20]   // 這段 +20 → 門檻 60
        let e2 = engine([cam], settings: settings)
        e2.sections = [sec]
        let quiet = runAlerts(e2, straightTrack(from: origin, bearing: 0, speedKmh: 55, seconds: 90))
        XCTAssertFalse(quiet.contains { $0.event.isOverspeedStarted })
        XCTAssertEqual(e2.nearbySectionGroup(for: cam), "s9")
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
                case let .preAlert(c, _), let .nearAlert(c, _, _), let .passed(c): return c.id
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

    // MARK: - 沒有定位（隧道）

    /// 往北開 fixSeconds 秒之後定位中斷，之後每秒只呼叫 tick（App 在隧道裡做的事）。
    private func runWithGap(_ e: CameraAlertEngine, speedKmh: Double, fixSeconds: Int,
                            gapSeconds: Int) -> [TimedEvent<CameraAlertEvent>] {
        var out = runAlerts(e, straightTrack(from: origin, bearing: 0, speedKmh: speedKmh, seconds: fixSeconds))
        for s in 1...gapSeconds {
            let now = t0.addingTimeInterval(Double(fixSeconds + s))
            for event in e.tick(now: now)?.events ?? [] {
                out.append(TimedEvent(time: now.timeIntervalSince(t0), event: event))
            }
        }
        return out
    }

    /// 定位回來時的一筆定位：在起點正北方 distance 公尺。
    private func fix(north distance: Double, speedKmh: Double = 50, at seconds: Int) -> VehicleFix {
        VehicleFix(point: GeoMath.destination(from: origin, bearing: 0, distance: distance),
                   speedMps: SpeedUnit.mps(fromKmh: speedKmh), course: 0, horizontalAccuracy: 5,
                   timestamp: t0.addingTimeInterval(Double(seconds)))
    }

    func testNoFixKeepsAlertingByTime() {
        // 開 10 秒（139 m）進隧道，照相點在隧道裡，還沒進預告距離
        let events = runWithGap(engine([camera(north: 1_000, limit: 50)]), speedKmh: 50, fixSeconds: 10, gapSeconds: 60)
        let pres = events.filter { $0.event.isPre }
        let nears = events.filter { $0.event.isNear }
        XCTAssertEqual(pres.count, 1)
        XCTAssertEqual(nears.count, 1)
        XCTAssertEqual(pres[0].event.distance!, 300, accuracy: 15)
        XCTAssertEqual(nears[0].event.distance!, 100, accuracy: 15)
        XCTAssertEqual(pres[0].time, (1_000 - 300) / SpeedUnit.mps(fromKmh: 50), accuracy: 1.5, "時間要和車速相符")
        guard case let .nearAlert(_, _, afterPre)? = nears.first?.event else { return XCTFail() }
        XCTAssertTrue(afterPre, "預告過了，近距只念距離")
        XCTAssertFalse(events.contains { $0.event.isPassed }, "沒有定位不能說已經通過")
    }

    func testNoFixTargetCountsDownThenDisappears() {
        let e = engine([camera(north: 500)])
        _ = runAlerts(e, straightTrack(from: origin, bearing: 0, speedKmh: 36, seconds: 10))   // 10 m/s，開了 100 m
        var distances: [Double] = []
        for s in 3...39 {
            if let t = e.tick(now: t0.addingTimeInterval(Double(10 + s)))?.target { distances.append(t.distance) }
        }
        XCTAssertEqual(distances, distances.sorted(by: >))
        XCTAssertEqual(distances.first ?? 0, 370, accuracy: 2)
        XCTAssertNil(e.tick(now: t0.addingTimeInterval(55))?.target, "推算已經過了，畫面不再顯示這支")
    }

    func testTickDoesNothingWhileFixesAreFresh() {
        let e = engine([camera(north: 1_000)])
        _ = runAlerts(e, straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 10))
        XCTAssertNil(e.tick(now: t0.addingTimeInterval(11)))
        XCTAssertNil(e.tick(now: t0.addingTimeInterval(12.4)))
        XCTAssertNotNil(e.tick(now: t0.addingTimeInterval(12.5)))
    }

    func testNoFixAtLowSpeedIsNotEstimated() {
        // 開進停車場之類的情況，不是隧道
        let e = engine([camera(north: 400)])
        _ = runAlerts(e, straightTrack(from: origin, bearing: 0, speedKmh: 15, seconds: 5))
        XCTAssertNil(e.tick(now: t0.addingTimeInterval(60)))
    }

    func testFixReturningPastCameraCountsAsPassedOnce() {
        let e = engine([camera(north: 500)])
        let before = runWithGap(e, speedKmh: 50, fixSeconds: 5, gapSeconds: 35)
        XCTAssertEqual(before.filter { $0.event.isPre }.count, 1)
        XCTAssertEqual(before.filter { $0.event.isNear }.count, 1)
        XCTAssertFalse(before.contains { $0.event.isPassed })

        // 出隧道：已經過了照相點一段距離
        let back = e.process(fix(north: 600, at: 41))
        XCTAssertEqual(back.events.filter { $0.isPassed }.count, 1)
        XCTAssertNil(back.target)
        XCTAssertTrue(e.process(fix(north: 614, at: 42)).events.isEmpty, "不重複提醒")
    }

    func testFixReturningBeforeCameraContinuesWithoutRepeating() {
        // 隧道裡塞車：推算已經快到了，定位回來時其實還有 200 m
        let e = engine([camera(north: 1_000)])
        let before = runWithGap(e, speedKmh: 50, fixSeconds: 10, gapSeconds: 60)
        XCTAssertEqual(before.filter { $0.event.isNear }.count, 1)
        var after: [CameraAlertEvent] = []
        for (i, meters) in stride(from: 800.0, through: 1_100, by: 14).enumerated() {
            after += e.process(fix(north: meters, at: 71 + i)).events
        }
        XCTAssertFalse(after.contains { $0.isPre || $0.isNear })
        XCTAssertEqual(after.filter { $0.isPassed }.count, 1, "真的經過時才算通過")
    }

    func testNoFixFindsTunnelCamerasBeyondSearchRadius() {
        // 長隧道：照相點在定位中斷時還很遠，要靠地址知道它在隧道裡
        let inTunnel = camera(north: 5_000, limit: 90, address: "國道五號南向19.7公里(雪山隧道科技執法)")
        let events = runWithGap(engine([inTunnel]), speedKmh: 80, fixSeconds: 5, gapSeconds: 230)
        XCTAssertEqual(events.filter { $0.event.isPre }.count, 1)
        XCTAssertEqual(events.first { $0.event.isPre }?.event.distance ?? 0, 600, accuracy: 30)
        XCTAssertEqual(events.filter { $0.event.isNear }.count, 1)

        // 地址沒有隧道的不推這麼遠（例如搭捷運進地下）
        let onStreet = camera(north: 5_000, limit: 50)
        XCTAssertTrue(runWithGap(engine([onStreet]), speedKmh: 80, fixSeconds: 5, gapSeconds: 230).isEmpty)
        let nearby = camera(north: 1_400, limit: 50)
        XCTAssertEqual(runWithGap(engine([nearby]), speedKmh: 80, fixSeconds: 5, gapSeconds: 60)
            .filter { $0.event.isPre }.count, 1, "隧道出口附近的照相點地址不一定寫隧道")
    }

    func testNoFixCamerasInSeriesAlertInOrderAndPassOnce() {
        let cams = [1_000.0, 2_400, 3_800].enumerated().map { i, meters in
            camera("c\(i)", north: meters, limit: 90, address: "雪山隧道")
        }
        let e = engine(cams)
        let events = runWithGap(e, speedKmh: 80, fixSeconds: 2, gapSeconds: 175)
        let ids = events.compactMap { event -> String? in
            if case let .preAlert(c, _) = event.event { return c.id }
            return nil
        }
        XCTAssertEqual(ids, ["c0", "c1", "c2"])
        XCTAssertEqual(events.filter { $0.event.isNear }.count, 3)
        // 出隧道：前面幾支已經不追蹤，不會一次響三聲
        let back = e.process(fix(north: 3_900, speedKmh: 80, at: 178))
        XCTAssertEqual(back.events.filter { $0.isPassed }.count, 1)
    }

    func testNoFixIgnoresOppositeDirection() {
        let opposite = camera(north: 800, heading: 180)
        XCTAssertTrue(runWithGap(engine([opposite]), speedKmh: 50, fixSeconds: 5, gapSeconds: 60).isEmpty)
        let otherTube = camera(north: 800, heading: 180, address: "國道五號南向19.7公里(雪山隧道科技執法)")
        XCTAssertTrue(runWithGap(engine([otherTube]), speedKmh: 50, fixSeconds: 5, gapSeconds: 60).isEmpty, "對向管道")
    }

    func testNoFixIgnoresCameraOnParallelRoad() {
        // 右前方 50°：開到定位中斷時已經在追蹤，但有定位時距離不會縮到預告範圍，不能因為推算而提醒
        let p = GeoMath.destination(from: origin, bearing: 50, distance: 600)
        let side = Camera(id: "side", type: .fixed, lat: p.lat, lon: p.lon, heading: 0, speedLimit: 50, address: "宜3線3k+850m宜三路")
        XCTAssertTrue(runWithGap(engine([side]), speedKmh: 50, fixSeconds: 2, gapSeconds: 60).isEmpty)
    }

    func testNoFixAllowsTunnelCameraWithDifferentHeading() {
        // 隧道有弧度，資料的方向只有八方位：萬里隧道往照相點的方向和取締方向差 77°
        let curved = camera(north: 900, heading: 77, address: "台2線48.3公里萬里隧道出口處（往基隆）")
        XCTAssertEqual(runWithGap(engine([curved]), speedKmh: 50, fixSeconds: 5, gapSeconds: 60)
            .filter { $0.event.isPre }.count, 1)
    }

    func testNoFixSkipsSectionCameraOnKnownSection() {
        let cam = camera(north: 1_000, limit: 50, type: .section, address: "自強隧道區間測速")
        let start = GeoMath.destination(from: origin, bearing: 0, distance: 600)
        let end = GeoMath.destination(from: origin, bearing: 0, distance: 1_500)
        let e = engine([cam])
        e.sections = [SpeedSection(id: "s-f", name: "測試", start: start, end: end, lengthMeters: 900, speedLimit: 50)]
        XCTAssertTrue(runWithGap(e, speedKmh: 50, fixSeconds: 5, gapSeconds: 60).isEmpty, "由區間的預告和倒數處理")
    }

    func testNoFixStopsBeepingBecauseSpeedIsStale() {
        let e = engine([camera(north: 1_500, limit: 50)])
        let before = runAlerts(e, straightTrack(from: origin, bearing: 0, speedKmh: 70, seconds: 64))
        XCTAssertEqual(before.filter { $0.event.isOverspeedStarted }.count, 1)

        var after: [CameraAlertEvent] = []
        for s in 1...9 { after += e.tick(now: t0.addingTimeInterval(Double(64 + s)))?.events ?? [] }
        XCTAssertFalse(after.contains { $0.isBeep || $0.isOverspeedEnded }, "短暫沒有定位不算結束，但也不嗶")

        let later = e.tick(now: t0.addingTimeInterval(74))
        XCTAssertEqual(later?.events.filter { $0.isOverspeedEnded }.count, 1)
        XCTAssertEqual(later?.target?.isOverspeed, false)
    }

    func testResetForgetsLastFix() {
        let e = engine([camera(north: 1_000)])
        _ = runAlerts(e, straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 5))
        e.reset()
        XCTAssertNil(e.lastFix)
        XCTAssertNil(e.tick(now: t0.addingTimeInterval(60)))
    }

    func testCellTowerFixIsNotReliable() {
        func make(speed: Double, accuracy: Double) -> VehicleFix {
            VehicleFix(point: origin, speedMps: speed, course: nil, horizontalAccuracy: accuracy, timestamp: t0)
        }
        XCTAssertTrue(make(speed: 14, accuracy: 5).isReliable)
        XCTAssertTrue(make(speed: 0, accuracy: 30).isReliable, "停紅燈")
        XCTAssertFalse(make(speed: 0, accuracy: 1_414).isReliable, "基地台定位")
        XCTAssertFalse(make(speed: -1, accuracy: 65).isReliable, "沒有車速，不是 GPS")
        XCTAssertFalse(make(speed: 14, accuracy: 0).isReliable, "iOS 回報精度無效")
    }
}
