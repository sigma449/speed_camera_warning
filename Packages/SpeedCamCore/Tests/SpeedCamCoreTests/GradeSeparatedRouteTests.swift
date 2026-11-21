import XCTest
@testable import SpeedCamCore

/// 導航走在高架上時，略過正下方平面路口的非測速提醒（2026-11-22 建國高架實測）。
final class GradeSeparatedRouteTests: XCTestCase {
    private let origin = GeoPoint(lat: 25.05, lon: 121.537)

    private func point(north: Double, east: Double = 0) -> GeoPoint {
        let lat = origin.lat + north / 111_195
        let lon = origin.lon + east / (111_195 * cos(origin.lat * .pi / 180))
        return GeoPoint(lat: lat, lon: lon)
    }

    /// 一直往北的路線：0–500 m 平面接近、500–2,500 m 高架、2,500–3,000 m 平面。
    private var polyline: [GeoPoint] { stride(from: 0.0, through: 3_000, by: 100).map { point(north: $0) } }

    /// 高架主線線形（只有 500–2,500 m 那段；偏 3 m 模擬 OSM 和 Apple 的差距）。
    private func roads(east: Double = 3) -> RoadMatcher {
        RoadMatcher(lines: [stride(from: 500.0, through: 2_500, by: 100).map { point(north: $0, east: east) }])
    }

    private func steps(entry: String = "靠左行駛上建國南北快速道路，朝景美、木柵前進",
                       middle: String = "靠右，下交流道往辛亥路") -> [RouteStepInfo] {
        [RouteStepInfo(instruction: entry, distance: 500),
         RouteStepInfo(instruction: middle, distance: 2_000),
         RouteStepInfo(instruction: "抵達目的地", distance: 500)]
    }

    private func camera(_ id: String, north: Double, east: Double = 0, type: CameraType = .tech,
                        items: String? = "闖紅燈、不停讓行人", limit: Int? = nil,
                        address: String = "南京東路與建國北路口", level: RoadLevel? = nil) -> Camera {
        let p = point(north: north, east: east)
        return Camera(id: id, type: type, lat: p.lat, lon: p.lon, speedLimit: limit, address: address,
                      level: level, enforcementItems: type == .tech ? items : nil)
    }

    func testSkipsSurfaceNonSpeedCamerasOnlyWhileOnElevatedStep() {
        let cameras = [
            camera("tech", north: 1_000),
            camera("redLight", north: 1_500, east: 12, type: .redLight),
            camera("noise", north: 1_800, type: .noise, address: "大安區建國南路2段125號旁"),
            camera("surfaceSpeed", north: 1_200, type: .fixed, limit: 50, address: "建國南路2段179號前", level: .surface),
            camera("techSpeed", north: 1_300, items: "超速、闖紅燈", limit: 50),
            camera("techOnElevated", north: 1_400, items: "逾10噸大貨車違規行駛", address: "建國高架道路(市民大道上方)"),
            camera("levelElevated", north: 1_600, type: .redLight, level: .elevated),
            camera("mobile", north: 1_700, type: .mobile, address: "建國南路2段"),
            camera("sideStreet", north: 1_900, east: 120),
            camera("beforeRamp", north: 300),
            camera("afterExit", north: 2_800),
        ]
        let route = GradeSeparatedRoute(polyline: polyline, steps: steps(), roads: roads(),
                                        cameras: SpatialIndex(cameras: cameras))
        XCTAssertEqual(route.segments.count, 1)
        XCTAssertEqual(route.segments.first?.start ?? 0, 500, accuracy: 1)
        XCTAssertEqual(route.segments.first?.end ?? 0, 2_500, accuracy: 1)
        XCTAssertEqual(route.suppressedCameraIDs(along: 1_000), ["tech", "redLight", "noise"])
        XCTAssertEqual(route.suppressedCameraIDs(along: 300), [])
        XCTAssertEqual(route.suppressedCameraIDs(along: 2_700), [])
        XCTAssertEqual(route.suppressedCameraIDs(along: .nan), [])
    }

    func testNeedsBothEntryInstructionAndElevatedGeometry() {
        let cameras = SpatialIndex(cameras: [camera("tech", north: 1_000)])
        // 走在高架正下方的平面道路：座標一樣，但 Apple 沒說「上」高架。
        let surface = GradeSeparatedRoute(polyline: polyline, steps: steps(entry: "右轉進入建國北路"),
                                          roads: roads(), cameras: cameras)
        XCTAssertTrue(surface.segments.isEmpty)
        // 只是方向說明，不是上高架。
        let towards = GradeSeparatedRoute(polyline: polyline,
                                          steps: steps(entry: "右轉進入八德路，朝市民大道高架道路前進"),
                                          roads: roads(), cameras: cameras)
        XCTAssertTrue(towards.segments.isEmpty)
        // 指示說上快速道路，但路形不在內建主線上（例如資料沒有這條路）。
        let elsewhere = GradeSeparatedRoute(polyline: polyline, steps: steps(), roads: roads(east: 200),
                                            cameras: cameras)
        XCTAssertTrue(elsewhere.segments.isEmpty)
        // 線形載入失敗。
        let noData = GradeSeparatedRoute(polyline: polyline, steps: steps(), roads: RoadMatcher(lines: []),
                                         cameras: cameras)
        XCTAssertTrue(noData.segments.isEmpty)
    }

    func testStaysOnTopUntilExitOrTurn() {
        let line = RoadMatcher(lines: [stride(from: 500.0, through: 3_000, by: 100).map { point(north: $0, east: 3) }])
        let cameras = SpatialIndex(cameras: [camera("late", north: 2_800)])
        // 中途「靠左行駛」仍在高架上：下一步接著算。
        let keepLeft = GradeSeparatedRoute(polyline: polyline, steps: steps(middle: "靠左行駛"),
                                           roads: line, cameras: cameras)
        XCTAssertEqual(keepLeft.segments.count, 1)
        XCTAssertEqual(keepLeft.segments.first?.end ?? 0, 3_000, accuracy: 1)
        XCTAssertEqual(keepLeft.suppressedCameraIDs(along: 2_700), ["late"])
        // 下交流道之後就算路形還疊著，也不再沿用。
        let exit = GradeSeparatedRoute(polyline: polyline, steps: steps(), roads: line, cameras: cameras)
        XCTAssertEqual(exit.suppressedCameraIDs(along: 2_700), [])
        let turn = GradeSeparatedRoute(polyline: polyline, steps: steps(middle: "右轉進入辛亥路"),
                                       roads: line, cameras: cameras)
        XCTAssertEqual(turn.suppressedCameraIDs(along: 2_700), [])
    }

    func testEntryInstructionPatterns() {
        for text in ["靠左行駛上建國南北快速道路，朝景美、木柵前進", "靠右，上市民大道高架道路", "上交流道往國道1號",
                     "左轉上高速公路", "左轉上水源快速道路，朝(永和)、景美前進"] {
            XCTAssertTrue(GradeSeparatedRoute.isEntry(text), text)
        }
        for text in ["右轉進入建國北路", "右轉進入八德路，朝市民大道高架道路前進", "靠左，朝上塔悠、市民大道高架道路前進",
                     "靠右，下交流道往辛亥路", "Take the ramp onto Jianguo Expressway"] {
            XCTAssertFalse(GradeSeparatedRoute.isEntry(text), text)
        }
    }

    func testEngineSkipsSuppressedCameraAndResumesAfterwards() {
        let cam = camera("tech", north: 250)
        let engine = CameraAlertEngine(index: SpatialIndex(cameras: [cam]))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        engine.suppressedCameraIDs = ["tech"]
        let skipped = engine.process(VehicleFix(point: origin, speedMps: 50 / 3.6, course: 0, timestamp: t0))
        XCTAssertTrue(skipped.events.isEmpty)
        XCTAssertNil(skipped.target)
        // 下了高架仍在前方：照常提醒（沒有被記成已通過）。
        engine.suppressedCameraIDs = []
        let resumed = engine.process(VehicleFix(point: point(north: 20), speedMps: 50 / 3.6, course: 0,
                                                timestamp: t0.addingTimeInterval(1.5)))
        XCTAssertFalse(resumed.events.isEmpty)
        XCTAssertEqual(resumed.target?.camera.id, "tech")
        // 已追蹤中才進入高架：直接放掉，不發通過。
        engine.suppressedCameraIDs = ["tech"]
        let dropped = engine.process(VehicleFix(point: point(north: 40), speedMps: 50 / 3.6, course: 0,
                                                timestamp: t0.addingTimeInterval(3)))
        XCTAssertNil(dropped.target)
        XCTAssertFalse(dropped.events.contains { if case .passed = $0 { return true } else { return false } })
    }

    func testTechSpeechIsShort() {
        let tech = camera("t", north: 0, items: "闖紅燈、不停讓行人、不依規定轉彎、不依標誌標線號誌指示行駛")
        XCTAssertEqual(AnnouncementFormatter.cameraAlert(camera: tech, announcedDistance: 300), "前方300公尺，科技執法")
        let elevated = camera("e", north: 0, items: "逾10噸大貨車違規行駛", address: "建國高架道路(市民大道上方)",
                              level: .elevated)
        XCTAssertEqual(AnnouncementFormatter.cameraAlert(camera: elevated, announcedDistance: 100), "前方100公尺，高架科技執法")
        // 畫面仍保留完整類型與項目。
        XCTAssertEqual(tech.displayTypeName, "路口科技執法")
        XCTAssertEqual(tech.reminderDetail, "取締：闖紅燈、不停讓行人、不依規定轉彎、不依標誌標線號誌指示行駛")
    }
}
