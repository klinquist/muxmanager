#if os(macOS) && DEBUG
import AppKit
import MuxCore
import SwiftTerm

@MainActor
enum MacValidation {
    @discardableResult
    static func run(model: AppModel) async -> [String: Bool] {
        // The Mac smoke fixture never opens SSH, reads Keychain, or syncs CloudKit.
        var checks: [String: Bool] = [:]
        checks["fixtureHasHostsAndWindows"] = model.library.visibleProfiles.count == 3 && model.activeWorkspace?.windows.count == 5
        checks["macDefaultsToTerminal"] = model.activeWorkspace?.terminalMode == true
        let capture = MacTerminalStyle.attributed(TerminalCaptureStyle.parse("\u{1b}[31mred\u{1b}[0m\nhttps://example.com"), size: 14)
        checks["styledTextAndLinks"] = capture.string == "red\nhttps://example.com" && capture.attribute(.link, at: 5, effectiveRange: nil) != nil
        let window = NSApp.windows.first { $0.contentView != nil && $0.isVisible }
        checks["nativeWindowRendered"] = window != nil && (window?.frame.width ?? 0) >= 900
        checks["windowOpensWithTerminalFocus"] = window?.firstResponder is MacPinnedTerminal

        let reading = MacReadingScroll(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let longWord = String(repeating: "filename", count: 30)
        reading.text.textStorage?.setAttributedString(MacTerminalStyle.attributed(TerminalCaptureStyle.parse(longWord + "\n" + (0..<250).map { "history line \($0)" }.joined(separator: "\n")), size: 14))
        reading.layoutSubtreeIfNeeded(); reading.layoutText()
        checks["smartWrapsLongWords"] = !reading.hasHorizontalScroller && reading.text.frame.width <= reading.contentSize.width + 1
        checks["smartRetainsHistory"] = reading.documentView!.frame.height > reading.contentSize.height * 4
        checks["liveReachesBottom"] = abs(reading.contentView.bounds.maxY - reading.documentView!.frame.height) < 2
        reading.follow = false; reading.contentView.scroll(to: .zero); reading.layoutText()
        checks["historyPositionHeld"] = reading.contentView.bounds.minY < 1
        let readingWindow = NSWindow(contentRect: reading.frame, styleMask: .borderless, backing: .buffered, defer: false)
        readingWindow.isReleasedWhenClosed = false
        readingWindow.contentView = reading
        readingWindow.makeFirstResponder(reading.text)
        defer { readingWindow.close() }
        reading.text.setSelectedRange(NSRange(location: 0, length: (reading.text.string as NSString).length))
        let clipboard = NSPasteboard.withUniqueName()
        clipboard.declareTypes([.string], owner: nil)
        checks["multilineSelection"] = reading.text.selectedRange().length == (reading.text.string as NSString).length
        checks["copyProducesPlainText"] = reading.text.writeSelection(to: clipboard, types: [.string])
        checks["multilineCopy"] = clipboard.string(forType: .string)?.contains("history line 249") == true
        clipboard.releaseGlobally()

        let raw = MacTerminalScroll(inputOnly: false)
        raw.frame = NSRect(x: 0, y: 0, width: 350, height: 240)
        raw.columns = 120; raw.liveRow = 249
        raw.layoutSubtreeIfNeeded(); raw.layoutTerminal()
        raw.apply("\u{1b}c" + (0..<250).map { "line \($0)" }.joined(separator: "\r\n"), follow: true)
        checks["originalPinsRemoteColumns"] = raw.terminal.getTerminal().cols == 120 && raw.terminal.frame.width > raw.contentSize.width
        raw.frame.size.width = 800; raw.layoutTerminal()
        checks["localResizePreservesRemoteColumns"] = raw.terminal.getTerminal().cols == 120
        checks["originalRetainsHistory"] = String(data: raw.terminal.getTerminal().getBufferAsData(), encoding: .utf8)?.contains("line 0") == true && String(data: raw.terminal.getTerminal().getBufferAsData(), encoding: .utf8)?.contains("line 249") == true
        let grid = (0..<90).map { "captured row \($0)" }
        raw.liveRow = 64
        raw.apply(TerminalSnapshot.capture(grid: grid, remoteRows: 36, x: 4, y: 10,
            applicationCursor: false, keypad: false, visible: true), follow: true)
        checks["originalCursorIncludesHistory"] = raw.terminal.getTerminal().getCursorLocation().y == 64
        raw.frame.size.height = 400; raw.layoutTerminal()
        checks["viewportHeightDoesNotMoveCursor"] = raw.terminal.getTerminal().getCursorLocation().y == 64
        reading.text.setSelectedRange(NSRange(location: 0, length: 0))
        reading.text.terminalCursorOffset = 10
        reading.layoutSubtreeIfNeeded(); reading.text.layoutSubtreeIfNeeded()
        checks["smartCaretDoesNotChangeCopyableText"] = reading.text.string.hasPrefix(longWord) && reading.text.terminalCursorOffset == 10
        checks["smartCaretIsVisible"] = reading.text.terminalCaretRect.map { $0.height > 0 && $0.width == 2 } == true
        var paused = false
        raw.onManualScroll = { paused = true }
        raw.contentView.scroll(to: .zero)
        checks["draggingHistoryPausesLive"] = paused
        let sink = KeySink(); raw.terminal.terminalDelegate = sink
        raw.terminal.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        checks["terminalBackTab"] = sink.data == Data([27, 91, 90])
        sink.data = Data()
        raw.terminal.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        checks["returnGoesToTerminal"] = sink.data == Data([13])
        sink.data = Data()
        raw.terminal.doCommand(by: #selector(NSResponder.insertTab(_:)))
        checks["tabGoesToTerminal"] = sink.data == Data([9])
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        checks["noComposerInMacWindow"] = window?.contentView.map { !descendants($0).contains { ($0 as? NSTextView)?.accessibilityLabel() == "Message or command" } } == true
        if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("mux-mac-window.png"))
        }
        if let data = try? JSONSerialization.data(withJSONObject: ["checks": checks, "passed": checks.values.allSatisfy { $0 }], options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("mux-mac-report.json"))
        }
        return checks
    }
    private final class KeySink: NSObject, TerminalViewDelegate {
        var data = Data()
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) { self.data.append(contentsOf: data) }
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
#endif
