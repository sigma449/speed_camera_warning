import CryptoKit
import Foundation
import MapKit
import os
import UIKit

enum RouteLineStyle: String {
    case current, whiteCasing, darkCasing

    var casingColor: UIColor? {
        switch self {
        case .current: return nil
        case .whiteCasing: return .white
        case .darkCasing: return .black
        }
    }

    static func lineWidth(isPreview: Bool) -> CGFloat { isPreview ? 8 : 7 }
}

enum MapEmphasis: String {
    case current, muted
}

enum RouteComparisonMode: String {
    case preview, navigation3D
}

/// 只讀本次啟動參數，不寫入使用者偏好設定。
struct MapAppearance {
    let routeLineStyle: RouteLineStyle
    let emphasis: MapEmphasis
    let comparison: RouteComparisonMode?

    static let comparisonSource = CLLocationCoordinate2D(latitude: 25.0468, longitude: 121.5366)
    init(arguments: [String]) {
        routeLineStyle = Self.option("-routeLineStyle", in: arguments) ?? .current
        emphasis = Self.option("-mapEmphasis", in: arguments) ?? .current
        comparison = Self.option("-routeComparison", in: arguments)
    }

    private static func option<T: RawRepresentable>(_ key: String, in arguments: [String]) -> T? where T.RawValue == String {
        guard let i = arguments.firstIndex(of: key) else { return nil }
        guard i + 1 < arguments.count, let value = T(rawValue: arguments[i + 1]) else {
            Logger(subsystem: "tw.speedcammap.app", category: "launch").error("無效的地圖啟動參數：\(key, privacy: .public)")
            return nil
        }
        return value
    }

    static func signature(of route: MKRoute) -> String {
        let points = MapItems.coordinates(of: route.polyline)
        let data = Data(points.map { "\($0.lat),\($0.lon)" }.joined(separator: ";").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
