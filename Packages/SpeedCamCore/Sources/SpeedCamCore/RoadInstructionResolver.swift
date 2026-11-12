import Foundation

/// 只用動作點「之後」的接續路形認路，不以整條路線 hasHighways 或起點附近的路名猜測。
public struct RoadInstructionResolver: Sendable {
    private let freeways: RoadMatcher
    private let named: [(name: String, matcher: RoadMatcher)]

    public static let empty = RoadInstructionResolver(freeways: [], namedRoads: [])

    public init(freeways: [[GeoPoint]], namedRoads: [NamedRoadLine]) {
        self.freeways = RoadMatcher(lines: freeways)
        named = namedRoads.filter { $0.freewayRef == nil && !$0.name.isEmpty }
            .map { ($0.name, RoadMatcher(lines: $0.lines)) }
    }

    public func corrected(_ instruction: String, joining path: [GeoPoint]) -> String {
        guard instruction.contains("上高速公路"), path.count >= 2 else { return instruction }
        let joined = RoadSnapping.subpath(path, from: 0, to: min(600, GeoMath.length(of: path)))
        let freeway = freeways.overlap(with: joined)
        guard freeway.total < 80 || freeway.longestCloseRun < 80 else { return instruction }
        let entrance = RoadSnapping.subpath(joined, from: 0, to: min(300, GeoMath.length(of: joined)))
        let matches = named.filter {
            let whole = $0.matcher.overlap(with: joined)
            let early = $0.matcher.overlap(with: entrance)
            return whole.total >= 150 && whole.longestCloseRun >= 150
                && early.total >= 80 && early.longestCloseRun >= 80
        }
        guard matches.count == 1, let road = matches.first else { return instruction }
        return instruction.replacingOccurrences(of: "上高速公路", with: "上" + road.name)
    }
}
