import CoreLocation
import Foundation
import MapKit
import Observation
import SpeedCamCore
import UIKit

/// App 的中心狀態：串起定位 → 測速提醒引擎 → 區間測速 → 導航 → 語音 → Live Activity。
@MainActor
@Observable
final class AppModel {

    // MARK: 對外狀態（畫面會觀察這些值）

    private(set) var database: CameraDatabase = .empty
    private(set) var index = SpatialIndex(cameras: [])
    /// 使用者設定。透過計算屬性包裝，寫入時自動存檔並套用到各元件。
    private var storedSettings: AlertSettings
    var settings: AlertSettings {
        get { storedSettings }
        set {
            let old = storedSettings
            storedSettings = newValue
            settingsChanged(from: old)
        }
    }

    private(set) var isCruising = false
    private(set) var lastFix: VehicleFix?
    private(set) var cameraTarget: CameraTarget?
    private(set) var sectionStatus: SectionStatus?
    private(set) var routeProgress: RouteProgress?
    private(set) var route: MKRoute?
    private(set) var destinationName: String?
    private(set) var isCalculatingRoute = false
    private(set) var authorizationDenied = false
    var statusMessage: String?

    /// 展示模式：用假資料與假軌跡跑一遍（CI 截圖、沒有真實資料時使用）。
    let demoMode: Bool
    /// 顯示 Live Activity 預覽頁（CI 截圖用）。
    let showGallery: Bool

    var vehicleMode: VehicleMode {
        get { settings.vehicleMode }
        set { settings.vehicleMode = newValue }
    }

    var currentSpeedKmh: Int { Int((lastFix?.speedKmh ?? 0).rounded()) }

    /// 目前畫面要顯示的速限：區間中用區間速限，否則用前方照相點的速限。
    var displayedSpeedLimit: Int? {
        if let s = sectionStatus { return s.section.speedLimit }
        return cameraTarget?.camera.speedLimit
    }

    var isOverspeed: Bool {
        if cameraTarget?.isOverspeed == true { return true }
        if let limit = displayedSpeedLimit, sectionStatus != nil {
            return Double(currentSpeedKmh) > Double(limit) + settings.overspeedToleranceKmh
        }
        return false
    }

    // MARK: 內部元件

    @ObservationIgnored private let location = LocationProvider()
    @ObservationIgnored private let announcer = VoiceAnnouncer()
    @ObservationIgnored private let activity = ActivityController()
    @ObservationIgnored private let navigation = NavigationController()
    @ObservationIgnored private var alertEngine: CameraAlertEngine
    @ObservationIgnored private var sectionTracker: SectionSpeedTracker
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private var didAppear = false

    private static let settingsKey = "alertSettings.v1"

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        demoMode = arguments.contains("-demo")
        showGallery = arguments.contains("-gallery")
        let loaded = Self.loadSettings()
        storedSettings = loaded
        alertEngine = CameraAlertEngine(index: SpatialIndex(cameras: []), settings: loaded)
        sectionTracker = SectionSpeedTracker(sections: [], settings: loaded)

        var db = CameraStore.loadBundled()
        if demoMode || db.cameras.isEmpty && arguments.contains("-demoIfEmpty") {
            db = CameraStore.demoDatabase()
        }
        applyDatabase(db)

        location.onFix = { [weak self] fix in
            guard let self, !self.demoMode else { return }
            self.handle(fix)
        }
        location.onAuthorizationChange = { [weak self] status in
            self?.authorizationChanged(status)
        }
        applySettingsToComponents()
    }

    // MARK: 生命週期

    func onAppear() {
        guard !didAppear else { return }
        didAppear = true
        if demoMode {
            startDemo()
        } else {
            refineSectionLengths()
        }
    }

    func sceneBecameActive() {
        // Live Activity 最長 8 小時，而且只能在前景開始；回到 App 時視需要重新開始。
        if isCruising && settings.liveActivityEnabled && activity.needsRestart {
            activity.start(initial: activityState())
        }
    }

    // MARK: 巡航

    func startCruise() {
        guard !isCruising else { return }
        if demoMode {
            isCruising = true
            return
        }
        switch location.authorizationStatus {
        case .notDetermined:
            location.requestAuthorization()
        case .denied, .restricted:
            authorizationDenied = true
            return
        default:
            break
        }
        isCruising = true
        UIApplication.shared.isIdleTimerDisabled = true
        alertEngine.reset()
        sectionTracker.reset()
        location.start()
        if settings.liveActivityEnabled {
            activity.start(initial: activityState())
        }
        announcer.speak("開始巡航，測速提醒已開啟")
    }

    func stopCruise() {
        guard isCruising else { return }
        endNavigation(silently: true)
        isCruising = false
        UIApplication.shared.isIdleTimerDisabled = false
        location.stop()
        activity.end()
        announcer.stopAll()
        cameraTarget = nil
        sectionStatus = nil
    }

    func toggleCruise() {
        isCruising ? stopCruise() : startCruise()
    }

    // MARK: 導航

    func search(_ query: String) async throws -> [MKMapItem] {
        let center = lastFix.map { CLLocationCoordinate2D(latitude: $0.point.lat, longitude: $0.point.lon) }
        return try await navigation.search(query, near: center)
    }

    func startNavigation(to item: MKMapItem) async {
        isCalculatingRoute = true
        defer { isCalculatingRoute = false }
        do {
            let newRoute = try await navigation.calculateRoute(to: item, mode: settings.vehicleMode)
            navigation.start(route: newRoute, destination: item)
            route = newRoute
            destinationName = item.name
            if !isCruising { startCruise() }
            let km = newRoute.distance / 1_000
            var text = "開始導航，全程\(String(format: "%.1f", km))公里"
            if let first = navigation.firstInstruction { text += "，\(first)" }
            announcer.speak(text)
            statusMessage = nil
        } catch {
            statusMessage = "路線規劃失敗：\(error.localizedDescription)"
        }
    }

    func endNavigation(silently: Bool = false) {
        guard navigation.isActive else { return }
        navigation.stop()
        route = nil
        routeProgress = nil
        destinationName = nil
        if !silently { announcer.speak("導航結束") }
    }

    private func reroute() {
        guard let destination = navigation.destination, navigation.shouldReroute() else { return }
        announcer.speak(AnnouncementFormatter.rerouting)
        Task {
            do {
                let newRoute = try await navigation.calculateRoute(to: destination, mode: settings.vehicleMode)
                navigation.start(route: newRoute, destination: destination)
                route = newRoute
            } catch {
                statusMessage = "重新規劃失敗：\(error.localizedDescription)"
            }
        }
    }

    // MARK: 定位處理（核心流程）

    func handle(_ fix: VehicleFix) {
        lastFix = fix

        let cam = alertEngine.process(fix)
        let sec = sectionTracker.process(fix)
        let nav = navigation.process(fix)

        cameraTarget = cam.target
        sectionStatus = sec.status
        routeProgress = nav?.progress

        // 語音優先順序：近距 / 超速 > 區間 > 預告 > 導航
        for event in cam.events { handleCameraEvent(event, fix: fix) }
        for event in sec.events { handleSectionEvent(event) }
        if let nav {
            for event in nav.events { handleRouteEvent(event) }
        }

        activity.update(activityState())
    }

    private func handleCameraEvent(_ event: CameraAlertEvent, fix: VehicleFix) {
        switch event {
        case let .preAlert(camera, distance):
            let th = settings.thresholds(speedLimit: camera.speedLimit, currentSpeedKmh: fix.speedKmh)
            announcer.speak(AnnouncementFormatter.cameraAlert(camera: camera, announcedDistance: spoken(distance, threshold: th.pre)))
        case let .nearAlert(camera, distance):
            let th = settings.thresholds(speedLimit: camera.speedLimit, currentSpeedKmh: fix.speedKmh)
            announcer.speak(AnnouncementFormatter.cameraAlert(camera: camera, announcedDistance: spoken(distance, threshold: th.near)),
                            urgent: true)
        case .passed:
            announcer.passTone()
        case let .overspeedStarted(limit, _):
            announcer.beep()
            announcer.speak(AnnouncementFormatter.overspeed(limit: limit), urgent: true)
        case .overspeedBeep:
            announcer.beep()
        case .overspeedEnded:
            break
        }
    }

    /// 播報時念門檻距離（300、100…）比念「296 公尺」自然；第一次偵測就已經很近時改念實際距離。
    private func spoken(_ distance: Double, threshold: Double) -> Double {
        distance >= threshold - 40 ? threshold : distance
    }

    private func handleSectionEvent(_ event: SectionEvent) {
        switch event {
        case let .entered(section, minimumSeconds):
            announcer.speak(AnnouncementFormatter.sectionEntered(section: section, minimumSeconds: minimumSeconds), urgent: true)
        case let .remaining(seconds):
            announcer.speak(AnnouncementFormatter.sectionRemaining(seconds: seconds))
        case .zeroReached:
            announcer.speak(AnnouncementFormatter.sectionZero)
        case let .completed(_, averageKmh, withinLimit):
            announcer.speak(AnnouncementFormatter.sectionCompleted(averageKmh: averageKmh, withinLimit: withinLimit))
        case .aborted:
            break
        }
    }

    private func handleRouteEvent(_ event: RouteEvent) {
        switch event {
        case let .announce(_, instruction, distance):
            announcer.speak(AnnouncementFormatter.maneuver(instruction: instruction, distance: distance))
        case .offRoute:
            reroute()
        case .arrived:
            announcer.speak(AnnouncementFormatter.arrived)
            endNavigation(silently: true)
        }
    }

    // MARK: Live Activity 內容

    func activityState() -> SpeedCamActivityAttributes.ContentState {
        var s = SpeedCamActivityAttributes.ContentState()
        s.currentSpeedKmh = currentSpeedKmh
        s.vehicleModeName = settings.vehicleMode.displayName
        if let sec = sectionStatus {
            s.mode = .section
            s.sectionEarliestExit = sec.earliestExit
            s.sectionAverageKmh = Int(sec.averageKmh.rounded())
            s.sectionLimit = sec.section.speedLimit
            s.sectionZero = sec.remainingSeconds <= 0
            s.isOverspeed = isOverspeed
        } else if let target = cameraTarget, target.phase >= .pre {
            s.mode = .camera
            s.cameraTypeName = target.camera.type.displayName
            s.cameraSymbol = target.camera.symbolName
            s.distanceMeters = target.distance
            s.speedLimit = target.camera.speedLimit
            s.isOverspeed = target.isOverspeed
        } else if let p = routeProgress {
            s.mode = .navigation
            s.maneuverText = p.nextInstruction
            s.maneuverSymbol = NavigationController.symbol(for: p.nextInstruction)
            s.maneuverDistance = p.distanceToNextManeuver
        } else {
            s.mode = .idle
        }
        return s
    }

    // MARK: 資料與設定

    var visibleCameraLimit: Int { 400 }

    func cameras(in region: MKCoordinateRegion) -> [Camera] {
        // 地圖縮得太小時不畫照相點，避免畫面塞滿、也省效能。
        guard region.span.latitudeDelta < 0.35 else { return [] }
        let c = region.center
        let latHalf = region.span.latitudeDelta / 2
        let lonHalf = region.span.longitudeDelta / 2
        return index.cameras(minLat: c.latitude - latHalf, maxLat: c.latitude + latHalf,
                             minLon: c.longitude - lonHalf, maxLon: c.longitude + lonHalf,
                             limit: visibleCameraLimit)
    }

    private func applyDatabase(_ db: CameraDatabase) {
        var db = db
        db.sections = SectionLengthRefiner.applyCached(to: db.sections)
        database = db
        index = SpatialIndex(cameras: db.cameras)
        alertEngine.replaceIndex(index)
        sectionTracker.replaceSections(db.sections)
    }

    private func refineSectionLengths() {
        guard database.sections.contains(where: { $0.lengthEstimated }) else { return }
        Task {
            let refined = await SectionLengthRefiner.refine(database.sections)
            database.sections = refined
            sectionTracker.replaceSections(refined)
        }
    }

    private func settingsChanged(from old: AlertSettings) {
        guard settings != old else { return }
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        applySettingsToComponents()
        if old.liveActivityEnabled != settings.liveActivityEnabled && isCruising {
            settings.liveActivityEnabled ? activity.start(initial: activityState()) : activity.end()
        }
    }

    private func applySettingsToComponents() {
        alertEngine.settings = settings
        sectionTracker.settings = settings
        announcer.voiceEnabled = settings.voiceEnabled
        announcer.beepEnabled = settings.beepEnabled
        activity.enabled = settings.liveActivityEnabled
    }

    private static func loadSettings() -> AlertSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(AlertSettings.self, from: data) else {
            return AlertSettings()
        }
        return s
    }

    func resetSettings() {
        let mode = settings.vehicleMode
        var fresh = AlertSettings()
        fresh.vehicleMode = mode
        settings = fresh
    }

    func testVoice() {
        let sample = Camera(id: "test", type: .fixed, lat: 0, lon: 0, heading: nil, speedLimit: 50)
        announcer.speak(AnnouncementFormatter.cameraAlert(camera: sample, announcedDistance: settings.generalPreDistance), urgent: true)
    }

    func testBeep() {
        announcer.beep()
    }

    func acknowledgeAuthorizationAlert() {
        authorizationDenied = false
    }

    private func authorizationChanged(_ status: CLAuthorizationStatus) {
        switch status {
        case .denied, .restricted:
            authorizationDenied = true
            if isCruising { stopCruise() }
        case .authorizedAlways, .authorizedWhenInUse:
            authorizationDenied = false
            if isCruising && !location.isRunning { location.start() }
        default:
            break
        }
    }

    // MARK: 展示模式

    private func startDemo() {
        isCruising = true
        let fixes = CameraStore.demoTrack(startTime: Date())
        demoTask = Task { @MainActor [weak self] in
            for fix in fixes {
                guard let self, !Task.isCancelled else { return }
                // 時間戳記改成現在，讓區間倒數與 Live Activity 計時正確
                var f = fix
                f.timestamp = Date()
                self.handle(f)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
