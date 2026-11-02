import XCTest
@testable import SpeedCamCore

final class RouteProgressTests: XCTestCase {

    /// L 型路線：先往北 1,500 m，再往東 800 m。
    /// MapKit 的步驟格式：第 0 步是起點（距離 0），第 i 步的指示是這一步開始時的動作。
    private func lRoute() -> RouteProgressTracker {
        let corner = GeoMath.destination(from: origin, bearing: 0, distance: 1_500)
        var poly: [GeoPoint] = []
        for i in 0...15 { poly.append(GeoMath.destination(from: origin, bearing: 0, distance: Double(i) * 100)) }
        for i in 1...8 { poly.append(GeoMath.destination(from: corner, bearing: 90, distance: Double(i) * 100)) }
        let steps = [
            RouteStepInfo(instruction: "", distance: 0),
            RouteStepInfo(instruction: "沿中山北路行駛", distance: 1_500),
            RouteStepInfo(instruction: "右轉進入忠孝東路", distance: 800),
            RouteStepInfo(instruction: "抵達目的地", distance: 0),
        ]
        return RouteProgressTracker(polyline: poly, steps: steps)
    }

    func testAnnouncesTurnAt500And200AndNowThenArrives() {
        let tracker = lRoute()
        let fixes = segmentedTrack(from: origin, segments: [(0, 36, 150), (90, 36, 85)])  // 10 m/s
        let events = runRoute(tracker, fixes)

        let turnAnnouncements = events.compactMap { e -> Int?? in
            if case let .announce(idx, text, d) = e.event, idx == 2 {
                XCTAssertEqual(text, "右轉進入忠孝東路")
                return .some(d)
            }
            return nil
        }
        XCTAssertEqual(turnAnnouncements, [500, 200, nil])
        XCTAssertEqual(events.filter { $0.event == .arrived }.count, 1)
        XCTAssertFalse(events.contains { $0.event == .offRoute })

        // 500 m 的播報應在約 100 秒（開了 1,000 m）時
        let first = events.first { if case .announce(2, _, 500) = $0.event { return true }; return false }!
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
    }

    func testOffRouteDetectedOnceAfterFiveSeconds() {
        let tracker = lRoute()
        // 往北 30 秒後轉往西邊離開路線
        let fixes = segmentedTrack(from: origin, segments: [(0, 36, 30), (270, 36, 30)])
        let events = runRoute(tracker, fixes)
        let off = events.filter { $0.event == .offRoute }
        XCTAssertEqual(off.count, 1)
        // 離開路線 50 m 約在轉向後 5 秒，再持續 5 秒 → 約第 40 秒
        XCTAssertEqual(off[0].time, 40, accuracy: 2)
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
            RouteStepInfo(instruction: "往北", distance: 1_000),
            RouteStepInfo(instruction: "右轉", distance: 150),
            RouteStepInfo(instruction: "左轉", distance: 500),
            RouteStepInfo(instruction: "抵達目的地", distance: 0),
        ]
        let tracker = RouteProgressTracker(polyline: poly, steps: steps)
        let fixes = segmentedTrack(from: origin, segments: [(0, 36, 100), (90, 36, 15), (0, 36, 50)])
        let events = runRoute(tracker, fixes)
        let leftTurn = events.compactMap { e -> Int?? in
            if case let .announce(3, _, d) = e.event { return .some(d) }
            return nil
        }
        // 轉進只有 150 m 的路段：不念「200 公尺後」，改念實際距離，接著「現在」
        XCTAssertEqual(leftTurn.count, 2)
        XCTAssertEqual(leftTurn.first!!, 150, accuracy: 20)
        XCTAssertNil(leftTurn.last!)
    }
}
