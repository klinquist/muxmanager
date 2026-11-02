#if os(macOS)
import SwiftUI
import AppKit

@main
struct MuxManagerMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @StateObject private var library: LibraryStore
    @StateObject private var model: AppModel
    init() {
        let store = LibraryStore()
        _library = StateObject(wrappedValue: store)
        _model = StateObject(wrappedValue: AppModel(library: store))
    }
    var body: some Scene {
        Window("Mux Manager", id: "main") {
            RootView().environmentObject(library).environmentObject(model)
                .tint(.mint).preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    delegate.model = model
                    #if DEBUG
                    if LibraryStore.screenshotScene == "mac" {
                        try? await Task.sleep(for: .seconds(2))
                        await MacValidation.run(model: model)
                        return
                    }
                    if LibraryStore.screenshotScene == "reconnect", let workspace = model.activeWorkspace {
                        await workspace.validateAutomaticReconnect(); return
                    }
                    #endif
                    if model.activeWorkspace == nil { model.open(.localMac) }
                    await library.runAutomaticSync()
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in model.resume() }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New connection…") { NotificationCenter.default.post(name: .muxAddConnection, object: nil) }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Live output") { NotificationCenter.default.post(name: .muxLiveOutput, object: nil) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Focus terminal") { NotificationCenter.default.post(name: .muxFocusTerminal, object: nil) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            TextEditingCommands()
        }
    }
}

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var quitting = false
    private var terminationReplied = false
    private func finishQuit() {
        guard !terminationReplied else { return }; terminationReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting, let model else { return .terminateNow }
        quitting = true
        Task { await model.disconnectAll(); self.finishQuit() }
        // A remote timeout must not trap the user in Quit.
        Task { try? await Task.sleep(for: .seconds(3)); self.finishQuit() }
        return .terminateLater
    }
}

extension Notification.Name {
    static let muxAddConnection = Notification.Name("MuxManager.addConnection")
    static let muxLiveOutput = Notification.Name("MuxManager.liveOutput")
    static let muxFocusTerminal = Notification.Name("MuxManager.focusTerminal")
}
#endif
