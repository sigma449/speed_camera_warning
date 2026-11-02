import Foundation
import XCTest
@testable import SpeedCamCore

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
/// 台北市區附近的起點
let origin = GeoPoint(lat: 25.0300, lon: 121.5650)

/// 產生等速直線行駛的軌跡（每秒一筆）。
func straightTrack(from start: GeoPoint, bearing: Double, speedKmh: Double,
                   seconds: Int, startTime: Date = t0) -> [VehicleFix] {
    let mps = SpeedUnit.mps(fromKmh: speedKmh)
    return (0...seconds).map { i in
        let p = GeoMath.destination(from: start, bearing: bearing, distance: mps * Double(i))
        return VehicleFix(point: p, speedMps: mps, course: bearing,
                          horizontalAccuracy: 5, timestamp: startTime.addingTimeInterval(Double(i)))
    }
}

/// 由多段（方位角、速度、秒數）組成的軌跡。
func segmentedTrack(from start: GeoPoint, segments: [(bearing: Double, speedKmh: Double, seconds: Int)],
                    startTime: Date = t0) -> [VehicleFix] {
    var fixes: [VehicleFix] = []
    var p = start
    var t = startTime
    for (index, seg) in segments.enumerated() {
        let mps = SpeedUnit.mps(fromKmh: seg.speedKmh)
        let first = index == 0 ? 0 : 1
        for i in first...seg.seconds {
            let q = GeoMath.destination(from: p, bearing: seg.bearing, distance: mps * Double(i))
            fixes.append(VehicleFix(point: q, speedMps: mps, course: seg.bearing,
                                    horizontalAccuracy: 5, timestamp: t.addingTimeInterval(Double(i))))
        }
        p = GeoMath.destination(from: p, bearing: seg.bearing, distance: mps * Double(seg.seconds))
        t = t.addingTimeInterval(Double(seg.seconds))
    }
    return fixes
}

struct TimedEvent<E> {
    let time: TimeInterval
    let event: E
}

func runAlerts(_ engine: CameraAlertEngine, _ fixes: [VehicleFix]) -> [TimedEvent<CameraAlertEvent>] {
    var out: [TimedEvent<CameraAlertEvent>] = []
    for f in fixes {
        for e in engine.process(f).events {
            out.append(TimedEvent(time: f.timestamp.timeIntervalSince(t0), event: e))
        }
    }
    return out
}

func runSections(_ tracker: SectionSpeedTracker, _ fixes: [VehicleFix]) -> [TimedEvent<SectionEvent>] {
    var out: [TimedEvent<SectionEvent>] = []
    for f in fixes {
        for e in tracker.process(f).events {
            out.append(TimedEvent(time: f.timestamp.timeIntervalSince(t0), event: e))
        }
    }
    return out
}

func runRoute(_ tracker: RouteProgressTracker, _ fixes: [VehicleFix]) -> [TimedEvent<RouteEvent>] {
    var out: [TimedEvent<RouteEvent>] = []
    for f in fixes {
        for e in tracker.process(f).events {
            out.append(TimedEvent(time: f.timestamp.timeIntervalSince(t0), event: e))
        }
    }
    return out
}

/// 簡易 GPX 讀取：取出 trkpt 的座標與時間，速度與方向由相鄰點推算。
enum GPXReplay {
    static func load(named name: String) throws -> [VehicleFix] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "gpx", subdirectory: "Fixtures") else {
            throw NSError(domain: "GPXReplay", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到 \(name).gpx"])
        }
        return try parse(String(contentsOf: url, encoding: .utf8))
    }

    static func parse(_ xml: String) throws -> [VehicleFix] {
        let formatter = ISO8601DateFormatter()
        var points: [(GeoPoint, Date)] = []
        let chunks = xml.components(separatedBy: "<trkpt").dropFirst()
        for chunk in chunks {
            guard let lat = attribute("lat", in: chunk), let lon = attribute("lon", in: chunk),
                  let timeStart = chunk.range(of: "<time>"), let timeEnd = chunk.range(of: "</time>"),
                  let date = formatter.date(from: String(chunk[timeStart.upperBound..<timeEnd.lowerBound]))
            else { continue }
            points.append((GeoPoint(lat: lat, lon: lon), date))
        }
        var fixes: [VehicleFix] = []
        for (i, (p, date)) in points.enumerated() {
            var speed = 0.0
            var course: Double? = nil
            if i > 0 {
                let (prev, prevDate) = points[i - 1]
                let dt = max(0.1, date.timeIntervalSince(prevDate))
                speed = GeoMath.distance(prev, p) / dt
                course = GeoMath.bearing(from: prev, to: p)
            }
            fixes.append(VehicleFix(point: p, speedMps: speed, course: course, horizontalAccuracy: 5, timestamp: date))
        }
        return fixes
    }

    private static func attribute(_ name: String, in s: String) -> Double? {
        guard let r = s.range(of: "\(name)=\"") else { return nil }
        let rest = s[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return Double(rest[..<end])
    }
}

extension CameraAlertEvent {
    var isPre: Bool { if case .preAlert = self { return true }; return false }
    var isNear: Bool { if case .nearAlert = self { return true }; return false }
    var isPassed: Bool { if case .passed = self { return true }; return false }
    var isOverspeedStarted: Bool { if case .overspeedStarted = self { return true }; return false }
    var isBeep: Bool { if case .overspeedBeep = self { return true }; return false }
    var isOverspeedEnded: Bool { if case .overspeedEnded = self { return true }; return false }
    var distance: Double? {
        switch self {
        case let .preAlert(_, d), let .nearAlert(_, d): return d
        default: return nil
        }
    }
}
