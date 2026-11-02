import Foundation

/// 經緯度座標（WGS84，單位：度）。
public struct GeoPoint: Codable, Hashable, Sendable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

/// 地理計算工具。距離單位一律為公尺，角度一律為度（正北 0°、順時針）。
public enum GeoMath {
    public static let earthRadius: Double = 6_371_008.8

    @inline(__always) static func rad(_ deg: Double) -> Double { deg * .pi / 180 }
    @inline(__always) static func deg(_ rad: Double) -> Double { rad * 180 / .pi }

    /// 兩點間的大圓距離（haversine）。
    public static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let dLat = rad(b.lat - a.lat)
        let dLon = rad(b.lon - a.lon)
        let s = sin(dLat / 2) * sin(dLat / 2)
            + cos(rad(a.lat)) * cos(rad(b.lat)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(s)))
    }

    /// 從 a 前往 b 的初始方位角（0..<360）。
    public static func bearing(from a: GeoPoint, to b: GeoPoint) -> Double {
        let φ1 = rad(a.lat), φ2 = rad(b.lat)
        let Δλ = rad(b.lon - a.lon)
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return normalize(deg(atan2(y, x)))
    }

    /// 把角度正規化到 0..<360。
    public static func normalize(_ angle: Double) -> Double {
        let r = angle.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// 兩個方位角之間的最小夾角（0...180）。
    public static func angleDifference(_ a: Double, _ b: Double) -> Double {
        let d = abs(normalize(a) - normalize(b))
        return d > 180 ? 360 - d : d
    }

    /// 從起點沿某方位角前進一段距離後的座標。
    public static func destination(from p: GeoPoint, bearing: Double, distance: Double) -> GeoPoint {
        let δ = distance / earthRadius
        let θ = rad(bearing)
        let φ1 = rad(p.lat), λ1 = rad(p.lon)
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return GeoPoint(lat: deg(φ2), lon: normalizeLon(deg(λ2)))
    }

    static func normalizeLon(_ lon: Double) -> Double {
        var l = lon
        while l > 180 { l -= 360 }
        while l < -180 { l += 360 }
        return l
    }

    /// 點到線段的投影結果。
    public struct SegmentProjection: Equatable, Sendable {
        /// 投影點在線段上的比例（0...1）。
        public var t: Double
        /// 點到線段的距離（公尺）。
        public var distance: Double
        /// 投影點。
        public var point: GeoPoint
    }

    /// 計算點 p 投影到線段 a→b 的位置。
    /// 使用以 a 為原點的局部等距投影，對幾公里內的線段誤差可以忽略。
    public static func project(_ p: GeoPoint, ontoSegment a: GeoPoint, _ b: GeoPoint) -> SegmentProjection {
        let cosLat = cos(rad(a.lat))
        let mPerDegLat = earthRadius * .pi / 180
        let mPerDegLon = mPerDegLat * cosLat
        let bx = (b.lon - a.lon) * mPerDegLon
        let by = (b.lat - a.lat) * mPerDegLat
        let px = (p.lon - a.lon) * mPerDegLon
        let py = (p.lat - a.lat) * mPerDegLat
        let len2 = bx * bx + by * by
        var t = 0.0
        if len2 > 0 {
            t = max(0, min(1, (px * bx + py * by) / len2))
        }
        let qx = bx * t, qy = by * t
        let dx = px - qx, dy = py - qy
        let point = GeoPoint(lat: a.lat + qy / mPerDegLat,
                             lon: mPerDegLon == 0 ? a.lon : a.lon + qx / mPerDegLon)
        return SegmentProjection(t: t, distance: sqrt(dx * dx + dy * dy), point: point)
    }

    /// 折線的總長度。
    public static func length(of polyline: [GeoPoint]) -> Double {
        guard polyline.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<polyline.count {
            total += distance(polyline[i - 1], polyline[i])
        }
        return total
    }
}

/// 單位換算。
public enum SpeedUnit {
    public static func kmh(fromMps mps: Double) -> Double { mps * 3.6 }
    public static func mps(fromKmh kmh: Double) -> Double { kmh / 3.6 }
}
