import SpeedCamCore
import SwiftUI
import UIKit

struct QuickCameraButton: View {
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: Symbols.addCamera)
                .font(.system(size: 20, weight: .semibold))
                .overlay(alignment: .topTrailing) {
                    if Symbols.addCamera == "camera.fill" {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .offset(x: 6, y: -4)
                    }
                }
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
                .foregroundStyle(Color.primary)
                .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("在目前位置新增測速點")
    }
}

struct QuickCameraConfirmationCard: View {
    let onSpeedLimit: (Int) -> Void
    let onEdit: () -> Void
    let onUndo: () -> Void
    @ScaledMetric(relativeTo: .headline) private var choiceWidth: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已新增測速點")
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: choiceWidth), spacing: 8)], spacing: 8) {
                ForEach([40, 50, 60, 70], id: \.self) { limit in
                    choice("\(limit)") { onSpeedLimit(limit) }
                        .accessibilityLabel("設定速限 \(limit) 公里每小時")
                }
                choice("其他", action: onEdit)
                    .accessibilityLabel("修改照相點，設定其他速限")
            }
            Button("復原", action: onUndo)
                .font(.body.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("復原，刪除剛新增的測速點")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func choice(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 4)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
