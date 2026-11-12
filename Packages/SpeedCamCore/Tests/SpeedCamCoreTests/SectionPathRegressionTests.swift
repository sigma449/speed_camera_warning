import XCTest
@testable import SpeedCamCore

final class SectionPathRegressionTests: XCTestCase {
    private struct Snapshot: Decodable {
        let sections: [SpeedSection]
    }

    private struct ReplayAnchor: Decodable {
        let t: Double
        let lat: Double
        let lon: Double
        var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }
    }

    private func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    func testEverySnapshotPathEntersAndCompletesWithoutAbort() throws {
        let snapshot = try fixture("sections_2026_11_07", as: Snapshot.self)
        XCTAssertEqual(snapshot.sections.count, 79)
        let mapped = snapshot.sections.filter { $0.path != nil }
        XCTAssertEqual(mapped.count, 71, "不可略過快照中的任何一段路形")
        verifyForwardCompletion(mapped)
    }

    func testEveryUnmappedSnapshotSectionKeepsStraightLineFallback() throws {
        let snapshot = try fixture("sections_2026_11_07", as: Snapshot.self)
        let unmapped = snapshot.sections.filter { $0.path == nil }
        XCTAssertEqual(unmapped.count, 8)
        verifyForwardCompletion(unmapped)
    }

    private func verifyForwardCompletion(_ mapped: [SpeedSection]) {
        for section in mapped {
            let path = section.displayPath
            let first = GeoMath.bearing(from: path[0], to: path[1])
            let last = GeoMath.bearing(from: path[path.count - 2], to: path[path.count - 1])
            let track = [GeoMath.destination(from: path[0], bearing: first + 180, distance: 200)]
                + path + [GeoMath.destination(from: path[path.count - 1], bearing: last, distance: 300)]
            let tracker = SectionSpeedTracker(sections: [section])
            var lifecycle: [String] = []
            let speed = SpeedUnit.mps(fromKmh: 60)
            let total = GeoMath.length(of: track)
            for second in 0...Int((total / speed).rounded(.up)) {
                let along = min(total, Double(second) * speed)
                let point = RoadSnapping.point(along: track, at: along)
                let behind = RoadSnapping.point(along: track, at: max(0, along - 1))
                let ahead = RoadSnapping.point(along: track, at: min(total, along + 1))
                let result = tracker.process(VehicleFix(point: point, speedMps: speed,
                    course: GeoMath.bearing(from: behind, to: ahead), horizontalAccuracy: 5,
                    timestamp: t0.addingTimeInterval(Double(second))))
                for event in result.events {
                    switch event {
                    case .entered: lifecycle.append("entered")
                    case .completed: lifecycle.append("completed")
                    case .aborted: lifecycle.append("aborted")
                    default: break
                    }
                }
            }
            XCTAssertEqual(lifecycle, ["entered", "completed"], section.id)
            XCTAssertFalse(tracker.isActive, section.id)
        }
    }

    func testBeiyiFourReverseReplayHairpinDoesNotAbort() throws {
        let snapshot = try fixture("sections_2026_11_07", as: Snapshot.self)
        let section = try XCTUnwrap(snapshot.sections.first { $0.id == "beiyi-4-r" })
        let anchors = try fixture("beiyi_4_r_replay_anchors", as: [ReplayAnchor].self)
        let tracker = SectionSpeedTracker(sections: [section])
        _ = runSections(tracker, straightTrack(from: section.start, bearing: section.entryHeading,
                                               speedKmh: 60, seconds: 2))
        XCTAssertTrue(tracker.isActive)
        // Log 只保留事件定位；在相鄰的原始紀錄間每秒插值，不冒充完整的 MapKit 定位軌跡。
        for (a, b) in zip(anchors, anchors.dropFirst()) {
            for second in Int(a.t)..<Int(b.t) {
                let ratio = (Double(second) - a.t) / (b.t - a.t)
                let point = GeoPoint(lat: a.lat + (b.lat - a.lat) * ratio,
                                     lon: a.lon + (b.lon - a.lon) * ratio)
                let result = tracker.process(VehicleFix(point: point, speedMps: 60 / 3.6,
                    course: GeoMath.bearing(from: a.point, to: b.point), horizontalAccuracy: 5,
                    timestamp: t0.addingTimeInterval(Double(second))))
                XCTAssertFalse(result.events.contains { if case .aborted = $0 { return true }; return false },
                               "t=\(second)，不能把九彎十八拐的正向路徑當成折返")
            }
        }
        let last = try XCTUnwrap(anchors.last)
        let result = tracker.process(VehicleFix(point: last.point, speedMps: 60 / 3.6, course: 230.1,
                                                horizontalAccuracy: 5, timestamp: t0.addingTimeInterval(last.t)))
        XCTAssertFalse(result.events.contains { if case .aborted = $0 { return true }; return false },
                       "原 log 的 t=382 定位本身也不能中止")
        XCTAssertTrue(tracker.isActive)
    }
}
