import MapKit
import os
import SpeedCamCore
import SwiftUI
import UIKit

private let uiLog = Logger(subsystem: "tw.speedcammap.app", category: "ui")

/// 主畫面：全螢幕地圖，上方顯示提醒／導航資訊，下方是速度與操作按鈕。
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var follow = MapFollowController()
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var selectedCameraID: String?
    @State private var showSearch = false
    @State private var showSettings = false
    /// 導航預覽的倒數（秒）；nil 表示沒有倒數。
    @State private var previewCountdown: Int?
    /// 預覽時使用者拖動了地圖：停止自動前進，等使用者按。
    @State private var previewPaused = false
    @State private var reportedComparisonReady = false

    var body: some View {
        ZStack {
            map
                .ignoresSafeArea()

            VStack(spacing: 8) {
                if let progress = model.routeProgress {
                    NavigationBanner(progress: progress, destination: model.destinationName)
                }
                if let section = model.sectionStatus {
                    SectionBanner(status: section, currentSpeed: model.currentSpeedKmh)
                } else if let target = model.bannerTarget {
                    CameraBanner(target: target)
                }
                if let message = model.statusMessage {
                    MessageBanner(text: message) { model.statusMessage = nil }
                }
                Spacer()
                if let preview = model.preview {
                    NavigationPreviewCard(preview: preview, vehicleMode: model.vehicleMode,
                                          countdown: previewCountdown,
                                          onShowRoute: { model.showRoutePreview() },
                                          onStart: { startPreviewedNavigation() },
                                          onCancel: { cancelPreview() })
                } else {
                    if let place = model.selectedMapPlace {
                        MapPlaceCard(place: place, onStart: { model.previewSelectedMapPlace() },
                                     onClose: { model.dismissMapPlace() })
                    } else if let camera = selectedCamera {
                        CameraDetailCard(camera: camera) { selectedCameraID = nil }
                    }
                    if model.selectedMapPlace == nil && model.mapAppearance.comparison == nil { recenterRow }
                }
                if model.selectedMapPlace == nil && model.mapAppearance.comparison == nil {
                    BottomBar(showSearch: $showSearch, showSettings: $showSettings)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSearch) {
            SearchView()
                .environmentObject(model)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(model)
        }
        .alert("需要定位權限", isPresented: Binding(get: { model.authorizationDenied },
                                              set: { if !$0 { model.acknowledgeAuthorizationAlert() } })) {
            Button("前往設定") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("請到「設定 → 隱私權與安全性 → 定位服務」允許「測速地圖」使用你的位置。")
        }
        .onAppear {
            uiLog.notice("RootView appeared; search=\(model.initialSearchQuery ?? "-", privacy: .public) region=\(model.initialMapRegion != nil, privacy: .public)")
            if model.demoMode {
                follow.setInitial(region: MKCoordinateRegion(center: CameraStore.demoOrigin.coordinate,
                                                             latitudinalMeters: 2_500, longitudinalMeters: 2_500))
            }
        }
        .task {
            // 剛啟動時畫面還沒準備好，太早開 sheet 或改地圖範圍會被系統忽略，稍等一下再做（CI 截圖用的啟動參數）。
            guard model.initialSearchQuery != nil || model.initialMapRegion != nil
                    || model.initialPreviewTarget != nil || model.initialShowSettings
                    || model.initialSelectedPlace != nil || model.searchTypingTest != nil
                    || model.mapAppearance.comparison != nil else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            if let mode = model.mapAppearance.comparison {
                follow.preview(cameraCenter: MapAppearance.demoCameraCenter,
                               distance: mode == .preview ? 5_000 : 3_800,
                               heading: 180, pitch: mode == .preview ? 0 : 55)
                reportComparisonReady(mode: mode)
                return
            }
            if model.initialShowSettings {
                showSettings = true
            }
            if let target = model.initialPreviewTarget {
                model.beginPreview(to: MapItems.item(name: target.name, coordinate: target.coordinate), subtitle: "")
                uiLog.notice("started navigation preview")
            } else if let place = model.initialSelectedPlace {
                model.selectMapPlace(at: place.coordinate, name: place.name)
                follow.show(region: MKCoordinateRegion(center: place.coordinate,
                                                        latitudinalMeters: 900, longitudinalMeters: 900))
            }
            if let region = model.initialMapRegion {
                follow.show(region: region)
                uiLog.notice("applied initial map region")
            }
            if model.initialSearchQuery != nil || model.searchTypingTest != nil {
                showSearch = true
                uiLog.notice("opened search sheet")
            }
        }
        .onChange(of: model.lastFix) { fix in
            if let fix { follow.handle(fix) }
        }
        .onChange(of: model.preview?.key) { _ in
            if model.preview != nil { selectedCameraID = nil }
            movePreviewCamera()
        }
        .onChange(of: selectedCameraID) { id in
            if id != nil { model.dismissMapPlace() }
        }
        .onChange(of: model.selectedMapPlace?.id) { id in
            if id != nil {
                selectedCameraID = nil
                follow.beginPlaceSelection()
                let legacy: Bool
                if #available(iOS 17, *), !LegacySupport.forced { legacy = false } else { legacy = true }
                uiLog.notice("place selection ready legacy=\(legacy, privacy: .public)")
            } else if model.preview == nil {
                follow.endPlaceSelection()
            }
        }
        .task(id: model.preview?.key) {
            await runPreviewTimer()
        }
    }

    // MARK: 導航預覽

    /// 地點階段：鏡頭移到目的地；路線階段：整條路線放進畫面（下方留位置給卡片）。
    private func movePreviewCamera() {
        guard let p = model.preview else {
            previewCountdown = nil
            follow.endPreview()
            return
        }
        switch p.stage {
        case .place:
            follow.preview(region: MKCoordinateRegion(center: p.coordinate, latitudinalMeters: 900, longitudinalMeters: 900))
        case .route:
            guard let route = p.route else { return }
            let r = route.polyline.boundingMapRect
            let padded = r.insetBy(dx: -r.width * 0.25 - 600, dy: -r.height * 0.2 - 600)
            // 卡片蓋住畫面下方約三分之一，往下多留空間
            let rect = MKMapRect(x: padded.minX, y: padded.minY, width: padded.width, height: padded.height + r.height * 0.7 + 800)
            follow.preview(rect: rect)
        }
    }

    private func reportComparisonReady(mode: RouteComparisonMode) {
        guard !reportedComparisonReady else { return }
        reportedComparisonReady = true
        let appearance = model.mapAppearance
        let legacy: Bool
        if #available(iOS 17, *), !LegacySupport.forced { legacy = false } else { legacy = true }
        uiLog.notice("map comparison ready mode=\(mode.rawValue, privacy: .public) style=\(appearance.routeLineStyle.rawValue, privacy: .public) emphasis=\(appearance.emphasis.rawValue, privacy: .public) legacy=\(legacy, privacy: .public) source=demo")
    }

    /// 地點階段停 3 秒後看路線；路線階段倒數 10 秒後開始導航。使用者拖動地圖就停止自動前進。
    private func runPreviewTimer() async {
        previewPaused = false
        previewCountdown = nil
        guard let p = model.preview else { return }
        switch p.stage {
        case .place:
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, !previewPaused else { return }
            model.showRoutePreview()
        case .route:
            for remaining in stride(from: 10, through: 1, by: -1) {
                previewCountdown = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                if previewPaused {
                    previewCountdown = nil
                    return
                }
            }
            startPreviewedNavigation()
        }
    }

    private func startPreviewedNavigation() {
        previewCountdown = nil
        model.confirmPreview()
    }

    private func cancelPreview() {
        previewCountdown = nil
        model.cancelPreview()
    }

    /// 右下角的「回到目前位置」按鈕。跟隨中再按一次會切換顯示方式（行進方向朝上 → 北方朝上 → 3D）。
    private var recenterRow: some View {
        HStack(spacing: 8) {
            Spacer()
            if let toast = follow.toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
            Button {
                follow.buttonTapped()
            } label: {
                Image(systemName: follow.buttonSymbol)
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(.regularMaterial, in: Circle())
                    .foregroundStyle(follow.isFollowing ? Color.blue : Color.primary)
                    .shadow(radius: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(follow.buttonAccessibilityLabel)
        }
    }

    private var selectedCamera: Camera? {
        guard let id = selectedCameraID else { return nil }
        return model.database.cameras.first { $0.id == id }
    }

    private var visibleCameras: [Camera] {
        // 導航預覽時暫時不畫照相點，避免擋住目的地和路線（預覽結束就恢復）
        if model.preview != nil || model.mapAppearance.comparison != nil { return [] }
        if let region = visibleRegion {
            return model.cameras(in: region)
        }
        // 還沒收到地圖範圍時（剛開啟、尚未拖動），先顯示目前位置周圍 3 公里內的照相點。
        if let fix = model.lastFix {
            return model.cameras(in: MKCoordinateRegion(center: fix.point.coordinate,
                                                        latitudinalMeters: 3_000, longitudinalMeters: 3_000))
        }
        return []
    }

    @ViewBuilder
    private var map: some View {
        if #available(iOS 17, *), !LegacySupport.forced {
            modernMap
        } else {
            legacyMap
        }
    }

    /// iOS 15、16 的地圖，內容和 `modernMap` 一樣。
    private var legacyMap: some View {
        LegacyMapView(cameras: visibleCameras,
                      highlightedCameraID: model.cameraTarget?.camera.id,
                      selectedCameraID: $selectedCameraID,
                      routeLine: legacyRouteLine,
                      appearance: model.mapAppearance,
                      canSelectPlace: model.canSelectMapPlace,
                      pin: legacyPin,
                      sections: model.sectionOverlays,
                      demoPosition: model.demoMode ? model.lastFix?.point.coordinate : nil,
                      request: follow.legacyRequest,
                      onSelectPlace: { coordinate, name in
                          model.selectMapPlace(at: coordinate, name: name)
                      },
                      onRegionChange: { region in
                          visibleRegion = region
                          model.requestRoadSnapping(near: GeoPoint(lat: region.center.latitude,
                                                                   lon: region.center.longitude))
                      },
                      onUserInteraction: {
                          follow.userMovedMap()
                          if model.preview != nil { previewPaused = true }
                      })
    }

    private var legacyRouteLine: LegacyMapView.RouteLine? {
        if let mode = model.mapAppearance.comparison {
            return LegacyMapView.RouteLine(polyline: MapAppearance.demoPolyline, isPreview: mode == .preview)
        }
        if let p = model.preview {
            guard p.stage == .route, let route = p.route else { return nil }
            return LegacyMapView.RouteLine(polyline: route.polyline, isPreview: true)
        }
        guard let route = model.route else { return nil }
        return LegacyMapView.RouteLine(polyline: route.polyline, isPreview: false)
    }

    private var legacyPin: LegacyMapView.Pin? {
        if let p = model.preview {
            return LegacyMapView.Pin(title: p.name, latitude: p.coordinate.latitude,
                                     longitude: p.coordinate.longitude, usesFlag: false)
        }
        if let place = model.selectedMapPlace {
            return LegacyMapView.Pin(title: place.name, latitude: place.point.lat,
                                     longitude: place.point.lon, usesFlag: false)
        }
        guard let destination = model.destinationCoordinate else { return nil }
        return LegacyMapView.Pin(title: model.destinationName ?? "目的地", latitude: destination.latitude,
                                 longitude: destination.longitude, usesFlag: true)
    }

    @available(iOS 17, *)
    private var modernMap: some View {
        ModernMapView(model: model, follow: follow, cameras: visibleCameras, selectedCameraID: $selectedCameraID,
                      onRegionChange: { region in
                          visibleRegion = region
                          model.requestRoadSnapping(near: GeoPoint(lat: region.center.latitude, lon: region.center.longitude))
                      },
                      onUserInteraction: {
                          follow.userMovedMap()
                          if model.preview != nil { previewPaused = true }
                      })
    }
}

// MARK: - 地圖標記

struct CameraMarker: View {
    let camera: Camera
    var highlighted = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: highlighted ? 38 : 28, height: highlighted ? 38 : 28)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(radius: 2)
            Image(systemName: camera.symbolName)
                .font(.system(size: highlighted ? 18 : 13, weight: .bold))
                .foregroundStyle(.white)
        }
        .overlay {
            if let heading = camera.heading {
                // 小三角形指出取締方向（以標記中心旋轉）
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .offset(y: highlighted ? -25 : -20)
                    .rotationEffect(.degrees(heading))
            }
        }
    }

    private var color: Color { Self.color(for: camera.type) }

    static func color(for type: CameraType) -> Color {
        switch type {
        case .fixed: return .red
        case .redLight: return .orange
        case .redLightSpeed: return .pink
        case .section: return .purple
        case .tech: return .blue
        case .mobile: return .gray
        }
    }
}
