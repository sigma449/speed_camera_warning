import MapKit
import SpeedCamCore
import SwiftUI
import UIKit

/// iOS 15、16 用的地圖（MKMapView）。SwiftUI 的 Map 要 iOS 17 才能畫路線和自訂標記。
/// 畫的內容和 RootView 裡 iOS 17 以上的地圖一樣：照相點、路線、目的地、區間。
struct LegacyMapView: UIViewRepresentable {
    struct RouteLine {
        let polyline: MKPolyline
        let isPreview: Bool
    }

    struct Pin: Equatable {
        let title: String
        let latitude: Double
        let longitude: Double
        /// 導航中的目的地用旗子，預覽的地點用一般大頭針。
        let usesFlag: Bool
    }

    let cameras: [Camera]
    let highlightedCameraID: String?
    @Binding var selectedCameraID: String?
    let routeLine: RouteLine?
    let pin: Pin?
    let sections: [SpeedSection]
    /// 展示模式沒有真實定位，用一台車的圖示代表目前位置。
    let demoPosition: CLLocationCoordinate2D?
    let request: LegacyMapRequest?
    let onRegionChange: (MKCoordinateRegion) -> Void
    let onUserInteraction: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.showsTraffic = true
        map.pointOfInterestFilter = .excludingAll
        // 目前位置的圓點跟著 tintColor，不設定的話會變成 App 的強調色（黃色），和照相點的黃色混淆
        map.tintColor = .systemBlue
        context.coordinator.attachGestures(to: map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(map)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: LegacyMapView

        private var cameraAnnotations: [String: CameraAnnotation] = [:]
        private var highlightedID: String?
        private var routeOverlay: MKPolyline?
        private var routeIsPreview = false
        private var sectionOverlays: [String: (path: [GeoPoint], polyline: MKPolyline)] = [:]
        private var pinAnnotation: PinAnnotation?
        private var demoAnnotation: DemoVehicleAnnotation?
        private var lastRequestID: Int?

        init(parent: LegacyMapView) {
            self.parent = parent
        }

        func attachGestures(to map: MKMapView) {
            let recognizers: [UIGestureRecognizer] = [
                UIPanGestureRecognizer(target: self, action: #selector(userGesture(_:))),
                UIPinchGestureRecognizer(target: self, action: #selector(userGesture(_:))),
                UIRotationGestureRecognizer(target: self, action: #selector(userGesture(_:))),
            ]
            for recognizer in recognizers {
                recognizer.delegate = self
                recognizer.cancelsTouchesInView = false
                map.addGestureRecognizer(recognizer)
            }
        }

        @objc private func userGesture(_ recognizer: UIGestureRecognizer) {
            if recognizer.state == .began || recognizer.state == .changed {
                parent.onUserInteraction()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: 同步內容

        func sync(_ map: MKMapView) {
            syncCameras(map)
            syncRoute(map)
            syncSections(map)
            syncPin(map)
            syncDemo(map)
            applyRequest(map)
        }

        private func syncCameras(_ map: MKMapView) {
            var wanted: [String: Camera] = [:]
            for camera in parent.cameras { wanted[camera.id] = camera }

            var removed: [MKAnnotation] = []
            for (id, annotation) in cameraAnnotations where wanted[id] == nil {
                removed.append(annotation)
                cameraAnnotations[id] = nil
            }
            if !removed.isEmpty { map.removeAnnotations(removed) }

            let oldHighlight = highlightedID
            highlightedID = parent.highlightedCameraID

            var added: [MKAnnotation] = []
            for (id, camera) in wanted where cameraAnnotations[id] == nil {
                let annotation = CameraAnnotation(camera: camera)
                cameraAnnotations[id] = annotation
                added.append(annotation)
            }
            if !added.isEmpty { map.addAnnotations(added) }

            // 接近中的照相點要放大
            guard oldHighlight != highlightedID else { return }
            for id in [oldHighlight, highlightedID].compactMap({ $0 }) {
                guard let annotation = cameraAnnotations[id],
                      let view = map.view(for: annotation) else { continue }
                view.image = CameraMarkerImage.make(camera: annotation.camera, highlighted: id == highlightedID)
            }
        }

        private func syncRoute(_ map: MKMapView) {
            let line = parent.routeLine
            routeIsPreview = line?.isPreview ?? false
            guard line?.polyline !== routeOverlay else { return }
            if let old = routeOverlay { map.removeOverlay(old) }
            routeOverlay = line?.polyline
            if let new = routeOverlay { map.addOverlay(new, level: .aboveRoads) }
        }

        private func syncSections(_ map: MKMapView) {
            var wanted = Set<String>()
            for section in parent.sections {
                wanted.insert(section.groupID)
                let path = section.displayPath
                if let existing = sectionOverlays[section.groupID], existing.path == path { continue }
                if let existing = sectionOverlays[section.groupID] { map.removeOverlay(existing.polyline) }
                let coordinates = path.map(\.coordinate)
                let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
                sectionOverlays[section.groupID] = (path, polyline)
                // 放在最底層，路線才會蓋在區間上面
                map.insertOverlay(polyline, at: 0, level: .aboveRoads)
            }
            for (id, overlay) in sectionOverlays where !wanted.contains(id) {
                map.removeOverlay(overlay.polyline)
                sectionOverlays[id] = nil
            }
        }

        private func syncPin(_ map: MKMapView) {
            guard parent.pin != pinAnnotation?.pin else { return }
            if let old = pinAnnotation { map.removeAnnotation(old) }
            pinAnnotation = parent.pin.map(PinAnnotation.init(pin:))
            if let new = pinAnnotation { map.addAnnotation(new) }
        }

        private func syncDemo(_ map: MKMapView) {
            guard let position = parent.demoPosition else { return }
            if let demoAnnotation {
                demoAnnotation.coordinate = position
            } else {
                let annotation = DemoVehicleAnnotation(coordinate: position)
                demoAnnotation = annotation
                map.addAnnotation(annotation)
            }
        }

        // MARK: 鏡頭

        private func applyRequest(_ map: MKMapView) {
            guard let request = parent.request, request.id != lastRequestID else { return }
            // 還沒排版就設定範圍會算錯，等下一輪再做
            if map.bounds.isEmpty {
                DispatchQueue.main.async { [weak self, weak map] in
                    if let self, let map { self.applyRequest(map) }
                }
                return
            }
            lastRequestID = request.id
            switch request.target {
            case let .userLocation(followsHeading):
                map.setUserTrackingMode(followsHeading ? .followWithHeading : .follow, animated: request.animated)
            case let .region(region):
                map.userTrackingMode = .none
                map.setRegion(region, animated: request.animated)
            case let .rect(rect):
                map.userTrackingMode = .none
                map.setVisibleMapRect(rect, animated: request.animated)
            case let .camera(center, distance, heading, pitch):
                map.userTrackingMode = .none
                let camera = MKMapCamera(lookingAtCenter: center, fromDistance: distance,
                                         pitch: CGFloat(pitch), heading: heading)
                if request.animated {
                    UIView.animate(withDuration: 0.9, delay: 0,
                                   options: [.curveLinear, .beginFromCurrentState, .allowUserInteraction]) {
                        map.camera = camera
                    }
                } else {
                    map.camera = camera
                }
            }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            DispatchQueue.main.async { [weak self] in
                self?.parent.onRegionChange(region)
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? CameraAnnotation else { return }
            // 馬上取消選取，再點同一個照相點才會有反應
            mapView.deselectAnnotation(annotation, animated: false)
            parent.selectedCameraID = annotation.camera.id
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case let camera as CameraAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "camera")
                    ?? MKAnnotationView(annotation: camera, reuseIdentifier: "camera")
                view.annotation = camera
                view.image = CameraMarkerImage.make(camera: camera.camera, highlighted: camera.camera.id == highlightedID)
                view.displayPriority = .required
                view.canShowCallout = false
                return view
            case let pin as PinAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "pin") as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: pin, reuseIdentifier: "pin")
                view.annotation = pin
                view.markerTintColor = .systemRed
                view.glyphImage = pin.pin.usesFlag
                    ? (UIImage(systemName: "flag.checkered") ?? UIImage(systemName: "flag.fill"))
                    : nil
                view.displayPriority = .required
                view.titleVisibility = .visible
                return view
            case is DemoVehicleAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "demo")
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "demo")
                view.annotation = annotation
                let configuration = UIImage.SymbolConfiguration(pointSize: 34)
                    .applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemBlue]))
                if let symbol = UIImage(systemName: "location.north.circle.fill", withConfiguration: configuration) {
                    // MKAnnotationView 直接用符號圖的黑色底圖，要先畫成點陣圖才有顏色
                    view.image = UIGraphicsImageRenderer(size: symbol.size).image { _ in symbol.draw(at: .zero) }
                }
                view.displayPriority = .required
                return view
            default:
                return nil   // 目前位置用系統的藍點
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.lineCap = .round
            renderer.lineJoin = .round
            if polyline === routeOverlay {
                renderer.strokeColor = routeIsPreview ? UIColor.systemBlue.withAlphaComponent(0.85) : .systemBlue
                renderer.lineWidth = routeIsPreview ? 8 : 7
            } else {
                renderer.strokeColor = UIColor.systemOrange.withAlphaComponent(0.75)
                renderer.lineWidth = 6
                renderer.lineDashPattern = [10, 7]
            }
            return renderer
        }
    }
}

// MARK: - 地圖標記

private final class CameraAnnotation: NSObject, MKAnnotation {
    let camera: Camera
    let coordinate: CLLocationCoordinate2D
    let title: String?

    init(camera: Camera) {
        self.camera = camera
        coordinate = camera.coordinate
        title = camera.type.displayName
    }
}

private final class PinAnnotation: NSObject, MKAnnotation {
    let pin: LegacyMapView.Pin
    let coordinate: CLLocationCoordinate2D
    let title: String?

    init(pin: LegacyMapView.Pin) {
        self.pin = pin
        coordinate = CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
        title = pin.title
    }
}

private final class DemoVehicleAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

/// 把照相點標記畫成圖片（外觀同 `CameraMarker`）。地圖上可能有幾百個，所以不用 SwiftUI 的畫面，也會重複使用畫好的圖。
private enum CameraMarkerImage {
    private static var cache: [String: UIImage] = [:]

    static func make(camera: Camera, highlighted: Bool) -> UIImage {
        let heading = camera.heading.map { Int($0.rounded()) }
        let key = "\(camera.type.rawValue)|\(heading ?? -1)|\(highlighted)"
        if let cached = cache[key] { return cached }

        let diameter: CGFloat = highlighted ? 38 : 28
        let arrowOffset: CGFloat = highlighted ? 25 : 20
        let side = (arrowOffset + 8) * 2
        let center = CGPoint(x: side / 2, y: side / 2)
        let fill = UIColor(CameraMarker.color(for: camera.type))
        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: highlighted ? 18 : 13, weight: .bold)
        let symbol = UIImage(systemName: camera.symbolName, withConfiguration: symbolConfiguration)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let arrow = UIImage(systemName: "arrowtriangle.up.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)

        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let cg = context.cgContext
            let circle = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)

            cg.saveGState()
            cg.setShadow(offset: .zero, blur: 2, color: UIColor.black.withAlphaComponent(0.4).cgColor)
            fill.setFill()
            cg.fillEllipse(in: circle)
            cg.restoreGState()

            UIColor.white.setStroke()
            cg.setLineWidth(2)
            cg.strokeEllipse(in: circle)

            if let symbol {
                symbol.draw(at: CGPoint(x: center.x - symbol.size.width / 2, y: center.y - symbol.size.height / 2))
            }
            // 小三角形指出取締方向（以標記中心旋轉）
            if let heading = camera.heading, let arrow {
                cg.translateBy(x: center.x, y: center.y)
                cg.rotate(by: CGFloat(heading) * .pi / 180)
                arrow.draw(at: CGPoint(x: -arrow.size.width / 2, y: -arrowOffset - arrow.size.height / 2))
            }
        }
        cache[key] = image
        return image
    }
}
