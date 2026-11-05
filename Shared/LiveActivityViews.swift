import SwiftUI
import WidgetKit

// Live Activity 的畫面。Widget Extension 用它顯示在鎖定畫面、動態島與 CarPlay；
// App 內的「Live Activity 預覽」頁也用同一份程式碼，方便在 CI 截圖檢查。

typealias ActivityState = SpeedCamActivityAttributes.ContentState

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

// MARK: - CarPlay／Apple Watch 用的 .small 版面（約 240×78 ～ 240×100 pt）

/// 重點：字要大。只放「距離或倒數」與「速限」兩個大元素，其他資訊用小字。
struct SmallActivityView: View {
    let state: ActivityState

    var body: some View {
        HStack(spacing: 10) {
            leading
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
                }
                .foregroundStyle(secondaryColor)
            }
            // 不用 Spacer：HStack 的間距也會算在 Spacer 前面，文字會少 10 pt 的寬度。
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(state.isOverspeed ? Color.red.opacity(0.35) : Color.clear)
        .foregroundStyle(.white)
    }

    @ViewBuilder private var leading: some View {
        switch state.mode {
        case .camera:
            SpeedLimitSign(limit: state.speedLimit, size: 48)
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
            Text(ActivityFormat.distance(state.maneuverDistance))
        case .idle:
            Text("\(state.currentSpeedKmh)")
        }
    }

    private var secondary: String {
        switch state.mode {
        case .camera:
            let name = state.cameraTypeName ?? "測速照相"
            return state.isOverspeed ? "超速！\(name)" : name
        case .section:
            let avg = state.sectionAverageKmh.map { "均速 \($0)" } ?? "區間測速"
            if state.sectionZero { return "可依速限行駛・\(avg)" }
            if let kmh = state.sectionSuggestedKmh { return "建議≤\(kmh)・\(avg)" }
            return "區間倒數・\(avg)"
        case .navigation:
            return state.maneuverText ?? "導航中"
        case .idle:
            return "km/h・巡航中・\(state.vehicleModeName)"
        }
    }

    /// 最窄尺寸用的短文字。沒有另外定義的模式就沿用完整文字，放不下時再縮小。
    private var secondaryCompact: String {
        switch state.mode {
        case .section:
            let avg = state.sectionAverageKmh.map { "均 \($0)" }
            if state.sectionZero { return avg.map { "可依速限・\($0)" } ?? "可依速限行駛" }
            if let kmh = state.sectionSuggestedKmh { return avg.map { "≤\(kmh)・\($0)" } ?? "建議≤\(kmh)" }
            return avg.map { "區間・\($0)" } ?? "區間倒數"
        case .idle:
            return "km/h・\(state.vehicleModeName)"
        case .camera, .navigation:
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

struct LockScreenActivityView: View {
    let state: ActivityState

    var body: some View {
        HStack(spacing: 14) {
            SmallActivityView(state: state)
                .frame(height: 70)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(state.currentSpeedKmh)")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text("km/h")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
        }
        .padding(14)
        .activityBackgroundTint(state.isOverspeed ? Color.red.opacity(0.8) : Color.black.opacity(0.75))
        .activitySystemActionForegroundColor(.white)
    }
}

// MARK: - 動態島

struct CompactLeadingView: View {
    let state: ActivityState
    var body: some View {
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

struct CompactTrailingView: View {
    let state: ActivityState
    var body: some View {
        Group {
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
        .font(.system(.body, design: .rounded).weight(.bold))
        .monospacedDigit()
    }
}
