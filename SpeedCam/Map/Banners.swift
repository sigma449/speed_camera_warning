import SpeedCamCore
import SwiftUI
import UIKit

// 主畫面上方的資訊橫幅與下方的操作列。字體刻意放大，方便開車時快速瞄一眼。

struct CameraBanner: View {
    let target: CameraTarget

    var body: some View {
        HStack(spacing: 14) {
            SpeedLimitSign(limit: target.camera.speedLimit, size: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(AnnouncementFormatter.displayDistance(target.distance))
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(target.isOverspeed ? Color.white : Color.yellow)
                HStack(spacing: 6) {
                    Label(target.camera.type.displayName, systemImage: target.camera.symbolName)
                        .font(.headline)
                    if let level = target.camera.levelName {
                        LevelTag(text: level)
                    }
                }
                Text(target.camera.address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(target.isOverspeed ? Color.red.opacity(0.9) : Color.black.opacity(0.8),
                    in: RoundedRectangle(cornerRadius: 20))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

struct SectionBanner: View {
    let status: SectionStatus
    let currentSpeed: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                SpeedLimitSign(limit: status.section.speedLimit, size: 64)
                VStack(alignment: .leading, spacing: 0) {
                    if status.remainingSeconds > 0 {
                        Text("還要 \(status.remainingWholeSeconds) 秒")
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                        Text("才能到終點（區間倒數）")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("可依速限行駛")
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .foregroundStyle(.green)
                    }
                }
                Spacer(minLength: 0)
            }
            if status.remainingSeconds > 0 {
                suggestion
            }
            HStack {
                stat("均速", "\(Int(status.averageKmh.rounded()))")
                stat("剩餘", AnnouncementFormatter.displayDistance(status.remainingMeters))
            }
            HStack(spacing: 6) {
                Image(systemName: "timer")
                Text(status.section.name)
                if Int(status.effectiveLimitKmh.rounded()) > status.section.speedLimit {
                    Text("・以 \(Int(status.effectiveLimitKmh.rounded())) 計算")
                }
                if status.section.lengthEstimated {
                    Text("・長度為估算").foregroundStyle(.yellow)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 20))
        .foregroundStyle(.white)
    }

    /// 建議時速：依剩餘距離與剩餘時間計算，照這個時速以下開完，平均就不會超過「速限＋容許值」。
    private var suggestion: some View {
        let kmh = status.suggestedWholeKmh
        let tooFast = currentSpeed > kmh
        return HStack(spacing: 10) {
            Image(systemName: tooFast ? "tortoise.fill" : "checkmark.circle.fill")
                .font(.title2)
            VStack(alignment: .leading, spacing: 0) {
                Text("建議時速 \(kmh) 以下")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text(tooFast ? "目前 \(currentSpeed)，請放慢" : "依剩餘 \(AnnouncementFormatter.displayDistance(status.remainingMeters)) 計算")
                    .font(.caption)
                    .opacity(0.85)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background((tooFast ? Color.orange : Color.green).opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct NavigationBanner: View {
    let progress: RouteProgress
    let destination: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: NavigationController.symbol(for: progress.nextInstruction))
                .font(.system(size: 40, weight: .bold))
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(AnnouncementFormatter.displayDistance(progress.distanceToNextManeuver))
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text(progress.nextInstruction)
                    .font(.headline)
                    .lineLimit(2)
                if let destination {
                    Text("往 \(destination)・剩 \(AnnouncementFormatter.displayDistance(progress.distanceRemaining))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 20))
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
        .background(Color.orange.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
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
            .background(text == "高架" ? Color.teal : Color.brown, in: Capsule())
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
    @Environment(AppModel.self) private var model
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
            circleButton(model.vehicleMode == .car ? "car.fill" : Symbols.motorcycle, tint: .indigo) {
                model.vehicleMode = model.vehicleMode == .car ? .motorcycle : .car
            }
            .accessibilityLabel("切換車種：目前\(model.vehicleMode.displayName)")
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
        .background(model.isOverspeed ? Color.red : Color.black.opacity(0.8), in: Capsule())
        .foregroundStyle(.white)
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
    /// 重機圖示；舊系統沒有 motorcycle 符號時改用 scooter。
    static var motorcycle: String {
        UIImage(systemName: "motorcycle") != nil ? "motorcycle" : "scooter"
    }
}
