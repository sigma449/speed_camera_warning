import Foundation
import OSLog
import SpeedCamCore

/// App 內建的國道和白牌限制道路線形（Resources/road_lines.json）。
enum RoadLineStore {
    /// 設定頁顯示的出處，內容和 data-pipeline 的 `ATTRIBUTION` 一樣。
    static let attribution = "國道線形：© OpenStreetMap 貢獻者（ODbL，openstreetmap.org/copyright）"

    /// 第一次用到才載入。讀檔和建索引要一點時間，所以用 `loadRules()` 在背景取得。
    private static let rules: RouteRules = {
        let log = Logger(subsystem: "tw.speedcammap.app", category: "route")
        guard let url = Bundle.main.url(forResource: "road_lines", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let lines = try? RoadLineData.decode(from: data) else {
            log.error("road_lines.json 載入失敗，紅黃牌路線改成只走平面道路")
            return .noData
        }
        return RouteRules(data: lines)
    }()

    static func loadRules() async -> RouteRules {
        await Task.detached(priority: .userInitiated) { RoadLineStore.rules }.value
    }
}
