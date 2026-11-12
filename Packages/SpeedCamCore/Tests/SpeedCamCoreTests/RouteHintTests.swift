import XCTest
@testable import SpeedCamCore

final class RouteHintTests: XCTestCase {
    private struct Branches: Decodable {
        struct Way: Decodable { let points: [[Double]] }
        let ways: [String: Way]
    }

    private func bundledHints() throws -> [RouteHint] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try RouteHint.decode(from: Data(contentsOf: root.appendingPathComponent("SpeedCam/Resources/route_hints.json")))
    }

    private func branch(_ ids: [Int]) throws -> [GeoPoint] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "route_hint_branches", withExtension: "json", subdirectory: "Fixtures"))
        let data = try JSONDecoder().decode(Branches.self, from: Data(contentsOf: url))
        var points: [GeoPoint] = []
        for id in ids {
            let way = try XCTUnwrap(data.ways[String(id)], "\(id)")
            let path = way.points.map { GeoPoint(lat: $0[0], lon: $0[1]) }
            if let last = points.last, let first = path.first, GeoMath.distance(last, first) < 1 {
                points += path.dropFirst()
            } else {
                points += path
            }
        }
        return points
    }

    private func hint() -> RouteHint {
        RouteHint(id: "underpass", point: GeoMath.destination(from: origin, bearing: 0, distance: 800),
                  heading: 0, confirmation: GeoMath.destination(from: origin, bearing: 0, distance: 1_050),
                  shortText: "中間車道 下地下道", instruction: "走中間車道下地下道，往北宜路", source: "使用者實測",
                  replaces: ["左轉進入環河路"])
    }

    func testRealBranchesMatchInOrderAndRejectReverseDirection() throws {
        let hints = try bundledHints()
        let cases: [(String, [Int])] = [
            ("jianguo-shida-descent", [764187879, 49695699, 49695689]),
            ("shida-underpass", [49695689, 49749172, 331609728]),
            ("shuiyuan-south-huanhe", [24836732, 28905846, 540625075]),
            ("huanhe-underpass", [1345096370, 189011738, 189011740]),
            ("shuiyuan-north-entry", [283481043, 540625076, 1422614376, 238689685, 28905845]),
        ]
        XCTAssertEqual(hints.count, cases.count)
        for (id, ways) in cases {
            let route = try branch(ways)
            let selected = try XCTUnwrap(hints.first { $0.id == id })
            let matches = RouteHintMatcher.matches([selected], polyline: route)
            XCTAssertEqual(matches.map { $0.hint.id }, [id])
            XCTAssertGreaterThan(try XCTUnwrap(matches.first).confirmationAlong, matches[0].along)
            XCTAssertTrue(RouteHintMatcher.matches([selected], polyline: Array(route.reversed())).isEmpty, id)
        }
    }

    func testRealXiulangAndSurfaceBranchesDoNotReceiveHuanheHints() throws {
        let hints = try bundledHints()
        let south = try XCTUnwrap(hints.first { $0.id == "shuiyuan-south-huanhe" })
        let bridge = try branch([24836732, 28905846, 24836710])
        XCTAssertTrue(RouteHintMatcher.matches([south], polyline: bridge).isEmpty)
        let underground = try XCTUnwrap(hints.first { $0.id == "huanhe-underpass" })
        for route in [try branch([1345096370, 238699270]), try branch([1080802350])] {
            XCTAssertTrue(RouteHintMatcher.matches([underground], polyline: route).isEmpty)
        }
    }

    func testParallelRoadWrongOrderAndAbsentNavigationDoNotMatch() {
        let h = hint()
        let end = GeoMath.destination(from: origin, bearing: 0, distance: 1_800)
        let parallel = [origin, end].map { GeoMath.destination(from: $0, bearing: 90, distance: 40) }
        XCTAssertTrue(RouteHintMatcher.matches([h], polyline: parallel).isEmpty)
        let reversedOrder = [h.confirmation, origin, h.point]
        XCTAssertTrue(RouteHintMatcher.matches([h], polyline: reversedOrder).isEmpty)
        XCTAssertTrue(RouteHintMatcher.matches([h], polyline: []).isEmpty)
        XCTAssertNil(RouteProgressTracker(polyline: [], steps: []).process(
            VehicleFix(point: h.point, speedMps: 10, course: 0, timestamp: t0)).progress)
    }

    func testHintReplacesMisleadingStepSharesThresholdsAndDoesNotRepeat() throws {
        let h = hint()
        let route = [origin, GeoMath.destination(from: origin, bearing: 0, distance: 1_800)]
        let matches = RouteHintMatcher.matches([h, h], polyline: route)
        let steps = RouteHintMatcher.steps([
            RouteStepInfo(instruction: "左轉進入環河路", distance: 805),
            RouteStepInfo(instruction: "抵達目的地", distance: 995),
        ], matches: matches + matches, totalDistance: 1_800)
        XCTAssertEqual(steps.filter { $0.hintID == h.id }.count, 1)
        XCTAssertFalse(steps.contains { $0.instruction == "左轉進入環河路" })
        XCTAssertEqual(steps.reduce(0) { $0 + $1.distance }, 1_800, accuracy: 0.01)
        let tracker = RouteProgressTracker(polyline: route, steps: steps)
        var announcements: [Int?] = []
        for fix in straightTrack(from: origin, bearing: 0, speedKmh: 36, seconds: 100) {
            let result = tracker.process(fix)
            if let p = result.progress, p.hintID == h.id {
                XCTAssertEqual(p.maneuverText, h.shortText)
                XCTAssertEqual(p.nextInstruction, h.instruction)
            }
            for event in result.events {
                if case let .announce(index, instruction, distance) = event, steps[index].hintID == h.id {
                    announcements.append(distance)
                    XCTAssertEqual(instruction, h.instruction)
                }
            }
        }
        XCTAssertEqual(announcements, [500, 200, nil])
        let repeated = runRoute(tracker, straightTrack(from: origin, bearing: 0, speedKmh: 36, seconds: 100,
                                                       startTime: t0.addingTimeInterval(101)))
        XCTAssertFalse(repeated.contains {
            if case let .announce(index, _, _) = $0.event { return steps[index].hintID == h.id }
            return false
        })
    }

    func testUnrelatedAppleInstructionsAndManeuverPositionsArePreserved() {
        let h = hint()
        let route = [origin, GeoMath.destination(from: origin, bearing: 0, distance: 1_800)]
        let original = [RouteStepInfo(instruction: "右轉進入長春路", distance: 100),
                        RouteStepInfo(instruction: "抵達目的地", distance: 1_700)]
        XCTAssertEqual(RouteHintMatcher.steps(original, matches: [], totalDistance: 1_800), original)
        let steps = RouteHintMatcher.steps(original, matches: RouteHintMatcher.matches([h], polyline: route),
                                           totalDistance: 1_800)
        XCTAssertEqual(steps.first, original.first)
        XCTAssertEqual(steps.last?.instruction, original.last?.instruction)
        XCTAssertEqual(steps.reduce(0) { $0 + $1.distance }, 1_800, accuracy: 0.01)
        XCTAssertEqual(steps.prefix(2).reduce(0) { $0 + $1.distance }, 800, accuracy: 0.1)
    }

    func testNearbyUnrelatedAppleTurnIsNotReplaced() {
        let h = hint()
        let route = [origin, GeoMath.destination(from: origin, bearing: 0, distance: 1_800)]
        let original = [RouteStepInfo(instruction: "右轉進入無關道路", distance: 790),
                        RouteStepInfo(instruction: "抵達目的地", distance: 1_010)]
        let steps = RouteHintMatcher.steps(original, matches: RouteHintMatcher.matches([h], polyline: route),
                                           totalDistance: 1_800)
        XCTAssertEqual(steps.first, original.first)
        XCTAssertEqual(steps[1].hintID, h.id)
        XCTAssertEqual(steps[1].distance, 10, accuracy: 0.1)
        XCTAssertEqual(steps.last?.instruction, "抵達目的地")
    }

    func testInvalidOrDuplicateHintDataFailsExplicitly() throws {
        var bad = hint()
        bad.heading = 360
        XCTAssertThrowsError(try RouteHint.decode(from: JSONEncoder().encode([bad])))
        XCTAssertThrowsError(try RouteHint.decode(from: JSONEncoder().encode([hint(), hint()])))
        bad = hint()
        bad.source = ""
        XCTAssertThrowsError(try RouteHint.decode(from: JSONEncoder().encode([bad])))
        XCTAssertThrowsError(try RouteHint.decode(from: Data("[]".utf8)))
    }
}
