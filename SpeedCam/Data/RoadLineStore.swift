import Foundation
import OSLog
import SpeedCamCore

/// App 內建的國道和白牌限制道路線形（Resources/road_lines.json）。
enum RoadLineStore {
    /// 設定頁顯示的出處，內容和 data-pipeline 的 `ATTRIBUTION` 一樣。
    static let attribution = "國道線形：© OpenStreetMap 貢獻者（ODbL，openstreetmap.org/copyright）"

    /// 第一次用到才載入。讀檔和建索引要一點時間，所以用 `loadRules()` 在背景取得。
    private static let content: (rules: RouteRules, resolver: RoadInstructionResolver, gradeSeparated: RoadMatcher) = {
        let log = Logger(subsystem: "tw.speedcammap.app", category: "route")
        guard let url = Bundle.main.url(forResource: "road_lines", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let lines = try? RoadLineData.decode(from: data) else {
            log.error("road_lines.json 載入失敗，紅黃牌路線改成只走平面道路")
            return (.noData, .empty, RoadMatcher(lines: []))
        }
        // 高架／快速道路／國道主線：導航確定走在上面時，略過正下方平面路口的非測速提醒（GradeSeparatedRoute）。
        // 「快速公路」（台61 等省道）有平面路口，不算。
        let elevated = lines.namedRoads.filter {
            $0.freewayRef != nil || $0.name.contains("高架") || $0.name.contains("快速道路")
        }.flatMap(\.lines)
        return (RouteRules(data: lines), RoadInstructionResolver(freeways: lines.freeways, namedRoads: lines.namedRoads),
                RoadMatcher(lines: lines.freeways + elevated))
    }()

    static func loadRules() async -> RouteRules {
        await Task.detached(priority: .userInitiated) { RoadLineStore.content.rules }.value
    }

    static func loadInstructionResolver() async -> RoadInstructionResolver {
        await Task.detached(priority: .userInitiated) { RoadLineStore.content.resolver }.value
    }

    static func loadGradeSeparatedRoads() async -> RoadMatcher {
        await Task.detached(priority: .userInitiated) { RoadLineStore.content.gradeSeparated }.value
    }
}
