import MapKit
import os
import SpeedCamCore
import SwiftUI

private let searchLog = Logger(subsystem: "tw.speedcammap.app", category: "search")

/// 搜尋目的地並開始導航。
/// - 沒有輸入時：快速搜尋按鈕（加油站、停車場…）和最近的目的地。
/// - 輸入中：邊打字邊顯示候選地點（MKLocalSearchCompleter）。
/// - 按下搜尋或點了一類地點：顯示搜尋結果，附距離。
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var completer = SearchCompleter()
    @State private var results: [SearchResultRow] = []
    /// 目前的搜尋結果是用哪段文字查的；輸入改變時用來判斷要不要清掉結果。
    @State private var resultsQuery: String?
    @State private var isSearching = false
    @State private var errorText: String?
    @State private var didApplyInitialQuery = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    HStack(spacing: 10) { ProgressView(); Text("搜尋中…") }
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
                if !results.isEmpty {
                    resultsSection
                } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    quickSection
                    recentSection
                } else {
                    suggestionsSection
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜尋地點或地址")
            .searchFocused($searchFocused)
            .onSubmit(of: .search) { runSearch(query) }
            .onChange(of: query) { _, newValue in
                if newValue != resultsQuery {
                    results = []
                    resultsQuery = nil
                    errorText = nil
                }
                completer.update(query: newValue, near: model.searchCenter)
            }
            .onAppear {
                if !didApplyInitialQuery, let initial = model.initialSearchQuery {
                    didApplyInitialQuery = true
                    query = initial
                } else {
                    // 打開就可以直接打字
                    searchFocused = true
                }
            }
            .task {
                if let text = model.searchTypingTest {
                    await runTypingStressTest(text)
                }
            }
            .navigationTitle("目的地")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Label(model.vehicleMode.routeTitle,
                          systemImage: model.vehicleMode == .car ? "car.fill" : Symbols.motorcycle)
                        .labelStyle(.titleAndIcon)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 沒有輸入時

    private var quickSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(QuickCategory.all) { category in
                        Button {
                            query = category.title
                            runSearch(category.title, sortByDistance: true)
                        } label: {
                            Label(category.title, systemImage: category.symbol)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.thinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        } header: {
            Text("附近")
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !model.recentDestinations.isEmpty {
            Section {
                ForEach(model.recentDestinations) { recent in
                    Button {
                        model.beginPreview(to: recent)
                        dismiss()
                    } label: {
                        row(symbol: "clock.arrow.circlepath", title: Text(recent.name), subtitle: recent.subtitle,
                            distance: MapItems.distanceText(from: model.searchCenter, to: recent.coordinate))
                    }
                    .swipeActions {
                        Button("刪除", role: .destructive) { model.removeRecent(recent) }
                    }
                }
            } header: {
                HStack {
                    Text("最近的目的地")
                    Spacer()
                    Button("清除") { model.clearRecents() }
                        .font(.footnote)
                }
            }
        }
    }

    // MARK: 輸入中：候選

    @ViewBuilder
    private var suggestionsSection: some View {
        Section {
            if completer.suggestions.isEmpty {
                Text(completer.failed ? "暫時找不到候選，按鍵盤上的「搜尋」試試看" : "輸入中…")
                    .foregroundStyle(.secondary)
            }
            ForEach(completer.suggestions) { suggestion in
                Button {
                    select(suggestion.completion)
                } label: {
                    row(symbol: suggestion.isCategory ? "magnifyingglass" : "mappin.circle.fill",
                        title: Text(suggestion.title), subtitle: suggestion.subtitle, distance: nil)
                }
                .disabled(isSearching)
            }
        }
    }

    // MARK: 搜尋結果

    private var resultsSection: some View {
        Section {
            ForEach(results) { result in
                Button {
                    navigate(to: result.item)
                } label: {
                    row(symbol: "mappin.circle.fill", title: Text(result.name), subtitle: result.subtitle,
                        distance: MapItems.distanceText(from: model.searchCenter, to: result.coordinate))
                }
            }
        } header: {
            Text("搜尋結果（\(results.count)）")
        }
    }

    private func row(symbol: String, title: Text, subtitle: String, distance: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let distance {
                Text(distance)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: 壓力測試（CI 用）

    /// 模擬使用者慢慢打字、等結果、改字、刪掉重打，用來重現打字時閃退（使用者回報：打「台北車站」等一下就閃退）。
    private func runTypingStressTest(_ text: String) async {
        let chars = Array(text)
        let edits = ["台", "台北", "台北車", "台北車站", "台北車站 ", "台北車站東", "台北車站東三門", "台北", "台", "", text]
        for round in 1...4 {
            searchLog.notice("typing round \(round)")
            for n in 1...max(1, chars.count) {
                query = String(chars.prefix(n))
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)   // 停下來等候選結果
            for q in edits {
                query = q
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        searchLog.notice("typing test finished; suggestions=\(completer.suggestions.count)")
    }

    // MARK: 動作

    /// 選好地點：關掉搜尋，回到地圖先預覽地點和路線，再開始導航。
    private func navigate(to item: MKMapItem) {
        model.beginPreview(to: item)
        dismiss()
    }

    /// 點了候選：只有一個地點就直接預覽；是一類地點（例如「加油站」）就列出結果。
    private func select(_ suggestion: MKLocalSearchCompletion) {
        isSearching = true
        errorText = nil
        Task {
            defer { isSearching = false }
            do {
                let items = try await model.search(completion: suggestion)
                if items.count == 1, let item = items.first {
                    navigate(to: item)
                } else if items.isEmpty {
                    errorText = "找不到「\(suggestion.title)」"
                } else {
                    show(items, for: query, sortByDistance: suggestion.subtitle.isEmpty)
                }
            } catch {
                errorText = "搜尋失敗：\(error.localizedDescription)"
            }
        }
    }

    private func runSearch(_ text: String, sortByDistance: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSearching = true
        errorText = nil
        Task {
            defer { isSearching = false }
            do {
                let items = try await model.search(text)
                if items.isEmpty {
                    errorText = "找不到「\(text)」"
                } else {
                    show(items, for: text, sortByDistance: sortByDistance)
                }
            } catch {
                errorText = "搜尋失敗：\(error.localizedDescription)"
            }
        }
    }

    private func show(_ items: [MKMapItem], for text: String, sortByDistance: Bool) {
        resultsQuery = text
        var sorted = items
        if sortByDistance, let center = model.searchCenter {
            sorted = items.sorted {
                MapItems.distance(from: center, to: MapItems.coordinate(of: $0))
                    < MapItems.distance(from: center, to: MapItems.coordinate(of: $1))
            }
        }
        results = sorted.enumerated().map { index, item in
            SearchResultRow(id: index, item: item, name: item.name ?? "未命名地點",
                            subtitle: MapItems.subtitle(of: item), coordinate: MapItems.coordinate(of: item))
        }
    }
}

/// 搜尋結果的一列（顯示用的資料先算好，清單用 id 不用索引）。
struct SearchResultRow: Identifiable {
    let id: Int
    let item: MKMapItem
    let name: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
}
