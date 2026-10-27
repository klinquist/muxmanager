import SwiftUI
import MuxCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var editingProfile: ConnectionProfile?
    @State private var showLicenses = false
    @State private var showSyncDiagnostics = false
    @State private var diagnosticWorkspace: HostWorkspace?
    @State private var managementRequest: ManagementRequest?

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $preferredColumn) {
            List {
                Section {
                    ForEach(library.visibleProfiles) { profile in
                      VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            Button { model.open(profile) } label: {
                              HStack(spacing: 12) {
                                Image(systemName: profile.bastionID == nil ? "server.rack" : "point.3.connected.trianglepath.dotted")
                                    .foregroundStyle(.mint)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.name).font(.headline).foregroundStyle(.primary)
                                    Text("\(profile.username)@\(profile.hostname)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                              }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                            }.buttonStyle(.plain)
                            if let workspace = model.workspaces[profile.id] {
                                HostConnectionControl(workspace: workspace) { model.open(profile) }
                            } else {
                                Button("Connect") { model.open(profile) }
                                    .font(.caption.weight(.medium)).buttonStyle(.borderless)
                            }
                        }
                        if let workspace = model.workspaces[profile.id] {
                            HostConnectionProgress(workspace: workspace)
                        }
                      }
                        .contextMenu {
                            Button("Edit connection", systemImage: "pencil") { editingProfile = profile }
                            Button("Disconnect", systemImage: "network.slash") { Task { await model.workspaces[profile.id]?.disconnect() } }
                            Button("Connection diagnostics", systemImage: "stethoscope") { diagnosticWorkspace = model.workspaces[profile.id] }
                                .disabled(model.workspaces[profile.id] == nil)
                            Button("Delete connection", systemImage: "trash", role: .destructive) {
                                Task {
                                    await model.workspaces[profile.id]?.disconnect()
                                    do { try library.remove(profile) } catch { library.error = error.localizedDescription }
                                }
                            }
                        }
                    }
                } header: { Label("Hosts", systemImage: "network") }

                if let workspace = model.activeWorkspace {
                    WindowSidebar(workspace: workspace, selected: {
                        preferredColumn = .detail
                        if UIDevice.current.userInterfaceIdiom == .phone { visibility = .detailOnly }
                    }, manage: { action in managementRequest = ManagementRequest(workspace: workspace, action: action) })
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Mux Manager")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if let workspace = model.activeWorkspace {
                            Button("Connection diagnostics", systemImage: "stethoscope") { diagnosticWorkspace = workspace }
                        }
                        Button("Open source licenses", systemImage: "doc.text") { showLicenses = true }
                        Button("iCloud diagnostics", systemImage: "icloud") { showSyncDiagnostics = true }
                        Link("Support", destination: URL(string: "https://klinquist.github.io/muxmanager/support/")!)
                        Link("Privacy policy", destination: URL(string: "https://klinquist.github.io/muxmanager/privacy/")!)
                        Link("Source code", destination: URL(string: "https://github.com/klinquist/muxmanager")!)
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Info")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add connection", systemImage: "plus") { editingProfile = ConnectionProfile() }
                }
            }
            .overlay {
                if library.visibleProfiles.isEmpty {
                    ContentUnavailableView {
                        Label("Your windows, anywhere", systemImage: "terminal")
                    } description: {
                        if library.lastSyncError != nil {
                            Text("iCloud could not sync your saved connections. Open Info → iCloud diagnostics for details. You can still add a host on this device.")
                        } else {
                            Text("Add a host to connect over SSH and browse its tmux windows.")
                        }
                    } actions: {
                        Button("Add connection") { editingProfile = ConnectionProfile() }.buttonStyle(.borderedProminent)
                    }.allowsHitTesting(true)
                }
            }
        } detail: {
            if let workspace = model.activeWorkspace {
                WorkspaceView(workspace: workspace, returnToWindows: {
                    preferredColumn = .sidebar
                    visibility = .all
                }).id(workspace.id)
            } else {
                ContentUnavailableView("Choose a host", systemImage: "terminal", description: Text("Connect to your existing tmux windows without changing their size."))
                    .navigationTitle("Mux Manager")
            }
        }
        .task {
            #if DEBUG
            if let scene = LibraryStore.screenshotScene {
                if scene == "connection" { editingProfile = library.visibleProfiles.first }
                else if scene != "hosts" && scene != "connecting-hosts" {
                    preferredColumn = .detail
                    if UIDevice.current.userInterfaceIdiom == .phone { visibility = .detailOnly }
                }
                if scene.hasPrefix("history") {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    HistoryScrollValidation.writeReport()
                }
                if scene.hasPrefix("copy"), let workspace = model.activeWorkspace {
                    try? await Task.sleep(for: .seconds(2))
                    await CopySelectionValidation.run(workspace: workspace)
                }
            }
            #endif
        }
        .sheet(item: $editingProfile) { profile in ConnectionEditor(profile: profile) }
        .sheet(isPresented: $showLicenses) { OpenSourceLicensesView() }
        .sheet(isPresented: $showSyncDiagnostics) { CloudSyncDiagnosticsView() }
        .sheet(item: $diagnosticWorkspace) { ConnectionDiagnosticsView(workspace: $0) }
        .sheet(item: $managementRequest) { request in
            ManagementSheet(workspace: request.workspace, action: request.action) { managementRequest = nil }
        }
        .alert("Mux Manager", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(library.error ?? "") }
    }
}

struct CloudSyncDiagnosticsView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(library.syncDiagnostics)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("iCloud diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(copied ? "Copied" : "Copy report") {
                        UIPasteboard.general.string = library.syncDiagnostics; copied = true
                    }
                }
            }
        }
    }
}

struct ConnectionDiagnosticsView: View {
    @ObservedObject var workspace: HostWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var refreshing = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(workspace.profile.name).font(.headline)
                    Spacer()
                    Button(refreshing ? "Refreshing…" : "Refresh") {
                        refreshing = true
                        Task { await workspace.refreshDiagnostics(); refreshing = false; copied = false }
                    }.disabled(refreshing || !workspace.isConnected)
                    Button("Clear") { workspace.clearDiagnostics(); copied = false }
                }.padding(.horizontal)
                Text("Includes hostnames, usernames, paths, and tmux names. Passwords, private keys, terminal contents, and submitted commands are excluded. Logs stay in memory until you copy them.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                ScrollView {
                    Text(workspace.diagnosticReport)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).padding()
                }
            }
            .navigationTitle("Connection diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(copied ? "Copied" : "Copy log", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = workspace.diagnosticReport; copied = true
                    }
                }
            }
        }
    }
}

private struct OpenSourceLicensesView: View {
    @Environment(\.dismiss) private var dismiss
    private var notices: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "License information is unavailable in this build." }
        return text
    }
    var body: some View {
        NavigationStack {
            ScrollView { Text(notices).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding() }
                .navigationTitle("Open source licenses")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct WindowSidebar: View {
    @ObservedObject var workspace: HostWorkspace
    var selected: () -> Void
    var manage: (ManagementAction) -> Void
    var body: some View {
      if workspace.isConnected {
        Section {
            HStack {
                Circle().fill(workspace.isConnected ? .mint : .orange).frame(width: 6, height: 6)
                Text(workspace.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            }
            if workspace.sessions.count > 1 || (workspace.selectedSessionID == nil && !workspace.sessions.isEmpty) {
                Picker("Session (\(workspace.sessions.count))", selection: Binding(get: { workspace.selectedSessionID ?? "" }, set: { value in Task { await workspace.selectSession(value) } })) {
                    Text("Choose session").tag("")
                    ForEach(workspace.sessions) { Text($0.name).tag($0.id) }
                }.pickerStyle(.menu).disabled(workspace.busy || !workspace.isConnected)
                if workspace.selectedSessionID == nil && workspace.isConnected {
                    Text("Choose a session to see its windows.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(workspace.windows) { window in
                Button {
                    Task { await workspace.selectWindow(window.id); selected() }
                } label: {
                    HStack {
                        Image(systemName: window.command.lowercased().contains("codex") ? "sparkle" : "terminal")
                        Text(window.name).lineLimit(1)
                        Spacer()
                        if window.id == workspace.selectedWindowID { Image(systemName: "checkmark").font(.caption.bold()) }
                    }.foregroundStyle(window.id == workspace.selectedWindowID ? .mint : .primary)
                }.disabled(workspace.busy)
            }
            Button("New window", systemImage: "plus.rectangle") { manage(.newWindow) }.disabled(workspace.selectedSessionID == nil)
            Button("New session", systemImage: "plus.rectangle.on.folder") { manage(.newSession) }
        } header: { Text(workspace.profile.name) }
      }
    }
}

private struct HostConnectionProgress: View {
    @ObservedObject var workspace: HostWorkspace
    var body: some View {
        if workspace.isEstablishingConnection {
            HStack(alignment: .top, spacing: 8) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(workspace.statusText)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.bottom, 4)
        }
    }
}

private struct HostConnectionControl: View {
    @ObservedObject var workspace: HostWorkspace
    let connect: () -> Void
    private var label: String {
        switch workspace.state {
        case .connected: return "Disconnect"
        case .connecting: return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        case .disconnected, .failed: return "Connect"
        }
    }
    var body: some View {
        Button {
            if workspace.isConnected { Task { await workspace.disconnect() } }
            else { connect() }
        } label: {
            HStack(spacing: 5) {
                if workspace.isConnected { Circle().fill(.mint).frame(width: 5, height: 5) }
                Text(label).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(.caption.weight(.medium)).buttonStyle(.borderless)
        .disabled(!workspace.isConnected && !workspace.canConnect)
        .accessibilityLabel("\(label) \(workspace.profile.name)")
    }
}

private struct ManagementRequest: Identifiable {
    let id = UUID()
    let workspace: HostWorkspace
    let action: ManagementAction
}

enum ManagementAction: String, Identifiable {
    case newWindow = "New window", newSession = "New session", renameWindow = "Rename window", renameSession = "Rename session"
    var id: String { rawValue }
}

struct ManagementSheet: View {
    @ObservedObject var workspace: HostWorkspace
    let action: ManagementAction
    let onClose: () -> Void
    @State private var name = ""
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form { TextField("Name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(saving) }
                .navigationTitle(action.rawValue)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "Saving…" : "Save") {
                            guard !saving else { return }
                            saving = true
                            Task {
                                switch action {
                                case .newWindow: await workspace.createWindow(name)
                                case .newSession: await workspace.createSession(name)
                                case .renameWindow: await workspace.renameWindow(name)
                                case .renameSession: await workspace.renameSession(name)
                                }
                                onClose()
                            }
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.busy || saving)
                    }
                }
        }.presentationDetents([.medium]).interactiveDismissDisabled(saving)
    }
}
