import Foundation

/// Serializes command/response pairs. Notifications remain independent of the command queue.
public actor ControlChannel {
    public typealias Writer = @Sendable (Data) async throws -> Void
    private let writer: Writer
    private let onEvent: @Sendable (ControlEvent) async -> Void
    private var parser = TmuxControlParser()
    private var initialResponseSeen = false
    private var initialError: MuxError?
    private struct Request {
        let id: UUID
        let command: String
        let continuation: CheckedContinuation<[String], Error>
    }
    private var queue: [Request] = []
    private var active: Request?
    private var timeout: Task<Void, Never>?
    private var closed = false
    public var isClosed: Bool { closed }
    private let timeoutNanoseconds: UInt64

    public init(timeoutNanoseconds: UInt64 = 15_000_000_000, writer: @escaping Writer, onEvent: @escaping @Sendable (ControlEvent) async -> Void) {
        self.writer = writer; self.onEvent = onEvent; self.timeoutNanoseconds = timeoutNanoseconds
    }

    public func command(_ text: String) async throws -> [String] {
        guard !closed else { throw MuxError.message("The SSH connection is closed.") }
        guard !text.contains("\n"), !text.contains("\r") else { throw MuxError.message("Invalid tmux command.") }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.append(Request(id: id, command: text, continuation: continuation))
                if !initialResponseSeen && timeout == nil {
                    timeout = Task { [weak self, timeoutNanoseconds] in
                        do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
                        await self?.startupTimedOut()
                    }
                }
                startNext()
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    public func receive(_ bytes: Data) async {
        for event in parser.feed(bytes) {
            switch event {
            case .response(_, let lines, let failed):
                if !initialResponseSeen {
                    initialResponseSeen = true
                    timeout?.cancel(); timeout = nil
                    if failed { initialError = .message(lines.joined(separator: "\n")); await close(initialError!) }
                    else { startNext() }
                } else if let request = active {
                    active = nil; timeout?.cancel(); timeout = nil
                    if failed { request.continuation.resume(throwing: MuxError.message(lines.joined(separator: "\n"))) }
                    else { request.continuation.resume(returning: lines) }
                    startNext()
                }
            case .exit(let reason): await close(.message(reason.isEmpty ? "tmux disconnected." : reason)); await onEvent(event)
            case .protocolError(let reason): await close(.message(reason)); await onEvent(event)
            default: await onEvent(event)
            }
        }
    }

    public func close(_ error: MuxError = .message("Disconnected.")) async {
        guard !closed else { return }; closed = true
        timeout?.cancel(); timeout = nil
        active?.continuation.resume(throwing: error); active = nil
        for request in queue { request.continuation.resume(throwing: error) }
        queue = []
    }

    private func startNext() {
        guard initialResponseSeen, !closed, active == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst(); active = request
        timeout = Task { [weak self, timeoutNanoseconds] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
            await self?.timedOut(request.id)
        }
        Task {
            do { try await writer(Data((request.command + "\n").utf8)) }
            catch {
                await close(.message(error.localizedDescription))
                await onEvent(.protocolError(error.localizedDescription))
            }
        }
    }
    private func timedOut(_ id: UUID) async {
        guard active?.id == id else { return }
        // Closing avoids associating a late response with a later command.
        await close(.message("tmux stopped responding. Reconnect to continue."))
        await onEvent(.protocolError("tmux command timed out."))
    }
    private func startupTimedOut() async {
        guard !initialResponseSeen, !closed else { return }
        await close(.message("tmux did not complete attachment. Reconnect to try again."))
        await onEvent(.protocolError("tmux attachment timed out."))
    }
    private func cancel(_ id: UUID) async {
        if active?.id == id {
            // Bytes already sent cannot be recalled. Drain this response (or its timeout)
            // before advancing, so a graceful background resize restoration can still run.
            return
        } else if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }
}
