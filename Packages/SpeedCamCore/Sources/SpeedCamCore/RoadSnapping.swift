import Foundation

/// 把區間的路形「貼齊」地圖上的道路時用到的計算。
///
/// 資料處理產生的路形是里程牌座標連起來的，里程牌有空缺或位置偏差時，髮夾彎會被抄近路。
/// App 會用 Apple 地圖的路線規劃（MKDirections）沿著這條路形重新規劃，畫出來就跟地圖上的道路一致；
/// 這裡負責取中途點、判斷規劃出來的路線是不是同一條路（沒有繞到別條路）、簡化線條。
public enum RoadSnapping {
    /// 快取依方向別 ID 與精確門架配對；groupID 只用於共用容許值，不可共用路形。
    public static func cacheSignature(for section: SpeedSection) -> String {
        String(format: "%@|%.7f,%.7f>%.7f,%.7f", section.id,
               section.start.lat, section.start.lon, section.end.lat, section.end.lon)
    }

    /// 點到折線的最短距離（公尺）。
    public static func distance(from p: GeoPoint, to line: [GeoPoint]) -> Double {
        guard let first = line.first else { return .infinity }
        guard line.count >= 2 else { return GeoMath.distance(p, first) }
        var best = Double.infinity
        for i in 0..<(line.count - 1) {
            best = min(best, GeoMath.project(p, ontoSegment: line[i], line[i + 1]).distance)
        }
        return best
    }

    /// reference 每個點離 line 最遠的距離。用來判斷規劃出來的路線有沒有偏離原本的路形。
    public static func maxDeviation(of reference: [GeoPoint], from line: [GeoPoint]) -> Double {
        reference.map { distance(from: $0, to: line) }.max() ?? .infinity
    }

    /// 路線長度是否合理：在 expected × [minRatio, maxRatio] ± slack 之間。
    public static func isPlausible(routeLength: Double, expected: Double,
                                   minRatio: Double, maxRatio: Double, slack: Double) -> Bool {
        routeLength >= expected * minRatio - slack && routeLength <= expected * maxRatio + slack
    }

    /// 沿折線走 distance 公尺的位置。
    public static func point(along path: [GeoPoint], at distance: Double) -> GeoPoint {
        guard var prev = path.first else { return GeoPoint(lat: 0, lon: 0) }
        var walked = 0.0
        for p in path.dropFirst() {
            let step = GeoMath.distance(prev, p)
            if walked + step >= distance, step > 0 {
                let t = (distance - walked) / step
                return GeoPoint(lat: prev.lat + (p.lat - prev.lat) * t, lon: prev.lon + (p.lon - prev.lon) * t)
            }
            walked += step
            prev = p
        }
        return path.last ?? prev
    }

    /// 折線從 d0 到 d1 公尺的那一段（頭尾用內插點）。
    public static func subpath(_ path: [GeoPoint], from d0: Double, to d1: Double) -> [GeoPoint] {
        guard path.count >= 2 else { return path }
        var out = [point(along: path, at: d0)]
        var walked = 0.0
        for i in 1..<path.count {
            walked += GeoMath.distance(path[i - 1], path[i])
            if walked > d0 + 0.5 && walked < d1 - 0.5 {
                out.append(path[i])
            }
        }
        out.append(point(along: path, at: d1))
        return out
    }

    /// 把折線切成大約 spacing 公尺一段（等長），每段的頭尾就是規劃路線的起訖點。
    public static func segments(of path: [GeoPoint], spacing: Double) -> [[GeoPoint]] {
        guard path.count >= 2, spacing > 0 else { return [path] }
        let total = GeoMath.length(of: path)
        let n = max(1, Int((total / spacing).rounded()))
        let length: Double = total / Double(n)
        var result: [[GeoPoint]] = []
        for k in 0..<n {
            let from: Double = Double(k) * length
            let to: Double = (k == n - 1) ? total : Double(k + 1) * length
            result.append(subpath(path, from: from, to: to))
        }
        return result
    }

    /// Douglas–Peucker 簡化（偏差不超過 tolerance 公尺）。Apple 地圖的路線點很密，存起來前先簡化。
    public static func simplify(_ points: [GeoPoint], tolerance: Double) -> [GeoPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (i, j) = stack.popLast() {
            guard j > i + 1 else { continue }
            var best = 0.0
            var index = -1
            for k in (i + 1)..<j {
                let d = GeoMath.project(points[k], ontoSegment: points[i], points[j]).distance
                if d > best {
                    best = d
                    index = k
                }
            }
            if index >= 0 && best > tolerance {
                keep[index] = true
                stack.append((i, index))
                stack.append((index, j))
            }
        }
        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }

    /// 同一段區間的另一個方向：路形頭尾對調。依區間起點離路形哪一端比較近決定要不要反轉。
    public static func oriented(_ path: [GeoPoint], startingNear start: GeoPoint) -> [GeoPoint] {
        guard let first = path.first, let last = path.last else { return path }
        return GeoMath.distance(start, first) <= GeoMath.distance(start, last) ? path : path.reversed()
    }
}
