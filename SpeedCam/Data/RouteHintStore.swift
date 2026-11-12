import Foundation
import SpeedCamCore

enum RouteHintStore {
    static let attribution = "導航補充提示：使用者實測；道路接續 © OpenStreetMap 貢獻者（ODbL）"

    private static let content = Result<[RouteHint], Error> {
        guard let url = Bundle.main.url(forResource: "route_hints", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try RouteHint.decode(from: Data(contentsOf: url))
    }

    static func load() throws -> [RouteHint] { try content.get() }
}
