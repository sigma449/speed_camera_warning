import Foundation

/// 照相類型。
public enum CameraType: String, Codable, CaseIterable, Sendable {
    /// 固定式測速
    case fixed
    /// 闖紅燈照相
    case redLight
    /// 測速兼闖紅燈
    case redLightSpeed
    /// 區間測速的照相點（起點或終點）
    case section
    /// 科技執法（不停讓、違規轉彎等）
    case tech
    /// 流動測速熱點
    case mobile

    /// 語音和畫面上使用的中文名稱。
    public var displayName: String {
        switch self {
        case .fixed: return "測速照相"
        case .redLight: return "闖紅燈照相"
        case .redLightSpeed: return "測速及闖紅燈照相"
        case .section: return "區間測速"
        case .tech: return "科技執法"
        case .mobile: return "流動測速"
        }
    }

    /// 這種照相會不會取締超速（決定要不要做超速警示）。
    public var enforcesSpeed: Bool {
        switch self {
        case .fixed, .redLightSpeed, .section, .mobile: return true
        case .redLight, .tech: return false
        }
    }
}

/// 一個測速照相點。
public struct Camera: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: CameraType
    public var lat: Double
    public var lon: Double
    /// 取締的行車方向（車輛行進的方位角）。nil 表示資料沒有方向或雙向。
    public var heading: Double?
    /// 雙向照相的道路軸向：0 = 南北向、90 = 東西向。nil 表示不知道。
    /// 有 heading 時不使用。
    public var axis: Double?
    /// 速限（km/h）。
    public var speedLimit: Int?
    public var address: String
    public var city: String?
    public var district: String?

    public init(id: String, type: CameraType, lat: Double, lon: Double,
                heading: Double? = nil, speedLimit: Int? = nil,
                address: String = "", city: String? = nil, district: String? = nil,
                axis: Double? = nil) {
        self.id = id
        self.type = type
        self.lat = lat
        self.lon = lon
        self.heading = heading
        self.axis = axis
        self.speedLimit = speedLimit
        self.address = address
        self.city = city
        self.district = district
    }

    public var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }
}

/// 一段區間測速。
public struct SpeedSection: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var start: GeoPoint
    public var end: GeoPoint
    /// 區間長度（公尺）。
    public var lengthMeters: Double
    /// 區間速限（km/h）。
    public var speedLimit: Int
    /// 長度是不是估算值（沒有官方長度時為 true）。
    public var lengthEstimated: Bool
    /// 起點附近的道路方向（由里程牌資料計算）。山路彎曲時比起終點直線方向準確。
    public var startHeading: Double?
    /// 沿路的座標（起點 → 終點，由里程牌資料產生），地圖上順著路形畫區間用。沒有時畫直線。
    public var path: [GeoPoint]?

    public init(id: String, name: String, start: GeoPoint, end: GeoPoint,
                lengthMeters: Double, speedLimit: Int, lengthEstimated: Bool = false,
                startHeading: Double? = nil, path: [GeoPoint]? = nil) {
        self.id = id
        self.name = name
        self.start = start
        self.end = end
        self.lengthMeters = lengthMeters
        self.speedLimit = speedLimit
        self.lengthEstimated = lengthEstimated
        self.startHeading = startHeading
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, start, end, lengthMeters, speedLimit, lengthEstimated, startHeading, path
    }

    /// JSON 裡的 path 是 [[緯度, 經度], ...]，比 {"lat":…,"lon":…} 小很多。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        start = try c.decode(GeoPoint.self, forKey: .start)
        end = try c.decode(GeoPoint.self, forKey: .end)
        lengthMeters = try c.decode(Double.self, forKey: .lengthMeters)
        speedLimit = try c.decode(Int.self, forKey: .speedLimit)
        lengthEstimated = try c.decodeIfPresent(Bool.self, forKey: .lengthEstimated) ?? false
        startHeading = try c.decodeIfPresent(Double.self, forKey: .startHeading)
        let raw = (try? c.decodeIfPresent([[Double]].self, forKey: .path)) ?? nil
        let points = raw?.compactMap { $0.count >= 2 ? GeoPoint(lat: $0[0], lon: $0[1]) : nil }
        path = (points?.count ?? 0) >= 2 ? points : nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(lengthMeters, forKey: .lengthMeters)
        try c.encode(speedLimit, forKey: .speedLimit)
        try c.encode(lengthEstimated, forKey: .lengthEstimated)
        try c.encodeIfPresent(startHeading, forKey: .startHeading)
        try c.encodeIfPresent(path?.map { [$0.lat, $0.lon] }, forKey: .path)
    }

    /// 地圖上要畫的線：有沿路座標就用它，否則畫起終點直線。
    public var displayPath: [GeoPoint] {
        if let path, path.count >= 2 { return path }
        return [start, end]
    }

    /// 起點往終點的直線方位角。
    public var heading: Double { GeoMath.bearing(from: start, to: end) }

    /// 判斷是否同方向進入區間時使用的方向：有起點道路方向就用它，否則用起終點直線方向。
    public var entryHeading: Double { startHeading ?? heading }

    /// 同一段區間的兩個方向（id 結尾 -f／-r）共用的群組 ID，用於個別容許值設定。
    public var groupID: String {
        if id.hasSuffix("-f") || id.hasSuffix("-r") {
            return String(id.dropLast(2))
        }
        return id
    }

    /// 群組顯示名稱：去掉結尾的方向說明（例如「（往宜蘭）」）。
    public var displayGroupName: String {
        guard name.hasSuffix("）"), let open = name.range(of: "（往", options: .backwards) else { return name }
        return String(name[..<open.lowerBound])
    }

    /// 以速限行駛完整區間所需的最短秒數（不含安全餘裕）。
    public var minimumSeconds: Double {
        minimumSeconds(atKmh: Double(speedLimit))
    }

    /// 以指定時速（例如速限＋容許值）行駛完整區間所需的最短秒數。
    public func minimumSeconds(atKmh kmh: Double) -> Double {
        guard kmh > 0 else { return 0 }
        return lengthMeters / SpeedUnit.mps(fromKmh: kmh)
    }
}

/// App 內建的資料庫檔案（cameras.json）。
public struct CameraDatabase: Codable, Sendable {
    public var version: String
    public var generatedAt: String
    /// 資料來源與授權標示。
    public var sources: [String]
    public var cameras: [Camera]
    public var sections: [SpeedSection]

    public init(version: String, generatedAt: String, sources: [String],
                cameras: [Camera], sections: [SpeedSection]) {
        self.version = version
        self.generatedAt = generatedAt
        self.sources = sources
        self.cameras = cameras
        self.sections = sections
    }

    public static func decode(from data: Data) throws -> CameraDatabase {
        try JSONDecoder().decode(CameraDatabase.self, from: data)
    }

    public static let empty = CameraDatabase(version: "empty", generatedAt: "",
                                             sources: [], cameras: [], sections: [])
}

/// 車種模式。
public enum VehicleMode: String, Codable, CaseIterable, Sendable {
    case car
    case motorcycle

    public var displayName: String {
        switch self {
        case .car: return "汽車"
        case .motorcycle: return "重機"
        }
    }
}

/// 一筆定位資料（由 App 從 CLLocation 轉換而來）。
public struct VehicleFix: Sendable, Equatable {
    public var point: GeoPoint
    /// 速度（m/s），負值表示無效。
    public var speedMps: Double
    /// 行進方位角，nil 表示無效。
    public var course: Double?
    /// 水平精度（公尺）。
    public var horizontalAccuracy: Double
    public var timestamp: Date

    public init(point: GeoPoint, speedMps: Double, course: Double?,
                horizontalAccuracy: Double = 5, timestamp: Date) {
        self.point = point
        self.speedMps = speedMps
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
    }

    public var speedKmh: Double { max(0, SpeedUnit.kmh(fromMps: speedMps)) }
}
