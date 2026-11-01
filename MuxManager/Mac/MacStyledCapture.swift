#if os(macOS)
import SwiftUI
import AppKit
import SwiftTerm
import MuxCore

@MainActor
enum MacTerminalStyle {
    static let background = NSColor(red: 0.035, green: 0.055, blue: 0.07, alpha: 1)
    static func attributed(_ text: StyledTerminalText, size: Double) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in text.runs {
            let style = run.style
            var font = NSFont.monospacedSystemFont(ofSize: size, weight: style.bold ? .bold : .regular)
            if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var foreground = color(style.foreground, bright: style.bold) ?? .white
            var back = color(style.background, bright: false)
            if style.inverse { let previous = foreground; foreground = back ?? background; back = previous }
            if style.dim { foreground = foreground.withAlphaComponent(0.55) }
            if style.hidden { foreground = .clear }
            var values: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
            if let back { values[.backgroundColor] = back }
            if style.underline { values[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style.strikethrough { values[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: run.text, attributes: values))
        }
        for link in TerminalWebLinks.find(in: result.string) { result.addAttribute(.link, value: link.url, range: link.range) }
        return result
    }
    static func color(_ value: TerminalTextColor?, bright: Bool) -> NSColor? {
        guard let value else { return nil }
        let r: Int, g: Int, b: Int
        switch value {
        case .rgb(let red, let green, let blue): r = red; g = green; b = blue
        case .indexed(let raw):
            let index = bright && raw < 8 ? raw + 8 : raw
            if index < 16 {
                let color = SwiftTerm.Color.terminalAppColors[max(0, index)]
                return NSColor(red: CGFloat(color.red) / 65535, green: CGFloat(color.green) / 65535, blue: CGFloat(color.blue) / 65535, alpha: 1)
            } else if index < 232 {
                let palette = [0, 95, 135, 175, 215, 255], n = index - 16
                r = palette[n / 36]; g = palette[(n / 6) % 6]; b = palette[n % 6]
            } else { r = 8 + 10 * (min(255, index) - 232); g = r; b = r }
        }
        return NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}

struct MacStyledCapture: NSViewRepresentable {
    let capture: String
    let fontSize: Double
    @Binding var follow: Bool
    let liveToken: Int
    let onSelection: () -> Void
    let onFocus: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MacReadingScroll {
        let view = MacReadingScroll()
        view.text.delegate = context.coordinator
        return view
    }
    func updateNSView(_ view: MacReadingScroll, context: Context) {
        context.coordinator.onSelection = onSelection
        view.text.onTerminalFocus = onFocus
        view.onManualScroll = { follow = false }
        view.follow = follow
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        let value = MacTerminalStyle.attributed(TerminalCaptureStyle.parse(capture), size: fontSize)
        if !view.text.attributedString().isEqual(to: value) { view.text.textStorage?.setAttributedString(value) }
        if context.coordinator.lastLiveToken != liveToken { view.follow = true; view.text.setSelectedRange(NSRange(location: 0, length: 0)) }
        context.coordinator.lastLiveToken = liveToken
        view.layoutText()
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelection: () -> Void = {}
        var updating = false, lastLiveToken = -1
        func textViewDidChangeSelection(_ notification: Notification) {
            if !updating, let view = notification.object as? NSTextView, view.selectedRange().length > 0 { onSelection() }
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, TerminalWebLinks.isWebURL(url) else { return false }
            NSWorkspace.shared.open(url); return true
        }
    }
}

private final class MacFlippedDocument: NSView { override var isFlipped: Bool { true } }

final class MacOutputTextView: NSTextView {
    var onTerminalFocus: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if selectedRange().length == 0 && event.clickCount == 1 { onTerminalFocus?() }
    }
    // Terminal output is copied as plain text, including all selected paragraphs.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return super.writeSelection(to: pasteboard, type: type) }
        let source = string as NSString
        let selections = selectedRanges.map(\.rangeValue).filter { $0.length > 0 && NSMaxRange($0) <= source.length }
        guard !selections.isEmpty else { return false }
        return pasteboard.setString(selections.map { source.substring(with: $0) }.joined(separator: "\n"), forType: .string)
    }
}

final class MacReadingScroll: NSScrollView {
    let text = MacOutputTextView()
    private let document = MacFlippedDocument()
    var onManualScroll: (() -> Void)?
    var follow = true
    private var layingOut = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = true; hasHorizontalScroller = false; autohidesScrollers = true
        drawsBackground = true; backgroundColor = MacTerminalStyle.background
        text.drawsBackground = true; text.backgroundColor = backgroundColor
        text.isEditable = false; text.isSelectable = true; text.isRichText = true
        text.isHorizontallyResizable = false; text.isVerticallyResizable = true
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineBreakMode = .byWordWrapping
        text.linkTextAttributes = [.foregroundColor: NSColor.systemMint, .underlineStyle: NSUnderlineStyle.single.rawValue]
        document.addSubview(text); documentView = document
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY != 0 { follow = false; onManualScroll?() }
        super.scrollWheel(with: event)
    }
    override func layout() { super.layout(); layoutText() }
    func layoutText() {
        guard !layingOut, contentSize.width > 0 else { return }; layingOut = true; defer { layingOut = false }
        let width = contentSize.width
        text.setFrameSize(NSSize(width: width, height: max(1, text.frame.height)))
        text.textContainer?.containerSize = NSSize(width: max(1, width - 24), height: .greatestFiniteMagnitude)
        if let manager = text.layoutManager, let container = text.textContainer {
            manager.ensureLayout(for: container)
            let height = ceil(manager.usedRect(for: container).height) + 24
            document.setFrameSize(NSSize(width: width, height: max(contentSize.height, height)))
            text.setFrameOrigin(NSPoint(x: 0, y: max(0, contentSize.height - height)))
            text.setFrameSize(NSSize(width: width, height: height))
        }
        if follow { contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - contentSize.height))); reflectScrolledClipView(contentView) }
    }
}
#endif
