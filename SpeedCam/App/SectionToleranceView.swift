import SpeedCamCore
import SwiftUI

/// 個別區間容許值：可搜尋、多選，再一次套用同一個容許值。
/// 同一段的兩個方向共用設定（依 SpeedSection.groupID 合併）。
struct SectionToleranceView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<String> = []
    @State private var query = ""

    private let choices: [Double] = [0, 5, 10, 15, 20]

    var body: some View {
        List {
            Section {
                ForEach(filteredGroups) { group in
                    Button {
                        toggle(group.id)
                    } label: {
                        row(group)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("\(filteredGroups.count) 段區間・已選 \(selected.count) 段")
            } footer: {
                Text("點選區間可多選，再用下方按鈕一次設定。沒有個別設定的區間使用預設 +\(Int(model.settings.sectionToleranceKmh))。同一段的兩個方向共用設定。")
            }

            if !model.settings.sectionToleranceOverrides.isEmpty {
                Section {
                    Button("清除所有個別設定", role: .destructive) {
                        model.clearAllSectionOverrides()
                        selected.removeAll()
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "搜尋路段（例如 台9、北宜、台61）")
        .navigationTitle("個別區間設定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selected.count == filteredGroups.count && !filteredGroups.isEmpty ? "取消全選" : "全選") {
                    if selected.count == filteredGroups.count {
                        selected.removeAll()
                    } else {
                        selected = Set(filteredGroups.map(\.id))
                    }
                }
                .disabled(filteredGroups.isEmpty)
            }
            ToolbarItem(placement: .bottomBar) {
                Menu {
                    Button("使用預設（+\(Int(model.settings.sectionToleranceKmh))）") {
                        model.setSectionTolerance(nil, for: selected)
                        selected.removeAll()
                    }
                    ForEach(choices, id: \.self) { value in
                        Button("+\(Int(value)) km/h") {
                            model.setSectionTolerance(value, for: selected)
                            selected.removeAll()
                        }
                    }
                } label: {
                    Label("設定選取的 \(selected.count) 段", systemImage: "slider.horizontal.3")
                        .font(.headline)
                }
                .disabled(selected.isEmpty)
            }
        }
    }

    private var filteredGroups: [AppModel.SectionGroup] {
        let groups = model.sectionGroups
        let q = query.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "臺", with: "台")
        guard !q.isEmpty else { return groups }
        return groups.filter { $0.name.replacingOccurrences(of: "臺", with: "台").localizedCaseInsensitiveContains(q) }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    private func row(_ group: AppModel.SectionGroup) -> some View {
        let override = model.settings.sectionToleranceOverrides[group.id]
        let tolerance = model.settings.sectionTolerance(forGroup: group.id)
        return HStack(spacing: 12) {
            Image(systemName: selected.contains(group.id) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected.contains(group.id) ? Color.accentColor : Color.secondary)
            SpeedLimitSign(limit: group.speedLimit, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(String(format: "%.1f 公里・%@", group.lengthMeters / 1_000, group.bidirectional ? "雙向" : "單向"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text("+\(Int(tolerance))")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(override == nil ? Color.secondary : Color.orange)
                Text(override == nil ? "預設" : "以 \(group.speedLimit + Int(tolerance)) 計算")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
