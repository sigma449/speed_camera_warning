import XCTest
@testable import SpeedCamCore

final class RoadSnappingTests: XCTestCase {
    private let origin = GeoPoint(lat: 24.95, lon: 121.60)

    private func east(_ m: Double, north n: Double = 0) -> GeoPoint {
        GeoMath.destination(from: GeoMath.destination(from: origin, bearing: 90, distance: m), bearing: 0, distance: n)
    }

    func testDistanceToPolylineAndDeviation() {
        let line = [east(0), east(1_000)]
        XCTAssertEqual(RoadSnapping.distance(from: east(500, north: 100), to: line), 100, accuracy: 1)
        XCTAssertEqual(RoadSnapping.maxDeviation(of: [east(100, north: 20), east(900, north: 150)], from: line), 150, accuracy: 1)
    }

    func testPlausibleLength() {
        XCTAssertTrue(RoadSnapping.isPlausible(routeLength: 4_300, expected: 4_100, minRatio: 0.85, maxRatio: 1.2, slack: 150))
        XCTAssertFalse(RoadSnapping.isPlausible(routeLength: 9_000, expected: 4_100, minRatio: 0.85, maxRatio: 1.2, slack: 150))
        XCTAssertFalse(RoadSnapping.isPlausible(routeLength: 2_000, expected: 4_100, minRatio: 0.85, maxRatio: 1.2, slack: 150))
    }

    func testSegmentsCoverWholePathWithSharedEndpoints() {
        // L 形 3 公里：東 2 公里再北 1 公里
        let path = [east(0), east(2_000), east(2_000, north: 1_000)]
        let segs = RoadSnapping.segments(of: path, spacing: 1_200)
        XCTAssertEqual(segs.count, 3)                       // 3,000 / 1,200 ≈ 2.5 → 3 段，每段 1 公里
        XCTAssertEqual(GeoMath.distance(segs[0].first!, path[0]), 0, accuracy: 0.5)
        XCTAssertEqual(GeoMath.distance(segs[2].last!, path[2]), 0, accuracy: 0.5)
        for (a, b) in zip(segs, segs.dropFirst()) {
            XCTAssertEqual(GeoMath.distance(a.last!, b.first!), 0, accuracy: 0.5)
        }
        // 第二段經過轉角，轉角點要保留
        XCTAssertTrue(segs[1].contains { GeoMath.distance($0, path[1]) < 0.5 })
        XCTAssertEqual(segs.map { GeoMath.length(of: $0) }.reduce(0, +), 3_000, accuracy: 2)
    }

    func testSimplifyKeepsCornersAndDropsStraightPoints() {
        let straight = (0...10).map { east(Double($0) * 100) }
        XCTAssertEqual(RoadSnapping.simplify(straight, tolerance: 3).count, 2)
        let corner = (0...5).map { east(Double($0) * 100) } + (1...5).map { east(500, north: Double($0) * 100) }
        let simplified = RoadSnapping.simplify(corner, tolerance: 3)
        XCTAssertEqual(simplified.count, 3)
        XCTAssertEqual(GeoMath.distance(simplified[1], east(500)), 0, accuracy: 0.5)
    }

    func testOrientedReversesForOtherDirection() {
        let path = [east(0), east(500), east(1_000)]
        XCTAssertEqual(RoadSnapping.oriented(path, startingNear: east(5)), path)
        XCTAssertEqual(RoadSnapping.oriented(path, startingNear: east(990)), path.reversed())
    }

    func testCacheInvalidatesChangedGatesAndNeverSharesAsymmetricDirections() {
        let original = SpeedSection(id: "beiyi-2-f", name: "北宜", start: east(0), end: east(1_000),
                                    lengthMeters: 1_000, speedLimit: 40)
        var moved = original
        moved.start = east(80)
        XCTAssertNotEqual(RoadSnapping.cacheSignature(for: original), RoadSnapping.cacheSignature(for: moved))
        var reverse = original
        reverse.id = "beiyi-2-r"
        reverse.start = east(1_010)
        reverse.end = east(90)
        XCTAssertEqual(original.groupID, reverse.groupID, "容許值仍共用")
        XCTAssertNotEqual(RoadSnapping.cacheSignature(for: moved), RoadSnapping.cacheSignature(for: reverse))
        var movedEnd = moved
        movedEnd.end = east(1_001)
        XCTAssertNotEqual(RoadSnapping.cacheSignature(for: moved), RoadSnapping.cacheSignature(for: movedEnd))
    }
}
