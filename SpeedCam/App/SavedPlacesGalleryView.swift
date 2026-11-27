import SpeedCamCore
import SwiftUI

enum SavedPlacesGalleryData {
    static let searchCenter = GeoPoint(lat: 25.0164, lon: 121.4625)
    private static let homePoint = GeoPoint(lat: 25.0162, lon: 121.4632)
    static let card = MapPlaceSelection.Place(point: GeoMath.destination(from: homePoint, bearing: 90, distance: 25),
        name: "文化路一段188巷口（示例）", address: "新北市板橋區文化路一段188巷", isResolvingAddress: false)

    static func samples() throws -> (SavedPlaces, [RecentDestination]) {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var places = SavedPlaces()
        let home = try places.save(.home, placeName: "文化路一段188巷（示例）", subtitle: "新北市板橋區文化路一段188巷",
                                   point: homePoint, now: now)
        try places.save(.favorite, placeName: "台北車站東三門", subtitle: "臺北市中正區北平西路3號",
                        point: GeoPoint(lat: 25.0478, lon: 121.5170), now: now)
        try places.save(.favorite, placeName: "國道3號木柵休息站", subtitle: "臺北市文山區（示例）",
                        point: GeoPoint(lat: 24.995, lon: 121.593), now: now)
        try places.save(.favorite, placeName: "臺灣新竹地方法院新竹簡易庭（長名稱示例）", subtitle: "新竹市東區（示例）",
                        point: GeoPoint(lat: 24.802, lon: 120.976), now: now)
        return (places, [
            RecentDestination(name: home.placeName, subtitle: home.subtitle, lat: homePoint.lat, lon: homePoint.lon, date: now),
            RecentDestination(name: "板橋車站", subtitle: "新北市板橋區站前路", lat: 25.014, lon: 121.464, date: now),
        ])
    }
}

struct SavedPlacesGalleryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var style = BannerCombineStyle.defaultStyle
    @State private var feedback: String?
    private let scenario: String

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        scenario = arguments.firstIndex(of: "-gallerySavedPlaces").flatMap { arguments.dropFirst($0 + 1).first } ?? ""
    }

    var body: some View {
        Group {
            if let warning = model.savedPlacesWarning {
                Text(warning)
            } else {
                switch scenario {
                case "search": SearchView(autoFocus: false)
                case "assign": SearchView(assigning: .work, autoFocus: false)
                case "card", "card-menu": card
                case "settings": AdaptiveNavigationStack { SavedPlacesView() }
                case "rename":
                    if let place = model.savedPlaces.favorites.last {
                        SavedPlaceRenameView(place: place) { try model.renameSavedPlace(id: place.id, title: $0) }
                    } else {
                        Text("找不到改名示例")
                    }
                case "banner-style":
                    AdaptiveNavigationStack {
                        Form { BannerStyleSettings(selection: $style) }
                            .navigationTitle("設定")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                default: Text("無效的常用地點 gallery 情境：\(scenario)")
                }
            }
        }
        .frame(maxWidth: 375)
        .frame(maxWidth: .infinity)
    }

    private var card: some View {
        let place = SavedPlacesGalleryData.card
        return ScrollView {
            MapPlaceCard(place: place, savedMatches: model.savedPlaces.matches(point: place.point, placeName: place.name),
                         home: model.savedPlaces.home, work: model.savedPlaces.work, feedback: feedback,
                         openMenuOnAppear: scenario == "card-menu", onSave: { kind in
                             do {
                                 try model.savePlace(kind, mapPlace: place)
                                 feedback = kind.savedMessage
                             } catch { feedback = error.localizedDescription }
                         }, onRemoveSaved: { match in
                             model.removeSavedPlace(id: match.id)
                             feedback = "已移除"
                         }, onStart: {}, onAddCamera: {}, onClose: {})
                .padding(12)
        }
        .background(Color(white: 0.3))
    }
}
