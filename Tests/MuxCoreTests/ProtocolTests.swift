import XCTest
@testable import MuxCore

final class ProtocolTests: XCTestCase {
    func testEveryPacketBoundaryIncludingUnicodeAndOctal() {
        let wire = Data("%begin 123 4 0\nhello 🦊\n%end 123 4 0\n%output %9 a\\015\\012\\033[31m\\134\n".utf8)
        let expected: [ControlEvent] = [.response(token: "123 4 0", lines: ["hello 🦊"], failed: false),
                                        .output(pane: "%9", bytes: Data("a\r\n\u{1b}[31m\\".utf8))]
        for split in 0...wire.count {
            var parser = TmuxControlParser()
            let actual = parser.feed(wire.prefix(split)) + parser.feed(wire.dropFirst(split))
            XCTAssertEqual(actual, expected, "split \(split)")
        }
    }
    func testResponseContentIsNotMistakenForNotifications() {
        var parser = TmuxControlParser()
        XCTAssertEqual(parser.feed(Data("%begin 1 2 0\n%output %1 text\n%end 1 9 0\n%end 1 2 0\n".utf8)),
                       [.response(token: "1 2 0", lines: ["%output %1 text", "%end 1 9 0"], failed: false)])
    }
    func testErrorsAndLimits() {
        var parser = TmuxControlParser(limit: 32)
        XCTAssertEqual(parser.feed(Data("%begin 1 2 0\nno server\n%error 1 2 0\n".utf8)),
                       [.response(token: "1 2 0", lines: ["no server"], failed: true)])
        XCTAssertEqual(parser.feed(Data(repeating: 65, count: 33)).count, 1)
    }
    func testInputCannotInjectTmuxCommands() throws {
        let text = "hello\n; kill-server\n%exit\n🦊"
        let commands = try TmuxCommand.sendBytes(Data(text.utf8), pane: "%9")
        XCTAssertTrue(commands.allSatisfy { !$0.contains("\n") && !$0.contains("kill-server") })
        let encoded = commands.joined().components(separatedBy: "\" ").last!
        let decoded = Data(encoded.split(separator: " ").compactMap { UInt8($0, radix: 16) })
        XCTAssertEqual(decoded, Data(text.utf8))
        XCTAssertThrowsError(try TmuxCommand.sendBytes(Data(), pane: "%9; kill-server"))
    }
    func testDiscoveryAndVersion() {
        XCTAssertTrue(TmuxVersion("tmux 3.2a")!.isSupported)
        XCTAssertFalse(TmuxVersion("tmux 3.1c")!.isSupported)
        XCTAssertTrue(TmuxVersion("tmux 4.0")!.isSupported)
        let windows = TmuxCommand.windows(["@1\t2\tmy\\ window\t%4\t160\t48\tcodex", "bogus"], session: "$0")
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.name, "my window")
        XCTAssertEqual(windows.first?.columns, 160)
    }
    func testDiscoveryPreservesSessionZeroUnderscoresAndUnicode() {
        // The reported "$0_0" is a sanitized wire record, not an underscore delimiter.
        XCTAssertTrue(TmuxCommand.sessions(["$0_0"]).isEmpty)
        XCTAssertEqual(TmuxCommand.sessions(["$0\t0"]), [RemoteSession(id: "$0", name: "0")])
        XCTAssertEqual(TmuxCommand.sessions(["$12\tmy_session_🦊"]), [RemoteSession(id: "$12", name: "my_session_🦊")])
        let windows = TmuxCommand.windows(["@1\t0\tbuild_🦊\\ work\t%2\t160\t40\tcodex"], session: "$0")
        XCTAssertEqual(windows.first?.name, "build_🦊 work")
    }

    #if os(macOS)
    func testUTF8FlagAndDiscoveryFormatSurviveExecShell() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mux-quote-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake 'tmux")
        try Data("#!/bin/sh\nprintf '%s\\0' \"$@\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        for arguments in ["list-sessions -F \(TmuxCommand.quote(TmuxCommand.sessionFormat))",
                          "list-windows -t \(TmuxCommand.quote("$0")) -F \(TmuxCommand.quote(TmuxCommand.windowFormat))",
                          try TmuxCommand.attach(session: "$0")] {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", TmuxCommand.invocation(executable: executable.path, arguments: arguments)]
            process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let argv = String(decoding: data, as: UTF8.self).components(separatedBy: "\0").dropLast()
            XCTAssertEqual(argv.first, "-u", "Every tmux entry point must explicitly enable UTF-8")
            if arguments.hasPrefix("list-sessions") { XCTAssertEqual(argv.last, TmuxCommand.sessionFormat) }
            if arguments.hasPrefix("list-windows") {
                XCTAssertEqual(argv.last, TmuxCommand.windowFormat)
                XCTAssertTrue(argv.contains("$0"), "Session IDs must not undergo shell expansion")
            }
            if arguments.hasPrefix("-C") { XCTAssertTrue(argv.contains("ignore-size")); XCTAssertEqual(argv.last, "$0") }
        }
    }
    #endif
    func testMultilinePasteUsesTmuxModeDetectionAndPrivateBuffer() throws {
        let commands = try TmuxCommand.pasteCommands("one\ntwo; kill-server\n\"$HOME\\", pane: "%9", buffer: "mux-123", submit: true)
        XCTAssertEqual(commands.count, 3)
        XCTAssertTrue(commands.allSatisfy { !$0.contains("\n") && !$0.contains("\r") })
        XCTAssertTrue(commands[0].contains("one\\ntwo; kill-server\\n\\\"\\$HOME\\\\"))
        XCTAssertEqual(commands[1], "paste-buffer -p -r -d -b \"mux-123\" -t \"%9\"")
        XCTAssertEqual(commands[2], "send-keys -t \"%9\" Enter")
        XCTAssertEqual(try TmuxCommand.pasteCommands("a\nb", pane: "%1", buffer: "mux-1", submit: false).count, 2)
        XCTAssertThrowsError(try TmuxCommand.pasteCommands("a\0b", pane: "%1", buffer: "mux-1", submit: true))
    }
    func testTerminalPastePreservesShortAndMultilinePayloadWithoutSubmitting() throws {
        for (text, normalized) in [("x", "x"), ("\n", "\n"), ("a\r\nb\rc🙂", "a\nb\nc🙂")] {
            let commands = try TmuxCommand.pasteCommands(text, pane: "%1", buffer: "mux-paste", submit: false)
            XCTAssertEqual(commands.count, 2)
            XCTAssertEqual(commands[0], "set-buffer -b \"mux-paste\" -- \(TmuxCommand.quote(normalized))")
            XCTAssertEqual(commands[1], "paste-buffer -p -r -d -b \"mux-paste\" -t \"%1\"")
            XCTAssertFalse(commands.contains { $0.hasPrefix("send-keys") })
        }
    }
    func testSmartPreservesHardNewlinesAndFixedContent() {
        let input = "A long logical line with words.\nA deliberate new paragraph.\n```swift\nlet x = 1\n```\nname   value\n│ table │"
        let blocks = SmartPresentation.blocks(from: input)
        XCTAssertEqual(blocks.map(\.text).joined(separator: "\n"), input)
        XCTAssertEqual(blocks.first?.kind, .prose)
        XCTAssertEqual(blocks.last?.kind, .fixed)
    }
    func testConversationNeverDropsAmbiguousOrApprovalContent() {
        let input = "unrecognized header\n› prompt\n• response\nWould you like to run?\n1. Yes\n2. No\nunknown footer"
        let blocks = CodexPresentation.blocks(from: input)
        XCTAssertEqual(blocks.map(\.role), [.terminal, .user, .assistant, .terminal])
        XCTAssertTrue(blocks.last!.text.contains("unknown footer"))
        XCTAssertTrue(blocks.last!.text.contains("1. Yes"))
    }
    func testResizeRestorationHonorsOtherClientsAndServerRestart() {
        let original = WindowSizing(columns: 180, rows: 50, localPolicy: nil)
        let applied = WindowSizing(columns: 44, rows: 25, localPolicy: "manual")
        let lease = ResizeLease(hostID: UUID(), serverIdentity: "server-1", windowID: "@2", previous: original, applied: applied)
        XCTAssertEqual(lease.restorationCommands(current: applied, serverIdentity: "server-1").count, 2)
        XCTAssertTrue(lease.restorationCommands(current: original, serverIdentity: "server-1").isEmpty)
        XCTAssertTrue(lease.restorationCommands(current: applied, serverIdentity: "server-2").isEmpty)
        XCTAssertEqual(lease.restorationCommands(current: applied, serverIdentity: "server-1").last, "set-option -wu -t \"@2\" window-size")
    }
    func testOfflineDeletionWinsOverStaleCopy() {
        let older = ConnectionProfile(name: "Host", hostname: "server", username: "me", modifiedAt: Date(timeIntervalSince1970: 1))
        var newer = older; newer.deleted = true; newer.modifiedAt = Date(timeIntervalSince1970: 2)
        XCTAssertEqual(ProfileMerge.merge(local: [newer], remote: [older]), [newer])
    }
    func testInterruptedFitUpdateCanRestoreLastAcknowledgedSize() {
        let original = WindowSizing(columns: 160, rows: 40, localPolicy: nil)
        let portrait = WindowSizing(columns: 44, rows: 25, localPolicy: "manual")
        let landscape = WindowSizing(columns: 90, rows: 15, localPolicy: "manual")
        var lease = ResizeLease(hostID: UUID(), serverIdentity: "server", windowID: "@1", previous: original,
                                applied: landscape, fallbackApplied: portrait)
        XCTAssertTrue(lease.mayRestore(current: portrait, serverIdentity: "server"))
        XCTAssertTrue(lease.mayRestore(current: landscape, serverIdentity: "server"))
        XCTAssertFalse(lease.mayRestore(current: original, serverIdentity: "server"))
        lease.fallbackApplied = nil
        XCTAssertFalse(lease.mayRestore(current: portrait, serverIdentity: "server"))
    }
}
