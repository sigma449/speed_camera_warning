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

/// 字卡高度依內容決定，不設最小高度：使用者實測（2026-11-20）覺得字卡太大、底部空白擋住地圖。
enum BannerLayout {
    static let iconSize: CGFloat = 64
    static let primaryFont = Font.system(size: 38, weight: .heavy, design: .rounded)
    static let primaryLineHeight: CGFloat = 46
    /// 和主數字同一行、但比較次要的字（「超速！」「區間倒數」「秒」）。
    static let primaryCompanionFont = Font.system(size: 26, weight: .heavy, design: .rounded)
    static let primaryUnitFont = Font.system(size: 20, weight: .heavy, design: .rounded)
    /// 取代主數字的整句狀態（「重新規劃中」「可依速限行駛」）。
    static let primaryStatusFont = Font.system(size: 28, weight: .heavy, design: .rounded)
    /// 合併字卡裡縮成一行的那一方（方案 A 細條、方案 B 小牌）。
    static let stripIconSize: CGFloat = 40
    static let stripFont = Font.system(size: 26, weight: .heavy, design: .rounded)
}

/// 導航中遇到照相點（沒有區間）時，兩張字卡怎麼放。2026-11-20 使用者要求方案 A／B 各打一個 IPA 實測，選定後再收斂。
enum BannerCombineStyle: String {
    /// 原本：導航卡、照相卡上下疊放。
    case stacked
    /// 方案 A：合成一張卡，誰重要誰大字（`NavigationCameraLead`），另一個縮成底部一行。
    case swap
    /// 方案 B：導航卡不動，右上角掛照相小牌；超速時整張卡變紅。
    case badge

    /// 這個建置的預設。方案 A／B 的 IPA 只差這一行。
    static let buildDefault: BannerCombineStyle = .swap

    /// `-bannerCombine stacked|swap|badge` 可覆寫（CI／內部比對用，不儲存）。
    static let current: BannerCombineStyle = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-bannerCombine"), i + 1 < args.count,
           let style = BannerCombineStyle(rawValue: args[i + 1]) {
            return style
        }
        return buildDefault
    }()
}

/// 主畫面上方的導航、區間、照相字卡。導航中遇到照相點且沒有區間時，依 `BannerCombineStyle` 合成一張。
struct TopAlertBanners: View {
    let progress: RouteProgress?
    let destination: String?
    let section: SectionStatus?
    let target: CameraTarget?
    let currentSpeed: Int
    var style = BannerCombineStyle.current

    var body: some View {
        if let progress, section == nil, let target, style != .stacked {
            if style == .badge {
                NavigationBanner(progress: progress, destination: destination, cameraBadge: target)
            } else {
                NavigationCameraBanner(progress: progress, target: target)
            }
        } else {
            if let progress {
                NavigationBanner(progress: progress, destination: destination)
            }
            if let section {
                SectionBanner(status: section, currentSpeed: currentSpeed)
            } else if let target {
                CameraBanner(target: target)
            }
        }
    }
}

/// 方案 A：導航和照相合成一張卡。主角用原本的大字版面，另一個縮成底部一行；誰當主角見 `NavigationCameraLead`。
struct NavigationCameraBanner: View {
    let progress: RouteProgress
    let target: CameraTarget

    var body: some View {
        VStack(spacing: 0) {
            switch NavigationCameraLead.decide(progress: progress, target: target) {
            case .navigation:
                NavigationBanner(progress: progress, destination: nil, embedded: true)
                CameraStrip(target: target)
            case .camera:
                CameraBanner(target: target, embedded: true)
                NavigationStrip(progress: progress)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

/// 方案 A 的照相細條：速限（或類型圖示）、距離、類型、高架／平面。地址不放，點地圖上的照相點看詳情。
struct CameraStrip: View {
    let target: CameraTarget

    var body: some View {
        HStack(spacing: 14) {
            CameraIndicator(limit: target.camera.enforcesSpeed ? target.camera.speedLimit : nil,
                            symbol: target.camera.symbolName, size: BannerLayout.stripIconSize)
                .frame(width: BannerLayout.iconSize)
            HStack(spacing: 10) {
                Text(AnnouncementFormatter.displayDistance(target.distance))
                    .font(BannerLayout.stripFont)
                    .monospacedDigit()
                    .foregroundStyle(target.isOverspeed ? Color.white : Color.yellow)
                    .lineLimit(1)
                    .fixedSize()
                Text(target.camera.type.displayName)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                if let level = target.camera.levelName {
                    LevelTag(text: level)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(target.isOverspeed ? BannerStyle.overspeed : BannerStyle.dark)
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

/// 方案 A 的導航細條：轉彎圖示、距離、短指示；重新規劃中只寫狀態。
struct NavigationStrip: View {
    let progress: RouteProgress

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: progress.isOffRoute ? "arrow.triangle.2.circlepath"
                  : NavigationController.symbol(for: progress.nextInstruction))
                .font(.system(size: 26, weight: .bold))
                .frame(width: BannerLayout.iconSize)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if progress.isOffRoute {
                    Text("重新規劃中")
                        .font(.headline)
                } else {
                    Text(AnnouncementFormatter.displayDistance(progress.distanceToNextManeuver))
                        .font(BannerLayout.stripFont)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                    Text(progress.maneuverText)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BannerStyle.good)
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

/// 方案 B：放在導航大字那一行右側的照相小牌。速限（或類型圖示）＋距離，第二行「超速！」或高架／平面。
/// 2026-11-22 使用者：小牌不能把導航卡撐高，所以整塊高度不超過大字那一行（`primaryLineHeight`）。
struct CameraBadge: View {
    let target: CameraTarget

    var body: some View {
        HStack(spacing: 6) {
            CameraIndicator(limit: target.camera.enforcesSpeed ? target.camera.speedLimit : nil,
                            symbol: target.camera.symbolName, size: BannerLayout.stripIconSize)
            VStack(alignment: .leading, spacing: 0) {
                Text(AnnouncementFormatter.displayDistance(target.distance))
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(target.isOverspeed ? Color.white : Color.yellow)
                // 只放得下一行：超速優先，高架／平面仍在無障礙說明裡。
                if target.isOverspeed {
                    Text("超速！")
                        .font(.system(size: 15, weight: .heavy))
                } else if let level = target.camera.levelName {
                    LevelTag(text: level, font: .system(size: 12, weight: .heavy))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(height: BannerLayout.primaryLineHeight)
        .background(BannerStyle.dark, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        let parts: [String?] = [target.camera.type.displayName,
                                AnnouncementFormatter.displayDistance(target.distance),
                                target.isOverspeed ? "超速！" : nil,
                                target.camera.levelName]
        return parts.compactMap { $0 }.joined(separator: "，")
    }
}

struct CameraBanner: View {
    let target: CameraTarget
    /// 合併在導航字卡裡（方案 A）：不放地址、不另外圓角，外層統一裁切。
    var embedded = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CameraIndicator(limit: target.camera.enforcesSpeed ? target.camera.speedLimit : nil,
                            symbol: target.camera.symbolName, size: BannerLayout.iconSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(AnnouncementFormatter.displayDistance(target.distance))
                        .font(BannerLayout.primaryFont)
                        .monospacedDigit()
                        .foregroundStyle(target.isOverspeed ? Color.white : Color.yellow)
                    if target.isOverspeed {
                        // 超速不能只靠紅底：色弱、強光或瞄一眼時也要看得懂
                        Text("超速！")
                            .font(BannerLayout.primaryCompanionFont)
                    }
                }
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
                if let detail = target.camera.reminderDetail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(BannerStyle.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !embedded {
                    Text(target.camera.shortAddress)
                        .font(.subheadline)
                        .foregroundStyle(BannerStyle.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(target.isOverspeed ? BannerStyle.overspeed : BannerStyle.dark,
                    in: RoundedRectangle(cornerRadius: embedded ? 0 : 20))
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
                                .font(BannerLayout.primaryUnitFont)
                            Text(String(status.remainingWholeSeconds))
                                .font(BannerLayout.primaryFont)
                                .monospacedDigit()
                            Text("秒")
                                .font(BannerLayout.primaryUnitFont)
                        }
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(minHeight: BannerLayout.primaryLineHeight, alignment: .leading)
                    } else {
                        Text("可依速限行駛")
                            .font(BannerLayout.primaryStatusFont)
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
    /// 方案 B：右上角掛照相小牌，超速時整張卡變紅。
    var cameraBadge: CameraTarget? = nil
    /// 合併在照相字卡裡（方案 A）：不另外圓角，外層統一裁切。
    var embedded = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: progress.isOffRoute ? "arrow.triangle.2.circlepath"
                  : NavigationController.symbol(for: progress.nextInstruction))
                .font(.system(size: 40, weight: .bold))
                .frame(width: BannerLayout.iconSize, height: BannerLayout.iconSize)
            VStack(alignment: .leading, spacing: 2) {
                // 方案 B 的小牌放在大字同一行右側，不另佔一行，導航卡高度和沒有照相時一樣。
                HStack(spacing: 8) {
                    if progress.isOffRoute {
                        // 舊路線的下一步已經不對了，不要繼續顯示
                        Text("重新規劃中")
                            .font(BannerLayout.primaryStatusFont)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    } else {
                        Text(AnnouncementFormatter.displayDistance(progress.distanceToNextManeuver))
                            .font(BannerLayout.primaryFont)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    if let cameraBadge {
                        Spacer(minLength: 0)
                        CameraBadge(target: cameraBadge)
                    }
                }
                .frame(minHeight: BannerLayout.primaryLineHeight, alignment: .leading)
                if !progress.isOffRoute {
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cameraBadge?.isOverspeed == true ? BannerStyle.overspeed : BannerStyle.good,
                    in: RoundedRectangle(cornerRadius: embedded ? 0 : 20))
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
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("關閉訊息")
        }
        .padding(12)
        .background(BannerStyle.caution, in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
    }
}

/// 「高架」「平面」標籤。App 分不出你在哪一層，看到標籤可以自己判斷這支照相是不是你這條路。
struct LevelTag: View {
    let text: String
    var font: Font = .subheadline.weight(.heavy)

    var body: some View {
        Text(text)
            .font(font)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(text == "高架" ? BannerStyle.elevated : BannerStyle.surface, in: Capsule())
            .foregroundStyle(.white)
    }
}

struct CameraDetailCard: View {
    let camera: Camera
    var isUserAdded = false
    var isUserModified = false
    var onEdit: (() -> Void)? = nil
    var onHide: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onRestore: (() -> Void)? = nil
    let onClose: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                CameraIndicator(limit: camera.enforcesSpeed ? camera.speedLimit : nil, symbol: camera.symbolName, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Label(camera.type.displayName, systemImage: camera.symbolName).font(.headline)
                        if let level = camera.levelName {
                            LevelTag(text: level)
                        }
                    }
                    if isUserAdded || isUserModified {
                        Text(isUserAdded ? "自行新增" : "已自行修改").font(.subheadline.weight(.semibold))
                    }
                    if camera.enforcesSpeed && camera.speedLimit == nil {
                        Text(UserCameraEdits.unsetSpeedLimitDescription)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(camera.address).font(.subheadline)
                    if ["milestone", "door", "lamp", "intersection", "official-milepost",
                        "existing-official-junction"].contains(camera.positionMethod ?? "") {
                        Text("位置依公告地址推定").font(.footnote.weight(.semibold))
                    }
                    if let detail = camera.enforcementDetail {
                        Text(detail).font(.subheadline)
                    }
                    if let conditions = camera.conditions {
                        Text(conditions).font(.footnote)
                    }
                    Text("取締方向：\(UserCameraDirection(camera: camera).description)")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let source = camera.source, let value = camera.sourceURL, let url = URL(string: value) {
                        Link("資料來源：\(source)", destination: url).font(.footnote)
                    }
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("關閉照相點資訊")
            }
            if camera.type != .section {
                HStack(spacing: 12) {
                    if let onEdit { secondaryAction("修改", action: onEdit) }
                    if isUserAdded {
                        if onDelete != nil { secondaryAction("刪除") { confirmDelete = true } }
                    } else if let onHide {
                        secondaryAction("隱藏", action: onHide)
                    }
                }
                if isUserModified, !isUserAdded, let onRestore {
                    secondaryAction("還原成原始資料", action: onRestore)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .confirmationDialog("刪除這個自行新增的照相點？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("刪除照相點", role: .destructive) { onDelete?() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("刪除後無法復原。")
        }
    }

    private func secondaryAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 8)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
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
    static var addCamera: String {
        UIImage(systemName: "camera.badge.plus") != nil ? "camera.badge.plus" : "camera.fill"
    }

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
