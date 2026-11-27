import Foundation
import SpeedCamCore

enum SavedPlaceStore {
    private static let key = "savedPlaces.v1"

    static func load() -> (SavedPlaces, warning: String?) {
        let defaults = UserDefaults.standard
        guard let original = defaults.object(forKey: key) else { return (SavedPlaces(), nil) }
        if let data = original as? Data, let places = try? JSONDecoder().decode(SavedPlaces.self, from: data) {
            return (places, nil)
        }
        let backup = key + ".unreadable"
        if defaults.object(forKey: backup) == nil { defaults.set(original, forKey: backup) }
        return (SavedPlaces(), "常用地點資料讀不到，已保留原始資料；重新設定後會另存新檔")
    }

    static func save(_ places: SavedPlaces) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(places), forKey: key)
    }
}
