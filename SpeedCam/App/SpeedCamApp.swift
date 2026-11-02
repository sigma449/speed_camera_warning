import SwiftUI

@main
struct SpeedCamApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if model.showGallery {
                    ActivityGalleryView()
                } else {
                    RootView()
                }
            }
            .environment(model)
            .onAppear { model.onAppear() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.sceneBecameActive() }
            }
            .preferredColorScheme(.dark)
        }
    }
}
