import MapKit
import SpeedCamCore
import SwiftUI

/// 開始導航前的預覽卡片。
/// - 地點階段：名稱、地址、路線距離與時間（還在規劃時顯示「規劃路線中…」）；按「查看路線」或點卡片進入路線預覽。
/// - 路線階段：「開始導航（10）」倒數，時間到或按下就開始導航；拖動地圖時倒數暫停。
struct NavigationPreviewCard: View {
    let preview: AppModel.NavigationPreview
    let vehicleMode: VehicleMode
    /// 倒數秒數；nil 表示沒有倒數（暫停或還沒開始）。
    let countdown: Int?
    let onShowRoute: () -> Void
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: preview.stage == .place ? "mappin.circle.fill" : "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.title)
                    .foregroundStyle(preview.stage == .place ? Color.red : Color.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.name)
                        .font(.title3.bold())
                        .lineLimit(2)
                    if !preview.subtitle.isEmpty {
                        Text(preview.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }

            summary

            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text("取消").frame(minWidth: 70)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                if preview.stage == .place {
                    Button(action: onShowRoute) {
                        Label("查看路線", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(preview.errorText != nil)
                } else {
                    Button(action: onStart) {
                        Text(countdown.map { "開始導航（\($0)）" } ?? "開始導航")
                            .font(.headline)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onTapGesture {
            // 地點階段點卡片任何地方都可以直接看路線
            if preview.stage == .place, preview.errorText == nil { onShowRoute() }
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let error = preview.errorText {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
        } else if let route = preview.route {
            VStack(alignment: .leading, spacing: 8) {
                // 接成一段文字，放不下時才會整段換行，不會每一項各自斷行
                Text([Self.distanceText(route.distance), Self.durationText(route.expectedTravelTime), vehicleMode.routeNote]
                    .compactMap { $0 }
                    .joined(separator: "・"))
                    .font(.headline)
                if let warning = preview.routeWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(BannerStyle.caution, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                Text("規劃路線中…")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    static func distanceText(_ meters: Double) -> String {
        meters < 1_000 ? "\(Int(meters.rounded())) 公尺" : String(format: "%.1f 公里", meters / 1_000)
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "約 \(minutes) 分鐘" }
        let rest = minutes % 60
        return rest == 0 ? "約 \(minutes / 60) 小時" : "約 \(minutes / 60) 小時 \(rest) 分"
    }
}
