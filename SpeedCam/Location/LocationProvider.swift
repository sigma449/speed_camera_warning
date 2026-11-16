import CoreLocation
import Foundation
import os
import SpeedCamCore

private let locationLog = Logger(subsystem: "tw.speedcammap.app", category: "location")

/// 定位來源。兩種做法都會在背景（螢幕關閉、切到其他 App）繼續收到位置：
/// - iOS 17 以上：CLLocationUpdate.liveUpdates 取得導航等級的定位，配合 CLBackgroundActivitySession
/// - iOS 15、16：CLLocationManager
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var legacyManager: CLLocationManager?
    private var updatesTask: Task<Void, Never>?
    /// CLBackgroundActivitySession（iOS 17 以上）。存成 AnyObject，舊系統才不會碰到這個型別。
    private var backgroundSession: AnyObject?
    private var updateState = LocationUpdateState()

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

    var isRunning: Bool { updateState.generation != nil }

    /// 系統記得的最後位置（沒有在巡航時，搜尋用它找附近的地點）。
    var lastKnownCoordinate: CLLocationCoordinate2D? {
        (legacyManager?.location ?? manager.location)?.coordinate
    }

    func start() {
        updateState.request()
        restartIfNeeded()
    }

    func restartIfNeeded(now: Date = Date()) {
        guard let generation = updateState.beginIfNeeded(now: now, isAuthorized: isAuthorized) else { return }
        if #available(iOS 17, *), !LegacySupport.forced {
            startLiveUpdates(generation: generation)
        } else {
            startManagerUpdates()
        }
    }

    @available(iOS 17, *)
    private func startLiveUpdates(generation: UUID) {
        backgroundSession = CLBackgroundActivitySession()
        updatesTask = Task { [weak self] in
            var reason = "定位串流正常結束"
            defer { self?.finishUpdates(generation: generation, reason: reason) }
            guard !Task.isCancelled, self?.updateState.generation == generation else {
                reason = "定位串流啟動前已取消"
                return
            }
            do {
                for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
                    guard !Task.isCancelled else {
                        reason = "定位串流已取消"
                        return
                    }
                    guard let self, self.updateState.generation == generation else { return }
                    guard let location = update.location else { continue }
                    self.onFix?(LocationProvider.fix(from: location))
                }
            } catch is CancellationError {
                reason = "定位串流已取消"
            } catch {
                reason = "定位串流失敗：\(error.localizedDescription)"
            }
        }
    }

    private func startManagerUpdates() {
        let manager = CLLocationManager()
        legacyManager = manager
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stop() {
        updateState.stop()
        updatesTask?.cancel()
        updatesTask = nil
        releaseSession()
    }

    private func finishUpdates(generation: UUID, reason: String) {
        guard updateState.finish(generation, now: Date()) else {
            locationLog.debug("忽略已失效定位工作的收尾：\(reason, privacy: .public)")
            return
        }
        updatesTask = nil
        releaseSession()
        locationLog.warning("\(reason, privacy: .public)；仍在巡航且有權限時，五秒後可重試")
    }

    private func releaseSession() {
        if let manager = legacyManager {
            manager.delegate = nil
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
        }
        legacyManager = nil
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
            guard let self, self.legacyManager === manager, let generation = self.updateState.generation else { return }
            for location in locations {
                guard self.updateState.generation == generation else { return }
                self.onFix?(LocationProvider.fix(from: location))
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.legacyManager === manager, let generation = self.updateState.generation else { return }
            if let error = error as? CLError, error.code == .locationUnknown {
                locationLog.warning("暫時無法取得定位，保留定位工作：\(error.localizedDescription, privacy: .public)")
                return
            }
            self.finishUpdates(generation: generation, reason: "舊版定位失敗：\(error.localizedDescription)")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.onAuthorizationChange?(status)
        }
    }
}
