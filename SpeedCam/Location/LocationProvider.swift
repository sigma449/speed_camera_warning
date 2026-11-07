import CoreLocation
import Foundation
import SpeedCamCore

/// 定位來源。兩種做法都會在背景（螢幕關閉、切到其他 App）繼續收到位置：
/// - iOS 17 以上：CLLocationUpdate.liveUpdates 取得導航等級的定位，配合 CLBackgroundActivitySession
/// - iOS 15、16：CLLocationManager
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var updatesTask: Task<Void, Never>?
    /// CLBackgroundActivitySession（iOS 17 以上）。存成 AnyObject，舊系統才不會碰到這個型別。
    private var backgroundSession: AnyObject?
    private var managerRunning = false

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

    var isRunning: Bool { updatesTask != nil || managerRunning }

    /// 系統記得的最後位置（沒有在巡航時，搜尋用它找附近的地點）。
    var lastKnownCoordinate: CLLocationCoordinate2D? {
        manager.location?.coordinate
    }

    func start() {
        guard !isRunning else { return }
        if #available(iOS 17, *), !LegacySupport.forced {
            startLiveUpdates()
        } else {
            startManagerUpdates()
        }
    }

    @available(iOS 17, *)
    private func startLiveUpdates() {
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

    private func startManagerUpdates() {
        managerRunning = true
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        if managerRunning {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            managerRunning = false
        }
        if #available(iOS 17, *) {
            (backgroundSession as? CLBackgroundActivitySession)?.invalidate()
        }
        backgroundSession = nil
    }

    static func fix(from location: CLLocation) -> VehicleFix {
        let course: Double? = (location.course >= 0 && location.courseAccuracy >= 0 && location.courseAccuracy < 90)
            ? location.course : nil
        return VehicleFix(point: GeoPoint(lat: location.coordinate.latitude, lon: location.coordinate.longitude),
                          speedMps: location.speed,   // 負值表示無效（見 VehicleFix.isReliable）
                          course: course,
                          horizontalAccuracy: max(0, location.horizontalAccuracy),
                          timestamp: location.timestamp)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self, self.managerRunning else { return }
            for location in locations {
                self.onFix?(LocationProvider.fix(from: location))
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.onAuthorizationChange?(status)
        }
    }
}
