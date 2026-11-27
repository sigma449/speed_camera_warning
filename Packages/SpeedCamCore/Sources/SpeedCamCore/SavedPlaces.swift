import Foundation

public struct SavedPlace: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case home, work, favorite }

    public var id: UUID
    public var kind: Kind
    public var title: String
    public var placeName: String
    public var subtitle: String
    public var point: GeoPoint
    public var createdAt: Date

    public var displayTitle: String {
        switch kind {
        case .home: return "住家"
        case .work: return "公司"
        case .favorite: return title
        }
    }
}

public struct SavedPlaces: Codable, Equatable, Sendable {
    public static let maxFavorites = 20
    public static let maxTitleLength = 30
    public static let sameSpotMeters = 50.0

    public enum EditError: LocalizedError, Equatable {
        case invalidCoordinate, tooManyFavorites, notFound

        public var errorDescription: String? {
            switch self {
            case .invalidCoordinate: return "座標無效"
            case .tooManyFavorites: return "常用地點最多 20 個，請先刪除不用的"
            case .notFound: return "找不到這個常用地點"
            }
        }
    }

    public private(set) var home: SavedPlace?
    public private(set) var work: SavedPlace?
    public private(set) var favorites: [SavedPlace] = []
    public var all: [SavedPlace] { [home, work].compactMap { $0 } + favorites }
    public var isEmpty: Bool { home == nil && work == nil && favorites.isEmpty }

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        home = try values.decodeIfPresent(SavedPlace.self, forKey: .home)
        work = try values.decodeIfPresent(SavedPlace.self, forKey: .work)
        favorites = try values.decodeIfPresent([SavedPlace].self, forKey: .favorites) ?? []
    }

    @discardableResult
    public mutating func save(_ kind: SavedPlace.Kind, placeName: String, subtitle: String,
                              point: GeoPoint, now: Date) throws -> SavedPlace {
        guard point.lat.isFinite, point.lon.isFinite, (-90...90).contains(point.lat),
              (-180...180).contains(point.lon) else { throw EditError.invalidCoordinate }
        let trimmed = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "所選位置" : trimmed
        if kind == .favorite {
            if let i = favorites.firstIndex(where: {
                $0.placeName == name && GeoMath.distance($0.point, point) <= Self.sameSpotMeters
            }) {
                favorites[i].subtitle = subtitle
                favorites[i].point = point
                return favorites[i]
            }
            guard favorites.count < Self.maxFavorites else { throw EditError.tooManyFavorites }
        }
        let title = kind == .favorite && name == "所選位置" && !subtitle.isEmpty ? subtitle : name
        let place = SavedPlace(id: UUID(), kind: kind, title: title, placeName: name, subtitle: subtitle,
                               point: point, createdAt: now)
        switch kind {
        case .home: home = place
        case .work: work = place
        case .favorite: favorites.append(place)
        }
        return place
    }

    public mutating func rename(id: UUID, to title: String) throws {
        if id == home?.id || id == work?.id { return }
        guard let i = favorites.firstIndex(where: { $0.id == id }) else { throw EditError.notFound }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        favorites[i].title = trimmed.isEmpty ? favorites[i].placeName : String(trimmed.prefix(Self.maxTitleLength))
    }

    public mutating func remove(id: UUID) {
        if home?.id == id { home = nil }
        if work?.id == id { work = nil }
        favorites.removeAll { $0.id == id }
    }

    public mutating func moveFavorites(fromOffsets: IndexSet, toOffset: Int) {
        // 超出範圍的索引直接忽略，避免畫面與資料不同步時閃退。
        let offsets = IndexSet(fromOffsets.filter { favorites.indices.contains($0) })
        guard !offsets.isEmpty else { return }
        let target = min(max(toOffset, 0), favorites.count)
        let moving = offsets.map { favorites[$0] }
        let destination = target - offsets.count(in: 0..<target)
        for i in offsets.reversed() { favorites.remove(at: i) }
        favorites.insert(contentsOf: moving, at: min(destination, favorites.count))
    }

    public func matches(point: GeoPoint, placeName: String?) -> [SavedPlace] {
        all.filter { GeoMath.distance($0.point, point) <= Self.sameSpotMeters }
    }

    public func hidesRecent(name: String, point: GeoPoint) -> Bool {
        all.contains {
            ($0.placeName == name || $0.displayTitle == name) && GeoMath.distance($0.point, point) <= 100
        }
    }
}
