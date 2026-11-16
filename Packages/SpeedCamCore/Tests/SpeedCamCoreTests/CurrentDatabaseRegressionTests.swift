import XCTest
@testable import SpeedCamCore

final class CurrentDatabaseRegressionTests: XCTestCase {
    private func database() throws -> CameraDatabase {
        if ProcessInfo.processInfo.environment["SPEEDCAM_CURRENT_DATABASE_REQUIRED"] == "1" {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let data = try Data(contentsOf: root.appendingPathComponent("SpeedCam/Resources/cameras.json"))
            let database = try CameraDatabase.decode(from: data)
            XCTAssertGreaterThanOrEqual(database.sections.count, 70, "CI 必須測本輪完整資料，不能退回小型 fixture")
            return database
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "current_database_v1", withExtension: "json",
                                                subdirectory: "Fixtures"))
        return try CameraDatabase.decode(from: Data(contentsOf: url))
    }

    func testEveryCurrentDirectionApproachesEntersAndCompletes() throws {
        let database = try database()
        XCTAssertFalse(database.sections.isEmpty)
        for section in database.sections {
            let path = section.displayPath
            let lead = section.speedLimit >= 80 ? 700.0 : 400.0
            let last = GeoMath.bearing(from: path[path.count - 2], to: path[path.count - 1])
            let track = [GeoMath.destination(from: section.start, bearing: section.entryHeading + 180, distance: lead)]
                + path + [GeoMath.destination(from: section.end, bearing: last, distance: 300)]
            let total = GeoMath.length(of: track)
            let speed = SpeedUnit.mps(fromKmh: 60)
            let samples = Set((0...Int((total / speed).rounded(.up))).map { min(total, Double($0) * speed) } + [lead])
                .sorted()
            let tracker = SectionSpeedTracker(sections: [section])
            var lifecycle: [String] = []
            for along in samples {
                let point = RoadSnapping.point(along: track, at: along)
                let behind = RoadSnapping.point(along: track, at: max(0, along - 1))
                let ahead = RoadSnapping.point(along: track, at: min(total, along + 1))
                let heading = along <= lead + 1 ? section.entryHeading : GeoMath.bearing(from: behind, to: ahead)
                let result = tracker.process(VehicleFix(point: point, speedMps: speed, course: heading,
                    horizontalAccuracy: 5, timestamp: t0.addingTimeInterval(along / speed)))
                for event in result.events {
                    switch event {
                    case .approaching: lifecycle.append("approaching")
                    case .entered: lifecycle.append("entered")
                    case .completed: lifecycle.append("completed")
                    case .aborted: lifecycle.append("aborted")
                    default: break
                    }
                }
            }
            XCTAssertEqual(lifecycle, ["approaching", "entered", "completed"], section.id)
            XCTAssertFalse(tracker.isActive, section.id)
        }
    }

    func testEveryCurrentDirectionRejectsOppositeApproach() throws {
        for section in try database().sections {
            let tracker = SectionSpeedTracker(sections: [section])
            let point = GeoMath.destination(from: section.start, bearing: section.entryHeading + 180, distance: 200)
            let result = tracker.process(VehicleFix(point: point, speedMps: 60 / 3.6,
                course: section.entryHeading + 180, horizontalAccuracy: 5, timestamp: t0))
            XCTAssertFalse(result.events.contains {
                switch $0 {
                case .approaching, .entered: return true
                default: return false
                }
            }, section.id)
        }
    }

    func testCurrentDatabasePreservesVerifiedReferences() throws {
        let database = try database()
        for prefix in ["beiyi-1", "beiyi-2", "beiyi-3", "beiyi-4", "ziqiang-tunnel", "xinhai-tunnel"] {
            for suffix in ["-f", "-r"] {
                XCTAssertNotNil(database.sections.first { $0.id == prefix + suffix }, prefix + suffix)
            }
        }
        for id in ["tai64-zhonghe-west", "tai64-zhonghe-east", "ntpc-huanhe-f", "ntpc-huanhe-r"] {
            XCTAssertNotNil(database.sections.first { $0.id == id }, id)
        }
        let galaxy = try XCTUnwrap(database.cameras.first { $0.address.contains("銀河") })
        XCTAssertEqual(galaxy.speedLimit, 40)
        let douliu = database.cameras.filter { $0.source == "douliu-mobile" }
        XCTAssertGreaterThanOrEqual(douliu.count, 4)
        XCTAssertTrue(douliu.allSatisfy { $0.speedLimit == nil })
    }
}
