import XCTest
@testable import SpeedCamCore

final class RoadInstructionResolverTests: XCTestCase {
    private let text = "左轉上高速公路，朝(永和)、景美前進"

    private func east(_ meters: Double, north: Double = 0) -> GeoPoint {
        let point = GeoMath.destination(from: origin, bearing: 90, distance: meters)
        return GeoMath.destination(from: point, bearing: 0, distance: north)
    }

    private func resolver(lines: [[GeoPoint]], freeways: [[GeoPoint]] = []) -> RoadInstructionResolver {
        RoadInstructionResolver(freeways: freeways,
            namedRoads: [NamedRoadLine(name: "水源快速道路", lines: lines)])
    }

    func testNamedExpresswayChangesFullSpeechAndShortDisplayOnlyAtJoiningRoad() {
        let path = [east(0), east(2_000)]
        let corrected = resolver(lines: [path]).corrected(text, joining: path)
        XCTAssertEqual(corrected, "左轉上水源快速道路，朝(永和)、景美前進")
        XCTAssertEqual(ManeuverText.short(corrected), "左轉 上水源快速道路")
        XCTAssertEqual(AnnouncementFormatter.maneuver(instruction: corrected, distance: 200),
                       "200公尺後，左轉上水源快速道路，朝(永和)、景美前進")
    }

    func testConfirmedFreewayAndUnknownRoadKeepOriginal() {
        let path = [east(0), east(2_000)]
        XCTAssertEqual(resolver(lines: [path], freeways: [path]).corrected(text, joining: path), text)
        XCTAssertEqual(RoadInstructionResolver.empty.corrected(text, joining: path), text)
        XCTAssertEqual(resolver(lines: [path]).corrected(text, joining: []), text)
    }

    func testParallelCrossingAndLaterRoadDoNotGuessName() {
        let path = [east(0), east(2_000)]
        XCTAssertEqual(resolver(lines: [[east(0, north: 15), east(2_000, north: 15)]]).corrected(text, joining: path), text)
        XCTAssertEqual(resolver(lines: [[east(0, north: 30), east(2_000, north: 30)]]).corrected(text, joining: path), text)
        XCTAssertEqual(resolver(lines: [[east(150, north: -500), east(150, north: 500)]]).corrected(text, joining: path), text)
        XCTAssertEqual(resolver(lines: [[east(400), east(2_000)]]).corrected(text, joining: path), text)
        XCTAssertEqual(resolver(lines: [path]).corrected(text, joining: [east(0), east(60)]), text)
    }

    func testAmbiguousNamedRoadsAndNonHighwayInstructionsRemainUnchanged() {
        let path = [east(0), east(2_000)]
        let resolver = RoadInstructionResolver(freeways: [], namedRoads: [
            NamedRoadLine(name: "水源快速道路", lines: [path]), NamedRoadLine(name: "另一條道路", lines: [path]),
        ])
        XCTAssertEqual(resolver.corrected(text, joining: path), text)
        XCTAssertEqual(resolver.corrected("右轉進入水源路", joining: path), "右轉進入水源路")
    }

    func testRoadDataDecodesNamesAndKeepsOlderFilesCompatible() throws {
        let old = #"{"generatedAt":"2026-11-06","attribution":"OSM","freeways":[],"whitePlateRestricted":[]}"#
        let oldData = try RoadLineData.decode(from: Data(old.utf8))
        XCTAssertEqual(RoadInstructionResolver(freeways: oldData.freeways, namedRoads: oldData.namedRoads)
            .corrected(text, joining: [east(0), east(1_000)]), text)
        let named = old.dropLast() + #","namedRoads":[{"name":"水源快速道路","lines":[[[25.03,121.565],[25.03,121.585]]]}]}"#
        let data = try RoadLineData.decode(from: Data(named.utf8))
        let path = data.namedRoads[0].lines[0]
        XCTAssertEqual(RoadInstructionResolver(freeways: data.freeways, namedRoads: data.namedRoads)
            .corrected(text, joining: path), "左轉上水源快速道路，朝(永和)、景美前進")
    }
}
