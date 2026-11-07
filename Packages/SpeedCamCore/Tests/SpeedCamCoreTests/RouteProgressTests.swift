import XCTest
@testable import SpeedCamCore

final class RouteProgressTests: XCTestCase {

    /// L 型路線：先往北 1,500 m，再往東 800 m。
    /// MapKit 的步驟格式：第 0 步是起點（距離 0、沒有文字），之後每一步的指示是「這一步走完時」要做的動作。
    /// 實測的例子：距離 123 m「左轉進入鄭州路」、距離 982 m「右轉進入環河北路一段」。
    private func lRoute() -> RouteProgressTracker {
        let corner = GeoMath.destination(from: origin, bearing: 0, distance: 1_500)
        var poly: [GeoPoint] = []
        for i in 0...15 { poly.append(GeoMath.destination(from: origin, bearing: 0, distance: Double(i) * 100)) }
        for i in 1...8 { poly.append(GeoMath.destination(from: corner, bearing: 90, distance: Double(i) * 100)) }
        let steps = [
            RouteStepInfo(instruction: "", distance: 0),
            RouteStepInfo(instruction: "右轉進入忠孝東路", distance: 1_500),
            RouteStepInfo(instruction: "目的地在你的右邊", distance: 800),
        ]
        return RouteProgressTracker(polyline: poly, steps: steps)
    }

    func testAnnouncesTurnAt500And200AndNowThenArrives() {
        let tracker = lRoute()
        let fixes = segmentedTrack(from: origin, segments: [(0, 36, 150), (90, 36, 85)])  // 10 m/s
        let events = runRoute(tracker, fixes)

        let turnAnnouncements = events.compactMap { e -> Int?? in
            if case let .announce(idx, text, d) = e.event, idx == 1 {
                XCTAssertEqual(text, "右轉進入忠孝東路")
                return .some(d)
            }
            return nil
        }
        XCTAssertEqual(turnAnnouncements, [500, 200, nil])
        XCTAssertEqual(events.filter { $0.event == .arrived }.count, 1)
        XCTAssertFalse(events.contains { $0.event == .offRoute })

        // 500 m 的播報應在約 100 秒（開了 1,000 m）時
        let first = events.first { if case .announce(1, _, 500) = $0.event { return true }; return false }!
        XCTAssertEqual(first.time, 100, accuracy: 1.5)
    }

    func testProgressDistances() {
        let tracker = lRoute()
        let fix = VehicleFix(point: GeoMath.destination(from: origin, bearing: 0, distance: 1_000),
                             speedMps: 10, course: 0, timestamp: t0)
        let p = tracker.process(fix).progress!
        XCTAssertEqual(p.distanceToNextManeuver, 500, accuracy: 2)
        XCTAssertEqual(p.distanceRemaining, 1_300, accuracy: 2)
        XCTAssertEqual(p.nextInstruction, "右轉進入忠孝東路")
        XCTAssertEqual(p.distanceFromRoute, 0, accuracy: 1)
        XCTAssertFalse(p.isOffRoute)
    }

    /// 實測問題：右轉民生西路時顯示「右轉吉林路」，轉吉林路時顯示「左轉長春路」，轉長春路時顯示目的地。
    /// 每一步的指示要在開到這一步終點之前顯示，走完才換下一個。
    func testInstructionShownBeforeItsOwnManeuverPoint() {
        let c1 = GeoMath.destination(from: origin, bearing: 0, distance: 1_000)
        let c2 = GeoMath.destination(from: c1, bearing: 90, distance: 600)
        let c3 = GeoMath.destination(from: c2, bearing: 180, distance: 400)
        var poly: [GeoPoint] = []
        for i in 0...10 { poly.append(GeoMath.destination(from: origin, bearing: 0, distance: Double(i) * 100)) }
        for i in 1...6 { poly.append(GeoMath.destination(from: c1, bearing: 90, distance: Double(i) * 100)) }
        for i in 1...4 { poly.append(GeoMath.destination(from: c2, bearing: 180, distance: Double(i) * 100)) }
        for i in 1...3 { poly.append(GeoMath.destination(from: c3, bearing: 90, distance: Double(i) * 100)) }
        let steps = [
            RouteStepInfo(instruction: "", distance: 0),
            RouteStepInfo(instruction: "右轉進入民生西路", distance: 1_000),
            RouteStepInfo(instruction: "右轉進入吉林路", distance: 600),
            RouteStepInfo(instruction: "左轉進入長春路", distance: 400),
            RouteStepInfo(instruction: "目的地在你的右邊", distance: 300),
        ]
        let tracker = RouteProgressTracker(polyline: poly, steps: steps)
        func shown(north: Double, east: Double = 0, south: Double = 0) -> String {
            var p = GeoMath.destination(from: origin, bearing: 0, distance: north)
            if east > 0 { p = GeoMath.destination(from: p, bearing: 90, distance: east) }
            if south > 0 { p = GeoMath.destination(from: p, bearing: 180, distance: south) }
            return tracker.process(VehicleFix(point: p, speedMps: 10, course: 0, timestamp: t0)).progress!.nextInstruction
        }
        XCTAssertEqual(shown(north: 500), "右轉進入民生西路")
        XCTAssertEqual(shown(north: 980), "右轉進入民生西路")
        XCTAssertEqual(shown(north: 1_000, east: 50), "右轉進入吉林路")
        XCTAssertEqual(shown(north: 1_000, east: 580), "右轉進入吉林路")
        XCTAssertEqual(shown(north: 1_000, east: 600, south: 50), "左轉進入長春路")
        XCTAssertEqual(shown(north: 1_000, east: 600, south: 380), "左轉進入長春路")
    }

    func testFastRoadGetsOneKilometerWarningAndEarlierNow() {
        // 往北 3 km 後靠右下交流道，100 km/h
        var poly: [GeoPoint] = []
        for i in 0...30 { poly.append(GeoMath.destination(from: origin, bearing: 0, distance: Double(i) * 100)) }
        let steps = [
            RouteStepInfo(instruction: "", distance: 0),
            RouteStepInfo(instruction: "從20號出口下交流道", distance: 2_500),
            RouteStepInfo(instruction: "目的地在你的右邊", distance: 500),
        ]
        let tracker = RouteProgressTracker(polyline: poly, steps: steps)
        let events = runRoute(tracker, straightTrack(from: origin, bearing: 0, speedKmh: 100, seconds: 95))
        let spoken = events.compactMap { e -> (Int?, TimeInterval)? in
            if case let .announce(1, _, d) = e.event { return (d, e.time) }
            return nil
        }
        XCTAssertEqual(spoken.map { $0.0 }, [1_000, 500, 200, nil])
        // 「現在」提早約 3 秒：100 km/h 時約 83 m 前就念
        let mps = SpeedUnit.mps(fromKmh: 100)
        XCTAssertEqual(spoken.last!.1, 2_500 / mps - 3, accuracy: 1.5)
    }

    // MARK: - 偏離路線

    func testOffRouteDetectedQuicklyWhenHeadingIsWrong() {
        let tracker = lRoute()
        // 往北 30 秒後轉往西邊離開路線（路口轉錯）
        let fixes = segmentedTrack(from: origin, segments: [(0, 36, 30), (270, 36, 10)])
        let off = runRoute(tracker, fixes).filter { $0.event == .offRoute }
        XCTAssertEqual(off.count, 1)
        // 離開 30 m 約在轉向後 3 秒，再持續 3 秒 → 約第 36 秒
        XCTAssertEqual(off[0].time, 36, accuracy: 2)
    }

    func testOffRouteByDistanceWhenHeadingIsSimilar() {
        let tracker = lRoute()
        // 走平行的路：方向相同，離路線 60 m
        let parallel = GeoMath.destination(from: origin, bearing: 270, distance: 60)
        let fixes = straightTrack(from: parallel, bearing: 0, speedKmh: 36, seconds: 20)
        let off = runRoute(tracker, fixes).filter { $0.event == .offRoute }
        XCTAssertEqual(off.first?.time ?? 0, 5, accuracy: 1)
    }

    /// 實測問題：沒照導航走之後，過了 5 分鐘以上才改下一步。
    /// 這次規劃失敗或被擋掉時，還沒回到路線上就要再要求一次，不能只發一次。
    func testOffRouteRepeatsUntilBackOnRoute() {
        let tracker = lRoute()
        let fixes = segmentedTrack(from: origin, segments: [(0, 36, 30), (270, 36, 60)])
        let off = runRoute(tracker, fixes).filter { $0.event == .offRoute }
        XCTAssertGreaterThanOrEqual(off.count, 4)
        for (a, b) in zip(off, off.dropFirst()) {
            XCTAssertEqual(b.time - a.time, 15, accuracy: 1.5)
        }
    }

    func testOffRouteStateShownAndClearedWhenBack() {
        let tracker = lRoute()
        var progress: [RouteProgress] = []
        // 離開路線 15 秒後回到路線上
        let north = segmentedTrack(from: origin, segments: [(0, 36, 30), (270, 36, 15)])
        for f in north { progress.append(tracker.process(f).progress!) }
        XCTAssertTrue(progress.last!.isOffRoute, "偏離後畫面要知道，不再顯示舊路線的下一步")
        let back = VehicleFix(point: GeoMath.destination(from: origin, bearing: 0, distance: 500),
                              speedMps: 10, course: 0, timestamp: t0.addingTimeInterval(60))
        XCTAssertFalse(tracker.process(back).progress!.isOffRoute)
    }

    func testNoAnnouncementsWhileOffRoute() {
        let tracker = lRoute()
        let fixes = segmentedTrack(from: origin, segments: [(0, 36, 10), (270, 36, 40)])
        let events = runRoute(tracker, fixes)
        let lastOff = events.first { $0.event == .offRoute }!
        XCTAssertFalse(events.contains { if case .announce = $0.event { return $0.time > lastOff.time }; return false })
    }

    func testShortStepAnnouncesActualDistance() {
        // 往北 1,000 m → 東 150 m → 北 500 m
        let c1 = GeoMath.destination(from: origin, bearing: 0, distance: 1_000)
        let c2 = GeoMath.destination(from: c1, bearing: 90, distance: 150)
        var poly: [GeoPoint] = []
        for i in 0...10 { poly.append(GeoMath.destination(from: origin, bearing: 0, distance: Double(i) * 100)) }
        poly.append(GeoMath.destination(from: c1, bearing: 90, distance: 75))
        poly.append(c2)
        for i in 1...5 { poly.append(GeoMath.destination(from: c2, bearing: 0, distance: Double(i) * 100)) }
        let steps = [
            RouteStepInfo(instruction: "", distance: 0),
            RouteStepInfo(instruction: "右轉", distance: 1_000),
            RouteStepInfo(instruction: "左轉", distance: 150),
            RouteStepInfo(instruction: "目的地在你的右邊", distance: 500),
        ]
        let tracker = RouteProgressTracker(polyline: poly, steps: steps)
        let fixes = segmentedTrack(from: origin, segments: [(0, 36, 100), (90, 36, 15), (0, 36, 50)])
        let events = runRoute(tracker, fixes)
        let leftTurn = events.compactMap { e -> Int?? in
            if case let .announce(2, _, d) = e.event { return .some(d) }
            return nil
        }
        // 轉進只有 150 m 的路段：不念「200 公尺後」，改念實際距離，接著「現在」
        XCTAssertEqual(leftTurn.count, 2)
        XCTAssertEqual(leftTurn.first!!, 150, accuracy: 20)
        XCTAssertNil(leftTurn.last!)
    }

    // MARK: - CarPlay 上的短文字（句子都來自實測的 Apple 導航）

    func testShortManeuverText() {
        let cases = [
            ("右轉進入環河北路一段", "右轉 環河北路一段"),
            ("左轉進入民族路，朝東區區公所、東區戶政事務所前進", "左轉 民族路"),
            ("右轉", "右轉"),
            ("稍向右轉進入民族路", "靠右 民族路"),
            ("稍向右轉上國1，朝五股前進", "靠右 上國1"),
            ("稍向左轉", "靠左"),
            ("向右急轉進入中山北路五段", "右轉 中山北路五段"),
            ("靠右行駛上五股楊梅高架，朝桃園機場、中壢前進", "靠右 上五股楊梅高架"),
            ("靠左行駛上東西向快速公路八里新店線", "靠左 上東西向快速公路八里新店線"),
            ("靠右行駛進入中豐路二段", "靠右 中豐路二段"),
            ("靠左行駛，進入新莊越堤道", "靠左 新莊越堤道"),
            ("靠左行駛，朝光復路前進", "靠左 往光復路"),
            ("靠右行駛，朝竹東、新竹前進", "靠右 往竹東"),
            ("靠右行駛", "靠右"),
            ("靠左行駛進入縣道122，朝臺灣新竹地方法院新竹簡易庭、新竹市政府前進", "靠左 縣道122"),
            ("從95A號出口下交流道，朝竹東、新竹前進", "下交流道 95A出口"),
            ("從20號出口下交流道，朝板橋、台北前進", "下交流道 20出口"),
            ("從196號出口下交流道上國1，朝彰化、台中前進", "196出口 上國1"),
            ("從264號出口下交流道，進入縣道159，朝嘉義前進", "下交流道 264出口"),
            ("從38 宜蘭號出口下交流道進入縣道191，朝壯圍、宜蘭前進", "38出口 縣道191"),
            ("在左側出口下交流道進入重慶北路，朝臺北車站前進", "左側下交流道 重慶北路"),
            ("下交流道上台64，朝五股前進", "下交流道 上台64"),
            ("下交流道，走(永福橋)，朝永和前進", "下交流道 永福橋"),
            ("下交流道，朝霧峰市區、國3前進", "下交流道 往霧峰市區"),
            ("從第6個出口離開圓環，進入勝利路", "圓環第6出口 勝利路"),
            ("從第2個出口離開圓環，進入北安路", "圓環第2出口 北安路"),
            ("從出口離開圓環，進入忠孝東路三段", "離開圓環 忠孝東路三段"),
            ("在圓環，右轉進入新光路二段，朝國3、高速公路前進", "圓環右轉 新光路二段"),
            ("在圓環，繼續往二十一號越堤道前進", "圓環直行 二十一號越堤道"),
            ("繼續往景平路前進", "直行 景平路"),
            ("繼續沿著大漢河捷徑前進，朝鶯 歌、Yingge前進", "直行 大漢河捷徑"),
            ("繼續往前走", "直行"),
            ("在大同路二段41巷迴轉", "迴轉 大同路二段41巷"),
            ("迴轉", "迴轉"),
            ("目的地在你的右邊", "目的地在右邊"),
            ("抵達目的地", "抵達目的地"),
            ("準備停車", "準備停車"),
            ("走過橋樑", "走過橋樑"),
            ("上快速公路五股土城線", "上快速公路五股土城線"),
            ("Turn right onto Main St", "Right onto Main St"),
            ("Keep left toward Taipei", "Keep left"),
            ("", ""),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(ManeuverText.short(input), expected, "原文：\(input)")
        }
    }
}
