import SwiftUI

// 新舊系統 API 不同的畫面元件。新系統用原本的元件，舊系統用外觀接近的替代做法（見 LegacySupport）。

/// NavigationStack 要 iOS 16，舊系統用 NavigationView。
struct AdaptiveNavigationStack<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 16, *), !LegacySupport.forced {
            NavigationStack(root: content)
        } else {
            NavigationView(content: content)
                .navigationViewStyle(.stack)
        }
    }
}

/// LabeledContent 要 iOS 16，舊系統用左右兩段文字。
struct LabeledValue: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        if #available(iOS 16, *), !LegacySupport.forced {
            LabeledContent(title, value: value)
        } else {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

private struct MapCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MapCardScrollView<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            content()
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: MapCardHeightKey.self, value: geometry.size.height)
                })
        }
        .frame(maxHeight: min(contentHeight ?? maximumHeight, maximumHeight))
        .onPreferenceChange(MapCardHeightKey.self) { contentHeight = $0 }
    }
}

extension View {
    /// 打開搜尋就可以打字要 iOS 18；舊系統要自己點搜尋框。
    @ViewBuilder
    func searchFocusedIfAvailable(_ focused: FocusState<Bool>.Binding) -> some View {
        if #available(iOS 18, *) {
            searchFocused(focused)
        } else {
            self
        }
    }
}
