import XCTest
@testable import SpeedCamCore

final class MapPlaceSelectionTests: XCTestCase {
    private let point = GeoPoint(lat: 25.0478, lon: 121.5170)

    func testSelectionWaitsForExplicitPreviewAction() throws {
        var selection = MapPlaceSelection()
        try selection.select(point: point, name: "台北車站", mode: .browsing)
        XCTAssertEqual(selection.place?.point, point)
        XCTAssertEqual(selection.place?.name, "台北車站")
        let destination = selection.takeForPreview(mode: .browsing)
        XCTAssertEqual(destination?.point, point)
        XCTAssertNil(selection.place)
        XCTAssertNil(selection.takeForPreview(mode: .browsing))
    }

    func testNavigationAndPreviewRejectNewSelectionAndConsumption() throws {
        for mode in [MapPlaceSelection.Mode.navigating, .previewing] {
            var selection = MapPlaceSelection()
            try selection.select(point: point, name: "原選點", mode: .browsing)
            let original = selection.place
            XCTAssertNil(try selection.select(point: GeoPoint(lat: 24, lon: 120), name: "誤觸", mode: mode))
            XCTAssertNil(selection.takeForPreview(mode: mode))
            XCTAssertEqual(selection.place, original)
        }
    }

    func testReverseGeocodingKeepsLongPressedCoordinate() throws {
        var selection = MapPlaceSelection()
        let id = try XCTUnwrap(try selection.select(point: point, name: nil, mode: .browsing))
        XCTAssertTrue(selection.resolveAddress(id: id, name: "附近地址", address: "臺北市中正區北平西路"))
        XCTAssertEqual(selection.place?.name, "附近地址")
        XCTAssertEqual(selection.takeForPreview(mode: .browsing)?.point, point)
    }

    func testOldAddressCannotReplaceNewPointOrPOIName() throws {
        var selection = MapPlaceSelection()
        let old = try XCTUnwrap(try selection.select(point: point, name: nil, mode: .browsing))
        let nextPoint = GeoPoint(lat: 24.8016, lon: 120.9717)
        let next = try XCTUnwrap(try selection.select(point: nextPoint, name: "新竹車站", mode: .browsing))
        XCTAssertFalse(selection.resolveAddress(id: old, name: "舊地址", address: "臺北"))
        XCTAssertTrue(selection.place?.isResolvingAddress == true)
        XCTAssertTrue(selection.resolveAddress(id: next, name: "其他地標", address: "新竹市東區中華路二段"))
        XCTAssertEqual(selection.place?.name, "新竹車站")
        XCTAssertEqual(selection.place?.point, nextPoint)
        XCTAssertFalse(selection.place?.isResolvingAddress == true)
    }

    func testDismissAndPreviewIgnorePendingAddressResults() throws {
        var selection = MapPlaceSelection()
        let closed = try XCTUnwrap(try selection.select(point: point, name: nil, mode: .browsing))
        selection.cancel()
        XCTAssertFalse(selection.resolveAddress(id: closed, name: "晚到的地址", address: "臺北"))
        XCTAssertNil(selection.place)
        let started = try XCTUnwrap(try selection.select(point: point, name: nil, mode: .browsing))
        XCTAssertNotNil(selection.takeForPreview(mode: .browsing))
        XCTAssertFalse(selection.resolveAddress(id: started, name: nil, address: "晚到的地址"))
        XCTAssertNil(selection.place)
    }

    func testMissingAddressStillAllowsPreviewAtChosenPoint() throws {
        var selection = MapPlaceSelection()
        let id = try XCTUnwrap(try selection.select(point: point, name: " 地圖地點 ", mode: .browsing))
        XCTAssertTrue(selection.resolveAddress(id: id, name: nil, address: " \n"))
        XCTAssertTrue(selection.place?.addressUnavailable == true)
        XCTAssertEqual(selection.place?.name, "地圖地點")
        XCTAssertEqual(selection.takeForPreview(mode: .browsing)?.point, point)
    }

    func testInvalidCoordinatesDoNotReplaceValidSelection() throws {
        var selection = MapPlaceSelection()
        try selection.select(point: point, name: nil, mode: .browsing)
        let original = selection.place
        for invalid in [GeoPoint(lat: .nan, lon: 121), GeoPoint(lat: 25, lon: .infinity),
                        GeoPoint(lat: 91, lon: 121), GeoPoint(lat: 25, lon: -181)] {
            XCTAssertThrowsError(try selection.select(point: invalid, name: nil, mode: .browsing))
            XCTAssertEqual(selection.place, original)
        }
    }
}
