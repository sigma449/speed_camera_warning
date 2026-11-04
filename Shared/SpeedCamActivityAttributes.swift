import ActivityKit
import Foundation

/// Live Activity 的資料模型。App 與 Widget Extension 共用。
/// 刻意只用基本型別（不依賴 SpeedCamCore 的型別），也不需要 App Groups 或推播。
struct SpeedCamActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
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
    }

    var startedAt: Date
}

extension SpeedCamActivityAttributes.ContentState {
    /// 預覽、CI 截圖用的範例資料。
    static let previewCamera = Self(mode: .camera, cameraTypeName: "測速照相", cameraSymbol: "camera.fill",
                                    distanceMeters: 280, speedLimit: 50, currentSpeedKmh: 48)
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
}
