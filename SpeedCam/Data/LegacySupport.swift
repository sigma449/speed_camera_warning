import Foundation

/// App 最低支援 iOS 15，只為了用舊手機（iPhone 7）測 App 內的功能。
/// iOS 17 以上走原本的程式，舊系統才走替代做法：
/// - 地圖：`LegacyMapView`（MKMapView），因為 SwiftUI 的 Map 要 iOS 17 才能畫路線和自訂標記
/// - 定位：CLLocationManager，因為 CLLocationUpdate 要 iOS 17
/// - Live Activity：iOS 16.2 以前沒有，什麼都不做
/// - 路線：iOS 16 以前不能要求 Apple 避開高速或收費，也看不到路線有沒有這些路段，只能比對國道線形
///
/// CI 的「路線實測」也會編譯這個檔案，所以不能依賴 UIKit 或 SwiftUI。
enum LegacySupport {
    /// `-legacyUI`：在新系統上也走舊系統的做法，CI 才截得到圖、測得到。
    static let forced = ProcessInfo.processInfo.arguments.contains("-legacyUI")

    static var supportsLiveActivity: Bool {
        if #available(iOS 16.2, *) { return !forced }
        return false
    }

    /// 能不能要求 Apple 避開高速或收費（`MKDirections.Request.highwayPreference`），
    /// 並知道路線有沒有這些路段（`MKRoute.hasHighways`）。
    static var supportsRoutePreferences: Bool {
        if #available(iOS 16, *) { return !forced }
        return false
    }
}
