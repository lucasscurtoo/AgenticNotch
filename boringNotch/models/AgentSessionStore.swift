//
//  AgentSessionStore.swift
//  AgenticNotch
//
//  Live list of every running CLI agent session, fed by `agenticnotch://agent-event`
//  URLs from scripts/agenticnotch-notify. The finish card, chime and history still
//  come from the separate `agenticnotch://done` URL — this only tracks state.
//

import Foundation
import SwiftUI

/// One event of the shared hook contract:
/// `agenticnotch://agent-event?tool=<claude|codex>&event=<kind>&session=<id>&project=<name>&detail=<text>`
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
    var session: String
    var project: String
    var detail: String

    /// Parse an `agenticnotch://agent-event?...` URL. Nil for anything else, and for an
    /// event without tool or session: there is nothing to track it against.
    /// The scheme is unauthenticated, so every string is capped where it enters.
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
                          project: q("project", max: 80), detail: q("detail", max: 200))
    }
}

struct AgentSession: Identifiable, Equatable {
    enum State: Equatable {
        case working, needsYou, done

        var label: String {
            switch self {
            case .working:  return "working"
            case .needsYou: return "needs you"
            case .done:     return "done"
            }
        }

        /// Display order: what needs you first, finished last.
        fileprivate var rank: Int {
            switch self {
            case .needsYou: return 0
            case .working:  return 1
            case .done:     return 2
            }
        }
    }

    /// "<tool>:<session>" — Claude and Codex ids live in separate spaces.
    let id: String
    var tool: String
    var project: String
    var state: State
    /// When the current state began; drives the elapsed time in the Live list.
    var since: Date
    var lastEvent: Date

    static let doneTTL: TimeInterval = 10 * 60
    static let staleTTL: TimeInterval = 2 * 3_600
    /// Hostile-URL ceiling; real use is a handful of terminals.
    static let maxSessions = 24

    /// When this entry drops out of the list if nothing else arrives.
    var expiresAt: Date {
        state == .done ? since + Self.doneTTL : lastEvent + Self.staleTTL
    }

    /// The session list after `event` arrives at `now`. Pure: the store and the
    /// self-check both go through here.
    static func applying(_ event: AgentEvent, to sessions: [AgentSession], now: Date) -> [AgentSession] {
        var list = pruned(sessions, now: now)
        let id = "\(event.tool):\(event.session)"
        let index = list.firstIndex { $0.id == id }

        let next: State
        switch event.kind {
        case .sessionEnd:
            list.removeAll { $0.id == id }
            return list
        case .sessionStart, .prompt:
            next = .working
        case .stop:
            next = .done
        case .waiting:
            // Claude also fires Notification ~60 s after a finished turn ("waiting for
            // your input"). The turn is already done — only a running turn escalates.
            next = index.map { list[$0].state == .done } == true ? .done : .needsYou
        }

        if let index {
            if list[index].state != next {
                list[index].state = next
                list[index].since = now
            }
            list[index].lastEvent = now
            if !event.project.isEmpty { list[index].project = event.project }
        } else {
            list.append(AgentSession(id: id, tool: event.tool, project: event.project,
                                     state: next, since: now, lastEvent: now))
        }

        list.sort { ($0.state.rank, $1.since) < ($1.state.rank, $0.since) }
        if list.count > maxSessions {
            let oldest = list.indices.min { list[$0].lastEvent < list[$1].lastEvent }!
            list.remove(at: oldest)
        }
        return list
    }

    /// Drops finished sessions after `doneTTL` and silent ones after `staleTTL`.
    static func pruned(_ sessions: [AgentSession], now: Date) -> [AgentSession] {
        sessions.filter { $0.expiresAt > now }
    }
}

@MainActor
final class AgentSessionStore: ObservableObject {
    static let shared = AgentSessionStore()

    @Published private(set) var sessions: [AgentSession] = []
    private var expiryTask: Task<Void, Never>?

    private init() {}

    /// Sessions still in flight (working or blocked on you) — the closed-notch count.
    var activeCount: Int { sessions.filter { $0.state != .done }.count }
    var anyNeedsYou: Bool { sessions.contains { $0.state == .needsYou } }

    func handle(_ event: AgentEvent) {
        withAnimation(.smooth) {
            sessions = AgentSession.applying(event, to: sessions, now: Date())
        }
        scheduleExpiry()
    }

    /// One sleeping task aimed at the next entry to expire, so a crashed agent that
    /// never sends session_end still leaves — no polling.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let next = sessions.map(\.expiresAt).min() else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled else { return }
            withAnimation(.smooth) {
                self.sessions = AgentSession.pruned(self.sessions, now: Date())
            }
            self.scheduleExpiry()
        }
    }
}

#if DEBUG
extension AgentSession {
    static func runSelfCheck() {
        let t0 = Date(timeIntervalSince1970: 1_735_732_800)
        func event(_ kind: String, _ session: String = "s1", tool: String = "claude") -> AgentEvent {
            AgentEvent.from(url: URL(string:
                "agenticnotch://agent-event?tool=\(tool)&event=\(kind)&session=\(session)&project=api")!)!
        }

        // Parser
        assert(AgentEvent.from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=waiting&session=abc&project=gcu-api&detail=Claude%20needs%20your%20permission%20to%20use%20Bash")!)
               == AgentEvent(tool: "claude", kind: .waiting, session: "abc", project: "gcu-api",
                             detail: "Claude needs your permission to use Bash"))
        assert(AgentEvent.from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=bogus&session=a")!) == nil)
        assert(AgentEvent.from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=stop")!) == nil, "no session")
        assert(AgentEvent.from(url: URL(string: "agenticnotch://agent-event?event=stop&session=a")!) == nil, "no tool")
        assert(AgentEvent.from(url: URL(string: "agenticnotch://done?tool=claude&event=stop&session=a")!) == nil, "wrong host")
        let long = String(repeating: "x", count: 5_000)
        assert(AgentEvent.from(url: URL(string: "agenticnotch://agent-event?tool=claude&event=stop&session=\(long)&project=\(long)")!)?
               .project.count == 80, "hostile lengths are capped")

        // session_start → working
        var s = applying(event("session_start"), to: [], now: t0)
        assert(s.count == 1 && s[0].state == .working && s[0].since == t0 && s[0].project == "api")
        // Another prompt while working keeps the state clock.
        s = applying(event("prompt"), to: s, now: t0 + 30)
        assert(s[0].state == .working && s[0].since == t0 && s[0].lastEvent == t0 + 30)

        // waiting → needs you
        s = applying(event("waiting"), to: s, now: t0 + 60)
        assert(s[0].state == .needsYou && s[0].since == t0 + 60)

        // stop → done, listed for 10 minutes, then dropped
        s = applying(event("stop"), to: s, now: t0 + 120)
        assert(s[0].state == .done && s[0].since == t0 + 120)
        s = applying(event("waiting"), to: s, now: t0 + 180)
        assert(s[0].state == .done, "the idle reminder after a finished turn is not 'needs you'")
        assert(pruned(s, now: t0 + 120 + doneTTL - 1).count == 1)
        assert(pruned(s, now: t0 + 120 + doneTTL).isEmpty)

        // prompt after done → working again; session_end → removed
        s = applying(event("prompt"), to: s, now: t0 + 200)
        assert(s[0].state == .working && s[0].since == t0 + 200)
        s = applying(event("session_end"), to: s, now: t0 + 210)
        assert(s.isEmpty)
        assert(applying(event("session_end"), to: [], now: t0).isEmpty, "ending an unknown session is a no-op")

        // Stale: no event for 2 hours drops even a working session.
        s = applying(event("prompt", "s2"), to: [], now: t0)
        assert(pruned(s, now: t0 + staleTTL - 1).count == 1)
        assert(pruned(s, now: t0 + staleTTL).isEmpty)
        s = applying(event("prompt", "s3"), to: s, now: t0 + staleTTL + 1)
        assert(s.map(\.id) == ["claude:s3"], "the next event sweeps stale sessions out")

        // Codex only reports stop: its first sign of life lands as done.
        s = applying(event("stop", "s3", tool: "codex"), to: s, now: t0 + staleTTL + 2)
        assert(s.count == 2 && s.first { $0.id == "codex:s3" }?.state == .done, "same id, different tool")

        // Order: needs you, working, done.
        s = applying(event("waiting", "s4"), to: s, now: t0 + staleTTL + 3)
        assert(s.map(\.state) == [.needsYou, .working, .done])

        // Flood ceiling.
        var flood: [AgentSession] = []
        for i in 0..<(maxSessions + 5) { flood = applying(event("prompt", "f\(i)"), to: flood, now: t0 + Double(i)) }
        assert(flood.count == maxSessions && !flood.contains { $0.id == "claude:f0" })
    }
}
#endif
