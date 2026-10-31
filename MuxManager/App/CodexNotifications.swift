import SwiftUI
import UserNotifications
import MuxCore

struct CodexNotificationTarget: Equatable, Sendable {
    let hostID: UUID
    let sessionID: String
    let windowID: String
    let paneID: String

    var userInfo: [String: String] {
        ["hostID": hostID.uuidString, "sessionID": sessionID, "windowID": windowID, "paneID": paneID]
    }
    init(hostID: UUID, sessionID: String, windowID: String, paneID: String) {
        self.hostID = hostID; self.sessionID = sessionID; self.windowID = windowID; self.paneID = paneID
    }
    init?(userInfo: [AnyHashable: Any]) {
        guard let host = userInfo["hostID"] as? String, let hostID = UUID(uuidString: host),
              let session = userInfo["sessionID"] as? String, TmuxCommand.isID(session, prefix: "$"),
              let window = userInfo["windowID"] as? String, TmuxCommand.isID(window, prefix: "@"),
              let pane = userInfo["paneID"] as? String, TmuxCommand.isID(pane, prefix: "%") else { return nil }
        self.init(hostID: hostID, sessionID: session, windowID: window, paneID: pane)
    }
}

@MainActor
final class CodexNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var enabled: Bool
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var error: String?
    var onEnabledChange: ((Bool) -> Void)?
    var onOpen: ((CodexNotificationTarget) -> Void)?
    private let library: LibraryStore
    private let center = UNUserNotificationCenter.current()

    init(library: LibraryStore) {
        self.library = library
        enabled = library.readLocal(Bool.self, name: "codex-notifications.json") ?? false
        super.init()
        center.delegate = self
    }
    func refreshAuthorization() async { authorization = await center.notificationSettings().authorizationStatus }
    func setEnabled(_ value: Bool) async {
        error = nil
        if value {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch { self.error = error.localizedDescription }
            await refreshAuthorization()
            guard authorization == .authorized || authorization == .provisional || authorization == .ephemeral else { return }
        }
        do { try library.writeLocal(value, name: "codex-notifications.json") }
        catch { self.error = error.localizedDescription; return }
        enabled = value; onEnabledChange?(value)
    }
    static func content(hostName: String, windowName: String, state: CodexAttentionState,
                        target: CodexNotificationTarget) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(hostName) · \(windowName)"
        content.body = state == .needsInput ? "Codex is waiting for input." : "Codex is ready for follow-up."
        content.sound = .default
        content.threadIdentifier = "codex-\(target.hostID)-\(target.windowID)-\(target.paneID)"
        content.userInfo = target.userInfo
        return content
    }
    func post(hostName: String, pane: CodexPaneTarget, state: CodexAttentionState, hostID: UUID) async {
        guard enabled else { return }
        await refreshAuthorization()
        guard enabled, authorization == .authorized || authorization == .provisional || authorization == .ephemeral else { return }
        let target = CodexNotificationTarget(hostID: hostID, sessionID: pane.sessionID, windowID: pane.windowID, paneID: pane.paneID)
        let content = Self.content(hostName: hostName, windowName: pane.windowName, state: state, target: target)
        do { try await center.add(UNNotificationRequest(identifier: "codex-" + UUID().uuidString, content: content, trigger: nil)) }
        catch { self.error = error.localizedDescription }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in completionHandler(enabled ? [.banner, .sound] : []) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let target = CodexNotificationTarget(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let target { onOpen?(target) }
            completionHandler()
        }
    }
}

struct CodexNotificationSettingsView: View {
    @ObservedObject var notifications: CodexNotifications
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Notify when Codex needs attention", isOn: Binding(get: { notifications.enabled }, set: { value in
                        saving = true
                        Task { await notifications.setEnabled(value); saving = false }
                    })).disabled(saving)
                    if saving { ProgressView() }
                } footer: {
                    Text("Checks Codex windows across sessions on connected hosts. Alerts include the host and window name; tap one to open that window. No host installation is needed.")
                }
                Section("Best effort") {
                    Text("Looks for Codex finishing a response or asking for input. It can miss short tasks or misread custom layouts. Work completed while disconnected is not detected. Existing idle windows do not generate alerts when you connect.")
                    Text("Monitoring can continue briefly in the background while iOS allows execution. It stops when iOS suspends the app or ends its background runtime. There is no remote push service.")
                    Text("Only host/window names and window identifiers are included in notifications. Terminal contents are not saved or sent to a server. This setting applies to this device.")
                }
                if notifications.authorization == .denied {
                    Section {
                        Text("Notifications are disabled in iOS Settings.")
                        Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    }
                }
                if let error = notifications.error { Section { Text(error).foregroundStyle(.orange) } }
            }
            .navigationTitle("Codex notifications")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await notifications.refreshAuthorization() }
        }
    }
}
