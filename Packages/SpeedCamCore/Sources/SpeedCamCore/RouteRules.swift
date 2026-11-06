import Foundation

/// 向 Apple 要路線時的一組設定（對應 `MKDirections.Request`）。
public struct RouteRequestOption: Equatable, Sendable {
    public var avoidHighways: Bool
    public var avoidTolls: Bool
    /// 也要其他路線。機車模式要多條路線才有得挑。
    public var alternates: Bool

    public init(avoidHighways: Bool, avoidTolls: Bool, alternates: Bool) {
        self.avoidHighways = avoidHighways
        self.avoidTolls = avoidTolls
        self.alternates = alternates
    }
}

/// 判斷路線能不能用所需要的資料（App 從 `MKRoute` 取得）。
public struct RouteFacts: Sendable {
    public var hasHighways: Bool
    public var hasTolls: Bool
    public var points: [GeoPoint]

    public init(hasHighways: Bool, hasTolls: Bool, points: [GeoPoint]) {
        self.hasHighways = hasHighways
        self.hasTolls = hasTolls
        self.points = points
    }
}

/// 路線不符合車種規則的地方。
public enum RouteIssue: Equatable, Sendable {
    /// 比對線形後確定走了國道（最長連續幾公尺）。
    case freeway(meters: Double)
    /// Apple 標示有高速路段。白牌不走；沒有線形資料時紅黃牌也不走，因為分不出是國道還是快速道路。
    case highway
    /// 走了白牌不走的高架或快速道路（最長連續幾公尺）。
    case restrictedRoad(meters: Double)
    case toll
}

/// 找不到符合規則的路線，只好用最接近的一條時，給使用者看的提醒。
public enum RouteWarning: Equatable, Sendable {
    case freeway
    case expressway
    case toll

    public var text: String {
        switch self {
        case .freeway: return "這條路線會走國道，請自行確認"
        case .expressway: return "這條路線可能走快速道路或高架，請自行確認"
        case .toll: return "這條路線可能要收費，請自行確認"
        }
    }
}

public struct RoutePlan<Route> {
    public var route: Route
    /// nil 表示符合車種的規則。
    public var warning: RouteWarning?
    /// 第幾次請求、回傳的第幾條（實測和除錯用）。
    public var requestIndex: Int
    public var routeIndex: Int
    public var issues: [RouteIssue]
}

public enum RoutePlanError: LocalizedError, Equatable {
    case noRoute

    public var errorDescription: String? {
        switch self {
        case .noRoute: return "找不到可行的路線"
        }
    }
}

/// 各車種怎麼規劃路線。
///
/// - 汽車：Apple 給的第一條。
/// - 紅黃牌：只避開收費並要多條路線，排除有收費或走國道的路線；都不行才退回避開高速。
///   只避開收費時，Apple 仍然會走不收費的國道（例如國 2、國 6），所以要比對線形。
///   Apple 的 `highwayPreference` 連快速道路和市區高架也算，不能拿來避開國道。
/// - 白牌：避開高速和收費。Apple 有些高架不算 highway（例如新生高架），所以再比對這些道路。
///
/// 比對線形只看平面座標，分不出高架和正下方的平面道路。所以只有 Apple 標示有高速路段的路線才比對國道：
/// 2026-11-06 實測 Apple 標示沒有高速路段的路線都沒有走國道，而國道下方的平面道路不應該被排除。
public struct RouteRules: Sendable {
    /// 連續貼著線形超過這個長度就算走在上面。實測最短的一段國道是 1.6 km（汐科到南港的國 3）。
    public static let overlapLimit = 800.0

    public let freeways: RoadMatcher
    public let whitePlateRestricted: RoadMatcher

    public init(freeways: RoadMatcher, whitePlateRestricted: RoadMatcher) {
        self.freeways = freeways
        self.whitePlateRestricted = whitePlateRestricted
    }

    public init(data: RoadLineData) {
        self.init(freeways: RoadMatcher(lines: data.freeways),
                  whitePlateRestricted: RoadMatcher(lines: data.whitePlateRestricted))
    }

    /// 線形資料載入失敗時用：無法確認有沒有走國道，紅黃牌就退回只走平面道路。
    public static let noData = RouteRules(freeways: RoadMatcher(lines: []), whitePlateRestricted: RoadMatcher(lines: []))

    /// 依序嘗試的請求，前面的沒有符合規則的路線才用下一個。
    public func requests(for mode: VehicleMode) -> [RouteRequestOption] {
        let avoidBoth = RouteRequestOption(avoidHighways: true, avoidTolls: true, alternates: true)
        switch mode {
        case .car:
            return [RouteRequestOption(avoidHighways: false, avoidTolls: false, alternates: false)]
        case .motorcycleRedYellow:
            if freeways.isEmpty { return [avoidBoth] }
            return [RouteRequestOption(avoidHighways: false, avoidTolls: true, alternates: true), avoidBoth]
        case .motorcycleWhite:
            return [avoidBoth]
        }
    }

    public func issues(of route: RouteFacts, mode: VehicleMode) -> [RouteIssue] {
        guard mode != .car else { return [] }
        var result: [RouteIssue] = []
        if route.hasHighways {
            let run = freeways.overlap(with: route.points).longestCloseRun
            if run >= Self.overlapLimit { result.append(.freeway(meters: run)) }
        }
        switch mode {
        case .car:
            break
        case .motorcycleRedYellow:
            if route.hasHighways && freeways.isEmpty { result.append(.highway) }
        case .motorcycleWhite:
            if route.hasHighways { result.append(.highway) }
            let run = whitePlateRestricted.overlap(with: route.points).longestCloseRun
            if run >= Self.overlapLimit { result.append(.restrictedRoad(meters: run)) }
        }
        if route.hasTolls { result.append(.toll) }
        return result
    }

    /// 依序送出請求，用第一條符合規則的路線。都不符合就用問題最小的一條並附上提醒。
    /// `fetch` 回傳的路線順序就是 Apple 建議的順序。
    public func plan<Route>(mode: VehicleMode,
                            fetch: (RouteRequestOption) async throws -> [(route: Route, facts: RouteFacts)])
        async throws -> RoutePlan<Route> {
        var best: (plan: RoutePlan<Route>, score: [Double])?
        var lastError: Error?
        for (requestIndex, option) in requests(for: mode).enumerated() {
            let routes: [(route: Route, facts: RouteFacts)]
            do {
                routes = try await fetch(option)
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                lastError = error
                continue
            }
            for (routeIndex, item) in routes.enumerated() {
                let found = issues(of: item.facts, mode: mode)
                var plan = RoutePlan(route: item.route, warning: nil, requestIndex: requestIndex,
                                     routeIndex: routeIndex, issues: found)
                if found.isEmpty { return plan }
                plan.warning = Self.warning(for: found)
                let score = Self.score(found)
                if best == nil || score.lexicographicallyPrecedes(best!.score) {
                    best = (plan, score)
                }
            }
        }
        if let best { return best.plan }
        throw lastError ?? RoutePlanError.noRoute
    }

    private static func warning(for issues: [RouteIssue]) -> RouteWarning {
        if issues.contains(where: { if case .freeway = $0 { return true } else { return false } }) { return .freeway }
        if issues.contains(where: { $0 != .toll }) { return .expressway }
        return .toll
    }

    /// 問題由重到輕：國道（越長越差）、高速路段、其他高架、收費。
    private static func score(_ issues: [RouteIssue]) -> [Double] {
        var freeway = 0.0, highway = 0.0, restricted = 0.0, toll = 0.0
        for issue in issues {
            switch issue {
            case .freeway(let meters): freeway = meters
            case .highway: highway = 1
            case .restrictedRoad(let meters): restricted = meters
            case .toll: toll = 1
            }
        }
        return [freeway, highway, restricted, toll]
    }
}
