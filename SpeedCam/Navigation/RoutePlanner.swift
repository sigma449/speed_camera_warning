import CoreLocation
import MapKit
import OSLog
import SpeedCamCore

/// 依車種向 Apple 要路線並挑選。怎麼挑寫在 SpeedCamCore 的 `RouteRules`，這裡只負責和 MapKit 溝通。
/// CI 的「路線實測」也直接編譯這個檔案，所以不能依賴 UIKit。
enum RoutePlanner {
    static func plan(from source: MKMapItem, to destination: MKMapItem, mode: VehicleMode,
                     rules: RouteRules) async throws -> RoutePlan<MKRoute> {
        let plan = try await rules.plan(mode: mode) { option -> [(route: MKRoute, facts: RouteFacts)] in
            let request = MKDirections.Request()
            request.source = source
            request.destination = destination
            request.transportType = .automobile
            request.requestsAlternateRoutes = option.alternates
            // iOS 15 不能要求避開高速或收費，只能從回傳的路線裡挑，常常會挑不到而跳提醒。
            if #available(iOS 16, *), LegacySupport.supportsRoutePreferences {
                request.highwayPreference = option.avoidHighways ? .avoid : .any
                request.tollPreference = option.avoidTolls ? .avoid : .any
            }
            let response = try await MKDirections(request: request).calculate()
            return response.routes.map { route in
                (route: route, facts: RouteFacts(hasHighways: route.hasHighways, hasTolls: route.hasTolls,
                                                 points: MapItems.coordinates(of: route.polyline)))
            }
        }
        Logger(subsystem: "tw.speedcammap.app", category: "route")
            .notice("route plan \(mode.rawValue, privacy: .public): request \(plan.requestIndex) route \(plan.routeIndex) issues \(String(describing: plan.issues), privacy: .public)")
        return plan
    }
}
