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

    private struct TunnelReplays: Decodable {
        let cases: [TunnelReplay]
    }

    private struct TunnelReplay: Decodable {
        let section: SpeedSection
        let route: [[Double]]
        let speedKmh: Double
        let gpsGaps: [[Int]]
        let anchors: [ReplayAnchor]
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

    func testAcceptanceDongaoCompletesAfterMissingTheEndGateDuringGpsLoss() throws {
        let replay = try tunnelReplay("auto-台9-110.96-108.224-r")
        let lifecycle = replayTunnel(replay)
        XCTAssertEqual(lifecycle.map(\.event), ["entered", "completed"])
        XCTAssertEqual(lifecycle.map(\.second), [378, 550])
    }

    func testAcceptanceXueshanDoesNotEstimateEntryIntoNearbyBeiyiSection() throws {
        let replay = try tunnelReplay("beiyi-4-r")
        XCTAssertTrue(replayTunnel(replay, includeApproach: true).isEmpty,
                      "國5失聯前的行向不會經過北宜門架，不能預告、進入或事後以中止掩蓋")
    }

    private func tunnelReplay(_ id: String) throws -> TunnelReplay {
        let snapshot = try fixture("tunnel_replay_2026_11_16", as: TunnelReplays.self)
        return try XCTUnwrap(snapshot.cases.first { $0.section.id == id })
    }

    private func replayTunnel(_ replay: TunnelReplay, includeApproach: Bool = false) -> [(second: Int, event: String)] {
        let path = replay.route.map { GeoPoint(lat: $0[0], lon: $0[1]) }
        var cumulative = [0.0]
        for (a, b) in zip(path, path.dropFirst()) {
            cumulative.append(cumulative.last! + GeoMath.distance(a, b))
        }
        let tracker = SectionSpeedTracker(sections: [replay.section])
        var lifecycle: [(second: Int, event: String)] = []
        var segment = 0
        var along = 0.0
        var second = 0
        while along < cumulative.last! {
            while segment < path.count - 2 && cumulative[segment + 1] <= along { segment += 1 }
            let a = path[segment], b = path[segment + 1]
            let ratio = min(1, max(0, (along - cumulative[segment])
                                  / max(0.01, cumulative[segment + 1] - cumulative[segment])))
            let point = GeoPoint(lat: a.lat + (b.lat - a.lat) * ratio,
                                 lon: a.lon + (b.lon - a.lon) * ratio)
            for anchor in replay.anchors where anchor.t == Double(second) {
                XCTAssertLessThan(GeoMath.distance(point, anchor.point), 0.001,
                                  "重建定位須與原 log 的事件定位一致")
            }
            let now = t0.addingTimeInterval(Double(second))
            let result: SectionResult?
            if replay.gpsGaps.contains(where: { $0[0] <= second && second < $0[1] }) {
                result = tracker.tick(now: now)
            } else {
                result = tracker.process(VehicleFix(point: point, speedMps: replay.speedKmh / 3.6,
                    course: GeoMath.bearing(from: a, to: b), horizontalAccuracy: 5, timestamp: now))
            }
            for event in result?.events ?? [] {
                switch event {
                case .entered: lifecycle.append((second, "entered"))
                case .completed: lifecycle.append((second, "completed"))
                case .aborted: lifecycle.append((second, "aborted"))
                case .approaching where includeApproach: lifecycle.append((second, "approaching"))
                default: break
                }
            }
            along += replay.speedKmh / 3.6
            second += 1
        }
        XCTAssertFalse(tracker.isActive)
        return lifecycle
    }
}
