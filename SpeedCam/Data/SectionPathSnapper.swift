import Foundation
import MapKit
import os
import SpeedCamCore

/// 用 Apple 地圖的路線規劃，把區間的路形貼齊地圖上的道路，結果存在本機（每段只算一次）。
///
/// 做法：
/// 1. 先直接規劃「起點 → 終點」。路線長度接近區間長度、而且沒有偏離原本的里程牌路形（200 m 內）就採用。
/// 2. 不行的話（例如最快路線繞到別條路），沿著里程牌路形每 1.2 公里取一個點，一段一段規劃再接起來；
///    某一段不合理就用那段原本的里程牌路形。
/// 3. 都不行就維持原本的路形，7 天後再試。
///
/// Apple 地圖的路線規劃有頻率限制，所以一次只查一個，間隔 1.5 秒，並優先處理離地圖中心近的區間。
@MainActor
final class SectionPathSnapper {
    private struct Entry: Codable {
        var signature: String
        var path: [[Double]]?
        var failedAt: Date?
    }

    /// 某一段（groupID）貼齊完成時呼叫，path 是該段第一個方向（起點 → 終點）的路形。
    var onSnapped: ((String, [GeoPoint]) -> Void)?

    private var cache: [String: Entry] = [:]
    private var pending: [String: SpeedSection] = [:]
    private var center: GeoPoint?
    private var worker: Task<Void, Never>?
    private let log = Logger(subsystem: "tw.speedcammap.app", category: "snap")

    private static let retryInterval: TimeInterval = 7 * 24 * 3600
    private static let requestGap: UInt64 = 1_500_000_000

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            cache = saved
        }
    }

    /// 已經貼齊過的路形（方向與這個區間一致）。
    func cachedPath(for section: SpeedSection) -> [GeoPoint]? {
        guard let entry = cache[section.groupID], entry.signature == Self.signature(section),
              let raw = entry.path else { return nil }
        let points = raw.compactMap { $0.count >= 2 ? GeoPoint(lat: $0[0], lon: $0[1]) : nil }
        guard points.count >= 2 else { return nil }
        return RoadSnapping.oriented(points, startingNear: section.start)
    }

    /// 把還沒貼齊的區間排進佇列（每段只需要一個方向）。near 是地圖中心或目前位置，越近越先處理。
    func enqueue(_ sections: [SpeedSection], near: GeoPoint?) {
        if let near { center = near }
        for s in sections where pending[s.groupID] == nil && needsSnapping(s) {
            pending[s.groupID] = s
        }
        startWorkerIfNeeded()
    }

    private func needsSnapping(_ s: SpeedSection) -> Bool {
        guard let entry = cache[s.groupID], entry.signature == Self.signature(s) else { return true }
        if entry.path != nil { return false }
        if let failed = entry.failedAt, Date().timeIntervalSince(failed) < Self.retryInterval { return false }
        return true
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task { [weak self] in
            while let self, let next = self.popNearest() {
                let path = await self.snap(next)
                self.store(next, path: path)
                if let path {
                    self.onSnapped?(next.groupID, path)
                }
            }
            self?.worker = nil
        }
    }

    private func popNearest() -> SpeedSection? {
        guard !pending.isEmpty else { return nil }
        let pick: SpeedSection?
        if let center {
            pick = pending.values.min {
                GeoMath.distance(center, $0.start) < GeoMath.distance(center, $1.start)
            }
        } else {
            pick = pending.values.first
        }
        if let pick { pending.removeValue(forKey: pick.groupID) }
        return pick
    }

    private func store(_ section: SpeedSection, path: [GeoPoint]?) {
        cache[section.groupID] = Entry(signature: Self.signature(section),
                                       path: path?.map { [($0.lat * 1e6).rounded() / 1e6, ($0.lon * 1e6).rounded() / 1e6] },
                                       failedAt: path == nil ? Date() : nil)
        if let data = try? JSONEncoder().encode(cache) {
            try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    // MARK: 貼齊

    private func snap(_ section: SpeedSection) async -> [GeoPoint]? {
        let reference = section.displayPath
        let expected = section.lengthEstimated ? GeoMath.length(of: reference) : section.lengthMeters

        // 1) 起點 → 終點一次規劃；不合理再試反方向（起點可能被吸到快速道路對向車道，要繞一大圈迴轉）
        for reversed in [false, true] {
            let (a, b) = reversed ? (section.end, section.start) : (section.start, section.end)
            guard let route = await route(from: a, to: b) else { continue }
            let deviation = RoadSnapping.maxDeviation(of: reference, from: route.points)
            if RoadSnapping.isPlausible(routeLength: route.distance, expected: expected,
                                        minRatio: 0.85, maxRatio: 1.2, slack: 150),
               deviation <= 200 {
                log.notice("\(section.groupID, privacy: .public): 一次規劃成功\(reversed ? "（反方向）" : "", privacy: .public)（\(Int(route.distance)) m，偏差 \(Int(deviation)) m）")
                let points = reversed ? Array(route.points.reversed()) : route.points
                return RoadSnapping.simplify(points, tolerance: 3)
            }
            log.notice("\(section.groupID, privacy: .public): 一次規劃不合理\(reversed ? "（反方向）" : "", privacy: .public)（\(Int(route.distance)) m / 預期 \(Int(expected)) m，偏差 \(Int(deviation)) m）")
        }

        // 2) 沿著里程牌路形分段規劃
        guard reference.count >= 2 else { return nil }
        var output: [GeoPoint] = []
        var snappedSegments = 0
        let segments = RoadSnapping.segments(of: reference, spacing: 1_200)
        for segment in segments {
            guard let a = segment.first, let b = segment.last else { continue }
            var piece = segment
            let segmentLength = GeoMath.length(of: segment)
            for reversed in [false, true] {
                guard let route = await route(from: reversed ? b : a, to: reversed ? a : b) else { continue }
                if RoadSnapping.isPlausible(routeLength: route.distance, expected: segmentLength,
                                            minRatio: 0.8, maxRatio: 1.6, slack: 200),
                   RoadSnapping.maxDeviation(of: segment, from: route.points) <= 200 {
                    piece = reversed ? Array(route.points.reversed()) : route.points
                    snappedSegments += 1
                    break
                }
            }
            output += output.isEmpty ? piece : Array(piece.dropFirst())
        }
        log.notice("\(section.groupID, privacy: .public): 分段規劃 \(snappedSegments)／\(segments.count) 段成功")
        guard snappedSegments > 0 else { return nil }
        return RoadSnapping.simplify(output, tolerance: 3)
    }

    private func route(from a: GeoPoint, to b: GeoPoint) async -> (points: [GeoPoint], distance: Double)? {
        for attempt in 0..<2 {
            try? await Task.sleep(nanoseconds: Self.requestGap)
            let request = MKDirections.Request()
            request.source = MapItems.item(at: a)
            request.destination = MapItems.item(at: b)
            request.transportType = .automobile
            request.requestsAlternateRoutes = false
            do {
                guard let route = try await MKDirections(request: request).calculate().routes.first else { return nil }
                return (MapItems.coordinates(of: route.polyline), route.distance)
            } catch {
                if let mk = error as? MKError, mk.code == .loadingThrottled, attempt == 0 {
                    log.notice("路線規劃被限流，等 60 秒再試")
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    continue
                }
                return nil
            }
        }
        return nil
    }

    // MARK: 存檔

    /// 起訖點變了（資料更新）就重新貼齊。兩個方向共用同一個結果，所以起訖點排序後再組合。
    private static func signature(_ s: SpeedSection) -> String {
        let a = String(format: "%.5f,%.5f", s.start.lat, s.start.lon)
        let b = String(format: "%.5f,%.5f", s.end.lat, s.end.lon)
        return a < b ? "\(a)-\(b)" : "\(b)-\(a)"
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("snappedSectionPaths.v1.json")
    }
}
