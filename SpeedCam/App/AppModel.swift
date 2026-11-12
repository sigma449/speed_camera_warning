import AVFoundation
import Combine
import CoreLocation
import Foundation
import MapKit
import os
import SpeedCamCore
import UIKit

/// App 的中心狀態：串起定位 → 測速提醒引擎 → 區間測速 → 導航 → 語音 → Live Activity。
/// 用 ObservableObject 而不是 @Observable：App 最低支援 iOS 15，@Observable 要 iOS 17。
@MainActor
final class AppModel: ObservableObject {

    // MARK: 對外狀態（畫面會觀察這些值）

    @Published private(set) var database: CameraDatabase = .empty
    @Published private(set) var index = SpatialIndex(cameras: [])
    /// 使用者設定。透過計算屬性包裝，寫入時自動存檔並套用到各元件。
    @Published private var storedSettings: AlertSettings
    var settings: AlertSettings {
        get { storedSettings }
        set {
            let old = storedSettings
            storedSettings = newValue
            settingsChanged(from: old)
        }
    }

    @Published private(set) var isCruising = false
    @Published private(set) var lastFix: VehicleFix?
    @Published private(set) var cameraTarget: CameraTarget?
    @Published private(set) var sectionStatus: SectionStatus?
    /// 正在接近、還沒進入的區間。
    @Published private(set) var sectionApproach: SectionApproach?
    @Published private(set) var routeProgress: RouteProgress?
    @Published private(set) var route: MKRoute?
    @Published private(set) var destinationName: String?
    @Published private(set) var destinationCoordinate: CLLocationCoordinate2D?
    @Published private(set) var isCalculatingRoute = false
    /// 開始導航前的預覽（先看地點，再看路線，最後開始導航）。
    @Published private(set) var preview: NavigationPreview?
    @Published private(set) var authorizationDenied = false
    @Published private(set) var recentDestinations: [RecentDestination] = RecentDestinationStore.load()
    @Published var statusMessage: String?
    @Published private var mapPlaceSelection = MapPlaceSelection()

    var selectedMapPlace: MapPlaceSelection.Place? { mapPlaceSelection.place }
    var canSelectMapPlace: Bool { mapPlaceMode == .browsing }
    private var mapPlaceMode: MapPlaceSelection.Mode {
        if preview != nil { return .previewing }
        return route != nil ? .navigating : .browsing
    }

    /// 展示模式：用假資料與假軌跡跑一遍（CI 截圖、沒有真實資料時使用）。
    let demoMode: Bool
    /// 顯示 Live Activity 預覽頁（CI 截圖用）。
    let showGallery: Bool
    /// 啟動時直接打開搜尋並輸入這段文字（CI 截圖用：`-search 台北車站`）。
    let initialSearchQuery: String?
    /// 啟動時地圖顯示的範圍（CI 截圖用：`-mapCenter 24.905,121.695 -mapSpan 0.16`）。
    let initialMapRegion: MKCoordinateRegion?
    /// 啟動後直接打開設定頁（CI 截圖用：`-settings`）。
    let initialShowSettings: Bool
    /// 搜尋壓力測試：打開搜尋，反覆輸入、刪除這段文字（CI 用來重現打字時閃退：`-typeSearch 台北車站`）。
    let searchTypingTest: String?
    /// 啟動後直接預覽到這個地點的導航（CI 截圖用：`-previewTo 25.0478,121.5170,台北車站`）。
    let initialPreviewTarget: (coordinate: CLLocationCoordinate2D, name: String)?
    let initialSelectedPlace: (coordinate: CLLocationCoordinate2D, name: String)?
    let mapAppearance: MapAppearance

    var vehicleMode: VehicleMode {
        get { settings.vehicleMode }
        set { settings.vehicleMode = newValue }
    }

    var currentSpeedKmh: Int { Int((lastFix?.speedKmh ?? 0).rounded()) }

    /// 目前畫面要顯示的速限：區間中用區間速限，否則用前方照相點的速限。
    var displayedSpeedLimit: Int? {
        if let s = sectionStatus { return s.section.speedLimit }
        return cameraTarget?.camera.speedLimit ?? sectionApproach?.section.speedLimit
    }

    /// 上方橫幅要顯示的照相點：預告過的照相點優先，其次是接近中的區間。
    var bannerTarget: CameraTarget? {
        if let target = cameraTarget, target.phase >= .pre { return target }
        return sectionApproach?.asCameraTarget
    }

    /// Live Activity 目前的狀態（設定頁顯示，實機看不到時才知道原因）。
    var liveActivityStatusText: String { activity.statusText }

    var isOverspeed: Bool {
        if cameraTarget?.isOverspeed == true { return true }
        return sectionStatus?.isOverspeed == true
    }

    // MARK: 內部元件

    private let location = LocationProvider()
    private let announcer = VoiceAnnouncer()
    private let activity = LiveActivityFactory.make()
    private let navigation = NavigationController()
    private let placeGeocoder = CLGeocoder()
    private var placeLookupTask: Task<Void, Never>?
    private let pathSnapper = SectionPathSnapper()
    private var alertEngine: CameraAlertEngine
    private var sectionTracker: SectionSpeedTracker
    private var demoTask: Task<Void, Never>?
    private var didAppear = false
    /// 巡航中每秒執行：沒有定位時讓區間倒數繼續跑，Live Activity 沒開始成功時再試一次。
    private var tickTask: Task<Void, Never>?
    private var lastActivityAttempt = Date.distantPast
    private var rerouteTask: Task<Void, Never>?
    private var lastRerouteAnnouncement = Date.distantPast
    private var audioRouteObserver: NSObjectProtocol?
    private var isInCar = false

    private static let settingsKey = "alertSettings.v2"
    private static let legacySettingsKey = "alertSettings.v1"

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        demoMode = arguments.contains("-demo")
        showGallery = arguments.contains("-gallery")
        if let i = arguments.firstIndex(of: "-search"), i + 1 < arguments.count {
            initialSearchQuery = arguments[i + 1]
        } else {
            initialSearchQuery = nil
        }
        initialMapRegion = Self.parseMapRegion(arguments)
        initialPreviewTarget = Self.parsePlaceTarget(arguments, flag: "-previewTo", defaultName: "目的地")
        initialSelectedPlace = Self.parsePlaceTarget(arguments, flag: "-selectPlace", defaultName: "所選位置")
        mapAppearance = MapAppearance(arguments: arguments)
        initialShowSettings = arguments.contains("-settings")
        if let i = arguments.firstIndex(of: "-typeSearch"), i + 1 < arguments.count {
            searchTypingTest = arguments[i + 1]
        } else {
            searchTypingTest = nil
        }
        _ = MapLanguage.atLaunch   // 記下啟動時的語言設定
        Logger(subsystem: "tw.speedcammap.app", category: "launch")
            .notice("arguments: \(arguments.dropFirst().joined(separator: " "), privacy: .public); languages: \(Locale.preferredLanguages.joined(separator: ","), privacy: .public)")
        var loaded = Self.loadSettings()
        if let i = arguments.firstIndex(of: "-vehicleMode"), i + 1 < arguments.count,
           let mode = VehicleMode(rawValue: arguments[i + 1]) {
            loaded.vehicleMode = mode
        }
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
        pathSnapper.onSnapped = { [weak self] sectionID, path in
            self?.applySnappedPath(path, toSection: sectionID)
        }
        applySettingsToComponents()
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.audioRouteChanged() }
            }
    }

    private static func parsePlaceTarget(_ arguments: [String], flag: String, defaultName: String)
        -> (coordinate: CLLocationCoordinate2D, name: String)? {
        guard let i = arguments.firstIndex(of: flag) else { return nil }
        guard i + 1 < arguments.count else {
            Logger(subsystem: "tw.speedcammap.app", category: "launch").error("地點啟動參數缺少座標：\(flag, privacy: .public)")
            return nil
        }
        let parts = arguments[i + 1].split(separator: ",", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else {
            Logger(subsystem: "tw.speedcammap.app", category: "launch").error("無效的地點啟動參數：\(flag, privacy: .public)")
            return nil
        }
        return (CLLocationCoordinate2D(latitude: lat, longitude: lon), parts.count > 2 ? parts[2] : defaultName)
    }

    private static func parseMapRegion(_ arguments: [String]) -> MKCoordinateRegion? {
        guard let i = arguments.firstIndex(of: "-mapCenter"), i + 1 < arguments.count else { return nil }
        let parts = arguments[i + 1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        var span = 0.05
        if let j = arguments.firstIndex(of: "-mapSpan"), j + 1 < arguments.count, let s = Double(arguments[j + 1]) {
            span = s
        }
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1]),
                                  span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span * 1.4))
    }

    // MARK: 生命週期

    func onAppear() {
        guard !didAppear else { return }
        didAppear = true
        if demoMode {
            startDemo()
        } else {
            refineSectionLengths()
            requestRoadSnapping(near: searchCenter.map { GeoPoint(lat: $0.latitude, lon: $0.longitude) })
            // 打開 App 就開始測速偵測（可在設定關閉）。
            if AppPreferences.autoStartCruise && !showGallery {
                startCruise()
            }
        }
        if !isCruising || !settings.liveActivityEnabled || demoMode {
            activity.end()
        }
    }

    func sceneBecameActive() {
        restartLiveActivityIfNeeded()
    }

    /// Live Activity 最長 8 小時，而且只能在前景開始；剛開 App 時太早要求也可能被系統拒絕。
    /// 所以回到 App 時、以及在前景的每隔幾秒都檢查一次，沒有在跑就再開。
    private func restartLiveActivityIfNeeded() {
        guard isCruising, !demoMode, settings.liveActivityEnabled, activity.needsRestart,
              UIApplication.shared.applicationState != .background,
              Date().timeIntervalSince(lastActivityAttempt) >= 5 else { return }
        lastActivityAttempt = Date()
        activity.start(initial: activityState())
    }

    /// 接上 CarPlay 時主動更新一次：Live Activity 可能是連上之前開始的，內容也可能已經過期。
    private func audioRouteChanged() {
        let inCar = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
        defer { isInCar = inCar }
        guard inCar, !isInCar, isCruising, settings.liveActivityEnabled else { return }
        activity.refresh(activityState())
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    private func tick() {
        guard isCruising else { return }
        restartLiveActivityIfNeeded()
        // 隧道裡沒有定位：照相提醒、區間倒數和語音都依時間繼續
        let now = Date()
        let cam = alertEngine.tick(now: now)
        let sec = sectionTracker.tick(now: now)
        guard cam != nil || sec != nil else { return }

        if let cam { cameraTarget = cam.target }
        if let sec {
            sectionStatus = sec.status
            sectionApproach = sec.approach
        }
        if let cam, let fix = alertEngine.lastFix {
            handleCameraResult(cam, fix: fix)
        }
        for event in sec?.events ?? [] { handleSectionEvent(event) }

        let alert = settings.liveActivityAlertsEnabled
            ? ActivityAlertPolicy.alert(cameraEvents: cam?.events ?? [], sectionEvents: sec?.events ?? [],
                                        cameraOverspeedActive: cameraTarget?.isOverspeed == true)
            : nil
        activity.update(activityState(), alert: alert)
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
            lastActivityAttempt = Date()
            activity.start(initial: activityState())
        }
        startTicking()
        announcer.speak("開始巡航，測速提醒已開啟")
    }

    func stopCruise() {
        dismissMapPlace()
        cancelPreview()
        endNavigation(silently: true)
        isCruising = false
        demoTask?.cancel()
        demoTask = nil
        tickTask?.cancel()
        tickTask = nil
        UIApplication.shared.isIdleTimerDisabled = false
        location.stop()
        activity.end()
        announcer.stopAll()
        alertEngine.reset()
        sectionTracker.reset()
        cameraTarget = nil
        sectionStatus = nil
        sectionApproach = nil
    }

    func toggleCruise() {
        isCruising ? stopCruise() : startCruise()
    }

    // MARK: 導航

    /// 搜尋的中心點：巡航中用最新定位，否則用系統記得的最後位置。
    var searchCenter: CLLocationCoordinate2D? {
        if let fix = lastFix { return fix.point.coordinate }
        return location.lastKnownCoordinate
    }

    func search(_ query: String) async throws -> [MKMapItem] {
        try await navigation.search(query, near: searchCenter)
    }

    func search(completion: MKLocalSearchCompletion) async throws -> [MKMapItem] {
        try await navigation.search(completion: completion)
    }

    // MARK: 地圖選點

    func selectMapPlace(at coordinate: CLLocationCoordinate2D, name: String? = nil) {
        let id: UUID
        do {
            guard let selected = try mapPlaceSelection.select(
                point: GeoPoint(lat: coordinate.latitude, lon: coordinate.longitude),
                name: name, mode: mapPlaceMode) else { return }
            id = selected
        } catch {
            statusMessage = error.localizedDescription
            Logger(subsystem: "tw.speedcammap.app", category: "mapPlace").error("\(error.localizedDescription, privacy: .public)")
            return
        }
        placeLookupTask?.cancel()
        placeGeocoder.cancelGeocode()
        placeLookupTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.selectedMapPlace?.id == id else { return }
            do {
                let placemarks = try await self.placeGeocoder.reverseGeocodeLocation(
                    CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
                guard !Task.isCancelled else { return }
                let placemark = placemarks.first
                let address = placemark.flatMap { MKPlacemark(placemark: $0).title }
                let applied = self.mapPlaceSelection.resolveAddress(id: id, name: placemark?.name, address: address)
                if applied, self.selectedMapPlace?.addressUnavailable == true {
                    Logger(subsystem: "tw.speedcammap.app", category: "mapPlace").warning("反查沒有地址，選點卡保留座標並顯示提醒")
                }
            } catch {
                guard !Task.isCancelled else { return }
                if self.mapPlaceSelection.resolveAddress(id: id, name: nil, address: nil) {
                    Logger(subsystem: "tw.speedcammap.app", category: "mapPlace")
                        .warning("反查地址失敗，選點卡保留座標：\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func dismissMapPlace() {
        placeLookupTask?.cancel()
        placeLookupTask = nil
        placeGeocoder.cancelGeocode()
        mapPlaceSelection.cancel()
    }

    func previewSelectedMapPlace() {
        guard let place = mapPlaceSelection.takeForPreview(mode: mapPlaceMode) else { return }
        beginPreview(to: MapItems.item(name: place.name, coordinate: place.point.coordinate),
                     subtitle: place.address ?? place.coordinateText)
    }

    // MARK: 導航預覽

    struct NavigationPreview {
        enum Stage: Equatable { case place, route }
        let item: MKMapItem
        let name: String
        let subtitle: String
        let coordinate: CLLocationCoordinate2D
        var route: MKRoute?
        /// 找不到符合車種規則的路線時，給使用者看的提醒。
        var routeWarning: String?
        var stage: Stage = .place
        /// 使用者已經要看路線（或時間到了），路線算好就切換過去。
        var wantsRoute = false
        var errorText: String?
        /// 每次預覽不同（地點或階段）都會變，畫面用來重新觸發計時與鏡頭移動。
        var key: String { "\(ObjectIdentifier(item).hashValue)-\(stage == .place ? "place" : "route")" }
    }

    private var previewTask: Task<Void, Never>?

    /// 選好目的地：先預覽地點，同時在背景規劃路線。
    func beginPreview(to item: MKMapItem, subtitle: String? = nil) {
        dismissMapPlace()
        endNavigation(silently: true)
        previewTask?.cancel()
        preview = NavigationPreview(item: item, name: item.name ?? "未命名地點",
                                    subtitle: subtitle ?? MapItems.subtitle(of: item),
                                    coordinate: MapItems.coordinate(of: item))
        isCalculatingRoute = true
        previewTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.preview?.item === item { self.isCalculatingRoute = false }
            }
            do {
                let source = self.mapAppearance.comparison == nil ? nil
                    : MapItems.item(name: "地圖對照起點", coordinate: MapAppearance.comparisonSource)
                let plan = try await self.navigation.calculateRoute(to: item, mode: self.settings.vehicleMode, from: source)
                guard !Task.isCancelled, self.preview?.item === item else { return }
                self.preview?.route = plan.route
                self.preview?.routeWarning = plan.warning?.text
                if self.preview?.wantsRoute == true { self.preview?.stage = .route }
            } catch {
                guard !Task.isCancelled, self.preview?.item === item else { return }
                self.preview?.errorText = "路線規劃失敗：\(error.localizedDescription)"
            }
        }
    }

    func beginPreview(to recent: RecentDestination) {
        beginPreview(to: MapItems.item(name: recent.name, coordinate: recent.coordinate), subtitle: recent.subtitle)
    }

    /// 從地點預覽切換到路線預覽（路線還在規劃的話，算好就切換）。
    func showRoutePreview() {
        guard var p = preview else { return }
        p.wantsRoute = true
        if p.route != nil { p.stage = .route }
        preview = p
    }

    /// 開始導航（使用者按下，或倒數結束）。
    func confirmPreview() {
        guard let p = preview, let route = p.route else { return }
        preview = nil
        startNavigation(route: route, destination: p.item, subtitle: p.subtitle)
    }

    func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        preview = nil
        isCalculatingRoute = false
    }

    func removeRecent(_ recent: RecentDestination) {
        recentDestinations.removeAll { $0.id == recent.id }
        RecentDestinationStore.save(recentDestinations)
    }

    func clearRecents() {
        recentDestinations = []
        RecentDestinationStore.save([])
    }

    private func rememberDestination(_ item: MKMapItem, subtitle: String?) {
        let entry = RecentDestination(name: item.name ?? "未命名地點",
                                      subtitle: subtitle ?? MapItems.subtitle(of: item),
                                      lat: MapItems.coordinate(of: item).latitude,
                                      lon: MapItems.coordinate(of: item).longitude,
                                      date: Date())
        recentDestinations = RecentDestinationStore.adding(entry, to: recentDestinations)
        RecentDestinationStore.save(recentDestinations)
    }

    private func startNavigation(route newRoute: MKRoute, destination item: MKMapItem, subtitle: String?) {
        navigation.start(route: newRoute, destination: item)
        route = newRoute
        destinationName = item.name
        destinationCoordinate = MapItems.coordinate(of: item)
        rememberDestination(item, subtitle: subtitle)
        if !isCruising { startCruise() }
        let km = newRoute.distance / 1_000
        var text = "開始導航，全程\(String(format: "%.1f", km))公里"
        if let first = navigation.firstInstruction { text += "，\(first)" }
        announcer.speak(text)
        statusMessage = navigation.routeHintWarning
    }

    /// 改語言後重新開啟 App 之前：結束巡航（Live Activity 也一起結束）。
    func prepareForRelaunch() {
        cancelPreview()
        stopCruise()
    }

    func endNavigation(silently: Bool = false) {
        guard navigation.isActive else { return }
        rerouteTask?.cancel()
        rerouteTask = nil
        navigation.stop()
        route = nil
        routeProgress = nil
        destinationName = nil
        destinationCoordinate = nil
        if !silently { announcer.speak("導航結束") }
    }

    /// 偏離路線時由 `RouteProgressTracker` 觸發；還沒回到路線上會每 15 秒再觸發一次，
    /// 所以這次失敗（沒有網路）或新路線又走錯，都不會卡在舊路線上。
    private func reroute() {
        guard let destination = navigation.destination, rerouteTask == nil else { return }
        // 重試時不要一直念
        if Date().timeIntervalSince(lastRerouteAnnouncement) >= 60 {
            lastRerouteAnnouncement = Date()
            announcer.speak(AnnouncementFormatter.rerouting)
        }
        let source = lastFix.map { MapItems.item(at: $0.point) }
        rerouteTask = Task { [weak self] in
            guard let self else { return }
            defer { self.rerouteTask = nil }
            do {
                let plan = try await self.navigation.calculateRoute(to: destination, mode: self.settings.vehicleMode,
                                                                    from: source)
                // 等待期間使用者可能已經結束導航
                guard !Task.isCancelled, self.navigation.destination === destination else { return }
                self.navigation.start(route: plan.route, destination: destination)
                self.route = plan.route
                let warnings = [plan.warning?.text, self.navigation.routeHintWarning].compactMap { $0 }
                self.statusMessage = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
                // 不等下一筆定位：藍線和下一步馬上換成新路線
                if let fix = self.lastFix {
                    self.routeProgress = self.navigation.process(fix)?.progress
                }
                self.activity.update(self.activityState(), alert: nil)
            } catch {
                guard !Task.isCancelled else { return }
                self.statusMessage = "重新規劃失敗，稍後再試：\(error.localizedDescription)"
            }
        }
    }

    // MARK: 定位處理（核心流程）

    func handle(_ fix: VehicleFix) {
        guard isCruising else { return }
        lastFix = fix

        // 隧道裡的基地台定位不能判斷照相點和區間，當作沒有定位，由 tick 依時間推算
        let cam = fix.isReliable ? alertEngine.process(fix) : nil
        let sec = fix.isReliable ? sectionTracker.process(fix) : nil
        let nav = navigation.process(fix)

        if let cam { cameraTarget = cam.target }
        if let sec {
            sectionStatus = sec.status
            sectionApproach = sec.approach
        }
        routeProgress = nav?.progress

        // 語音優先順序：近距 / 超速 > 區間 > 預告 > 導航
        if let cam { handleCameraResult(cam, fix: fix) }
        for event in sec?.events ?? [] { handleSectionEvent(event) }
        if let nav {
            for event in nav.events { handleRouteEvent(event) }
        }

        let alert = settings.liveActivityAlertsEnabled
            ? ActivityAlertPolicy.alert(cameraEvents: cam?.events ?? [], sectionEvents: sec?.events ?? [],
                                        cameraOverspeedActive: cameraTarget?.isOverspeed == true)
            : nil
        activity.update(activityState(), alert: alert)
    }

    private func handleCameraResult(_ result: CameraAlertResult, fix: VehicleFix) {
        for speech in CameraAnnouncementPolicy.speech(for: result, speedKmh: fix.speedKmh, settings: settings) {
            announcer.speak(speech.text, urgent: speech.urgent)
        }
        for event in result.events {
            switch event {
            case .passed: announcer.passTone()
            case .overspeedStarted, .overspeedBeep: announcer.beep()
            case .preAlert, .nearAlert, .overspeedEnded: break
            }
        }
    }

    /// 播報時念門檻距離（300、100…）比念「296 公尺」自然；第一次偵測就已經很近時改念實際距離。
    private func spoken(_ distance: Double, threshold: Double) -> Double {
        AnnouncementFormatter.announcedDistance(distance, threshold: threshold)
    }

    private func handleSectionEvent(_ event: SectionEvent) {
        switch event {
        case let .approaching(section, distance):
            let threshold = settings.thresholds(speedLimit: section.speedLimit, currentSpeedKmh: 0).pre
            announcer.speak(AnnouncementFormatter.sectionApproaching(
                section: section, announcedDistance: spoken(distance, threshold: threshold)))
        case let .entered(section, minimumSeconds):
            announcer.speak(AnnouncementFormatter.sectionEntered(
                section: section, minimumSeconds: minimumSeconds,
                effectiveLimitKmh: settings.sectionEffectiveLimit(section.speedLimit, sectionID: section.groupID)), urgent: true)
        case let .remaining(seconds):
            announcer.speak(AnnouncementFormatter.sectionRemaining(seconds: seconds,
                                                                   suggestedKmh: sectionStatus?.suggestedWholeKmh))
        case .zeroReached:
            announcer.speak(AnnouncementFormatter.sectionZero)
        case let .completed(_, averageKmh, withinLimit):
            announcer.speak(AnnouncementFormatter.sectionCompleted(averageKmh: averageKmh, withinLimit: withinLimit))
        case .aborted:
            break
        case let .overspeedStarted(threshold):
            // 照相機前的超速警示已經在嗶的話就不重複
            guard cameraTarget?.isOverspeed != true else { break }
            announcer.speak(AnnouncementFormatter.sectionOverspeed(threshold: threshold), urgent: true)
        case .overspeedBeep:
            guard cameraTarget?.isOverspeed != true else { break }
            announcer.beep()
        case .overspeedEnded:
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

    func activityState() -> SpeedCamActivityState {
        var s = SpeedCamActivityState()
        s.currentSpeedKmh = currentSpeedKmh
        s.vehicleModeName = settings.vehicleMode.shortName
        // 導航資訊一律放進去：區間和照相模式快到轉彎時，小字也要顯示下一步（見 navHint）
        if let p = routeProgress {
            s.maneuverText = p.isOffRoute ? "重新規劃中" : p.maneuverText
            s.maneuverSymbol = p.isOffRoute ? "arrow.triangle.2.circlepath" : NavigationController.symbol(for: p.nextInstruction)
            s.maneuverDistance = p.isOffRoute ? nil : p.distanceToNextManeuver
        }
        if let sec = sectionStatus {
            s.mode = .section
            s.sectionEarliestExit = sec.earliestExit
            s.sectionAverageKmh = Int(sec.averageKmh.rounded())
            s.sectionSuggestedKmh = sec.suggestedWholeKmh
            s.sectionLimit = sec.section.speedLimit
            s.sectionZero = sec.remainingSeconds <= 0
            s.isOverspeed = isOverspeed
        } else if let target = cameraTarget, target.phase >= .pre {
            s.mode = .camera
            s.cameraTypeName = target.camera.displayTypeName
            s.cameraSymbol = target.camera.symbolName
            s.distanceMeters = target.distance
            s.speedLimit = target.camera.speedLimit
            s.isOverspeed = target.isOverspeed
        } else if let approach = sectionApproach {
            s.mode = .camera
            s.cameraTypeName = CameraType.section.displayName
            s.cameraSymbol = "timer"
            s.distanceMeters = approach.distance
            s.speedLimit = approach.section.speedLimit
        } else if routeProgress != nil {
            s.mode = .navigation
        } else {
            s.mode = .idle
        }
        return s
    }

    // MARK: 資料與設定

    var visibleCameraLimit: Int { 400 }

    /// 地圖上要畫的區間：同一段的兩個方向（-f／-r）路線相同，只畫一次。
    var sectionOverlays: [SpeedSection] {
        var seen = Set<String>()
        return database.sections.filter { seen.insert($0.groupID).inserted }
    }

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

    // MARK: 區間路形貼齊道路

    /// 請 Apple 地圖把區間路形貼齊道路（只處理還沒做過的，近的先做）。地圖移動後由 RootView 呼叫。
    func requestRoadSnapping(near center: GeoPoint?) {
        guard !demoMode, !database.sections.isEmpty else { return }
        pathSnapper.enqueue(database.sections, near: center ?? lastFix?.point)
    }

    private func applySnappedPath(_ path: [GeoPoint], toSection sectionID: String) {
        for i in database.sections.indices where database.sections[i].id == sectionID {
            database.sections[i].path = path
        }
        sectionTracker.updatePath(path, forSectionID: sectionID)
        alertEngine.sections = database.sections
    }

    private func applyDatabase(_ db: CameraDatabase) {
        var db = db
        db.sections = SectionLengthRefiner.applyCached(to: db.sections)
        if !demoMode {
            db.sections = db.sections.map { s in
                guard let snapped = pathSnapper.cachedPath(for: s) else { return s }
                var copy = s
                copy.path = snapped
                return copy
            }
        }
        database = db
        index = SpatialIndex(cameras: db.cameras)
        alertEngine.replaceIndex(index)
        alertEngine.sections = db.sections
        sectionTracker.replaceSections(db.sections)
    }

    private func refineSectionLengths() {
        guard database.sections.contains(where: { $0.lengthEstimated }) else { return }
        Task {
            let refined = await SectionLengthRefiner.refine(database.sections)
            // 只更新長度（等待期間路形可能已經貼齊道路，不要被舊的覆蓋）
            let lengths = Dictionary(refined.map { ($0.id, $0.lengthMeters) }, uniquingKeysWith: { a, _ in a })
            for i in database.sections.indices {
                if let length = lengths[database.sections[i].id] {
                    database.sections[i].lengthMeters = length
                }
            }
            sectionTracker.replaceSections(database.sections)
            alertEngine.sections = database.sections
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
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: settingsKey),
           let s = try? JSONDecoder().decode(AlertSettings.self, from: data) {
            return s
        }
        // 從 v1 遷移：v1 的區間容許值預設是 0，改成新的預設 +10（使用者若自己調過其他值則保留）。
        if let data = defaults.data(forKey: legacySettingsKey),
           var s = try? JSONDecoder().decode(AlertSettings.self, from: data) {
            if s.sectionToleranceKmh == 0 {
                s.sectionToleranceKmh = AlertSettings().sectionToleranceKmh
            }
            if let migrated = try? JSONEncoder().encode(s) {
                defaults.set(migrated, forKey: settingsKey)
            }
            return s
        }
        return AlertSettings()
    }

    // MARK: 個別區間容許值

    /// 區間群組（同一段的兩個方向合併），設定頁用。
    struct SectionGroup: Identifiable, Hashable {
        let id: String
        let name: String
        let speedLimit: Int
        let lengthMeters: Double
        let bidirectional: Bool
    }

    var sectionGroups: [SectionGroup] {
        var seen: [String: SectionGroup] = [:]
        var order: [String] = []
        for s in database.sections {
            if let existing = seen[s.groupID] {
                seen[s.groupID] = SectionGroup(id: existing.id, name: existing.name, speedLimit: existing.speedLimit,
                                               lengthMeters: existing.lengthMeters, bidirectional: true)
            } else {
                seen[s.groupID] = SectionGroup(id: s.groupID, name: s.displayGroupName, speedLimit: s.speedLimit,
                                               lengthMeters: s.lengthMeters, bidirectional: false)
                order.append(s.groupID)
            }
        }
        return order.compactMap { seen[$0] }
    }

    /// 設定（或清除，value = nil）多個區間的個別容許值。
    func setSectionTolerance(_ value: Double?, for groupIDs: Set<String>) {
        var s = settings
        for id in groupIDs {
            if let value {
                s.sectionToleranceOverrides[id] = value
            } else {
                s.sectionToleranceOverrides.removeValue(forKey: id)
            }
        }
        settings = s
    }

    func clearAllSectionOverrides() {
        var s = settings
        s.sectionToleranceOverrides.removeAll()
        settings = s
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
