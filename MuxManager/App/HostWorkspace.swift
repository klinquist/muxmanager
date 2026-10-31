import Foundation
import Combine
#if DEBUG
import UIKit
#endif
import MuxCore

@MainActor
final class HostWorkspace: ObservableObject, Identifiable {
    enum State: Equatable { case disconnected, connecting, connected, disconnecting, failed(String) }
    let id: UUID
    @Published var profile: ConnectionProfile
    @Published private(set) var state: State = .disconnected {
        didSet { if oldValue != state { record("state", stateText) } }
    }
    @Published private(set) var diagnostics = DiagnosticBuffer()
    @Published private(set) var connectionProgress: String?
    @Published private(set) var sessions: [RemoteSession] = []
    @Published private(set) var windows: [RemoteWindow] = []
    @Published private(set) var selectedSessionID: String?
    @Published private(set) var selectedWindowID: String?
    @Published private(set) var closedWindowRevision = 0
    @Published private(set) var notificationFocusRevision = 0
    @Published private(set) var displayMode: DisplayMode = .smart
    @Published var conversation = false
    @Published private(set) var terminalMode = false
    @Published var directInput = false
    @Published var controlModifier = false
    @Published var fontSize: Double = 14
    @Published var error: String?
    @Published var challenge: HostKeyChallenge?
    @Published private(set) var busy = false
    @Published private(set) var sending = false
    @Published private(set) var joinedCapture = ""
    @Published private(set) var terminalCapture = ""
    @Published private(set) var snapshotRevision = 0
    @Published private(set) var inputRevision = 0
    @Published private(set) var completionHint: String?
    @Published private(set) var remoteColumns = 80
    @Published private(set) var remoteRows = 24
    @Published private(set) var terminalLiveRow = 0
    @Published var draft = "" {
        didSet {
            completionHint = nil
            guard let selectedWindowID else { return }
            drafts[selectedWindowID] = draft
            draftSaveTask?.cancel()
            draftSaveTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                self?.persistDrafts()
            }
        }
    }
    private let library: LibraryStore
    private let transport = SSHTransport()
    private var control: ControlChannel?
    private var pollTask: Task<Void, Never>?
    private var pollingGeneration = UUID()
    private var drafts: [String: String] = [:]
    private var commandHistories: [String: CommandHistory] = [:]
    private var lease: ResizeLease?
    private var serverIdentity = ""
    private var dirty = true
    private var refreshInProgress = false
    private var viewport = (columns: 44, rows: 25)
    private var fittedViewport: (columns: Int, rows: Int)?
    private var connectionGeneration = UUID()
    private var connectionSetupGeneration: UUID?
    private(set) var connectionIntent = UUID()
    private var isBackgrounded = false
    private var backgroundGeneration = UUID()
    private var backgroundPreparation: (id: UUID, task: Task<Void, Never>)?
    private var resumingFromBackground = false
    private var backgroundOutputPaused = false
    private var attachmentGeneration = UUID()
    private var inputTail: Task<Void, Never>?
    private var draftSaveTask: Task<Void, Never>?
    private struct IncompleteCompletion {
        let prompt: ShellCompletionScreen
        let draft: String
    }
    private var incompleteCompletions: [String: IncompleteCompletion] = [:]
    private var applicationCursorKeys = false
    private var lastSessionLines: [String]?
    private var lastWindowResult: (session: String, lines: [String])?
    private var lastSessionFailure: String?
    private var lastWindowFailure: String?
    private var reconnectSessionID: String?
    private var reconnectWindowID: String?
    private var captureDiagnostics = "No terminal capture yet"
    private var lastCaptureSignature: String?
    private var attentionEnabled = false
    private var attentionRuntimeAvailable = true
    private var attentionTask: Task<Void, Never>?
    private var attentionEpoch = UUID()
    private var attentionTracker = CodexAttentionTracker()
    private var attentionHandler: ((CodexPaneTarget, CodexAttentionState) -> Void)?
    private let attentionClockStart = ContinuousClock.now
    private var attentionTime: TimeInterval {
        let duration = attentionClockStart.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    init(profile: ConnectionProfile, library: LibraryStore) {
        self.id = profile.id; self.profile = profile; self.library = library
        drafts = library.readLocal([String: String].self, name: "drafts-\(id).json") ?? [:]
        lease = library.readLocal(ResizeLease.self, name: "resize-\(id).json")
        transport.diagnostic = { [weak self] message in self?.record("ssh", message) }
    }
    #if DEBUG
    /// Deterministic sample data rendered by the production views, without SSH.
    func configureScreenshot(scene: String) {
        if scene.hasPrefix("connecting") {
            state = .connecting
            connectionProgress = "Jump host Gateway connected. Connecting to Build server…"
            sessions = []; windows = []; selectedSessionID = nil; selectedWindowID = nil
            return
        }
        state = .connected
        sessions = [RemoteSession(id: "$1", name: "work"), RemoteSession(id: "$2", name: "personal")]
        selectedSessionID = "$1"
        windows = [
            RemoteWindow(id: "@1", sessionID: "$1", name: "api-refactor", index: 0, paneID: "%1", columns: 120, rows: 36, command: "codex"),
            RemoteWindow(id: "@2", sessionID: "$1", name: "test-suite", index: 1, paneID: "%2", columns: 120, rows: 36, command: "zsh"),
            RemoteWindow(id: "@3", sessionID: "$1", name: "deploy", index: 2, paneID: "%3", columns: 120, rows: 36, command: "zsh"),
            RemoteWindow(id: "@4", sessionID: "$1", name: "service-logs", index: 3, paneID: "%4", columns: 120, rows: 36, command: "tail"),
            RemoteWindow(id: "@5", sessionID: "$1", name: "system-monitor", index: 4, paneID: "%5", columns: 120, rows: 36, command: "htop")
        ]
        selectedWindowID = ["hosts", "connection"].contains(scene) ? nil : "@1"
        remoteColumns = scene == "fit" ? 44 : 120
        remoteRows = 36
        displayMode = ["original", "history-original", "copy-original", "input-original"].contains(scene) ? .original : (scene == "fit" ? .fit : .smart)
        if scene.hasPrefix("input") {
            commandHistories["@1"] = CommandHistory()
            commandHistories["@1"]?.record("ls -la")
            commandHistories["@1"]?.record("echo first\necho second")
            draft = "unfinished"
        }
        if scene == "copy-conversation" { conversation = true }
        fontSize = UIDevice.current.userInterfaceIdiom == .pad ? 22 : 16
        if scene == "original" { fontSize = UIDevice.current.userInterfaceIdiom == .pad ? 18 : 13 }
        joinedCapture = """
        \u{1b}[38;5;244m$ git status --short
         M Sources/API/RequestHandler.swift
         M Sources/API/Validation.swift
         M Tests/API/RequestHandlerTests.swift

        $ swift test
        Building for debugging...
        Build complete. (2.4s)
        Test Suite 'RequestHandlerTests' started
        Test Suite 'ValidationTests' started
        Test Suite 'ResponseTests' started
        Test Suite 'All tests' passed\u{1b}[0m

        \u{1b}[38;5;79m› Review the API changes and run the tests.\u{1b}[0m

        \u{1b}[1m• I reviewed the request handlers and found two places where error responses were inconsistent.\u{1b}[0m

        The handlers now return a consistent error shape, and validation failures include a useful message. Existing clients keep the same successful responses.

        \u{1b}[38;5;117m```swift
        struct APIError: Codable {
            let code: String
            let message: String
        }
        ```\u{1b}[0m

        \u{1b}[38;5;79m✓ Updated request validation
        ✓ Preserved existing response types
        ✓ All 42 tests passed\u{1b}[0m

        \u{1b}[1mReady for your review.\u{1b}[0m
        You can inspect the changes before committing.
        """
        if scene == "shell" || scene == "copy-updated" {
            if scene == "shell" { selectedWindowID = "@2" }
            joinedCapture = """
            dev@build % ls
            \u{1b}[34mApplications\u{1b}[0m         Config                  Documentation           Package.swift
            \u{1b}[34mSources\u{1b}[0m              README.md               Tests                   scripts
            application-configuration-development.json          command-line-completion-tests.swift
            averylongfilenamewithoutspaces1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.txt

            dev@build %
            """
        }
        if scene.hasPrefix("history") {
            joinedCapture = (1...2036).map { String(format: "\u{1b}[32mROW %04d\u{1b}[0m — retained terminal history for scrolling validation", $0) }.joined(separator: "\n")
        }
        if scene == "links" {
            joinedCapture = "\u{1b}[32m• Read the documentation.\u{1b}[0m\n\n🙂 https://example.com/docs?a=1&b=2#part\n\nOpen http://localhost:3000/test.\n\nMore details on a separate line."
        }
        let screen = scene == "original" ? """
        \u{1b}[1;38;5;79mPROJECT TASKS\u{1b}[0m  /workspace/api

        \u{1b}[48;5;29;97m  › Review request validation                 ready       api-refactor       \u{1b}[0m
            Run integration tests                   passed      test-suite
            Inspect deployment changes              pending     deploy
            Check service output                    live        service-logs

        \u{1b}[38;5;117mDetails\u{1b}[0m
        Error responses now use a consistent shape.
        42 tests passed. No failing checks.

        \u{1b}[38;5;117mRecent activity\u{1b}[0m
        09:38  Request handler review completed
        09:38  Validation paths checked
        09:39  Response types checked
        09:39  Integration tests completed
        09:40  Changes ready for review

        \u{1b}[38;5;79mChecks\u{1b}[0m
        [passed] Request validation
        [passed] Authentication errors
        [passed] Pagination responses
        [passed] Unicode input
        [passed] Missing fields
        [passed] Existing API clients

        \u{1b}[38;5;117mSummary\u{1b}[0m
        3 files changed
        42 checks passed
        0 failing checks

        \u{1b}[38;5;244m↑/↓ select    Enter open    q quit\u{1b}[0m
        """ : joinedCapture
        terminalCapture = "\u{1b}c" + screen.replacingOccurrences(of: "\n", with: "\r\n") + "\u{1b}[?25l"
        terminalLiveRow = screen.components(separatedBy: "\n").count - 1
        snapshotRevision += 1
    }
    #endif

    var selectedWindow: RemoteWindow? { windows.first { $0.id == selectedWindowID } }
    var isConnected: Bool { state == .connected }
    var isEstablishingConnection: Bool { connectionProgress != nil && (state == .connecting || isConnected) }
    var shouldRetainInBackground: Bool { isConnected || state == .connecting || resumingFromBackground }
    var canConnect: Bool {
        switch state {
        case .disconnected, .failed: return true
        case .connecting, .connected, .disconnecting: return false
        }
    }
    var statusText: String {
        if isEstablishingConnection, let connectionProgress { return connectionProgress }
        return stateText
    }
    private var stateText: String {
        switch state {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting…"
        case .failed(let message): return message
        }
    }

    var diagnosticReport: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let bastion = profile.bastionID.flatMap { id in library.visibleProfiles.first { $0.id == id } }
        let route = bastion.map { "\($0.name) (\($0.username)@\($0.hostname):\($0.port))" }
            ?? (profile.bastionID == nil ? "direct" : "missing saved bastion")
        return """
        Mux Manager \(version) (\(build)) — connection diagnostics
        \(ProcessInfo.processInfo.operatingSystemVersionString)
        Target: \(profile.name) (\(profile.username)@\(profile.hostname):\(profile.port)); route: \(route)
        State: \(statusText)
        Sessions: \(sessions.count); selected session: \(selectedSessionID ?? "none")
        Windows in selected session: \(windows.count); selected window: \(selectedWindowID ?? "none")
        Capture: \(captureDiagnostics)
        Includes host/user identifiers, paths, and tmux session/window names.
        No passwords, private keys, terminal contents, or submitted input are recorded.

        \(diagnostics.text)
        """
    }
    func clearDiagnostics() { diagnostics.clear(); record("diagnostics", "Log cleared") }
    func refreshDiagnostics() async {
        record("diagnostics", "Refresh requested; sessions=\(sessions.count), selected=\(selectedSessionID ?? "none"), windows=\(windows.count)")
        guard isConnected, !busy else { record("diagnostics", "Connect first and wait for any pending operation before refreshing"); return }
        await transport.collectEnvironmentDiagnostics()
        do {
            try await discoverSessions(forceLog: true)
            try await discoverWindows(forceLog: true)
            if selectedWindow != nil { try await refreshSnapshot(forceLog: true) }
        } catch { record("diagnostics", "Discovery refresh failed: \(error.localizedDescription)") }
    }
    private func record(_ category: String, _ message: String) { diagnostics.append(message, category: category) }
    private func reportConnectionProgress(_ message: String) {
        connectionProgress = message
        record("progress", message)
    }
    private func recordDiscovery(_ label: String, command: String, lines: [String], parsed: Int) {
        record("tmux", "\(label) via \(control == nil ? "SSH exec (-u)" : "control mode (-u)"): \(command)")
        record("tmux", "\(label): received \(lines.count) lines; parsed \(parsed) records")
        for (index, line) in lines.prefix(100).enumerated() { record("tmux", "\(label)[\(index)]: \(line)") }
        if lines.count > 100 { record("tmux", "\(lines.count - 100) additional discovery rows omitted") }
        if parsed < lines.count { record("tmux", "WARNING: \(lines.count - parsed) discovery rows did not match the expected tab-separated format") }
    }

    func connect(automatically: Bool = false) async {
        guard canConnect else { return }
        stopAttentionMonitoring()
        if !automatically { connectionIntent = UUID(); isBackgrounded = false }
        state = .connecting; error = nil; challenge = nil
        backgroundOutputPaused = false
        lastSessionLines = nil; lastWindowResult = nil; lastSessionFailure = nil; lastWindowFailure = nil
        record("connection", "New attempt for \(profile.name)")
        let generation = UUID(); connectionGeneration = generation
        connectionSetupGeneration = generation
        reportConnectionProgress("Preparing connection to \(profile.name)…")
        defer {
            if connectionSetupGeneration == generation { connectionSetupGeneration = nil }
            if connectionGeneration == generation { connectionProgress = nil }
        }
        do {
            await transport.disconnect(); control = nil
            try await transport.connect(profile: profile, library: library, onProgress: { [weak self] message in
                guard self?.connectionGeneration == generation else { return }
                self?.reportConnectionProgress(message)
            }) { [weak self] challenge in
                Task { @MainActor in
                    guard self?.connectionGeneration == generation else { return }
                    self?.record("ssh", "Host verification required for \(challenge.endpoint); changed key=\(challenge.previousFingerprint != nil)")
                    self?.challenge = challenge
                }
            }
            guard generation == connectionGeneration else { await transport.disconnect(); return }
            reportConnectionProgress("Inspecting tmux server…")
            await transport.collectEnvironmentDiagnostics()
            guard generation == connectionGeneration else { return }
            state = .connected
            reportConnectionProgress("Loading tmux sessions…")
            try await discoverSessions()
            if let session = sessions.first(where: { $0.id == (selectedSessionID ?? reconnectSessionID) }) ?? (sessions.count == 1 ? sessions.first : nil) {
                try await attach(session.id)
            } else if sessions.count > 1 {
                record("selection", "Found \(sessions.count) sessions. Waiting for the user to choose a session; windows are not listed until then.")
            } else {
                record("selection", "No sessions found on the default tmux server for this SSH user/environment")
            }
            connectionProgress = nil; connectionSetupGeneration = nil
            if isBackgrounded { await prepareForBackground(expectedIntent: connectionIntent) }
            if !isBackgrounded && !resumingFromBackground { startPolling() }
            startAttentionMonitoring()
        } catch {
            if generation == connectionGeneration { state = .failed(error.localizedDescription) }
        }
    }

    func trustAndReconnect(_ challenge: HostKeyChallenge) async {
        do {
            try library.secrets.write(Data(challenge.publicKey.utf8), account: "trust:\(challenge.endpoint)", synchronized: false)
            self.challenge = nil
            await disconnect()
            await connect()
        } catch { self.error = error.localizedDescription }
    }

    func disconnect(automatically: Bool = false) async {
        // Explicit Disconnect also cancels a pending automatic foreground resume.
        if !automatically { connectionIntent = UUID() }
        guard state != .disconnecting, state != .disconnected else { return }
        record("connection", "Disconnect requested")
        reconnectSessionID = selectedSessionID; reconnectWindowID = selectedWindowID
        state = .disconnecting
        connectionProgress = nil
        connectionGeneration = UUID(); attachmentGeneration = UUID(); pollTask?.cancel(); pollTask = nil
        stopAttentionMonitoring()
        draftSaveTask?.cancel(); persistDrafts()
        do { try await restoreSize() } catch {
            record("resize", "Restoration pending: \(error.localizedDescription)")
            self.error = "Resize restoration is pending: \(error.localizedDescription)"
        }
        await transport.disconnect(); control = nil
        backgroundOutputPaused = false
        windows = []; sessions = []; selectedWindowID = nil; selectedSessionID = nil
        captureDiagnostics = "No terminal capture yet"; lastCaptureSignature = nil
        joinedCapture = ""; terminalCapture = ""; terminalLiveRow = 0; snapshotRevision += 1
        draft = ""; directInput = false; controlModifier = false
        displayMode = .smart; fittedViewport = nil; state = .disconnected
    }

    func pauseForBackground() {
        isBackgrounded = true
        backgroundGeneration = UUID()
        pollingGeneration = UUID()
        draftSaveTask?.cancel(); persistDrafts()
        if shouldRetainInBackground {
            record("lifecycle", "Backgrounded; retaining SSH for up to 10 minutes, subject to iOS suspension and network availability")
        }
    }

    func unpauseAfterBackground() {
        isBackgrounded = false; attentionRuntimeAvailable = true
        startAttentionMonitoring()
    }

    func prepareForBackground(expectedIntent: UUID) async {
        let generation = backgroundGeneration
        // Authentication can finish while the app-level preparation is running.
        // Share that work so foregrounding waits for every output-pause command.
        while let previous = backgroundPreparation {
            await previous.task.value
            if previous.id == generation { return }
            if backgroundPreparation?.id == previous.id { backgroundPreparation = nil }
        }
        guard isBackgrounded, backgroundGeneration == generation, connectionIntent == expectedIntent else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.parkConnection(expectedIntent: expectedIntent, generation: generation)
        }
        backgroundPreparation = (generation, task)
        await task.value
        if backgroundPreparation?.id == generation { backgroundPreparation = nil }
    }

    private func parkConnection(expectedIntent: UUID, generation background: UUID) async {
        // Let an in-flight read finish. Cancelling a ControlChannel request can
        // close the channel to prevent response misassociation.
        await pollTask?.value
        guard isBackgrounded, backgroundGeneration == background, connectionIntent == expectedIntent else { return }
        pollTask = nil
        await inputTail?.value
        while isBackgrounded, backgroundGeneration == background, connectionIntent == expectedIntent, busy || sending {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard isBackgrounded, backgroundGeneration == background, connectionIntent == expectedIntent, isConnected else { return }
        let generation = connectionGeneration
        do {
            try await restoreSize()
            guard generation == connectionGeneration, isBackgrounded, backgroundGeneration == background else { return }
            if displayMode == .fit { displayMode = .original }
            if let control {
                _ = try await control.command("refresh-client -f \(TmuxCommand.quote("no-output"))")
                guard generation == connectionGeneration else { return }
                backgroundOutputPaused = true
            }
            persistDrafts()
            record("lifecycle", "Polling paused; app-owned Fit sizing restored; SSH remains open")
        } catch {
            record("lifecycle", "Background preparation: \(error.localizedDescription). Pending resize recovery remains saved.")
        }
    }

    func backgroundTimeExpired() {
        attentionRuntimeAvailable = false
        stopAttentionMonitoring()
        record("lifecycle", "iOS background runtime ended; leaving SSH parked and checking it on return")
    }

    func resumeFromBackground(forceReconnect: Bool) async {
        isBackgrounded = false
        attentionRuntimeAvailable = true
        resumingFromBackground = true
        defer { resumingFromBackground = false; startAttentionMonitoring() }
        let intent = connectionIntent
        await backgroundPreparation?.task.value
        guard !isBackgrounded, connectionIntent == intent else { return }
        // no-output suppresses pane notifications while parked; don't rely on a
        // new output event to make the selected pane eligible for capture again.
        dirty = true
        // An in-progress connection starts polling itself after discovery.
        if connectionSetupGeneration != nil && !forceReconnect { return }
        if isConnected && !forceReconnect {
            let generation = connectionGeneration
            do {
                if backgroundOutputPaused, let control {
                    _ = try await control.command("refresh-client -f \(TmuxCommand.quote("!no-output"))")
                    backgroundOutputPaused = false
                }
                guard !isBackgrounded, connectionIntent == intent, connectionGeneration == generation else { return }
                try await discoverSessions(forceLog: true)
                guard !isBackgrounded, connectionIntent == intent, connectionGeneration == generation else { return }
                try await discoverWindows(forceLog: true)
                try await refreshSnapshot(forceLog: true)
                guard !isBackgrounded, connectionIntent == intent, connectionGeneration == generation else { return }
                record("lifecycle", "Foreground check succeeded; reusing the existing SSH connection")
                startPolling()
                return
            } catch {
                guard !isBackgrounded, connectionIntent == intent else { return }
                record("lifecycle", "Retained connection is unavailable: \(error.localizedDescription); reconnecting")
            }
        } else if forceReconnect {
            record("lifecycle", "10-minute background retention elapsed; reconnecting")
        }
        guard !isBackgrounded, connectionIntent == intent else { return }
        await disconnect(automatically: true)
        guard !isBackgrounded, connectionIntent == intent else { return }
        await connect(automatically: true)
        if !isBackgrounded, connectionIntent == intent, isConnected { startPolling() }
    }

    func selectSession(_ id: String) async {
        guard !busy, !sending, isConnected else { return }; busy = true
        record("selection", "Session selected: \(id)")
        defer { busy = false }
        do { try await restoreSize(); try await attach(id) }
        catch { record("selection", "Session attachment failed: \(error.localizedDescription)"); self.error = error.localizedDescription }
    }

    private func attach(_ id: String) async throws {
        guard TmuxCommand.isID(id, prefix: "$") else { throw MuxError.message("Invalid session.") }
        if connectionSetupGeneration != nil {
            reportConnectionProgress("Opening tmux session \(sessions.first(where: { $0.id == id })?.name ?? id)…")
        }
        let connection = connectionGeneration
        let previousWindowID = selectedSessionID == id ? selectedWindowID : (reconnectSessionID == id ? reconnectWindowID : nil)
        control = nil
        let generation = UUID(); attachmentGeneration = generation
        let channel = try await transport.startControl(session: id, events: { [weak self] event in
            Task { @MainActor in
                guard self?.attachmentGeneration == generation else { return }
                self?.handle(event)
            }
        }, closed: { [weak self] message in
            Task { @MainActor in
                guard let self, self.attachmentGeneration == generation, self.isConnected else { return }
                self.state = .failed(message); self.pollTask?.cancel()
            }
        })
        guard connection == connectionGeneration, isConnected else { await channel.close(); throw CancellationError() }
        control = channel
        selectedSessionID = id; selectedWindowID = nil; displayMode = .smart; fittedViewport = nil
        let identity = try await command("display-message -p '#{pid}:#{start_time}:#{socket_path}'")
        guard connection == connectionGeneration, isConnected else { throw CancellationError() }
        serverIdentity = identity.joined(separator: "")
        record("tmux", "Attached session \(id); server identity=\(serverIdentity)")
        try await restoreSize()
        guard connection == connectionGeneration, isConnected else { throw CancellationError() }
        if connectionSetupGeneration != nil { reportConnectionProgress("Loading tmux windows…") }
        try await discoverWindows()
        if let selected = windows.first(where: { $0.id == previousWindowID }) ?? windows.first {
            if connectionSetupGeneration != nil { reportConnectionProgress("Loading window \(selected.name)…") }
            try await chooseWindow(selected.id)
        }
    }

    func selectWindow(_ id: String) async {
        guard isConnected, !busy, !sending, id != selectedWindowID else { return }; busy = true
        defer { busy = false }
        do { try await restoreSize(); try await chooseWindow(id) }
        catch { self.error = error.localizedDescription }
    }
    private func chooseWindow(_ id: String) async throws {
        guard windows.contains(where: { $0.id == id }) else { return }
        record("selection", "Window selected: \(id)")
        selectedWindowID = id; draft = drafts[id] ?? ""
        captureDiagnostics = "No terminal capture yet"; lastCaptureSignature = nil
        joinedCapture = ""; terminalCapture = ""; snapshotRevision += 1
        displayMode = .smart; fittedViewport = nil; dirty = true
        try await refreshSnapshot()
    }

    func setDisplayMode(_ mode: DisplayMode) async {
        guard mode != displayMode, !busy, !sending, selectedWindow != nil else { return }; busy = true
        let generation = connectionGeneration
        defer { busy = false }
        do {
            if displayMode == .fit { try await restoreSize() }
            guard generation == connectionGeneration, isConnected else { throw MuxError.message("The connection changed before resizing.") }
            if mode == .fit { try await fitWindow() }
            guard generation == connectionGeneration, isConnected else { return }
            displayMode = mode
            try await discoverWindows(); try await refreshSnapshot()
        } catch { self.error = error.localizedDescription }
    }

    func updateViewport(columns: Int, rows: Int) {
        viewport = (max(10, min(1000, columns)), max(5, min(1000, rows)))
        // Only the polling loop applies changes, coalescing keyboard/rotation animations.
    }

    private func fitWindow() async throws {
        guard let window = selectedWindow else { return }
        let generation = connectionGeneration
        let current = try await sizing(window.id)
        try Task.checkCancellation()
        guard generation == connectionGeneration, isConnected, !isBackgrounded else { throw MuxError.message("The connection changed or the app backgrounded before resizing.") }
        if let lease, !lease.mayRestore(current: current, serverIdentity: serverIdentity) {
            self.lease = nil; try persistLease(); fittedViewport = nil; displayMode = .original
            throw MuxError.message("The window was resized by another client. Fit mode has stopped; choose Fit device again to take control.")
        }
        let applied = WindowSizing(columns: viewport.columns, rows: viewport.rows, localPolicy: "manual")
        var record = ResizeLease(hostID: id, serverIdentity: serverIdentity, windowID: window.id,
                                 previous: lease?.previous ?? current, applied: applied, fallbackApplied: lease?.applied)
        // Save the intended lease before the remote mutation so abrupt suspension is recoverable.
        lease = record; try persistLease()
        _ = try await command("resize-window -t \(TmuxCommand.quote(window.id)) -x \(applied.columns) -y \(applied.rows)")
        guard generation == connectionGeneration, isConnected else { return }
        record.fallbackApplied = nil; lease = record; try persistLease()
        fittedViewport = (applied.columns, applied.rows); dirty = true
    }

    private func sizing(_ window: String) async throws -> WindowSizing {
        guard TmuxCommand.isID(window, prefix: "@") else { throw MuxError.message("Invalid window ID.") }
        let size = try await command("display-message -p -t \(TmuxCommand.quote(window)) '#{window_width} #{window_height}'")
        let fields = size.joined().split(separator: " ")
        guard fields.count == 2, let cols = Int(fields[0]), let rows = Int(fields[1]) else { throw MuxError.message("Could not read tmux window dimensions.") }
        let localPolicy = try await command("show-options -wqv -t \(TmuxCommand.quote(window)) window-size")
        let policy = localPolicy.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return WindowSizing(columns: cols, rows: rows, localPolicy: policy.isEmpty ? nil : policy)
    }

    private func restoreSize() async throws {
        guard let lease, !serverIdentity.isEmpty else { return }
        if lease.serverIdentity != serverIdentity { self.lease = nil; try persistLease(); return }
        let exists = try await command("list-windows -a -F '#{window_id}'")
        guard exists.contains(lease.windowID) else { self.lease = nil; try persistLease(); return }
        let current = try await sizing(lease.windowID)
        for text in lease.restorationCommands(current: current, serverIdentity: serverIdentity) { _ = try await command(text) }
        self.lease = nil; fittedViewport = nil; try persistLease()
    }

    private func persistLease() throws { try library.writeLocal(lease, name: "resize-\(id).json") }
    private func persistDrafts() {
        do { try library.writeLocal(drafts, name: "drafts-\(id).json") }
        catch { self.error = "Could not save draft: \(error.localizedDescription)" }
    }

    func setTerminalMode(_ enabled: Bool) {
        terminalMode = enabled
        if enabled { conversation = false }
        directInput = enabled && isConnected
        controlModifier = false
    }

    var isBrowsingCommandHistory: Bool {
        guard let selectedWindowID else { return false }
        return commandHistories[selectedWindowID]?.isBrowsing(draft) == true
    }

    func recallCommand(older: Bool) {
        guard !sending, !busy, let selectedWindowID else { return }
        var history = commandHistories[selectedWindowID] ?? CommandHistory()
        let recalled = older ? history.previous(from: draft) : history.next(from: draft)
        commandHistories[selectedWindowID] = history
        if let recalled { draft = recalled }
    }

    func sendDraft() async {
        guard !sending, !busy, isConnected, let window = selectedWindow, !draft.isEmpty else { return }
        let pane = window.paneID
        inputRevision += 1
        let text = draft; sending = true
        let generation = connectionGeneration
        defer { sending = false }
        do {
            await inputTail?.value
            guard generation == connectionGeneration, isConnected else { throw MuxError.message("The connection changed before submission.") }
            if let pending = incompleteCompletions[pane] {
                let current = try await readShellCompletionScreen(pane: pane)
                guard current.beforeCursor == pending.prompt.beforeCursor else {
                    throw MuxError.message("A completion is still on the remote command line. Inspect or cancel it using Terminal mode before sending this draft.")
                }
                incompleteCompletions.removeValue(forKey: pane)
            }
            try await paste(text, pane: pane, submit: true)
            commandHistories[window.id, default: CommandHistory()].record(text)
            if selectedWindowID == window.id, draft == text { draft = "" }
        } catch { self.error = "Send was not confirmed; the draft was kept. Check the terminal before sending again. \(error.localizedDescription)" }
    }

    func sendKey(_ bytes: Data) async {
        guard !bytes.isEmpty, !sending, !busy, isConnected, let pane = selectedWindow?.paneID else { return }
        inputRevision += 1
        var input = bytes
        if applicationCursorKeys, bytes.count == 3, bytes.starts(with: [27, 91]),
           let last = bytes.last, (65...68).contains(last) { input = Data([27, 79, last]) }
        if controlModifier {
            if bytes.count == 1, let first = bytes.first, (64...127).contains(first) { input = Data([first & 0x1f]) }
            controlModifier = false
        }
        let previous = inputTail
        let generation = connectionGeneration
        let task = Task { [weak self, input] in
            await previous?.value
            guard let self, self.connectionGeneration == generation, self.isConnected else { return }
            do {
                if input.count > 1, input.contains(10), let text = String(data: input, encoding: .utf8) {
                    try await self.paste(text, pane: pane, submit: false)
                } else { try await self.send(input, pane: pane) }
                if input == Data([3]) || input == Data([13]) {
                    let pending = self.incompleteCompletions.removeValue(forKey: pane)
                    if input == Data([13]), let pending, self.draft == pending.draft { self.draft = "" }
                }
            }
            catch { self.error = "Input was not confirmed. Reconnect and inspect the terminal. \(error.localizedDescription)" }
        }
        inputTail = task
        await task.value
    }

    /// Clipboard text is a paste even if it is only one character or newline.
    /// Keep it separate from key events so tmux can supply bracketed-paste
    /// markers, and never append an extra Enter or apply the Ctrl toggle.
    func pasteIntoTerminal(_ text: String, windowID: String, connectionIntent: UUID) async {
        guard !text.isEmpty, !sending, !busy, isConnected, terminalMode,
              self.connectionIntent == connectionIntent,
              let window = selectedWindow, window.id == windowID else { return }
        inputRevision += 1; controlModifier = false
        let previous = inputTail
        let generation = connectionGeneration
        let pane = window.paneID
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.connectionGeneration == generation, self.isConnected,
                  self.connectionIntent == connectionIntent, self.terminalMode,
                  self.selectedWindowID == windowID, self.selectedWindow?.paneID == pane else { return }
            do { try await self.paste(text, pane: pane, submit: false) }
            catch { self.error = "Paste was not confirmed. Check the terminal before pasting again. \(error.localizedDescription)" }
        }
        inputTail = task
        await task.value
    }

    func completeInShell() async {
        guard !sending, !busy, isConnected, let pane = selectedWindow?.paneID else { return }
        if terminalMode || directInput { await sendKey(Data([9])); return }
        let text = draft
        guard !text.contains(where: \.isNewline),
              text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
            error = "Shell completion needs a single command line without control characters. Your draft has been kept."
            return
        }
        sending = true; busy = true; inputRevision += 1; controlModifier = false
        completionHint = nil
        let generation = connectionGeneration
        defer { sending = false; busy = false }
        do {
            await inputTail?.value
            let prompt = try await readShellCompletionScreen(pane: pane)
            if let pending = incompleteCompletions[pane] {
                guard prompt.beforeCursor == pending.prompt.beforeCursor else {
                    throw MuxError.message("The previous completion is still on the remote line. Inspect or cancel it using Terminal mode first.")
                }
                incompleteCompletions.removeValue(forKey: pane)
            }
            guard generation == connectionGeneration, isConnected, selectedWindow?.paneID == pane else { throw CancellationError() }
            // The temporary edit must start at an empty, recognizable shell prompt.
            // Never clear an existing command or send Enter as part of completion.
            guard prompt.resemblesEmptyPrompt else {
                throw MuxError.message("Could not identify an empty shell prompt. Native completion is best effort; use Terminal mode for this prompt.")
            }
            incompleteCompletions[pane] = IncompleteCompletion(prompt: prompt, draft: text)
            if !text.isEmpty { try await paste(text, pane: pane, submit: false) }
            guard generation == connectionGeneration, isConnected, selectedWindow?.paneID == pane else { throw CancellationError() }
            try await send(Data([9]), pane: pane)
            var previous: String?, completed: String?
            for _ in 0..<8 {
                try await Task.sleep(nanoseconds: 100_000_000)
                let screen = try await readShellCompletionScreen(pane: pane)
                if let candidate = screen.completedText(after: prompt) {
                    if previous == candidate { completed = candidate; break }
                    previous = candidate
                }
            }
            guard let completed else {
                throw MuxError.message("The shell's completion could not be read safely. Check the terminal using Terminal mode; your draft is kept.")
            }
            guard generation == connectionGeneration, isConnected, selectedWindow?.paneID == pane else { throw CancellationError() }
            if draft == text { draft = completed }
            // zsh/bash's normal line editor clears our temporary single-line input.
            // Confirm restoration so Send cannot paste a second copy of the command.
            try await send(Data([21]), pane: pane)
            var restored = false
            for _ in 0..<4 {
                try await Task.sleep(nanoseconds: 80_000_000)
                let current = try await readShellCompletionScreen(pane: pane)
                if current.beforeCursor == prompt.beforeCursor { restored = true; break }
            }
            guard restored else {
                throw MuxError.message("The completed text is in the composer, but the remote line could not be cleared. Check it using Terminal mode before sending.")
            }
            incompleteCompletions.removeValue(forKey: pane)
            if completed == text, draft == completed { completionHint = "No unique completion. Type more characters and try Tab again." }
            // Keep the existing composer and its keyboard focus throughout.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func readShellCompletionScreen(pane: String) async throws -> ShellCompletionScreen {
        let format = "#{pane_current_command}\t#{cursor_x}\t#{cursor_y}\t#{pane_width}\t#{pane_in_mode}\t#{alternate_on}"
        let rows = try await command("display-message -p -t \(TmuxCommand.quote(pane)) \(TmuxCommand.quote(format))")
        let fields = rows.joined().components(separatedBy: "\t")
        guard fields.count == 6,
              ["zsh", "bash"].contains((fields[0] as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))),
              let x = Int(fields[1]), let y = Int(fields[2]), let columns = Int(fields[3]),
              (0...1000).contains(y), fields[4] == "0", fields[5] == "0" else {
            throw MuxError.message("Native completion currently supports recognizable zsh/bash prompts. Use Terminal mode for other shells or interactive completion tools.")
        }
        let lines = try await command("capture-pane -pJ -S 0 -E \(y) -t \(TmuxCommand.quote(pane))")
        guard let line = lines.last,
              let screen = ShellCompletionScreen(joinedLine: line, columns: columns, cursorX: x) else {
            throw MuxError.message("Could not read the shell cursor safely. Use Terminal mode for this completion.")
        }
        return screen
    }
    private func send(_ bytes: Data, pane: String) async throws {
        guard let channel = control, isConnected else { throw MuxError.message("Reconnect before sending input.") }
        for text in try TmuxCommand.sendBytes(bytes, pane: pane) { _ = try await channel.command(text) }
        dirty = true
    }
    private func paste(_ text: String, pane: String, submit: Bool) async throws {
        guard let channel = control, isConnected else { throw MuxError.message("Reconnect before sending input.") }
        let buffer = "mux-manager-" + UUID().uuidString
        do {
            for command in try TmuxCommand.pasteCommands(text, pane: pane, buffer: buffer, submit: submit) {
                _ = try await channel.command(command)
            }
        } catch {
            // Best effort only: a dropped connection can leave a uniquely named buffer behind.
            _ = try? await channel.command("delete-buffer -b \(TmuxCommand.quote(buffer))")
            throw error
        }
        dirty = true
    }

    func createSession(_ name: String) async {
        guard !busy, !sending, isConnected, !name.isEmpty else { return }; busy = true
        defer { busy = false }
        do {
            _ = try await transport.tmux("new-session -d -s \(TmuxCommand.shellQuote(name))")
            try await discoverSessions()
            if let session = sessions.first(where: { $0.name == name }) { try await restoreSize(); try await attach(session.id) }
        } catch { self.error = error.localizedDescription }
    }
    func createWindow(_ name: String) async {
        guard !busy, !sending, let session = selectedSessionID else { return }; busy = true
        defer { busy = false }
        do {
            let result = try await command("new-window -d -P -F '#{window_id}' -t \(TmuxCommand.quote(session + ":")) -n \(TmuxCommand.quote(name))")
            try await discoverWindows()
            if let id = result.first { try await restoreSize(); try await chooseWindow(id) }
        } catch { self.error = error.localizedDescription }
    }
    func renameWindow(_ name: String) async {
        guard let id = selectedWindowID else { return }
        do { _ = try await command("rename-window -t \(TmuxCommand.quote(id)) \(TmuxCommand.quote(name))"); try await discoverWindows() }
        catch { self.error = error.localizedDescription }
    }
    func renameSession(_ name: String) async {
        guard let id = selectedSessionID else { return }
        do { _ = try await command("rename-session -t \(TmuxCommand.quote(id)) \(TmuxCommand.quote(name))"); try await discoverSessions() }
        catch { self.error = error.localizedDescription }
    }

    private func command(_ text: String) async throws -> [String] {
        if let control { return try await control.command(text) }
        let result = try await transport.tmux(text)
        var lines = result.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
    private func discoverSessions(forceLog: Bool = false) async throws {
        let generation = connectionGeneration
        let request = "list-sessions -F \(TmuxCommand.quote(TmuxCommand.sessionFormat))"
        do {
            let lines = try await command(request)
            guard generation == connectionGeneration else { throw CancellationError() }
            sessions = TmuxCommand.sessions(lines)
            if forceLog || lines != lastSessionLines {
                recordDiscovery("list-sessions", command: request, lines: lines, parsed: sessions.count)
                lastSessionLines = lines
            }
            if !lines.isEmpty && sessions.isEmpty {
                throw MuxError.message("tmux returned session data that Mux Manager could not read. Open Connection diagnostics for details.")
            }
            lastSessionFailure = nil
        }
        catch {
            guard generation == connectionGeneration else { throw CancellationError() }
            if forceLog || lastSessionFailure != error.localizedDescription {
                let status = (error as? RemoteCommandFailure).map { " (exit \($0.status))" } ?? ""
                record("tmux", "list-sessions failed\(status): \(error.localizedDescription)")
                lastSessionFailure = error.localizedDescription
            }
            // No server is a normal initial state; other failures should remain visible.
            if let failed = error as? RemoteCommandFailure, failed.isNoServer {
                sessions = []; lastSessionLines = nil
                if forceLog { record("tmux", "Classified as no default tmux server. Check SSH username, TMUX_TMPDIR, and custom sockets.") }
            }
            else { throw error }
        }
    }
    private func discoverWindows(forceLog: Bool = false) async throws {
        let generation = connectionGeneration
        guard let session = selectedSessionID else {
            if forceLog { record("selection", "Window discovery skipped: no session selected. Available sessions=\(sessions.count)") }
            return
        }
        let request = "list-windows -t \(TmuxCommand.quote(session)) -F \(TmuxCommand.quote(TmuxCommand.windowFormat))"
        do {
            let lines = try await command(request)
            guard generation == connectionGeneration, selectedSessionID == session else { throw CancellationError() }
            windows = TmuxCommand.windows(lines, session: session)
            if forceLog || lastWindowResult?.session != session || lastWindowResult?.lines != lines {
                recordDiscovery("list-windows", command: request, lines: lines, parsed: windows.count)
                lastWindowResult = (session, lines)
            }
            if !lines.isEmpty && windows.isEmpty {
                throw MuxError.message("tmux returned window data that Mux Manager could not read. Open Connection diagnostics for details.")
            }
            lastWindowFailure = nil
        } catch {
            guard generation == connectionGeneration, selectedSessionID == session else { throw CancellationError() }
            if forceLog || lastWindowFailure != error.localizedDescription {
                let status = (error as? RemoteCommandFailure).map { " (exit \($0.status))" } ?? ""
                record("tmux", "list-windows failed for \(session)\(status): \(error.localizedDescription)")
                lastWindowFailure = error.localizedDescription
            }
            throw error
        }
        if let id = selectedWindowID, !windows.contains(where: { $0.id == id }) {
            record("selection", "Selected window \(id) closed; returning to the window list")
            selectedWindowID = nil; joinedCapture = ""; terminalCapture = ""; displayMode = .smart
            closedWindowRevision += 1
        }
    }

    private func refreshSnapshot(forceLog: Bool = false) async throws {
        let generation = connectionGeneration
        guard !isBackgrounded, let pane = selectedWindow?.paneID, !refreshInProgress else { return }
        refreshInProgress = true; dirty = false
        defer { refreshInProgress = false }
        let metadata = try await command("display-message -p -t \(TmuxCommand.quote(pane)) '#{pane_width} #{pane_height} #{cursor_x} #{cursor_y} #{keypad_cursor_flag} #{keypad_flag} #{cursor_flag} #{history_size} #{history_limit} #{alternate_on}'")
        let fields = metadata.joined().split(separator: " ")
        guard fields.count >= 4, let cols = Int(fields[0]), let rows = Int(fields[1]),
              let x = Int(fields[2]), let y = Int(fields[3]) else { return }
        var joined = try await command(TmuxCommand.capture(pane: pane, joined: true, colors: true))
        while let last = joined.last, TerminalCaptureStyle.parse(last).text.trimmingCharacters(in: .whitespaces).isEmpty { joined.removeLast() }
        let grid = try await command(TmuxCommand.capture(pane: pane, joined: false, colors: true))
        guard generation == connectionGeneration, pane == selectedWindow?.paneID else { dirty = true; return }
        let historySize = fields.count > 7 ? Int(fields[7]) : nil
        let historyLimit = fields.count > 8 ? Int(fields[8]) : nil
        let alternate = fields.count > 9 ? String(fields[9]) : "unknown"
        captureDiagnostics = "pane=\(pane); remote history=\(historySize.map(String.init) ?? "unknown")/\(historyLimit.map(String.init) ?? "unknown"); alternate screen=\(alternate); grid rows=\(grid.count); joined lines=\(joined.count); remote grid=\(cols)×\(rows)"
        let signature = "\(pane):\(cols):\(rows):\(historyLimit ?? -1):\(historySize == 0):\(alternate)"
        if forceLog || signature != lastCaptureSignature {
            record("capture", captureDiagnostics); lastCaptureSignature = signature
        }
        var lastTextRow = max(0, grid.count - 1)
        while lastTextRow > 0 && TerminalCaptureStyle.parse(grid[lastTextRow]).text.trimmingCharacters(in: .whitespaces).isEmpty { lastTextRow -= 1 }
        terminalLiveRow = max(lastTextRow, max(0, grid.count - rows) + y)
        let prose = joined.joined(separator: "\n")
        applicationCursorKeys = fields.count > 4 && fields[4] == "1"
        let cursorMode = applicationCursorKeys ? "\u{1b}[?1h" : "\u{1b}[?1l"
        let keypadMode = fields.count > 5 && fields[5] == "1" ? "\u{1b}=" : "\u{1b}>"
        let visibleCursor = fields.count > 6 && fields[6] == "0" ? "\u{1b}[?25l" : "\u{1b}[?25h"
        let terminal = "\u{1b}c" + grid.joined(separator: "\r\n") + "\u{1b}[\(y + 1);\(x + 1)H" + cursorMode + keypadMode + visibleCursor
        if terminalCapture != terminal || remoteColumns != cols || remoteRows != rows {
            remoteColumns = cols; remoteRows = rows; terminalCapture = terminal; snapshotRevision += 1
        }
        if joinedCapture != prose { joinedCapture = prose }
    }

    func configureAttention(enabled: Bool, handler: @escaping (CodexPaneTarget, CodexAttentionState) -> Void) {
        attentionHandler = handler
        if attentionEnabled != enabled { stopAttentionMonitoring(); attentionEnabled = enabled }
        startAttentionMonitoring()
    }

    private func stopAttentionMonitoring() {
        // Rotate ownership instead of cancelling an in-flight tmux response.
        attentionEpoch = UUID(); attentionTask = nil
        attentionTracker = CodexAttentionTracker()
    }

    private func observeAttention(target: CodexPaneTarget, screen: String) {
        guard attentionEnabled, attentionRuntimeAvailable, isConnected else { return }
        let state = CodexAttention.state(screen: screen, command: target.command)
        if let event = attentionTracker.observe(pane: target.paneID, state: state, at: attentionTime) {
            record("notifications", "Codex needs attention: window=\(target.windowID) pane=\(target.paneID)")
            attentionHandler?(target, event)
        }
    }

    private func startAttentionMonitoring() {
        guard attentionEnabled, attentionRuntimeAvailable, isConnected, attentionTask == nil else { return }
        let epoch = UUID(); attentionEpoch = epoch
        let generation = connectionGeneration
        attentionTask = Task { [weak self] in
            var targets: [CodexPaneTarget] = []
            var nextDiscovery: TimeInterval = 0
            var cursor = 0
            var lastError: TimeInterval = -.infinity
            while let self, self.attentionEpoch == epoch, self.connectionGeneration == generation,
                  self.isConnected, self.attentionEnabled, self.attentionRuntimeAvailable {
                if !self.busy && !self.sending && self.connectionSetupGeneration == nil && !self.resumingFromBackground {
                    do {
                        let now = self.attentionTime
                        if now >= nextDiscovery {
                            let lines = try await self.command("list-windows -a -F \(TmuxCommand.quote(TmuxCommand.attentionFormat))")
                            guard self.attentionEpoch == epoch, self.connectionGeneration == generation else { break }
                            let all = TmuxCommand.attentionTargets(lines)
                            self.attentionTracker.retain(panes: Set(all.filter { CodexAttention.isCandidate(command: $0.command) }.map(\.paneID)))
                            // Linked windows occur in multiple sessions. Monitor
                            // each active pane once and prefer the viewed session.
                            var seen = Set<String>()
                            targets = all.sorted { ($0.sessionID == self.selectedSessionID ? 0 : 1) < ($1.sessionID == self.selectedSessionID ? 0 : 1) }
                                .filter { seen.insert($0.paneID).inserted && CodexAttention.isCandidate(command: $0.command) }
                            nextDiscovery = now + 6
                        }
                        // Round-robin bounds each pass so dozens of windows don't
                        // monopolize the SSH command queue or starve older panes.
                        for _ in 0..<min(8, targets.count) {
                            guard self.attentionEpoch == epoch, self.connectionGeneration == generation,
                                  self.attentionRuntimeAvailable, self.isConnected, !self.busy, !self.sending else { break }
                            let target = targets[cursor % targets.count]; cursor += 1
                            let lines = try await self.command("capture-pane -pJ -S 0 -t \(TmuxCommand.quote(target.paneID))")
                            guard self.attentionEpoch == epoch, self.connectionGeneration == generation else { break }
                            self.observeAttention(target: target, screen: lines.joined(separator: "\n"))
                        }
                    } catch {
                        // Never log pane contents or replay input. A closed or
                        // disappearing window is retried by the next discovery.
                        let now = self.attentionTime
                        if now - lastError >= 30 {
                            self.record("notifications", "Monitoring query failed; will retry")
                            lastError = now
                        }
                        nextDiscovery = 0
                    }
                }
                do { try await Task.sleep(for: .milliseconds(1500)) } catch { break }
            }
            if self?.attentionEpoch == epoch { self?.attentionTask = nil }
        }
    }

    func openNotificationWindow(_ target: CodexNotificationTarget, isCurrent: () -> Bool) async {
        guard isConnected, !busy, !sending, target.hostID == id else { return }
        let generation = connectionGeneration
        busy = true
        defer { busy = false }
        do {
            try await discoverSessions()
            guard sessions.contains(where: { $0.id == target.sessionID }) else { throw MuxError.message("This tmux session is no longer available.") }
            let lines = try await command("list-windows -t \(TmuxCommand.quote(target.sessionID)) -F \(TmuxCommand.quote(TmuxCommand.windowFormat))")
            guard isCurrent(), isConnected, generation == connectionGeneration else { return }
            guard TmuxCommand.windows(lines, session: target.sessionID).contains(where: { $0.id == target.windowID }) else {
                throw MuxError.message("This tmux window is no longer available.")
            }
            if selectedSessionID != target.sessionID { try await restoreSize(); try await attach(target.sessionID) }
            else { try await discoverWindows() }
            guard isCurrent(), isConnected, generation == connectionGeneration else { return }
            if selectedWindowID != target.windowID { try await restoreSize(); try await chooseWindow(target.windowID) }
            guard isCurrent(), isConnected, generation == connectionGeneration else { return }
            directInput = false; notificationFocusRevision += 1
            if selectedWindow?.paneID != target.paneID { error = "This window now has a different active pane." }
        } catch { self.error = error.localizedDescription }
    }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .output(let pane, _): if pane == selectedWindow?.paneID { dirty = true }
        case .notification(let message):
            dirty = true
            if !isBackgrounded && (message.hasPrefix("%window-close ") || message.hasPrefix("%unlinked-window-close ")) {
                Task {
                    do { try await discoverWindows() }
                    catch { record("tmux", "Window-close refresh: \(error.localizedDescription)") }
                }
            }
        case .exit(let message):
            record("tmux", "Attached session ended: \(message)")
            // SSH is still usable when tmux's final window/session exits.
            attachmentGeneration = UUID(); control = nil; serverIdentity = ""
            let hadWindow = selectedWindowID != nil
            selectedWindowID = nil; selectedSessionID = nil; windows = []; sessions = []
            joinedCapture = ""; terminalCapture = ""; snapshotRevision += 1; displayMode = .smart
            if hadWindow { closedWindowRevision += 1 }
            if isBackgrounded { return }
            Task {
                do { try await discoverSessions(forceLog: true) }
                catch { record("tmux", "Session-exit refresh: \(error.localizedDescription)") }
            }
        case .protocolError(let message):
            record("tmux", "Control mode ended: \(message)")
            state = .failed(message.isEmpty ? "tmux disconnected." : message); pollTask?.cancel()
        case .response: break
        }
    }
    private func startPolling() {
        guard !isBackgrounded else { return }
        pollTask?.cancel()
        let generation = UUID(); pollingGeneration = generation
        pollTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { break }
                guard let self, self.isConnected, !self.isBackgrounded, self.pollingGeneration == generation else { break }
                if self.busy { continue }
                do {
                    ticks += 1
                    if ticks % 10 == 0 {
                        try await self.discoverSessions(); try await self.discoverWindows()
                        guard !self.isBackgrounded, self.pollingGeneration == generation else { break }
                        if self.displayMode == .fit, let lease = self.lease {
                            let current = try await self.sizing(lease.windowID)
                            if !lease.mayRestore(current: current, serverIdentity: self.serverIdentity) {
                                self.lease = nil; try self.persistLease(); self.fittedViewport = nil; self.displayMode = .original
                                self.error = "Another client changed the window size or sizing policy. Fit mode has stopped."
                            }
                        }
                    }
                    if self.displayMode == .fit,
                       self.fittedViewport?.columns != self.viewport.columns || self.displayMode == .fit && self.fittedViewport?.rows != self.viewport.rows {
                        try await self.fitWindow(); try await self.discoverWindows()
                    }
                    if self.dirty { try await self.refreshSnapshot() }
                } catch {
                    if Task.isCancelled { break }
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

#if DEBUG
/// A fake tmux peer for exercising the production monitor without SSH, user
/// data, notification authorization, or posting OS notifications.
private actor AttentionFixturePeer {
    private var channel: ControlChannel?
    private var sequence = 1
    private var screens: [String: String] = Dictionary(uniqueKeysWithValues: (1...11).map {
        ("%\($0)", [1, 11].contains($0) ? "• Working (5s · esc to interrupt)\n›\n100% context left" : "• Complete\n›\n100% context left")
    })
    private(set) var reads: [String: Int] = [:]
    private(set) var commands: [String] = []
    func install(_ value: ControlChannel?) { channel = value }
    func screen(_ pane: String, _ value: String) { screens[pane] = value }
    func write(_ data: Data) async throws {
        let command = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        commands.append(command)
        let lines: [String]
        if command.hasPrefix("list-windows -a") {
            lines = (1...11).map { "\($0 == 11 ? "$2" : "$1")\t@\($0)\t\($0 == 11 ? "review-needed" : "project-\($0)")\t%\($0)\tcodex" }
                + ["$2\t@1\tlinked-project\t%1\tcodex"]
        } else if command.hasPrefix("list-sessions") { lines = ["$1\twork", "$2\tother"] }
        else if command.hasPrefix("list-windows") {
            lines = (1...11).map { "@\($0)\t\($0 - 1)\tproject-\($0)\t%\($0)\t120\t36\tcodex" }
        } else if command.hasPrefix("capture-pane"), let pane = screens.keys.first(where: { command.hasSuffix(TmuxCommand.quote($0)) }) {
            reads[pane, default: 0] += 1
            lines = screens[pane]!.components(separatedBy: "\n")
        } else if command.hasPrefix("display-message") { lines = ["120 36 0 1 0 0 1 0 2000 0"] }
        else if command.hasPrefix("refresh-client") { lines = [] }
        else { throw MuxError.message("Unexpected fixture command.") }
        sequence += 1
        let token = "\(sequence) \(sequence) 0"
        await channel?.receive(Data(("%begin \(token)\n" + lines.map { $0 + "\n" }.joined() + "%end \(token)\n").utf8))
    }
}

extension HostWorkspace {
    func validateAttentionMonitoring() async {
        guard LibraryStore.screenshotScene == "attention" else { return }
        var checks: [String: Bool] = [:]
        var events: [(CodexPaneTarget, CodexAttentionState)] = []
        let peer = AttentionFixturePeer()
        let channel = ControlChannel(writer: { try await peer.write($0) }, onEvent: { _ in })
        await peer.install(channel)
        await channel.receive(Data("%begin 0 0 0\n%end 0 0 0\n".utf8))
        control = channel
        configureAttention(enabled: true) { events.append(($0, $1)) }
        func wait(_ condition: () async -> Bool) async -> Bool {
            let end = ContinuousClock.now.advanced(by: .seconds(15))
            while ContinuousClock.now < end {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }
        let sampled = await wait { await peer.reads.count == 11 }
        checks["roundRobinSamplesMoreThanOneBatchAcrossSessions"] = sampled
        checks["initialIdleWindowsDoNotNotify"] = events.isEmpty
        await peer.screen("%1", "• Done\n›\n100% context left")
        await peer.screen("%11", "Which branch should I use?\n›\n100% context left")
        let completed = await wait { events.count >= 2 }
        checks["completionAndQuestionGenerateEvents"] = completed && events.contains { $0.0.paneID == "%1" && $0.1 == .ready }
            && events.contains { $0.0.sessionID == "$2" && $0.0.windowName == "review-needed" && $0.1 == .needsInput }
        try? await Task.sleep(for: .seconds(3))
        checks["linkedWindowsAndRepeatedScreensDoNotDuplicate"] = events.count == 2
        pauseForBackground()
        await prepareForBackground(expectedIntent: connectionIntent)
        let reads = await peer.reads["%1", default: 0]
        await peer.screen("%1", "• Working (esc to interrupt)\n›\n100% context left")
        _ = await wait { await peer.reads["%1", default: 0] >= reads + 2 }
        await peer.screen("%1", "Would you like to run this command?\n› 1. Yes, proceed\n2. No\nEnter to confirm")
        checks["backgroundRuntimeStillDetectsApproval"] = await wait { events.count == 3 }
        backgroundTimeExpired()
        try? await Task.sleep(for: .milliseconds(500))
        let stopped = await peer.commands.count
        try? await Task.sleep(for: .seconds(2))
        checks["runtimeExpirationStopsQueries"] = await peer.commands.count == stopped
        unpauseAfterBackground()
        let beforeRestart = events.count
        try? await Task.sleep(for: .seconds(4))
        checks["restartBaselinesDoNotReplayOldAlerts"] = events.count == beforeRestart
        configureAttention(enabled: false) { _, _ in }
        try? await Task.sleep(for: .milliseconds(300))
        let disabledCount = await peer.commands.count
        try? await Task.sleep(for: .seconds(2))
        checks["disablingStopsMonitorQueries"] = await peer.commands.count == disabledCount
        let target = CodexNotificationTarget(hostID: id, sessionID: "$1", windowID: "@2", paneID: "%2")
        let focus = notificationFocusRevision
        await openNotificationWindow(target, isCurrent: { true })
        checks["notificationTargetOpensWindowAndResumesLive"] = selectedWindowID == "@2" && notificationFocusRevision == focus + 1
        error = nil
        let missing = CodexNotificationTarget(hostID: id, sessionID: "$1", windowID: "@999", paneID: "%999")
        await openNotificationWindow(missing, isCurrent: { true })
        checks["closedWindowDoesNotSelectAnotherOrCreateAnything"] = selectedWindowID == "@2" && error?.contains("no longer available") == true
        error = nil
        let content = CodexNotifications.content(hostName: "Fixture host", windowName: "project-2", state: .needsInput, target: target)
        checks["notificationContainsNamesAndStableDestination"] = content.title == "Fixture host · project-2"
            && CodexNotificationTarget(userInfo: content.userInfo) == target && content.userInfo.count == 4
        checks["notificationHasNoTerminalResponseContent"] = content.body == "Codex is waiting for input."
        checks["malformedNotificationDestinationRejected"] = CodexNotificationTarget(userInfo: ["hostID": id.uuidString, "sessionID": "bad", "windowID": "@1", "paneID": "%1"]) == nil
        let requests = await peer.commands
        checks["monitorNeverSendsInputCreatesWindowsOrChangesDesktopSelection"] = requests.allSatisfy {
            ["list-windows", "list-sessions", "capture-pane", "display-message", "refresh-client"].contains(where: $0.hasPrefix)
        }
        await channel.close(); await peer.install(nil); control = nil
        let report: [String: Any] = ["checks": checks, "passed": checks.values.allSatisfy { $0 }, "queryCount": requests.count]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("mux-attention-report.json"))
        }
    }
}
#endif
