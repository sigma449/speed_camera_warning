// 路線實測：用真正的 MapKit 規劃台灣的路線，比較不同避開設定實際走的路。
// 重機路線要不要走快速道路和市區高架，Apple 文件沒有寫，只能實測。
// 只在 CI 的 macOS runner 上跑（scripts/ci/route-probe.sh），不會編進 App。
//
// 用法：RouteProbe <結果檔.jsonl>
// 結果一行一個請求，包含每條路線的距離、時間、步驟文字和路線座標。

import CoreLocation
import Foundation
import MapKit

setvbuf(stdout, nil, _IOLBF, 0)

struct Place {
    let name: String
    let lat: Double
    let lon: Double
}

struct ProbeCase {
    /// 這條路線用來測哪一類道路
    let group: String
    /// 走最快路線時，預期會用到的道路
    let expected: String
    let from: Place
    let to: Place
}

struct ProbeConfig {
    let key: String
    let highway: MKDirections.RoutePreference
    let toll: MKDirections.RoutePreference
}

private func place(_ name: String, _ lat: Double, _ lon: Double) -> Place {
    Place(name: name, lat: lat, lon: lon)
}

let cases: [ProbeCase] = [
    // 收費國道
    ProbeCase(group: "收費國道", expected: "國道1或3號",
              from: place("台北車站", 25.0478, 121.5170), to: place("新竹車站", 24.8016, 120.9717)),
    ProbeCase(group: "收費國道", expected: "國道1或3號",
              from: place("台中車站", 24.1372, 120.6869), to: place("嘉義車站", 23.4794, 120.4407)),
    ProbeCase(group: "收費國道", expected: "國道5號（避開時應走北宜或濱海）",
              from: place("大坪林站", 24.9830, 121.5414), to: place("宜蘭車站", 24.7544, 121.7585)),
    // 不收費的國道：只避開收費時，可能還是會走
    ProbeCase(group: "免費國道", expected: "國道6號",
              from: place("霧峰區公所", 24.0620, 120.7010), to: place("埔里鎮公所", 23.9677, 120.9690)),
    ProbeCase(group: "免費國道", expected: "國道2號",
              from: place("桃園機場", 25.0777, 121.2328), to: place("鶯歌車站", 24.9543, 121.3547)),
    ProbeCase(group: "免費國道", expected: "國道8號",
              from: place("新市車站", 23.0790, 120.2890), to: place("安平古堡", 23.0015, 120.1606)),
    // 快速道路
    ProbeCase(group: "快速道路", expected: "台64",
              from: place("景安站", 24.9937, 121.5050), to: place("五股區公所", 25.0828, 121.4382)),
    ProbeCase(group: "快速道路", expected: "台65",
              from: place("頂埔站", 24.9600, 121.4197), to: place("五股區公所", 25.0828, 121.4382)),
    ProbeCase(group: "快速道路", expected: "台61",
              from: place("竹南車站", 24.6866, 120.8805), to: place("南寮漁港", 24.8487, 120.9279)),
    ProbeCase(group: "快速道路", expected: "台74",
              from: place("逢甲大學", 24.1790, 120.6469), to: place("大里區公所", 24.0994, 120.6775)),
    ProbeCase(group: "快速道路", expected: "台88",
              from: place("鳳山車站", 22.6270, 120.3582), to: place("潮州車站", 22.5500, 120.5418)),
    ProbeCase(group: "快速道路", expected: "台62",
              from: place("七堵車站", 25.0928, 121.7133), to: place("瑞芳車站", 25.1089, 121.8062)),
    // 市區高架和市區快速道路
    ProbeCase(group: "市區高架", expected: "建國高架",
              from: place("建國北路民權東路口", 25.0619, 121.5372), to: place("建國南路和平東路口", 25.0258, 121.5376)),
    ProbeCase(group: "市區高架", expected: "市民高架",
              from: place("松山車站", 25.0492, 121.5778), to: place("市民大道重慶北路口", 25.0488, 121.5130)),
    ProbeCase(group: "市區高架", expected: "水源快速道路",
              from: place("西藏路萬大路口", 25.0230, 121.4990), to: place("公館基隆路", 25.0146, 121.5340)),
    ProbeCase(group: "市區高架", expected: "環河快速道路",
              from: place("板橋華江橋頭", 25.0330, 121.4800), to: place("永和秀朗橋頭", 24.9990, 121.5280)),
    ProbeCase(group: "市區高架", expected: "洲美快速道路",
              from: place("士林基河路", 25.0950, 121.5240), to: place("關渡站", 25.1256, 121.4670)),
]

let configs = [
    // 汽車模式目前的設定
    ProbeConfig(key: "不避開", highway: .any, toll: .any),
    // 重機模式目前的設定
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
    for notice in route.advisoryNotices {
        print("    注意：\(notice)")
    }
    for step in route.steps where !step.instructions.isEmpty {
        print(String(format: "    %6.1f km  %@", step.distance / 1_000, step.instructions))
    }
}

func run() async -> Int32 {
    guard CommandLine.arguments.count >= 2 else {
        print("用法：RouteProbe <結果檔.jsonl>")
        return 64
    }
    let outputPath = CommandLine.arguments[1]
    FileManager.default.createFile(atPath: outputPath, contents: nil)
    guard let output = FileHandle(forWritingAtPath: outputPath) else {
        print("寫不了結果檔：\(outputPath)")
        return 73
    }

    print("語言：\(Locale.preferredLanguages)，地區：\(Locale.current.identifier)")
    var succeeded = 0
    var failed = 0

    for testCase in cases {
        print("")
        print("=== [\(testCase.group)] \(testCase.from.name) → \(testCase.to.name)（預期：\(testCase.expected)）")
        for config in configs {
            print("--- \(config.key)")
            let request = MKDirections.Request()
            request.source = MKMapItem(location: CLLocation(latitude: testCase.from.lat, longitude: testCase.from.lon),
                                       address: nil)
            request.destination = MKMapItem(location: CLLocation(latitude: testCase.to.lat, longitude: testCase.to.lon),
                                            address: nil)
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

            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes]) {
                output.write(data)
                output.write(Data([0x0A]))
            }
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
