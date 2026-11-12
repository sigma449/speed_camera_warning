import ActivityKit
import Foundation

/// Live Activity 顯示的內容。App 與 Widget Extension 共用。
/// 刻意只用基本型別（不依賴 SpeedCamCore 的型別），也不需要 App Groups 或推播。
/// 放在 `SpeedCamActivityAttributes` 外面，因為 AppModel 在沒有 Live Activity 的舊系統上也會用到它。
struct SpeedCamActivityState: Codable, Hashable {
    enum Mode: String, Codable, Hashable {
        /// 巡航中，附近沒有照相點
        case idle
        /// 接近測速照相
        case camera
        /// 區間測速中
        case section
        /// 導航中，附近沒有照相點
        case navigation
    }

    var mode: Mode = .idle

    // 測速照相
    var cameraTypeName: String?
    var cameraSymbol: String?
    var cameraDetail: String?
    var distanceMeters: Double?
    var speedLimit: Int?
    var isOverspeed: Bool = false

    // 區間測速
    /// 最早可以抵達終點的時間；畫面用它做自動倒數（不需要 App 每秒更新）。
    var sectionEarliestExit: Date?
    var sectionAverageKmh: Int?
    var sectionLimit: Int?
    var sectionZero: Bool = false
    /// 依剩餘距離算出的建議時速（剩下的路照這個以下開，平均不會超過速限＋容許值）。
    var sectionSuggestedKmh: Int?

    // 導航
    var maneuverText: String?
    var maneuverSymbol: String?
    var maneuverDistance: Double?

    // 共用
    var currentSpeedKmh: Int = 0
    var vehicleModeName: String = "汽車"

    /// 區間和照相模式下，快到轉彎時顯示的下一步（例如「300m 右轉 民生西路」）。
    /// 距離取到 50 公尺，避免 Live Activity 一直更新。超速時先顯示超速。
    var navHint: String? {
        guard let meters = navHintMeters, let maneuverText else { return nil }
        return "\(meters)m \(maneuverText)"
    }

    /// 最窄的尺寸放不下路名，只留距離和動作（例如「300m 右轉」）。
    var navHintCompact: String? {
        guard let meters = navHintMeters, let maneuverText else { return nil }
        let action = maneuverText.split(separator: " ").first.map(String.init) ?? maneuverText
        return "\(meters)m \(action)"
    }

    private var navHintMeters: Int? {
        guard mode == .camera || mode == .section, !isOverspeed,
              maneuverText != nil, let maneuverDistance, maneuverDistance <= 300 else { return nil }
        return max(50, Int((maneuverDistance / 50).rounded()) * 50)
    }

    /// 導航模式最窄的尺寸只留路名：動作已經有箭頭（「靠右 上五股楊梅高架」→「上五股楊梅高架」）。
    var maneuverTextCompact: String? {
        guard let maneuverText else { return nil }
        let parts = maneuverText.split(separator: " ", maxSplits: 1).map(String.init)
        return parts.count == 2 ? parts[1] : maneuverText
    }
}

@available(iOS 16.1, *)
struct SpeedCamActivityAttributes: ActivityAttributes {
    typealias ContentState = SpeedCamActivityState

    var startedAt: Date
}

extension SpeedCamActivityState {
    /// 預覽、CI 截圖用的範例資料。
    static let previewCamera = Self(mode: .camera, cameraTypeName: "測速照相", cameraSymbol: "camera.fill",
                                    distanceMeters: 280, speedLimit: 50, currentSpeedKmh: 48)
    static let previewMobile = Self(mode: .camera, cameraTypeName: "常見移動測速", cameraSymbol: "binoculars.fill",
                                    cameraDetail: "公告熱點・非即時執法", distanceMeters: 300, currentSpeedKmh: 48)
    static let previewTech = Self(mode: .camera, cameraTypeName: "路口科技執法", cameraSymbol: "video.fill",
                                  cameraDetail: "取締：闖紅燈、未依標線行駛", distanceMeters: 300, currentSpeedKmh: 48)
    static let previewNoise = Self(mode: .camera, cameraTypeName: "聲音照相", cameraSymbol: "speaker.wave.2.fill",
                                   distanceMeters: 300, currentSpeedKmh: 48)
    static let previewOverspeed = Self(mode: .camera, cameraTypeName: "測速照相", cameraSymbol: "camera.fill",
                                       distanceMeters: 120, speedLimit: 50, isOverspeed: true, currentSpeedKmh: 63)
    static let previewSection = Self(mode: .section, sectionEarliestExit: Date().addingTimeInterval(125),
                                     sectionAverageKmh: 58, sectionLimit: 60, sectionSuggestedKmh: 54, currentSpeedKmh: 57)
    static let previewSectionZero = Self(mode: .section, sectionEarliestExit: Date(),
                                         sectionAverageKmh: 55, sectionLimit: 60, sectionZero: true, currentSpeedKmh: 60)
    static let previewNavigation = Self(mode: .navigation, maneuverText: "右轉進入忠孝東路",
                                        maneuverSymbol: "arrow.turn.up.right", maneuverDistance: 350,
                                        currentSpeedKmh: 42)
    static let previewIdle = Self(mode: .idle, currentSpeedKmh: 37)
    /// 車種名稱最長的情況。
    static let previewIdleRedYellow = Self(mode: .idle, currentSpeedKmh: 137, vehicleModeName: "紅黃牌")
    /// 最長的文字，用來檢查最窄的尺寸放不放得下。
    static let previewLongestCamera = Self(mode: .camera, cameraTypeName: "高架測速及闖紅燈照相", cameraSymbol: "camera.fill",
                                           distanceMeters: 1_250, speedLimit: 110, currentSpeedKmh: 96)
    static let previewLongestNavigation = Self(mode: .navigation, maneuverText: "靠右 上五股楊梅高架",
                                               maneuverSymbol: "arrow.up.right", maneuverDistance: 1_250,
                                               currentSpeedKmh: 96)
    /// 接近區間起點。
    static let previewSectionApproach = Self(mode: .camera, cameraTypeName: "區間測速", cameraSymbol: "timer",
                                             distanceMeters: 300, speedLimit: 70, currentSpeedKmh: 65)
    /// 區間倒數中，快到要轉彎的地方。
    static let previewSectionWithTurn = Self(mode: .section, sectionEarliestExit: Date().addingTimeInterval(125),
                                             sectionAverageKmh: 58, sectionLimit: 60, sectionSuggestedKmh: 54,
                                             maneuverText: "下交流道 95A出口", maneuverSymbol: "arrow.up.right",
                                             maneuverDistance: 280, currentSpeedKmh: 57)
    /// 接近照相點，快到要轉彎的地方。
    static let previewCameraWithTurn = Self(mode: .camera, cameraTypeName: "測速照相", cameraSymbol: "camera.fill",
                                            distanceMeters: 280, speedLimit: 50,
                                            maneuverText: "右轉 環河北路一段", maneuverSymbol: "arrow.turn.up.right",
                                            maneuverDistance: 150, currentSpeedKmh: 48)
    /// 偏離路線，重新規劃中。
    static let previewRerouting = Self(mode: .navigation, maneuverText: "重新規劃中",
                                       maneuverSymbol: "arrow.triangle.2.circlepath", currentSpeedKmh: 42)
}
