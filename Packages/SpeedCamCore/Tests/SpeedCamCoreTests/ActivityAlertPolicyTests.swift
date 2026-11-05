import XCTest
@testable import SpeedCamCore

final class ActivityAlertPolicyTests: XCTestCase {
    private let camera = Camera(id: "c", type: .fixed, lat: 25, lon: 121, heading: 0, speedLimit: 50)
    private let section = SpeedSection(id: "s-f", name: "測試區間", start: GeoPoint(lat: 25, lon: 121),
                                       end: GeoPoint(lat: 25.1, lon: 121), lengthMeters: 11_000, speedLimit: 60)

    private func alert(_ cameraEvents: [CameraAlertEvent] = [], _ sectionEvents: [SectionEvent] = [],
                       cameraOverspeedActive: Bool = false) -> ActivityAlertContent? {
        ActivityAlertPolicy.alert(cameraEvents: cameraEvents, sectionEvents: sectionEvents,
                                  cameraOverspeedActive: cameraOverspeedActive)
    }

    func testRepeatingAndClosingEventsDoNotAlert() {
        XCTAssertNil(alert())
        XCTAssertNil(alert([.passed(camera: camera), .overspeedBeep, .overspeedEnded]))
        XCTAssertNil(alert([], [.remaining(seconds: 60), .overspeedBeep, .overspeedEnded,
                                .completed(section: section, averageKmh: 55, withinLimit: true),
                                .aborted(section: section)]))
    }

    func testCameraAlertsIncludeDistanceAndLimit() {
        XCTAssertEqual(alert([.preAlert(camera: camera, distance: 296)]),
                       ActivityAlertContent(title: "測速照相", body: "前方300公尺，速限50"))
        XCTAssertEqual(alert([.nearAlert(camera: camera, distance: 104)]),
                       ActivityAlertContent(title: "測速照相", body: "前方100公尺，速限50"))
    }

    func testCameraThatDoesNotEnforceSpeedOmitsLimit() {
        let red = Camera(id: "r", type: .redLight, lat: 25, lon: 121, heading: 0, speedLimit: 50)
        XCTAssertEqual(alert([.nearAlert(camera: red, distance: 100)]),
                       ActivityAlertContent(title: "闖紅燈照相", body: "前方100公尺"))
    }

    func testSectionAlerts() {
        XCTAssertEqual(alert([], [.entered(section: section, minimumSeconds: 680)]),
                       ActivityAlertContent(title: "進入區間測速", body: "速限60，至少需要680秒"))
        XCTAssertEqual(alert([], [.zeroReached]),
                       ActivityAlertContent(title: "區間時間已到", body: "可依速限行駛"))
        XCTAssertEqual(alert([], [.overspeedStarted(threshold: 70)]),
                       ActivityAlertContent(title: "區間測速超速", body: "車速超過70"))
    }

    func testSectionOverspeedIsSkippedWhileCameraOverspeedIsActive() {
        XCTAssertNil(alert([], [.overspeedStarted(threshold: 70)], cameraOverspeedActive: true))
    }

    func testOnlyMostImportantEventAlerts() {
        let pre = CameraAlertEvent.preAlert(camera: camera, distance: 300)
        let near = CameraAlertEvent.nearAlert(camera: camera, distance: 100)
        let speeding = CameraAlertEvent.overspeedStarted(limit: 50, speedKmh: 63)
        let entered = SectionEvent.entered(section: section, minimumSeconds: 680)

        XCTAssertEqual(alert([pre, speeding])?.title, "您已超速")
        XCTAssertEqual(alert([near], [.overspeedStarted(threshold: 70)])?.title, "測速照相")
        XCTAssertEqual(alert([], [.overspeedStarted(threshold: 70), entered])?.title, "區間測速超速")
        XCTAssertEqual(alert([], [.zeroReached, entered])?.title, "進入區間測速")
        XCTAssertEqual(alert([pre], [.zeroReached])?.title, "區間時間已到")
    }

    /// 實際跑一段軌跡：速限內通過一支照相機，只會跳預告和近距兩則，不會每秒都跳。
    func testDrivingPastCameraAlertsOncePerStage() {
        let point = GeoMath.destination(from: origin, bearing: 0, distance: 2_000)
        let cam = Camera(id: "cam", type: .fixed, lat: point.lat, lon: point.lon, heading: 0,
                         speedLimit: 50, address: "測試路")
        let engine = CameraAlertEngine(index: SpatialIndex(cameras: [cam]))
        let bodies = straightTrack(from: origin, bearing: 0, speedKmh: 50, seconds: 200).compactMap { fix in
            ActivityAlertPolicy.alert(cameraEvents: engine.process(fix).events, sectionEvents: [])?.body
        }
        XCTAssertEqual(bodies.count, 2, "\(bodies)")
        XCTAssertTrue(bodies.allSatisfy { $0.hasPrefix("前方") && $0.hasSuffix("公尺，速限50") }, "\(bodies)")
    }

    func testAlertsSettingDefaultsToOnAndOldSavedSettingsStayOn() throws {
        XCTAssertTrue(AlertSettings().liveActivityAlertsEnabled)
        let saved = try JSONDecoder().decode(AlertSettings.self, from: Data(#"{"liveActivityEnabled":true}"#.utf8))
        XCTAssertTrue(saved.liveActivityAlertsEnabled)
    }
}
