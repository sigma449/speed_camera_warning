import MapKit
import SpeedCamCore
import SwiftUI
import UIKit

/// 主畫面：全螢幕地圖，上方顯示提醒／導航資訊，下方是速度與操作按鈕。
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var position: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var selectedCameraID: String?
    @State private var showSearch = false
    @State private var showSettings = false

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
                } else if let target = model.cameraTarget, target.phase >= .pre {
                    CameraBanner(target: target)
                }
                if let message = model.statusMessage {
                    MessageBanner(text: message) { model.statusMessage = nil }
                }
                Spacer()
                if let camera = selectedCamera {
                    CameraDetailCard(camera: camera) { selectedCameraID = nil }
                }
                BottomBar(showSearch: $showSearch, showSettings: $showSettings)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSearch) {
            SearchView()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
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
            if model.demoMode {
                position = .region(MKCoordinateRegion(center: CameraStore.demoOrigin.coordinate,
                                                      latitudinalMeters: 2_500, longitudinalMeters: 2_500))
            }
        }
    }

    private var selectedCamera: Camera? {
        guard let id = selectedCameraID else { return nil }
        return model.database.cameras.first { $0.id == id }
    }

    private var visibleCameras: [Camera] {
        guard let region = visibleRegion else { return [] }
        return model.cameras(in: region)
    }

    private var map: some View {
        Map(position: $position, selection: $selectedCameraID) {
            UserAnnotation()

            ForEach(visibleCameras) { camera in
                Annotation(camera.type.displayName, coordinate: camera.coordinate, anchor: .center) {
                    CameraMarker(camera: camera,
                                 highlighted: model.cameraTarget?.camera.id == camera.id)
                }
                .annotationTitles(.hidden)
                .tag(camera.id)
            }

            if let route = model.route {
                MapPolyline(route.polyline)
                    .stroke(.blue, lineWidth: 7)
            }

            ForEach(model.database.sections) { section in
                MapPolyline(coordinates: [section.start.coordinate, section.end.coordinate])
                    .stroke(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 5, dash: [8, 6]))
            }

            // 展示模式沒有真實定位，用一台車的圖示代表目前位置。
            if model.demoMode, let fix = model.lastFix {
                Annotation("目前位置", coordinate: fix.point.coordinate, anchor: .center) {
                    Image(systemName: "location.north.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white, .blue)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll, showsTraffic: true))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
        }
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

    private var color: Color {
        switch camera.type {
        case .fixed: return .red
        case .redLight: return .orange
        case .redLightSpeed: return .pink
        case .section: return .purple
        case .tech: return .blue
        case .mobile: return .gray
        }
    }
}
