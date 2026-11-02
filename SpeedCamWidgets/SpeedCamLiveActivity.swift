import ActivityKit
import SwiftUI
import WidgetKit

/// 測速提醒的 Live Activity。
/// - 鎖定畫面：LockScreenActivityView
/// - CarPlay Dashboard 與 Apple Watch：自訂的 .small 版面（大字），
///   不使用系統把動態島左右兩塊硬拼起來的預設樣式（那樣字會很小）。
struct SpeedCamLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpeedCamActivityAttributes.self) { context in
            FamilyAdaptiveView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    expandedLeading(context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(context.state.currentSpeedKmh)")
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        Text("km/h").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SmallActivityView(state: context.state)
                        .frame(height: 64)
                }
            } compactLeading: {
                CompactLeadingView(state: context.state)
            } compactTrailing: {
                CompactTrailingView(state: context.state)
            } minimal: {
                CompactLeadingView(state: context.state)
            }
            .keylineTint(context.state.isOverspeed ? Color.red : Color.yellow)
        }
        .supplementalActivityFamilies([.small])
    }

    @ViewBuilder
    private func expandedLeading(_ state: ActivityState) -> some View {
        switch state.mode {
        case .camera:
            SpeedLimitSign(limit: state.speedLimit, size: 40)
        case .section:
            SpeedLimitSign(limit: state.sectionLimit, size: 40)
        case .navigation, .idle:
            Image(systemName: state.maneuverSymbol ?? "location.north.line.fill")
                .font(.system(size: 26, weight: .bold))
        }
    }
}

/// 依顯示位置切換版面：.small（CarPlay、Apple Watch）用大字精簡版，其他（鎖定畫面）用完整版。
private struct FamilyAdaptiveView: View {
    @Environment(\.activityFamily) private var family
    let state: ActivityState

    var body: some View {
        switch family {
        case .small:
            SmallActivityView(state: state)
                .activityBackgroundTint(state.isOverspeed ? Color.red.opacity(0.85) : Color.black)
        default:
            LockScreenActivityView(state: state)
        }
    }
}
