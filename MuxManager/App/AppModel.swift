import SwiftUI
import MuxCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var workspaces: [UUID: HostWorkspace] = [:]
    @Published var activeHostID: UUID?
    let library: LibraryStore
    let notifications: CodexNotifications
    @Published private(set) var notificationNavigationRevision = 0
    private var notificationNavigationRequest = UUID()
    private var backgroundSession: BackgroundConnectionSession?
    private var transitionID = UUID()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTaskOwner: UUID?
    private var preparationTask: Task<Void, Never>?
    private var graceTimer: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var foregroundResumeSession: BackgroundConnectionSession?
    init(library: LibraryStore) {
        self.library = library
        notifications = CodexNotifications(library: library)
        notifications.onEnabledChange = { [weak self] _ in
            guard let self else { return }
            for workspace in self.workspaces.values { self.configureNotifications(workspace) }
        }
        notifications.onOpen = { [weak self] target in self?.openNotification(target) }
        #if DEBUG
        if let scene = LibraryStore.screenshotScene, let profile = library.visibleProfiles.first {
            let workspace = HostWorkspace(profile: profile, library: library)
            workspace.configureScreenshot(scene: scene)
            configureNotifications(workspace)
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
        cancelNotificationNavigation()
        let workspace = workspace(for: profile)
        activeHostID = profile.id
        #if DEBUG
        if let scene = LibraryStore.screenshotScene { workspace.configureScreenshot(scene: scene); return }
        #endif
        Task { await workspace.connect() }
    }

    private func workspace(for profile: ConnectionProfile) -> HostWorkspace {
        let workspace: HostWorkspace
        if let existing = workspaces[profile.id] { workspace = existing; workspace.profile = profile }
        else {
            workspace = HostWorkspace(profile: profile, library: library)
            workspaces[profile.id] = workspace
        }
        configureNotifications(workspace)
        return workspace
    }
    private func configureNotifications(_ workspace: HostWorkspace) {
        workspace.configureAttention(enabled: notifications.enabled) { [weak self, weak workspace] pane, state in
            guard let self, let workspace, self.library.visibleProfiles.contains(where: { $0.id == workspace.id }) else { return }
            Task { await self.notifications.post(hostName: workspace.profile.name, pane: pane, state: state, hostID: workspace.id) }
        }
    }
    func cancelNotificationNavigation() { notificationNavigationRequest = UUID() }

    private func openNotification(_ target: CodexNotificationTarget) {
        guard let profile = library.visibleProfiles.first(where: { $0.id == target.hostID }) else {
            library.error = "The connection for this notification is no longer saved."; return
        }
        let request = UUID(); notificationNavigationRequest = request
        let workspace = workspace(for: profile)
        activeHostID = profile.id; notificationNavigationRevision += 1
        Task { [weak self] in
            let originalIntent = workspace.connectionIntent
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            // A tap can arrive while SwiftUI is still delivering the foreground
            // transition. Let connection validation/recovery finish first.
            try? await Task.sleep(for: .milliseconds(100))
            while UIApplication.shared.applicationState != .active || self?.foregroundResumeSession != nil || workspace.state == .disconnecting {
                guard self?.notificationNavigationRequest == request, workspace.connectionIntent == originalIntent,
                      ContinuousClock.now < deadline else { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard self?.notificationNavigationRequest == request, workspace.connectionIntent == originalIntent else { return }
            if workspace.canConnect { await workspace.connect() }
            while workspace.state == .connecting || workspace.busy || workspace.sending {
                guard self?.notificationNavigationRequest == request, ContinuousClock.now < deadline else { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, self.notificationNavigationRequest == request, workspace.isConnected else { return }
            await workspace.openNotificationWindow(target, isCurrent: { [weak self] in self?.notificationNavigationRequest == request })
        }
    }
    func suspend() {
        #if DEBUG
        if LibraryStore.screenshotScene != nil { return }
        #endif
        guard backgroundSession == nil else { return }
        transitionID = UUID()
        for workspace in workspaces.values { workspace.pauseForBackground() }
        let targets = workspaces.values.filter {
            $0.shouldRetainInBackground || foregroundResumeSession?.includes(host: $0.id, intent: $0.connectionIntent) == true
        }
        guard !targets.isEmpty else {
            if let owner = backgroundTaskOwner { finishBackgroundTask(owner: owner) }
            return
        }
        let session = BackgroundConnectionSession(intents: Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.connectionIntent) }))
        backgroundSession = session
        // An old expiration callback must never end a newer runtime request.
        if let owner = backgroundTaskOwner { finishBackgroundTask(owner: owner) }
        backgroundTaskOwner = session.id
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SSH connection grace period") { [weak self] in
            Task { @MainActor in self?.backgroundTimeExpired(owner: session.id) }
        }
        let previousPreparation = preparationTask, previousResume = resumeTask, previousCleanup = cleanupTask
        let preparation = Task { [weak self] in
            await previousPreparation?.value
            await previousResume?.value
            await previousCleanup?.value
            guard self?.backgroundSession?.id == session.id else { return }
            await withTaskGroup(of: Void.self) { group in
                for workspace in targets {
                    let intent = session.intents[workspace.id]!
                    group.addTask { await workspace.prepareForBackground(expectedIntent: intent) }
                }
            }
        }
        preparationTask = preparation
        graceTimer?.cancel()
        graceTimer = Task { [weak self] in
            await preparation.value
            do { try await Task.sleep(for: session.remainingTime()) } catch { return }
            guard let self, self.backgroundSession?.id == session.id, !Task.isCancelled else { return }
            // Separate cleanup from the timer so returning to the foreground can
            // cancel a sleep without interrupting an in-progress SSH command.
            self.cleanupTask = Task { [weak self] in
                await withTaskGroup(of: Void.self) { group in
                    for workspace in targets {
                        group.addTask { [weak self] in await self?.closeRetainedConnection(workspace, session: session) }
                    }
                }
                self?.finishBackgroundTask(owner: session.id)
            }
        }
    }
    func resume() {
        guard let session = backgroundSession else {
            if foregroundResumeSession == nil {
                for workspace in workspaces.values { workspace.unpauseAfterBackground() }
            }
            return
        }
        backgroundSession = nil
        let transition = UUID(); transitionID = transition
        foregroundResumeSession = session
        graceTimer?.cancel(); graceTimer = nil
        let preparation = preparationTask, cleanup = cleanupTask
        resumeTask = Task { [weak self] in
            defer {
                if self?.foregroundResumeSession?.id == session.id { self?.foregroundResumeSession = nil }
            }
            await preparation?.value
            await cleanup?.value
            guard let self, self.transitionID == transition, self.backgroundSession == nil else { return }
            self.finishBackgroundTask(owner: session.id)
            for workspace in self.workspaces.values where !session.includes(host: workspace.id, intent: workspace.connectionIntent) {
                workspace.unpauseAfterBackground()
            }
            await withTaskGroup(of: Void.self) { group in
                for id in session.intents.keys {
                    group.addTask { [weak self] in
                        await self?.resumeRetainedConnection(id, session: session, transition: transition)
                    }
                }
            }
        }
    }

    private func closeRetainedConnection(_ workspace: HostWorkspace, session: BackgroundConnectionSession) async {
        guard session.includes(host: workspace.id, intent: workspace.connectionIntent) else { return }
        await workspace.disconnect(automatically: true)
    }

    private func resumeRetainedConnection(_ id: UUID, session: BackgroundConnectionSession, transition: UUID) async {
        guard transitionID == transition, backgroundSession == nil, let workspace = workspaces[id],
              session.includes(host: id, intent: workspace.connectionIntent) else { return }
        await workspace.resumeFromBackground(forceReconnect: session.requiresReconnect())
    }

    private func backgroundTimeExpired(owner: UUID) {
        guard backgroundTaskOwner == owner else { return }
        // Stop requesting CPU time. Parked sockets may survive suspension; they
        // are validated on return rather than deliberately closed at this point.
        if let session = backgroundSession, session.id == owner {
            for workspace in workspaces.values where session.includes(host: workspace.id, intent: workspace.connectionIntent) {
                workspace.backgroundTimeExpired()
            }
        }
        finishBackgroundTask(owner: owner)
    }

    private func finishBackgroundTask(owner: UUID) {
        guard backgroundTaskOwner == owner else { return }
        let task = backgroundTask
        backgroundTask = .invalid; backgroundTaskOwner = nil
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }
}
