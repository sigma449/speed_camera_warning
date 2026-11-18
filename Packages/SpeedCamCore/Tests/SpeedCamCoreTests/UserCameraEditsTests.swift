import Foundation
import XCTest
@testable import SpeedCamCore

final class UserCameraEditsTests: XCTestCase {
    private func official(_ id: String = "official", type: CameraType = .fixed,
                          north: Double = 280) -> Camera {
        let point = GeoMath.destination(from: origin, bearing: 0, distance: north)
        return Camera(id: id, type: type, lat: point.lat, lon: point.lon, heading: 0,
                      speedLimit: 50, address: "測試路", city: "臺北市", district: "信義區",
                      source: "官方", sourceID: "123", positionMethod: "official")
    }

    private func added(_ number: Int = 1, type: CameraType = .fixed,
                       heading: Double? = 0, axis: Double? = nil, limit: Int? = 50) -> Camera {
        var camera = official()
        camera.id = String(format: "user-00000000-0000-0000-0000-%012d", number)
        camera.type = type
        camera.heading = heading
        camera.axis = axis
        camera.speedLimit = type == .fixed ? limit : nil
        camera.source = "自行新增"
        camera.sourceID = nil
        camera.positionMethod = "user"
        return camera
    }

    private func inTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UserCameraTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try! FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    func testEmptyEditsKeepEveryFieldAndOrderIdentical() throws {
        var camera = official()
        camera.axis = 90
        camera.level = .elevated
        camera.sectionGroupID = "known"
        camera.enforcementItems = "超速"
        camera.conditions = "一般車輛"
        camera.sourceURL = "https://example.test/123"
        let input = [camera, official("section", type: .section), official("noise", type: .noise)]
        XCTAssertEqual(UserCameraEdits().apply(to: input), input)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(UserCameraEdits().apply(to: input)),
                       try encoder.encode(input))
    }

    func testMergeAddsHidesAndOverridesOnlySelectedFields() throws {
        let first = official()
        let second = official("hidden", type: .noise)
        let user = added()
        var edits = UserCameraEdits()
        try edits.add(user)
        try edits.hide(second)
        try edits.modify(first, speedLimit: 40, direction: UserCameraDirection(axis: 45))
        var expected = first
        expected.speedLimit = 40
        expected.heading = nil
        expected.axis = 45
        XCTAssertEqual(edits.apply(to: [first, second]), [expected, user])
        edits.restoreOriginal(id: first.id)
        edits.unhide(id: second.id)
        XCTAssertEqual(edits.apply(to: [first, second]), [first, second, user])
        edits.deleteAdded(id: user.id)
        XCTAssertEqual(edits, UserCameraEdits())
    }

    func testMissingIDsRemainStoredAndBecomeEffectiveIfTheyReturn() throws {
        let camera = official()
        var edits = UserCameraEdits()
        try edits.modify(camera, speedLimit: 40, direction: UserCameraDirection())
        try edits.hide(official("hidden"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(edits)
        XCTAssertEqual(edits.apply(to: []), [])
        XCTAssertEqual(try encoder.encode(edits), encoded)
        let restored = try XCTUnwrap(edits.apply(to: [camera]).first)
        XCTAssertEqual(restored.speedLimit, 40)
        XCTAssertNil(restored.heading)
        XCTAssertNil(restored.axis)
    }

    func testUpdatingAnAddedCameraKeepsItsIDAndDateAndCanSwitchToRedLight() throws {
        var camera = added(heading: 240.61066)
        var edits = UserCameraEdits()
        try edits.add(camera)
        let date = edits.addedOn[camera.id]
        camera.type = .redLight
        camera.speedLimit = nil
        camera.heading = nil
        camera.axis = 135
        try edits.updateAdded(camera)
        XCTAssertEqual(edits.apply(to: []), [camera])
        XCTAssertEqual(edits.addedOn[camera.id], date)
        XCTAssertEqual(edits.added.first?.id, camera.id)
        XCTAssertFalse(edits.added[0].enforcesSpeed)
        XCTAssertTrue(edits.added[0].usesTwoStageAlert)
        var invalid = camera
        invalid.speedLimit = 50
        XCTAssertThrowsError(try edits.updateAdded(invalid))
        XCTAssertEqual(edits.added, [camera])
    }

    func testSelectedPlaceAddressUsesResolvedNameOrCoordinatesAfterFailure() throws {
        var selection = MapPlaceSelection()
        let id = try XCTUnwrap(selection.select(point: origin, name: "測試地點", mode: .browsing))
        XCTAssertEqual(selection.place?.userCameraAddress, "測試地點")
        XCTAssertTrue(selection.resolveAddress(id: id, name: nil, address: "臺北市測試路1號"))
        XCTAssertEqual(selection.place?.userCameraAddress, "測試地點（臺北市測試路1號）")
        XCTAssertTrue(selection.resolveAddress(id: id, name: nil, address: nil))
        XCTAssertEqual(selection.place?.userCameraAddress, "自行新增（25.03000, 121.56500）")
        XCTAssertEqual(selection.place?.point, origin)
        var camera = added(heading: nil)
        camera.lat = origin.lat
        camera.lon = origin.lon
        camera.address = try XCTUnwrap(selection.place?.userCameraAddress)
        XCTAssertEqual(camera.shortAddress, "所選位置")
        var edits = UserCameraEdits()
        try edits.add(camera)
        XCTAssertTrue(try UserCameraExport(edits: edits, originals: []).csv
            .contains("\"自行新增（25.03000, 121.56500）\""))
    }

    func testSectionsCannotBeHiddenOrModifiedEvenByStoredOverrides() throws {
        let camera = official(type: .section)
        var edits = UserCameraEdits(hidden: [camera.id],
            modified: [camera.id: UserCameraOverride(speedLimit: 30, direction: UserCameraDirection(axis: 90))])
        XCTAssertEqual(edits.apply(to: [camera]), [camera])
        XCTAssertThrowsError(try edits.hide(camera))
        XCTAssertThrowsError(try edits.modify(camera, speedLimit: 30, direction: UserCameraDirection()))
    }

    func testNonSpeedTypesKeepOriginalLimitAndEnforcementSemantics() throws {
        for type in [CameraType.mobile, .noise, .redLight, .tech] {
            var camera = official(type: type)
            if type == .tech { camera.enforcementItems = "闖紅燈、違規停車" }
            var edits = UserCameraEdits()
            try edits.modify(camera, speedLimit: 30, direction: UserCameraDirection(heading: 90))
            let result = try XCTUnwrap(edits.apply(to: [camera]).first)
            XCTAssertEqual(result.speedLimit, camera.speedLimit)
            XCTAssertEqual(result.enforcementItems, camera.enforcementItems)
            XCTAssertFalse(result.enforcesSpeed)
            XCTAssertEqual(result.heading, 90)
            try edits.hide(camera)
            XCTAssertTrue(edits.apply(to: [camera]).isEmpty)
        }
        var tech = official(type: .tech)
        tech.enforcementItems = "超速、闖紅燈"
        var edits = UserCameraEdits()
        try edits.modify(tech, speedLimit: 60, direction: UserCameraDirection(camera: tech))
        XCTAssertEqual(edits.apply(to: [tech]).first?.speedLimit, 60)
    }

    func testJSONRoundTripKeepsClearedDirectionExactAnglesAndOriginalSnapshots() throws {
        let original = official()
        var edits = UserCameraEdits()
        try edits.add(added(heading: 240.61066))
        try edits.add(added(2, heading: nil, axis: 135))
        try edits.modify(original, speedLimit: 60, direction: UserCameraDirection())
        try edits.hide(original)
        let decoded = try JSONDecoder().decode(UserCameraEdits.self, from: JSONEncoder().encode(edits))
        XCTAssertEqual(decoded, edits)
        XCTAssertEqual(decoded.modified[original.id]?.direction, UserCameraDirection())
        XCTAssertEqual(decoded.originals[original.id], original)
        let minimal = Data(#"{"added":[],"hidden":[],"modified":{}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(UserCameraEdits.self, from: minimal), UserCameraEdits())
    }

    func testFileRoundTripAndInvalidSaveLeavePreviousBytesIntact() throws {
        try inTemporaryDirectory { directory in
            let file = UserCameraEditsFile(url: directory.appendingPathComponent("support")
                .appendingPathComponent("userCameraEdits.v1.json"))
            XCTAssertTrue(try file.load().edits.isEmpty)
            var edits = UserCameraEdits()
            try edits.add(added())
            try file.save(edits)
            XCTAssertEqual(try file.load().edits, edits)
            let previous = try Data(contentsOf: file.url)
            edits.added[0].lat = .infinity
            XCTAssertThrowsError(try file.save(edits))
            XCTAssertEqual(try Data(contentsOf: file.url), previous)
        }
    }

    func testBadJSONAndInvalidContentsArePreservedBeforeWritingANewFile() throws {
        let malformed = Data("{broken".utf8)
        var invalid = UserCameraEdits()
        try invalid.add(added())
        invalid.added[0].axis = 45
        let invalidData = try JSONEncoder().encode(invalid)
        for bytes in [malformed, invalidData, Data(#"{"added":[]}"#.utf8)] {
            try inTemporaryDirectory { directory in
                let file = UserCameraEditsFile(url: directory.appendingPathComponent("userCameraEdits.v1.json"))
                try bytes.write(to: file.url)
                let result = try file.load()
                XCTAssertTrue(result.edits.isEmpty)
                XCTAssertNotNil(result.warning)
                let preserved = try XCTUnwrap(result.preservedURL)
                XCTAssertEqual(try Data(contentsOf: preserved), bytes)
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
                var newEdits = result.edits
                try newEdits.add(added(2))
                try file.save(newEdits)
                XCTAssertEqual(try file.load().edits, newEdits)
                XCTAssertEqual(try Data(contentsOf: preserved), bytes)
            }
        }
    }

    func testUnreadableFileIsNotRenamedOrReplacedByEmptyEdits() throws {
        try inTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("userCameraEdits.v1.json")
            var edits = UserCameraEdits()
            try edits.add(added())
            try UserCameraEditsFile(url: url).save(edits)
            let saved = try Data(contentsOf: url)
            // 重開機後尚未解鎖時，資料保護會讓檔案暫時讀不到：不是壞檔，不能改名或當成空清單。
            let locked = UserCameraEditsFile(url: url) { _ in throw CocoaError(.fileReadNoPermission) }
            XCTAssertThrowsError(try locked.load())
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path),
                           ["userCameraEdits.v1.json"])
            XCTAssertEqual(try Data(contentsOf: url), saved)
            XCTAssertEqual(try UserCameraEditsFile(url: url).load().edits, edits)
        }
    }

    func testCurrentHeadingRequiresCruiseReliableMovingFixAndNearbyCurrentPosition() {
        let moving = VehicleFix(point: origin, speedMps: 8 / 3.6, course: 240.61066, timestamp: t0)
        let near = GeoMath.destination(from: origin, bearing: 0, distance: 149)
        let far = GeoMath.destination(from: origin, bearing: 0, distance: 151)
        func heading(_ fix: VehicleFix?, _ headingFix: VehicleFix?, at point: GeoPoint = origin,
                     cruising: Bool = true) -> Double? {
            UserCameraEdits.suggestedHeading(at: point, isCruising: cruising, lastFix: fix, lastHeadingFix: headingFix)
        }
        XCTAssertEqual(heading(moving, moving, at: near), 240.61066)
        XCTAssertNil(heading(moving, moving, at: far))
        XCTAssertNil(heading(moving, moving, cruising: false))
        XCTAssertNil(heading(nil, moving))
        for bad in [
            VehicleFix(point: origin, speedMps: 7.9 / 3.6, course: 0, timestamp: t0),
            VehicleFix(point: origin, speedMps: 20, course: nil, timestamp: t0),
            VehicleFix(point: origin, speedMps: 20, course: -.infinity, timestamp: t0),
            VehicleFix(point: origin, speedMps: 20, course: 0, horizontalAccuracy: 101, timestamp: t0),
            VehicleFix(point: origin, speedMps: -1, course: 0, timestamp: t0),
        ] {
            XCTAssertNil(heading(moving, bad))
        }
        var stopped = moving
        stopped.speedMps = 0
        stopped.course = nil
        XCTAssertEqual(heading(stopped, moving), 240.61066)
        stopped.horizontalAccuracy = 101
        XCTAssertNil(heading(stopped, moving))
    }

    func testAllFourBidirectionalAxesRejectCrossTrafficAndUnknownUsesExistingAheadRule() {
        for axis in [0.0, 45, 90, 135] {
            let camera = added(heading: nil, axis: axis)
            let engine = CameraAlertEngine(index: SpatialIndex(cameras: [camera]))
            for heading in [axis, axis + 180, axis + 90] {
                let start = GeoMath.destination(from: camera.point, bearing: heading + 180, distance: 280)
                let result = engine.isRelevant(camera, distance: 280, from: start, heading: heading, isTracked: false)
                XCTAssertEqual(result, heading != axis + 90)
            }
        }
        let unknown = added(heading: nil)
        let engine = CameraAlertEngine(index: SpatialIndex(cameras: [unknown]))
        for delta in [29.0, 31] {
            let start = GeoMath.destination(from: unknown.point, bearing: delta + 180, distance: 280)
            XCTAssertEqual(engine.isRelevant(unknown, distance: 280, from: start, heading: 0, isTracked: false),
                           delta < 30)
        }
    }

    func testAddedSpeedAndRedLightUseExistingStagesAndOnlySpeedBeeps() throws {
        for type in [CameraType.fixed, .redLight] {
            let camera = added(type: type)
            var edits = UserCameraEdits()
            try edits.add(camera)
            let engine = CameraAlertEngine(index: SpatialIndex(cameras: edits.apply(to: [])))
            let events = runAlerts(engine, straightTrack(from: origin, bearing: 0, speedKmh: 70, seconds: 25))
            XCTAssertEqual(events.filter { $0.event.isPre }.count, 1)
            XCTAssertEqual(events.filter { $0.event.isNear }.count, 1)
            XCTAssertEqual(events.contains { $0.event.isOverspeedStarted }, type == .fixed)
            XCTAssertEqual(events.contains { $0.event.isBeep }, type == .fixed)
            XCTAssertFalse(events.compactMap { timed in
                CameraAnnouncementPolicy.speech(for: CameraAlertResult(events: [timed.event], target: nil),
                    speedKmh: 70, settings: AlertSettings()).first?.text
            }.contains { $0.contains("自行新增") })
        }
    }

    func testHidingAnActiveCameraRemovesItFromNormalAndTunnelAlertsImmediately() throws {
        let camera = official()
        let engine = CameraAlertEngine(index: SpatialIndex(cameras: [camera]))
        let fix = VehicleFix(point: origin, speedMps: 20, course: 0, timestamp: t0)
        XCTAssertTrue(engine.process(fix).events.contains(where: \.isPre))
        var edits = UserCameraEdits()
        try edits.hide(camera)
        engine.replaceIndex(SpatialIndex(cameras: edits.apply(to: [camera])), preservingState: true)
        XCTAssertNil(engine.tick(now: t0.addingTimeInterval(4))?.target)
        let result = engine.process(VehicleFix(point: origin, speedMps: 20, course: 0,
                                              timestamp: t0.addingTimeInterval(5)))
        XCTAssertNil(result.target)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testUnrelatedEditPreservesPreNearOverspeedThrottleAndNoFixHistory() throws {
        let camera = official()
        let other = official("other", north: 2_000)
        let engine = CameraAlertEngine(index: SpatialIndex(cameras: [camera, other]))
        let initial = VehicleFix(point: origin, speedMps: 20, course: 0, timestamp: t0)
        XCTAssertTrue(engine.process(initial).events.contains(where: \.isPre))
        var edits = UserCameraEdits()
        try edits.modify(other, speedLimit: 40, direction: UserCameraDirection(axis: 45))
        engine.replaceIndex(SpatialIndex(cameras: edits.apply(to: [camera, other])), preservingState: true)
        XCTAssertEqual(engine.lastFix, initial)
        XCTAssertEqual(engine.currentCourse, 0)
        let same = engine.process(VehicleFix(point: origin, speedMps: 20, course: 0, timestamp: t0.addingTimeInterval(1)))
        XCTAssertTrue(same.events.isEmpty)
        XCTAssertEqual(same.target?.phase, .pre)
        XCTAssertEqual(same.target?.isOverspeed, true)
        let beep = engine.process(VehicleFix(point: origin, speedMps: 20, course: 0, timestamp: t0.addingTimeInterval(5)))
        XCTAssertEqual(beep.events, [.overspeedBeep])
        let nearPoint = GeoMath.destination(from: camera.point, bearing: 180, distance: 90)
        let near = engine.process(VehicleFix(point: nearPoint, speedMps: 20, course: 0,
                                            timestamp: t0.addingTimeInterval(6)))
        XCTAssertTrue(near.events.contains(where: \.isNear))
        engine.replaceIndex(SpatialIndex(cameras: [camera]), preservingState: true)
        let tunnel = try XCTUnwrap(engine.tick(now: t0.addingTimeInterval(9)))
        XCTAssertEqual(tunnel.target?.phase, .near)
        XCTAssertTrue(tunnel.events.isEmpty)
    }

    func testUnrelatedEditPreservesPassedCameraCooldown() throws {
        let camera = official()
        let other = official("other", north: 2_000)
        let engine = CameraAlertEngine(index: SpatialIndex(cameras: [camera, other]))
        let events = runAlerts(engine, straightTrack(from: origin, bearing: 0, speedKmh: 60, seconds: 22))
        XCTAssertEqual(events.filter { $0.event.isPassed }.count, 1)
        var edits = UserCameraEdits()
        try edits.hide(other)
        engine.replaceIndex(SpatialIndex(cameras: edits.apply(to: [camera, other])), preservingState: true)
        let returned = engine.process(VehicleFix(point: origin, speedMps: 20, course: 0,
                                                timestamp: t0.addingTimeInterval(25)))
        XCTAssertFalse(returned.events.contains { $0.isPre || $0.isNear })
        XCTAssertNil(returned.target)
    }

    func testEditingTheActiveTargetReplacesItsOldDirectionAndOverspeedThreshold() throws {
        let camera = official()
        let engine = CameraAlertEngine(index: SpatialIndex(cameras: [camera]))
        XCTAssertTrue(engine.process(VehicleFix(point: origin, speedMps: 20, course: 0, timestamp: t0))
            .events.contains(where: \.isOverspeedStarted))
        var edits = UserCameraEdits()
        try edits.modify(camera, speedLimit: 40, direction: UserCameraDirection(heading: 90))
        engine.replaceIndex(SpatialIndex(cameras: edits.apply(to: [camera])), preservingState: true)
        let wrongWay = engine.process(VehicleFix(point: origin, speedMps: 20, course: 0,
                                                timestamp: t0.addingTimeInterval(1)))
        XCTAssertNil(wrongWay.target)
        XCTAssertTrue(wrongWay.events.isEmpty)
        let west = GeoMath.destination(from: camera.point, bearing: 270, distance: 280)
        let rightWay = engine.process(VehicleFix(point: west, speedMps: 20, course: 90,
                                                timestamp: t0.addingTimeInterval(2)))
        XCTAssertTrue(rightWay.events.contains(where: \.isPre))
        XCTAssertTrue(rightWay.events.contains(.overspeedStarted(limit: 40, speedKmh: 72)))
        XCTAssertEqual(rightWay.target?.camera.speedLimit, 40)
        XCTAssertEqual(rightWay.target?.camera.heading, 90)
    }

    func testEditsDuringActiveSectionKeepStartCountdownAndOverspeedCooldown() throws {
        let start = GeoMath.destination(from: origin, bearing: 0, distance: 200)
        let end = GeoMath.destination(from: start, bearing: 0, distance: 3_000)
        let section = SpeedSection(id: "s", name: "測試區間", start: start, end: end,
                                   lengthMeters: 3_000, speedLimit: 40)
        let tracker = SectionSpeedTracker(sections: [section])
        let camera = official(north: 1_000)
        let engine = CameraAlertEngine(index: SpatialIndex(cameras: [camera]))
        var before: SectionStatus?
        let fixes = straightTrack(from: origin, bearing: 0, speedKmh: 70, seconds: 18)
        for fix in fixes {
            before = tracker.process(fix).status
            _ = engine.process(fix)
        }
        let active = try XCTUnwrap(before)
        var edits = UserCameraEdits()
        try edits.hide(camera)
        var capture = QuickCameraCapture()
        let currentFix = try XCTUnwrap(fixes.last)
        let captured = try capture.capture(fix: currentFix, lastHeadingFix: currentFix,
            edits: &edits, at: currentFix.timestamp)
        engine.replaceIndex(SpatialIndex(cameras: edits.apply(to: [camera])), preservingState: true)
        engine.markPassed(captured.camera, at: currentFix.timestamp)
        let next = straightTrack(from: origin, bearing: 0, speedKmh: 70, seconds: 19).last!
        let after = tracker.process(next)
        XCTAssertEqual(after.status?.startTime, active.startTime)
        XCTAssertEqual(after.status?.earliestExit, active.earliestExit)
        XCTAssertEqual(after.status?.remainingSeconds ?? 0, active.remainingSeconds - 1, accuracy: 0.001)
        XCTAssertFalse(after.events.contains {
            if case .entered = $0 { return true }
            if case .overspeedStarted = $0 { return true }
            if case .overspeedBeep = $0 { return true }
            return false
        })
    }

    func testCoverageWarningSharesGeometryButDoesNotChangeFixedCameraBehavior() {
        let camera = added()
        let engine = CameraAlertEngine(index: SpatialIndex(cameras: [camera]))
        engine.sections = [SpeedSection(id: "s", name: "區間", start: origin, end: camera.point,
                                        lengthMeters: 280, speedLimit: 50)]
        XCTAssertNotNil(engine.coveringSection(for: camera))
        XCTAssertFalse(engine.isCoveredBySection(camera))
        var sectionCamera = camera
        sectionCamera.type = .section
        XCTAssertTrue(engine.isCoveredBySection(sectionCamera))
        XCTAssertTrue(engine.process(VehicleFix(point: origin, speedMps: 20, course: 0, timestamp: t0))
            .events.contains(where: \.isPre))
    }

    private func fixtureEdits() throws -> UserCameraEdits {
        let values: [(CameraType, Double?, Double?, Int?)] = [
            (.fixed, 240.6, nil, 50), (.fixed, 0, nil, 80),
            (.redLight, nil, 90, 0), (.fixed, nil, 0, 30),
            (.fixed, nil, 45, 50), (.redLight, nil, 135, 0),
            (.fixed, nil, nil, 110), (.redLight, 315, nil, 0),
            (.fixed, 240.61066, nil, nil),
        ]
        var edits = UserCameraEdits()
        for (index, value) in values.enumerated() {
            var camera = added(index + 1, type: value.0, heading: value.1, axis: value.2, limit: value.3)
            camera.lat = 25.03 + Double(index) * 0.001
            camera.lon = 121.565
            camera.address = index == 0 ? "測試路口,東側\"桿\"" : "測試路\(index + 1)號"
            try edits.add(camera)
            edits.addedOn[camera.id] = "2026-11-17"
        }
        return edits
    }

    func testQuickCaptureUsesCurrentFixExactHeadingUnknownLimitAndExistingStorage() throws {
        let moving = VehicleFix(point: origin, speedMps: 8 / 3.6, course: 240.61066, timestamp: t0)
        var stopped = moving
        stopped.speedMps = 0
        stopped.course = nil
        var capture = QuickCameraCapture()
        var edits = UserCameraEdits()
        let result = try capture.capture(fix: stopped, lastHeadingFix: moving, edits: &edits, at: t0)
        let camera = result.camera
        XCTAssertTrue(result.isNew)
        XCTAssertEqual(camera.point, stopped.point)
        XCTAssertEqual(camera.type, .fixed)
        XCTAssertEqual(camera.heading, 240.61066)
        XCTAssertNil(camera.axis)
        XCTAssertNil(camera.speedLimit)
        XCTAssertEqual(camera.address, "自行新增（25.03000, 121.56500）")
        XCTAssertEqual(camera.source, "自行新增")
        XCTAssertEqual(camera.positionMethod, "user")
        XCTAssertTrue(camera.id.hasPrefix("user-"))
        try inTemporaryDirectory { directory in
            let file = UserCameraEditsFile(url: directory.appendingPathComponent("userCameraEdits.v1.json"))
            try file.save(edits)
            XCTAssertEqual(try file.load().edits.apply(to: []), [camera])
        }
        for headingFix in [nil, VehicleFix(point: origin, speedMps: 7.9 / 3.6, course: 0, timestamp: t0)] {
            var unknownCapture = QuickCameraCapture()
            var unknownEdits = UserCameraEdits()
            let unknown = try unknownCapture.capture(fix: stopped, lastHeadingFix: headingFix,
                edits: &unknownEdits, at: t0)
            XCTAssertNil(unknown.camera.heading)
            XCTAssertNil(unknown.camera.axis)
        }
    }

    func testQuickCaptureRejectsUnreliableAndStaleFixesWithoutSaving() throws {
        let good = VehicleFix(point: origin, speedMps: 20, course: 0, timestamp: t0)
        for bad in [
            VehicleFix(point: origin, speedMps: -1, course: 0, timestamp: t0),
            VehicleFix(point: origin, speedMps: 20, course: 0, horizontalAccuracy: 101, timestamp: t0),
            VehicleFix(point: origin, speedMps: .infinity, course: 0, timestamp: t0),
            VehicleFix(point: origin, speedMps: 20, course: 0, timestamp: t0.addingTimeInterval(-2.5)),
        ] {
            var capture = QuickCameraCapture()
            var edits = UserCameraEdits()
            XCTAssertThrowsError(try capture.capture(fix: bad, lastHeadingFix: good, edits: &edits, at: t0))
            XCTAssertTrue(edits.isEmpty)
            XCTAssertNil(capture.confirmationID)
        }
        XCTAssertTrue(QuickCameraCapture.hasCurrentFix(good, at: t0.addingTimeInterval(2.49)))
        XCTAssertFalse(QuickCameraCapture.hasCurrentFix(nil, at: t0))
    }

    func testQuickCaptureLocksUntilCardDisappearsOrThreeSecondsWhicheverIsLonger() throws {
        var capture = QuickCameraCapture()
        var edits = UserCameraEdits()
        let fix = VehicleFix(point: origin, speedMps: 20, course: 0, timestamp: t0)
        _ = try capture.capture(fix: fix, lastHeadingFix: fix, edits: &edits, at: t0)
        XCTAssertThrowsError(try capture.capture(fix: fix, lastHeadingFix: fix, edits: &edits, at: t0))
        capture.expireConfirmation(at: t0.addingTimeInterval(7.99))
        XCTAssertNotNil(capture.confirmationID)
        XCTAssertFalse(capture.canCapture(at: t0.addingTimeInterval(7.99)))
        capture.expireConfirmation(at: t0.addingTimeInterval(8))
        XCTAssertNil(capture.confirmationID)
        XCTAssertTrue(capture.canCapture(at: t0.addingTimeInterval(8)))

        var next = fix
        next.timestamp = t0.addingTimeInterval(8)
        _ = try capture.capture(fix: next, lastHeadingFix: fix, edits: &edits, at: next.timestamp)
        capture.dismissConfirmation()
        XCTAssertFalse(capture.canCapture(at: t0.addingTimeInterval(10.99)))
        XCTAssertTrue(capture.canCapture(at: t0.addingTimeInterval(11)))
        XCTAssertEqual(edits.added.count, 1)
    }

    func testQuickCaptureReusesNearbyCapturedPointButNotOneOutsideFiftyMetersAndUndoAllowsNew() throws {
        var capture = QuickCameraCapture()
        var edits = UserCameraEdits()
        func fix(_ distance: Double, _ seconds: Double) -> VehicleFix {
            VehicleFix(point: GeoMath.destination(from: origin, bearing: 0, distance: distance),
                speedMps: 20, course: 0, timestamp: t0.addingTimeInterval(seconds))
        }
        let first = try capture.capture(fix: fix(0, 0), lastHeadingFix: fix(0, 0), edits: &edits, at: t0)
        var changed = first.camera
        changed.speedLimit = 60
        try edits.updateAdded(changed)
        capture.expireConfirmation(at: t0.addingTimeInterval(8))
        let reused = try capture.capture(fix: fix(49.99, 8), lastHeadingFix: fix(49.99, 8),
            edits: &edits, at: t0.addingTimeInterval(8))
        XCTAssertFalse(reused.isNew)
        XCTAssertEqual(reused.camera, changed)
        XCTAssertEqual(capture.confirmationID, first.camera.id)
        XCTAssertEqual(edits.added.count, 1)
        capture.expireConfirmation(at: t0.addingTimeInterval(16))
        let second = try capture.capture(fix: fix(50.01, 16), lastHeadingFix: nil,
            edits: &edits, at: t0.addingTimeInterval(16))
        XCTAssertTrue(second.isNew)
        XCTAssertNotEqual(second.camera.id, first.camera.id)
        XCTAssertEqual(edits.added.count, 2)
        edits.deleteAdded(id: second.camera.id)
        capture.forget(id: second.camera.id)
        XCTAssertNil(capture.confirmationID)
        XCTAssertFalse(edits.apply(to: []).contains { $0.id == second.camera.id })
        let third = try capture.capture(fix: fix(50.01, 19), lastHeadingFix: nil,
            edits: &edits, at: t0.addingTimeInterval(19))
        XCTAssertTrue(third.isNew)
        XCTAssertNotEqual(third.camera.id, second.camera.id)
    }

    func testQuickCapturePassedCooldownSurvivesSpeedAndAddressUpdatesWithoutResettingOtherTarget() throws {
        let other = official()
        let engine = CameraAlertEngine(index: SpatialIndex(cameras: [other]))
        let initial = VehicleFix(point: origin, speedMps: 20, course: 0, timestamp: t0)
        XCTAssertTrue(engine.process(initial).events.contains(where: \.isPre))
        var capture = QuickCameraCapture()
        var edits = UserCameraEdits()
        let result = try capture.capture(fix: initial, lastHeadingFix: initial, edits: &edits, at: t0)
        engine.replaceIndex(SpatialIndex(cameras: edits.apply(to: [other])), preservingState: true)
        engine.markPassed(result.camera, at: t0)
        var camera = result.camera
        camera.speedLimit = 40
        try edits.updateAdded(camera)
        XCTAssertTrue(try edits.resolveAddedAddress(id: camera.id, point: camera.point, address: "測試路1號"))
        engine.replaceIndex(SpatialIndex(cameras: edits.apply(to: [other])), preservingState: true)
        for second in 1...5 {
            var next = initial
            next.timestamp = t0.addingTimeInterval(Double(second))
            let output = engine.process(next)
            XCTAssertEqual(output.target?.camera.id, other.id)
            XCTAssertEqual(output.target?.phase, .pre)
            XCTAssertEqual(output.events, second == 5 ? [.overspeedBeep] : [])
        }
        XCTAssertEqual(engine.lastFix?.timestamp, t0.addingTimeInterval(5))
        XCTAssertEqual(engine.tick(now: t0.addingTimeInterval(8))?.target?.camera.id, other.id)
        let far = GeoMath.destination(from: origin, bearing: 0, distance: 1_100)
        _ = engine.process(VehicleFix(point: far, speedMps: 20, course: 0, timestamp: t0.addingTimeInterval(60)))
        let approach = GeoMath.destination(from: origin, bearing: 180, distance: 280)
        let again = engine.process(VehicleFix(point: approach, speedMps: 20, course: 0,
            timestamp: t0.addingTimeInterval(90)))
        XCTAssertEqual(again.target?.camera.id, camera.id)
        XCTAssertTrue(again.events.contains(where: \.isPre))
        XCTAssertTrue(again.events.contains(where: \.isOverspeedStarted))
    }

    func testUnsetFixedCameraAlertsTwiceWithoutBeepsThenUsesFilledLimitAndUndoRemovesIt() throws {
        let camera = added(limit: nil)
        var edits = UserCameraEdits()
        try edits.add(camera)
        let engine = CameraAlertEngine(index: SpatialIndex(cameras: edits.apply(to: [])))
        let events = runAlerts(engine, straightTrack(from: origin, bearing: 0, speedKmh: 70, seconds: 13))
        XCTAssertEqual(events.filter { $0.event.isPre }.count, 1)
        XCTAssertEqual(events.filter { $0.event.isNear }.count, 1)
        XCTAssertFalse(events.contains { $0.event.isOverspeedStarted || $0.event.isBeep })
        var filled = camera
        filled.speedLimit = 40
        try edits.updateAdded(filled)
        engine.replaceIndex(SpatialIndex(cameras: edits.apply(to: [])), preservingState: true)
        let fix = try XCTUnwrap(straightTrack(from: origin, bearing: 0, speedKmh: 70, seconds: 14).last)
        XCTAssertTrue(engine.process(fix).events.contains(where: \.isOverspeedStarted))
        edits.deleteAdded(id: camera.id)
        engine.replaceIndex(SpatialIndex(cameras: edits.apply(to: [])), preservingState: true)
        XCTAssertNil(engine.index.camera(id: camera.id))
        XCTAssertNil(engine.tick(now: fix.timestamp.addingTimeInterval(3))?.target)
        XCTAssertTrue(engine.process(fix).events.isEmpty)
        XCTAssertTrue(edits.isEmpty)
    }

    func testQuickCaptureLateAddressKeepsLatestFieldsAndCannotUpdateAnotherOrDeletedPoint() throws {
        let camera = UserCameraEdits.newCamera(at: origin, speedLimit: nil, heading: 90)
        var edits = UserCameraEdits()
        try edits.add(camera)
        var updated = camera
        updated.speedLimit = 70
        try edits.updateAdded(updated)
        XCTAssertFalse(try edits.resolveAddedAddress(id: "another-id", point: origin, address: "錯誤路名"))
        XCTAssertFalse(try edits.resolveAddedAddress(id: camera.id,
            point: GeoMath.destination(from: origin, bearing: 0, distance: 10), address: "錯誤路名"))
        XCTAssertTrue(try edits.resolveAddedAddress(id: camera.id, point: origin, address: " 正確路名 "))
        XCTAssertEqual(edits.added.first?.speedLimit, 70)
        XCTAssertEqual(edits.added.first?.heading, 90)
        XCTAssertEqual(edits.added.first?.address, "正確路名")
        XCTAssertFalse(try edits.resolveAddedAddress(id: camera.id, point: origin, address: "舊結果"))
        edits.deleteAdded(id: camera.id)
        XCTAssertFalse(try edits.resolveAddedAddress(id: camera.id, point: origin, address: "已刪除"))
        XCTAssertTrue(edits.isEmpty)
    }

    func testCSVExportMatchesCrossLanguageFixtureIncludingEscapingAndLossyAxes() throws {
        let edits = try fixtureEdits()
        let exported = try UserCameraExport(edits: edits, originals: [])
        let url = try XCTUnwrap(Bundle.module.url(forResource: "user_cameras_export", withExtension: "csv",
                                                 subdirectory: "Fixtures"))
        XCTAssertEqual(exported.csv, try String(contentsOf: url, encoding: .utf8))
        let review = try JSONDecoder().decode(UserCameraExport.Review.self, from: exported.json)
        XCTAssertEqual(review.added, edits.added)
        XCTAssertEqual(review.added[4].axis, 45)
        XCTAssertEqual(review.added[5].axis, 135)
        XCTAssertEqual(review.added[0].heading, 240.6)
        XCTAssertNil(review.added[8].speedLimit)
        XCTAssertEqual(review.speedLimitUnsetIDs, [edits.added[8].id])
        XCTAssertTrue(review.notes.contains(UserCameraExport.unsetSpeedLimitNote))
        XCTAssertFalse(review.notes.isEmpty)
    }

    func testReviewExportIncludesMissingIDOriginalNewValueAndHiddenSnapshot() throws {
        let camera = official()
        let hidden = official("hidden")
        var edits = UserCameraEdits()
        try edits.modify(camera, speedLimit: 40, direction: UserCameraDirection())
        try edits.hide(hidden)
        let exported = try UserCameraExport(edits: edits, originals: [])
        let review = try JSONDecoder().decode(UserCameraExport.Review.self, from: exported.json)
        let change = try XCTUnwrap(review.modified.first)
        XCTAssertEqual(change.id, camera.id)
        XCTAssertEqual(change.shortAddress, camera.shortAddress)
        XCTAssertEqual(change.lat, camera.lat)
        XCTAssertEqual(change.original, camera)
        XCTAssertEqual(change.newValue?.speedLimit, 40)
        XCTAssertNil(change.newValue?.heading)
        XCTAssertTrue(change.missingFromDatabase)
        XCTAssertEqual(review.hidden.first?.original, hidden)
        XCTAssertNil(review.hidden.first?.newValue)
        XCTAssertEqual(exported.csv, UserCameraExport.csvHeader + "\n")
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: exported.json) as? [String: Any])
        let hiddenRows = try XCTUnwrap(raw["hidden"] as? [[String: Any]])
        XCTAssertTrue(hiddenRows[0]["newValue"] is NSNull)
    }

    func testCSVNorthWrapAndNegativeZeroStayValidExplicitDirections() throws {
        for heading in [-0.0, 359.999999999999] {
            var edits = UserCameraEdits()
            try edits.add(added(heading: heading))
            let exported = try UserCameraExport(edits: edits, originals: [])
            XCTAssertTrue(exported.csv.contains(",0°,50,測速照相,"))
            let review = try JSONDecoder().decode(UserCameraExport.Review.self, from: exported.json)
            XCTAssertEqual(review.added[0].heading, heading)
        }
    }
}
