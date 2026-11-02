import MapKit
import SpeedCamCore
import SwiftUI

/// 搜尋目的地並開始導航。
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: model.vehicleMode == .car ? "car.fill" : Symbols.motorcycle)
                        Text(model.vehicleMode == .motorcycle
                             ? "重機模式：路線會避開國道與收費道路"
                             : "汽車模式")
                            .font(.footnote)
                    }
                    .foregroundStyle(.secondary)
                }
                if isSearching {
                    HStack { ProgressView(); Text("搜尋中…") }
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
                ForEach(results.indices, id: \.self) { i in
                    let item = results[i]
                    Button {
                        Task {
                            await model.startNavigation(to: item)
                            dismiss()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "未命名地點").font(.headline)
                            Text(MapItems.subtitle(of: item))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .disabled(model.isCalculatingRoute)
                }
            }
            .overlay {
                if model.isCalculatingRoute {
                    ProgressView("規劃路線中…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜尋地點或地址")
            .onSubmit(of: .search) { runSearch() }
            .navigationTitle("目的地")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
            }
        }
    }

    private func runSearch() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSearching = true
        errorText = nil
        Task {
            do {
                results = try await model.search(text)
                if results.isEmpty { errorText = "找不到「\(text)」" }
            } catch {
                errorText = "搜尋失敗：\(error.localizedDescription)"
            }
            isSearching = false
        }
    }
}
