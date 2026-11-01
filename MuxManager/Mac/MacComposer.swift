#if os(macOS)
import SwiftUI
import AppKit

struct MacComposer: NSViewRepresentable {
    @Binding var text: String
    let spelling: Bool
    let focusToken: Int
    let browsingHistory: Bool
    let onSubmit: () -> Void
    let onHistory: (Bool) -> Void
    let onTab: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let view = MacCommandTextView()
        view.delegate = context.coordinator
        view.isRichText = false; view.importsGraphics = false
        view.drawsBackground = false; view.textColor = .labelColor
        view.insertionPointColor = .systemMint
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.autoresizingMask = [.width]
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.setAccessibilityLabel("Message or command")
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? MacCommandTextView else { return }
        context.coordinator.parent = self
        view.onSubmit = onSubmit; view.onHistory = onHistory; view.onTab = onTab
        view.browsingHistory = browsingHistory
        view.wantedSpelling = spelling; view.applySpelling()
        if view.string != text, !view.hasMarkedText() {
            let old = view.selectedRange(), end = NSMaxRange(old) == (view.string as NSString).length
            view.string = text
            let length = (text as NSString).length
            view.setSelectedRange(NSRange(location: end ? length : min(old.location, length), length: 0))
        }
        view.setFrameSize(NSSize(width: max(1, scroll.contentSize.width), height: max(88, view.frame.height)))
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            view.needsInitialFocus = true; view.requestFocus()
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacComposer
        var focusToken = -1
        init(_ parent: MacComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? MacCommandTextView else { return }
            parent.text = view.string; view.applySpelling()
        }
    }
}

final class MacCommandTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onHistory: ((Bool) -> Void)?
    var onTab: (() -> Void)?
    var browsingHistory = false
    var needsInitialFocus = false
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); requestFocus() }
    func requestFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.needsInitialFocus, let window = self.window else { return }
            self.needsInitialFocus = false; window.makeFirstResponder(self)
        }
    }
    var wantedSpelling = true
    func applySpelling() {
        guard !hasMarkedText() else { return }
        isContinuousSpellCheckingEnabled = wantedSpelling
        isAutomaticSpellingCorrectionEnabled = wantedSpelling
    }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if !hasMarkedText() {
            if [36, 76].contains(event.keyCode), modifiers.isEmpty || modifiers == .command { onSubmit?(); return }
            if [36, 76].contains(event.keyCode), modifiers == .shift { insertNewlineIgnoringFieldEditor(self); return }
            if event.keyCode == 48, modifiers.isEmpty { onTab?(); return }
            if modifiers.isEmpty, [125, 126].contains(event.keyCode), canRecall(older: event.keyCode == 126) {
                onHistory?(event.keyCode == 126); return
            }
        }
        super.keyDown(with: event)
    }
    func canRecall(older: Bool) -> Bool {
        guard !hasMarkedText(), selectedRange().length == 0 else { return false }
        if browsingHistory { return true }
        guard let manager = layoutManager, let container = textContainer else { return false }
        manager.ensureLayout(for: container)
        let location = min(selectedRange().location, (string as NSString).length)
        if string.isEmpty { return true }
        let glyph = manager.glyphIndexForCharacter(at: min(location, (string as NSString).length - 1))
        let boundary = older ? 0 : max(0, manager.numberOfGlyphs - 1)
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let edge = manager.lineFragmentRect(forGlyphAt: boundary, effectiveRange: nil)
        return abs(line.minY - edge.minY) < 1
    }
}
#endif
