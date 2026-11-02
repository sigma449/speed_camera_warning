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
    }

    func testSectionTexts() {
        let s = SpeedSection(id: "s", name: "x", start: origin, end: origin, lengthMeters: 3_200, speedLimit: 60)
        XCTAssertEqual(AnnouncementFormatter.sectionEntered(section: s, minimumSeconds: 198),
                       "進入區間測速，全長3.2公里，速限60，至少需要198秒")
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
        XCTAssertEqual(db.cameras.count, 10)
        XCTAssertTrue(db.cameras.contains { $0.type == .redLightSpeed })
        XCTAssertTrue(db.cameras.contains { $0.heading == nil })
        XCTAssertEqual(db.sections.first?.lengthEstimated, true)
        XCTAssertEqual(Set(db.cameras.map(\.id)).count, db.cameras.count)
    }

    func testSettingsDecodeWithMissingKeysUsesDefaults() throws {
        let json = #"{"generalPreDistance": 350, "vehicleMode": "motorcycle"}"#
        let s = try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.generalPreDistance, 350)
        XCTAssertEqual(s.vehicleMode, .motorcycle)
        XCTAssertEqual(s.fastPreDistance, 600)
        XCTAssertEqual(s.overspeedBeepInterval, 3)
        // 往返編碼
        let again = try JSONDecoder().decode(AlertSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(again, s)
    }

    func testThresholdSelection() {
        let s = AlertSettings()
        XCTAssertEqual(s.thresholds(speedLimit: 50, currentSpeedKmh: 100).pre, 300)
        XCTAssertEqual(s.thresholds(speedLimit: 80, currentSpeedKmh: 30).pre, 600)
        XCTAssertEqual(s.thresholds(speedLimit: nil, currentSpeedKmh: 85).near, 200)
        XCTAssertEqual(s.thresholds(speedLimit: nil, currentSpeedKmh: 60).near, 100)
    }
}
