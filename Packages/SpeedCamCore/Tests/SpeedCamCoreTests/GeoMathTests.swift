import XCTest
@testable import SpeedCamCore

final class GeoMathTests: XCTestCase {
    func testOneDegreeLatitudeIsAbout111km() {
        let d = GeoMath.distance(GeoPoint(lat: 24, lon: 121), GeoPoint(lat: 25, lon: 121))
        XCTAssertEqual(d, 111_195, accuracy: 300)
    }

    func testBearings() {
        let a = GeoPoint(lat: 25, lon: 121)
        XCTAssertEqual(GeoMath.bearing(from: a, to: GeoPoint(lat: 25.01, lon: 121)), 0, accuracy: 0.1)
        XCTAssertEqual(GeoMath.bearing(from: a, to: GeoPoint(lat: 25, lon: 121.01)), 90, accuracy: 0.1)
        XCTAssertEqual(GeoMath.bearing(from: a, to: GeoPoint(lat: 24.99, lon: 121)), 180, accuracy: 0.1)
        XCTAssertEqual(GeoMath.bearing(from: a, to: GeoPoint(lat: 25, lon: 120.99)), 270, accuracy: 0.1)
    }

    func testAngleDifferenceWrapsAround() {
        XCTAssertEqual(GeoMath.angleDifference(350, 10), 20, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.angleDifference(10, 350), 20, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.angleDifference(0, 180), 180, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.angleDifference(-90, 270), 0, accuracy: 1e-9)
    }

    func testDestinationRoundTrip() {
        let p = GeoMath.destination(from: origin, bearing: 37, distance: 1_234)
        XCTAssertEqual(GeoMath.distance(origin, p), 1_234, accuracy: 0.5)
        XCTAssertEqual(GeoMath.bearing(from: origin, to: p), 37, accuracy: 0.1)
    }

    func testProjectionOntoSegment() {
        let a = origin
        let b = GeoMath.destination(from: a, bearing: 0, distance: 1_000)
        let mid = GeoMath.destination(from: a, bearing: 0, distance: 400)
        let off = GeoMath.destination(from: mid, bearing: 90, distance: 30)
        let proj = GeoMath.project(off, ontoSegment: a, b)
        XCTAssertEqual(proj.t, 0.4, accuracy: 0.005)
        XCTAssertEqual(proj.distance, 30, accuracy: 0.5)

        // 線段外側：投影夾在端點
        let before = GeoMath.destination(from: a, bearing: 180, distance: 50)
        let p2 = GeoMath.project(before, ontoSegment: a, b)
        XCTAssertEqual(p2.t, 0, accuracy: 1e-9)
        XCTAssertEqual(p2.distance, 50, accuracy: 0.5)
    }

    func testPolylineLength() {
        let pts = [origin,
                   GeoMath.destination(from: origin, bearing: 0, distance: 500),
                   GeoMath.destination(from: GeoMath.destination(from: origin, bearing: 0, distance: 500), bearing: 90, distance: 300)]
        XCTAssertEqual(GeoMath.length(of: pts), 800, accuracy: 0.5)
    }
}

final class SpatialIndexTests: XCTestCase {
    func testNearQuerySortedAndFiltered() {
        let cams = [
            Camera(id: "a", type: .fixed, lat: origin.lat, lon: origin.lon),
            Camera(id: "b", type: .fixed, lat: GeoMath.destination(from: origin, bearing: 0, distance: 500).lat, lon: origin.lon),
            Camera(id: "c", type: .fixed, lat: GeoMath.destination(from: origin, bearing: 0, distance: 3_000).lat, lon: origin.lon),
        ]
        let index = SpatialIndex(cameras: cams)
        let near = index.cameras(near: GeoMath.destination(from: origin, bearing: 0, distance: 100), radius: 800)
        XCTAssertEqual(near.map { $0.camera.id }, ["a", "b"])
        XCTAssertEqual(near[0].distance, 100, accuracy: 1)
    }

    func testBoxQueryAcrossCells() {
        var cams: [Camera] = []
        for i in 0..<50 {
            let p = GeoMath.destination(from: origin, bearing: 45, distance: Double(i) * 200)
            cams.append(Camera(id: "\(i)", type: .fixed, lat: p.lat, lon: p.lon))
        }
        let index = SpatialIndex(cameras: cams)
        let all = index.cameras(minLat: 24.9, maxLat: 25.2, minLon: 121.4, maxLon: 121.7)
        XCTAssertEqual(all.count, 50)
        let limited = index.cameras(minLat: 24.9, maxLat: 25.2, minLon: 121.4, maxLon: 121.7, limit: 10)
        XCTAssertEqual(limited.count, 10)
    }
}
