#if os(macOS)
import SwiftUI
import AppKit
import MuxCore

struct WorkspaceView: View {
    @ObservedObject var workspace: HostWorkspace
    var returnToWindows: () -> Void
    @AppStorage("composerSpellCheckEnabled") private var spelling = true
    @State private var action: ManagementAction?
    @State private var diagnostics = false
    @State private var follow = true
    @State private var heldCapture: String?
    @State private var liveToken = 0
    @State private var focusToken = 0

    var body: some View {
        VStack(spacing: 0) {
            if let window = workspace.selectedWindow {
                HStack(spacing: 16) {
                    Picker("Display", selection: Binding(get: { workspace.displayMode }, set: { value in Task { await workspace.setDisplayMode(value) } })) {
                        Text("Smart").tag(DisplayMode.smart)
                        Text("Fit window").tag(DisplayMode.fit)
                        Text("Original").tag(DisplayMode.original)
                    }.pickerStyle(.segmented).frame(maxWidth: 360)
                    Picker("Input", selection: Binding(get: { workspace.terminalMode }, set: { value in workspace.setTerminalMode(value); focusToken += 1 })) {
                        Text("Compose").tag(false); Text("Terminal").tag(true)
                    }.pickerStyle(.segmented).frame(width: 200)
                    Spacer()
                    Text("\(workspace.remoteColumns)×\(workspace.remoteRows)").monospacedDigit().foregroundStyle(.secondary)
                }.padding(12).disabled(!workspace.isReadyForInput)
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        if workspace.displayMode == .smart || workspace.conversation {
                            MacStyledCapture(capture: heldCapture ?? workspace.joinedCapture,
                                             fontSize: workspace.fontSize, conversation: workspace.conversation,
                                             follow: $follow, liveToken: liveToken,
                                             onSelection: pauseForSelection)
                            if workspace.terminalMode && workspace.directInput {
                                MacTerminalCanvas(workspace: workspace, follow: .constant(true), liveToken: liveToken, inputOnly: true)
                                    .frame(width: 1, height: 1).opacity(0.01)
                            }
                        } else {
                            MacTerminalCanvas(workspace: workspace, follow: $follow, liveToken: liveToken)
                        }
                    }
                    .background(Color(red: 0.035, green: 0.055, blue: 0.07))
                    .onAppear { viewport(geometry.size); workspace.noteAttentionWindowViewed() }
                    .onChange(of: geometry.size) { _, size in viewport(size) }
                    .onChange(of: workspace.fontSize) { _, _ in viewport(geometry.size) }
                }
                HStack {
                    Circle().fill(workspace.isConnected ? .mint : .orange).frame(width: 6, height: 6)
                    Text(workspace.profile.name)
                    Text(workspace.displayMode == .fit ? "Remote size changed" : "Remote size preserved").foregroundStyle(.secondary)
                    Spacer()
                    Button("Live", systemImage: "arrow.down.to.line", action: live).help("Follow the latest output (⇧⌘L)")
                    if workspace.terminalMode {
                        Button("Focus terminal", systemImage: "keyboard") {
                            workspace.setTerminalMode(true); focusToken += 1; live()
                        }.help("Focus terminal (⇧⌘T)")
                        Button("Paste", systemImage: "doc.on.clipboard") {
                            guard let text = NSPasteboard.general.string(forType: .string) else { return }
                            let intent = workspace.connectionIntent
                            Task { await workspace.pasteIntoTerminal(text, windowID: window.id, connectionIntent: intent) }
                        }.disabled(!workspace.isReadyForInput || workspace.sending)
                    }
                }.font(.caption).padding(.horizontal, 12).padding(.vertical, 7).background(.bar)
                if !workspace.isReadyForInput {
                    HStack {
                        if workspace.isAutoReconnecting || workspace.isEstablishingConnection { ProgressView().controlSize(.small) }
                        Text(workspace.statusText).font(.callout)
                        Spacer()
                        if workspace.canDisconnect { Button("Disconnect") { Task { await workspace.disconnect() } } }
                        else { Button("Connect") { Task { await workspace.connect() } }.disabled(!workspace.canConnect) }
                    }.padding(10).background(.orange.opacity(0.12))
                }
                if !workspace.terminalMode {
                    HStack(alignment: .bottom, spacing: 10) {
                        MacComposer(text: $workspace.draft, spelling: spelling, focusToken: focusToken,
                                    browsingHistory: workspace.isBrowsingCommandHistory,
                                    onSubmit: { if workspace.submitDraft() != nil { live() } },
                                    onHistory: { workspace.recallCommand(older: $0) },
                                    onTab: { Task { await workspace.completeInShell() } })
                            .frame(height: 88)
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        VStack(spacing: 10) {
                            Toggle("ABC", isOn: $spelling).toggleStyle(.button)
                                .help("Spelling and autocorrect").accessibilityLabel("Spelling and autocorrect")
                            Button {
                                if workspace.submitDraft() != nil { live() }
                            } label: {
                                if workspace.isSubmittingDraft { ProgressView().controlSize(.small).frame(width: 46) }
                                else { Label("Send", systemImage: "arrow.up").frame(width: 46) }
                            }.buttonStyle(.borderedProminent)
                                .disabled(!workspace.isReadyForInput || workspace.draft.isEmpty || workspace.sending || workspace.busy)
                                .help("Send (Return); Shift-Return inserts a newline")
                        }
                    }.padding(12)
                    if workspace.isSubmittingDraft { Text("Sending…").font(.caption).foregroundStyle(.secondary).padding(.bottom, 6) }
                    if let hint = workspace.completionHint { Text(hint).font(.caption).foregroundStyle(.secondary).padding(.bottom, 6) }
                }
            } else {
                ContentUnavailableView {
                    Label(workspace.isEstablishingConnection ? "Connecting" : (workspace.isConnected ? "Choose a window" : workspace.profile.name), systemImage: "terminal")
                } description: { Text(workspace.statusText) } actions: {
                    if workspace.isEstablishingConnection || workspace.isAutoReconnecting { ProgressView() }
                    else if workspace.isConnected { Button("New session") { action = .newSession } }
                    else { Button("Connect") { Task { await workspace.connect() } }.disabled(!workspace.canConnect) }
                }
            }
        }
        .navigationTitle(workspace.selectedWindow?.name ?? workspace.profile.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Connection diagnostics") { diagnostics = true }
                    Button("New window…") { action = .newWindow }.disabled(!workspace.isConnected)
                    Button("New session…") { action = .newSession }.disabled(!workspace.isConnected)
                    Button("Rename window…") { action = .renameWindow }.disabled(workspace.selectedWindow == nil)
                    Button("Rename session…") { action = .renameSession }.disabled(workspace.selectedSessionID == nil)
                    Divider()
                    Button("Larger text") { workspace.fontSize = min(32, workspace.fontSize + 1) }
                    Button("Smaller text") { workspace.fontSize = max(8, workspace.fontSize - 1) }
                    Toggle("Conversation view", isOn: $workspace.conversation).disabled(workspace.terminalMode)
                    Divider()
                    Button("Disconnect") { Task { await workspace.disconnect() } }.disabled(!workspace.canDisconnect)
                } label: { Image(systemName: "ellipsis.circle") }.help("Window actions")
            }
        }
        .sheet(item: $action) { item in ManagementSheet(workspace: workspace, action: item) { action = nil } }
        .sheet(isPresented: $diagnostics) { ConnectionDiagnosticsView(workspace: workspace).muxFormSheet() }
        .sheet(item: $workspace.challenge) { challenge in MacHostTrustView(challenge: challenge) { Task { await workspace.trustAndReconnect(challenge) } } }
        .alert("Mux Manager", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
        .onChange(of: follow) { _, value in
            if value { heldCapture = nil }
            else if heldCapture == nil { heldCapture = workspace.joinedCapture }
        }
        .onChange(of: workspace.selectedWindowID) { _, _ in live(); focusToken += 1; workspace.noteAttentionWindowViewed() }
        .onChange(of: workspace.inputRevision) { _, _ in live() }
        .onChange(of: workspace.connectionRecoveryRevision) { _, _ in live() }
        .onChange(of: workspace.notificationFocusRevision) { _, _ in live() }
        .onReceive(NotificationCenter.default.publisher(for: .muxLiveOutput)) { _ in live() }
        .onReceive(NotificationCenter.default.publisher(for: .muxFocusTerminal)) { _ in workspace.setTerminalMode(true); focusToken += 1; live() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in workspace.noteAttentionWindowViewed() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in live() }
    }
    private func live() { heldCapture = nil; follow = true; liveToken += 1 }
    private func pauseForSelection() { heldCapture = workspace.joinedCapture; follow = false; workspace.directInput = false }
    private func viewport(_ size: CGSize) {
        let font = NSFont.monospacedSystemFont(ofSize: workspace.fontSize, weight: .regular)
        let width = ("W" as NSString).size(withAttributes: [.font: font]).width
        let height = ceil(font.ascender - font.descender + font.leading)
        workspace.updateViewport(columns: Int(max(1, size.width - 16) / max(1, width)), rows: Int(size.height / max(1, height)))
    }
}

private struct MacHostTrustView: View {
    let challenge: HostKeyChallenge
    let approve: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(challenge.previousFingerprint == nil ? "Verify host fingerprint" : "Host key changed", systemImage: "checkmark.shield").font(.title2)
            Text(challenge.endpoint).font(.headline)
            Text("Compare this fingerprint with the host before trusting it on this Mac.")
            Text(challenge.fingerprint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            if let previous = challenge.previousFingerprint { Text("Previously trusted: \(previous)").foregroundStyle(.orange).textSelection(.enabled) }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Trust and connect") { dismiss(); approve() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 520)
    }
}
#endif
