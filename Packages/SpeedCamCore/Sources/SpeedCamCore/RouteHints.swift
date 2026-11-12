import Foundation

public struct RouteHint: Codable, Equatable, Sendable {
    public var id: String
    public var point: GeoPoint
    public var heading: Double
    public var confirmation: GeoPoint
    public var radius: Double
    public var shortText: String
    public var instruction: String
    public var source: String
    public var replaces: [String]?

    public init(id: String, point: GeoPoint, heading: Double, confirmation: GeoPoint, radius: Double = 15,
                shortText: String, instruction: String, source: String, replaces: [String] = []) {
        self.id = id
        self.point = point
        self.heading = heading
        self.confirmation = confirmation
        self.radius = radius
        self.shortText = shortText
        self.instruction = instruction
        self.source = source
        self.replaces = replaces
    }

    public static func decode(from data: Data) throws -> [RouteHint] {
        let hints = try JSONDecoder().decode([RouteHint].self, from: data)
        guard !hints.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "導航提示資料為空"))
        }
        var ids = Set<String>()
        for hint in hints {
            let validPoints = [hint.point, hint.confirmation].allSatisfy {
                $0.lat.isFinite && $0.lon.isFinite && (21.8...25.4).contains($0.lat) && (119.3...122.1).contains($0.lon)
            }
            guard !hint.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ids.insert(hint.id).inserted, validPoints,
                  hint.heading.isFinite, (0..<360).contains(hint.heading),
                  hint.radius.isFinite, hint.radius > 0, hint.radius <= 30,
                  GeoMath.distance(hint.point, hint.confirmation) >= 20,
                  [hint.shortText, hint.instruction, hint.source].allSatisfy({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }), (hint.replaces ?? []).allSatisfy({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "無效或重複的導航提示：\(hint.id)"))
            }
        }
        return hints
    }
}

public struct RouteHintMatch: Equatable, Sendable {
    public var hint: RouteHint
    public var along: Double
    public var confirmationAlong: Double
}

/// 只依規劃路線的有序接續補提示，不憑目前位置猜橋上、橋下或哪一個匝道。
public enum RouteHintMatcher {
    public static func matches(_ hints: [RouteHint], polyline: [GeoPoint]) -> [RouteHintMatch] {
        guard polyline.count >= 2 else { return [] }
        var cumulative = [0.0]
        for (a, b) in zip(polyline, polyline.dropFirst()) {
            cumulative.append(cumulative.last! + GeoMath.distance(a, b))
        }
        func projections(_ point: GeoPoint, radius: Double, heading: Double?) -> [(along: Double, lateral: Double)] {
            var result: [(Double, Double)] = []
            for i in 0..<(polyline.count - 1) {
                let a = polyline[i], b = polyline[i + 1]
                let length = cumulative[i + 1] - cumulative[i]
                guard length > 0 else { continue }
                if let heading, GeoMath.angleDifference(heading, GeoMath.bearing(from: a, to: b)) > 45 { continue }
                let projection = GeoMath.project(point, ontoSegment: a, b)
                if projection.distance <= radius {
                    result.append((cumulative[i] + projection.t * length, projection.distance))
                }
            }
            return result
        }
        var result: [RouteHintMatch] = []
        var used = Set<String>()
        for hint in hints where used.insert(hint.id).inserted {
            let entries = projections(hint.point, radius: hint.radius, heading: hint.heading)
            let exits = projections(hint.confirmation, radius: hint.radius, heading: nil)
            // 不能繞了一大圈才碰到後續點，或先走另一個分支再回來。
            let maxSpan = max(100, GeoMath.distance(hint.point, hint.confirmation) * 2 + hint.radius * 2)
            let pairs = entries.flatMap { entry in
                exits.compactMap { exit -> (Double, Double, Double)? in
                    let span = exit.along - entry.along
                    guard span >= 20, span <= maxSpan else { return nil }
                    return (entry.along, exit.along, entry.lateral + exit.lateral)
                }
            }
            guard let best = pairs.min(by: { $0.2 < $1.2 }) else { continue }
            // 同一路線若有多次互不相鄰的符合位置，無法唯一確認就不補。
            guard pairs.allSatisfy({ abs($0.0 - best.0) <= hint.radius * 2 }) else { continue }
            result.append(RouteHintMatch(hint: hint, along: best.0, confirmationAlong: best.1))
        }
        return result.sorted { $0.along < $1.along }
    }

    /// 插入同一條導航時間軸，共用既有轉彎門檻、語音優先順序及重複抑制。
    public static func steps(_ original: [RouteStepInfo], matches: [RouteHintMatch],
                             totalDistance: Double) -> [RouteStepInfo] {
        guard !matches.isEmpty, !original.isEmpty else { return original }
        let sum = original.reduce(0) { $0 + max(0, $1.distance) }
        guard sum > 0, totalDistance > 0 else { return original }
        var position = 0.0
        var entries = original.enumerated().map { index, step -> (position: Double, order: Int, step: RouteStepInfo) in
            position += max(0, step.distance) * totalDistance / sum
            return (position, index, step)
        }
        var used = Set<String>()
        for match in matches where used.insert(match.hint.id).inserted {
            let step = RouteStepInfo(instruction: match.hint.instruction, distance: 0,
                                     shortInstruction: match.hint.shortText, hintID: match.hint.id)
            let nearby = entries.indices.filter {
                entries[$0].step.hintID == nil && !entries[$0].step.instruction.isEmpty
                    && !entries[$0].step.instruction.contains("抵達")
                    && abs(entries[$0].position - match.along) <= 40
                    && (entries[$0].step.instruction == match.hint.instruction
                        || (match.hint.replaces ?? []).contains(where: entries[$0].step.instruction.contains))
            }.min { abs(entries[$0].position - match.along) < abs(entries[$1].position - match.along) }
            if let nearby {
                entries[nearby].step = step
                entries[nearby].position = match.along
            } else {
                entries.append((match.along, original.count + entries.count, step))
            }
        }
        entries.sort { $0.position == $1.position ? $0.order < $1.order : $0.position < $1.position }
        var previous = 0.0
        return entries.map { entry in
            var step = entry.step
            step.distance = max(0, entry.position - previous)
            previous = entry.position
            return step
        }
    }
}
