import SpeedCamCore
import SwiftUI

/// 手機橫幅預覽頁（以 `-gallery -galleryBanners` 啟動）。
/// 展示模式不一定碰得到每個狀態，而且展示資料的文字很短，所以這裡固定列出各種狀態，並用真實資料裡最長的區間名稱。
/// 加上 `-galleryBottom` 從頁面底部開始顯示，CI 才拍得到整頁。
@available(iOS 17, *)
struct BannerGalleryView: View {
    private let startAnchor: UnitPoint =
        ProcessInfo.processInfo.arguments.contains("-galleryBottom") ? .bottom : .top

    private let section = SpeedSection(id: "gallery", name: "宜蘭縣南澳鄉 台9線 137.295K–141.458K（往北）",
                                       start: GeoPoint(lat: 24.5, lon: 121.8), end: GeoPoint(lat: 24.46, lon: 121.8),
                                       lengthMeters: 4_163, speedLimit: 60)

    private let longAddressCamera = Camera(id: "gallery", type: .fixed, lat: 24.1, lon: 120.4, speedLimit: 80,
                                           address: "線西鄉台61線170.11公里(快速道路)(20公噸以上大貨車速限80公里/小時)",
                                           level: .elevated)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if ProcessInfo.processInfo.arguments.contains("-galleryHints") {
                    hintExamples
                } else {
                    standardExamples
                }
            }
            .padding()
        }
        .defaultScrollAnchor(startAnchor)
        .background(Color(white: 0.3))
    }

    @ViewBuilder
    private var hintExamples: some View {
        switch Result(catching: RouteHintStore.load) {
        case .success(let hints):
            ForEach(hints, id: \.id) { hint in
                label(hint.shortText)
                NavigationBanner(progress: RouteProgress(nextStepIndex: 1, nextInstruction: hint.instruction,
                    distanceToNextManeuver: 200, distanceRemaining: 7_300, distanceFromRoute: 0,
                    shortInstruction: hint.shortText, hintID: hint.id), destination: "坪林7-ELEVEN")
                SmallActivityView(state: ActivityState(mode: .navigation, maneuverText: hint.shortText,
                    maneuverSymbol: NavigationController.symbol(for: hint.instruction), maneuverDistance: 200))
                    .frame(width: 170, height: 78)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                SmallActivityView(state: ActivityState(mode: .camera, distanceMeters: 280, speedLimit: 50,
                    maneuverText: hint.shortText, maneuverSymbol: NavigationController.symbol(for: hint.instruction),
                    maneuverDistance: 200))
                    .frame(width: 170, height: 78)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        case .failure(let error):
            label("導航補充提示預覽載入失敗：\(error.localizedDescription)")
        }
    }

    private var standardExamples: some View {
        Group {
            label("導航＋區間同時")
            NavigationBanner(progress: RouteProgress(nextStepIndex: 1, nextInstruction: "右轉進入忠孝東路",
                                                     distanceToNextManeuver: 350, distanceRemaining: 7_300,
                                                     distanceFromRoute: 0),
                             destination: "台北車站")
            SectionBanner(status: status(remaining: 51, meters: 1_100, average: 61, suggested: 70), currentSpeed: 57)

            label("區間倒數，開太快（三位數秒數、最長距離）")
            SectionBanner(status: status(remaining: 615, meters: 12_300, average: 72, suggested: 55), currentSpeed: 62)

            label("區間歸零")
            SectionBanner(status: status(remaining: 0, meters: 320, average: 55, suggested: 70), currentSpeed: 60)

            label("照相點（真實資料裡很長的地址）")
            CameraBanner(target: CameraTarget(camera: longAddressCamera, distance: 280, phase: .pre, isOverspeed: false))

            label("接近區間")
            CameraBanner(target: SectionApproach(section: section, distance: 300).asCameraTarget)

            label("導航：最長的指示縮短後、偏離路線")
            NavigationBanner(progress: RouteProgress(nextStepIndex: 1, nextInstruction: "靠左行駛進入縣道122，朝臺灣新竹地方法院新竹簡易庭、新竹市政府前進",
                                                     distanceToNextManeuver: 800, distanceRemaining: 7_300,
                                                     distanceFromRoute: 0),
                             destination: "台北車站")
            NavigationBanner(progress: RouteProgress(nextStepIndex: 1, nextInstruction: "右轉進入忠孝東路",
                                                     distanceToNextManeuver: 350, distanceRemaining: 7_300,
                                                     distanceFromRoute: 80, isOffRoute: true),
                             destination: "台北車站")
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.white)
    }

    private func status(remaining: Double, meters: Double, average: Double, suggested: Double) -> SectionStatus {
        let now = Date()
        return SectionStatus(section: section, startTime: now, elapsed: 0, minimumSeconds: remaining,
                             remainingSeconds: remaining, earliestExit: now.addingTimeInterval(remaining),
                             traveledMeters: 0, remainingMeters: meters, averageKmh: average,
                             suggestedMaxKmh: suggested, effectiveLimitKmh: 70)
    }
}
