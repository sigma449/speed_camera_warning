import SwiftUI
import WidgetKit

// Live Activity 的畫面。Widget Extension 用它顯示在鎖定畫面、動態島與 CarPlay；
// App 內的「Live Activity 預覽」頁也用同一份程式碼，方便在 CI 截圖檢查。

typealias ActivityState = SpeedCamActivityState

struct StaleActivityView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("已停止更新")
                .font(.system(size: 24, weight: .bold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text("請開啟 App")
                .font(.system(size: 15, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

enum ActivityFormat {
    static func distance(_ meters: Double?) -> String {
        guard let m = meters else { return "--" }
        if m >= 1_000 { return String(format: "%.1fkm", m / 1_000) }
        return "\(Int((m / 10).rounded()) * 10)m"
    }

    static func countdownRange(until date: Date?) -> ClosedRange<Date> {
        let now = Date()
        let end = max(now, date ?? now)
        return now...end
    }
}

/// 速限標誌（紅圈白底黑字）。
struct SpeedLimitSign: View {
    let limit: Int?
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().fill(.white)
            Circle().strokeBorder(.red, lineWidth: size * 0.13)
            Text(limit.map(String.init) ?? "--")
                .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.black)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(size * 0.12)
        }
        .frame(width: size, height: size)
    }
}

struct CameraIndicator: View {
    let limit: Int?
    let symbol: String
    let size: CGFloat

    var body: some View {
        if let limit {
            SpeedLimitSign(limit: limit, size: size)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.62, weight: .bold))
                .foregroundStyle(.yellow)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - CarPlay／Apple Watch 用的 .small 版面（約 240×78 ～ 240×100 pt）

/// 重點：字要大。只放「距離或倒數」與「速限」兩個大元素，其他資訊用小字。
@available(iOS 16.1, *)
struct SmallActivityView: View {
    let state: ActivityState
    var isStale = false
    /// 動態島展開時，上面已經有速限標誌或圖示，這裡就不再顯示一次。
    var showsLeading = true
    /// 超速時自己加一層紅色。鎖定畫面整張卡片已經是紅底，再加會多出一塊方框。
    var tintsOverspeed = true

    var body: some View {
        if isStale {
            StaleActivityView()
        } else {
            liveContent
        }
    }

    private var liveContent: some View {
        HStack(spacing: 10) {
            if showsLeading {
                leading
            }
            VStack(alignment: .leading, spacing: 0) {
                primary
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                // 放得下就顯示完整文字；最窄的尺寸（170 pt）改用短文字，字不用縮太小，也不會被截斷。
                ViewThatFits(in: .horizontal) {
                    secondaryLabel(secondary)
                    secondaryLabel(secondaryCompact)
                        .minimumScaleFactor(0.7)
                    if state.mode == .camera && state.cameraDetail?.hasPrefix("取締：") == true
                        && state.navHint == nil && !state.isOverspeed {
                        secondaryLabel(state.cameraTypeName ?? "測速照相")
                            .minimumScaleFactor(0.7)
                    }
                }
                .foregroundStyle(secondaryColor)
            }
            // 不用 Spacer：HStack 的間距也會算在 Spacer 前面，文字會少 10 pt 的寬度。
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(state.isOverspeed && tintsOverspeed ? Color.red.opacity(0.35) : Color.clear)
        .foregroundStyle(.white)
    }

    @ViewBuilder private var leading: some View {
        switch state.mode {
        case .camera:
            CameraIndicator(limit: state.speedLimit, symbol: state.cameraSymbol ?? "camera.fill", size: 48)
        case .section:
            SpeedLimitSign(limit: state.sectionLimit, size: 48)
        case .navigation:
            Image(systemName: state.maneuverSymbol ?? "arrow.up")
                .font(.system(size: 34, weight: .bold))
                .frame(width: 48, height: 48)
        case .idle:
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 30, weight: .bold))
                .frame(width: 48, height: 48)
        }
    }

    @ViewBuilder private var primary: some View {
        switch state.mode {
        case .camera:
            Text(ActivityFormat.distance(state.distanceMeters))
                .foregroundStyle(state.isOverspeed ? Color.white : Color.yellow)
        case .section:
            if state.sectionZero {
                Text("時間到").foregroundStyle(.green)
            } else {
                Text(timerInterval: ActivityFormat.countdownRange(until: state.sectionEarliestExit), countsDown: true)
                    .foregroundStyle(.orange)
            }
        case .navigation:
            // 重新規劃時沒有距離，大字改顯示車速
            if state.maneuverDistance == nil {
                Text("\(state.currentSpeedKmh)")
            } else {
                Text(ActivityFormat.distance(state.maneuverDistance))
            }
        case .idle:
            Text("\(state.currentSpeedKmh)")
        }
    }

    private var secondary: String {
        // 快到轉彎了：這時下一步比照相類型或建議時速重要（語音也會念）
        if let hint = state.navHint { return hint }
        switch state.mode {
        case .camera:
            // 超速時只要知道超速，距離和速限都在旁邊
            if state.isOverspeed { return "超速！" }
            let name = state.cameraTypeName ?? "測速照相"
            return state.cameraDetail.map { "\(name)・\($0)" } ?? name
        case .section:
            let avg = state.sectionAverageKmh.map { "均速 \($0)" } ?? "區間測速"
            if state.sectionZero { return "可依速限行駛・\(avg)" }
            if let kmh = state.sectionSuggestedKmh { return "建議≤\(kmh)・\(avg)" }
            return "區間倒數・\(avg)"
        case .navigation:
            return state.maneuverText ?? "導航中"
        case .idle:
            return "km/h・\(state.vehicleModeName)"
        }
    }

    /// 最窄尺寸用的短文字。沒有另外定義的模式就沿用完整文字，放不下時再縮小。
    private var secondaryCompact: String {
        if let hint = state.navHintCompact { return hint }
        switch state.mode {
        case .section:
            let avg = state.sectionAverageKmh.map { "均 \($0)" }
            if state.sectionZero { return avg.map { "可依速限・\($0)" } ?? "可依速限行駛" }
            if let kmh = state.sectionSuggestedKmh { return avg.map { "≤\(kmh)・\($0)" } ?? "建議≤\(kmh)" }
            return avg.map { "區間・\($0)" } ?? "區間倒數"
        case .navigation:
            return state.maneuverTextCompact ?? secondary
        case .camera:
            if state.isOverspeed { return "超速！" }
            if let detail = state.cameraDetail, detail.hasPrefix("取締："),
               let first = detail.split(separator: "、").first {
                return String(first) + (detail.contains("、") ? "等" : "")
            }
            return state.cameraTypeName ?? "測速照相"
        case .idle:
            return secondary
        }
    }

    private func secondaryLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
    }

    private var secondaryColor: Color {
        state.isOverspeed ? .white : .white.opacity(0.85)
    }
}

// MARK: - 鎖定畫面版面

@available(iOS 16.1, *)
struct LockScreenActivityView: View {
    let state: ActivityState
    var isStale = false

    var body: some View {
        HStack(spacing: 14) {
            SmallActivityView(state: state, isStale: isStale, tintsOverspeed: false)
                .frame(height: 70)
            // 巡航時大字已經是車速，不再顯示一次
            if !isStale && state.mode != .idle {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(state.currentSpeedKmh)")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    // 不用 .secondary：在紅底上會變成看不清楚的粉紅色
                    Text("km/h")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.88))
                }
                .foregroundStyle(.white)
            }
        }
        .padding(14)
        .activityBackgroundTint(!isStale && state.isOverspeed ? Color.red.opacity(0.8) : Color.black.opacity(0.75))
        .activitySystemActionForegroundColor(.white)
    }
}

// MARK: - 動態島

/// 展開時左上角：速限標誌或圖示（下方的 SmallActivityView 就不再顯示）。
struct ExpandedLeadingView: View {
    let state: ActivityState
    var isStale = false

    var body: some View {
        if isStale {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 26, weight: .bold))
                .accessibilityLabel("已停止更新")
        } else {
            liveContent
        }
    }

    @ViewBuilder private var liveContent: some View {
        switch state.mode {
        case .camera:
            CameraIndicator(limit: state.speedLimit, symbol: state.cameraSymbol ?? "camera.fill", size: 40)
        case .section:
            SpeedLimitSign(limit: state.sectionLimit, size: 40)
        case .navigation:
            Image(systemName: state.maneuverSymbol ?? "arrow.up")
                .font(.system(size: 26, weight: .bold))
        case .idle:
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 26, weight: .bold))
        }
    }
}

/// 展開時右上角：目前車速。巡航時下方的大字已經是車速，這裡不顯示。
struct ExpandedTrailingView: View {
    let state: ActivityState
    var isStale = false

    var body: some View {
        if !isStale && state.mode != .idle {
            VStack(alignment: .trailing, spacing: 0) {
                Text("\(state.currentSpeedKmh)")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text("km/h").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct CompactLeadingView: View {
    let state: ActivityState
    var isStale = false
    var body: some View {
        if isStale {
            Image(systemName: "pause.circle.fill")
                .accessibilityLabel("已停止更新")
        } else {
            liveContent
        }
    }

    @ViewBuilder private var liveContent: some View {
        switch state.mode {
        case .camera:
            Image(systemName: state.cameraSymbol ?? "camera.fill")
                .foregroundStyle(state.isOverspeed ? Color.red : Color.yellow)
        case .section:
            Image(systemName: "timer").foregroundStyle(Color.orange)
        case .navigation:
            Image(systemName: state.maneuverSymbol ?? "arrow.up")
        case .idle:
            Image(systemName: "gauge.with.dots.needle.33percent")
        }
    }
}

@available(iOS 16.1, *)
struct CompactTrailingView: View {
    let state: ActivityState
    var isStale = false
    var body: some View {
        Group {
            if isStale {
                Text("已停止")
            } else {
                liveContent
            }
        }
        .font(.system(.body, design: .rounded).weight(.bold))
        .monospacedDigit()
    }

    @ViewBuilder private var liveContent: some View {
        switch state.mode {
        case .camera:
            Text(ActivityFormat.distance(state.distanceMeters))
        case .section:
            if state.sectionZero {
                Text("OK")
            } else {
                Text(timerInterval: ActivityFormat.countdownRange(until: state.sectionEarliestExit), countsDown: true)
                    .frame(maxWidth: 44)
            }
        case .navigation:
            Text(ActivityFormat.distance(state.maneuverDistance))
        case .idle:
            Text("\(state.currentSpeedKmh)")
        }
    }
}
