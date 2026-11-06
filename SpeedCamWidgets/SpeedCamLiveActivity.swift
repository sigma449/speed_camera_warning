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
                    ExpandedLeadingView(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailingView(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SmallActivityView(state: context.state, showsLeading: false)
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
