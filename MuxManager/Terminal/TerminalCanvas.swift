import SwiftUI
import UIKit
import SwiftTerm
import MuxCore

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
            context.coordinator.revision = workspace.snapshotRevision
        }
        if shouldFollow { view.followLive = true; view.showLive() }
        context.coordinator.lastLiveToken = liveToken
        if workspace.directInput && !view.terminal.isFirstResponder { _ = view.terminal.becomeFirstResponder() }
        if !workspace.directInput && view.terminal.isFirstResponder { _ = view.terminal.resignFirstResponder() }
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
            guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
            Task { @MainActor in UIApplication.shared.open(url) }
        }
        // Clipboard reads and remote OSC writes retain SwiftTerm's deny-by-default behavior.
    }
}

final class PinnedTerminalView: TerminalView {
    var pinnedColumns = 80
    var pinnedRows = 24
    var keyboardEnabled = false
    var afterLayout: (() -> Void)?
    var manualOffsetChanged: ((CGPoint) -> Void)?
    override var contentOffset: CGPoint {
        didSet {
            if isTracking || isDragging || isDecelerating { manualOffsetChanged?(contentOffset) }
        }
    }
    override var canBecomeFirstResponder: Bool { keyboardEnabled && super.canBecomeFirstResponder }
    override func layoutSubviews() {
        super.layoutSubviews()
        let model = getTerminal()
        if model.cols != pinnedColumns || model.rows != pinnedRows { resize(cols: pinnedColumns, rows: pinnedRows) }
        afterLayout?()
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
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.035, green: 0.055, blue: 0.07, alpha: 1)
        horizontal.alwaysBounceHorizontal = false
        horizontal.showsHorizontalScrollIndicator = true
        horizontal.isDirectionalLockEnabled = true
        terminal.backgroundColor = backgroundColor
        terminal.changeScrollback(2200)
        addSubview(horizontal); horizontal.addSubview(terminal)
        terminal.afterLayout = { [weak self] in self?.pinLiveOffset() }
        terminal.manualOffsetChanged = { [weak self] offset in
            guard let self, !self.followLive, !self.applyingSnapshot else { return }
            self.readingOffset = offset
        }
        terminal.panGestureRecognizer.addTarget(self, action: #selector(terminalPanned))
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
        // Update the emulator's scroll state as well as UIKit's pixel offset.
        terminal.scroll(toPosition: 1)
        pinLiveOffset()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.followLive else { return }
            self.layoutIfNeeded(); self.terminal.layoutIfNeeded(); self.pinLiveOffset()
        }
    }
    @objc private func terminalPanned() {
        let velocity = terminal.panGestureRecognizer.velocity(in: terminal)
        if terminal.panGestureRecognizer.state == .began, abs(velocity.y) > abs(velocity.x) {
            followLive = false
            readingOffset = terminal.contentOffset
            onManualScroll?()
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
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
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
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let value = attributedText()
        if !view.attributedText.isEqual(to: value) { view.attributedText = value }
        view.textContainer.lineBreakMode = wraps ? .byWordWrapping : .byClipping
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
        let velocity = scrollView.panGestureRecognizer.velocity(in: scrollView)
        if abs(velocity.y) > abs(velocity.x) { scroll.followsLive = false; onManualScroll?() }
    }
}

struct DirectKeyboard: UIViewRepresentable {
    var onInput: (Data) -> Void
    func makeUIView(context: Context) -> KeyInputView { KeyInputView() }
    func updateUIView(_ view: KeyInputView, context: Context) {
        view.onInput = onInput
        DispatchQueue.main.async { if view.window != nil && !view.isFirstResponder { view.becomeFirstResponder() } }
    }
    static func dismantleUIView(_ view: KeyInputView, coordinator: ()) { view.resignFirstResponder() }
}

final class KeyInputView: UIView, UIKeyInput {
    var onInput: ((Data) -> Void)?
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    override var canBecomeFirstResponder: Bool { true }
    func insertText(_ text: String) { onInput?(Data((text == "\n" ? "\r" : text).utf8)) }
    func deleteBackward() { onInput?(Data([127])) }
    override var keyCommands: [UIKeyCommand]? {
        var commands = [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow,
                        UIKeyCommand.inputRightArrow, UIKeyCommand.inputEscape, "\t"].map {
            UIKeyCommand(input: $0, modifierFlags: [], action: #selector(specialKey(_:)))
        }
        commands += "abcdefghijklmnopqrstuvwxyz".map {
            UIKeyCommand(input: String($0), modifierFlags: .control, action: #selector(controlKey(_:)))
        }
        return commands
    }
    @objc private func specialKey(_ command: UIKeyCommand) {
        let sequences = [UIKeyCommand.inputUpArrow: "\u{1b}[A", UIKeyCommand.inputDownArrow: "\u{1b}[B",
                         UIKeyCommand.inputRightArrow: "\u{1b}[C", UIKeyCommand.inputLeftArrow: "\u{1b}[D",
                         UIKeyCommand.inputEscape: "\u{1b}", "\t": "\t"]
        if let value = sequences[command.input ?? ""] { onInput?(Data(value.utf8)) }
    }
    @objc private func controlKey(_ command: UIKeyCommand) {
        if let byte = command.input?.utf8.first { onInput?(Data([byte & 0x1f])) }
    }
}
