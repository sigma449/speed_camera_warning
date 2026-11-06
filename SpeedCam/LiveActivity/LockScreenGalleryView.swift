import SwiftUI

/// 鎖定畫面和動態島展開的預覽頁（以 `-gallery -galleryLock` 啟動）。
/// 用和 Live Activity 相同的畫面元件排出各種狀態。動態島的外框是示意，實際由系統畫。
/// 加上 `-galleryBottom` 從頁面底部開始顯示，CI 才拍得到整頁。
struct LockScreenGalleryView: View {
    private let startAnchor: UnitPoint =
        ProcessInfo.processInfo.arguments.contains("-galleryBottom") ? .bottom : .top

    private let states: [ActivityState] = [
        .previewCamera, .previewOverspeed, .previewSection, .previewSectionZero, .previewNavigation, .previewIdle,
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("鎖定畫面").font(.headline)
                ForEach(states.indices, id: \.self) { i in
                    LockScreenActivityView(state: states[i])
                        .background(states[i].isOverspeed ? Color.red.opacity(0.8) : Color.black.opacity(0.75))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                }

                Text("動態島展開（外框為示意）").font(.headline).padding(.top, 8)
                ForEach(states.indices, id: \.self) { i in
                    expanded(states[i])
                }
            }
            .padding()
        }
        .defaultScrollAnchor(startAnchor)
        .background(Color(white: 0.3))
    }

    private func expanded(_ state: ActivityState) -> some View {
        VStack(spacing: 4) {
            HStack {
                ExpandedLeadingView(state: state)
                Spacer()
                ExpandedTrailingView(state: state)
            }
            SmallActivityView(state: state, showsLeading: false)
                .frame(height: 64)
        }
        .padding(14)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 32))
        .foregroundStyle(.white)
    }
}
