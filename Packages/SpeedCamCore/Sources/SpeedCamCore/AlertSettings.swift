import Foundation

/// 提醒相關的所有可調整設定。預設值依照與使用者確認的規格：
/// - 一般道路：預告 300 m、近距 100 m
/// - 速限 ≥ 80 的道路（快速道路、高速公路）：預告 600 m、近距 200 m
/// - 超速時每 3 秒嗶一聲
/// - 區間測速：每分鐘、最後 30 秒、最後 10 秒、歸零各提醒一次
public struct AlertSettings: Codable, Equatable, Sendable {
    // MARK: 測速提醒距離
    public var generalPreDistance: Double = 300
    public var generalNearDistance: Double = 100
    public var fastPreDistance: Double = 600
    public var fastNearDistance: Double = 200
    /// 速限大於等於這個值，就視為快速道路或高速公路。
    public var fastRoadSpeedLimit: Int = 80

    // MARK: 超速警示
    /// 超過速限多少 km/h 才算超速（預設 0）。
    public var overspeedToleranceKmh: Double = 0
    /// 超速時嗶聲的間隔（秒）。
    public var overspeedBeepInterval: TimeInterval = 3

    // MARK: 方向判斷
    /// 行進方向與照相取締方向的容許夾角。
    public var directionTolerance: Double = 45
    /// 有方向資料時，照相點必須落在前方多少度以內（道路彎曲時需要寬一點）。
    public var aheadToleranceWithHeading: Double = 60
    /// 沒有方向資料時，照相點必須落在前方多少度以內。
    public var aheadToleranceWithoutHeading: Double = 30
    /// 低於這個速度（km/h）時 GPS 的行進方向不可靠，沿用上一次的方向。
    public var minimumSpeedForCourse: Double = 8

    // MARK: 通過判斷與冷卻
    /// 同一個照相點，離開多遠之後才會再次提醒。
    public var rearmDistance: Double = 1_000
    /// 或者經過多久之後才會再次提醒。
    public var rearmInterval: TimeInterval = 600

    // MARK: 區間測速
    /// 安全餘裕：最短合法時間再多加的比例（預設 3%）。
    public var sectionSafetyMargin: Double = 0.03
    /// 區間容許值（km/h）：倒數與區間內的超速嗶聲都以「速限＋容許值」計算。
    /// 預設 0（照表定速限）；例如北宜公路表定 40、寬限 50，可設成 10。
    public var sectionToleranceKmh: Double = 0
    /// 進入或離開區間時，與起終點的判定距離。
    public var sectionGateRadius: Double = 60
    /// 是否在最後 30 秒、10 秒額外提醒。
    public var sectionFinalCountdown: Bool = true

    // MARK: 其他
    public var voiceEnabled: Bool = true
    public var beepEnabled: Bool = true
    public var liveActivityEnabled: Bool = true
    public var vehicleMode: VehicleMode = .car

    public init() {}

    /// 依照相點速限（沒有的話用目前車速）決定預告與近距距離。
    public func thresholds(speedLimit: Int?, currentSpeedKmh: Double) -> (pre: Double, near: Double) {
        let isFastRoad: Bool
        if let limit = speedLimit {
            isFastRoad = limit >= fastRoadSpeedLimit
        } else {
            isFastRoad = currentSpeedKmh >= Double(fastRoadSpeedLimit)
        }
        return isFastRoad ? (fastPreDistance, fastNearDistance) : (generalPreDistance, generalNearDistance)
    }

    /// 區間的計算速度（速限＋區間容許值）。
    public func sectionEffectiveLimit(_ speedLimit: Int) -> Double {
        Double(speedLimit) + max(0, sectionToleranceKmh)
    }

    /// 搜尋附近照相點時使用的半徑（比最大預告距離再大一點）。
    public var searchRadius: Double {
        max(generalPreDistance, fastPreDistance) + 150
    }

    // 讓舊版存檔缺少新欄位時也能解碼（缺的欄位用預設值）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlertSettings()
        generalPreDistance = try c.decodeIfPresent(Double.self, forKey: .generalPreDistance) ?? d.generalPreDistance
        generalNearDistance = try c.decodeIfPresent(Double.self, forKey: .generalNearDistance) ?? d.generalNearDistance
        fastPreDistance = try c.decodeIfPresent(Double.self, forKey: .fastPreDistance) ?? d.fastPreDistance
        fastNearDistance = try c.decodeIfPresent(Double.self, forKey: .fastNearDistance) ?? d.fastNearDistance
        fastRoadSpeedLimit = try c.decodeIfPresent(Int.self, forKey: .fastRoadSpeedLimit) ?? d.fastRoadSpeedLimit
        overspeedToleranceKmh = try c.decodeIfPresent(Double.self, forKey: .overspeedToleranceKmh) ?? d.overspeedToleranceKmh
        overspeedBeepInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .overspeedBeepInterval) ?? d.overspeedBeepInterval
        directionTolerance = try c.decodeIfPresent(Double.self, forKey: .directionTolerance) ?? d.directionTolerance
        aheadToleranceWithHeading = try c.decodeIfPresent(Double.self, forKey: .aheadToleranceWithHeading) ?? d.aheadToleranceWithHeading
        aheadToleranceWithoutHeading = try c.decodeIfPresent(Double.self, forKey: .aheadToleranceWithoutHeading) ?? d.aheadToleranceWithoutHeading
        minimumSpeedForCourse = try c.decodeIfPresent(Double.self, forKey: .minimumSpeedForCourse) ?? d.minimumSpeedForCourse
        rearmDistance = try c.decodeIfPresent(Double.self, forKey: .rearmDistance) ?? d.rearmDistance
        rearmInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .rearmInterval) ?? d.rearmInterval
        sectionSafetyMargin = try c.decodeIfPresent(Double.self, forKey: .sectionSafetyMargin) ?? d.sectionSafetyMargin
        sectionToleranceKmh = try c.decodeIfPresent(Double.self, forKey: .sectionToleranceKmh) ?? d.sectionToleranceKmh
        sectionGateRadius = try c.decodeIfPresent(Double.self, forKey: .sectionGateRadius) ?? d.sectionGateRadius
        sectionFinalCountdown = try c.decodeIfPresent(Bool.self, forKey: .sectionFinalCountdown) ?? d.sectionFinalCountdown
        voiceEnabled = try c.decodeIfPresent(Bool.self, forKey: .voiceEnabled) ?? d.voiceEnabled
        beepEnabled = try c.decodeIfPresent(Bool.self, forKey: .beepEnabled) ?? d.beepEnabled
        liveActivityEnabled = try c.decodeIfPresent(Bool.self, forKey: .liveActivityEnabled) ?? d.liveActivityEnabled
        vehicleMode = try c.decodeIfPresent(VehicleMode.self, forKey: .vehicleMode) ?? d.vehicleMode
    }
}
