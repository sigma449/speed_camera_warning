import Foundation
import MapKit
import SpeedCamCore

/// 讀取 App 內建的測速資料，並提供展示模式用的假資料。
enum CameraStore {

    static func loadBundled() -> CameraDatabase {
        guard let url = Bundle.main.url(forResource: "cameras", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let db = try? CameraDatabase.decode(from: data) else {
            return .empty
        }
        return db
    }

    // MARK: - 展示模式（-demo），CI 截圖與沒有真實資料時使用

    /// 台北市信義區附近（市府路一帶）的展示起點。
    static let demoOrigin = GeoPoint(lat: 25.0300, lon: 121.5650)

    static func demoDatabase() -> CameraDatabase {
        let o = demoOrigin
        func north(_ m: Double) -> GeoPoint { GeoMath.destination(from: o, bearing: 0, distance: m) }
        let c1 = north(600)
        let c2 = GeoMath.destination(from: north(900), bearing: 90, distance: 250)
        let c3 = GeoMath.destination(from: north(300), bearing: 270, distance: 400)
        let sectionStart = north(1_200)
        let sectionEnd = north(3_200)
        return CameraDatabase(
            version: "demo",
            generatedAt: "",
            sources: ["展示資料（非真實照相點）"],
            cameras: [
                Camera(id: "demo-1", type: .fixed, lat: c1.lat, lon: c1.lon, heading: 0, speedLimit: 50, address: "展示路一段（固定測速）"),
                Camera(id: "demo-2", type: .redLightSpeed, lat: c2.lat, lon: c2.lon, heading: 90, speedLimit: 50, address: "展示路二段（測速及闖紅燈）"),
                Camera(id: "demo-3", type: .tech, lat: c3.lat, lon: c3.lon, heading: nil, speedLimit: nil, address: "展示街（科技執法）"),
                Camera(id: "demo-s", type: .section, lat: sectionStart.lat, lon: sectionStart.lon, heading: 0, speedLimit: 60, address: "展示區間起點"),
            ],
            sections: [
                SpeedSection(id: "demo-section", name: "展示區間", start: sectionStart, end: sectionEnd,
                             lengthMeters: 2_000, speedLimit: 60),
            ]
        )
    }

    /// 展示用的行車軌跡：往北以 62 km/h 行駛（超過 50 的速限，示範超速警示），之後進入區間。
    static func demoTrack(startTime: Date) -> [VehicleFix] {
        let mps = SpeedUnit.mps(fromKmh: 62)
        return (0...240).map { i in
            let p = GeoMath.destination(from: demoOrigin, bearing: 0, distance: mps * Double(i))
            return VehicleFix(point: p, speedMps: mps, course: 0, horizontalAccuracy: 5,
                              timestamp: startTime.addingTimeInterval(Double(i)))
        }
    }
}

/// 區間長度是估算值時，用 Apple 地圖的道路距離修正，並快取在本機。
enum SectionLengthRefiner {
    private static let cacheKey = "sectionLengthCache.v1"

    static func applyCached(to sections: [SpeedSection]) -> [SpeedSection] {
        let cache = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: Double] ?? [:]
        return sections.map { s in
            guard s.lengthEstimated, let len = cache[s.id] else { return s }
            var copy = s
            copy.lengthMeters = len
            return copy
        }
    }

    /// 對所有估算長度的區間查詢道路距離（只查還沒快取的）。回傳是否有更新。
    static func refine(_ sections: [SpeedSection]) async -> [SpeedSection] {
        var cache = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: Double] ?? [:]
        var result = sections
        for (i, s) in sections.enumerated() where s.lengthEstimated && cache[s.id] == nil {
            let request = MKDirections.Request()
            request.source = MapItems.item(at: s.start)
            request.destination = MapItems.item(at: s.end)
            request.transportType = .automobile
            if let route = try? await MKDirections(request: request).calculate().routes.first {
                cache[s.id] = route.distance
                result[i].lengthMeters = route.distance
            }
        }
        UserDefaults.standard.set(cache, forKey: cacheKey)
        return result
    }
}
