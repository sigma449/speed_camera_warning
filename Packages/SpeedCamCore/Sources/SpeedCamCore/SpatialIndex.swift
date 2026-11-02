import Foundation

/// 以固定大小網格建立的空間索引，用來快速找出附近的照相點。
/// 全台約 2,500 筆資料，0.01°（約 1.1 公里）的格子就很夠用。
public struct SpatialIndex: Sendable {
    public let cellSize: Double
    private let cells: [CellKey: [Camera]]
    public let count: Int

    struct CellKey: Hashable, Sendable {
        let x: Int
        let y: Int
    }

    public init(cameras: [Camera], cellSize: Double = 0.01) {
        self.cellSize = cellSize
        var map: [CellKey: [Camera]] = [:]
        for cam in cameras {
            map[Self.key(lat: cam.lat, lon: cam.lon, cellSize: cellSize), default: []].append(cam)
        }
        self.cells = map
        self.count = cameras.count
    }

    static func key(lat: Double, lon: Double, cellSize: Double) -> CellKey {
        CellKey(x: Int(floor(lon / cellSize)), y: Int(floor(lat / cellSize)))
    }

    /// 找出某點半徑內的照相點，依距離由近到遠排序。
    public func cameras(near p: GeoPoint, radius: Double) -> [(camera: Camera, distance: Double)] {
        let latSpan = radius / 111_000
        let lonSpan = radius / max(1, 111_000 * cos(p.lat * .pi / 180))
        let candidates = cameras(minLat: p.lat - latSpan, maxLat: p.lat + latSpan,
                                 minLon: p.lon - lonSpan, maxLon: p.lon + lonSpan)
        var result: [(camera: Camera, distance: Double)] = []
        for cam in candidates {
            let d = GeoMath.distance(p, cam.point)
            if d <= radius { result.append((cam, d)) }
        }
        result.sort { $0.distance < $1.distance }
        return result
    }

    /// 找出矩形範圍內的照相點（地圖畫面用）。
    public func cameras(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double,
                        limit: Int = .max) -> [Camera] {
        let lo = Self.key(lat: minLat, lon: minLon, cellSize: cellSize)
        let hi = Self.key(lat: maxLat, lon: maxLon, cellSize: cellSize)
        // 畫面縮得太小時避免掃描過多格子：直接回傳空陣列，由 UI 提示「請放大地圖」。
        let cellCount = (hi.x - lo.x + 1) * (hi.y - lo.y + 1)
        guard cellCount > 0, cellCount <= 40_000 else { return [] }
        var out: [Camera] = []
        for y in lo.y...hi.y {
            for x in lo.x...hi.x {
                guard let list = cells[CellKey(x: x, y: y)] else { continue }
                for cam in list where cam.lat >= minLat && cam.lat <= maxLat
                    && cam.lon >= minLon && cam.lon <= maxLon {
                    out.append(cam)
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }
}
