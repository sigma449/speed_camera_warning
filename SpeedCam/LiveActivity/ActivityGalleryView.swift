import SwiftUI

/// Live Activity 預覽頁（以 -gallery 參數啟動）。
/// 依 Apple 文件列出的 CarPlay 尺寸（240×78、240×100、170×78 pt）排出各種狀態，
/// 讓 CI 可以截圖檢查版面，不需要真的接上 CarPlay。
@available(iOS 17, *)
struct ActivityGalleryView: View {
    private let states: [(String, ActivityState)] = [
        ("接近測速", .previewCamera),
        ("超速", .previewOverspeed),
        ("區間倒數", .previewSection),
        ("區間歸零", .previewSectionZero),
        ("導航", .previewNavigation),
        ("巡航", .previewIdle),
        ("巡航・紅黃牌", .previewIdleRedYellow),
        ("最長類型", .previewLongestCamera),
        ("最長指示", .previewLongestNavigation),
        ("接近區間", .previewSectionApproach),
        ("區間＋轉彎", .previewSectionWithTurn),
        ("照相＋轉彎", .previewCameraWithTurn),
        ("重新規劃", .previewRerouting),
    ]

    /// 預覽頁比一個畫面長。`-galleryMiddle`、`-galleryBottom` 指定從哪裡開始顯示，CI 才拍得到整頁。
    private let startAnchor: UnitPoint = {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-galleryBottom") { return .bottom }
        if arguments.contains("-galleryMiddle") { return .center }
        return .top
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("CarPlay Live Activity 預覽（240×78 pt，最矮的尺寸）")
                    .font(.headline)
                ForEach(states.indices, id: \.self) { i in
                    HStack(spacing: 10) {
                        tile(states[i].1, width: 240, height: 78)
                        Text(states[i].0).font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                Text("170×78 pt（最窄的尺寸）").font(.headline).padding(.top, 8)
                LazyVGrid(columns: [GridItem(.fixed(170)), GridItem(.fixed(170))], alignment: .leading, spacing: 10) {
                    ForEach(states.indices, id: \.self) { i in
                        tile(states[i].1, width: 170, height: 78)
                    }
                }

                Text("240×100 pt").font(.headline).padding(.top, 8)
                ForEach(states.indices, id: \.self) { i in
                    tile(states[i].1, width: 240, height: 100)
                }

                Text("鎖定畫面").font(.headline).padding(.top, 8)
                LockScreenActivityView(state: .previewCamera)
                    .background(Color.black.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            .padding()
        }
        .defaultScrollAnchor(startAnchor)
        .background(Color(white: 0.12))
    }

    private func tile(_ state: ActivityState, width: CGFloat, height: CGFloat) -> some View {
        SmallActivityView(state: state)
            .frame(width: width, height: height)
            .background(state.isOverspeed ? Color.red.opacity(0.85) : Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
