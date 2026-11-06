import XCTest
@testable import SpeedCamCore

/// 用 Apple 實際規劃的路線（2026-11-06 路線實測的結果，Fixtures/real_routes.json）和 App 內建的線形測試。
/// 這些情況是實測時找出來的，改比對的參數或重新產生線形後，都要維持同樣的結果。
final class RealRouteTests: XCTestCase {
    private struct Route: Decodable {
        let label: String
        let hasHighways: Bool
        let hasTolls: Bool
        let points: [[Double]]

        var facts: RouteFacts {
            RouteFacts(hasHighways: hasHighways, hasTolls: hasTolls,
                       points: points.map { GeoPoint(lat: $0[0], lon: $0[1]) })
        }
    }

    private static let routes: [String: RouteFacts] = {
        guard let url = Bundle.module.url(forResource: "real_routes", withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Route].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.label, $0.facts) })
    }()

    private func rules() throws -> RouteRules {
        // 測試檔在 Packages/SpeedCamCore/Tests/SpeedCamCoreTests/，資料在 SpeedCam/Resources/
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("SpeedCam/Resources/road_lines.json")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("只掛載套件目錄時讀不到 \(url.path)，CI 會跑")
        }
        return RouteRules(data: try RoadLineData.decode(from: data))
    }

    private func route(_ label: String) throws -> RouteFacts {
        try XCTUnwrap(Self.routes[label], "測試資料沒有「\(label)」")
    }

    private func isFreeway(_ issues: [RouteIssue]) -> Bool {
        issues.contains { if case .freeway = $0 { return true } else { return false } }
    }

    func testLineDataLooksComplete() throws {
        let rules = try rules()
        XCTAssertFalse(rules.freeways.isEmpty)
        XCTAssertFalse(rules.whitePlateRestricted.isEmpty)
    }

    func testRedYellowCatchesTollFreeFreeways() throws {
        let rules = try rules()
        for label in ["免費國6", "免費國2", "短程國3", "免費國8"] {
            let facts = try route(label)
            XCTAssertFalse(facts.hasTolls, label)
            XCTAssertTrue(isFreeway(rules.issues(of: facts, mode: .motorcycleRedYellow)), label)
        }
    }

    func testRedYellowKeepsExpresswaysAndElevatedRoads() throws {
        let rules = try rules()
        for label in ["台64接台61", "台62旁邊的國3", "建國高架", "台88"] {
            let facts = try route(label)
            XCTAssertTrue(facts.hasHighways, label)
            XCTAssertEqual(rules.issues(of: facts, mode: .motorcycleRedYellow), [], label)
        }
    }

    func testRoadsNextToFreewaysAreNotFreeways() throws {
        let rules = try rules()
        for label in ["縣道191旁邊的國5", "大同路", "市民大道平面"] {
            let facts = try route(label)
            XCTAssertFalse(facts.hasHighways, label)
            XCTAssertEqual(rules.issues(of: facts, mode: .motorcycleRedYellow), [], label)
        }
    }

    func testParallelRoadIsNearButNotOnTheFreeway() throws {
        let rules = try rules()
        let overlap = rules.freeways.overlap(with: try route("台62旁邊的國3").points)
        XCTAssertGreaterThan(overlap.longestRun, 1_000)
        XCTAssertEqual(overlap.longestCloseRun, 0)
    }

    func testWhitePlateRejectsExpresswaysAndElevatedRoads() throws {
        let rules = try rules()
        XCTAssertTrue(rules.issues(of: try route("建國高架"), mode: .motorcycleWhite).contains(.highway))
        let zhoumei = rules.issues(of: try route("洲美快速道路"), mode: .motorcycleWhite)
        XCTAssertTrue(zhoumei.contains { if case .restrictedRoad = $0 { return true } else { return false } })
    }

    func testWhitePlateAcceptsSurfaceRoads() throws {
        let rules = try rules()
        for label in ["大同路", "市民大道平面"] {
            XCTAssertEqual(rules.issues(of: try route(label), mode: .motorcycleWhite), [], label)
        }
    }
}
