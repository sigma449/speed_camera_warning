import SpeedCamCore
import SwiftUI

extension SavedPlace.Kind {
    var label: String {
        switch self {
        case .home: return "住家"
        case .work: return "公司"
        case .favorite: return "常用地點"
        }
    }

    var assignmentTitle: String { self == .favorite ? "新增常用地點" : "設定\(label)" }
    var savedMessage: String { self == .favorite ? "已加入常用地點" : "已設為\(label)" }
}

private enum SavedPlaceSheet: Identifiable {
    case assign(SavedPlace.Kind)
    case rename(SavedPlace)

    var id: String {
        switch self {
        case .assign(let kind): return kind.rawValue
        case .rename(let place): return place.id.uuidString
        }
    }
}

struct SavedPlacesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var sheet: SavedPlaceSheet?
    @State private var feedback: String?
    /// 自己控制編輯狀態：系統 EditButton 會跟著 App 語言變成「Edit」。
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            if let warning = model.savedPlacesWarning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if let feedback {
                Text(feedback).font(.callout)
            }
            if model.savedPlaces.isEmpty {
                Text("在搜尋頁點「住家」「公司」，或在地圖長按地點後點星號，就能存成常用地點。")
            }
            Section("住家與公司") {
                shortcut(.home, place: model.savedPlaces.home, symbol: "house.fill")
                shortcut(.work, place: model.savedPlaces.work, symbol: "briefcase.fill")
            }
            Section("常用地點（\(model.savedPlaces.favorites.count)／\(SavedPlaces.maxFavorites)）") {
                ForEach(model.savedPlaces.favorites) { place in
                    Button { sheet = .rename(place) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(place.displayTitle)
                            if !place.subtitle.isEmpty { Text(place.subtitle).font(.footnote).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    let ids = offsets.map { model.savedPlaces.favorites[$0].id }
                    for id in ids {
                        model.removeSavedPlace(id: id)
                        if model.savedPlacesWarning != nil { return }
                    }
                    feedback = "已移除"
                }
                .onMove { offsets, destination in
                    model.moveFavorites(fromOffsets: offsets, toOffset: destination)
                    if model.savedPlacesWarning == nil { feedback = "已更新排序" }
                }
                let full = model.savedPlaces.favorites.count >= SavedPlaces.maxFavorites
                Button { sheet = .assign(.favorite) } label: {
                    Label(full ? "已達 20 個上限" : "新增常用地點", systemImage: "plus")
                }
                .disabled(full)
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("常用地點")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(editMode.isEditing ? "完成" : "編輯") {
                    editMode = editMode.isEditing ? .inactive : .active
                }
                .disabled(model.savedPlaces.favorites.isEmpty && !editMode.isEditing)
            }
        }
        .sheet(item: $sheet) { request in
            switch request {
            case .assign(let kind):
                SearchView(assigning: kind) { feedback = $0.savedMessage }
                    .environmentObject(model)
            case .rename(let place):
                SavedPlaceRenameView(place: place) { title in
                    try model.renameSavedPlace(id: place.id, title: title)
                    feedback = "已儲存名稱"
                }
            }
        }
    }

    private func shortcut(_ kind: SavedPlace.Kind, place: SavedPlace?, symbol: String) -> some View {
        Button { sheet = .assign(kind) } label: {
            HStack {
                Label(kind.label, systemImage: symbol)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(place?.placeName ?? "未設定")
                    if let place, !place.subtitle.isEmpty { Text(place.subtitle).font(.footnote) }
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            if let place {
                Button("移除", role: .destructive) {
                    model.removeSavedPlace(id: place.id)
                    if model.savedPlacesWarning == nil { feedback = "已移除" }
                }
            }
        }
    }
}

struct SavedPlaceRenameView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var errorText: String?
    let place: SavedPlace
    let onSave: (String) throws -> Void

    init(place: SavedPlace, onSave: @escaping (String) throws -> Void) {
        self.place = place
        self.onSave = onSave
        _title = State(initialValue: place.title)
    }

    var body: some View {
        AdaptiveNavigationStack {
            Form {
                Section {
                    TextField("常用地點名稱", text: $title)
                } header: {
                    Text("顯示名稱")
                } footer: {
                    Text("最多 30 個字；留白會使用原地點名稱「\(place.placeName)」。")
                }
                if let errorText { Text(errorText).foregroundStyle(.red) }
            }
            .navigationTitle("更改常用地點名稱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        do {
                            try onSave(title)
                            dismiss()
                        } catch { errorText = error.localizedDescription }
                    }
                }
            }
        }
    }
}
