import Combine
import Foundation
import MapKit
import SwiftUI

/// 一筆候選。畫面需要的文字在收到結果時就先算好，清單用自己的 id，不用陣列索引。
///
/// 之前用 `ForEach(suggestions.indices)` 再用索引取資料：打中文時候選會一直更新、數量會變，
/// 畫面還拿舊的索引去取新的陣列就會超出範圍而閃退（使用者回報、CI 壓力測試重現）。
struct SearchSuggestion: Identifiable {
    let id: String
    let completion: MKLocalSearchCompletion
    let title: AttributedString
    let subtitle: String
    let isCategory: Bool
}

/// 邊打字邊顯示候選地點（像 Google 地圖的自動完成），用 MapKit 的 MKLocalSearchCompleter。
@MainActor
final class SearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [SearchSuggestion] = []
    @Published private(set) var failed = false

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address, .query]
    }

    /// 每次輸入改變就呼叫。center 是目前位置，候選會優先顯示附近的地點。
    func update(query: String, near center: CLLocationCoordinate2D?) {
        if let center {
            completer.region = MKCoordinateRegion(center: center, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        let text = query.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            completer.cancel()
            suggestions = []
            failed = false
        } else {
            completer.queryFragment = text
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            var seen = Set<String>()
            self.suggestions = completer.results.enumerated().map { index, c in
                var id = "\(c.title)|\(c.subtitle)"
                if !seen.insert(id).inserted { id += "#\(index)" }
                return SearchSuggestion(id: id, completion: c,
                                        title: Self.highlighted(c.title, ranges: c.titleHighlightRanges),
                                        subtitle: c.subtitle, isCategory: c.subtitle.isEmpty)
            }
            self.failed = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.failed = true
        }
    }

    /// 把符合輸入的部分標成粗體。
    static func highlighted(_ text: String, ranges: [NSValue]) -> AttributedString {
        var attributed = AttributedString(text)
        for value in ranges {
            guard let range = Range(value.rangeValue, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }
}

/// 最近的目的地（存在 UserDefaults，最多 15 筆）。
struct RecentDestination: Codable, Hashable, Identifiable {
    var name: String
    var subtitle: String
    var lat: Double
    var lon: Double
    var date: Date

    var id: String { "\(name)|\(String(format: "%.4f,%.4f", lat, lon))" }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

enum RecentDestinationStore {
    private static let key = "recentDestinations.v1"
    static let maxCount = 15

    static func load() -> [RecentDestination] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([RecentDestination].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [RecentDestination]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 加到最前面；同名而且在 100 公尺內的視為同一個地點，只保留最新的。
    static func adding(_ entry: RecentDestination, to list: [RecentDestination]) -> [RecentDestination] {
        let here = CLLocation(latitude: entry.lat, longitude: entry.lon)
        var result = list.filter { old in
            !(old.name == entry.name && CLLocation(latitude: old.lat, longitude: old.lon).distance(from: here) < 100)
        }
        result.insert(entry, at: 0)
        return Array(result.prefix(maxCount))
    }
}

/// 沒有輸入時顯示的快速搜尋按鈕。
struct QuickCategory: Identifiable, Hashable {
    let title: String
    let symbol: String
    var id: String { title }

    static let all: [QuickCategory] = [
        QuickCategory(title: "加油站", symbol: "fuelpump.fill"),
        QuickCategory(title: "停車場", symbol: "parkingsign"),
        QuickCategory(title: "便利商店", symbol: "cart.fill"),
        QuickCategory(title: "休息站", symbol: "cup.and.saucer.fill"),
        QuickCategory(title: "充電站", symbol: "bolt.car.fill"),
    ]
}
