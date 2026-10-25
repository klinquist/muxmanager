import SwiftUI
import MuxCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var workspaces: [UUID: HostWorkspace] = [:]
    @Published var activeHostID: UUID?
    let library: LibraryStore
    private var resumeIDs: [UUID] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var suspensionTask: Task<Void, Never>?
    init(library: LibraryStore) {
        self.library = library
        #if DEBUG
        if let scene = LibraryStore.screenshotScene, let profile = library.visibleProfiles.first {
            let workspace = HostWorkspace(profile: profile, library: library)
            workspace.configureScreenshot(scene: scene)
            workspaces[profile.id] = workspace
            activeHostID = profile.id
            if scene == "preview" {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    workspace.conversation = true
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    workspace.conversation = false
                    workspace.configureScreenshot(scene: "original")
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    workspace.configureScreenshot(scene: "fit")
                }
            }
        }
        #endif
    }
    var activeWorkspace: HostWorkspace? { activeHostID.flatMap { workspaces[$0] } }

    func open(_ profile: ConnectionProfile) {
        let workspace: HostWorkspace
        if let existing = workspaces[profile.id] { workspace = existing; workspace.profile = profile }
        else {
            workspace = HostWorkspace(profile: profile, library: library)
            workspaces[profile.id] = workspace
        }
        activeHostID = profile.id
        #if DEBUG
        if let scene = LibraryStore.screenshotScene { workspace.configureScreenshot(scene: scene); return }
        #endif
        Task { await workspace.connect() }
    }
    func suspend() {
        #if DEBUG
        if LibraryStore.screenshotScene != nil { return }
        #endif
        guard suspensionTask == nil else { return }
        resumeIDs = workspaces.values.filter { $0.isConnected }.map(\.id)
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Restore tmux sizes") { [weak self] in
            Task { @MainActor in self?.finishBackgroundTask() }
        }
        suspensionTask = Task {
            await withTaskGroup(of: Void.self) { group in
                for workspace in workspaces.values { group.addTask { await workspace.disconnect() } }
            }
            finishBackgroundTask()
        }
    }
    func resume() {
        Task {
            await suspensionTask?.value
            suspensionTask = nil
            for id in resumeIDs {
                if let workspace = workspaces[id] { Task { await workspace.connect() } }
            }
            resumeIDs = []
        }
    }
    private func finishBackgroundTask() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
}
