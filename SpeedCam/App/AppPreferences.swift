import Foundation

/// App 層級的偏好設定。跟提醒邏輯無關，所以不放在 SpeedCamCore 的 AlertSettings。
enum AppPreferences {
    /// 開啟 App 時自動開始巡航（測速偵測）。SettingsView 用同一個 key 的 @AppStorage。
    static let autoStartCruiseKey = "autoStartCruise"

    static var autoStartCruise: Bool {
        UserDefaults.standard.object(forKey: autoStartCruiseKey) as? Bool ?? true
    }
}

/// 地圖標示與搜尋結果使用的語言。
///
/// MapKit 沒有單獨指定語言的 API，地圖上的地名和搜尋結果都跟著 App 的語言走。
/// 這裡用的是 iOS「個別 App 語言」同一個機制：寫入 App 自己的 `AppleLanguages`，
/// 重新開啟 App 後生效。App 內的文字是寫死的中文，不受影響。
enum MapLanguage: String, CaseIterable, Identifiable {
    case system
    case traditionalChinese = "zh-Hant-TW"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟隨 iPhone 設定"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }

    private static let appleLanguagesKey = "AppleLanguages"

    /// 目前儲存的選擇。直接讀 App 自己的設定檔，所以在 iPhone「設定 → App → 語言」改的也讀得到。
    static var selected: MapLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: id)?[appleLanguagesKey] as? [String],
              let first = languages.first else {
            return .system
        }
        if first.hasPrefix("zh") { return .traditionalChinese }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    static func select(_ language: MapLanguage) {
        let defaults = UserDefaults.standard
        if language == .system {
            defaults.removeObject(forKey: appleLanguagesKey)
        } else {
            defaults.set([language.rawValue], forKey: appleLanguagesKey)
        }
    }

    /// 這次執行實際使用的語言（改了設定要重新開啟 App 才會變）。
    static var active: String {
        Locale.preferredLanguages.first ?? "—"
    }
}
