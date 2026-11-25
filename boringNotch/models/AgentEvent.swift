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

enum AgentEventKind: String {
    case sessionStart = "session_start"
    case prompt
    case waiting
    case stop
    case sessionEnd = "session_end"
}

/// Payload decoded from
/// `agenticnotch://agent-event?tool=&event=&session=&project=&detail=`,
/// one per Claude Code hook (SessionStart, UserPromptSubmit, Notification, Stop,
/// SessionEnd). The legacy `done` URL keeps going through `AgentActivityInfo`.
struct AgentEvent: Equatable {
    var tool: String
    var kind: AgentEventKind
    var session: String   // Claude Code session_id; may be ""
    var project: String   // basename of the session's cwd; may be ""
    var detail: String    // e.g. the Notification message; may be ""

    /// The scheme is registered and unauthenticated: cap what a stranger can make
    /// us render and persist into the history.
    private static let maxFieldLength = 200

    static func from(url: URL) -> AgentEvent? {
        guard url.scheme == "agenticnotch", url.host == "agent-event" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String {
            String((items.first(where: { $0.name == name })?.value ?? "").prefix(maxFieldLength))
        }
        guard !q("tool").isEmpty, let kind = AgentEventKind(rawValue: q("event")) else { return nil }
        return AgentEvent(tool: q("tool"), kind: kind, session: q("session"),
                          project: q("project"), detail: q("detail"))
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
        assert(from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=waiting&detail=Claude%20is%20waiting%20for%20your%20input")!)?
               .subtitle == "waiting for your input")
        assert(from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=waiting")!)?.subtitle == "waiting for you")

        for (raw, kind) in [("session_start", AgentEventKind.sessionStart), ("prompt", .prompt),
                            ("stop", .stop), ("session_end", .sessionEnd)] {
            assert(from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=\(raw)&session=s")!)?.kind == kind)
        }

        // Malformed: no tool, unknown/missing event, wrong host, wrong scheme.
        assert(from(url: URL(string: "agenticnotch://agent-event?event=waiting&session=s")!) == nil)
        assert(from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=sleeping")!) == nil)
        assert(from(url: URL(string: "agenticnotch://agent-event?tool=claude")!) == nil)
        assert(from(url: URL(string: "agenticnotch://agent-event")!) == nil)
        assert(from(url: URL(string: "https://example.com/agent-event?tool=claude&event=waiting")!) == nil)

        // Hostile length is capped.
        let long = String(repeating: "x", count: 5_000)
        assert(from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=waiting&detail=\(long)")!)?
               .detail.count == maxFieldLength)

        // The old finished URL is not claimed here and still decodes as before.
        let done = URL(string: "agenticnotch://done?tool=claude&status=ok&project=gcu-api&title=Fixed%20the%20build")!
        assert(from(url: done) == nil, "the two hosts must not shadow each other")
        assert(AgentActivityInfo.from(url: done)
               == AgentActivityInfo(tool: "claude", status: .ok, project: "gcu-api", title: "Fixed the build"))
        assert(AgentActivityInfo.from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=stop")!) == nil)
    }
    #endif
}
