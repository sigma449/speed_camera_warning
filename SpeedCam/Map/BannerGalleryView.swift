import SpeedCamCore
import SwiftUI

/// 手機橫幅預覽頁（以 `-gallery -galleryBanners` 啟動）。
/// 展示模式不一定碰得到每個狀態，而且展示資料的文字很短，所以這裡固定列出各種狀態，並用真實資料裡最長的區間名稱。
/// 加上 `-galleryBottom` 從頁面底部開始顯示，CI 才拍得到整頁。
struct BannerGalleryView: View {
    private let startAnchor: UnitPoint =
        ProcessInfo.processInfo.arguments.contains("-galleryBottom") ? .bottom : .top

    private let section = SpeedSection(id: "gallery", name: "宜蘭縣南澳鄉 台9線 137.295K–141.458K（往北）",
                                       start: GeoPoint(lat: 24.5, lon: 121.8), end: GeoPoint(lat: 24.46, lon: 121.8),
                                       lengthMeters: 4_163, speedLimit: 60)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
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
            }
            .padding()
        }
        .defaultScrollAnchor(startAnchor)
        .background(Color(white: 0.3))
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
