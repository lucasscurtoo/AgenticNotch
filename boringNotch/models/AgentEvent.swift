//
//  AgentEvent.swift
//  boringNotch
//
//  AgenticNotch: decoding of the agenticnotch:// URLs fired by
//  scripts/agenticnotch-notify. Foundation only, so scripts/test-agent-event
//  can compile and run the self-checks without the app.
//

import Foundation

// MARK: - Agent activity (AgenticNotch)

enum AgentStatus: String {
    case ok
    case error
    case waiting   // blocked on the user (Claude Code `Notification` hook)
}

/// Payload decoded from an `agenticnotch://done?...` URL fired when a CLI AI
/// agent (Claude Code, Codex, ...) finishes a turn.
struct AgentActivityInfo: Equatable {
    var tool: String          // "claude", "codex", ...
    var status: AgentStatus
    var project: String       // basename of the agent's cwd; may be ""
    var title: String         // optional extra line; may be ""

    /// Parse an `agenticnotch://done?...` URL. Returns nil for anything else.
    static func from(url: URL) -> AgentActivityInfo? {
        guard url.scheme == "agenticnotch", url.host == "done" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String { items.first(where: { $0.name == name })?.value ?? "" }
        let tool = q("tool")
        guard !tool.isEmpty else { return nil }
        let status = AgentStatus(rawValue: q("status")) ?? .ok
        return AgentActivityInfo(tool: tool, status: status, project: q("project"), title: q("title"))
    }

    static func displayName(for tool: String) -> String {
        switch tool.lowercased() {
        case "claude": return "Claude"
        case "codex":  return "Codex"
        default:       return tool.capitalized
        }
    }

    var toolDisplayName: String { AgentActivityInfo.displayName(for: tool) }

    #if DEBUG
    static func runSelfCheck() {
        assert(from(url: URL(string: "agenticnotch://done?tool=claude&status=error&project=gcu-api")!)
               == AgentActivityInfo(tool: "claude", status: .error, project: "gcu-api", title: ""))
        assert(from(url: URL(string: "agenticnotch://done?tool=codex")!)?.status == .ok)
        assert(from(url: URL(string: "agenticnotch://done?status=ok")!) == nil)          // no tool
        assert(from(url: URL(string: "agenticnotch://other?tool=x")!) == nil)            // wrong host
        assert(from(url: URL(string: "https://example.com")!) == nil)                    // wrong scheme
    }
    #endif
}

// MARK: - Agent session events (shared contract)

/// Payload decoded from
/// `agenticnotch://agent-event?tool=<claude|codex>&event=<kind>&session=<id>&project=<name>&detail=<text>`,
/// one per Claude Code hook (SessionStart, UserPromptSubmit, Notification, Stop,
/// SessionEnd) or Codex finished turn. Feeds both the "needs you" card
/// (`BoringViewCoordinator.handleAgentEvent`) and the live session list
/// (`AgentSessionStore`). The legacy `done` URL keeps going through `AgentActivityInfo`.
struct AgentEvent: Equatable {
    enum Kind: String {
        case sessionStart = "session_start"
        case prompt
        case waiting
        case stop
        case sessionEnd = "session_end"
    }

    var tool: String
    var kind: Kind
    var session: String   // Claude session_id / Codex thread-id
    var project: String   // basename of the session's cwd; may be ""
    var detail: String    // the Notification message, or the Stop summary; may be ""

    /// The scheme is registered and unauthenticated: cap every string where it enters,
    /// before we render it or persist it into the history.
    static let maxDetailLength = 200

    /// Nil for anything but `agent-event`, and for an event without tool or session:
    /// both the card and the live list key on the session.
    static func from(url: URL) -> AgentEvent? {
        guard url.scheme == "agenticnotch", url.host == "agent-event" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String, max: Int) -> String {
            String((items.first(where: { $0.name == name })?.value ?? "").prefix(max))
        }
        guard let kind = Kind(rawValue: q("event", max: 16)) else { return nil }
        let tool = q("tool", max: 32), session = q("session", max: 128)
        guard !tool.isEmpty, !session.isEmpty else { return nil }
        return AgentEvent(tool: tool, kind: kind, session: session,
                          project: q("project", max: 80), detail: q("detail", max: maxDetailLength))
    }

    var toolDisplayName: String { AgentActivityInfo.displayName(for: tool) }

    /// "Claude needs your permission to use Bash" → "permission to use Bash",
    /// "Claude is waiting for your input" → "waiting for your input".
    var shortReason: String {
        for prefix in ["\(toolDisplayName) needs your ", "\(toolDisplayName) is "]
        where detail.hasPrefix(prefix) {
            return String(detail.dropFirst(prefix.count))
        }
        return detail
    }

    /// "<project> · <short reason>", dropping whichever half is empty.
    var subtitle: String {
        let parts = [project, shortReason].filter { !$0.isEmpty }
        return parts.isEmpty ? "waiting for you" : parts.joined(separator: " · ")
    }

    #if DEBUG
    static func runSelfCheck() {
        let waiting = from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=waiting&session=abc-123&project=gcu-api&detail=Claude%20needs%20your%20permission%20to%20use%20Bash")!)
        assert(waiting == AgentEvent(tool: "claude", kind: .waiting, session: "abc-123",
                                     project: "gcu-api", detail: "Claude needs your permission to use Bash"))
        assert(waiting?.shortReason == "permission to use Bash")
        assert(waiting?.subtitle == "gcu-api · permission to use Bash")
        assert(from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=waiting&session=s&detail=Claude%20is%20waiting%20for%20your%20input")!)?
               .subtitle == "waiting for your input")
        assert(from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=waiting&session=s")!)?.subtitle == "waiting for you")

        for (raw, kind) in [("session_start", Kind.sessionStart), ("prompt", .prompt),
                            ("stop", .stop), ("session_end", .sessionEnd)] {
            assert(from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=\(raw)&session=s")!)?.kind == kind)
        }

        // Malformed: no tool, no session, unknown/missing event, wrong host, wrong scheme.
        assert(from(url: URL(string: "agenticnotch://agent-event?event=waiting&session=s")!) == nil)
        assert(from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=waiting")!) == nil)
        assert(from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=sleeping&session=s")!) == nil)
        assert(from(url: URL(string: "agenticnotch://agent-event?tool=claude&session=s")!) == nil)
        assert(from(url: URL(string: "agenticnotch://agent-event")!) == nil)
        assert(from(url: URL(string: "https://example.com/agent-event?tool=claude&event=waiting")!) == nil)

        // Hostile length is capped.
        let long = String(repeating: "x", count: 5_000)
        let capped = from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=waiting&session=\(long)&project=\(long)&detail=\(long)")!)
        assert(capped?.detail.count == maxDetailLength && capped?.project.count == 80 && capped?.session.count == 128)

        // The old finished URL is not claimed here and still decodes as before.
        let done = URL(string: "agenticnotch://done?tool=claude&status=ok&project=gcu-api&title=Fixed%20the%20build")!
        assert(from(url: done) == nil, "the two hosts must not shadow each other")
        assert(AgentActivityInfo.from(url: done)
               == AgentActivityInfo(tool: "claude", status: .ok, project: "gcu-api", title: "Fixed the build"))
        assert(AgentActivityInfo.from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=stop&session=s")!) == nil)
        assert(from(url: URL(string: "agenticnotch://done?tool=claude&event=stop&session=s")!) == nil)
    }
    #endif
}
