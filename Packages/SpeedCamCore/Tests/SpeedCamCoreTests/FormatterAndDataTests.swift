import XCTest
@testable import SpeedCamCore

final class AnnouncementFormatterTests: XCTestCase {
    func testSpokenDistance() {
        XCTAssertEqual(AnnouncementFormatter.spokenDistance(296), "300公尺")
        XCTAssertEqual(AnnouncementFormatter.spokenDistance(104), "100公尺")
        XCTAssertEqual(AnnouncementFormatter.spokenDistance(1_000), "1公里")
        XCTAssertEqual(AnnouncementFormatter.spokenDistance(1_540), "1.5公里")
        XCTAssertEqual(AnnouncementFormatter.spokenDistance(3), "10公尺")
    }

    func testDisplayDistance() {
        XCTAssertEqual(AnnouncementFormatter.displayDistance(283), "280m")
        XCTAssertEqual(AnnouncementFormatter.displayDistance(1_234), "1.2km")
    }

    func testCameraAlertText() {
        let cam = Camera(id: "x", type: .fixed, lat: 25, lon: 121, heading: 0, speedLimit: 50)
        XCTAssertEqual(AnnouncementFormatter.cameraAlert(camera: cam, announcedDistance: 300),
                       "前方300公尺，測速照相，速限50")
        let red = Camera(id: "y", type: .redLight, lat: 25, lon: 121, heading: 0, speedLimit: 50)
        XCTAssertEqual(AnnouncementFormatter.cameraAlert(camera: red, announcedDistance: 100),
                       "前方100公尺，闖紅燈照相")
        let up = Camera(id: "e", type: .fixed, lat: 25, lon: 121, speedLimit: 80, level: .elevated)
        XCTAssertEqual(AnnouncementFormatter.cameraAlert(camera: up, announcedDistance: 300),
                       "前方300公尺，高架測速照相，速限80")
        let down = Camera(id: "s", type: .fixed, lat: 25, lon: 121, heading: 90, speedLimit: 40, level: .surface)
        XCTAssertEqual(AnnouncementFormatter.cameraAlert(camera: down, announcedDistance: 100),
                       "前方100公尺，平面測速照相，速限40")
    }

    func testRoadLevelDecodingToleratesUnknownValues() throws {
        let json = #"[{"id":"a","type":"fixed","lat":25,"lon":121,"address":"x","level":"elevated"},"#
            + #"{"id":"b","type":"fixed","lat":25,"lon":121,"address":"y","level":"tunnel"},"#
            + #"{"id":"c","type":"fixed","lat":25,"lon":121,"address":"z"}]"#
        let cams = try JSONDecoder().decode([Camera].self, from: Data(json.utf8))
        XCTAssertEqual(cams.map(\.level), [.elevated, .unknown, nil])
        XCTAssertEqual(cams.map(\.displayTypeName), ["高架測速照相", "測速照相", "測速照相"])
    }

    func testSectionTexts() {
        let s = SpeedSection(id: "s", name: "x", start: origin, end: origin, lengthMeters: 3_200, speedLimit: 60)
        XCTAssertEqual(AnnouncementFormatter.sectionEntered(section: s, minimumSeconds: 198),
                       "進入區間測速，全長3.2公里，速限60，至少需要198秒")
        XCTAssertEqual(AnnouncementFormatter.sectionEntered(section: s, minimumSeconds: 238, effectiveLimitKmh: 50),
                       "進入區間測速，全長3.2公里，速限60，至少需要238秒",
                       "計算時速沒有高於速限時不念")
        let bx = SpeedSection(id: "b", name: "北宜", start: origin, end: origin, lengthMeters: 4_100, speedLimit: 40)
        XCTAssertEqual(AnnouncementFormatter.sectionEntered(section: bx, minimumSeconds: 304, effectiveLimitKmh: 50),
                       "進入區間測速，全長4.1公里，速限40，以時速50計算，至少需要304秒")
        XCTAssertEqual(AnnouncementFormatter.sectionOverspeed(threshold: 50), "區間測速，車速超過50")
        XCTAssertEqual(AnnouncementFormatter.sectionRemaining(seconds: 120), "區間測速，還有120秒")
        XCTAssertEqual(AnnouncementFormatter.sectionCompleted(averageKmh: 58.4, withinLimit: true), "區間測速結束，平均時速58")
    }

    func testManeuverText() {
        XCTAssertEqual(AnnouncementFormatter.maneuver(instruction: "右轉進入忠孝東路", distance: 500), "500公尺後，右轉進入忠孝東路")
        XCTAssertEqual(AnnouncementFormatter.maneuver(instruction: "右轉進入忠孝東路", distance: nil), "右轉進入忠孝東路")
    }
}

final class ToneGeneratorTests: XCTestCase {
    func testWavHeaderAndLength() {
        let data = ToneGenerator.wavData(frequency: 1_000, duration: 0.1, sampleRate: 8_000)
        XCTAssertEqual(data.count, 44 + 800 * 2)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
    }

    func testDoubleBeepIsLongerThanSingle() {
        XCTAssertGreaterThan(ToneGenerator.doubleBeep(sampleRate: 8_000).count,
                             ToneGenerator.wavData(duration: 0.09, sampleRate: 8_000).count)
    }
}

final class DatabaseTests: XCTestCase {
    func testDecodeSampleDatabase() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample_db", withExtension: "json", subdirectory: "Fixtures"))
        let db = try CameraDatabase.decode(from: Data(contentsOf: url))
        XCTAssertEqual(db.cameras.count, 3)
        XCTAssertEqual(db.cameras[0].type, .fixed)
        XCTAssertNil(db.cameras[2].heading)
        XCTAssertEqual(db.sections.count, 1)
        XCTAssertEqual(db.sections[0].speedLimit, 90)
        XCTAssertFalse(db.sources.isEmpty)
    }

    /// Python 資料處理腳本產生的檔案（data-pipeline/build_cameras.py）必須能被 App 解碼。
    func testDecodePipelineOutput() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "pipeline_output", withExtension: "json", subdirectory: "Fixtures"))
        let db = try CameraDatabase.decode(from: Data(contentsOf: url))
        XCTAssertEqual(db.cameras.count, 11)
        XCTAssertTrue(db.cameras.contains { $0.type == .redLightSpeed })
        XCTAssertTrue(db.cameras.contains { $0.type == .section && $0.axis == 0 && $0.heading == nil })
        XCTAssertTrue(db.cameras.contains { $0.heading == nil })
        XCTAssertEqual(db.sections.map(\.id), ["s1-f", "s1-r"])
        XCTAssertEqual(db.sections.first?.lengthEstimated, false)
        XCTAssertEqual(db.sections.first?.startHeading, 5)
        XCTAssertEqual(db.sections.last?.startHeading, 185)
        XCTAssertEqual(db.sections.first?.end, db.sections.last?.start)
        XCTAssertEqual(Set(db.cameras.map(\.id)).count, db.cameras.count)
        // 沿路座標：有 path 的照著畫，沒有的畫起終點直線
        XCTAssertEqual(db.sections.first?.path?.count, 3)
        XCTAssertEqual(db.sections.first?.displayPath[1], GeoPoint(lat: 25.015, lon: 121.502))
        XCTAssertNil(db.sections.last?.path)
        XCTAssertEqual(db.sections.last?.displayPath, [GeoPoint(lat: 25.03, lon: 121.5), GeoPoint(lat: 25.0, lon: 121.5)])
    }

    func testSectionPathRoundTripsAsCompactArrays() throws {
        let path = [GeoPoint(lat: 24.9, lon: 121.6), GeoPoint(lat: 24.91, lon: 121.61), GeoPoint(lat: 24.92, lon: 121.6)]
        let section = SpeedSection(id: "p", name: "路形", start: path[0], end: path[2], lengthMeters: 2_500,
                                   speedLimit: 40, path: path)
        let data = try JSONEncoder().encode(section)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("[24.91,121.61]"), json)
        XCTAssertEqual(try JSONDecoder().decode(SpeedSection.self, from: data), section)
        // 壞掉的 path（少於兩點）視為沒有
        let broken = #"{"id":"b","name":"x","start":{"lat":25,"lon":121},"end":{"lat":25.01,"lon":121},"lengthMeters":1000,"speedLimit":50,"path":[[25,121]]}"#
        let decoded = try JSONDecoder().decode(SpeedSection.self, from: Data(broken.utf8))
        XCTAssertNil(decoded.path)
        XCTAssertFalse(decoded.lengthEstimated)
        XCTAssertEqual(decoded.displayPath.count, 2)
    }

    func testSettingsDecodeWithMissingKeysUsesDefaults() throws {
        let json = #"{"generalPreDistance": 350, "vehicleMode": "motorcycle"}"#
        let s = try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.generalPreDistance, 350)
        XCTAssertEqual(s.vehicleMode, .motorcycle)
        XCTAssertEqual(s.fastPreDistance, 600)
        XCTAssertEqual(s.overspeedBeepInterval, 3)
        XCTAssertEqual(s.sectionToleranceKmh, 10)
        XCTAssertEqual(s.sectionEffectiveLimit(40), 50)
        XCTAssertEqual(s.sectionToleranceOverrides, [:])
        // 往返編碼
        let again = try JSONDecoder().decode(AlertSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(again, s)
    }

    func testToleranceOverridesDecodeAndClamp() throws {
        let json = #"{"sectionToleranceKmh": 10, "sectionToleranceOverrides": {"beiyi-1": 20, "bad": 99}}"#
        let s = try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.sectionTolerance(forGroup: "beiyi-1"), 20)
        XCTAssertEqual(s.sectionTolerance(forGroup: "bad"), 20, "超過上限 20 會被夾住")
        XCTAssertEqual(s.sectionTolerance(forGroup: "none"), 10)
        XCTAssertEqual(s.sectionTolerance(forGroup: nil), 10)
    }

    func testThresholdSelection() {
        let s = AlertSettings()
        XCTAssertEqual(s.thresholds(speedLimit: 50, currentSpeedKmh: 100).pre, 300)
        XCTAssertEqual(s.thresholds(speedLimit: 80, currentSpeedKmh: 30).pre, 600)
        XCTAssertEqual(s.thresholds(speedLimit: nil, currentSpeedKmh: 85).near, 200)
        XCTAssertEqual(s.thresholds(speedLimit: nil, currentSpeedKmh: 60).near, 100)
    }
}
