#if os(macOS)
import XCTest
import AppKit
import SwiftUI
import SwiftTerm
import MuxCore
@testable import Mux_Manager

final class MacAppTests: XCTestCase {
    @MainActor
    func testNativeControlsAndRendering() async throws {
        XCTAssertEqual(LibraryStore.screenshotScene, "mac-tests", "Tests must use fictional data without Keychain/CloudKit/SSH")
        let model = AppModel(library: LibraryStore())
        // Let SwiftUI mount the native window before checking the rendered view.
        try await Task.sleep(for: .seconds(2))
        let checks = await MacValidation.run(model: model)
        for (name, passed) in checks.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(passed, name)
        }
        if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Mux Manager native Mac window"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testInteractiveInputLatencyAndOrdering() async throws {
        let model = AppModel(library: LibraryStore())
        let workspace = try XCTUnwrap(model.activeWorkspace)
        for (name, passed) in await workspace.validateInteractiveInput() { XCTAssertTrue(passed, name) }
    }

    @MainActor
    func testSmartSelectAllCopyAndTypingRestoreTerminalFocus() async throws {
        let model = AppModel(library: LibraryStore())
        let workspace = try XCTUnwrap(model.workspaces[ConnectionProfile.localMacID])
        let hosting = NSHostingView(rootView: WorkspaceView(workspace: workspace, returnToWindows: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let input = try XCTUnwrap(descendants(hosting).compactMap { $0 as? MacPinnedTerminal }.first)
        let output = try XCTUnwrap(descendants(hosting).compactMap { $0 as? MacOutputTextView }.first)
        let sink = RecordingTerminalKeys(); input.terminalDelegate = sink
        for (characters, keyCode, flags, expected) in [
            ("x", UInt16(7), NSEvent.ModifierFlags(), Data("x".utf8)),
            ("\u{7f}", UInt16(51), NSEvent.ModifierFlags(), Data([127])),
            ("\r", UInt16(36), NSEvent.ModifierFlags(), Data([13])),
            ("\u{1}", UInt16(0), NSEvent.ModifierFlags.control, Data([1]))
        ] {
            window.makeFirstResponder(input)
            XCTAssertTrue(NSApp.sendAction(#selector(NSText.selectAll(_:)), to: input, from: nil))
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertFalse(workspace.directInput)
            XCTAssertTrue(window.firstResponder === output)
            let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            XCTAssertTrue(output.validateUserInterfaceItem(pasteItem))
            XCTAssertEqual(output.selectedRange().length, output.string.utf16.count)
            XCTAssertGreaterThan(output.selectedRange().length, 0)
            XCTAssertTrue(descendants(hosting).contains { $0 === input }, "Smart must retain its input view during selection")
            let clipboard = NSPasteboard.withUniqueName()
            clipboard.declareTypes([.string], owner: nil)
            XCTAssertTrue(output.writeSelection(to: clipboard, type: .string))
            XCTAssertEqual(clipboard.string(forType: .string), output.string)
            clipboard.releaseGlobally()
            sink.data = Data()
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: flags.contains(.control) ? "a" : characters, isARepeat: false, keyCode: keyCode))
            output.keyDown(with: event)
            XCTAssertEqual(sink.data, expected, "The first key after Select All must arrive exactly once: keyCode=\(keyCode), expected=\(expected as NSData)")
            XCTAssertTrue(workspace.directInput)
            XCTAssertTrue(window.firstResponder === input)
            XCTAssertEqual(output.selectedRange().length, 0)
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    @MainActor
    func testOriginalSelectAllThenTypingAndClickResumeInput() throws {
        let scroll = MacTerminalScroll(inputOnly: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.close() }
        scroll.layoutSubtreeIfNeeded(); scroll.layoutTerminal()
        let terminal = scroll.terminal
        window.makeFirstResponder(terminal)
        terminal.feed(text: "old output\r\n$ ")
        let sink = RecordingTerminalKeys(); terminal.terminalDelegate = sink
        var directInput = true
        terminal.onSelection = { directInput = false }
        terminal.onFocus = { directInput = true }
        terminal.selectAll(nil)
        XCTAssertTrue(terminal.selection.active)
        XCTAssertFalse(directInput)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
        scroll.prepareForKeyEvent(event)
        terminal.keyDown(with: event)
        XCTAssertEqual(sink.data, Data([127]))
        XCTAssertTrue(directInput)
        XCTAssertFalse(terminal.selection.active)
        terminal.selectAll(nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        terminal.mouseDown(with: click)
        XCTAssertTrue(directInput)
        XCTAssertFalse(terminal.selection.active)
    }

    @MainActor
    func testOptimisticCodexCursorRendering() throws {
        var prediction = CodexInputPrediction()
        let grid = ["Earlier output" + String(repeating: " ", count: 40), "› " + String(repeating: " ", count: 78), "footer"]
        let joined = "Earlier output\n› \nfooter"
        let offset = TerminalSnapshot.smartCursorOffset(grid: grid, joined: joined, row: 1, column: 2, columns: 80)
        prediction.observe(grid: grid, joined: joined,
            cursor: TerminalCursor(row: 1, column: 2, visible: false, smartOffset: offset), columns: 80)
        XCTAssertTrue(prediction.type(Data("hi🙂".utf8)))
        let projected = try XCTUnwrap(prediction.projection)
        let reading = MacReadingScroll(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
        let window = NSWindow(contentRect: reading.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = reading
        // Smart routes key events through a tiny SwiftTerm view, leaving its
        // read-only TextKit output unfocused while the caret is visible.
        let input = MacPinnedTerminal(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        input.alphaValue = 0.01; reading.addSubview(input)
        window.makeFirstResponder(input)
        defer { window.close() }
        reading.text.textStorage?.setAttributedString(MacTerminalStyle.attributed(TerminalCaptureStyle.parse(projected.joined), size: 14))
        reading.text.terminalCursorOffset = projected.cursor.smartOffset
        reading.layoutSubtreeIfNeeded(); reading.layoutText(); reading.text.layoutSubtreeIfNeeded()
        XCTAssertEqual(reading.text.terminalCursorOffset, "Earlier output\n› hi🙂".utf16.count)
        let caret = try XCTUnwrap(reading.text.terminalCaretRect)
        XCTAssertGreaterThan(caret.height, 0)
        XCTAssertTrue(reading.text.visibleRect.intersects(caret))
        XCTAssertTrue(window.firstResponder === input)
        XCTAssertTrue(reading.text.terminalCaretIsSolid)

        let raw = MacTerminalScroll(inputOnly: false)
        raw.frame = reading.frame; raw.columns = 80; raw.liveRow = 1
        raw.apply(TerminalSnapshot.capture(grid: projected.grid, remoteRows: 3,
            x: projected.cursor.column, y: 1, applicationCursor: false, keypad: false, visible: projected.cursor.visible), follow: true)
        XCTAssertEqual(raw.terminal.getTerminal().getCursorLocation().x, 6)
        XCTAssertEqual(raw.terminal.getTerminal().options.cursorStyle.tagName, "steadyBlock")
    }

    @MainActor
    func testLocalTerminalsRemainGroupedWhileRemoteIsActive() throws {
        let model = AppModel(library: LibraryStore())
        let remote = try XCTUnwrap(model.activeWorkspace)
        let local = try XCTUnwrap(model.workspaces[ConnectionProfile.localMacID])
        XCTAssertFalse(remote.profile.isLocalMac)
        XCTAssertEqual(model.sidebarWorkspaces.map(\.id), [local.id, remote.id])
        XCTAssertFalse(local.windows.isEmpty)
        let localSelection = local.selectedWindowID
        let remoteSelection = remote.selectedWindowID
        model.activate(local)
        XCTAssertTrue(model.activeWorkspace === local)
        XCTAssertEqual(remote.selectedWindowID, remoteSelection)
        XCTAssertTrue(remote.isConnected)
        model.activate(remote)
        XCTAssertEqual(model.sidebarWorkspaces.map(\.id), [local.id, remote.id])
        XCTAssertEqual(local.selectedWindowID, localSelection)
        XCTAssertTrue(local.isConnected)
    }

    @MainActor
    func testBuiltInLocalConnectionAndTmux() async throws {
        let model = AppModel(library: LibraryStore())
        XCTAssertEqual(model.connectionProfiles.first?.id, ConnectionProfile.localMacID)
        XCTAssertFalse(model.library.profiles.contains { $0.isLocalMac })
        XCTAssertThrowsError(try model.library.save(.localMac, password: nil))
        let local = LocalTransport(socketName: "mux-validation-" + UUID().uuidString)
        do {
            try await local.connect(onProgress: { _ in })
            let sessions = try await local.tmux("list-sessions -F '#{session_id}'")
            let session = try XCTUnwrap(sessions.split(separator: "\n").first).description
            let control = try await local.startControl(session: session, events: { _ in }, closed: { _ in })
            let result = try await control.command("display-message -p 'local-control-ok'")
            XCTAssertEqual(result, ["local-control-ok"])
            try await Task.sleep(for: .milliseconds(150))
            let metadata = try await control.command("display-message -p '#{pane_width} #{pane_height} #{cursor_x} #{cursor_y}'")
            let dimensions = try XCTUnwrap(metadata.first).split(separator: " ").compactMap { Int($0) }
            XCTAssertEqual(dimensions.count, 4)
            let grid = try await control.command(TmuxCommand.capture(pane: "%0", joined: false, colors: true))
            let joined = try await control.command(TmuxCommand.capture(pane: "%0", joined: true, colors: true))
            let cursorRow = TerminalSnapshot.cursorRow(gridCount: grid.count, remoteRows: dimensions[1], cursorY: dimensions[3])
            XCTAssertNotNil(TerminalSnapshot.smartCursorOffset(grid: grid, joined: joined.joined(separator: "\n"), row: cursorRow, column: dimensions[2], columns: dimensions[0]), "Real local shell prompt must map to a Smart caret")
            let shell = try await local.execute("printf local-shell-ok")
            XCTAssertEqual(shell, "local-shell-ok")
            _ = try await local.tmux("kill-server")
            await local.disconnect()
        } catch {
            _ = try? await local.tmux("kill-server"); await local.disconnect(); throw error
        }
    }

    @MainActor
    func testAutomaticReconnectOnMac() async throws {
        let model = AppModel(library: LibraryStore())
        let workspace = try XCTUnwrap(model.activeWorkspace)
        await workspace.validateAutomaticReconnect()
        let data = try Data(contentsOf: FileManager.default.temporaryDirectory.appendingPathComponent("mux-reconnect-report.json"))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(report["passed"] as? Bool, true, "\(report)")
    }
}

@MainActor
private final class RecordingTerminalKeys: NSObject, TerminalViewDelegate {
    var data = Data()
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { self.data.append(contentsOf: data) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
#endif
