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
}

/// 隧道裡沒有定位。模擬時在這些範圍內不給定位，只呼叫 tick（App 每秒做的事）。
let tunnels: [(name: String, a: GeoPoint, b: GeoPoint)] = [
    ("自強隧道", GeoPoint(lat: 25.08698, lon: 121.54930), GeoPoint(lat: 25.09442, lon: 121.54870)),
    ("辛亥隧道", GeoPoint(lat: 25.01000, lon: 121.55730), GeoPoint(lat: 25.01320, lon: 121.55400)),
]

func isInTunnel(_ p: GeoPoint) -> Bool {
    tunnels.contains { t in
        let projection = GeoMath.project(p, ontoSegment: t.a, t.b)
        return projection.distance <= 80 && projection.t > 0 && projection.t < 1
    }
}

func describe(_ event: CameraAlertEvent) -> String? {
    switch event {
    case let .preAlert(c, d): return "【照相預告】\(Int(d)) m \(c.displayTypeName) 速限\(c.speedLimit ?? 0) \(c.address)"
    case let .nearAlert(c, d, afterPre): return "【照相近距】\(Int(d)) m \(afterPre ? "只念距離" : "完整句子") \(c.address)"
    case let .passed(c): return "【通過照相】\(c.address)"
    default: return nil
    }
}

func describe(_ event: SectionEvent) -> String? {
    switch event {
    case let .approaching(s, d): return "【區間預告】\(Int(d)) m 前 \(s.name)"
    case let .entered(s, sec): return "【進入區間】\(s.name) 長 \(Int(s.lengthMeters)) m，至少 \(sec) 秒"
    case let .remaining(sec): return "【區間倒數】還有 \(sec) 秒"
    case .zeroReached: return "【區間歸零】"
    case let .completed(s, avg, _): return "【通過區間終點】\(s.name) 均速 \(Int(avg))"
    case let .aborted(s): return "【中途離開區間】\(s.name)"
    default: return nil
    }
}

/// 沿著 Apple 規劃的路線模擬開一次，把 App 的核心程式會發出的提醒，連同當時的位置印出來。
/// 同時檢查每個轉彎：開到動作點之前，畫面顯示的是不是這個動作。
func runReplay(legs: [ReplayLeg], databasePath: String, output: FileHandle) async -> Int32 {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: databasePath)),
          let db = try? CameraDatabase.decode(from: data) else {
        print("讀不了 \(databasePath)")
        return 66
    }
    print("資料：照相點 \(db.cameras.count) 處，區間 \(db.sections.count) 段")
    var totalManeuvers = 0
    var correctManeuvers = 0

    for leg in legs {
        print("")
        print("=== \(leg.name)")
        let request = MKDirections.Request()
        request.source = mapItem(leg.from)
        request.destination = mapItem(leg.to)
        request.transportType = .automobile
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard case .success(let response) = await calculate(request), let route = response.routes.first else {
            print("規劃失敗")
            continue
        }
        log(route: route, index: 0)

        let polyline = MapItems.coordinates(of: route.polyline)
        var cumulative: [Double] = [0]
        for (a, b) in zip(polyline, polyline.dropFirst()) {
            cumulative.append(cumulative.last! + GeoMath.distance(a, b))
        }
        let total = cumulative.last ?? 0

        // 步驟：Apple 的距離、折線實際長度、終點座標
        var maneuvers: [(position: Double, text: String)] = []
        var acc = 0.0
        for (i, step) in route.steps.enumerated() {
            let points = MapItems.coordinates(of: step.polyline)
            var length = 0.0
            for (a, b) in zip(points, points.dropFirst()) { length += GeoMath.distance(a, b) }
            acc += length
            if !step.instructions.isEmpty { maneuvers.append((acc, step.instructions)) }
            let end = points.last ?? GeoPoint(lat: 0, lon: 0)
            print(String(format: "  步驟%2d Apple %6.0f m／折線 %6.0f m，累計 %7.0f m，終點 %.5f,%.5f  ", i, step.distance, length, acc, end.lat, end.lon)
                  + step.instructions)
        }
        print(String(format: "  路線折線總長 %.0f m，步驟折線加總 %.0f m，Apple 距離 %.0f m", total, acc, route.distance))

        let nav = RouteProgressTracker(polyline: polyline, steps: MapItems.stepInfos(of: route))
        let engine = CameraAlertEngine(index: SpatialIndex(cameras: db.cameras), settings: AlertSettings())
        engine.sections = db.sections
        let sections = SectionSpeedTracker(sections: db.sections, settings: AlertSettings())

        let speedKmh = leg.speedKmh ?? min(90, max(25, route.distance / max(1, route.expectedTravelTime) * 3.6))
        let speed = speedKmh / 3.6
        print(String(format: "  模擬車速 %.0f km/h", speedKmh))
        let start = Date()
        var traveled = 0.0
        var second = 0.0
        var segment = 0
        var displayed = ""
        var previousDisplayed = ""
        var nextManeuver = 0
        var inTunnel = false
        while traveled < total {
            while segment < polyline.count - 2 && cumulative[segment + 1] <= traveled { segment += 1 }
            let a = polyline[segment], b = polyline[segment + 1]
            let span = max(0.01, cumulative[segment + 1] - cumulative[segment])
            let ratio = min(1, max(0, (traveled - cumulative[segment]) / span))
            let point = GeoPoint(lat: a.lat + (b.lat - a.lat) * ratio, lon: a.lon + (b.lon - a.lon) * ratio)
            let now = start.addingTimeInterval(second)
            let fix = VehicleFix(point: point, speedMps: speed, course: GeoMath.bearing(from: a, to: b),
                                 horizontalAccuracy: 5, timestamp: now)
            let stamp = String(format: "  %7.0f m %.5f,%.5f ", traveled, point.lat, point.lon)

            // 隧道裡沒有定位：只有時間在走
            let tunnelNow = isInTunnel(point)
            if tunnelNow != inTunnel {
                inTunnel = tunnelNow
                print(stamp + (tunnelNow ? "── 進隧道，定位中斷" : "── 出隧道，定位恢復"))
            }
            if tunnelNow {
                for event in sections.tick(now: now)?.events ?? [] {
                    if let text = describe(event) { print(stamp + text) }
                }
                traveled += speed
                second += 1
                continue
            }

            let navResult = nav.process(fix)
            previousDisplayed = displayed
            if let progress = navResult.progress, progress.nextInstruction != displayed {
                displayed = progress.nextInstruction
                print(stamp + String(format: "畫面下一步（%.0f m 後）：", progress.distanceToNextManeuver) + displayed)
            }
            for event in navResult.events {
                if case let .announce(_, text, distance) = event {
                    print(stamp + "語音：" + AnnouncementFormatter.maneuver(instruction: text, distance: distance))
                }
            }
            for event in engine.process(fix).events {
                if let text = describe(event) { print(stamp + text) }
            }
            for event in sections.process(fix).events {
                if let text = describe(event) { print(stamp + text) }
            }

            // 開到動作點之前，畫面應該正在顯示這個動作（這一秒剛好經過動作點時，看換之前顯示的）
            while nextManeuver < maneuvers.count && maneuvers[nextManeuver].position <= traveled + speed {
                let expected = maneuvers[nextManeuver].text
                totalManeuvers += 1
                if displayed == expected || previousDisplayed == expected {
                    correctManeuvers += 1
                } else {
                    print(stamp + "★ 動作點應顯示「\(expected)」，實際顯示「\(displayed)」")
                }
                nextManeuver += 1
            }
            traveled += speed
            second += 1
        }
        write(["leg": leg.name, "route": summary(of: route)], to: output)
    }
    print("")
    print("轉彎指示和實際動作點相符：\(correctManeuvers)／\(totalManeuvers)")
    return 0
}

func run() async -> Int32 {
    guard CommandLine.arguments.count >= 4 else {
        print("用法：RouteProbe <compare|plan|replay> <路線清單.json> <結果檔.jsonl> [road_lines.json] [cameras.json]")
        return 64
    }
    if CommandLine.arguments[1] == "replay" {
        guard CommandLine.arguments.count >= 6,
              let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])),
              let legs = try? JSONDecoder().decode([ReplayLeg].self, from: data) else {
            print("讀不了路線清單或沒有指定 cameras.json")
            return 66
        }
        FileManager.default.createFile(atPath: CommandLine.arguments[3], contents: nil)
        guard let output = FileHandle(forWritingAtPath: CommandLine.arguments[3]) else { return 73 }
        return await runReplay(legs: legs, databasePath: CommandLine.arguments[5], output: output)
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
