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
        let text = MacCommandTextView()
        text.wantedSpelling = true; text.applySpelling()
        checks["composerSpellingAndAutocorrection"] = text.isContinuousSpellCheckingEnabled && text.isAutomaticSpellingCorrectionEnabled
        var submissions = 0
        text.onSubmit = { submissions += 1 }
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        text.keyDown(with: enter)
        checks["returnSubmitsOnce"] = submissions == 1
        let shift = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        text.keyDown(with: shift)
        checks["shiftReturnInsertsNewline"] = submissions == 1 && text.string == "\n"
        text.wantedSpelling = false; text.applySpelling()
        checks["spellingToggleDisablesBoth"] = !text.isContinuousSpellCheckingEnabled && !text.isAutomaticSpellingCorrectionEnabled
        let capture = MacTerminalStyle.attributed(TerminalCaptureStyle.parse("\u{1b}[31mred\u{1b}[0m\nhttps://example.com"), size: 14)
        checks["styledTextAndLinks"] = capture.string == "red\nhttps://example.com" && capture.attribute(.link, at: 5, effectiveRange: nil) != nil
        let window = NSApp.windows.first { $0.contentView != nil && $0.isVisible }
        checks["nativeWindowRendered"] = window != nil && (window?.frame.width ?? 0) >= 900

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
        let sink = KeySink(); raw.terminal.terminalDelegate = sink
        raw.terminal.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        checks["terminalBackTab"] = sink.data == Data([27, 91, 90])
        var histories: [Bool] = []; var tabs = 0
        text.onHistory = { histories.append($0) }; text.onTab = { tabs += 1 }
        text.string = ""; text.setSelectedRange(NSRange(location: 0, length: 0))
        for code: UInt16 in [126, 125, 48] {
            text.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
        }
        checks["composerHistoryAndTab"] = histories == [true, false] && tabs == 1
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
