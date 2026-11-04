import MapKit
import Observation
import SpeedCamCore
import SwiftUI

/// 地圖鏡頭：跟隨目前位置（依車速縮放、行進方向朝上）、「回到目前位置」按鈕、自動回到中心。
///
/// 巡航中每次收到定位就自己算鏡頭位置（MapCamera），這樣才能依車速調整縮放；
/// 還沒有定位時改用系統的跟隨（.userLocation）。
@MainActor
@Observable
final class MapFollowController {
    var position: MapCameraPosition
    private(set) var isFollowing = true
    private(set) var mode: MapFollowMode
    /// 切換顯示方式時短暫顯示的文字（例如「北方朝上」）。
    private(set) var toast: String?

    @ObservationIgnored private var lastInteraction: Date?
    @ObservationIgnored private var policy = AutoRecenterPolicy()
    @ObservationIgnored private var smoothedSpeed = 0.0
    @ObservationIgnored private var lastCourse = 0.0
    @ObservationIgnored private var lastFix: VehicleFix?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    private static let modeKey = "mapFollowMode"

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(MapFollowMode.init(rawValue:))
        let mode = saved ?? .headingUp
        self.mode = mode
        position = .userLocation(followsHeading: mode.rotatesWithHeading, fallback: .automatic)
    }

    /// 按鈕圖示：沒在跟隨時是空心箭頭；跟隨中依顯示方式不同。
    var buttonSymbol: String {
        guard isFollowing else { return "location" }
        switch mode {
        case .headingUp: return "location.north.line.fill"
        case .northUp: return "location.fill"
        case .headingUp3D: return "view.3d"
        }
    }

    var buttonAccessibilityLabel: String {
        isFollowing ? "切換地圖顯示方式，目前：\(mode.displayName)" : "回到目前位置"
    }

    /// 沒在跟隨 → 回到目前位置（縮放回適合的大小）；已經在跟隨 → 換下一種顯示方式。
    func buttonTapped() {
        if isFollowing {
            mode = mode.next
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            showToast(mode.displayName)
        }
        recenter(animated: true)
    }

    func recenter(animated: Bool) {
        isFollowing = true
        lastInteraction = nil
        if let fix = lastFix {
            apply(fix, animated: animated)
        } else {
            setPosition(.userLocation(followsHeading: mode.rotatesWithHeading, fallback: .automatic), animated: animated)
        }
    }

    /// 一開始先顯示某個範圍，但仍然跟隨（收到第一筆定位就移過去）。展示模式用。
    func setInitial(region: MKCoordinateRegion) {
        position = .region(region)
    }

    /// 顯示指定範圍並停止跟隨（CI 截圖用）。
    func show(region: MKCoordinateRegion) {
        isFollowing = false
        lastInteraction = Date()
        position = .region(region)
    }

    /// 使用者動了地圖（拖曳、縮放、旋轉）：停止跟隨，並記下時間（自動回到中心要等使用者放手一段時間）。
    func userMovedMap() {
        if isFollowing { isFollowing = false }
        lastInteraction = Date()
    }

    /// 每次收到定位就呼叫。
    func handle(_ fix: VehicleFix) {
        lastFix = fix
        smoothedSpeed = MapFollowCamera.smoothedSpeed(previous: smoothedSpeed, current: fix.speedKmh)
        if let course = fix.course, fix.speedKmh >= 5 {
            lastCourse = course
        }
        if isFollowing {
            apply(fix, animated: true)
        } else if policy.shouldRecenter(fix: fix, isFollowing: false, lastInteraction: lastInteraction) {
            recenter(animated: true)
        }
    }

    private func apply(_ fix: VehicleFix, animated: Bool) {
        let distance = MapFollowCamera.distance(forSpeedKmh: smoothedSpeed, mode: mode)
        let heading = mode.rotatesWithHeading ? lastCourse : 0
        let ahead = MapFollowCamera.lookAhead(distance: distance, speedKmh: smoothedSpeed, mode: mode)
        let center = ahead > 0 ? GeoMath.destination(from: fix.point, bearing: heading, distance: ahead) : fix.point
        let camera = MapCamera(centerCoordinate: center.coordinate, distance: distance, heading: heading, pitch: mode.pitch)
        setPosition(.camera(camera), animated: animated)
    }

    private func setPosition(_ newPosition: MapCameraPosition, animated: Bool) {
        if animated {
            withAnimation(.linear(duration: 0.9)) { position = newPosition }
        } else {
            position = newPosition
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { self?.toast = nil }
        }
    }
}
