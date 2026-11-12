// 路線實測：用真正的 MapKit 規劃台灣的路線。Apple 怎麼走、文件沒有寫，只能實測。
// 只在 CI 的 macOS runner 上跑（scripts/ci/route-probe.sh），不會編進 App。
//
// 用法：RouteProbe <compare|plan> <路線清單.json> <結果檔.jsonl> [road_lines.json]
// - compare：比較不同避開設定實際走的路，每種設定回傳的路線都記下來。
// - plan：用 App 的 RoutePlanner 和 RouteRules，看三種車種實際選到哪條路。
// 結果一行一筆，包含路線的距離、時間、步驟文字和路線座標。

import CoreLocation
import Foundation
import MapKit
import SpeedCamCore

setvbuf(stdout, nil, _IOLBF, 0)

struct Place: Decodable {
    let name: String
    let lat: Double
    let lon: Double
    /// 有 query 時，座標只是搜尋中心；查不到就使案例失敗，不用中心冒充目的地。
    let query: String?
}

struct ProbeCase: Decodable {
    /// 這條路線用來測哪一類道路
    let group: String
    /// 走最快路線時，預期會用到的道路
    let expected: String
    let from: Place
    let to: Place
    /// 只跑這幾種設定；沒寫就全部跑
    let configs: [String]?
}

struct ProbeConfig {
    let key: String
    let highway: MKDirections.RoutePreference
    let toll: MKDirections.RoutePreference
}

let configs = [
    ProbeConfig(key: "不避開", highway: .any, toll: .any),
    ProbeConfig(key: "避開高速和收費", highway: .avoid, toll: .avoid),
    ProbeConfig(key: "只避開高速", highway: .avoid, toll: .any),
    ProbeConfig(key: "只避開收費", highway: .any, toll: .avoid),
]

final class Once {
    private var done = false
    private let lock = NSLock()

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

struct RequestTimedOut: Error {}

/// 查一次路線。`calculate` 沒有回應時也不要卡住整個實測，60 秒後就當作失敗。
func calculate(_ request: MKDirections.Request) async -> Result<MKDirections.Response, Error> {
    await withCheckedContinuation { continuation in
        let once = Once()
        let directions = MKDirections(request: request)
        directions.calculate { response, error in
            guard once.claim() else { return }
            if let response {
                continuation.resume(returning: .success(response))
            } else {
                continuation.resume(returning: .failure(error ?? RequestTimedOut()))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard once.claim() else { return }
            directions.cancel()
            continuation.resume(returning: .failure(RequestTimedOut()))
        }
    }
}

/// 路線座標。相鄰點至少隔 50 m，結果檔才不會太大。
func coordinates(of polyline: MKPolyline) -> [[Double]] {
    var raw = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
    polyline.getCoordinates(&raw, range: NSRange(location: 0, length: polyline.pointCount))
    var result: [[Double]] = []
    var last: CLLocation?
    for (i, c) in raw.enumerated() {
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        if i == raw.count - 1 || last == nil || here.distance(from: last!) >= 50 {
            result.append([c.latitude, c.longitude])
            last = here
        }
    }
    return result
}

func summary(of route: MKRoute) -> [String: Any] {
    [
        "name": route.name,
        "distance": route.distance,
        "time": route.expectedTravelTime,
        "hasHighways": route.hasHighways,
        "hasTolls": route.hasTolls,
        "advisories": route.advisoryNotices,
        "steps": route.steps.map { step -> [String: Any] in
            ["text": step.instructions, "notice": step.notice ?? "", "distance": step.distance]
        },
        "points": coordinates(of: route.polyline),
    ]
}

func log(route: MKRoute, index: Int) {
    let km = route.distance / 1_000
    let minutes = route.expectedTravelTime / 60
    let speed = minutes > 0 ? km / (minutes / 60) : 0
    print(String(format: "  路線%d：%@・%.1f km・%.0f 分・均速 %.0f・高速=%@・收費=%@",
                 index, route.name, km, minutes, speed,
                 route.hasHighways ? "有" : "無", route.hasTolls ? "有" : "無"))
}

func write(_ record: [String: Any], to output: FileHandle) {
    if let data = try? JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes]) {
        output.write(data)
        output.write(Data([0x0A]))
    }
}

func mapItem(_ place: Place) -> MKMapItem {
    MKMapItem(location: CLLocation(latitude: place.lat, longitude: place.lon), address: nil)
}

/// 用 App 的程式選路線，再把選到的路線和線形比對的結果記下來。
func runPlans(cases: [ProbeCase], rules: RouteRules, output: FileHandle) async -> Int32 {
    var succeeded = 0
    var failed = 0
    var warned = 0
    for testCase in cases {
        print("")
        print("=== [\(testCase.group)] \(testCase.from.name) → \(testCase.to.name)（預期：\(testCase.expected)）")
        for mode in VehicleMode.allCases {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            var record: [String: Any] = [
                "group": testCase.group,
                "expected": testCase.expected,
                "from": testCase.from.name,
                "to": testCase.to.name,
                "mode": mode.rawValue,
            ]
            do {
                let plan = try await RoutePlanner.plan(from: mapItem(testCase.from), to: mapItem(testCase.to),
                                                       mode: mode, rules: rules)
                let points = MapItems.coordinates(of: plan.route.polyline)
                let freeway = rules.freeways.overlap(with: points)
                let restricted = rules.whitePlateRestricted.overlap(with: points)
                succeeded += 1
                if plan.warning != nil { warned += 1 }
                record["route"] = summary(of: plan.route)
                record["requestIndex"] = plan.requestIndex
                record["routeIndex"] = plan.routeIndex
                record["warning"] = plan.warning?.text ?? ""
                record["issues"] = plan.issues.map { String(describing: $0) }
                record["freewayRun"] = freeway.longestRun
                record["freewayCloseRun"] = freeway.longestCloseRun
                record["restrictedCloseRun"] = restricted.longestCloseRun
                print(String(format: "--- %@：第 %d 次請求第 %d 條，國道貼著 %.0f m（附近 %.0f m），白牌路 %.0f m%@",
                             mode.displayName, plan.requestIndex + 1, plan.routeIndex + 1,
                             freeway.longestCloseRun, freeway.longestRun, restricted.longestCloseRun,
                             plan.warning.map { "，提醒：\($0.text)" } ?? ""))
                log(route: plan.route, index: plan.routeIndex)
            } catch {
                failed += 1
                record["error"] = String(describing: error)
                print("--- \(mode.displayName)：失敗 \(error)")
                if let mk = error as? MKError, mk.code == .loadingThrottled {
                    print("  被限流，等 60 秒")
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                }
            }
            write(record, to: output)
        }
    }
    print("")
    print("完成：成功 \(succeeded) 次，失敗 \(failed) 次，有提醒 \(warned) 次")
    return succeeded > 0 ? 0 : 1
}

// MARK: - 模擬開車（replay）

struct ReplayLeg: Decodable {
    let name: String
    let from: Place
    let to: Place
    /// 模擬車速；沒寫就用 Apple 估的平均時速
    let speedKmh: Double?
    /// 隧道裡實際的車速是幾倍（App 只知道進隧道前的車速）。沒寫就是 1，例如 0.7 是隧道裡慢下來。
    let tunnelSpeedFactor: Double?
    let vehicleMode: VehicleMode?
    /// 在同一組提醒核心內沿去程折線折返；只是測試軌跡，不代表可合法迴轉的位置。
    let turnaroundAtMeters: Double?
    let waitAtTurnaroundSeconds: Int?
    /// 同向停等後繼續，獨立驗證歸零政策，避免被折返中止掩蓋。
    let pauseAtMeters: Double?
    let pauseSeconds: Int?
    let hintChecks: [ReplayHintCheck]?
}

struct ReplayHintCheck: Decodable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
    let hintID: String
    var point: GeoPoint { GeoPoint(lat: lat, lon: lon) }
}

struct ReplayNavFrame {
    let along: Double
    let second: Double
    let progress: RouteProgress
}

struct ReplaySpeech {
    let along: Double
    let second: Double
    let text: String
    let source: String
    let hintID: String?

    var record: [String: Any] {
        ["along": along, "t": second, "text": text, "source": source, "hintID": hintID ?? ""]
    }
}

func reportHintChecks(_ checks: [ReplayHintCheck], leg: String, second: Double,
                      polyline: [GeoPoint], cumulative: [Double], stepRows: [[String: Any]],
                      hints: [RouteHint], matches: [RouteHintMatch],
                      frames: [ReplayNavFrame], speeches: [ReplaySpeech]) {
    for check in checks {
        var nearest = (along: 0.0, distance: Double.greatestFiniteMagnitude)
        for i in 0..<(polyline.count - 1) {
            let projection = GeoMath.project(check.point, ontoSegment: polyline[i], polyline[i + 1])
            if projection.distance < nearest.distance {
                nearest = (cumulative[i] + projection.t * (cumulative[i + 1] - cumulative[i]), projection.distance)
            }
        }
        let definition = hints.first { $0.id == check.hintID }
        let matched = matches.first { $0.hint.id == check.hintID && abs($0.along - nearest.along) <= 100 }
        let atPoint = frames.min { abs($0.along - nearest.along) < abs($1.along - nearest.along) }
        let displayed = frames.filter {
            abs($0.along - nearest.along) <= 300 && !$0.progress.isOffRoute && $0.progress.hintID == check.hintID
        }.min { abs($0.along - nearest.along) < abs($1.along - nearest.along) }
        let nearbySpeech = speeches.filter { abs($0.along - nearest.along) <= 300 }
        let triggered = nearbySpeech.contains { $0.source == "navigation" && $0.hintID == check.hintID }
        let coverage: String
        if nearest.distance > 30 { coverage = "not_on_route" }
        else if matched == nil { coverage = "different_branch" }
        else if displayed == nil || !triggered { coverage = "missing_prompt" }
        else { coverage = "covered" }
        let currentStep = stepRows.firstIndex { ($0["end"] as? Double ?? 0) >= nearest.along } ?? stepRows.count - 1
        let context = stepRows.enumerated().filter { index, row in
            abs(index - currentStep) <= 1
                || (row["start"] as? Double ?? 0) <= nearest.along + 300 && (row["end"] as? Double ?? 0) >= nearest.along - 300
        }.map { $0.element }
        let shortText = definition?.shortText ?? ""
        let liveHint = displayed.map { $0.progress.distanceToNextManeuver <= 300 ? $0.progress.maneuverText : "" } ?? ""
        replayRecord("hint_check", leg: leg, second: second, point: check.point, fields: [
            "id": check.id, "name": check.name, "hintID": check.hintID, "routeDistance": nearest.distance,
            "along": nearest.along, "coverage": coverage, "matched": matched != nil,
            "triggered": triggered, "shortText": shortText, "instruction": definition?.instruction ?? "",
            "displayAtPoint": atPoint?.progress.maneuverText ?? "", "displayedHint": displayed?.progress.maneuverText ?? "",
            "liveActivityHint": liveHint, "speeches": nearbySpeech.map(\.record), "appleSteps": context,
        ])
        print(String(format: "  提示點 %@ %@：%@，路線最近 %.1f m；當時下一步：%@；補充短句：%@；觸發=%@",
                     check.id, check.name, coverage == "covered" ? "涵蓋" : "未涵蓋（\(coverage)）",
                     nearest.distance, atPoint?.progress.maneuverText ?? "無", shortText, triggered ? "是" : "否"))
        for row in context {
            print("    Apple 步驟\(row["index"] ?? "") [\(row["start"] ?? "")–\(row["end"] ?? "")m]：\(row["text"] ?? "")")
        }
        for speech in nearbySpeech { print("    前後300m語音候選 [\(speech.source)]：\(speech.text)") }
    }
}

/// 隧道裡沒有定位。模擬時在這些範圍內不給定位，只呼叫 tick（App 每秒做的事）。
/// 座標是 OSM 的隧道線形（簡化過），每條只記一個方向，另一個方向的管道也在 130 m 內。
let tunnels: [[GeoPoint]] = ([
    [(25.08698, 121.54930), (25.09442, 121.54870)],     // 自強隧道
    [(25.01000, 121.55730), (25.01320, 121.55400)],     // 辛亥隧道
    [(24.84789, 121.79150), (24.85208, 121.79156), (24.85688, 121.79030), (24.85948, 121.78898), (24.86407, 121.78549),
     (24.87769, 121.77117), (24.88040, 121.76875), (24.89516, 121.75829), (24.89992, 121.75406), (24.90337, 121.75010),
     (24.91571, 121.73412), (24.92064, 121.72900), (24.92527, 121.72543), (24.93279, 121.72050), (24.93862, 121.71474)],   // 雪山隧道
    [(25.00919, 121.58163), (25.01241, 121.58156), (25.01516, 121.58103), (25.01805, 121.57993), (25.02119, 121.57801)],   // 文山隧道
    [(24.99617, 121.55171), (24.99176, 121.55137)],     // 懷恩隧道
    [(24.53358, 121.83528), (24.53715, 121.83650), (24.56028, 121.84246), (24.56298, 121.84356)],   // 東澳隧道
    [(24.36815, 121.78003), (24.37574, 121.78290), (24.38293, 121.78446), (24.41217, 121.78705), (24.41560, 121.78657),
     (24.42020, 121.78483), (24.42414, 121.78207), (24.42869, 121.77759), (24.43023, 121.77651), (24.43285, 121.77531),
     (24.43614, 121.77463)],    // 觀音隧道
    [(25.19253, 121.68452), (25.19378, 121.68500), (25.19470, 121.68459), (25.20044, 121.67848)],   // 萬里隧道
    [(22.56013, 120.30978), (22.56586, 120.31780)],     // 過港隧道
] as [[(Double, Double)]]).map { $0.map { GeoPoint(lat: $0.0, lon: $0.1) } }

func isInTunnel(_ p: GeoPoint) -> Bool {
    tunnels.contains { path in
        zip(path, path.dropFirst()).enumerated().contains { i, segment in
            let projection = GeoMath.project(p, ontoSegment: segment.0, segment.1)
            guard projection.distance <= 130 else { return false }
            // 隧道的頭尾不能超出去，中間的折點可以
            return (i > 0 || projection.t > 0) && (i < path.count - 2 || projection.t < 1)
        }
    }
}

/// 沒有定位時的提醒：另外印出車子實際離照相點多遠，看推算準不準。
func withActualDistance(_ event: CameraAlertEvent, at point: GeoPoint) -> String {
    switch event {
    case let .preAlert(c, _), let .nearAlert(c, _, _):
        return "（實際直線 \(Int(GeoMath.distance(point, c.point))) m）"
    default:
        return ""
    }
}

func describe(_ event: CameraAlertEvent) -> String? {
    switch event {
    case let .preAlert(c, d):
        let limit = c.enforcesSpeed ? (c.speedLimit.map { " 速限\($0)" } ?? " 速限未提供") : ""
        return "【照相預告】id=\(c.id) \(Int(d)) m \(c.alertDescription)\(limit) \(c.address)"
    case let .nearAlert(c, d, afterPre): return "【照相近距】id=\(c.id) \(Int(d)) m afterPre=\(afterPre) \(afterPre ? "已預告短句" : "完整句子") \(c.address)"
    case let .passed(c): return "【通過照相】id=\(c.id) \(c.address)"
    case let .overspeedStarted(limit, speed):
        return "【照相超速開始】車速\(Int(speed)) 門檻\(limit)（語音見同批候選）"
    case .overspeedBeep: return "【照相超速嗶聲】"
    case .overspeedEnded: return "【照相超速結束】"
    }
}

func describe(_ event: SectionEvent) -> String? {
    switch event {
    case let .approaching(s, d): return "【區間預告】id=\(s.id) \(Int(d)) m 前 \(s.name)"
    case let .entered(s, sec): return "【進入區間】id=\(s.id) \(s.name) 長 \(Int(s.lengthMeters)) m，至少 \(sec) 秒"
    case let .remaining(sec): return "【區間倒數】還有 \(sec) 秒"
    case .zeroReached: return "【區間歸零】"
    case let .completed(s, avg, _): return "【通過區間終點】id=\(s.id) \(s.name) 均速 \(Int(avg))"
    case let .aborted(s): return "【中途離開區間】id=\(s.id) \(s.name)"
    case let .overspeedStarted(threshold):
        return "【區間超速開始】門檻\(threshold)（是否播報見結構化紀錄）"
    case .overspeedBeep: return "【區間超速嗶聲】"
    case .overspeedEnded: return "【區間超速結束】"
    }
}

func replayRecord(_ event: String, leg: String, second: Double, point: GeoPoint,
                  fields: [String: Any] = [:]) {
    var record = fields
    record["schema"] = 1
    record["event"] = event
    record["case"] = leg
    record["t"] = second
    record["lat"] = point.lat
    record["lon"] = point.lon
    do {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        print("REPLAY1108 " + String(decoding: data, as: UTF8.self))
    } catch {
        print("[錯誤] replay 結構化紀錄無法序列化：\(error)")
        exit(65)
    }
}

func logReplay(camera: CameraAlertResult?, section: SectionResult?, stamp: String,
               point: GeoPoint, showStatus: Bool, estimated: Bool,
               leg: String, second: Double, speedKmh: Double, settings: AlertSettings,
               cameraTarget: inout CameraTarget?, sectionStatus: inout SectionStatus?) -> [String] {
    let previousSection = sectionStatus
    if let camera { cameraTarget = camera.target }
    if let section { sectionStatus = section.status }
    let speeches = camera.map { CameraAnnouncementPolicy.speech(for: $0, speedKmh: speedKmh, settings: settings) } ?? []
    var speechCandidates = speeches.map(\.text)
    for event in camera?.events ?? [] {
        if let text = describe(event) {
            print(stamp + text + (estimated ? withActualDistance(event, at: point) : ""))
        }
        var fields: [String: Any] = ["id": cameraTarget?.camera.id ?? "", "estimated": estimated]
        let key: String
        switch event {
        case let .preAlert(c, distance), let .nearAlert(c, distance, _):
            key = event.isReplayNear ? "camera_near" : "camera_pre"
            let th = settings.thresholds(speedLimit: c.speedLimit, currentSpeedKmh: speedKmh)
            let threshold = event.isReplayNear ? th.near : th.pre
            fields["id"] = c.id
            fields["address"] = c.address
            fields["cameraType"] = c.type.rawValue
            fields["enforcesSpeed"] = c.enforcesSpeed
            fields["source"] = c.source ?? "legacy"
            fields["distance"] = distance
            fields["announcedDistance"] = AnnouncementFormatter.announcedDistance(distance, threshold: threshold)
            fields["threshold"] = threshold
            fields["overspeed"] = cameraTarget?.camera.id == c.id && cameraTarget?.isOverspeed == true
            fields["speeches"] = speeches.map(\.text)
            if case let .nearAlert(_, _, afterPre) = event { fields["afterPre"] = afterPre }
        case let .passed(c):
            key = "camera_passed"
            fields["id"] = c.id
            fields["address"] = c.address
            fields["cameraType"] = c.type.rawValue
            fields["enforcesSpeed"] = c.enforcesSpeed
            fields["source"] = c.source ?? "legacy"
        case .overspeedStarted: key = "camera_overspeed_started"
        case .overspeedBeep: key = "camera_beep"
        case .overspeedEnded: key = "camera_overspeed_ended"
        }
        replayRecord(key, leg: leg, second: second, point: point, fields: fields)
    }
    for speech in speeches {
        print(stamp + "照相語音候選：" + speech.text)
    }
    if let camera, !camera.events.isEmpty, let target = camera.target {
        let c = target.camera
        print(stamp + "相機目標 id=\(c.id) 座標=\(c.lat),\(c.lon) heading=\(String(describing: c.heading)) axis=\(String(describing: c.axis)) 超速=\(target.isOverspeed)")
    }
    for event in section?.events ?? [] {
        if let text = describe(event) { print(stamp + text) }
        var fields: [String: Any] = [
            "id": sectionStatus?.section.id ?? previousSection?.section.id ?? "",
            "remaining": sectionStatus?.remainingSeconds ?? previousSection?.remainingSeconds ?? 0,
            "sectionOverspeed": sectionStatus?.isOverspeed == true,
            "cameraOverspeed": cameraTarget?.isOverspeed == true,
        ]
        let key: String
        let speech: String?
        switch event {
        case let .approaching(s, distance):
            key = "section_approach"
            fields["id"] = s.id
            fields["distance"] = distance
            speech = AnnouncementFormatter.sectionApproaching(section: s, announcedDistance:
                AnnouncementFormatter.announcedDistance(distance, threshold: settings.thresholds(
                    speedLimit: s.speedLimit, currentSpeedKmh: 0).pre))
        case let .entered(s, seconds):
            key = "section_entered"
            fields["id"] = s.id
            fields["length"] = s.lengthMeters
            fields["gateLat"] = s.start.lat
            fields["gateLon"] = s.start.lon
            speech = AnnouncementFormatter.sectionEntered(section: s, minimumSeconds: seconds,
                effectiveLimitKmh: settings.sectionEffectiveLimit(s.speedLimit, sectionID: s.groupID))
        case let .completed(s, average, within):
            key = "section_completed"
            fields["id"] = s.id
            fields["gateLat"] = s.end.lat
            fields["gateLon"] = s.end.lon
            speech = AnnouncementFormatter.sectionCompleted(averageKmh: average, withinLimit: within)
        case let .aborted(s):
            key = "section_aborted"
            fields["id"] = s.id
            speech = nil
        case let .remaining(seconds):
            key = "section_remaining"
            speech = AnnouncementFormatter.sectionRemaining(seconds: seconds, suggestedKmh: sectionStatus?.suggestedWholeKmh)
        case .zeroReached:
            key = "section_zero"
            speech = AnnouncementFormatter.sectionZero
        case let .overspeedStarted(threshold):
            key = "section_overspeed_started"
            fields["threshold"] = threshold
            speech = cameraTarget?.isOverspeed == true ? nil : AnnouncementFormatter.sectionOverspeed(threshold: threshold)
        case .overspeedBeep:
            key = "section_beep"
            fields["audibleBeep"] = cameraTarget?.isOverspeed != true
            speech = nil
        case .overspeedEnded:
            key = "section_overspeed_ended"
            speech = nil
        }
        fields["speech"] = speech ?? ""
        if let speech { speechCandidates.append(speech) }
        replayRecord(key, leg: leg, second: second, point: point, fields: fields)
    }
    if let section, let status = section.status, showStatus || !section.events.isEmpty {
        print(stamp + String(format: "區間狀態 id=%@ 經過=%.0f s 剩餘=%.1f s 累計=%.0f m 剩距=%.0f m 均速=%.1f 門檻=%.0f 相機超速=%@",
                             status.section.id, status.elapsed, status.remainingSeconds,
                             status.traveledMeters, status.remainingMeters, status.averageKmh,
                             status.effectiveLimitKmh, camera?.target?.isOverspeed == true ? "是" : "否"))
        replayRecord("section_status", leg: leg, second: second, point: point, fields: [
            "id": status.section.id, "remaining": status.remainingSeconds,
            "sectionOverspeed": status.isOverspeed, "cameraOverspeed": cameraTarget?.isOverspeed == true,
            "presentationOverspeed": status.isOverspeed || cameraTarget?.isOverspeed == true,
        ])
    }
    return speechCandidates
}

extension CameraAlertEvent {
    var isReplayNear: Bool {
        if case .nearAlert = self { return true }
        return false
    }
}

/// 沿著 Apple 規劃的路線模擬開一次，把 App 的核心程式會發出的提醒，連同當時的位置印出來。
/// 同時檢查每個轉彎：開到動作點之前，畫面顯示的是不是這個動作。
func runReplay(legs: [ReplayLeg], databasePath: String, rules: RouteRules?,
               resolver: RoadInstructionResolver, hints: [RouteHint], output: FileHandle) async -> Int32 {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: databasePath)),
          let db = try? CameraDatabase.decode(from: data) else {
        print("讀不了 \(databasePath)")
        return 66
    }
    print("資料：版本 \(db.version)，產生時間 \(db.generatedAt)，照相點 \(db.cameras.count) 處，區間 \(db.sections.count) 段")
    print("每段重新建立核心；折返案例的去回程共用核心。事件不等於實際播放：App 會抑制重複嗶聲，緊急語音會打斷前句。")
    replayRecord("run_start", leg: "", second: 0, point: GeoPoint(lat: 0, lon: 0),
                 fields: ["dataVersion": db.version, "dataGeneratedAt": db.generatedAt,
                          "cameras": db.cameras.count, "sections": db.sections.count, "routeHints": hints.count])
    var totalManeuvers = 0
    var correctManeuvers = 0
    var succeeded = 0
    var failed = 0
    var resolvedPlaces: [String: Place] = [:]
    func resolve(_ place: Place) async throws -> Place {
        guard let query = place.query else { return place }
        if let cached = resolvedPlaces[query] { return cached }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon),
                                           latitudinalMeters: 5_000, longitudinalMeters: 5_000)
        request.resultTypes = [.pointOfInterest, .address]
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            throw NSError(domain: "RouteProbeSearch", code: 1, userInfo: [NSLocalizedDescriptionKey: "查不到 \(query)"])
        }
        let coordinate = MapItems.coordinate(of: item)
        guard GeoMath.distance(GeoPoint(lat: place.lat, lon: place.lon),
                               GeoPoint(lat: coordinate.latitude, lon: coordinate.longitude)) <= 5_000 else {
            throw NSError(domain: "RouteProbeSearch", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(query) 搜尋結果不在指定地區"])
        }
        let resolved = Place(name: "\(item.name ?? place.name)（\(MapItems.subtitle(of: item))）",
                             lat: coordinate.latitude, lon: coordinate.longitude, query: query)
        resolvedPlaces[query] = resolved
        return resolved
    }

    for leg in legs {
        print("")
        print("=== \(leg.name)")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let from: Place
        let to: Place
        do {
            from = try await resolve(leg.from)
            to = try await resolve(leg.to)
            if leg.from.query != nil || leg.to.query != nil {
                print("  實際搜尋起點：\(from.name) \(from.lat),\(from.lon)")
                print("  實際搜尋終點：\(to.name) \(to.lat),\(to.lon)")
            }
        } catch {
            failed += 1
            print("目的地搜尋失敗：\(error)")
            write(["leg": leg.name, "error": String(describing: error)], to: output)
            continue
        }
        let route: MKRoute
        if let mode = leg.vehicleMode {
            guard let rules else {
                print("指定車種卻沒有道路規則")
                return 66
            }
            do {
                let plan = try await RoutePlanner.plan(from: mapItem(from), to: mapItem(to),
                                                       mode: mode, rules: rules)
                route = plan.route
                print("  車種=\(mode.rawValue)，請求\(plan.requestIndex + 1)，路線\(plan.routeIndex + 1)，提醒=\(plan.warning?.text ?? "無")")
            } catch {
                failed += 1
                print("規劃失敗：\(error)")
                write(["leg": leg.name, "error": String(describing: error)], to: output)
                continue
            }
        } else {
            let request = MKDirections.Request()
            request.source = mapItem(from)
            request.destination = mapItem(to)
            request.transportType = .automobile
            guard case .success(let response) = await calculate(request), let first = response.routes.first else {
                failed += 1
                print("規劃失敗")
                write(["leg": leg.name, "error": "規劃失敗"], to: output)
                continue
            }
            route = first
            print("  未指定車種：沿用舊案例的汽車路線請求")
        }
        log(route: route, index: 0)

        let polyline = MapItems.coordinates(of: route.polyline)
        var cumulative: [Double] = [0]
        for (a, b) in zip(polyline, polyline.dropFirst()) {
            cumulative.append(cumulative.last! + GeoMath.distance(a, b))
        }
        let total = cumulative.last ?? 0
        let speedKmh = leg.speedKmh ?? min(90, max(25, route.distance / max(1, route.expectedTravelTime) * 3.6))
        let speed = speedKmh / 3.6
        let tunnelFactor = leg.tunnelSpeedFactor ?? 1
        let turn = leg.turnaroundAtMeters ?? total
        let waitSeconds = leg.waitAtTurnaroundSeconds ?? 0
        let pauseAt = leg.pauseAtMeters ?? total
        let pauseSeconds = leg.pauseSeconds ?? 0
        guard polyline.count >= 2, total.isFinite, total > 0,
              speed.isFinite, speed > 0, tunnelFactor.isFinite, tunnelFactor > 0,
              turn.isFinite, turn > 0, turn <= total, waitSeconds >= 0,
              leg.turnaroundAtMeters != nil || waitSeconds == 0,
              pauseAt.isFinite, pauseAt > 0, pauseAt <= total, pauseSeconds >= 0,
              leg.pauseAtMeters != nil || pauseSeconds == 0,
              leg.turnaroundAtMeters == nil || leg.pauseAtMeters == nil else {
            print("案例參數或路線折線無效：\(leg.name)")
            return 65
        }
        let roundTrip = leg.turnaroundAtMeters != nil
        let tripDistance = roundTrip ? 2 * turn : total

        // 步驟：Apple 的距離、折線實際長度、終點座標
        var maneuvers: [(position: Double, text: String)] = []
        let original = MapItems.stepInfos(of: route, resolver: resolver)
        let hintMatches = RouteHintMatcher.matches(hints, polyline: polyline)
        let stepInfos = RouteHintMatcher.steps(original, matches: hintMatches, totalDistance: total)
        var acc = 0.0
        var stepRows: [[String: Any]] = []
        let stepScale = total / max(1, original.reduce(0) { $0 + $1.distance })
        for (i, step) in route.steps.enumerated() {
            let points = MapItems.coordinates(of: step.polyline)
            var length = 0.0
            for (a, b) in zip(points, points.dropFirst()) { length += GeoMath.distance(a, b) }
            let startAlong = acc * stepScale
            acc += length
            let instruction = original[i].instruction
            stepRows.append(["index": i, "start": startAlong, "end": acc * stepScale,
                             "text": step.instructions, "corrected": instruction,
                             "shortText": ManeuverText.short(instruction)])
            let end = points.last ?? GeoPoint(lat: 0, lon: 0)
            print(String(format: "  步驟%2d Apple %6.0f m／折線 %6.0f m，累計 %7.0f m，終點 %.5f,%.5f  ", i, step.distance, length, acc, end.lat, end.lon)
                  + step.instructions + "；校正：" + instruction + "；短句：" + ManeuverText.short(instruction)
                  + "；notice：" + (step.notice ?? "無"))
        }
        print(String(format: "  路線折線總長 %.0f m，步驟折線加總 %.0f m，Apple 距離 %.0f m", total, acc, route.distance))
        var maneuverPosition = 0.0
        for step in stepInfos {
            maneuverPosition += step.distance
            if !step.instruction.isEmpty { maneuvers.append((maneuverPosition, step.instruction)) }
        }

        let nav = RouteProgressTracker(polyline: polyline, steps: stepInfos)
        var settings = AlertSettings()
        if let mode = leg.vehicleMode { settings.vehicleMode = mode }
        let engine = CameraAlertEngine(index: SpatialIndex(cameras: db.cameras), settings: settings)
        engine.sections = db.sections
        let sections = SectionSpeedTracker(sections: db.sections, settings: settings)
        replayRecord("case_start", leg: leg.name, second: 0, point: polyline[0], fields: [
            "sectionBeepInterval": settings.sectionOverspeedBeepInterval,
            "sectionVoiceInterval": settings.sectionOverspeedVoiceInterval,
            "fromName": from.name, "fromQuery": from.query ?? "", "fromLat": from.lat, "fromLon": from.lon,
            "toName": to.name, "toQuery": to.query ?? "", "toLat": to.lat, "toLon": to.lon,
            "hintCheckIDs": (leg.hintChecks ?? []).map(\.id),
            "turnaroundAtMeters": leg.turnaroundAtMeters ?? 0, "waitAtTurnaroundSeconds": waitSeconds,
            "pauseAtMeters": leg.pauseAtMeters ?? 0, "pauseSeconds": pauseSeconds,
        ])
        let chunkSize = 400
        replayRecord("route_geometry", leg: leg.name, second: 0, point: polyline[0], fields: [
            "pointCount": polyline.count, "chunkCount": (polyline.count + chunkSize - 1) / chunkSize,
            "appleSteps": stepRows,
        ])
        // 完整折線分段印出，避免長路線把單行 log 撐得過大。
        for (index, offset) in stride(from: 0, to: polyline.count, by: chunkSize).enumerated() {
            replayRecord("route_geometry_part", leg: leg.name, second: 0, point: polyline[offset], fields: [
                "index": index, "points": polyline[offset..<min(offset + chunkSize, polyline.count)].map { [$0.lat, $0.lon] },
            ])
        }

        print(String(format: "  模擬車速 %.0f km/h", speedKmh))
        if roundTrip {
            print(String(format: "  去程 %.0f m 後停等 %d 秒，再沿折線反向回到起點；返程只測提醒，不測重新規劃或車道合法性", turn, waitSeconds))
        }
        let start = Date()
        var traveled = 0.0
        var second = 0.0
        var segment = 0
        var displayed = ""
        var previousDisplayed = ""
        var nextManeuver = 0
        var inTunnel = false
        var waited = 0
        var didTurn = false
        var cameraTarget: CameraTarget?
        var sectionStatus: SectionStatus?
        var navFrames: [ReplayNavFrame] = []
        var speechLog: [ReplaySpeech] = []
        var recordedHintWindows = Set<String>()
        while traveled < tripDistance {
            let returning = roundTrip && traveled >= turn
            let waiting = (returning && waited < waitSeconds)
                || (!roundTrip && traveled >= pauseAt && waited < pauseSeconds)
            let nextStop = !roundTrip && traveled < pauseAt ? pauseAt : (returning ? tripDistance : turn)
            let position = returning ? max(0, 2 * turn - traveled) : traveled
            while segment > 0 && cumulative[segment] > position { segment -= 1 }
            while segment < polyline.count - 2 && cumulative[segment + 1] <= position { segment += 1 }
            let a = polyline[segment], b = polyline[segment + 1]
            let span = max(0.01, cumulative[segment + 1] - cumulative[segment])
            let ratio = min(1, max(0, (position - cumulative[segment]) / span))
            let point = GeoPoint(lat: a.lat + (b.lat - a.lat) * ratio, lon: a.lon + (b.lon - a.lon) * ratio)
            let now = start.addingTimeInterval(second)
            let course = GeoMath.normalize(GeoMath.bearing(from: a, to: b) + (returning ? 180 : 0))
            let actualSpeed = waiting ? 0 : speed
            let fix = VehicleFix(point: point, speedMps: actualSpeed, course: course,
                                 horizontalAccuracy: 5, timestamp: now)
            let stamp = String(format: "  t=%6.0f s 樁距=%7.0f m %.6f,%.6f 車速=%.1f 方位=%.1f ",
                               second, position, point.lat, point.lon, actualSpeed * 3.6, course)
            if leg.name.hasPrefix("北宜4回程 "), (330...410).contains(second) {
                replayRecord("fix", leg: leg.name, second: second, point: point,
                             fields: ["along": position, "course": course, "speedKmh": actualSpeed * 3.6])
            }
            if returning && !didTurn {
                didTurn = true
                print(stamp + "── 折返測試：核心未重設")
            }

            // 隧道裡沒有定位：只有時間在走
            let tunnelNow = isInTunnel(point)
            if tunnelNow != inTunnel {
                inTunnel = tunnelNow
                print(stamp + (tunnelNow ? "── 進隧道，定位中斷" : "── 出隧道，定位恢復"))
            }
            if tunnelNow {
                let spoken = logReplay(camera: engine.tick(now: now), section: sections.tick(now: now), stamp: stamp,
                          point: point, showStatus: Int(second) % 30 == 0, estimated: true,
                          leg: leg.name, second: second, speedKmh: actualSpeed * 3.6, settings: settings,
                          cameraTarget: &cameraTarget, sectionStatus: &sectionStatus)
                speechLog += spoken.map { ReplaySpeech(along: position, second: second, text: $0, source: "測速", hintID: nil) }
                traveled = min(nextStop, traveled + actualSpeed * tunnelFactor)
                if waiting { waited += 1 }
                second += 1
                continue
            }

            if !returning {
                let navResult = nav.process(fix)
                if let progress = navResult.progress {
                    navFrames.append(ReplayNavFrame(along: position, second: second, progress: progress))
                    if let hintID = progress.hintID, !progress.isOffRoute,
                       progress.distanceToNextManeuver <= 300, recordedHintWindows.insert(hintID).inserted {
                        replayRecord("nav_hint", leg: leg.name, second: second, point: point,
                                     fields: ["hintID": hintID, "text": progress.maneuverText, "along": position,
                                              "distance": progress.distanceToNextManeuver])
                    }
                }
                previousDisplayed = displayed
                if let progress = navResult.progress, progress.nextInstruction != displayed {
                    displayed = progress.nextInstruction
                    print(stamp + String(format: "畫面下一步（%.0f m 後）：", progress.distanceToNextManeuver)
                          + progress.maneuverText + "；原文：" + displayed)
                    replayRecord("nav_display", leg: leg.name, second: second, point: point,
                                 fields: ["text": progress.maneuverText, "instruction": displayed,
                                          "hintID": progress.hintID ?? "", "along": position,
                                          "stepIndex": progress.nextStepIndex,
                                          "maneuverAlong": position + progress.distanceToNextManeuver])
                }
                for event in navResult.events {
                    if case let .announce(index, text, distance) = event {
                        let spoken = AnnouncementFormatter.maneuver(instruction: text, distance: distance)
                        let hintID = stepInfos[index].hintID
                        speechLog.append(ReplaySpeech(along: position, second: second, text: spoken,
                                                      source: "navigation", hintID: hintID))
                        print(stamp + "語音：" + spoken)
                        replayRecord("nav_speech", leg: leg.name, second: second, point: point,
                                     fields: ["text": spoken, "hintID": hintID ?? "", "along": position,
                                              "announcement": distance ?? -1, "stepIndex": index])
                    }
                }
            }
            let spoken = logReplay(camera: engine.process(fix), section: sections.process(fix), stamp: stamp,
                      point: point, showStatus: Int(second) % 30 == 0, estimated: false,
                      leg: leg.name, second: second, speedKmh: actualSpeed * 3.6, settings: settings,
                      cameraTarget: &cameraTarget, sectionStatus: &sectionStatus)
            speechLog += spoken.map { ReplaySpeech(along: position, second: second, text: $0, source: "測速", hintID: nil) }

            // 開到動作點之前，畫面應該正在顯示這個動作（這一秒剛好經過動作點時，看換之前顯示的）
            while !returning && nextManeuver < maneuvers.count && maneuvers[nextManeuver].position <= min(turn, position + actualSpeed) {
                let expected = maneuvers[nextManeuver].text
                totalManeuvers += 1
                if displayed == expected || previousDisplayed == expected {
                    correctManeuvers += 1
                } else {
                    print(stamp + "★ 動作點應顯示「\(expected)」，實際顯示「\(displayed)」")
                }
                nextManeuver += 1
            }
            traveled = min(nextStop, traveled + actualSpeed)
            if waiting { waited += 1 }
            second += 1
        }
        succeeded += 1
        reportHintChecks(leg.hintChecks ?? [], leg: leg.name, second: second, polyline: polyline,
                         cumulative: cumulative, stepRows: stepRows, hints: hints,
                         matches: hintMatches, frames: navFrames, speeches: speechLog)
        print("  案例結束：模擬 \(Int(second)) 秒，區間仍在追蹤=\(sections.isActive)")
        replayRecord("case_end", leg: leg.name, second: second, point: roundTrip ? polyline[0] : polyline.last!,
                     fields: ["sectionStillActive": sections.isActive])
        var routeRecord = summary(of: route)
        routeRecord["points"] = polyline.map { [$0.lat, $0.lon] }
        write(["leg": leg.name, "route": routeRecord, "vehicleMode": leg.vehicleMode?.rawValue ?? "舊版汽車請求",
               "dataVersion": db.version, "dataGeneratedAt": db.generatedAt,
               "turnaroundAtMeters": leg.turnaroundAtMeters ?? 0, "waitAtTurnaroundSeconds": waitSeconds,
               "pauseAtMeters": leg.pauseAtMeters ?? 0, "pauseSeconds": pauseSeconds,
               "sectionStillActive": sections.isActive], to: output)
    }
    print("")
    print("轉彎指示和實際動作點相符：\(correctManeuvers)／\(totalManeuvers)")
    print("案例完成：成功 \(succeeded)，失敗 \(failed)")
    replayRecord("run_end", leg: "", second: 0, point: GeoPoint(lat: 0, lon: 0),
                 fields: ["succeeded": succeeded, "failed": failed,
                          "correctManeuvers": correctManeuvers, "totalManeuvers": totalManeuvers])
    return succeeded > 0 && failed == 0 ? 0 : 1
}

func run() async -> Int32 {
    guard CommandLine.arguments.count >= 4 else {
        print("用法：RouteProbe <compare|plan|replay> <路線清單.json> <結果檔.jsonl> [road_lines.json] [cameras.json] [route_hints.json]")
        return 64
    }
    if CommandLine.arguments[1] == "replay" {
        guard CommandLine.arguments.count >= 7,
              let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])),
              let legs = try? JSONDecoder().decode([ReplayLeg].self, from: data) else {
            print("讀不了路線清單或沒有指定 cameras.json")
            return 66
        }
        FileManager.default.createFile(atPath: CommandLine.arguments[3], contents: nil)
        guard let output = FileHandle(forWritingAtPath: CommandLine.arguments[3]) else { return 73 }
        guard let roadData = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4])),
              let lines = try? RoadLineData.decode(from: roadData) else {
            print("讀不了 road_lines.json，不能依指定車種選路或校正道路名稱")
            return 66
        }
        let hints: [RouteHint]
        do {
            hints = try RouteHint.decode(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[6])))
        } catch {
            print("讀不了 route_hints.json：\(error)")
            return 66
        }
        return await runReplay(legs: legs, databasePath: CommandLine.arguments[5], rules: RouteRules(data: lines),
            resolver: RoadInstructionResolver(freeways: lines.freeways, namedRoads: lines.namedRoads), hints: hints, output: output)
    }
    let cases: [ProbeCase]
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        cases = try JSONDecoder().decode([ProbeCase].self, from: data)
    } catch {
        print("讀不了路線清單：\(error)")
        return 66
    }
    let outputPath = CommandLine.arguments[3]
    FileManager.default.createFile(atPath: outputPath, contents: nil)
    guard let output = FileHandle(forWritingAtPath: outputPath) else {
        print("寫不了結果檔：\(outputPath)")
        return 73
    }

    print("語言：\(Locale.preferredLanguages)，地區：\(Locale.current.identifier)，共 \(cases.count) 條路線")

    if CommandLine.arguments[1] == "plan" {
        guard CommandLine.arguments.count >= 5,
              let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4])),
              let lines = try? RoadLineData.decode(from: data) else {
            print("讀不了 road_lines.json")
            return 66
        }
        return await runPlans(cases: cases, rules: RouteRules(data: lines), output: output)
    }

    var succeeded = 0
    var failed = 0

    for testCase in cases {
        print("")
        print("=== [\(testCase.group)] \(testCase.from.name) → \(testCase.to.name)（預期：\(testCase.expected)）")
        for config in configs where testCase.configs?.contains(config.key) ?? true {
            print("--- \(config.key)")
            let request = MKDirections.Request()
            request.source = mapItem(testCase.from)
            request.destination = mapItem(testCase.to)
            request.transportType = .automobile
            request.requestsAlternateRoutes = true
            request.highwayPreference = config.highway
            request.tollPreference = config.toll

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            var result = await calculate(request)
            if case .failure(let error) = result, let mk = error as? MKError, mk.code == .loadingThrottled {
                print("  被限流，等 60 秒再試一次")
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                result = await calculate(request)
            }

            var record: [String: Any] = [
                "group": testCase.group,
                "expected": testCase.expected,
                "from": testCase.from.name,
                "to": testCase.to.name,
                "config": config.key,
            ]
            switch result {
            case .success(let response):
                succeeded += 1
                record["routes"] = response.routes.map(summary)
                for (i, route) in response.routes.enumerated() {
                    log(route: route, index: i)
                }
            case .failure(let error):
                failed += 1
                record["error"] = String(describing: error)
                print("  失敗：\(error)")
            }

            write(record, to: output)
        }
    }

    print("")
    print("完成：成功 \(succeeded) 次，失敗 \(failed) 次")
    return succeeded > 0 ? 0 : 1
}

Task { @MainActor in
    exit(await run())
}
RunLoop.main.run()
