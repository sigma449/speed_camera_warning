import Combine
import MapKit
import SpeedCamCore
import SwiftUI

/// 地圖鏡頭要移到哪裡。iOS 17 以上換成 MapCameraPosition，iOS 15、16 由 LegacyMapView 套用到 MKMapView。
enum MapTarget {
    case userLocation(followsHeading: Bool)
    case region(MKCoordinateRegion)
    case rect(MKMapRect)
    case camera(center: CLLocationCoordinate2D, distance: Double, heading: Double, pitch: Double)
}

/// 給 LegacyMapView 的一次鏡頭移動。id 每次都不同，同一個要求只會執行一次。
struct LegacyMapRequest {
    let id: Int
    let target: MapTarget
    let animated: Bool
}

/// 地圖鏡頭：跟隨目前位置（依車速縮放、行進方向朝上）、「回到目前位置」按鈕、自動回到中心。
///
/// 巡航中每次收到定位就自己算鏡頭位置（MapCamera），這樣才能依車速調整縮放；
/// 還沒有定位時改用系統的跟隨（.userLocation）。
@MainActor
final class MapFollowController: ObservableObject {
    @Published private(set) var isFollowing = true
    @Published private(set) var mode: MapFollowMode
    /// 切換顯示方式時短暫顯示的文字（例如「北方朝上」）。
    @Published private(set) var toast: String?
    /// iOS 15、16 的地圖要執行的鏡頭移動。iOS 17 以上用 `position`，這個一直是 nil。
    @Published private(set) var legacyRequest: LegacyMapRequest?

    /// MapCameraPosition（iOS 17 以上）。存成 Any，舊系統才不會碰到這個型別。
    private var storedPosition: Any?
    private var lastRequestID = 0
    private var lastInteraction: Date?
    private var policy = AutoRecenterPolicy()
    private var smoothedSpeed = 0.0
    private var lastCourse = 0.0
    private var lastFix: VehicleFix?
    private var toastTask: Task<Void, Never>?
    /// 導航預覽中不自動回到目前位置。
    private var autoRecenterSuspended = false

    private static let modeKey = "mapFollowMode"

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(MapFollowMode.init(rawValue:))
        let mode = saved ?? .headingUp
        self.mode = mode
        move(to: .userLocation(followsHeading: mode.rotatesWithHeading), animated: false)
    }

    @available(iOS 17, *)
    var position: MapCameraPosition {
        get { storedPosition as? MapCameraPosition ?? .automatic }
        set {
            objectWillChange.send()
            storedPosition = newValue
        }
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
            move(to: .userLocation(followsHeading: mode.rotatesWithHeading), animated: animated)
        }
    }

    /// 一開始先顯示某個範圍，但仍然跟隨（收到第一筆定位就移過去）。展示模式用。
    func setInitial(region: MKCoordinateRegion) {
        move(to: .region(region), animated: false)
    }

    /// 顯示指定範圍並停止跟隨（CI 截圖用）。
    func show(region: MKCoordinateRegion) {
        isFollowing = false
        lastInteraction = Date()
        move(to: .region(region), animated: false)
    }

    /// 導航預覽：鏡頭移到指定範圍，預覽期間不自動回到目前位置。
    func preview(region: MKCoordinateRegion) {
        beginPreview()
        move(to: .region(region), animated: true)
    }

    func preview(rect: MKMapRect) {
        beginPreview()
        move(to: .rect(rect), animated: true)
    }

    /// 預覽結束（開始導航或取消）：回到目前位置並恢復跟隨。
    func endPreview() {
        autoRecenterSuspended = false
        recenter(animated: true)
    }

    private func beginPreview() {
        isFollowing = false
        autoRecenterSuspended = true
        lastInteraction = Date()
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
        } else if !autoRecenterSuspended,
                  policy.shouldRecenter(fix: fix, isFollowing: false, lastInteraction: lastInteraction) {
            recenter(animated: true)
        }
    }

    private func apply(_ fix: VehicleFix, animated: Bool) {
        let distance = MapFollowCamera.distance(forSpeedKmh: smoothedSpeed, mode: mode)
        let heading = mode.rotatesWithHeading ? lastCourse : 0
        let ahead = MapFollowCamera.lookAhead(distance: distance, speedKmh: smoothedSpeed, mode: mode)
        let center = ahead > 0 ? GeoMath.destination(from: fix.point, bearing: heading, distance: ahead) : fix.point
        move(to: .camera(center: center.coordinate, distance: distance, heading: heading, pitch: mode.pitch),
             animated: animated)
    }

    private func move(to target: MapTarget, animated: Bool) {
        if #available(iOS 17, *), !LegacySupport.forced {
            let newPosition = Self.position(for: target)
            if animated {
                withAnimation(.linear(duration: 0.9)) { position = newPosition }
            } else {
                position = newPosition
            }
        } else {
            lastRequestID += 1
            legacyRequest = LegacyMapRequest(id: lastRequestID, target: target, animated: animated)
        }
    }

    @available(iOS 17, *)
    private static func position(for target: MapTarget) -> MapCameraPosition {
        switch target {
        case let .userLocation(followsHeading):
            return .userLocation(followsHeading: followsHeading, fallback: .automatic)
        case let .region(region):
            return .region(region)
        case let .rect(rect):
            return .rect(rect)
        case let .camera(center, distance, heading, pitch):
            return .camera(MapCamera(centerCoordinate: center, distance: distance, heading: heading, pitch: pitch))
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
