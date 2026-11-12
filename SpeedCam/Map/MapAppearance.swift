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

    // 師大市區接河岸的示意線，只比較繪圖樣式，不代表可行駛路線。
    static let demoPolyline: MKPolyline = {
        let points: [(Double, Double)] = [
            (25.026266, 121.537650), (25.025132, 121.537556),
            (25.023500, 121.536100), (25.022472, 121.535033),
            (25.021279, 121.530923), (25.020242, 121.529817),
            (25.018700, 121.528500), (25.019800, 121.526200),
            (25.018600, 121.525600), (25.016000, 121.526300),
            (25.012700, 121.528500), (25.011100, 121.531000),
            (25.010500, 121.533600), (25.008000, 121.534000),
            (25.005919, 121.534214),
        ]
        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }
        return MKPolyline(coordinates: coordinates, count: coordinates.count)
    }()
    static let demoCameraCenter = CLLocationCoordinate2D(latitude: 25.0165, longitude: 121.5310)

    init(arguments: [String]) {
        routeLineStyle = Self.option("-routeLineStyle", in: arguments) ?? .current
        emphasis = Self.option("-mapEmphasis", in: arguments) ?? .current
        comparison = arguments.contains("-routeStyleDemo")
            ? Self.option("-routeComparison", in: arguments) ?? .preview : nil
    }

    private static func option<T: RawRepresentable>(_ key: String, in arguments: [String]) -> T? where T.RawValue == String {
        guard let i = arguments.firstIndex(of: key) else { return nil }
        guard i + 1 < arguments.count, let value = T(rawValue: arguments[i + 1]) else {
            Logger(subsystem: "tw.speedcammap.app", category: "launch").error("無效的地圖啟動參數：\(key, privacy: .public)")
            return nil
        }
        return value
    }
}
