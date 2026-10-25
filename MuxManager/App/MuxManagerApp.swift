import SwiftUI

@main
struct MuxManagerApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = LibraryStore()
        _library = StateObject(wrappedValue: store)
        _model = StateObject(wrappedValue: AppModel(library: store))
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(model)
                .tint(.mint)
                .preferredColorScheme(.dark)
                .task(id: scenePhase) {
                    if scenePhase == .active { await library.runAutomaticSync() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.suspend() }
                    if phase == .active { model.resume() }
                }
        }
    }
}
