import MapKit
import SpeedCamCore
import SwiftUI

/// MapFeature 與 MapProxy 都留在 iOS 17 以上的型別，舊系統不儲存它們。
@available(iOS 17, *)
struct ModernMapView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var follow: MapFollowController
    let cameras: [Camera]
    @Binding var selectedCameraID: String?
    let onRegionChange: (MKCoordinateRegion) -> Void
    let onUserInteraction: () -> Void
    @State private var selectedFeature: MapFeature?
    @State private var touchLocation: CGPoint?

    var body: some View {
        MapReader { proxy in
            Map(position: $follow.position, selection: $selectedFeature) {
                content
            }
            .mapStyle(.standard(emphasis: model.mapAppearance.emphasis == .muted ? .muted : .automatic,
                                pointsOfInterest: .all, showsTraffic: true))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .mapFeatureSelectionDisabled { _ in !model.canSelectMapPlace }
            .simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if touchLocation == nil { touchLocation = value.startLocation }
                }
                .onEnded { _ in touchLocation = nil })
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.6, maximumDistance: 12)
                .onEnded { recognized in
                    if recognized, let location = touchLocation { selectPlace(at: location, in: proxy) }
                })
            .onChange(of: selectedFeature) { feature in
                guard let feature else { return }
                selectedFeature = nil
                guard model.canSelectMapPlace else { return }
                model.selectMapPlace(at: feature.coordinate, name: feature.title)
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                onRegionChange(context.region)
            }
            .onMapCameraChange(frequency: .continuous) { _ in
                if follow.position.positionedByUser { onUserInteraction() }
            }
            .onChange(of: follow.position.positionedByUser) { byUser in
                if byUser { onUserInteraction() }
            }
        }
    }

    @MapContentBuilder
    private var content: some MapContent {
        UserAnnotation()
        ForEach(cameras) { camera in
            Annotation(camera.type.displayName, coordinate: camera.coordinate, anchor: .center) {
                Button {
                    model.dismissMapPlace()
                    selectedCameraID = camera.id
                } label: {
                    CameraMarker(camera: camera, highlighted: model.cameraTarget?.camera.id == camera.id)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(camera.displayTypeName)，\(camera.shortAddress)")
            }
            .annotationTitles(.hidden)
        }
        ForEach(model.sectionOverlays) { section in
            MapPolyline(coordinates: section.displayPath.map(\.coordinate))
                .stroke(Color.orange.opacity(0.75),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round, dash: [10, 7]))
        }
        if let mode = model.mapAppearance.comparison {
            routeContent(MapAppearance.demoPolyline, isPreview: mode == .preview)
        } else if let route = model.route {
            routeContent(route.polyline, isPreview: false)
        }
        if let preview = model.preview {
            if preview.stage == .route, let route = preview.route {
                routeContent(route.polyline, isPreview: true)
            }
            Marker(preview.name, coordinate: preview.coordinate).tint(.red)
        } else if let place = model.selectedMapPlace {
            Marker(place.name, coordinate: place.point.coordinate).tint(.red)
        } else if let destination = model.destinationCoordinate {
            Marker(model.destinationName ?? "目的地", systemImage: "flag.checkered", coordinate: destination).tint(.red)
        }
        if model.demoMode, let fix = model.lastFix {
            Annotation("目前位置", coordinate: fix.point.coordinate, anchor: .center) {
                Image(systemName: "location.north.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white, .blue)
            }
            .annotationTitles(.hidden)
        }
    }

    @MapContentBuilder
    private func routeContent(_ polyline: MKPolyline, isPreview: Bool) -> some MapContent {
        let width = RouteLineStyle.lineWidth(isPreview: isPreview)
        if let color = model.mapAppearance.routeLineStyle.casingColor {
            MapPolyline(polyline)
                .stroke(Color(color), style: StrokeStyle(lineWidth: width + 6, lineCap: .round, lineJoin: .round))
        }
        if isPreview {
            MapPolyline(polyline)
                .stroke(.blue.opacity(0.85), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        } else {
            MapPolyline(polyline).stroke(.blue, lineWidth: width)
        }
    }

    private func selectPlace(at location: CGPoint, in proxy: MapProxy) {
        guard model.canSelectMapPlace else { return }
        for camera in cameras {
            if let point = proxy.convert(camera.coordinate, to: .local),
               abs(point.x - location.x) <= 22, abs(point.y - location.y) <= 22 {
                model.dismissMapPlace()
                selectedCameraID = camera.id
                return
            }
        }
        if let coordinate = proxy.convert(location, from: .local) {
            model.selectMapPlace(at: coordinate)
        }
    }
}
