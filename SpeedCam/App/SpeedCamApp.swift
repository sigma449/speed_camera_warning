import SwiftUI

@main
struct SpeedCamApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if model.showGallery, #available(iOS 17, *) {
                    GalleryRoot()
                } else {
                    RootView()
                }
            }
            .environmentObject(model)
            .onAppear { model.onAppear() }
            .onChange(of: scenePhase) { phase in
                if phase == .active { model.sceneBecameActive() }
            }
            .preferredColorScheme(.dark)
        }
    }
}

/// CI 截圖用的預覽頁。
@available(iOS 17, *)
private struct GalleryRoot: View {
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("-galleryBanners") {
            BannerGalleryView()
        } else if ProcessInfo.processInfo.arguments.contains("-galleryLock") {
            LockScreenGalleryView()
        } else {
            ActivityGalleryView()
        }
    }
}
