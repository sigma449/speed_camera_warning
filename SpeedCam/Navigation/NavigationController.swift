import CoreLocation
import Foundation
import MapKit
import os
import SpeedCamCore

/// 目的地搜尋、路線規劃與逐向導航進度。
@MainActor
final class NavigationController {
    private(set) var route: MKRoute?
    private(set) var destination: MKMapItem?
    private var tracker: RouteProgressTracker?
    private var instructionResolver: RoadInstructionResolver = .empty
    private var gradeSeparatedRoads = RoadMatcher(lines: [])
    /// 這條路線確定走在高架／快速道路／國道上的區段。
    private var gradeSeparated = GradeSeparatedRoute.none
    private(set) var routeHintWarning: String?

    var isActive: Bool { route != nil }

    // MARK: 搜尋

    func search(_ query: String, near center: CLLocationCoordinate2D?) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let center {
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        return try await performSearch(request)
    }

    /// 使用者點了自動完成的候選：查出實際地點（可能是一個，也可能是一類地點的多個結果）。
    func search(completion: MKLocalSearchCompletion) async throws -> [MKMapItem] {
        try await performSearch(MKLocalSearch.Request(completion: completion))
    }

    private func performSearch(_ request: MKLocalSearch.Request) async throws -> [MKMapItem] {
        let search = MKLocalSearch(request: request)
        let response = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await search.start()
        }, onCancel: {
            search.cancel()
        })
        try Task.checkCancellation()
        return response.mapItems
    }

    // MARK: 路線

    /// 依車種規劃路線；道路名稱校正使用與選路相同的內建線形。
    /// source：重新規劃時傳最新定位。系統的「目前位置」可能還是幾秒前的，開車時會差好幾十公尺。
    func calculateRoute(to destination: MKMapItem, mode: VehicleMode,
                        from source: MKMapItem? = nil) async throws -> RoutePlan<MKRoute> {
        try Task.checkCancellation()
        var rules = RouteRules.noData
        instructionResolver = await RoadLineStore.loadInstructionResolver()
        gradeSeparatedRoads = await RoadLineStore.loadGradeSeparatedRoads()
        if mode != .car { rules = await RoadLineStore.loadRules() }
        try Task.checkCancellation()
        return try await RoutePlanner.plan(from: source ?? MKMapItem.forCurrentLocation(), to: destination,
                                           mode: mode, rules: rules)
    }

    func start(route: MKRoute, destination: MKMapItem, cameras: SpatialIndex) {
        self.route = route
        self.destination = destination
        let polyline = MapItems.coordinates(of: route.polyline)
        let original = MapItems.stepInfos(of: route, resolver: instructionResolver)
        let hints: [RouteHint]
        do {
            hints = try RouteHintStore.load()
            routeHintWarning = nil
        } catch {
            hints = []
            routeHintWarning = "導航補充提示載入失敗，暫用 Apple 導航：\(error.localizedDescription)"
            Logger(subsystem: "tw.speedcammap.app", category: "route").error("\(self.routeHintWarning ?? "", privacy: .public)")
        }
        let matches = RouteHintMatcher.matches(hints, polyline: polyline)
        tracker = RouteProgressTracker(polyline: polyline, steps: RouteHintMatcher.steps(
            original, matches: matches, totalDistance: GeoMath.length(of: polyline)))
        // 用 Apple 原始步驟判斷上下高架；人工提示插入的步驟不影響沿路線距離。
        gradeSeparated = GradeSeparatedRoute(polyline: polyline, steps: original, roads: gradeSeparatedRoads,
                                             cameras: cameras)
        if !gradeSeparated.segments.isEmpty {
            let summary = gradeSeparated.segments.map {
                "\(Int($0.start))–\(Int($0.end)) m 略過 \($0.cameraIDs.count) 支"
            }.joined(separator: "；")
            Logger(subsystem: "tw.speedcammap.app", category: "route").info("高架區段：\(summary, privacy: .public)")
        }
    }

    /// 目前走在高架上時要略過的平面照相點；偏離路線或沒有進度時不略過。
    func suppressedCameraIDs(for progress: RouteProgress?) -> Set<String> {
        guard let progress, !progress.isOffRoute, let tracker else { return [] }
        return gradeSeparated.suppressedCameraIDs(along: tracker.totalDistance - progress.distanceRemaining)
    }

    func stop() {
        route = nil
        destination = nil
        tracker = nil
        gradeSeparated = .none
        routeHintWarning = nil
    }

    func process(_ fix: VehicleFix) -> RouteProgressResult? {
        tracker?.process(fix)
    }

    /// 開始導航時額外念 Apple 首步；人工提示留給轉彎事件，避免起點連念兩次。
    var firstInstruction: String? {
        guard let first = tracker?.steps.first(where: { !$0.instruction.isEmpty }), first.hintID == nil else { return nil }
        return first.instruction
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
