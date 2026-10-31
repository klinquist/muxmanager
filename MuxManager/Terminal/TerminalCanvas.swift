import SwiftUI
import UIKit
import SwiftTerm
import MuxCore

@MainActor
private enum TerminalWebBrowser {
    static func open(_ url: URL) {
        guard TerminalWebLinks.isWebURL(url) else { return }
        UIApplication.shared.open(url)
    }
}

/// All emulator sizing is local. This type never calls SSH window-change or tmux resize.
struct TerminalCanvas: UIViewRepresentable {
    @ObservedObject var workspace: HostWorkspace
    @Binding var follow: Bool
    var liveToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }
    func makeUIView(context: Context) -> TerminalContainer {
        let view = TerminalContainer()
        view.terminal.terminalDelegate = context.coordinator
        view.onManualScroll = { follow = false }
        return view
    }
    func updateUIView(_ view: TerminalContainer, context: Context) {
        let dimensionsChanged = view.columns != workspace.remoteColumns || view.rows != workspace.remoteRows
        view.columns = workspace.remoteColumns; view.rows = workspace.remoteRows
        view.liveRow = workspace.terminalLiveRow
        view.followLive = follow
        view.onManualScroll = { follow = false }
        view.terminal.keyboardEnabled = workspace.directInput && workspace.isConnected
        let windowID = workspace.selectedWindowID
        let connectionIntent = workspace.connectionIntent
        view.terminal.pasteEnabled = workspace.terminalMode && workspace.isConnected && !workspace.sending && !workspace.busy
        view.terminal.onPaste = { text in
            guard let windowID else { return }
            Task { await workspace.pasteIntoTerminal(text, windowID: windowID, connectionIntent: connectionIntent) }
        }
        view.terminal.onBackTab = { Task { await workspace.sendKey(Data("\u{1b}[Z".utf8)) } }
        if view.terminal.font.pointSize != workspace.fontSize {
            view.terminal.font = .monospacedSystemFont(ofSize: workspace.fontSize, weight: .regular)
        }
        view.setNeedsLayout(); view.layoutIfNeeded()
        let shouldFollow = follow || context.coordinator.lastLiveToken != liveToken
        // A capture resets the emulator, including its scroll position. Keep the
        // displayed capture stable while reading; Live applies the newest one.
        if context.coordinator.revision != workspace.snapshotRevision &&
            (shouldFollow || dimensionsChanged || context.coordinator.revision < 0) {
            view.applySnapshot(workspace.terminalCapture)
            view.terminal.webLinks = TerminalWebLinks.find(in: TerminalCaptureStyle.parse(workspace.joinedCapture).text)
            context.coordinator.revision = workspace.snapshotRevision
        }
        if shouldFollow { view.followLive = true; view.showLive() }
        context.coordinator.lastLiveToken = liveToken
        if workspace.directInput && !view.terminal.isFirstResponder { _ = view.terminal.becomeFirstResponder() }
        // In read-only mode the terminal may remain first responder for Copy;
        // its empty input view keeps the software keyboard hidden.
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let workspace: HostWorkspace
        var revision = -1
        var lastLiveToken = 0
        init(workspace: HostWorkspace) { self.workspace = workspace }
        // Intentionally ignore emulator layout notifications. Remote changes go through Fit mode only.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            Task { @MainActor in
                guard workspace.directInput else { return }
                await workspace.sendKey(bytes)
            }
        }
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            Task { @MainActor in TerminalWebBrowser.open(url) }
        }
        // Remote OSC clipboard reads/writes retain SwiftTerm's deny-by-default behavior.
    }
}

final class PinnedTerminalView: TerminalView {
    var webLinks: [TerminalWebLink] = []
    var onOpenWebURL: (URL) -> Void = { TerminalWebBrowser.open($0) }
    private var webLinkGestureDelegate: TerminalWebLinkGestureDelegate?

    func configureWebLinkTaps() {
        guard webLinkGestureDelegate == nil else { return }
        let delegate = TerminalWebLinkGestureDelegate(terminal: self)
        webLinkGestureDelegate = delegate
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedWebLink(_:)))
        tap.delegate = delegate
        for recognizer in gestureRecognizers ?? [] {
            guard let existing = recognizer as? UITapGestureRecognizer else { continue }
            if existing.numberOfTapsRequired == 1 { existing.require(toFail: tap) }
            else { tap.require(toFail: existing) }
        }
        addGestureRecognizer(tap)
    }

    func webURL(at point: CGPoint) -> URL? {
        guard !webLinks.isEmpty, point.x >= 0, point.y >= 0 else { return nil }
        let scale = window?.screen.scale ?? 2
        let width = (("W" as NSString).size(withAttributes: [.font: font]).width * scale).rounded() / scale
        let height = ceil(font.ascender - font.descender + font.leading)
        guard width > 0, height > 0 else { return nil }
        let row = Int(point.y / height), column = Int(point.x / width)
        let model = getTerminal()
        guard column < model.cols, model.getScrollInvariantLine(row: row) != nil else { return nil }
        var rendered = "", tappedOffset: Int?
        let radius = max(2, (webLinks.map { $0.text.utf16.count }.max() ?? 0) / max(1, model.cols) + 2)
        for index in max(0, row - radius)...(row + radius) {
            guard let line = model.getScrollInvariantLine(row: index) else { continue }
            var previousCellOffset = rendered.utf16.count
            for col in 0..<min(model.cols, line.count) {
                let continuation = line.getWidth(index: col) == 0
                if index == row, col == column { tappedOffset = continuation ? previousCellOffset : rendered.utf16.count }
                if continuation { continue }
                previousCellOffset = rendered.utf16.count
                let character = model.getCharacter(for: line[col])
                rendered.append(character == "\0" ? " " : character)
            }
        }
        guard let tappedOffset else { return nil }
        return TerminalWebLinks.url(in: rendered, atUTF16Offset: tappedOffset, links: webLinks)
    }

    @discardableResult func openWebLink(at point: CGPoint) -> Bool {
        guard !hasActiveSelection, let url = webURL(at: point) else { return false }
        onOpenWebURL(url); return true
    }
    @objc private func tappedWebLink(_ gesture: UITapGestureRecognizer) {
        if gesture.state == .ended { openWebLink(at: gesture.location(in: self)) }
    }
    var pinnedColumns = 80
    var pinnedRows = 24
    var pasteEnabled = false
    var onPaste: ((String) -> Void)?
    var onBackTab: (() -> Void)?
    override func paste(_ sender: Any?) {
        // SwiftTerm's non-open canPerformAction allows standard edit actions
        // only. Route the high-priority back-tab command through this supported
        // entry point; it must not read the clipboard or fall through to Paste.
        if let command = sender as? UIKeyCommand, command.input == "\t", command.modifierFlags == .shift {
            if keyboardEnabled { onBackTab?() }
            return
        }
        guard pasteEnabled, let text = UIPasteboard.general.string else { return }
        // Use the same tmux paste path as Smart and the Paste button, rather
        // than splitting SwiftTerm's bracketed-paste bytes across SSH commands.
        onPaste?(text)
    }
    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        if pasteEnabled {
            let paste = UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(paste(_:)))
            paste.wantsPriorityOverSystemBehavior = true; commands.append(paste)
        }
        if keyboardEnabled {
            let backTab = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(paste(_:)))
            backTab.wantsPriorityOverSystemBehavior = true; commands.append(backTab)
        }
        return commands
    }
    var keyboardEnabled = false {
        didSet {
            if !inputConfigured {
                standardInput = inputView; standardAccessory = inputAccessoryView; inputConfigured = true
            } else if oldValue == keyboardEnabled { return }
            inputView = keyboardEnabled ? standardInput : readOnlyInput
            inputAccessoryView = keyboardEnabled ? standardAccessory : nil
            if isFirstResponder { reloadInputViews() }
        }
    }
    private var inputConfigured = false
    private var standardInput: UIView?
    private var standardAccessory: UIView?
    private let readOnlyInput = UIView(frame: .zero)
    var onSelection: (() -> Void)?
    var afterLayout: (() -> Void)?
    var manualOffsetChanged: ((CGPoint) -> Void)?
    override var contentOffset: CGPoint {
        didSet {
            if isTracking || isDragging || isDecelerating { manualOffsetChanged?(contentOffset) }
        }
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, !keyboardEnabled { onSelection?() }
        return result
    }
    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        if hasActiveSelection { onSelection?() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let model = getTerminal()
        if model.cols != pinnedColumns || model.rows != pinnedRows { resize(cols: pinnedColumns, rows: pinnedRows) }
        afterLayout?()
    }
}

private final class TerminalWebLinkGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var terminal: PinnedTerminalView?
    init(terminal: PinnedTerminalView) { self.terminal = terminal }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let terminal, !terminal.hasActiveSelection else { return false }
        return terminal.webURL(at: touch.location(in: terminal)) != nil
    }
}

final class TerminalContainer: UIView {
    let horizontal = HorizontalTerminalScrollView()
    let terminal = PinnedTerminalView(frame: .zero)
    var columns = 80
    var rows = 24
    var liveRow = 0
    var followLive = true { didSet { if followLive { readingOffset = nil } } }
    var onManualScroll: (() -> Void)?
    private var readingOffset: CGPoint?
    private var applyingSnapshot = false
    private var aligningLive = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.035, green: 0.055, blue: 0.07, alpha: 1)
        horizontal.alwaysBounceHorizontal = false
        horizontal.showsHorizontalScrollIndicator = true
        horizontal.isDirectionalLockEnabled = true
        terminal.backgroundColor = backgroundColor
        terminal.changeScrollback(2200)
        terminal.keyboardEnabled = false
        terminal.configureWebLinkTaps()
        addSubview(horizontal); horizontal.addSubview(terminal)
        horizontal.isSelectingText = { [weak terminal] in terminal?.hasActiveSelection == true }
        terminal.onSelection = { [weak self] in
            guard let self, !self.applyingSnapshot else { return }
            self.followLive = false; self.readingOffset = self.terminal.contentOffset
            self.onManualScroll?()
        }
        terminal.afterLayout = { [weak self] in self?.pinLiveOffset() }
        terminal.manualOffsetChanged = { [weak self] offset in
            guard let self, !self.applyingSnapshot, !self.aligningLive else { return }
            // Observe actual vertical movement. A pan's initial velocity can be
            // zero; waiting for a direction at .began can leave Live enabled.
            let height = min(self.terminal.contentSize.height, CGFloat(self.liveRow + 1) * ceil(self.terminal.font.lineHeight))
            let inset = max(0, self.terminal.bounds.height - height)
            let bottom = TerminalViewport.bottomOffset(contentHeight: height, viewportHeight: self.terminal.bounds.height, topInset: inset)
            if self.followLive, offset.y < bottom - 1 {
                self.followLive = false
                self.onManualScroll?()
            }
            if !self.followLive { self.readingOffset = offset }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        horizontal.frame = bounds
        let scale = window?.screen.scale ?? 2
        let width = (("W" as NSString).size(withAttributes: [.font: terminal.font]).width * scale).rounded() / scale
        let contentWidth = max(1, CGFloat(columns) * width + 1)
        terminal.pinnedColumns = columns; terminal.pinnedRows = rows
        terminal.frame = CGRect(x: 0, y: 0, width: contentWidth, height: max(1, bounds.height))
        terminal.setNeedsLayout(); terminal.layoutIfNeeded()
        horizontal.contentSize = CGSize(width: contentWidth, height: bounds.height)
        pinLiveOffset()
    }
    func showLive() {
        guard !terminal.isTracking, !terminal.isDragging else { return }
        terminal.clearSelection()
        if !terminal.keyboardEnabled, terminal.isFirstResponder { _ = terminal.resignFirstResponder() }
        // Update the emulator's scroll state as well as UIKit's pixel offset.
        aligningLive = true
        terminal.scroll(toPosition: 1)
        pinLiveOffset()
        aligningLive = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.followLive else { return }
            self.aligningLive = true
            defer { self.aligningLive = false }
            self.layoutIfNeeded(); self.terminal.layoutIfNeeded(); self.pinLiveOffset()
        }
    }
    func applySnapshot(_ capture: String) {
        let offset = terminal.contentOffset
        let position = terminal.scrollPosition
        applyingSnapshot = true
        terminal.feed(text: capture)
        if !followLive {
            readingOffset = offset
            terminal.scroll(toPosition: position)
            terminal.setContentOffset(offset, animated: false)
        }
        // SwiftTerm can update its scroller on the next run-loop turn after feed().
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyingSnapshot = false
            self.pinLiveOffset()
        }
    }
    private func pinLiveOffset() {
        guard !terminal.isTracking, !terminal.isDragging, terminal.bounds.height > 0 else { return }
        if !followLive {
            if let readingOffset, !terminal.isDecelerating, abs(terminal.contentOffset.y - readingOffset.y) > 0.5 {
                terminal.setContentOffset(readingOffset, animated: false)
            }
            return
        }
        let height = min(terminal.contentSize.height, CGFloat(liveRow + 1) * ceil(terminal.font.lineHeight))
        let inset = max(0, terminal.bounds.height - height)
        if abs(terminal.contentInset.top - inset) > 0.5 { terminal.contentInset.top = inset }
        let y = TerminalViewport.bottomOffset(contentHeight: height, viewportHeight: terminal.bounds.height, topInset: inset)
        if abs(terminal.contentOffset.y - y) > 0.5 {
            terminal.setContentOffset(CGPoint(x: terminal.contentOffset.x, y: y), animated: false)
        }
    }
}

/// The outer viewport handles horizontal panning only; vertical history belongs to SwiftTerm.
final class HorizontalTerminalScrollView: UIScrollView {
    var isSelectingText: () -> Bool = { false }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            if isSelectingText() { return false }
            let velocity = panGestureRecognizer.velocity(in: self)
            if abs(velocity.y) >= abs(velocity.x) { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

/// UIKit attributed text preserves per-run backgrounds as well as foreground colors.
struct StyledTerminalLabel: UIViewRepresentable {
    let text: StyledTerminalText
    let fontSize: Double
    var wraps = true
    var selectionResetToken = 0
    var onSelection: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.textContainerInset = .zero
        view.linkTextAttributes = [.foregroundColor: UIColor.systemMint, .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onSelection = onSelection
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if context.coordinator.selectionResetToken != selectionResetToken {
            view.selectedRange = NSRange(location: 0, length: 0)
            if view.isFirstResponder { view.resignFirstResponder() }
            context.coordinator.selectionResetToken = selectionResetToken
        }
        let value = attributedText()
        if !view.attributedText.isEqual(to: value) { view.attributedText = value }
        view.textContainer.lineBreakMode = wraps ? .byWordWrapping : .byClipping
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var onOpenURL: (URL) -> Void = { TerminalWebBrowser.open($0) }
        var onSelection: () -> Void = {}
        var updating = false
        var selectionResetToken = -1
        func openWebURL(_ url: URL) {
            if TerminalWebLinks.isWebURL(url) { onOpenURL(url) }
        }
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content, TerminalWebLinks.isWebURL(url) else { return nil }
            return UIAction(title: "Open in Browser") { [weak self] _ in self?.openWebURL(url) }
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating, textView.selectedRange.length > 0 else { return }
            onSelection()
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let natural = uiView.attributedText.boundingRect(with: CGSize(width: 1_000_000, height: 1_000_000), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let width = wraps ? max(1, proposal.width ?? 320) : max(1, ceil(natural.width) + 1)
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }
    private func attributedText() -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in text.runs {
            let style = run.style
            var font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: style.bold ? .bold : .regular)
            if style.italic, let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                font = UIFont(descriptor: descriptor, size: fontSize)
            }
            let defaultBackground = UIColor(red: 0.035, green: 0.055, blue: 0.07, alpha: 1)
            var foreground = color(style.foreground, bright: style.bold) ?? .label
            var background = color(style.background, bright: false)
            if style.inverse { let old = foreground; foreground = background ?? defaultBackground; background = old }
            if style.dim { foreground = foreground.withAlphaComponent(0.55) }
            if style.hidden { foreground = .clear }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
            if let background { attributes[.backgroundColor] = background }
            if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        for link in TerminalWebLinks.find(in: result.string) { result.addAttribute(.link, value: link.url, range: link.range) }
        return result
    }
    private func color(_ value: TerminalTextColor?, bright: Bool) -> UIColor? {
        guard let value else { return nil }
        let r: Int, g: Int, b: Int
        switch value {
        case .rgb(let red, let green, let blue): r = red; g = green; b = blue
        case .indexed(let raw):
            let index = bright && raw < 8 ? raw + 8 : raw
            if index < 16 {
                let color = SwiftTerm.Color.terminalAppColors[max(0, index)]
                return UIColor(red: CGFloat(color.red) / 65535, green: CGFloat(color.green) / 65535, blue: CGFloat(color.blue) / 65535, alpha: 1)
            } else if index < 232 {
                let levels = [0, 95, 135, 175, 215, 255], n = index - 16
                r = levels[n / 36]; g = levels[(n / 6) % 6]; b = levels[n % 6]
            } else { r = 8 + 10 * (min(255, index) - 232); g = r; b = r }
        }
        return UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

/// Scroll after layout using measured content height, rather than a lazily positioned sentinel.
struct BottomFollowingContent<Content: View>: UIViewControllerRepresentable {
    @Binding var follow: Bool
    let liveToken: Int
    let content: Content
    init(follow: Binding<Bool>, liveToken: Int, @ViewBuilder content: () -> Content) {
        _follow = follow; self.liveToken = liveToken; self.content = content()
    }
    func makeUIViewController(context: Context) -> BottomContentController<Content> { BottomContentController(content: content) }
    func updateUIViewController(_ controller: BottomContentController<Content>, context: Context) {
        controller.loadViewIfNeeded()
        controller.scroll.followsLive = follow
        controller.onManualScroll = { follow = false }
        controller.host.rootView = content
        if controller.lastLiveToken != liveToken {
            controller.scroll.setContentOffset(controller.scroll.contentOffset, animated: false)
            controller.lastLiveToken = liveToken
        }
        controller.view.setNeedsLayout()
        DispatchQueue.main.async { [weak controller] in
            guard let controller else { return }
            controller.view.layoutIfNeeded(); controller.scroll.pinToBottom()
        }
    }
}

final class FollowingScrollView: UIScrollView {
    var followsLive = true
    override func layoutSubviews() { super.layoutSubviews(); pinToBottom() }
    func pinToBottom() {
        guard followsLive, !isTracking, !isDragging, bounds.height > 0 else { return }
        let inset = max(0, bounds.height - contentSize.height)
        if abs(contentInset.top - inset) > 0.5 { contentInset.top = inset }
        let y = TerminalViewport.bottomOffset(contentHeight: contentSize.height, viewportHeight: bounds.height, topInset: inset)
        if abs(contentOffset.y - y) > 0.5 { setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: false) }
    }
}

final class BottomContentController<Content: View>: UIViewController, UIScrollViewDelegate {
    let scroll = FollowingScrollView()
    let host: UIHostingController<Content>
    var onManualScroll: (() -> Void)?
    var lastLiveToken = -1
    private var contentHeight: NSLayoutConstraint?
    init(content: Content) { host = UIHostingController(rootView: content); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear; scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never; scroll.delegate = self
        scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        addChild(host)
        host.view.backgroundColor = .clear; host.view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(host.view); host.didMove(toParent: self)
        let height = host.view.heightAnchor.constraint(equalToConstant: 1)
        contentHeight = height
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), host.view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor), height
        ])
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scroll.bounds.width > 0 {
            let size = host.sizeThatFits(in: CGSize(width: scroll.bounds.width, height: .greatestFiniteMagnitude))
            let height = max(1, ceil(size.height))
            if let contentHeight, abs(contentHeight.constant - height) > 0.5 {
                contentHeight.constant = height
                view.setNeedsLayout()
            }
        }
        scroll.pinToBottom()
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // This view scrolls only vertically. UIKit can report zero velocity at
        // the start of a slow drag, which must still pause Live following.
        scroll.followsLive = false
        onManualScroll?()
    }
}

struct DirectKeyboard: UIViewRepresentable {
    var onInput: (Data) -> Void
    var onPaste: (String) -> Void = { _ in }
    var isActive: () -> Bool = { true }
    func makeUIView(context: Context) -> KeyInputView { KeyInputView() }
    func updateUIView(_ view: KeyInputView, context: Context) {
        view.onInput = { bytes in if isActive() { onInput(bytes) } }
        view.onPaste = { text in if isActive() { onPaste(text) } }
        view.isActive = isActive
        view.requestFocus()
    }
    static func dismantleUIView(_ view: KeyInputView, coordinator: ()) {
        view.isActive = { false }; view.onInput = nil; view.onPaste = nil
        view.resignFirstResponder()
    }
}

final class KeyInputView: UIView, UIKeyInput {
    var onInput: ((Data) -> Void)?
    var onPaste: ((String) -> Void)?
    var isActive: () -> Bool = { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    override var canBecomeFirstResponder: Bool { isActive() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A newly mounted keyboard overlay can receive updateUIView before it
        // has a window. Retry once it is attached, including after Hide keyboard.
        if window != nil { requestFocus() }
    }
    func requestFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.canBecomeFirstResponder, !self.isFirstResponder else { return }
            self.becomeFirstResponder()
        }
    }
    func insertText(_ text: String) { onInput?(Data((text == "\n" ? "\r" : text).utf8)) }
    func deleteBackward() { onInput?(Data([127])) }
    override func paste(_ sender: Any?) {
        guard isActive(), let text = UIPasteboard.general.string else { return }
        onPaste?(text)
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return isActive() && UIPasteboard.general.hasStrings }
        if action == #selector(specialKey(_:)) || action == #selector(controlKey(_:)) { return isActive() }
        return super.canPerformAction(action, withSender: sender)
    }
    override var keyCommands: [UIKeyCommand]? {
        var commands = [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow,
                        UIKeyCommand.inputRightArrow, UIKeyCommand.inputEscape, "\t"].map {
            UIKeyCommand(input: $0, modifierFlags: [], action: #selector(specialKey(_:)))
        }
        commands += "abcdefghijklmnopqrstuvwxyz".map {
            UIKeyCommand(input: String($0), modifierFlags: .control, action: #selector(controlKey(_:)))
        }
        commands.append(UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(specialKey(_:))))
        commands.append(UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(paste(_:))))
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }
    @objc private func specialKey(_ command: UIKeyCommand) {
        guard isActive() else { return }
        if command.input == "\t", command.modifierFlags == .shift {
            onInput?(Data("\u{1b}[Z".utf8)); return
        }
        let sequences = [UIKeyCommand.inputUpArrow: "\u{1b}[A", UIKeyCommand.inputDownArrow: "\u{1b}[B",
                         UIKeyCommand.inputRightArrow: "\u{1b}[C", UIKeyCommand.inputLeftArrow: "\u{1b}[D",
                         UIKeyCommand.inputEscape: "\u{1b}", "\t": "\t"]
        if let value = sequences[command.input ?? ""] { onInput?(Data(value.utf8)) }
    }
    @objc private func controlKey(_ command: UIKeyCommand) {
        if let byte = command.input?.utf8.first { onInput?(Data([byte & 0x1f])) }
    }
}

#if DEBUG
/// Isolated native-view probe; URLs are recorded instead of opening a browser.
@MainActor
enum WebLinkValidation {
    static func run(workspace: HostWorkspace) async {
        guard LibraryStore.screenshotScene == "links" else { return }
        func views() -> [UIView] {
            func flatten(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(flatten) }
            return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).flatMap(flatten)
        }
        func pause() async { try? await Task.sleep(for: .milliseconds(400)) }
        var checks: [String: Bool] = [:]
        for conversation in [false, true] {
            workspace.conversation = conversation
            await pause()
            let prefix = conversation ? "conversation" : "smart"
            let labels = views().compactMap { $0 as? UITextView }.filter { !$0.isEditable }
            let links = labels.flatMap { label -> [URL] in
                var urls: [URL] = []
                label.attributedText.enumerateAttribute(.link, in: NSRange(location: 0, length: label.attributedText.length)) { value, _, _ in
                    if let url = value as? URL { urls.append(url) }
                }
                return urls
            }
            checks[prefix + "WebLinks"] = Set(links.map(\.absoluteString)) == ["https://example.com/docs?a=1&b=2#part", "http://localhost:3000/test"]
            if let label = labels.first(where: { $0.text.contains("https://example.com") }),
               let coordinator = label.delegate as? StyledTerminalLabel.Coordinator {
                var opened: [URL] = []
                coordinator.onOpenURL = { opened.append($0) }
                coordinator.openWebURL(URL(string: "https://example.com/docs?a=1&b=2#part")!)
                coordinator.openWebURL(URL(string: "file:///etc/passwd")!)
                checks[prefix + "BrowserRouting"] = opened.map(\.absoluteString) == ["https://example.com/docs?a=1&b=2#part"]
                let original = label.text ?? ""
                _ = label.becomeFirstResponder()
                label.selectedRange = NSRange(location: 0, length: (original as NSString).length)
                label.copy(nil)
                checks[prefix + "CopyUnchanged"] = UIPasteboard.general.string == original
                label.selectedRange = NSRange(location: 0, length: 0)
                label.resignFirstResponder()
            }
        }
        workspace.conversation = false
        for mode in [DisplayMode.original, .fit] {
            workspace.configureScreenshot(scene: mode == .fit ? "fit" : "copy-original")
            await pause()
            let prefix = mode == .original ? "original" : "fit"
            guard let container = views().compactMap({ $0 as? TerminalContainer }).first else {
                checks[prefix + "TerminalExists"] = false; continue
            }
            let terminal = container.terminal
            let link = "https://example.com/very/long/path?a=1&b=2#section"
            let capture = "🙂 " + link + "\r\nordinary text\r\nlast line"
            terminal.pinnedColumns = 30; terminal.pinnedRows = 10
            terminal.resize(cols: 30, rows: 10)
            terminal.feed(text: "\u{1b}c" + capture)
            terminal.webLinks = TerminalWebLinks.find(in: capture)
            await pause()
            var opened: [URL] = []
            terminal.onOpenWebURL = { opened.append($0) }
            let scale = terminal.window?.screen.scale ?? 2
            let width = (("W" as NSString).size(withAttributes: [.font: terminal.font]).width * scale).rounded() / scale
            let height = ceil(terminal.font.ascender - terminal.font.descender + terminal.font.leading)
            let inputRevision = workspace.inputRevision
            checks[prefix + "WrappedLink"] = terminal.openWebLink(at: CGPoint(x: 3.5 * width, y: 1.5 * height)) && opened.map(\.absoluteString) == [link]
            checks[prefix + "NonLinkIgnored"] = !terminal.openWebLink(at: CGPoint(x: 2.5 * width, y: 2.5 * height)) && opened.count == 1
            terminal.setSelectionRange(start: Position(col: 0, row: 0), end: Position(col: 5, row: 2))
            checks[prefix + "SelectionWins"] = !terminal.openWebLink(at: CGPoint(x: 6.5 * width, y: 0.5 * height)) && opened.count == 1
            checks[prefix + "NoRemoteInput"] = workspace.inputRevision == inputRevision
        }
        let result: [String: Any] = ["checks": checks, "passed": checks.values.allSatisfy { $0 }]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("mux-links-report.json"))
        }
    }
}

/// Native scroll callback regression check using isolated 2,036-row fixtures.
@MainActor
enum HistoryScrollValidation {
    static func writeReport() {
        var metrics: [[String: Any]] = []
        @MainActor func inspect(_ view: UIView) {
            if let scroll = view as? UIScrollView {
                var values: [String: Any] = ["view": String(describing: type(of: scroll)), "height": scroll.bounds.height,
                                "contentHeight": scroll.contentSize.height, "offset": scroll.contentOffset.y,
                                "scrollEnabled": scroll.isScrollEnabled]
                if let following = scroll as? FollowingScrollView {
                    scroll.delegate?.scrollViewWillBeginDragging?(scroll)
                    values["zeroVelocityDragPausesLive"] = !following.followsLive
                    let target = max(0, scroll.contentOffset.y - 2 * scroll.bounds.height)
                    scroll.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                    scroll.layoutIfNeeded()
                    values["holdsTwoPagesBack"] = abs(scroll.contentOffset.y - target) < 1
                    scroll.setContentOffset(.zero, animated: false)
                    scroll.layoutIfNeeded()
                    values["reachesOldestLine"] = abs(scroll.contentOffset.y) < 1
                } else if let terminal = scroll as? PinnedTerminalView {
                    let target = max(0, scroll.contentOffset.y - 2 * scroll.bounds.height)
                    terminal.manualOffsetChanged?(CGPoint(x: scroll.contentOffset.x, y: target))
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: false)
                    scroll.layoutIfNeeded()
                    values["holdsTwoPagesBack"] = abs(scroll.contentOffset.y - target) < 1
                    terminal.manualOffsetChanged?(.zero)
                    scroll.setContentOffset(.zero, animated: false)
                    scroll.layoutIfNeeded()
                    values["reachesOldestLine"] = abs(scroll.contentOffset.y) < 1
                }
                metrics.append(values)
            }
            for child in view.subviews { inspect(child) }
        }
        for window in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) { inspect(window) }
        if let data = try? JSONSerialization.data(withJSONObject: metrics, options: .prettyPrinted) {
            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("mux-scroll-report.json"))
        }
    }
}
/// Runs only against isolated sample captures. Copy actions use the real UIKit
/// responders; the foreground step is completed by backgrounding/reopening the app.
@MainActor
enum CopySelectionValidation {
    static func run(workspace: HostWorkspace) async {
        guard LibraryStore.screenshotScene?.hasPrefix("copy") == true else { return }
        func views() -> [UIView] {
            func flatten(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(flatten) }
            return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).flatMap(flatten)
        }
        func pause() async { try? await Task.sleep(for: .milliseconds(250)) }
        var checks: [String: Bool] = [:]
        func write(_ stage: String) {
            let result: [String: Any] = ["stage": stage, "checks": checks, "passed": checks.values.allSatisfy { $0 }]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("mux-copy-report.json"))
            }
        }
        if let container = views().compactMap({ $0 as? TerminalContainer }).first {
            let terminal = container.terminal
            terminal.feed(text: "\u{1b}cfirst line\r\nsecond line\r\nthird line")
            await pause()
            _ = terminal.becomeFirstResponder()
            terminal.setSelectionRange(start: Position(col: 0, row: 0), end: Position(col: 10, row: 2))
            await pause()
            checks["terminalSelectionPausesLive"] = !container.followLive
            checks["terminalCopyResponderIsReadOnly"] = terminal.isFirstResponder && !terminal.keyboardEnabled && terminal.inputView != nil && terminal.inputAccessoryView == nil
            checks["terminalSelectionVetoesOuterPan"] = container.horizontal.isSelectingText()
            terminal.copy(nil)
            let copied = UIPasteboard.general.string ?? ""
            checks["terminalCopiesMultipleLines"] = copied.contains("first line\nsecond line\nthird line")
            write("complete")
            return
        }
        let textViews = views().compactMap { $0 as? UITextView }.filter { !$0.isEditable }
        guard let label = textViews.max(by: { $0.text.count < $1.text.count }) else {
            checks["selectableTextExists"] = false; write("complete"); return
        }
        let original = label.text ?? ""
        checks["responseContainsMultipleLines"] = original.components(separatedBy: "\n").count > 3
        if !workspace.conversation {
            checks["smartUsesOneSelectionDocument"] = textViews.count == 1
            checks["smartPreservesCaptureText"] = original == TerminalCaptureStyle.parse(workspace.joinedCapture).text
        }
        workspace.directInput = true
        await pause()
        let directKeyboard = views().compactMap { $0 as? KeyInputView }.first
        _ = label.becomeFirstResponder()
        label.selectedRange = NSRange(location: 0, length: (original as NSString).length)
        await pause()
        checks["selectionDisablesDirectKeys"] = !workspace.directInput
        checks["selectionKeepsCopyResponder"] = label.isFirstResponder
        let inputRevision = workspace.inputRevision
        directKeyboard?.insertText("late input")
        await pause()
        checks["selectionRejectsLateDirectInput"] = workspace.inputRevision == inputRevision
        checks["textSelectionPausesLive"] = views().compactMap { $0 as? FollowingScrollView }.contains { !$0.followsLive }
        label.copy(nil)
        checks["nativeCopyPreservesAllLines"] = UIPasteboard.general.string == original
        checks["selectionPreservesColors"] = label.attributedText.length > 0 && label.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil
        if workspace.conversation { write("complete"); return }
        workspace.configureScreenshot(scene: "copy-updated")
        await pause()
        checks["fixturePublishedNewOutput"] = original != TerminalCaptureStyle.parse(workspace.joinedCapture).text
        checks["selectionHoldsDisplayedCapture"] = label.text == original
        write("waiting-for-foreground")
        for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
            await pause()
            let current = views().compactMap { $0 as? UITextView }.first { !$0.isEditable }
            checks["foregroundDisplaysFreshCapture"] = current?.text == TerminalCaptureStyle.parse(workspace.joinedCapture).text
            checks["foregroundResumesFollowing"] = views().compactMap { $0 as? FollowingScrollView }.contains { $0.followsLive }
            checks["foregroundClearsSelection"] = current?.selectedRange.length == 0
            write("complete")
            return
        }
    }
}
#endif
