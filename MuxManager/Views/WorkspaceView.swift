import SwiftUI
import MuxCore

struct WorkspaceView: View {
    @ObservedObject var workspace: HostWorkspace
    var returnToWindows: () -> Void
    @State private var action: ManagementAction?
    @State private var showDiagnostics = false
    @State private var follow = true
    @State private var readingCapture: String?
    @State private var liveToken = 0
    @State private var magnificationStart: Double?
    @FocusState private var composerFocused: Bool
    @State private var keyboardVisible = false

    var body: some View {
        VStack(spacing: 0) {
            if let window = workspace.selectedWindow {
                displayControls
                GeometryReader { geometry in
                    ZStack(alignment: .bottomTrailing) {
                        if workspace.conversation {
                            ConversationContent(capture: readingCapture ?? workspace.joinedCapture, fontSize: workspace.fontSize, follow: $follow, liveToken: liveToken)
                        } else if workspace.displayMode == .smart {
                            SmartContent(capture: readingCapture ?? workspace.joinedCapture, fontSize: workspace.fontSize, follow: $follow, liveToken: liveToken)
                        } else {
                            TerminalCanvas(workspace: workspace, follow: $follow, liveToken: liveToken)
                        }
                    }
                    .background(Color(red: 0.035, green: 0.055, blue: 0.07))
                    .simultaneousGesture(MagnificationGesture().onChanged { scale in
                        if magnificationStart == nil { magnificationStart = workspace.fontSize }
                        workspace.fontSize = min(32, max(8, (magnificationStart ?? 14) * scale))
                    }.onEnded { _ in magnificationStart = nil })
                    .onAppear { updateViewport(geometry.size) }
                    .onChange(of: geometry.size) { _, size in updateViewport(size) }
                    .onChange(of: workspace.fontSize) { _, _ in updateViewport(geometry.size) }
                    .overlay(alignment: .topLeading) {
                        if workspace.directInput && (workspace.conversation || workspace.displayMode == .smart) {
                            DirectKeyboard { bytes in sendDirect(bytes) }.frame(width: 1, height: 1).opacity(0.01)
                        }
                    }
                }
                HStack(spacing: 6) {
                    Circle().fill(workspace.isConnected ? .mint : .orange).frame(width: 5, height: 5)
                    Text(workspace.profile.name)
                    Spacer()
                    Button {
                        follow = true; liveToken += 1
                    } label: { Label("Live", systemImage: "arrow.down.to.line").font(.caption.bold()) }
                        .buttonStyle(.borderless)
                    Text(workspace.displayMode == .fit ? "Remote size changed" : "Remote size preserved")
                    Text("\(workspace.remoteColumns)×\(workspace.remoteRows)").monospacedDigit()
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
                if !workspace.isConnected || workspace.isEstablishingConnection { connectionBanner }
                inputBar(window: window)
            } else {
                ContentUnavailableView {
                    Label(workspace.isEstablishingConnection ? "Connecting" : (workspace.isConnected ? "Choose a window" : workspace.profile.name), systemImage: "terminal")
                } description: {
                    Text(emptyDescription)
                } actions: {
                    if workspace.isEstablishingConnection {
                        ProgressView()
                    } else if workspace.isConnected {
                        Button("New session") { action = .newSession }.buttonStyle(.borderedProminent)
                    } else {
                        Button(workspace.state == .connecting ? "Connecting…" : "Connect") { Task { await workspace.connect() } }
                            .buttonStyle(.borderedProminent).disabled(!workspace.canConnect)
                    }
                }
            }
        }
        .navigationTitle(workspace.selectedWindow?.name ?? workspace.profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Connection diagnostics", systemImage: "stethoscope") { showDiagnostics = true }
                    Divider()
                    Button("New window", systemImage: "plus.rectangle") { action = .newWindow }.disabled(workspace.selectedSessionID == nil)
                    Button("New session", systemImage: "plus.rectangle.on.folder") { action = .newSession }
                    Button("Rename window", systemImage: "pencil") { action = .renameWindow }.disabled(workspace.selectedWindow == nil)
                    Button("Rename session", systemImage: "folder") { action = .renameSession }.disabled(workspace.selectedSessionID == nil)
                    Divider()
                    Button("Smaller text", systemImage: "textformat.size.smaller") { workspace.fontSize = max(8, workspace.fontSize - 1) }
                    Button("Larger text", systemImage: "textformat.size.larger") { workspace.fontSize = min(32, workspace.fontSize + 1) }
                    Divider()
                    Button("Disconnect", systemImage: "network.slash") { Task { await workspace.disconnect() } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(item: $action) { operation in ManagementSheet(workspace: workspace, action: operation) { action = nil } }
        .sheet(isPresented: $showDiagnostics) { ConnectionDiagnosticsView(workspace: workspace) }
        .sheet(item: $workspace.challenge) { challenge in
            HostTrustView(challenge: challenge) { Task { await workspace.trustAndReconnect(challenge) } }
        }
        .alert("Mux Manager", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
        .onChange(of: follow) { _, following in readingCapture = following ? nil : workspace.joinedCapture }
        .onChange(of: workspace.selectedWindowID) { _, _ in readingCapture = nil; follow = true; liveToken += 1; composerFocused = false }
        .onChange(of: workspace.inputRevision) { _, _ in readingCapture = nil; follow = true; liveToken += 1 }
        .onChange(of: workspace.directInput) { _, direct in if direct { composerFocused = false } }
        .onChange(of: workspace.closedWindowRevision) { _, _ in returnToWindows() }
        .onChange(of: workspace.state) { _, state in
            if state == .disconnected || state == .disconnecting { returnToWindows() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    }

    private var emptyDescription: String {
        if workspace.isEstablishingConnection || !workspace.isConnected { return workspace.statusText }
        return workspace.sessions.isEmpty
            ? "No tmux sessions are running. Create a session to begin."
            : "Choose a session and window from the sidebar."
    }

    private var displayControls: some View {
        VStack(spacing: 8) {
            Picker("Display mode", selection: Binding(get: { workspace.displayMode }, set: { mode in Task { await workspace.setDisplayMode(mode) } })) {
                ForEach(DisplayMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(workspace.busy || !workspace.isConnected)
                .accessibilityHint("Only Fit device changes the remote window size.")
            HStack {
                Button {
                    workspace.conversation.toggle()
                } label: {
                    Label(workspace.conversation ? "Conversation" : "Terminal", systemImage: workspace.conversation ? "bubble.left.and.bubble.right" : "terminal")
                        .font(.caption.weight(.medium))
                }
                Spacer()
                if workspace.conversation { Text("Interpreted from terminal").font(.caption2).foregroundStyle(.secondary) }
                Button {
                    workspace.directInput.toggle()
                } label: {
                    Label(workspace.directInput ? "Direct keys" : "Composer", systemImage: workspace.directInput ? "keyboard" : "square.and.pencil")
                        .font(.caption.weight(.medium))
                }.disabled(!workspace.isConnected)
            }
        }.padding(.horizontal, 12).padding(.vertical, 10).background(.bar)
    }

    private var connectionBanner: some View {
        HStack {
            Text(workspace.statusText).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if workspace.isEstablishingConnection {
                ProgressView().controlSize(.small)
            } else {
                Button("Reconnect") { Task { await workspace.connect() } }.font(.caption.bold()).disabled(!workspace.canConnect)
            }
        }.padding(10).background(.orange.opacity(0.15))
    }

    private func inputBar(window: RemoteWindow) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    key("Esc", "\u{1b}")
                    Button("Tab") { Task { await workspace.completeInShell() } }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Complete the command using the remote shell and copy the result back to this input box without submitting it.")
                    Button("Ctrl") { workspace.controlModifier.toggle() }.tint(workspace.controlModifier ? .orange : .mint)
                        .buttonStyle(.bordered).accessibilityAddTraits(workspace.controlModifier ? .isSelected : [])
                    key("Ctrl-C", "\u{3}")
                    key("↑", "\u{1b}[A"); key("↓", "\u{1b}[B"); key("←", "\u{1b}[D"); key("→", "\u{1b}[C")
                    key("Enter", "\r")
                }.font(.system(.caption, design: .monospaced)).disabled(!workspace.isConnected || workspace.sending)
              }
              if keyboardVisible {
                  Button {
                      workspace.directInput = false
                      composerFocused = false
                      UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                  } label: { Image(systemName: "keyboard.chevron.compact.down") }
                      .buttonStyle(.bordered).accessibilityLabel("Hide keyboard")
              }
            }
            if !workspace.directInput {
                if let hint = workspace.completionHint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Message or command…", text: $workspace.draft, axis: .vertical)
                        .lineLimit(1...6).font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($composerFocused)
                        .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    Button {
                        follow = true; liveToken += 1
                        Task { await workspace.sendDraft() }
                    } label: {
                        Image(systemName: workspace.sending ? "ellipsis" : "arrow.up").font(.headline)
                            .frame(width: 42, height: 42).background(.mint, in: Circle()).foregroundStyle(.black)
                    }
                    .accessibilityLabel("Send to \(window.name)")
                    .disabled(workspace.draft.isEmpty || workspace.sending || !workspace.isConnected || workspace.busy)
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
    }
    private func key(_ title: String, _ value: String) -> some View {
        Button(title) { sendDirect(Data(value.utf8)) }.buttonStyle(.bordered)
    }
    private func sendDirect(_ data: Data) {
        Task { await workspace.sendKey(data) }
    }
    private func updateViewport(_ size: CGSize) {
        let font = UIFont.monospacedSystemFont(ofSize: workspace.fontSize, weight: .regular)
        let width = ("W" as NSString).size(withAttributes: [.font: font]).width
        workspace.updateViewport(columns: Int(max(1, size.width - 2) / max(1, width)), rows: Int(size.height / max(1, ceil(font.lineHeight))))
    }
}

private struct HostTrustView: View {
    let challenge: HostKeyChallenge
    let approve: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(challenge.previousFingerprint == nil ? "First connection" : "Host key changed", systemImage: "checkmark.shield")
                    Text(challenge.endpoint).font(.headline)
                    Text(challenge.previousFingerprint == nil ? "Compare this fingerprint with the host before trusting it on this device." : "The host is presenting a different key. Verify why it changed before replacing the trusted key.")
                }
                Section("Presented fingerprint") {
                    Text(challenge.fingerprint).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                if let previous = challenge.previousFingerprint {
                    Section("Previously trusted fingerprint") { Text(previous).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                }
                Button(challenge.previousFingerprint == nil ? "Trust and reconnect" : "Replace trusted key and reconnect") { dismiss(); approve() }
                    .foregroundStyle(challenge.previousFingerprint == nil ? .mint : .orange)
            }
            .navigationTitle("Verify SSH host")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct SmartContent: View {
    let capture: String
    let fontSize: Double
    @Binding var follow: Bool
    let liveToken: Int
    var body: some View {
        BottomFollowingContent(follow: $follow, liveToken: liveToken) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SmartPresentation.blocks(from: capture)) { block in
                        // Smart always wraps locally, including shell columns,
                        // long paths, tables, and code. Original preserves grids.
                        StyledTerminalLabel(text: block.styledText, fontSize: fontSize)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, block.kind == .fixed ? 4 : 0)
                    }
                }.padding(.horizontal, 14).padding(.top, 14).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ConversationContent: View {
    let capture: String
    let fontSize: Double
    @Binding var follow: Bool
    let liveToken: Int
    var body: some View {
        BottomFollowingContent(follow: $follow, liveToken: liveToken) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("A view of the terminal, including unrecognized output. Use Terminal for interactive prompts.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(CodexPresentation.blocks(from: capture)) { block in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(block.role == .user ? "YOU" : block.role == .assistant ? "CODEX" : "TERMINAL")
                                .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.mint)
                            StyledTerminalLabel(text: block.styledText, fontSize: fontSize)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14).background(block.role == .user ? Color.mint.opacity(0.10) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                    }
                }.padding(.horizontal, 14).padding(.top, 14).fixedSize(horizontal: false, vertical: true)
        }
    }
}
