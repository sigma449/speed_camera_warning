import CoreLocation
import MapKit
import SpeedCamCore

/// MapKit 相關的小工具。把可能被標為「已棄用」的 API 集中在這裡，之後要換新 API 只改一處。
enum MapItems {
    static func item(at p: GeoPoint) -> MKMapItem {
        MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)))
    }

    static func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        item.placemark.coordinate
    }

    static func subtitle(of item: MKMapItem) -> String {
        item.placemark.title ?? ""
    }

    static func coordinates(of polyline: MKPolyline) -> [GeoPoint] {
        let count = polyline.pointCount
        guard count > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords.map { GeoPoint(lat: $0.latitude, lon: $0.longitude) }
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
