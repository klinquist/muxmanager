#if os(macOS)
import Foundation
import MuxCore

extension ConnectionProfile {
    static let localMacID = UUID(uuidString: "9BA63470-0692-4CEB-9AD4-68D789C70DE1")!
    static var localMac: Self { Self(id: localMacID, name: "This Mac", hostname: "localhost", username: NSUserName(), authentication: .password) }
    var isLocalMac: Bool { id == Self.localMacID }
}

/// Runs tmux directly as the logged-in user; no SSH daemon or credentials.
@MainActor
final class LocalTransport {
    private let socketName: String?
    init(socketName: String? = nil) { self.socketName = socketName }
    func tmux(_ arguments: String) async throws -> String {
        let socket = socketName.map { "-L " + TmuxCommand.shellQuote($0) + " " } ?? ""
        return try await execute(TmuxCommand.invocation(executable: tmuxPath, arguments: socket + arguments))
    }
    var diagnostic: ((String) -> Void)?
    private(set) var isConnected = false
    private(set) var tmuxPath = "tmux"
    private var process: Process?
    private var input: FileHandle?
    private var channel: ControlChannel?
    private var reader: Task<Void, Never>?
    private var generation = UUID()

    private static func launch(_ command: String) throws -> (Process, Pipe, Pipe, Pipe) {
        let task = Process(), output = Pipe(), errors = Pipe(), input = Pipe()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        task.executableURL = URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh")
        task.arguments = ["-lc", command]
        task.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        for key in ["TMUX", "TMUX_PANE", "SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"] { environment.removeValue(forKey: key) }
        environment["TERM"] = "xterm-256color"
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/opt/homebrew/bin:/usr/local/bin:/usr/local/homebrew/bin"
        task.environment = environment
        task.standardOutput = output; task.standardError = errors; task.standardInput = input
        try task.run()
        return (task, output, errors, input)
    }

    private static func bytes(_ handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; continuation.finish() }
                else { continuation.yield(data) }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    func execute(_ command: String) async throws -> String {
        let (task, out, err, stdin) = try Self.launch(command)
        try? stdin.fileHandleForWriting.close()
        let stdout = Self.bytes(out.fileHandleForReading), stderr = Self.bytes(err.fileHandleForReading)
        return try await withTaskCancellationHandler {
            async let result: Data = Self.collect(stdout, process: task)
            async let failure: Data = Self.collect(stderr, process: task)
            let (output, errors) = try await (result, failure)
            // EOF can precede Foundation delivering termination status.
            while task.isRunning { try await Task.sleep(for: .milliseconds(5)) }
            guard task.terminationStatus == 0 else { throw RemoteCommandFailure(status: Int(task.terminationStatus), diagnostic: String(decoding: errors, as: UTF8.self)) }
            return String(decoding: output, as: UTF8.self)
        } onCancel: { if task.isRunning { task.terminate() } }
    }
    private static func collect(_ stream: AsyncStream<Data>, process: Process) async throws -> Data {
        var result = Data()
        for await chunk in stream {
            result.append(chunk)
            if result.count > 8 * 1024 * 1024 { process.terminate(); throw MuxError.message("Local output exceeded the safety limit.") }
        }
        return result
    }

    func connect(onProgress: (String) -> Void) async throws {
        onProgress("Finding tmux on this Mac…")
        let path: String
        do { path = try await execute("command -v tmux") }
        catch { throw MuxError.message("Install tmux 3.2 or later on this Mac, then connect again.") }
        tmuxPath = path.split(separator: "\n").last.map(String.init) ?? ""
        guard !tmuxPath.isEmpty else { throw MuxError.message("Install tmux 3.2 or later on this Mac, then connect again.") }
        let version = try await tmux("-V")
        guard TmuxVersion(version)?.isSupported == true else { throw MuxError.message("This Mac needs tmux 3.2 or later.") }
        onProgress("Opening local tmux…")
        do { _ = try await tmux("-N list-sessions") }
        catch let error as RemoteCommandFailure where error.isNoServer {
            _ = try await tmux("new-session -d -s Mux-Manager")
        }
        diagnostic?("Local tmux ready: \(tmuxPath); \(version.trimmingCharacters(in: .newlines))")
        isConnected = true
    }

    func startControl(session: String, events: @escaping @Sendable (ControlEvent) -> Void,
                      closed: @escaping @Sendable (String) -> Void) async throws -> ControlChannel {
        await stopControl()
        let socket = socketName.map { "-L " + TmuxCommand.shellQuote($0) + " " } ?? ""
        let command = "exec " + TmuxCommand.invocation(executable: tmuxPath, arguments: socket + (try TmuxCommand.attach(session: session)))
        let (task, out, err, stdin) = try Self.launch(command)
        let token = UUID(); generation = token; process = task; input = stdin.fileHandleForWriting
        let writer = stdin.fileHandleForWriting
        let control = ControlChannel(writer: { data in try writer.write(contentsOf: data) }, onEvent: { events($0) })
        channel = control
        let stdout = Self.bytes(out.fileHandleForReading), stderr = Self.bytes(err.fileHandleForReading)
        reader = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await data in stdout { await control.receive(data) } }
                group.addTask { for await _ in stderr {} } // Never record terminal/user output.
            }
            await control.close()
            if self?.generation == token { closed("Local tmux control client ended.") }
        }
        return control
    }
    func stopControl() async {
        generation = UUID()
        if let channel { await channel.close() }
        try? input?.close(); input = nil
        if let process, process.isRunning { process.terminate() }
        reader?.cancel(); reader = nil; process = nil; channel = nil
    }
    func disconnect() async { await stopControl(); isConnected = false }
}
#endif
