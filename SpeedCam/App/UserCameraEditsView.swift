import os
import SpeedCamCore
import SwiftUI
import UIKit

private struct UserCameraShare: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct UserCameraEditsView: View {
    @EnvironmentObject private var model: AppModel
    var initialSection: String? = nil
    @State private var editor: UserCameraEditorRequest?
    @State private var deleting: Camera?
    @State private var share: UserCameraShare?
    @State private var exportDirectory: URL?
    @State private var errorMessage: String?

    var body: some View {
        ScrollViewReader { reader in
            Form {
                if let warning = model.userCameraEditsWarning {
                    Section { Text(warning).font(.footnote) }
                }
                if model.userCameraEdits.isEmpty {
                    Section {
                        Text("在地圖長按位置，或點選地點，再按「新增照相點」。資料只存在這支手機，不會上傳。")
                    }
                } else {
                    Section("自行新增（\(model.userCameraEdits.added.count)）") {
                        ForEach(model.userCameraEdits.added) { camera in
                            VStack(alignment: .leading, spacing: 8) {
                                cameraLabel(camera)
                                HStack(spacing: 20) {
                                    Button("修改") {
                                        editor = UserCameraEditorRequest(camera: camera, isNew: false, canChangeType: true,
                                            currentHeading: model.suggestedCameraHeading(at: camera.point))
                                    }
                                    .frame(minHeight: 44)
                                    Button("刪除", role: .destructive) { deleting = camera }
                                        .frame(minHeight: 44)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        if model.userCameraEdits.added.isEmpty { Text("尚無自行新增的照相點").foregroundStyle(.secondary) }
                    }
                    .id("added")
                    Section("已修改（\(model.userCameraEdits.modified.count)）") {
                        ForEach(model.userCameraEdits.modified.keys.sorted(), id: \.self) { id in
                            VStack(alignment: .leading, spacing: 8) {
                                originalLabel(id)
                                if let original = model.originalCamera(id),
                                   let changed = model.userCameraEdits.modified[id]?.apply(to: original) {
                                    Text("目前：\(summary(changed))").font(.footnote)
                                }
                                Button("還原成原始資料") { perform { try model.restoreCamera(id) } }
                                    .frame(minHeight: 44)
                                    .buttonStyle(.borderless)
                            }
                        }
                        if model.userCameraEdits.modified.isEmpty { Text("尚無自行修改的照相點").foregroundStyle(.secondary) }
                    }
                    .id("modified")
                    Section("已隱藏（\(model.userCameraEdits.hidden.count)）") {
                        ForEach(model.userCameraEdits.hidden, id: \.self) { id in
                            VStack(alignment: .leading, spacing: 8) {
                                originalLabel(id)
                                Button("復原顯示與提醒") { perform { try model.unhideCamera(id) } }
                                    .frame(minHeight: 44)
                                    .buttonStyle(.borderless)
                            }
                        }
                        if model.userCameraEdits.hidden.isEmpty { Text("尚無隱藏的照相點").foregroundStyle(.secondary) }
                    }
                    .id("hidden")
                }
                Section {
                    Button("匯出") { export() }
                        .frame(minHeight: 44)
                        .disabled(model.userCameraEdits.isEmpty)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("分享 cameras_extra_user.csv 與 camera_edits.json，只含照相點，不含行車紀錄或帳號資訊。")
                        if model.userCameraEdits.added.contains(where: {
                            $0.axis != nil && $0.axis != 0 && $0.axis != 90
                        }) {
                            Text(UserCameraExport.diagonalAxisNote)
                        }
                    }
                }
            }
            .task {
                guard let target = initialSection else { return }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                reader.scrollTo(target, anchor: .top)
            }
        }
        .navigationTitle("我的照相點")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editor) { request in
            UserCameraEditorView(request: request,
                cameras: model.database.cameras,
                sections: model.database.sections) { camera in
                try model.saveUserCamera(camera, isNew: false)
            }
        }
        .sheet(item: $share, onDismiss: cleanupExport) { item in
            UserCameraShareSheet(urls: item.urls) { message in
                errorMessage = message
                Logger(subsystem: "tw.speedcammap.app", category: "userCameras")
                    .error("分享失敗：\(message, privacy: .public)")
            }
        }
        .confirmationDialog("刪除這個自行新增的照相點？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible,
            presenting: deleting) { camera in
            Button("刪除照相點", role: .destructive) {
                perform { try model.deleteUserCamera(camera.id) }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { _ in
            Text("刪除後無法復原。")
        }
        .alert("照相點操作失敗", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func summary(_ camera: Camera) -> String {
        let limit = camera.enforcesSpeed ? camera.speedLimit.map { "速限 \($0)・" } ?? "" : ""
        return "\(limit)\(UserCameraDirection(camera: camera).description)"
    }

    private func cameraLabel(_ camera: Camera) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(camera.shortAddress).fixedSize(horizontal: false, vertical: true)
            Text("\(camera.type.displayName)・\(summary(camera))").font(.footnote)
        }
    }

    @ViewBuilder
    private func originalLabel(_ id: String) -> some View {
        if let original = model.originalCamera(id) {
            cameraLabel(original)
        } else {
            Text(id).font(.footnote)
        }
        if !model.originalCameras.contains(where: { $0.id == id }) {
            Text("目前資料無此點，設定保留但不生效").font(.footnote)
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
            Logger(subsystem: "tw.speedcammap.app", category: "userCameras")
                .error("操作失敗：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func export() {
        perform {
            cleanupExport()
            guard exportDirectory == nil else {
                throw UserCameraEdits.EditError.invalid("請先清除前一次的匯出暫存檔")
            }
            let exported = try UserCameraExport(edits: model.userCameraEdits, originals: model.originalCameras)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("UserCameraExport-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            exportDirectory = directory
            do {
                let csv = directory.appendingPathComponent("cameras_extra_user.csv")
                let json = directory.appendingPathComponent("camera_edits.json")
                try Data(exported.csv.utf8).write(to: csv, options: .atomic)
                try exported.json.write(to: json, options: .atomic)
                share = UserCameraShare(urls: [csv, json])
            } catch {
                cleanupExport()
                throw error
            }
        }
    }

    private func cleanupExport() {
        guard let directory = exportDirectory else { return }
        do {
            try FileManager.default.removeItem(at: directory)
            exportDirectory = nil
        } catch {
            errorMessage = "匯出暫存檔清除失敗：\(error.localizedDescription)"
            Logger(subsystem: "tw.speedcammap.app", category: "userCameras")
                .error("匯出暫存檔清除失敗：\(error.localizedDescription, privacy: .public)")
        }
    }
}

private struct UserCameraShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            if let error {
                DispatchQueue.main.async { onError(error.localizedDescription) }
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
