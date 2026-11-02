#if os(macOS)
import SwiftUI
import AppKit
import SwiftTerm
import MuxCore

struct MacTerminalCanvas: NSViewRepresentable {
    @ObservedObject var workspace: HostWorkspace
    @Binding var follow: Bool
    let liveToken: Int
    var inputOnly = false
    func makeCoordinator() -> Coordinator { Coordinator(workspace) }
    func makeNSView(context: Context) -> MacTerminalScroll {
        let view = MacTerminalScroll(inputOnly: inputOnly)
        view.terminal.terminalDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: MacTerminalScroll, context: Context) {
        view.onManualScroll = { follow = false }
        view.terminal.onSelection = { follow = false; workspace.directInput = false }
        view.terminal.onFocus = { if workspace.terminalMode && workspace.isReadyForInput { workspace.directInput = true } }
        view.terminal.allowMouseReporting = false // Snapshots cannot preserve live TUI mouse coordinates.
        let window = workspace.selectedWindowID, intent = workspace.connectionIntent
        view.terminal.onPaste = { text in
            guard let window else { return }
            Task { await workspace.pasteIntoTerminal(text, windowID: window, connectionIntent: intent) }
        }
        view.terminal.canPaste = workspace.terminalMode && workspace.isReadyForInput && !workspace.sending
        let font = NSFont.monospacedSystemFont(ofSize: workspace.fontSize, weight: .regular)
        let changed = view.terminal.font.pointSize != font.pointSize || view.columns != workspace.remoteColumns
        if view.terminal.font.pointSize != font.pointSize { view.terminal.font = font }
        view.columns = workspace.remoteColumns; view.rows = workspace.terminalBufferRows; view.liveRow = workspace.terminalLiveRow
        view.layoutTerminal()
        let live = follow || context.coordinator.lastLiveToken != liveToken
        if !inputOnly && ((workspace.snapshotRevision != context.coordinator.revision && live) || context.coordinator.revision < 0 || changed) {
            view.apply(workspace.terminalCapture, follow: live)
            context.coordinator.revision = workspace.snapshotRevision
        }
        if live && !inputOnly { view.showLive() }
        context.coordinator.lastLiveToken = liveToken
        view.wantsFocus = workspace.directInput && workspace.terminalMode
        if view.wantsFocus && view.window?.firstResponder !== view.terminal {
            DispatchQueue.main.async { [weak view, weak workspace] in
                guard let view, workspace?.directInput == true else { return }
                view.window?.makeFirstResponder(view.terminal)
            }
        }
    }
    final class Coordinator: NSObject, TerminalViewDelegate {
        weak var workspace: HostWorkspace?
        var revision = -1, lastLiveToken = -1
        init(_ workspace: HostWorkspace) { self.workspace = workspace }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {} // Local sizing never changes tmux.
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            Task { @MainActor [weak workspace] in
                guard let workspace, workspace.terminalMode, workspace.directInput else { return }
                await workspace.sendKey(bytes)
            }
        }
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), TerminalWebLinks.isWebURL(url) else { return }
            NSWorkspace.shared.open(url)
        }
        // Remote OSC clipboard access retains SwiftTerm's deny-by-default behavior.
    }
}

final class MacPinnedTerminal: TerminalView {
    var pinnedColumns = 80, pinnedRows = 24
    var canPaste = false
    var onPaste: ((String) -> Void)?
    var onSelection: (() -> Void)?
    var onFocus: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if getTerminal().cols != pinnedColumns || getTerminal().rows != pinnedRows { resize(cols: pinnedColumns, rows: pinnedRows) }
    }
    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        if selection.active { onSelection?() }
    }
    override func mouseDown(with event: NSEvent) {
        let selecting = selection.active || event.clickCount > 1
        super.mouseDown(with: event)
        if !selecting { onFocus?() }
    }
    override func paste(_ sender: Any) {
        guard canPaste, let text = NSPasteboard.general.string(forType: .string) else { return }
        onPaste?(text)
    }
}

private final class MacTerminalDocument: NSView { override var isFlipped: Bool { true } }

final class MacTerminalScroll: NSScrollView {
    let terminal = MacPinnedTerminal(frame: .zero)
    var columns = 80, rows = 24, liveRow = 0
    private let document = MacTerminalDocument()
    private var cellHeight: CGFloat = 1
    private var topPadding: CGFloat = 0
    var wantsFocus = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus { window?.makeFirstResponder(terminal) }
    }
    var onManualScroll: (() -> Void)?
    private let inputOnly: Bool
    private var eventMonitor: Any?
    private var capture = ""
    private var layingOut = false
    private var aligningLive = false
    private var lastScrollY: CGFloat = 0
    init(inputOnly: Bool) {
        self.inputOnly = inputOnly
        super.init(frame: .zero)
        drawsBackground = true; backgroundColor = NSColor(red: 0.035, green: 0.055, blue: 0.07, alpha: 1)
        terminal.nativeBackgroundColor = backgroundColor; terminal.nativeForegroundColor = .white
        terminal.changeScrollback(2200)
        hasHorizontalScroller = !inputOnly; hasVerticalScroller = !inputOnly; autohidesScrollers = true
        document.addSubview(terminal); documentView = document
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        if !inputOnly {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      let hit = self.window?.contentView?.hitTest(self.window!.contentView!.convert(event.locationInWindow, from: nil)),
                      hit === self || hit.isDescendant(of: self) else { return event }
                if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), self.terminal.frame.width > self.contentSize.width {
                    let x = min(max(0, self.contentView.bounds.origin.x - event.scrollingDeltaX), self.terminal.frame.width - self.contentSize.width)
                    self.contentView.scroll(to: NSPoint(x: x, y: self.contentView.bounds.origin.y)); self.reflectScrolledClipView(self.contentView)
                    return nil
                }
                if event.scrollingDeltaY != 0 { self.onManualScroll?(); self.scrollWheel(with: event); return nil }
                return event
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self); if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }
    @objc private func clipBoundsChanged() {
        let y = contentView.bounds.origin.y
        defer { lastScrollY = y }
        if !layingOut && !aligningLive && abs(y - lastScrollY) > 0.5 { onManualScroll?() }
    }
    override func layout() { super.layout(); layoutTerminal() }
    func layoutTerminal() {
        guard !layingOut else { return }; layingOut = true; defer { layingOut = false }
        let font = terminal.font
        let width = ("W" as NSString).size(withAttributes: [.font: font]).width
        let height = max(1, ceil(font.ascender - font.descender + font.leading))
        let rows = inputOnly ? 24 : max(1, self.rows)
        cellHeight = height
        topPadding = inputOnly ? 0 : max(0, contentSize.height - CGFloat(liveRow + 1) * height)
        let size = NSSize(width: max(contentSize.width, CGFloat(columns) * width + 16), height: CGFloat(rows) * height)
        document.setFrameSize(NSSize(width: size.width, height: max(contentSize.height, size.height + topPadding)))
        terminal.setFrameOrigin(NSPoint(x: 0, y: topPadding))
        let changed = terminal.pinnedColumns != columns || terminal.pinnedRows != rows || terminal.frame.size != size
        let position = terminal.scrollPosition
        terminal.pinnedColumns = columns; terminal.pinnedRows = rows
        if terminal.frame.size != size { terminal.setFrameSize(size) }
        if terminal.getTerminal().cols != columns || terminal.getTerminal().rows != rows { terminal.resize(cols: columns, rows: rows) }
        if changed && !capture.isEmpty { feedCapture(capture); terminal.scroll(toPosition: position) }
    }
    func apply(_ text: String, follow: Bool) {
        let position = terminal.scrollPosition
        capture = text; rows = max(1, text.components(separatedBy: "\r\n").count); layoutTerminal()
        terminal.selectNone(); feedCapture(text)
        if follow { showLive() } else { terminal.scroll(toPosition: position) }
    }
    private func feedCapture(_ text: String) {
        terminal.feed(text: text)
        terminal.getTerminal().setCursorStyle(.steadyBlock)
    }
    func showLive() {
        aligningLive = true; defer { aligningLive = false }
        contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: max(0, topPadding + CGFloat(liveRow + 1) * cellHeight - contentSize.height)))
        reflectScrolledClipView(contentView)
        terminal.needsDisplay = true
    }
}
#endif
