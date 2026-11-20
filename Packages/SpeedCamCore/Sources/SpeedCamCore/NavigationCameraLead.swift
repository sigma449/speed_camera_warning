import Foundation

/// 導航中遇到照相點、兩者合成一張字卡（方案 A，2026-11-20 試驗）時，誰用大字當主角、誰縮成底部一行。
///
/// 優先順序：超速 ＞ 轉彎點 100 m 內 ＞ 照相近距 ＞ 平常（導航）。
/// - 超速最急，照相一定大字（紅底）。
/// - 轉彎點很近時導航維持大字，免得為了看照相錯過路口。
/// - 照相已播過近距提醒（100／200 m）才換照相當主角；預告階段仍以導航為主。
/// - 重新規劃中導航沒有可用的下一步，照相當主角。
public enum NavigationCameraLead: Equatable, Sendable {
    case navigation
    case camera

    /// 轉彎點在這個距離（公尺）以內，導航維持大字。
    public static let turnPriorityDistance: Double = 100

    public static func decide(progress: RouteProgress, target: CameraTarget) -> NavigationCameraLead {
        if target.isOverspeed { return .camera }
        if progress.isOffRoute { return .camera }
        if progress.distanceToNextManeuver.isFinite,
           progress.distanceToNextManeuver <= turnPriorityDistance { return .navigation }
        return target.phase >= .near ? .camera : .navigation
    }
}
