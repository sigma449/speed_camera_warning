import CoreLocation
import MapKit
import SpeedCamCore

/// MapKit 相關的小工具。把可能被標為「已棄用」的 API 集中在這裡，之後要換新 API 只改一處。
enum MapItems {
    static func item(at p: GeoPoint) -> MKMapItem {
        make(CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon))
    }

    static func subtitle(of item: MKMapItem) -> String {
        item.placemark.title ?? ""
    }

    static func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        if #available(iOS 26, *), !LegacySupport.forced {
            return item.location.coordinate
        }
        return item.placemark.coordinate
    }

    /// 最近目的地用：用座標和名稱建立地點。
    static func item(name: String, coordinate: CLLocationCoordinate2D) -> MKMapItem {
        let item = make(coordinate)
        item.name = name
        return item
    }

    private static func make(_ coordinate: CLLocationCoordinate2D) -> MKMapItem {
        if #available(iOS 26, *), !LegacySupport.forced {
            return MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
    }

    /// 「850 公尺」「3.2 公里」「25 公里」
    static func distanceText(from origin: CLLocationCoordinate2D?, to target: CLLocationCoordinate2D) -> String? {
        guard let origin else { return nil }
        let meters = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
        if meters < 1_000 { return "\(Int((meters / 10).rounded()) * 10) 公尺" }
        if meters < 10_000 { return String(format: "%.1f 公里", meters / 1_000) }
        return "\(Int((meters / 1_000).rounded())) 公里"
    }

    static func distance(from origin: CLLocationCoordinate2D?, to target: CLLocationCoordinate2D) -> Double {
        guard let origin else { return 0 }
        return CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
    }

    static func coordinates(of polyline: MKPolyline) -> [GeoPoint] {
        let count = polyline.pointCount
        guard count > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords.map { GeoPoint(lat: $0.latitude, lon: $0.longitude) }
    }

    /// 導航用的步驟。長度用每一步折線的實際長度：整條路線的折線就是這些折線接起來，
    /// 轉彎點才會落在正確的位置。Apple 回報的距離和折線差到 2.3%，開到後面會累積成幾百公尺。
    static func stepInfos(of route: MKRoute, resolver: RoadInstructionResolver = .empty) -> [RouteStepInfo] {
        let paths = route.steps.map { coordinates(of: $0.polyline) }
        return route.steps.enumerated().map { index, step in
            let points = paths[index]
            var length = 0.0
            for (a, b) in zip(points, points.dropFirst()) {
                length += GeoMath.distance(a, b)
            }
            var joining: [GeoPoint] = []
            if step.instructions.contains("上高速公路") {
                for next in paths.dropFirst(index + 1) {
                    joining += joining.isEmpty ? next : Array(next.dropFirst())
                    if GeoMath.length(of: joining) >= 600 { break }
                }
            }
            return RouteStepInfo(instruction: resolver.corrected(step.instructions, joining: joining), distance: length)
        }
    }
}

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

extension Camera {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }

    /// 地圖與 Live Activity 使用的 SF Symbol。
    var symbolName: String {
        switch type {
        case .fixed: return "camera.fill"
        case .redLight: return "exclamationmark.octagon.fill"
        case .redLightSpeed: return "camera.fill"
        case .section: return "timer"
        case .tech: return "video.fill"
        case .mobile: return "binoculars.fill"
        }
    }
}
