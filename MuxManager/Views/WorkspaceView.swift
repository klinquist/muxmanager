import SwiftUI
import UIKit
import MuxCore

struct WorkspaceView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var workspace: HostWorkspace
    var returnToWindows: () -> Void
    @State private var action: ManagementAction?
    @State private var showDiagnostics = false
    @State private var follow = true
    @State private var readingCapture: String?
    @State private var resumeToLive = false
    @State private var liveToken = 0
    @State private var magnificationStart: Double?
    @State private var composerFocused = false
    @State private var keyboardVisible = false

    var body: some View {
        VStack(spacing: 0) {
            if let window = workspace.selectedWindow {
                displayControls
                GeometryReader { geometry in
                    let capture = readingCapture ?? workspace.joinedCapture
                    ZStack(alignment: .bottomTrailing) {
                        if workspace.conversation {
                            ConversationContent(capture: capture, fontSize: workspace.fontSize, follow: $follow, liveToken: liveToken, onSelection: { pauseForSelection(capture) })
                        } else if workspace.displayMode == .smart {
                            SmartContent(capture: capture, fontSize: workspace.fontSize, follow: $follow, liveToken: liveToken, onSelection: { pauseForSelection(capture) })
                        } else {
                            TerminalCanvas(workspace: workspace, follow: $follow, liveToken: liveToken)
                        }
                    }
                    .background(Color(red: 0.035, green: 0.055, blue: 0.07))
                    .simultaneousGesture(TapGesture().onEnded {
                        // Selection/scrolling pauses Live. Use the keyboard
                        // button to leave that state without stealing Copy focus.
                        if workspace.terminalMode, !workspace.directInput, follow { activateTerminalKeyboard() }
                    }, including: workspace.terminalMode ? .all : .subviews)
                    .simultaneousGesture(MagnificationGesture().onChanged { scale in
                        if magnificationStart == nil { magnificationStart = workspace.fontSize }
                        workspace.fontSize = min(32, max(8, (magnificationStart ?? 14) * scale))
                    }.onEnded { _ in magnificationStart = nil })
                    .onAppear { updateViewport(geometry.size) }
                    .onChange(of: geometry.size) { _, size in updateViewport(size) }
                    .onChange(of: workspace.fontSize) { _, _ in updateViewport(geometry.size) }
                    .overlay(alignment: .topLeading) {
                        if workspace.directInput && (workspace.conversation || workspace.displayMode == .smart) {
                            DirectKeyboard(onInput: { bytes in sendDirect(bytes) },
                                           onPaste: terminalPasteAction, isActive: { workspace.directInput })
                                .frame(width: 1, height: 1).opacity(0.01)
                        }
                    }
                }
                HStack(spacing: 6) {
                    Circle().fill(workspace.isConnected ? .mint : .orange).frame(width: 5, height: 5)
                    Text(workspace.profile.name)
                    Spacer()
                    Button {
                        showLive()
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
                    Toggle("Conversation view", isOn: $workspace.conversation).disabled(workspace.terminalMode)
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
        .onChange(of: follow) { _, following in
            if following { readingCapture = nil }
            else if readingCapture == nil { readingCapture = workspace.joinedCapture }
        }
        .onChange(of: scenePhase) { _, phase in
            // Foreground SSH probes refresh the model, but a held reading
            // capture/emulator can otherwise keep showing the pre-background text.
            if phase == .background { resumeToLive = true }
            else if phase == .active, resumeToLive { resumeToLive = false; showLive() }
        }
        .onChange(of: workspace.selectedWindowID) { _, _ in readingCapture = nil; follow = true; liveToken += 1; composerFocused = false }
        .onChange(of: workspace.inputRevision) { _, _ in readingCapture = nil; follow = true; liveToken += 1 }
        .onChange(of: workspace.directInput) { _, direct in if direct { composerFocused = false } }
        .onChange(of: workspace.closedWindowRevision) { _, _ in returnToWindows() }
        .onChange(of: workspace.notificationFocusRevision) { _, _ in composerFocused = false; showLive() }
        .onChange(of: workspace.state) { _, state in
            if state == .disconnected || state == .disconnecting { returnToWindows() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    }

    private func showLive() {
        readingCapture = nil; follow = true; liveToken += 1
    }
    private func pauseForSelection(_ capture: String) {
        workspace.directInput = false; composerFocused = false
        readingCapture = capture; follow = false
    }
    private func activateTerminalKeyboard() {
        guard workspace.terminalMode, workspace.isConnected else { return }
        composerFocused = false
        showLive()
        workspace.directInput = true
    }

    private func setTerminalMode(_ enabled: Bool) {
        composerFocused = false
        workspace.setTerminalMode(enabled)
        if enabled { showLive() }
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
            Picker("Input mode", selection: Binding(get: { workspace.terminalMode }, set: setTerminalMode)) {
                Text("Compose").tag(false)
                Text("Terminal").tag(true)
            }.pickerStyle(.segmented).disabled(!workspace.isConnected)
                .accessibilityHint("Terminal sends each key directly to the remote window. Compose drafts text before sending.")
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
        let paste = terminalPasteAction
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    key("Esc", "\u{1b}")
                    Button("Tab") { Task { await workspace.completeInShell() } }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Complete the command using the remote shell and copy the result back to this input box without submitting it.")
                    if workspace.terminalMode { key("Shift-Tab", "\u{1b}[Z") }
                    Button("Ctrl") { workspace.controlModifier.toggle() }.tint(workspace.controlModifier ? .orange : .mint)
                        .buttonStyle(.bordered).accessibilityAddTraits(workspace.controlModifier ? .isSelected : [])
                    key("Ctrl-C", "\u{3}")
                    Button("↑") { if workspace.terminalMode { sendDirect(Data("\u{1b}[A".utf8)) } else { workspace.recallCommand(older: true); composerFocused = true } }
                        .buttonStyle(.bordered).accessibilityLabel(workspace.terminalMode ? "Up arrow" : "Previous command")
                    Button("↓") { if workspace.terminalMode { sendDirect(Data("\u{1b}[B".utf8)) } else { workspace.recallCommand(older: false); composerFocused = true } }
                        .buttonStyle(.bordered).accessibilityLabel(workspace.terminalMode ? "Down arrow" : "Next command")
                    key("←", "\u{1b}[D"); key("→", "\u{1b}[C")
                    key("Enter", "\r")
                }.font(.system(.caption, design: .monospaced)).disabled(!workspace.isConnected || workspace.sending)
              }
              if workspace.terminalMode {
                  PasteButton(payloadType: String.self) { strings in paste(strings.joined(separator: "\n")) }
                      .labelStyle(.iconOnly).tint(.mint)
                      .accessibilityLabel("Paste into terminal")
                      .disabled(!workspace.isConnected || workspace.sending || workspace.busy)
              }
              if keyboardVisible {
                  Button {
                      workspace.directInput = false
                      composerFocused = false
                      UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                  } label: { Image(systemName: "keyboard.chevron.compact.down") }
                      .buttonStyle(.bordered).accessibilityLabel("Hide keyboard")
              } else if workspace.terminalMode {
                  Button(action: activateTerminalKeyboard) { Image(systemName: "keyboard") }
                      .buttonStyle(.bordered).accessibilityLabel("Show terminal keyboard")
              }
            }
            if !workspace.terminalMode {
                if let hint = workspace.completionHint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    CommandComposer(text: $workspace.draft, focused: $composerFocused, onSubmit: submitComposer,
                                    onHistory: { workspace.recallCommand(older: $0) },
                                    isBrowsingHistory: workspace.isBrowsingCommandHistory)
                        .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    Button(action: submitComposer) {
                        Image(systemName: workspace.sending ? "ellipsis" : "arrow.up").font(.headline)
                            .frame(width: 42, height: 42).background(.mint, in: Circle()).foregroundStyle(.black)
                    }
                    .accessibilityLabel("Send to \(window.name)")
                    .disabled(workspace.draft.isEmpty || workspace.sending || !workspace.isConnected || workspace.busy)
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
    }
    private func submitComposer() {
        guard !workspace.draft.isEmpty, !workspace.sending, workspace.isConnected, !workspace.busy else { return }
        follow = true; liveToken += 1
        Task { await workspace.sendDraft() }
    }
    private func key(_ title: String, _ value: String) -> some View {
        Button(title) { sendDirect(Data(value.utf8)) }.buttonStyle(.bordered)
    }
    private func sendDirect(_ data: Data) {
        Task { await workspace.sendKey(data) }
    }
    private var terminalPasteAction: (String) -> Void {
        // A system Paste button can load clipboard providers asynchronously.
        // Bind that request to this connection/window instead of retargeting
        // pasted text if the user navigates before the payload arrives.
        let windowID = workspace.selectedWindowID
        let connectionIntent = workspace.connectionIntent
        return { text in
            guard let windowID else { return }
            Task { await workspace.pasteIntoTerminal(text, windowID: windowID, connectionIntent: connectionIntent) }
        }
    }
    private func updateViewport(_ size: CGSize) {
        let font = UIFont.monospacedSystemFont(ofSize: workspace.fontSize, weight: .regular)
        let width = ("W" as NSString).size(withAttributes: [.font: font]).width
        workspace.updateViewport(columns: Int(max(1, size.width - 2) / max(1, width)), rows: Int(size.height / max(1, ceil(font.lineHeight))))
    }
}

/// UIKit key commands distinguish hardware Return from software Return and pasted newlines.
private struct CommandComposer: UIViewRepresentable {
    @Binding var text: String
    var focused: Binding<Bool>
    var onSubmit: () -> Void
    var onHistory: (Bool) -> Void
    var isBrowsingHistory: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> CommandTextView {
        let view = CommandTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = .label
        view.tintColor = .systemMint
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.returnKeyType = .default
        view.accessibilityLabel = "Message or command"
        view.accessibilityHint = "On a hardware keyboard, Return sends, Shift-Return inserts a new line, and Up recalls previous commands."
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: CommandTextView, context: Context) {
        context.coordinator.parent = self
        view.onSubmit = onSubmit
        view.onHistory = onHistory
        view.isBrowsingHistory = isBrowsingHistory
        view.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        if view.text != text, view.markedTextRange == nil {
            let selection = view.selectedRange
            let atEnd = NSMaxRange(selection) == (view.text as NSString).length
            view.text = text
            let length = (text as NSString).length
            let location = atEnd ? length : min(selection.location, length)
            view.selectedRange = NSRange(location: location, length: atEnd ? 0 : min(selection.length, length - location))
        }
        view.updatePlaceholder()
        view.wantsFocus = focused.wrappedValue
        if !view.wantsFocus, view.isFirstResponder { view.resignFirstResponder() }
        else if view.wantsFocus, !view.isFirstResponder {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.wantsFocus, view.window != nil, !view.isFirstResponder else { return }
                view.becomeFirstResponder()
            }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CommandTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let font = uiView.font else { return nil }
        let content = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(ceil(font.lineHeight * 6), max(ceil(font.lineHeight), content.height)))
    }
    static func dismantleUIView(_ view: CommandTextView, coordinator: Coordinator) {
        view.wantsFocus = false; view.onSubmit = nil; view.onHistory = nil; view.delegate = nil
        view.resignFirstResponder()
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CommandComposer
        init(_ parent: CommandComposer) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? CommandTextView)?.updatePlaceholder()
            textView.invalidateIntrinsicContentSize()
        }
        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.focused.wrappedValue { parent.focused.wrappedValue = true }
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.focused.wrappedValue { parent.focused.wrappedValue = false }
        }
    }
}

private final class CommandTextView: UITextView {
    var onSubmit: (() -> Void)?
    var onHistory: ((Bool) -> Void)?
    var isBrowsingHistory = false
    var wantsFocus = false
    private let placeholder = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.text = "Message or command…"
        placeholder.textColor = .placeholderText
        placeholder.isUserInteractionEnabled = false
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func updatePlaceholder() {
        placeholder.isHidden = !text.isEmpty
        placeholder.font = font
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        placeholder.frame = CGRect(x: textContainerInset.left + textContainer.lineFragmentPadding,
                                   y: textContainerInset.top, width: bounds.width, height: ceil(font?.lineHeight ?? 22))
    }
    override var keyCommands: [UIKeyCommand]? {
        // Let the input method consume Return while confirming marked text.
        guard markedTextRange == nil else { return super.keyCommands }
        let submit = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(submitCommand))
        let newline = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(insertLineBreak))
        submit.wantsPriorityOverSystemBehavior = true
        newline.wantsPriorityOverSystemBehavior = true
        var commands = [submit, newline]
        if canRecallHistory(older: true) {
            let up = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(previousCommand))
            up.wantsPriorityOverSystemBehavior = true; commands.append(up)
        }
        if canRecallHistory(older: false) {
            let down = UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(nextCommand))
            down.wantsPriorityOverSystemBehavior = true; commands.append(down)
        }
        return commands + (super.keyCommands ?? [])
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(previousCommand) { return canRecallHistory(older: true) }
        if action == #selector(nextCommand) { return canRecallHistory(older: false) }
        if action == #selector(submitCommand) || action == #selector(insertLineBreak) { return markedTextRange == nil }
        return super.canPerformAction(action, withSender: sender)
    }
    @objc private func submitCommand() {
        guard markedTextRange == nil else { return }
        onSubmit?()
    }
    @objc private func insertLineBreak() {
        guard markedTextRange == nil else { return }
        insertText("\n")
    }
    private func canRecallHistory(older: Bool) -> Bool {
        guard markedTextRange == nil, selectedRange.length == 0 else { return false }
        if isBrowsingHistory { return true }
        // Preserve ordinary caret movement inside multiline/wrapped drafts.
        guard let selectedTextRange else { return false }
        let caret = caretRect(for: selectedTextRange.start)
        let boundary = caretRect(for: older ? beginningOfDocument : endOfDocument)
        return abs(caret.minY - boundary.minY) < 1
    }
    @objc private func previousCommand() {
        guard canRecallHistory(older: true) else { return }
        onHistory?(true)
    }
    @objc private func nextCommand() {
        guard canRecallHistory(older: false) else { return }
        onHistory?(false)
    }
}

#if DEBUG
/// Isolated sample data only; dispatches native control/key actions without SSH.
@MainActor
enum InputModeValidation {
    static func run(workspace: HostWorkspace) async {
        guard LibraryStore.screenshotScene?.hasPrefix("input") == true else { return }
        func views() -> [UIView] {
            func flatten(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(flatten) }
            return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).flatMap(flatten)
        }
        func pause() async { try? await Task.sleep(for: .milliseconds(200)) }
        func composer() -> CommandTextView? { views().compactMap { $0 as? CommandTextView }.first }
        func press(_ input: String, modifiers: UIKeyModifierFlags = []) -> Bool {
            guard let command = composer()?.keyCommands?.first(where: { $0.input == input && $0.modifierFlags == modifiers }) else { return false }
            return UIApplication.shared.sendAction(command.action!, to: nil, from: command, for: nil)
        }
        var checks: [String: Bool] = [:]
        _ = composer()?.becomeFirstResponder(); await pause()
        checks["upRoutesToComposer"] = press(UIKeyCommand.inputUpArrow); await pause()
        checks["upRecallsMultilineCommand"] = workspace.draft == "echo first\necho second"
        _ = press(UIKeyCommand.inputUpArrow); await pause()
        checks["repeatedUpRecallsOlderCommand"] = workspace.draft == "ls -la"
        _ = press(UIKeyCommand.inputDownArrow); await pause()
        _ = press(UIKeyCommand.inputDownArrow); await pause()
        checks["downRestoresUnsubmittedDraft"] = workspace.draft == "unfinished"
        checks["historyDoesNotSendRemoteInput"] = workspace.inputRevision == 0
        workspace.draft = "first\nsecond\nthird"; await pause()
        composer()?.selectedRange = NSRange(location: 8, length: 0)
        checks["multilineMiddleKeepsVerticalCaretMovement"] = !(composer()?.keyCommands ?? []).contains { $0.action == NSSelectorFromString("previousCommand") || $0.action == NSSelectorFromString("nextCommand") }
        composer()?.setMarkedText("candidate", selectedRange: NSRange(location: 9, length: 0)); await pause()
        checks["markedTextSuppressesHistory"] = !(composer()?.keyCommands ?? []).contains { $0.action == NSSelectorFromString("previousCommand") || $0.action == NSSelectorFromString("nextCommand") }
        composer()?.unmarkText()
        workspace.draft = "saved draft"; await pause()
        _ = press("\r", modifiers: .shift); await pause()
        checks["shiftReturnStillInsertsNewline"] = workspace.draft.contains("\n") && workspace.inputRevision == 0
        let draft = workspace.draft
        let mode = views().compactMap { $0 as? UISegmentedControl }.first { control in
            (0..<control.numberOfSegments).contains { control.titleForSegment(at: $0) == "Terminal" }
        }
        checks["explicitModePickerExists"] = mode != nil
        mode?.selectedSegmentIndex = 1; mode?.sendActions(for: .valueChanged); await pause()
        // UIKit can still be dismissing the old composer while SwiftUI mounts
        // the terminal responder (especially on a freshly booted simulator).
        for _ in 0..<15 {
            if views().contains(where: { ($0 is KeyInputView || $0 is PinnedTerminalView) && $0.isFirstResponder }) { break }
            await pause()
        }
        checks["terminalModeHidesComposer"] = workspace.terminalMode && composer() == nil
        let direct = views().compactMap { $0 as? KeyInputView }.first
        let terminal = views().compactMap { $0 as? PinnedTerminalView }.first
        checks["terminalOwnsKeyboardFocus"] = workspace.directInput && (direct?.isFirstResponder == true || (terminal?.isFirstResponder == true && terminal?.keyboardEnabled == true))
        let originalInput = direct?.onInput
        if let direct {
            var bytes = Data()
            direct.onInput = { bytes.append($0) }
            direct.insertText("ls"); direct.insertText("\n"); direct.deleteBackward()
            if let up = direct.keyCommands?.first(where: { $0.input == UIKeyCommand.inputUpArrow }) {
                _ = UIApplication.shared.sendAction(up.action!, to: direct, from: up, for: nil)
            }
            checks["directInputForwardsKeysImmediately"] = bytes == Data("ls\r\u{7f}\u{1b}[A".utf8)
            bytes = Data()
            let shiftTab = direct.keyCommands?.first { $0.input == "\t" && $0.modifierFlags == .shift }
            checks["shiftTabHasPriority"] = shiftTab?.wantsPriorityOverSystemBehavior == true
            if let shiftTab { _ = UIApplication.shared.sendAction(shiftTab.action!, to: nil, from: shiftTab, for: nil) }
            checks["shiftTabForwardsBackTabOnce"] = bytes == Data("\u{1b}[Z".utf8)
            direct.onInput = originalInput
        }
        let clipboard = "pasted 🙂\nsecond line\n"
        UIPasteboard.general.string = clipboard
        let pasteResponder: UIView? = direct ?? terminal.map { $0 as UIView }
        var receivedPastes: [String] = []
        let originalPaste = direct?.onPaste ?? terminal?.onPaste
        if let direct { direct.onPaste = { receivedPastes.append($0) } }
        if let terminal { terminal.onPaste = { receivedPastes.append($0) } }
        let commandV = pasteResponder?.keyCommands?.first { $0.input == "v" && $0.modifierFlags == .command }
        checks["commandVHasPriority"] = commandV?.wantsPriorityOverSystemBehavior == true
        checks["terminalOffersNativePaste"] = pasteResponder?.canPerformAction(#selector(UIResponder.paste(_:)), withSender: nil) == true
        if let commandV { _ = UIApplication.shared.sendAction(commandV.action!, to: nil, from: commandV, for: nil) }
        checks["nativePastePreservesWholePayloadOnce"] = receivedPastes == [clipboard]
        UIPasteboard.general.string = "\n"
        if let commandV { _ = UIApplication.shared.sendAction(commandV.action!, to: nil, from: commandV, for: nil) }
        checks["singleNewlineIsPasteInsteadOfReturn"] = receivedPastes == [clipboard, "\n"]
        checks["pasteLeavesComposerDraftUntouched"] = workspace.draft == draft
        if let terminal {
            var backTabs = 0
            let original = terminal.onBackTab
            terminal.onBackTab = { backTabs += 1 }
            let backTab = terminal.keyCommands?.first { $0.input == "\t" && $0.modifierFlags == .shift }
            checks["shiftTabHasPriority"] = backTab?.wantsPriorityOverSystemBehavior == true
            if let backTab { _ = UIApplication.shared.sendAction(backTab.action!, to: nil, from: backTab, for: nil) }
            checks["shiftTabForwardsBackTabOnce"] = backTabs == 1
            terminal.onBackTab = original
        }
        // A stale provider/window/connection must not retarget clipboard text.
        let beforePaste = workspace.inputRevision
        await workspace.pasteIntoTerminal(clipboard, windowID: "@not-selected", connectionIntent: workspace.connectionIntent)
        await workspace.pasteIntoTerminal(clipboard, windowID: workspace.selectedWindowID ?? "", connectionIntent: UUID())
        checks["pasteRejectsStaleDestination"] = workspace.inputRevision == beforePaste
        if let direct { direct.onPaste = originalPaste }
        if let terminal { terminal.onPaste = originalPaste }
        workspace.directInput = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        await pause()
        checks["hideKeyboardKeepsTerminalModeWithoutComposer"] = workspace.terminalMode && composer() == nil && direct?.isFirstResponder != true && terminal?.keyboardEnabled != true
        workspace.setTerminalMode(true); await pause()
        checks["terminalKeyboardCanReopen"] = workspace.directInput && views().contains { ($0 is KeyInputView || $0 is PinnedTerminalView) && $0.isFirstResponder }
        mode?.selectedSegmentIndex = 0; mode?.sendActions(for: .valueChanged); await pause()
        checks["composeRestoresDraft"] = !workspace.terminalMode && !workspace.directInput && composer()?.text == draft
        let revision = workspace.inputRevision
        originalInput?(Data("late input".utf8)); await pause()
        checks["leavingTerminalRejectsQueuedInput"] = workspace.inputRevision == revision
        workspace.setTerminalMode(true); await pause()
        let report: [String: Any] = ["checks": checks, "passed": checks.values.allSatisfy { $0 }]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("mux-input-report.json"))
        }
    }
}
#endif

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
    var onSelection: () -> Void
    var body: some View {
        BottomFollowingContent(follow: $follow, liveToken: liveToken) {
            // One native text document lets selection span prose, code, tables,
            // and blank lines instead of stopping at a presentation-block boundary.
            StyledTerminalLabel(text: TerminalCaptureStyle.parse(capture), fontSize: fontSize,
                                selectionResetToken: liveToken, onSelection: onSelection)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.top, 14).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ConversationContent: View {
    let capture: String
    let fontSize: Double
    @Binding var follow: Bool
    let liveToken: Int
    var onSelection: () -> Void
    var body: some View {
        BottomFollowingContent(follow: $follow, liveToken: liveToken) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("A view of the terminal, including unrecognized output. Use Terminal for interactive prompts.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(CodexPresentation.blocks(from: capture)) { block in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(block.role == .user ? "YOU" : block.role == .assistant ? "CODEX" : "TERMINAL")
                                .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.mint)
                            StyledTerminalLabel(text: block.styledText, fontSize: fontSize,
                                                selectionResetToken: liveToken, onSelection: onSelection)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14).background(block.role == .user ? Color.mint.opacity(0.10) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                    }
                }.padding(.horizontal, 14).padding(.top, 14).fixedSize(horizontal: false, vertical: true)
        }
    }
}
