import Foundation

/// 地圖跟隨目前位置時的顯示方式。按「回到目前位置」按鈕可以依序切換。
public enum MapFollowMode: String, CaseIterable, Codable, Sendable {
    /// 行進方向朝上（預設）
    case headingUp
    /// 北方朝上
    case northUp
    /// 行進方向朝上＋3D 傾斜
    case headingUp3D

    /// 再按一次按鈕時切換到的下一種。
    public var next: MapFollowMode {
        switch self {
        case .headingUp: return .northUp
        case .northUp: return .headingUp3D
        case .headingUp3D: return .headingUp
        }
    }

    public var displayName: String {
        switch self {
        case .headingUp: return "行進方向朝上"
        case .northUp: return "北方朝上"
        case .headingUp3D: return "3D 行進方向"
        }
    }

    /// 地圖是否跟著行進方向旋轉。
    public var rotatesWithHeading: Bool { self != .northUp }

    /// 鏡頭傾斜角度（度）。
    public var pitch: Double { self == .headingUp3D ? 55 : 0 }
}

/// 跟隨目前位置時的鏡頭設定：依車速縮放，行進方向朝上時把車子放在畫面偏下。
public enum MapFollowCamera {
    /// 鏡頭距離（公尺）：市區低速約 700 m（畫面大約涵蓋 500 公尺），越快看越遠，高速公路最多 3,000 m（約 2 公里）。
    public static func distance(forSpeedKmh speed: Double, mode: MapFollowMode) -> Double {
        let base = min(3_000, max(700, 600 + max(0, speed) * 22))
        // 3D 傾斜時前方本來就看得比較遠，鏡頭拉近一點
        return mode == .headingUp3D ? base * 0.8 : base
    }

    /// 畫面中心要放在車子前方多遠（公尺）。行進方向朝上而且有在移動時，前方多留一些畫面。
    public static func lookAhead(distance: Double, speedKmh: Double, mode: MapFollowMode) -> Double {
        guard mode.rotatesWithHeading, speedKmh >= 10 else { return 0 }
        return distance * (mode == .headingUp3D ? 0.12 : 0.2)
    }

    /// 平滑車速，避免縮放一直跳動。
    public static func smoothedSpeed(previous: Double, current: Double) -> Double {
        previous * 0.7 + max(0, current) * 0.3
    }
}

/// 使用者把地圖滑到別處、沒有滑回來時，什麼時候自動回到目前位置。
///
/// 條件（都要符合）：
/// - GPS 定位良好（水平精度 ≤ 30 m、速度有效）。在地下的捷運或隧道裡通常沒有 GPS，不會觸發。
/// - 車速 ≥ 15 km/h，而且持續 5 秒以上（避免 GPS 飄移造成的瞬間高速）。
/// - 使用者已經 10 秒沒有碰地圖。
public struct AutoRecenterPolicy: Sendable {
    public var minimumSpeedKmh: Double = 15
    public var idleSeconds: TimeInterval = 10
    public var sustainSeconds: TimeInterval = 5
    public var maximumAccuracy: Double = 30

    private var fastSince: Date?

    public init() {}

    /// 每次收到定位就呼叫。回傳 true 表示現在要自動回到目前位置。
    public mutating func shouldRecenter(fix: VehicleFix, isFollowing: Bool, lastInteraction: Date?) -> Bool {
        guard !isFollowing else {
            fastSince = nil
            return false
        }
        let goodFix = fix.speedMps >= 0 && fix.horizontalAccuracy > 0 && fix.horizontalAccuracy <= maximumAccuracy
        guard goodFix, fix.speedKmh >= minimumSpeedKmh else {
            fastSince = nil
            return false
        }
        let since = fastSince ?? fix.timestamp
        fastSince = since
        guard fix.timestamp.timeIntervalSince(since) >= sustainSeconds else { return false }
        if let last = lastInteraction, fix.timestamp.timeIntervalSince(last) < idleSeconds {
            return false
        }
        fastSince = nil
        return true
    }
}
