import os
import SpeedCamCore
import SwiftUI

struct UserCameraEditorRequest: Identifiable {
    let id = UUID()
    let camera: Camera
    let isNew: Bool
    let canChangeType: Bool
    let currentHeading: Double?
}

private enum UserCameraDirectionChoice: Hashable {
    case current, compass(Int), both, unknown, original
}

private struct UserCameraCompassOption: Identifiable {
    let id: Int
    let name: String
}

struct UserCameraEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let request: UserCameraEditorRequest
    let cameras: [Camera]
    let sections: [SpeedSection]
    let onSave: (Camera) throws -> Void
    let initialScrollTarget: String?
    @State private var type: CameraType
    @State private var speedLimit: Int?
    @State private var direction: UserCameraDirectionChoice
    @State private var axis: Double
    @State private var errorMessage: String?

    init(request: UserCameraEditorRequest, cameras: [Camera], sections: [SpeedSection],
         initialScrollTarget: String? = nil,
         onSave: @escaping (Camera) throws -> Void) {
        self.request = request
        self.cameras = cameras
        self.sections = sections
        self.onSave = onSave
        self.initialScrollTarget = initialScrollTarget
        _type = State(initialValue: request.camera.type)
        _speedLimit = State(initialValue: request.camera.speedLimit)
        _axis = State(initialValue: request.camera.axis ?? 0)
        let choice: UserCameraDirectionChoice
        if request.isNew {
            choice = request.currentHeading == nil ? .unknown : .current
        } else if let heading = request.camera.heading {
            if let compass = (0..<8).first(where: { Double($0 * 45) == heading }) {
                choice = .compass(compass)
            } else {
                choice = .original
            }
        } else {
            choice = request.camera.axis == nil ? .unknown : .both
        }
        _direction = State(initialValue: choice)
    }

    private var canEditSpeed: Bool {
        request.canChangeType ? type == .fixed : request.camera.enforcesSpeed
    }

    private var selectedDirection: UserCameraDirection {
        switch direction {
        case .current: return UserCameraDirection(heading: request.currentHeading)
        case let .compass(index): return UserCameraDirection(heading: Double(index * 45))
        case .both: return UserCameraDirection(axis: axis)
        case .unknown: return UserCameraDirection()
        case .original: return UserCameraDirection(camera: request.camera)
        }
    }

    private var draft: Camera {
        var camera = request.camera
        if request.canChangeType {
            camera.type = type
            camera.speedLimit = type == .fixed ? speedLimit : nil
        } else if canEditSpeed {
            camera.speedLimit = speedLimit
        }
        selectedDirection.apply(to: &camera)
        return camera
    }

    private var nearbyCamera: Camera? {
        cameras.filter { $0.id != request.camera.id && $0.type == type }
            .map { ($0, GeoMath.distance($0.point, request.camera.point)) }
            .filter { $0.1 <= 50 }
            .min { $0.1 < $1.1 }?.0
    }

    private var coveringSection: SpeedSection? {
        let engine = CameraAlertEngine(index: SpatialIndex(cameras: []))
        engine.sections = sections
        return engine.coveringSection(for: request.camera)
    }

    var body: some View {
        AdaptiveNavigationStack {
            ScrollViewReader { reader in
                Form {
                    if request.canChangeType {
                        Section("類型") {
                            Picker("類型", selection: $type) {
                                Text(CameraType.fixed.displayName).tag(CameraType.fixed)
                                Text(CameraType.redLight.displayName).tag(CameraType.redLight)
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    if canEditSpeed {
                        Section("速限") {
                            Picker("速限", selection: $speedLimit) {
                                if !request.canChangeType && request.camera.speedLimit == nil {
                                    Text("未提供（只提醒）").tag(Int?.none)
                                }
                                if let original = request.camera.speedLimit,
                                   !UserCameraEdits.speedLimits.contains(original) {
                                    Text("\(original) km/h（原值）").tag(Optional(original))
                                }
                                ForEach(UserCameraEdits.speedLimits, id: \.self) { limit in
                                    Text("\(limit) km/h").tag(Optional(limit))
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    Section {
                        Picker("取締方向", selection: $direction) {
                            if request.currentHeading != nil {
                                Text("和我現在的行車方向相同").tag(UserCameraDirectionChoice.current)
                            }
                            ForEach(compassOptions) { option in
                                Text(option.name).tag(UserCameraDirectionChoice.compass(option.id))
                            }
                            Text("雙向").tag(UserCameraDirectionChoice.both)
                            Text("不確定").tag(UserCameraDirectionChoice.unknown)
                            if request.camera.heading != nil && !request.isNew {
                                Text("原方向：\(UserCameraDirection(camera: request.camera).description)")
                                    .tag(UserCameraDirectionChoice.original)
                            }
                        }
                        .pickerStyle(.menu)
                        if direction == .both {
                            Picker("道路軸向", selection: $axis) {
                                Text("南北向").tag(0.0)
                                Text("東北–西南").tag(45.0)
                                Text("東西向").tag(90.0)
                                Text("西北–東南").tag(135.0)
                                if let original = request.camera.axis, ![0.0, 45, 90, 135].contains(original) {
                                    Text("原軸向：\(UserCameraDirection(camera: request.camera).description)").tag(original)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    } header: {
                        Text("取締方向")
                    } footer: {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(UserCameraEdits.unknownDirectionExplanation)
                            if direction == .current, let heading = request.currentHeading {
                                Text("儲存實際行向：\(UserCameraDirection(heading: heading).description)。")
                            }
                            if !request.canChangeType && !canEditSpeed {
                                Text("此類型沒有測速門檻，只修改方向，不新增速限或超速嗶聲。")
                            }
                            Text(request.camera.address)
                            if let nearby = nearbyCamera {
                                Text("50 公尺內已有同類型照相點：\(nearby.shortAddress)。仍可儲存。")
                                    .foregroundStyle(.primary)
                            }
                            if let section = coveringSection {
                                Text("位於區間測速覆蓋範圍：\(section.shortName)。一般照相點不因此消音；區間照相點改由區間提醒。")
                                    .foregroundStyle(.primary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .id("camera-notes")
                    }
                }
                .task {
                    guard let target = initialScrollTarget else { return }
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    guard !Task.isCancelled else { return }
                    reader.scrollTo(target, anchor: .bottom)
                }
            }
            .navigationTitle(request.isNew ? "新增照相點" : "修改照相點")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { save() }.font(.headline)
                }
            }
            .onChange(of: type) { value in
                guard request.canChangeType else { return }
                speedLimit = value == .fixed ? (request.camera.speedLimit ?? 50) : nil
            }
            .alert("無法儲存照相點", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var compassOptions: [UserCameraCompassOption] {
        ["往北", "往東北", "往東", "往東南", "往南", "往西南", "往西", "往西北"]
            .enumerated().map { UserCameraCompassOption(id: $0.offset, name: $0.element) }
    }

    private func save() {
        do {
            try onSave(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            Logger(subsystem: "tw.speedcammap.app", category: "userCameras")
                .error("表單儲存失敗：\(error.localizedDescription, privacy: .public)")
        }
    }
}
