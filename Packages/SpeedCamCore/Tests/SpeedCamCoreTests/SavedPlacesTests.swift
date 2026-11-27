import XCTest
@testable import SpeedCamCore

final class SavedPlacesTests: XCTestCase {
    private let point = GeoPoint(lat: 0, lon: 0)
    private let now = Date(timeIntervalSince1970: 123)
    private var places = SavedPlaces()

    @discardableResult
    private func save(_ kind: SavedPlace.Kind, _ name: String, _ subtitle: String = "",
                      at meters: Double = 0) throws -> SavedPlace {
        try places.save(kind, placeName: name, subtitle: subtitle,
                        point: GeoMath.destination(from: point, bearing: 0, distance: meters), now: now)
    }

    func testReplacementOrderAndRemoval() throws {
        let old = try save(.home, "舊家")
        let work = try save(.work, "辦公室")
        let favorite = try save(.favorite, "車站")
        let home = try save(.home, "新家")
        XCTAssertNotEqual(old.id, home.id)
        XCTAssertEqual(places.all, [home, work, favorite])
        places.remove(id: work.id)
        XCTAssertEqual(places.all, [home, favorite])
        places.remove(id: favorite.id)
        XCTAssertEqual(places.all, [home])
        places.remove(id: home.id)
        XCTAssertTrue(places.isEmpty)
    }

    func testDifferentNameNearbyOrSameNameFartherAwayAddsAFavorite() throws {
        let station = try save(.favorite, "車站")
        let shop = try save(.favorite, "商店", at: 20)
        let otherStation = try save(.favorite, "車站", at: 51)
        XCTAssertEqual(places.favorites, [station, shop, otherStation])
        XCTAssertEqual(Set(places.favorites.map(\.id)).count, 3)
    }

    func testNearbyDuplicateUpdatesInPlaceEvenWhenFull() throws {
        let first = try save(.favorite, " 車站 ")
        try places.rename(id: first.id, to: "集合點")
        for i in 1..<20 { try save(.favorite, "不同地點\(i)") }
        let ids = places.favorites.map(\.id)
        let updated = try save(.favorite, "車站", "新地址", at: 49)
        XCTAssertEqual(places.favorites.map(\.id), ids)
        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(updated.title, "集合點")
        XCTAssertEqual(updated.subtitle, "新地址")
        XCTAssertNotEqual(updated.point, first.point)
        XCTAssertThrowsError(try save(.favorite, "車站", at: 150)) {
            XCTAssertEqual($0 as? SavedPlaces.EditError, .tooManyFavorites)
        }
    }

    func testRejectsInvalidCoordinates() {
        for invalid in [GeoPoint(lat: .nan, lon: 0), GeoPoint(lat: 91, lon: 0),
                        GeoPoint(lat: 0, lon: .infinity), GeoPoint(lat: 0, lon: -181)] {
            XCTAssertThrowsError(try places.save(.home, placeName: "家", subtitle: "", point: invalid, now: now)) {
                XCTAssertEqual($0 as? SavedPlaces.EditError, .invalidCoordinate)
            }
        }
        XCTAssertTrue(places.isEmpty)
    }

    func testRenameAndUnnamedPlace() throws {
        let favorite = try save(.favorite, " \n", "路口")
        XCTAssertEqual(favorite.title, "路口")
        try places.rename(id: favorite.id, to: " 集合點\n")
        XCTAssertEqual(places.favorites.first?.title, "集合點")
        try places.rename(id: favorite.id, to: "\n")
        XCTAssertEqual(places.favorites.first?.title, "所選位置")
        try places.rename(id: favorite.id, to: String(repeating: "🇹🇼", count: 31))
        XCTAssertEqual(places.favorites.first?.title, String(repeating: "🇹🇼", count: 30))
        let home = try save(.home, "公寓")
        try places.rename(id: home.id, to: "新名字")
        XCTAssertEqual(places.home, home)
        XCTAssertThrowsError(try places.rename(id: UUID(), to: "路口")) {
            XCTAssertEqual($0 as? SavedPlaces.EditError, .notFound)
        }
    }

    func testMoveFavoritesInBothDirections() throws {
        for name in ["甲", "乙", "丙", "丁"] { try save(.favorite, name) }
        places.moveFavorites(fromOffsets: IndexSet([0, 2]), toOffset: 4)
        XCTAssertEqual(places.favorites.map(\.title), ["乙", "丁", "甲", "丙"])
        places.moveFavorites(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(places.favorites.map(\.title), ["甲", "乙", "丁", "丙"])
        // 超出範圍的索引與目的地不閃退：無效索引忽略、目的地夾在清單內
        places.moveFavorites(fromOffsets: IndexSet([0, 9]), toOffset: 99)
        XCTAssertEqual(places.favorites.map(\.title), ["乙", "丁", "丙", "甲"])
        places.moveFavorites(fromOffsets: IndexSet(integer: 3), toOffset: -5)
        XCTAssertEqual(places.favorites.map(\.title), ["甲", "乙", "丁", "丙"])
        places.moveFavorites(fromOffsets: IndexSet(integer: 7), toOffset: 0)
        XCTAssertEqual(places.favorites.map(\.title), ["甲", "乙", "丁", "丙"])
    }

    func testMatchesAndRecentUseDifferentRadiiAndNames() throws {
        // 50 m 邊界兩側各留 1 mm，避免來回換算的浮點誤差讓結果不穩。
        let home = try save(.home, "公寓", at: 49.999)
        let favorite = try save(.favorite, "商店", at: 49.9)
        try save(.work, "辦公室", at: 50.001)
        XCTAssertEqual(places.matches(point: point, placeName: "無關"), [home, favorite])
        XCTAssertTrue(places.hidesRecent(name: "公寓", point: point))
        let nearby = GeoMath.destination(from: point, bearing: 0, distance: 149.9)
        XCTAssertTrue(places.hidesRecent(name: "住家", point: nearby))
        XCTAssertFalse(places.hidesRecent(name: "別處", point: nearby))
        XCTAssertFalse(places.hidesRecent(name: "住家", point: GeoMath.destination(from: point, bearing: 0, distance: 151)))
    }

    func testCodableRoundTripAndMissingFavorites() throws {
        let home = try save(.home, "公寓")
        try save(.favorite, "商店")
        let data = try JSONEncoder().encode(places)
        XCTAssertEqual(try JSONDecoder().decode(SavedPlaces.self, from: data), places)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "favorites")
        let old = try JSONDecoder().decode(SavedPlaces.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.all, [home])
    }
}
