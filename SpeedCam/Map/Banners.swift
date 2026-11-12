import SpeedCamCore
import SwiftUI
import UIKit

// 主畫面上方的資訊橫幅與下方的操作列。字體刻意放大，方便開車時快速瞄一眼。

/// 橫幅配色。底色全部不透明，地圖的路名才不會透出來干擾閱讀；
/// 有顏色的底色都選得夠深，白字的對比至少 4.5:1（系統的亮紅、亮綠、亮橘配白字只有約 2～3:1）。
enum BannerStyle {
    static let dark = Color.black
    static let overspeed = Color(red: 0.77, green: 0.12, blue: 0.12)
    static let good = Color(red: 0.0, green: 0.48, blue: 0.20)
    static let caution = Color(red: 0.72, green: 0.35, blue: 0.0)
    static let elevated = Color(red: 0.0, green: 0.42, blue: 0.52)
    static let surface = Color(red: 0.45, green: 0.30, blue: 0.16)
    /// 橫幅裡的小字。不用 .secondary：它在紅底上會變成對比很低的粉色。
    static let secondaryText = Color.white.opacity(0.88)
}

enum BannerLayout {
    static let iconSize: CGFloat = 64
    static let primaryFont = Font.system(size: 46, weight: .heavy, design: .rounded)
    static let primaryLineHeight: CGFloat = 56
    static let minimumHeight: CGFloat = 176
}

struct CameraBanner: View {
    let target: CameraTarget

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SpeedLimitSign(limit: target.camera.speedLimit, size: BannerLayout.iconSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(AnnouncementFormatter.displayDistance(target.distance))
                    .font(BannerLayout.primaryFont)
                    .monospacedDigit()
                    .foregroundStyle(target.isOverspeed ? Color.white : Color.yellow)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(minHeight: BannerLayout.primaryLineHeight, alignment: .leading)
                HStack(spacing: 6) {
                    Label(target.camera.type.displayName, systemImage: target.camera.symbolName)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let level = target.camera.levelName {
                        LevelTag(text: level)
                    }
                }
                Text(target.camera.shortAddress)
                    .font(.subheadline)
                    .foregroundStyle(BannerStyle.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: BannerLayout.minimumHeight, alignment: .topLeading)
        .background(target.isOverspeed ? BannerStyle.overspeed : BannerStyle.dark,
                    in: RoundedRectangle(cornerRadius: 20))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

struct SectionBanner: View {
    let status: SectionStatus
    let currentSpeed: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 14) {
                SpeedLimitSign(limit: status.section.speedLimit, size: BannerLayout.iconSize)
                VStack(alignment: .leading, spacing: 0) {
                    if status.remainingSeconds > 0 {
                        // 秒數最大，看一眼就懂
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("區間倒數")
                                .font(.system(size: 24, weight: .heavy, design: .rounded))
                            Text(String(status.remainingWholeSeconds))
                                .font(BannerLayout.primaryFont)
                                .monospacedDigit()
                            Text("秒")
                                .font(.system(size: 24, weight: .heavy, design: .rounded))
                        }
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(minHeight: BannerLayout.primaryLineHeight, alignment: .leading)
                    } else {
                        Text("可依速限行駛")
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .foregroundStyle(.green)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: BannerLayout.primaryLineHeight, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
            }
            if status.remainingSeconds > 0 {
                suggestion
            }
            // 區間名稱很長（真實資料 27～32 字）又用不到；「以 N 計算」進入區間時語音會念。都不放在這裡。
            HStack(spacing: 8) {
                Text("均速 \(Int(status.averageKmh.rounded()))・剩 \(AnnouncementFormatter.displayDistance(status.remainingMeters))")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if status.section.lengthEstimated {
                    Text("長度為估算")
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: BannerLayout.minimumHeight, alignment: .topLeading)
        .background(BannerStyle.dark, in: RoundedRectangle(cornerRadius: 20))
        .foregroundStyle(.white)
    }

    /// 建議時速：依剩餘距離與剩餘時間計算，照這個時速以下開完，平均就不會超過「速限＋容許值」。
    private var suggestion: some View {
        let kmh = status.suggestedWholeKmh
        let tooFast = currentSpeed > kmh
        return HStack(spacing: 10) {
            Image(systemName: tooFast ? "tortoise.fill" : "checkmark.circle.fill")
                .font(.title2)
            Text(tooFast ? "請放慢：建議 \(kmh) 以下" : "建議時速 \(kmh) 以下")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tooFast ? BannerStyle.caution : BannerStyle.good, in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
    }
}

struct NavigationBanner: View {
    let progress: RouteProgress
    let destination: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: progress.isOffRoute ? "arrow.triangle.2.circlepath"
                  : NavigationController.symbol(for: progress.nextInstruction))
                .font(.system(size: 40, weight: .bold))
                .frame(width: BannerLayout.iconSize, height: BannerLayout.iconSize)
            VStack(alignment: .leading, spacing: 2) {
                if progress.isOffRoute {
                    // 舊路線的下一步已經不對了，不要繼續顯示
                    Text("重新規劃中")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(minHeight: BannerLayout.primaryLineHeight, alignment: .leading)
                } else {
                    Text(AnnouncementFormatter.displayDistance(progress.distanceToNextManeuver))
                        .font(BannerLayout.primaryFont)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(minHeight: BannerLayout.primaryLineHeight, alignment: .leading)
                    Text(progress.maneuverText)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let destination {
                    Text("往 \(destination)・剩 \(AnnouncementFormatter.displayDistance(progress.distanceRemaining))")
                        .font(.footnote)
                        .foregroundStyle(BannerStyle.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: BannerLayout.minimumHeight, alignment: .topLeading)
        .background(BannerStyle.good, in: RoundedRectangle(cornerRadius: 20))
        .foregroundStyle(.white)
    }
}

struct MessageBanner: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(text).font(.subheadline)
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
        }
        .padding(12)
        .background(BannerStyle.caution, in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
    }
}

/// 「高架」「平面」標籤。App 分不出你在哪一層，看到標籤可以自己判斷這支照相是不是你這條路。
struct LevelTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.heavy))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(text == "高架" ? BannerStyle.elevated : BannerStyle.surface, in: Capsule())
            .foregroundStyle(.white)
    }
}

struct CameraDetailCard: View {
    let camera: Camera
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SpeedLimitSign(limit: camera.speedLimit, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Label(camera.type.displayName, systemImage: camera.symbolName).font(.headline)
                    if let level = camera.levelName {
                        LevelTag(text: level)
                    }
                }
                Text(camera.address).font(.subheadline)
                Text(directionText).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title2) }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var directionText: String {
        guard let h = camera.heading else {
            switch camera.axis {
            case 0: return "取締方向：南北雙向"
            case 90: return "取締方向：東西雙向"
            default: return "取締方向：雙向或資料未提供"
            }
        }
        let names = ["北", "東北", "東", "東南", "南", "西南", "西", "西北"]
        let idx = Int((GeoMath.normalize(h) + 22.5) / 45) % 8
        return "取締方向：往\(names[idx])行駛的車輛"
    }
}

struct BottomBar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showSearch: Bool
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 8) {
            speedChip
                .layoutPriority(1)
            Spacer(minLength: 0)
            if model.route != nil {
                circleButton("xmark", tint: .red) { model.endNavigation() }
                    .accessibilityLabel("結束導航")
            } else {
                circleButton("magnifyingglass", tint: .blue) { showSearch = true }
                    .accessibilityLabel("搜尋目的地")
            }
            vehicleMenu
            circleButton(model.isCruising ? "stop.fill" : "play.fill",
                         tint: model.isCruising ? .gray : .green) { model.toggleCruise() }
                .accessibilityLabel(model.isCruising ? "停止巡航" : "開始巡航")
            circleButton("gearshape.fill", tint: .gray) { showSettings = true }
                .accessibilityLabel("設定")
        }
    }

    private var speedChip: some View {
        HStack(spacing: 8) {
            VStack(spacing: -2) {
                Text("\(model.currentSpeedKmh)")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                Text("km/h").font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            if let limit = model.displayedSpeedLimit {
                SpeedLimitSign(limit: limit, size: 40)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(model.isOverspeed ? BannerStyle.overspeed : Color.black.opacity(0.8), in: Capsule())
        .foregroundStyle(.white)
    }

    /// 車種有三種，切換前要看得到選項，所以用選單。機車兩種圖示一樣，所以加上小字。
    private var vehicleMenu: some View {
        Menu {
            Picker("車種", selection: Binding(get: { model.vehicleMode }, set: { model.vehicleMode = $0 })) {
                ForEach(VehicleMode.allCases, id: \.self) { mode in
                    Text(mode.routeTitle).tag(mode)
                }
            }
        } label: {
            VStack(spacing: 0) {
                Image(systemName: model.vehicleMode == .car ? "car.fill" : Symbols.motorcycle)
                    .font(.system(size: model.vehicleMode == .car ? 20 : 17, weight: .bold))
                if model.vehicleMode.isMotorcycle {
                    Text(model.vehicleMode.shortName)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                }
            }
            .frame(width: 48, height: 48)
            .background(Color.indigo.opacity(0.9), in: Circle())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("選擇車種：目前\(model.vehicleMode.displayName)")
    }

    private func circleButton(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .frame(width: 48, height: 48)
                .background(tint.opacity(0.9), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

enum Symbols {
    /// 機車圖示；舊系統沒有 motorcycle 符號時改用 scooter。
    static var motorcycle: String {
        UIImage(systemName: "motorcycle") != nil ? "motorcycle" : "scooter"
    }

    /// 路線預覽的圖示；舊系統沒有這個符號時改用路線指示的圖示。
    static var routePreview: String {
        let name = "point.topleft.down.to.point.bottomright.curvepath"
        return UIImage(systemName: name) != nil ? name : "arrow.triangle.turn.up.right.diamond.fill"
    }
}
