import XCTest
@testable import SpeedCamCore

final class RouteRulesTests: XCTestCase {
    private let start = GeoPoint(lat: 25.0, lon: 121.0)

    private func north(_ length: Double, offsetEast: Double = 0) -> [GeoPoint] {
        let origin = GeoMath.destination(from: start, bearing: 90, distance: offsetEast)
        return stride(from: 0.0, through: length, by: 100).map {
            GeoMath.destination(from: origin, bearing: 0, distance: $0)
        }
    }

    /// 國道在 start 正北，白牌限制道路在東邊 1 km，其他路線走東邊 2 km。
    private var rules: RouteRules {
        RouteRules(freeways: RoadMatcher(lines: [north(10_000)]),
                   whitePlateRestricted: RoadMatcher(lines: [north(10_000, offsetEast: 1_000)]))
    }

    private var onFreeway: [GeoPoint] { north(5_000) }
    private var onRestricted: [GeoPoint] { north(5_000, offsetEast: 1_000) }
    private var elsewhere: [GeoPoint] { north(5_000, offsetEast: 2_000) }

    private func facts(_ points: [GeoPoint], highways: Bool = false, tolls: Bool = false) -> RouteFacts {
        RouteFacts(hasHighways: highways, hasTolls: tolls, points: points)
    }

    private typealias Item = (route: String, facts: RouteFacts)

    private func plan(_ mode: VehicleMode, using rules: RouteRules? = nil,
                      responses: [[Item]]) async throws -> (plan: RoutePlan<String>, requests: [RouteRequestOption]) {
        var requests: [RouteRequestOption] = []
        var remaining = responses
        let plan = try await (rules ?? self.rules).plan(mode: mode) { option -> [Item] in
            requests.append(option)
            return remaining.isEmpty ? [] : remaining.removeFirst()
        }
        return (plan, requests)
    }

    // MARK: 車種模式

    func testOldMotorcycleSettingBecomesWhitePlate() throws {
        let decode = { (raw: String) in try JSONDecoder().decode(VehicleMode.self, from: Data("\"\(raw)\"".utf8)) }
        XCTAssertEqual(try decode("motorcycle"), .motorcycleWhite)
        XCTAssertEqual(try decode("motorcycleRedYellow"), .motorcycleRedYellow)
        XCTAssertEqual(try decode("car"), .car)
        XCTAssertEqual(try decode("未來的車種"), .car)
        let encoded = try JSONEncoder().encode(VehicleMode.motorcycleRedYellow)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"motorcycleRedYellow\"")
    }

    // MARK: 汽車

    func testCarUsesTheFirstRouteWithoutChecking() async throws {
        let result = try await plan(.car, responses: [[("國道", facts(onFreeway, highways: true, tolls: true))]])
        XCTAssertEqual(result.plan.route, "國道")
        XCTAssertNil(result.plan.warning)
        XCTAssertEqual(result.requests, [RouteRequestOption(avoidHighways: false, avoidTolls: false, alternates: false)])
    }

    // MARK: 紅黃牌

    func testRedYellowKeepsExpresswaysAndAsksForOnlyTollFree() async throws {
        let result = try await plan(.motorcycleRedYellow, responses: [[("快速道路", facts(elsewhere, highways: true))]])
        XCTAssertEqual(result.plan.route, "快速道路")
        XCTAssertNil(result.plan.warning)
        XCTAssertEqual(result.requests, [RouteRequestOption(avoidHighways: false, avoidTolls: true, alternates: true)])
    }

    func testRedYellowSkipsTollFreeFreewayAndTollRoads() async throws {
        let result = try await plan(.motorcycleRedYellow, responses: [[
            ("免費國道", facts(onFreeway, highways: true)),
            ("收費道路", facts(elsewhere, highways: true, tolls: true)),
            ("平面道路", facts(elsewhere)),
        ]])
        XCTAssertEqual(result.plan.route, "平面道路")
        XCTAssertEqual(result.plan.routeIndex, 2)
        XCTAssertNil(result.plan.warning)
        XCTAssertEqual(result.requests.count, 1)
    }

    func testRedYellowFallsBackToAvoidingHighways() async throws {
        let result = try await plan(.motorcycleRedYellow, responses: [
            [("免費國道", facts(onFreeway, highways: true))],
            [("平面道路", facts(elsewhere))],
        ])
        XCTAssertEqual(result.plan.route, "平面道路")
        XCTAssertEqual(result.plan.requestIndex, 1)
        XCTAssertNil(result.plan.warning)
        XCTAssertEqual(result.requests.last, RouteRequestOption(avoidHighways: true, avoidTolls: true, alternates: true))
    }

    func testRoadUnderTheFreewayIsNotRejected() async throws {
        // 比對只看平面座標：Apple 說沒有高速路段，就是國道下方的平面道路
        let result = try await plan(.motorcycleRedYellow, responses: [[("國道下方", facts(onFreeway, highways: false))]])
        XCTAssertEqual(result.plan.route, "國道下方")
        XCTAssertNil(result.plan.warning)
    }

    func testShortOverlapIsNotAFreeway() {
        let parallel = facts(north(500), highways: true)
        XCTAssertEqual(rules.issues(of: parallel, mode: .motorcycleRedYellow), [])
    }

    func testParallelSideRoadIsNotAFreeway() {
        // 例如宜蘭的縣道 191 和國 5：連續幾公里都在 30 m 內，路線其他部分走了快速道路所以有高速路段
        let sideRoad = facts(north(5_000, offsetEast: 15), highways: true)
        XCTAssertEqual(rules.issues(of: sideRoad, mode: .motorcycleRedYellow), [])
    }

    func testRedYellowWarnsWhenEveryRouteUsesAFreeway() async throws {
        let result = try await plan(.motorcycleRedYellow, responses: [
            [("長國道", facts(north(9_000), highways: true))],
            [("短國道", facts(north(2_000), highways: true))],
        ])
        XCTAssertEqual(result.plan.route, "短國道")
        XCTAssertEqual(result.plan.warning, .freeway)
    }

    func testRedYellowWithoutLineDataOnlyUsesSurfaceRoads() async throws {
        let result = try await plan(.motorcycleRedYellow, using: .noData, responses: [[
            ("分不出來", facts(onFreeway, highways: true)),
            ("平面道路", facts(elsewhere)),
        ]])
        XCTAssertEqual(result.plan.route, "平面道路")
        XCTAssertEqual(result.requests, [RouteRequestOption(avoidHighways: true, avoidTolls: true, alternates: true)])
    }

    // MARK: 白牌

    func testWhitePlateRejectsHighwaysEvenWithoutFreeway() async throws {
        let result = try await plan(.motorcycleWhite, responses: [[
            ("快速道路", facts(elsewhere, highways: true)),
            ("平面道路", facts(elsewhere)),
        ]])
        XCTAssertEqual(result.plan.route, "平面道路")
        XCTAssertEqual(result.requests, [RouteRequestOption(avoidHighways: true, avoidTolls: true, alternates: true)])
    }

    func testWhitePlateRejectsElevatedRoadsAppleDoesNotCount() async throws {
        let result = try await plan(.motorcycleWhite, responses: [[
            ("新生高架", facts(onRestricted)),
            ("平面道路", facts(elsewhere)),
        ]])
        XCTAssertEqual(result.plan.route, "平面道路")
    }

    func testWhitePlateWarnsWhenNoSurfaceRouteExists() async throws {
        let result = try await plan(.motorcycleWhite, responses: [[
            ("國道", facts(onFreeway, highways: true)),
            ("快速道路", facts(elsewhere, highways: true)),
            ("新生高架", facts(onRestricted)),
        ]])
        XCTAssertEqual(result.plan.route, "新生高架")
        XCTAssertEqual(result.plan.warning, .expressway)
    }

    func testTollOnlyProblemGetsTollWarning() async throws {
        let result = try await plan(.motorcycleWhite, responses: [[("收費", facts(elsewhere, tolls: true))]])
        XCTAssertEqual(result.plan.warning, .toll)
    }

    // MARK: 失敗

    private struct Fake: Error {}

    func testFailedRequestTriesTheNextOne() async throws {
        var calls = 0
        let plan: RoutePlan<String> = try await rules.plan(mode: .motorcycleRedYellow) { _ -> [Item] in
            calls += 1
            if calls == 1 { throw Fake() }
            return [("平面道路", facts(elsewhere))]
        }
        XCTAssertEqual(plan.route, "平面道路")
    }

    func testAllRequestsFailingThrowsTheError() async {
        do {
            let _: RoutePlan<String> = try await rules.plan(mode: .motorcycleRedYellow) { _ -> [Item] in throw Fake() }
            XCTFail("應該要丟出錯誤")
        } catch {
            XCTAssertTrue(error is Fake)
        }
    }

    func testNoRoutesThrowsNoRoute() async {
        do {
            _ = try await plan(.motorcycleWhite, responses: [[]])
            XCTFail("應該要丟出錯誤")
        } catch {
            XCTAssertEqual(error as? RoutePlanError, .noRoute)
        }
    }

    func testCancellationStopsImmediately() async {
        var calls = 0
        do {
            let _: RoutePlan<String> = try await rules.plan(mode: .motorcycleRedYellow) { _ -> [Item] in
                calls += 1
                throw CancellationError()
            }
            XCTFail("應該要丟出錯誤")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertEqual(calls, 1)
        }
    }
}
