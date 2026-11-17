import os
import SpeedCamCore
import SwiftUI

enum UserCameraGalleryData {
    static let point = GeoPoint(lat: 25.0478, lon: 121.5170)
    static let place = MapPlaceSelection.Place(point: point, name: "台北車站（長名稱選點示例）",
        address: "臺北市中正區北平西路3號（西側出入口旁）", isResolvingAddress: false)
    static let official = Camera(id: "gallery-official", type: .fixed, lat: point.lat, lon: point.lon,
        heading: 0, speedLimit: 50, address: "北平西路與重慶北路一段口（純版面示例，非真實設備）", source: "官方示例")
    static let changed = Camera(id: "gallery-modified", type: .redLightSpeed, lat: point.lat, lon: point.lon,
        heading: 45, speedLimit: 50, address: "忠孝西路一段與館前路口（純版面示例）", source: "官方示例")
    static let hidden = Camera(id: "gallery-hidden", type: .noise, lat: point.lat, lon: point.lon,
        heading: 90, address: "承德路一段（已隱藏示例）", source: "官方示例")
    static let added = Camera(id: "user-00000000-0000-0000-0000-000000000001", type: .fixed,
        lat: point.lat, lon: point.lon, speedLimit: 40, address: "自行補充的長地址照相點（純版面示例）",
        axis: 45, source: "自行新增", positionMethod: "user")

    static var database: CameraDatabase {
        let red = Camera(id: "gallery-red", type: .redLight, lat: point.lat, lon: point.lon,
            address: "北平西路闖紅燈照相點（純版面示例）")
        let section = SpeedSection(id: "gallery-section", name: "示例道路區間",
            start: GeoMath.destination(from: point, bearing: 180, distance: 300),
            end: GeoMath.destination(from: point, bearing: 0, distance: 700),
            lengthMeters: 1_000, speedLimit: 50)
        return CameraDatabase(version: "user-camera-gallery", generatedAt: "", sources: ["記憶體假資料"],
            cameras: [official, changed, hidden, red], sections: [section])
    }

    static func edits() throws -> UserCameraEdits {
        var edits = UserCameraEdits()
        try edits.add(added)
        edits.addedOn[added.id] = "2026-11-17"
        try edits.modify(changed, speedLimit: 40, direction: UserCameraDirection(heading: 270))
        try edits.hide(hidden)
        return edits
    }
}

struct UserCameraGalleryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editor: UserCameraEditorRequest?
    @State private var errorMessage: String?
    private let arguments = ProcessInfo.processInfo.arguments

    private var scenario: String {
        guard let i = arguments.firstIndex(of: "-galleryUserCameras"), i + 1 < arguments.count else { return "" }
        return arguments[i + 1]
    }

    private var bottom: Bool { arguments.contains("-galleryBottom") }
    private var middle: Bool { arguments.contains("-galleryMiddle") }

    var body: some View {
        Group {
            switch scenario {
            case "fixed", "fixed-current", "redLight", "redLight-current", "both":
                let camera = formCamera
                let request = UserCameraEditorRequest(camera: camera, isNew: scenario != "both",
                    canChangeType: true, currentHeading: scenario.hasSuffix("-current") ? 240.61066 : nil)
                UserCameraEditorView(request: request,
                    cameras: model.database.cameras,
                    sections: model.database.sections,
                    initialScrollTarget: bottom ? "camera-notes" : nil) { value in
                    try model.saveUserCamera(value, isNew: request.isNew)
                }
            case "settings", "empty":
                AdaptiveNavigationStack {
                    UserCameraEditsView(initialSection: bottom ? "hidden" : middle ? "modified" : nil)
                }
            case "place", "official", "added", "modified":
                cardPage
            default:
                Text("無效的我的照相點 gallery 情境：\(scenario)")
            }
        }
        .frame(maxWidth: 375)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.3))
        .sheet(item: $editor) { request in
            UserCameraEditorView(request: request,
                cameras: model.database.cameras,
                sections: model.database.sections) { camera in
                try model.saveUserCamera(camera, isNew: request.isNew)
            }
        }
        .alert("示例操作失敗", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var formCamera: Camera {
        if scenario == "both" { return UserCameraGalleryData.added }
        var camera = model.newUserCamera(at: UserCameraGalleryData.place)
        camera.id = "user-00000000-0000-0000-0000-000000000002"
        if scenario.hasPrefix("redLight") {
            camera.type = .redLight
            camera.speedLimit = nil
        }
        return camera
    }

    private var cardPage: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("375 pt 版面示例・非真實照相點").font(.headline)
                    if scenario == "place" {
                        MapPlaceCard(place: UserCameraGalleryData.place, onStart: {}, onAddCamera: {
                            editor = UserCameraEditorRequest(camera: model.newUserCamera(at: UserCameraGalleryData.place),
                                isNew: true, canChangeType: true, currentHeading: nil)
                        }, onClose: {})
                    } else if let camera = detailCamera {
                        CameraDetailCard(camera: camera, isUserAdded: model.isUserAddedCamera(camera.id),
                            isUserModified: model.userCameraEdits.modified[camera.id] != nil,
                            onEdit: {
                                editor = UserCameraEditorRequest(camera: camera, isNew: false,
                                    canChangeType: model.isUserAddedCamera(camera.id), currentHeading: nil)
                            },
                            onHide: { perform { try model.hideCamera(camera) } },
                            onDelete: { perform { try model.deleteUserCamera(camera.id) } },
                            onRestore: { perform { try model.restoreCamera(camera.id) } }, onClose: {})
                    }
                    Color.clear.frame(height: 1).id("card-end")
                }
                .padding(12)
            }
            .task {
                guard bottom else { return }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                reader.scrollTo("card-end", anchor: .bottom)
            }
        }
    }

    private var detailCamera: Camera? {
        let id = scenario == "added" ? UserCameraGalleryData.added.id
            : scenario == "modified" ? UserCameraGalleryData.changed.id : UserCameraGalleryData.official.id
        return model.database.cameras.first { $0.id == id }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
            Logger(subsystem: "tw.speedcammap.app", category: "userCameras")
                .error("示例操作失敗：\(error.localizedDescription, privacy: .public)")
        }
    }
}
