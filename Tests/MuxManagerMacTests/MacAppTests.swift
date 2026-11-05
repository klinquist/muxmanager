#if os(macOS)
import XCTest
import AppKit
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
#endif
