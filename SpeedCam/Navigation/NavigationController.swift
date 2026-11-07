import CoreLocation
import Foundation
import MapKit
import SpeedCamCore

/// 目的地搜尋、路線規劃與逐向導航進度。
@MainActor
final class NavigationController {
    private(set) var route: MKRoute?
    private(set) var destination: MKMapItem?
    private var tracker: RouteProgressTracker?

    var isActive: Bool { route != nil }

    // MARK: 搜尋

    func search(_ query: String, near center: CLLocationCoordinate2D?) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let center {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems
    }

    /// 使用者點了自動完成的候選：查出實際地點（可能是一個，也可能是一類地點的多個結果）。
    func search(completion: MKLocalSearchCompletion) async throws -> [MKMapItem] {
        let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        return response.mapItems
    }

    // MARK: 路線

    /// 依車種規劃路線。汽車用不到線形資料，就不載入。
    /// source：重新規劃時傳最新定位。系統的「目前位置」可能還是幾秒前的，開車時會差好幾十公尺。
    func calculateRoute(to destination: MKMapItem, mode: VehicleMode,
                        from source: MKMapItem? = nil) async throws -> RoutePlan<MKRoute> {
        var rules = RouteRules.noData
        if mode != .car { rules = await RoadLineStore.loadRules() }
        return try await RoutePlanner.plan(from: source ?? MKMapItem.forCurrentLocation(), to: destination,
                                           mode: mode, rules: rules)
    }

    func start(route: MKRoute, destination: MKMapItem) {
        self.route = route
        self.destination = destination
        let polyline = MapItems.coordinates(of: route.polyline)
        tracker = RouteProgressTracker(polyline: polyline, steps: MapItems.stepInfos(of: route))
    }

    func stop() {
        route = nil
        destination = nil
        tracker = nil
    }

    func process(_ fix: VehicleFix) -> RouteProgressResult? {
        tracker?.process(fix)
    }

    /// 第一個有內容的指示（開始導航時念出來）。
    var firstInstruction: String? {
        route?.steps.first { !$0.instructions.isEmpty }?.instructions
    }

    /// 依指示文字挑選轉彎箭頭圖示。
    static func symbol(for instruction: String) -> String {
        if instruction.contains("迴轉") { return "arrow.uturn.down" }
        if instruction.contains("下交流道") {
            return instruction.contains("左側") ? "arrow.up.left" : "arrow.up.right"
        }
        if instruction.contains("靠左") { return "arrow.up.left" }
        if instruction.contains("靠右") { return "arrow.up.right" }
        if instruction.contains("左轉") { return "arrow.turn.up.left" }
        if instruction.contains("右轉") { return "arrow.turn.up.right" }
        if instruction.contains("圓環") { return "arrow.triangle.turn.up.right.circle" }
        if instruction.contains("目的地") || instruction.contains("抵達") { return "mappin.circle.fill" }
        if instruction.lowercased().contains("left") { return "arrow.turn.up.left" }
        if instruction.lowercased().contains("right") { return "arrow.turn.up.right" }
        return "arrow.up"
    }
}
