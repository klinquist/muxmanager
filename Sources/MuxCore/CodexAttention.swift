import Foundation

public enum CodexAttentionState: Equatable, Sendable {
    case unknown, working, ready, needsInput
}

/// Screen interpretation only. No silence timers, API assumptions, or transcript storage.
public enum CodexAttention {
    public static func isCandidate(command: String) -> Bool {
        let name = (command as NSString).lastPathComponent.lowercased()
        return name.contains("codex") || ["node", "nodejs"].contains(name)
    }

    public static func state(screen: String, command: String) -> CodexAttentionState {
        let lines = TerminalCaptureStyle.parse(screen).text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let tail = Array(lines.suffix(18))
        let lower = tail.map { $0.lowercased() }
        let codexCommand = (command as NSString).lastPathComponent.lowercased().contains("codex")
        let branded = lines.contains { $0.contains("OpenAI Codex") } ||
            (tail.contains { $0.contains("context left") } && tail.contains { $0.hasPrefix("›") })
        guard codexCommand || branded else { return .unknown }
        // Actual interactive dialogs have action hints/options, rather than a
        // question merely quoted in generated code or earlier output.
        let options = lower.contains { $0.hasPrefix("1. ") || $0.hasPrefix("› 1.") || $0.hasPrefix("❯ 1.") }
        let approval = lower.contains { $0.contains("would you like to run") || $0.contains("yes, proceed") || $0.contains("allow once") }
        let inputHint = lower.contains { $0.contains("enter to submit") || $0.contains("enter to confirm") || $0.contains("select an option") }
        let working = lower.indices.last { $0 >= max(0, lower.count - 10) &&
            (lower[$0].contains("esc to interrupt") || lower[$0].contains("esc to stop")) }
        let action = lower.indices.last { lower[$0].contains("enter to submit") || lower[$0].contains("enter to confirm") ||
            lower[$0].contains("yes, proceed") || lower[$0].contains("allow once") || lower[$0].hasPrefix("1. ") || lower[$0].hasPrefix("› 1.") }
        // A still-working footer beneath quoted approval examples takes
        // precedence; a real dialog below an old working line can request input.
        if options && (approval || inputHint), working == nil || (action ?? -1) > working! { return .needsInput }
        if working != nil { return .working }
        // A prompt near the bottom establishes that the TUI is ready. Lack of
        // output alone must never be interpreted as completion.
        guard let prompt = tail.lastIndex(where: { $0 == "›" || $0.hasPrefix("› ") }),
              prompt >= max(0, tail.count - 7) else { return .unknown }
        let preceding = tail[..<prompt].last { !$0.hasPrefix("─") && !$0.contains("context left") }
        if preceding?.hasSuffix("?") == true { return .needsInput }
        return .ready
    }
}

/// One bounded state record per pane. Initial/reconnected idle screens establish
/// a baseline, rather than producing a burst of old notifications.
public struct CodexAttentionTracker: Sendable {
    private struct Observation: Sendable {
        var lastSeen: TimeInterval
        var armed: Bool
        var candidate: CodexAttentionState
        var candidateSince: TimeInterval
    }
    private var observations: [String: Observation] = [:]
    public init() {}

    public mutating func observe(pane: String, state: CodexAttentionState, at time: TimeInterval) -> CodexAttentionState? {
        guard state != .unknown else { return nil }
        guard var old = observations[pane], time >= old.lastSeen, time - old.lastSeen <= 60 else {
            observations[pane] = Observation(lastSeen: time, armed: state == .working, candidate: state, candidateSince: time)
            return nil
        }
        old.lastSeen = time
        if state == .working { old.armed = true }
        if old.candidate != state { old.candidate = state; old.candidateSince = time }
        let alert = old.armed && (state == .ready || state == .needsInput) && time - old.candidateSince >= 1.5
        if alert { old.armed = false }
        observations[pane] = old
        return alert ? state : nil
    }

    public mutating func retain(panes: Set<String>) { observations = observations.filter { panes.contains($0.key) } }
}

public struct CodexPaneTarget: Equatable, Sendable {
    public let sessionID: String
    public let windowID: String
    public let windowName: String
    public let paneID: String
    public let command: String
    public init(sessionID: String, windowID: String, windowName: String, paneID: String, command: String) {
        self.sessionID = sessionID; self.windowID = windowID; self.windowName = windowName
        self.paneID = paneID; self.command = command
    }
}

/// Bounds screen reads to recently used Codex panes. A new candidate gets one
/// baseline; generic Node processes are excluded unless that screen identifies
/// Codex. No screen text or wall-clock timestamps are retained.
public struct CodexAttentionPolling: Sendable {
    private struct Pane: Sendable {
        var target: CodexPaneTarget
        var discoveredAt: TimeInterval
        var idleSince: TimeInterval?
        var recognizedCodex = false
        var excluded = false
    }
    private var panes: [String: Pane] = [:]
    private var windowUseTimes: [String: TimeInterval] = [:]
    public let recentWindowInterval: TimeInterval
    public let idleInterval: TimeInterval

    public init(recentWindowInterval: TimeInterval = 30 * 60, idleInterval: TimeInterval = 2 * 60) {
        self.recentWindowInterval = recentWindowInterval; self.idleInterval = idleInterval
    }
    @discardableResult
    public mutating func reconcile(_ targets: [CodexPaneTarget], at time: TimeInterval) -> Set<String> {
        var newBaselines = Set<String>()
        let windows = Set(targets.map(\.windowID))
        windowUseTimes = windowUseTimes.filter { windows.contains($0.key) }
        let candidates = targets.filter { CodexAttention.isCandidate(command: $0.command) }
        let live = Set(candidates.map(\.paneID))
        panes = panes.filter { live.contains($0.key) }
        for target in candidates {
            if var existing = panes[target.paneID], existing.target.command == target.command {
                existing.target = target; panes[target.paneID] = existing
            } else {
                panes[target.paneID] = Pane(target: target, discoveredAt: time)
                newBaselines.insert(target.paneID)
            }
        }
        return newBaselines
    }
    public mutating func viewed(windowID: String, at time: TimeInterval) {
        windowUseTimes[windowID] = time
        for id in Array(panes.keys) where panes[id]?.target.windowID == windowID {
            panes[id]?.idleSince = nil; panes[id]?.excluded = false
        }
    }
    public func shouldPoll(_ target: CodexPaneTarget, at time: TimeInterval) -> Bool {
        guard let pane = panes[target.paneID], !pane.excluded,
              pane.target.command == target.command else { return false }
        let lastUse = max(pane.discoveredAt, windowUseTimes[target.windowID] ?? pane.discoveredAt)
        guard time - lastUse < recentWindowInterval else { return false }
        return pane.idleSince.map { time - $0 < idleInterval } ?? true
    }
    public func classificationCommand(for target: CodexPaneTarget) -> String {
        // Once a Node wrapper has shown the Codex UI, its subsequent approval
        // dialog need not repeat the branding/context footer.
        panes[target.paneID]?.recognizedCodex == true ? "codex" : target.command
    }
    public mutating func observe(_ target: CodexPaneTarget, state: CodexAttentionState, at time: TimeInterval) {
        guard var pane = panes[target.paneID], pane.target.command == target.command else { return }
        if state != .unknown { pane.recognizedCodex = true }
        if state == .working { pane.idleSince = nil }
        else { pane.idleSince = pane.idleSince ?? time }
        let command = (target.command as NSString).lastPathComponent.lowercased()
        if ["node", "nodejs"].contains(command), !pane.recognizedCodex { pane.excluded = true }
        panes[target.paneID] = pane
    }
}
