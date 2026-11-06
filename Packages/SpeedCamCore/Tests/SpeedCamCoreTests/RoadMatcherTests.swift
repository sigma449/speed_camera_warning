import XCTest
@testable import SpeedCamCore

final class RoadMatcherTests: XCTestCase {
    private let start = GeoPoint(lat: 25.0, lon: 121.0)

    /// 從 start 往某方向一直線，長度單位公尺，offset 是整條線往東平移的距離。
    private func line(bearing: Double = 0, length: Double, offsetEast: Double = 0) -> [GeoPoint] {
        let origin = GeoMath.destination(from: start, bearing: 90, distance: offsetEast)
        return stride(from: 0.0, through: length, by: 100).map {
            GeoMath.destination(from: origin, bearing: bearing, distance: $0)
        }
    }

    func testRouteOnTheRoadOverlapsAlmostAllOfIt() {
        let matcher = RoadMatcher(lines: [line(length: 5_000)])
        let overlap = matcher.overlap(with: line(length: 3_000))
        XCTAssertEqual(overlap.total, 3_000, accuracy: 50)
        XCTAssertEqual(overlap.longestRun, 3_000, accuracy: 50)
    }

    func testCloseRoutesCountButParallelRoadsDoNot() {
        let matcher = RoadMatcher(lines: [line(length: 5_000)])
        XCTAssertEqual(matcher.overlap(with: line(length: 3_000, offsetEast: 3)).longestCloseRun, 3_000, accuracy: 50)
        // 平行的側道：在 30 m 內所以算「在附近」，但不算走在上面
        let parallel = matcher.overlap(with: line(length: 3_000, offsetEast: 15))
        XCTAssertEqual(parallel.longestRun, 3_000, accuracy: 50)
        XCTAssertEqual(parallel.longestCloseRun, 0)
    }

    func testCloseRunIsJudgedPerRun() {
        // 先貼著國道 2 km，離開，再沿著 15 m 外的側道 3 km
        let matcher = RoadMatcher(lines: [line(length: 8_000)])
        let onRoad = line(length: 2_000)
        let away = GeoMath.destination(from: onRoad.last!, bearing: 90, distance: 500)
        let side = line(length: 6_000, offsetEast: 15).filter { GeoMath.distance(start, $0) >= 3_000 }
        let overlap = matcher.overlap(with: onRoad + [away] + side)
        XCTAssertEqual(overlap.longestRun, 3_000, accuracy: 100)
        XCTAssertEqual(overlap.longestCloseRun, 2_000, accuracy: 100)
    }

    func testParallelRoadFartherAwayDoesNotCount() {
        let matcher = RoadMatcher(lines: [line(length: 5_000)])
        XCTAssertEqual(matcher.overlap(with: line(length: 3_000, offsetEast: 60)).total, 0)
    }

    func testCrossingTheRoadDoesNotCount() {
        let matcher = RoadMatcher(lines: [line(length: 5_000)])
        let origin = GeoMath.destination(from: GeoMath.destination(from: start, bearing: 0, distance: 2_500),
                                         bearing: 270, distance: 500)
        let crossing = stride(from: 0.0, through: 1_000, by: 50).map {
            GeoMath.destination(from: origin, bearing: 90, distance: $0)
        }
        XCTAssertEqual(matcher.overlap(with: crossing).total, 0)
    }

    func testOppositeDirectionCountsBecauseSomeRoadsAreOneLine() {
        let matcher = RoadMatcher(lines: [line(length: 5_000)])
        XCTAssertEqual(matcher.overlap(with: line(length: 3_000).reversed()).longestRun, 3_000, accuracy: 50)
    }

    func testLongGapSplitsTheRunButShortGapDoesNot() {
        let matcher = RoadMatcher(lines: [line(length: 1_000),
                                          line(length: 3_000).filter { GeoMath.distance(start, $0) >= 1_060 },
                                          line(length: 8_000).filter { GeoMath.distance(start, $0) >= 4_000 }])
        // 1,000～1,060 m 沒有線形（短中斷）：前兩段算一段；3,000～4,000 m 沒有線形（長中斷）：重新計算
        let overlap = matcher.overlap(with: line(length: 8_000))
        XCTAssertEqual(overlap.longestRun, 4_000, accuracy: 120)
        XCTAssertEqual(overlap.total, 6_900, accuracy: 150)
    }

    func testEmptyInputs() {
        XCTAssertTrue(RoadMatcher(lines: []).isEmpty)
        XCTAssertTrue(RoadMatcher(lines: [[start]]).isEmpty)
        XCTAssertEqual(RoadMatcher(lines: []).overlap(with: line(length: 1_000)).total, 0)
        XCTAssertEqual(RoadMatcher(lines: [line(length: 1_000)]).overlap(with: []).total, 0)
        XCTAssertEqual(RoadMatcher(lines: [line(length: 1_000)]).overlap(with: [start]).total, 0)
    }

    func testRoadLineDataDecodesAndSkipsBrokenPoints() throws {
        let json = #"""
        {"generatedAt":"2026-11-06","attribution":"OSM",
         "freeways":[[[25.0,121.0],[25.01,121.0],[25.02]]],
         "whitePlateRestricted":[]}
        """#
        let data = try RoadLineData.decode(from: Data(json.utf8))
        XCTAssertEqual(data.generatedAt, "2026-11-06")
        XCTAssertEqual(data.freeways, [[GeoPoint(lat: 25.0, lon: 121.0), GeoPoint(lat: 25.01, lon: 121.0)]])
        XCTAssertEqual(data.whitePlateRestricted, [])
    }
}
