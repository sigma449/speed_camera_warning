import XCTest
@testable import SpeedCamCore

final class NavigationCameraLeadTests: XCTestCase {
    private let camera = Camera(id: "lead", type: .fixed, lat: 25, lon: 121.5, speedLimit: 50)

    private func progress(turnIn meters: Double, offRoute: Bool = false) -> RouteProgress {
        RouteProgress(nextStepIndex: 1, nextInstruction: "右轉進入忠孝東路", distanceToNextManeuver: meters,
                      distanceRemaining: 5_000, distanceFromRoute: offRoute ? 80 : 0, isOffRoute: offRoute)
    }

    private func target(_ phase: AlertPhase, overspeed: Bool = false) -> CameraTarget {
        CameraTarget(camera: camera, distance: phase == .near ? 90 : 280, phase: phase, isOverspeed: overspeed)
    }

    func testPreAnnouncementKeepsNavigationAsLead() {
        XCTAssertEqual(NavigationCameraLead.decide(progress: progress(turnIn: 1_200), target: target(.pre)), .navigation)
        XCTAssertEqual(NavigationCameraLead.decide(progress: progress(turnIn: 1_200), target: target(.approaching)),
                       .navigation)
    }

    func testNearCameraBecomesLeadWhenTurnIsFar() {
        XCTAssertEqual(NavigationCameraLead.decide(progress: progress(turnIn: 1_200), target: target(.near)), .camera)
        XCTAssertEqual(NavigationCameraLead.decide(progress: progress(turnIn: 100.5), target: target(.near)), .camera)
    }

    func testTurnWithin100MetersBeatsNearCamera() {
        XCTAssertEqual(NavigationCameraLead.decide(progress: progress(turnIn: 100), target: target(.near)), .navigation)
        XCTAssertEqual(NavigationCameraLead.decide(progress: progress(turnIn: 30), target: target(.near)), .navigation)
    }

    func testOverspeedBeatsEverything() {
        XCTAssertEqual(NavigationCameraLead.decide(progress: progress(turnIn: 30), target: target(.near, overspeed: true)),
                       .camera)
        XCTAssertEqual(NavigationCameraLead.decide(progress: progress(turnIn: 30), target: target(.pre, overspeed: true)),
                       .camera)
    }

    func testReroutingHandsLeadToCamera() {
        XCTAssertEqual(NavigationCameraLead.decide(progress: progress(turnIn: 30, offRoute: true), target: target(.pre)),
                       .camera)
    }

    func testNonFiniteTurnDistanceDoesNotCountAsNear() {
        XCTAssertEqual(NavigationCameraLead.decide(progress: progress(turnIn: .nan), target: target(.near)), .camera)
        XCTAssertEqual(NavigationCameraLead.decide(progress: progress(turnIn: .nan), target: target(.pre)), .navigation)
    }
}
