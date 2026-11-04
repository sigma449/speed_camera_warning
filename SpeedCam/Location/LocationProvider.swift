import CoreLocation
import Foundation
import SpeedCamCore

/// 定位來源：用 iOS 17 的 CLLocationUpdate.liveUpdates 取得導航等級的定位，
/// 並以 CLBackgroundActivitySession 讓 App 在背景（螢幕關閉、切到其他 App）時繼續收到位置。
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var updatesTask: Task<Void, Never>?
    private var backgroundSession: CLBackgroundActivitySession?

    var onFix: ((VehicleFix) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    var isRunning: Bool { updatesTask != nil }

    /// 系統記得的最後位置（沒有在巡航時，搜尋用它找附近的地點）。
    var lastKnownCoordinate: CLLocationCoordinate2D? {
        manager.location?.coordinate
    }

    func start() {
        guard updatesTask == nil else { return }
        backgroundSession = CLBackgroundActivitySession()
        updatesTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
                    if Task.isCancelled { break }
                    guard let location = update.location else { continue }
                    self?.onFix?(LocationProvider.fix(from: location))
                }
            } catch {
                // 定位串流結束（例如權限被關閉），由權限變更的回呼處理。
            }
        }
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    static func fix(from location: CLLocation) -> VehicleFix {
        let course: Double? = (location.course >= 0 && location.courseAccuracy >= 0 && location.courseAccuracy < 90)
            ? location.course : nil
        return VehicleFix(point: GeoPoint(lat: location.coordinate.latitude, lon: location.coordinate.longitude),
                          speedMps: location.speed >= 0 ? location.speed : 0,
                          course: course,
                          horizontalAccuracy: max(0, location.horizontalAccuracy),
                          timestamp: location.timestamp)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.onAuthorizationChange?(status)
        }
    }
}
