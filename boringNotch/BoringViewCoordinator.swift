//
//  BoringViewCoordinator.swift
//  boringNotch
//
//  Created by Alexander on 2024-11-20.
//

import AppKit
import Combine
import Defaults
import Security
import SwiftUI

// MARK: - Focus activity (Engram pomodoro mirror)

enum FocusPhaseKind: String {
    case focusing, shortBreak, longBreak, paused, idle

    var symbol: String {
        switch self {
        case .focusing:   return "brain.head.profile"
        case .shortBreak: return "cup.and.saucer"
        case .longBreak:  return "figure.walk"
        case .paused:     return "pause.circle"
        case .idle:       return "timer"
        }
    }

    var title: String {
        switch self {
        case .focusing:   return "Focus"
        case .shortBreak: return "Short break"
        case .longBreak:  return "Long break"
        case .paused:     return "Paused"
        case .idle:       return "Idle"
        }
    }
}

/// Payload decoded from an `agenticnotch://focus?...` URL, pushed by Engram
/// (~/Proyectos/Engram) on every focus-session phase transition.
///
/// Display only: the notch never controls the session and never notifies for it.
/// Engram sends an absolute `endsAt` instead of ticking, so everything here is a
/// pure function of the payload and `now`.
struct FocusActivityInfo: Equatable {
    var phase: FocusPhaseKind
    /// When the running phase ends. Nil while paused and in open-ended deep work.
    var endsAt: Date?
    /// Frozen remainder, sent only while paused.
    var frozenRemaining: TimeInterval?
    /// Full length of the current phase; nil when open-ended. Drives the ring.
    var duration: TimeInterval?
    var blocks: Int
    var cycles: Int?
    var label: String
    /// Seconds already elapsed when the payload was built, sent instead of `endsAt`
    /// for an open-ended block. Engram's own session total, so the two agree.
    var elapsed: TimeInterval?
    /// Local arrival time — the origin an open-ended block counts up from.
    var receivedAt: Date

    /// Anything past this is not a plausible second count or epoch (year ~2096).
    /// `agenticnotch://` is registered and unauthenticated, so out-of-range numbers
    /// are dropped where they enter rather than trapping later in `Int(_:)`.
    private static let sanityBound: Double = 4_000_000_000
    /// Engram's own picker stops at 12; the notch must not take its word for it,
    /// because `cycles` drives an eager `ForEach`.
    private static let maxCycles = 12

    static func from(url: URL, now: Date = Date()) -> FocusActivityInfo? {
        guard url.scheme == "agenticnotch", url.host == "focus" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        /// `Double("inf")`, `"nan"` and `"1e400"` all parse; none of them may survive.
        func number(_ name: String) -> Double? {
            guard let value = q(name).flatMap(Double.init),
                  value.isFinite, abs(value) <= sanityBound else { return nil }
            return value
        }
        guard let phase = FocusPhaseKind(rawValue: q("phase") ?? "") else { return nil }
        return FocusActivityInfo(
            phase: phase,
            endsAt: number("endsAt").map { Date(timeIntervalSince1970: $0) },
            frozenRemaining: number("remaining"),
            duration: number("duration"),
            blocks: q("blocks").flatMap(Int.init) ?? 0,
            cycles: q("cycles").flatMap(Int.init).map { min(max(0, $0), maxCycles) },
            label: q("label") ?? phase.title,
            elapsed: number("elapsed"),
            receivedAt: now
        )
    }

    /// Deep work never ends on its own, so its block counts up instead of down.
    /// A paused block is never open-ended even without an end date — it is frozen.
    var isOpenEnded: Bool { phase != .paused && endsAt == nil && frozenRemaining == nil }

    /// Seconds left, or nil when there is no end to count down to.
    func remaining(at now: Date) -> TimeInterval? {
        if let frozenRemaining { return max(0, frozenRemaining) }
        guard let endsAt else { return nil }
        return max(0, endsAt.timeIntervalSince(now))
    }

    /// Seconds spent, for a block with no end date. `receivedAt` alone would restart
    /// the count on every push and disagree with Engram after a pause, so it is only
    /// the delta on top of the total Engram sent — and while paused, not even that.
    func elapsedSeconds(at now: Date) -> TimeInterval {
        let sent = max(0, elapsed ?? 0)
        return isOpenEnded ? sent + max(0, now.timeIntervalSince(receivedAt)) : sent
    }

    /// 0...1 through the current phase; nil without a duration.
    func progress(at now: Date) -> Double? {
        guard let duration, duration > 0, let remaining = remaining(at: now) else { return nil }
        return min(1, max(0, 1 - remaining / duration))
    }

    /// Countdown, or elapsed time when there is nothing to count down to.
    func clockText(at now: Date) -> String {
        let seconds = remaining(at: now) ?? elapsedSeconds(at: now)
        let total = Int(max(0, seconds.rounded()))
        return total >= 3_600
            ? String(format: "%d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// True once Engram has clearly stopped talking. A live Engram pushes the next
    /// phase within a second of the boundary, so 90 s past it means the app was
    /// killed mid-session and the countdown would otherwise sit at 00:00 forever.
    ///
    /// A pause or a deep-work block has no end to run past, so it gets a far longer
    /// ceiling on arrival instead: long enough never to interrupt a real all-day
    /// pause, short enough that a SIGKILLed Engram does not leave a frozen pill the
    /// user has no control to dismiss.
    func isStale(at now: Date) -> Bool {
        guard let endsAt else { return now.timeIntervalSince(receivedAt) > 12 * 3_600 }
        return now.timeIntervalSince(endsAt) > 90
    }
}

extension FocusActivityInfo {
    #if DEBUG
    static func runSelfCheck() {
        let now = Date(timeIntervalSince1970: 1_735_732_800)
        let endsAt = now.addingTimeInterval(1_200)

        let running = from(
            url: URL(string: "agenticnotch://focus?phase=focusing&endsAt=\(Int(endsAt.timeIntervalSince1970))&duration=1500&blocks=2&cycles=4&label=Focus")!,
            now: now
        )
        assert(running?.phase == .focusing)
        assert(running?.remaining(at: now) == 1_200)
        assert(abs((running?.progress(at: now) ?? -1) - 0.2) < 0.0001) // 300 of 1500 elapsed
        assert(running?.clockText(at: now) == "20:00")
        assert(running?.cycles == 4 && running?.blocks == 2)
        assert(running?.isStale(at: now) == false)
        assert(running?.isStale(at: endsAt.addingTimeInterval(90)) == false, "90 s is the boundary, not past it")
        assert(running?.isStale(at: endsAt.addingTimeInterval(91)) == true)

        let paused = from(url: URL(string: "agenticnotch://focus?phase=paused&remaining=871&duration=1500")!, now: now)
        assert(paused?.remaining(at: now.addingTimeInterval(600)) == 871, "paused time must not drain")
        assert(paused?.isOpenEnded == false, "a pause is frozen, never open-ended")
        assert(paused?.isStale(at: now.addingTimeInterval(11 * 3_600)) == false, "a pause may last all day")
        assert(paused?.isStale(at: now.addingTimeInterval(13 * 3_600)) == true, "but not past the ceiling")

        let open = from(url: URL(string: "agenticnotch://focus?phase=focusing&elapsed=1930&label=Deep%20work")!, now: now)
        assert(open?.isOpenEnded == true)
        assert(open?.remaining(at: now) == nil)
        assert(open?.progress(at: now) == nil)
        assert(open?.label == "Deep work")
        // Counts up from Engram's total, not from the moment the URL landed.
        assert(open?.clockText(at: now) == "32:10")
        assert(open?.clockText(at: now.addingTimeInterval(50)) == "33:00")
        assert(open?.isStale(at: now.addingTimeInterval(13 * 3_600)) == true, "a killed Engram must not linger")

        let pausedOpen = from(url: URL(string: "agenticnotch://focus?phase=paused&elapsed=1930&label=Paused")!, now: now)
        assert(pausedOpen?.isOpenEnded == false)
        assert(pausedOpen?.clockText(at: now.addingTimeInterval(600)) == "32:10",
               "a paused deep-work block must not tick up")

        // Out-of-range numbers reach Int(_:) in clockText and would trap there.
        assert(from(url: URL(string: "agenticnotch://focus?phase=focusing&endsAt=inf")!)?.endsAt == nil)
        assert(from(url: URL(string: "agenticnotch://focus?phase=focusing&endsAt=nan")!)?.endsAt == nil)
        assert(from(url: URL(string: "agenticnotch://focus?phase=focusing&endsAt=1e400")!)?.endsAt == nil)
        assert(from(url: URL(string: "agenticnotch://focus?phase=paused&remaining=1e30")!)?.frozenRemaining == nil)
        assert(from(url: URL(string: "agenticnotch://focus?phase=focusing&endsAt=inf")!, now: now)?
            .clockText(at: now) == "00:00")
        // An unbounded cycle count would materialize that many Circles in an HStack.
        assert(from(url: URL(string: "agenticnotch://focus?phase=focusing&cycles=100000000")!)?.cycles == 12)
        assert(from(url: URL(string: "agenticnotch://focus?phase=focusing&cycles=-3")!)?.cycles == 0)
        assert(from(url: URL(string: "agenticnotch://focus?phase=focusing&cycles=4")!)?.cycles == 4)

        assert(from(url: URL(string: "agenticnotch://focus?phase=idle")!)?.phase == .idle)
        assert(from(url: URL(string: "agenticnotch://focus")!) == nil)              // no phase
        assert(from(url: URL(string: "agenticnotch://focus?phase=sleeping")!) == nil) // unknown phase
        assert(from(url: URL(string: "agenticnotch://done?tool=claude")!) == nil)   // wrong host
        assert(from(url: URL(string: "https://example.com?phase=focusing")!) == nil) // wrong scheme
        assert(AgentActivityInfo.from(url: URL(string: "agenticnotch://focus?phase=focusing")!) == nil,
               "the two hosts must not shadow each other")
    }
    #endif
}

enum SneakContentType {
    case brightness
    case volume
    case backlight
    case music
    case mic
    case battery
    case download
}

struct sneakPeek {
    var show: Bool = false
    var type: SneakContentType = .music
    var value: CGFloat = 0
    var icon: String = ""
}

struct SharedSneakPeek: Codable {
    var show: Bool
    var type: String
    var value: String
    var icon: String
}

enum BrowserType {
    case chromium
    case safari
}

struct ExpandedItem {
    var show: Bool = false
    var type: SneakContentType = .battery
    var value: CGFloat = 0
    var browser: BrowserType = .chromium
}

@MainActor
class BoringViewCoordinator: ObservableObject {
    static let shared = BoringViewCoordinator()

    @Published var currentView: NotchViews = .home
    @Published var helloAnimationRunning: Bool = false
    private var sneakPeekDispatch: DispatchWorkItem?
    private var expandingViewDispatch: DispatchWorkItem?
    private var hudEnableTask: Task<Void, Never>?

    @AppStorage("firstLaunch") var firstLaunch: Bool = true
    @AppStorage("showWhatsNew") var showWhatsNew: Bool = true
    @AppStorage("musicLiveActivityEnabled") var musicLiveActivityEnabled: Bool = true
    @AppStorage("currentMicStatus") var currentMicStatus: Bool = true

    @AppStorage("alwaysShowTabs") var alwaysShowTabs: Bool = true {
        didSet {
            if !alwaysShowTabs {
                openLastTabByDefault = false
                if ShelfStateViewModel.shared.isEmpty || !Defaults[.openShelfByDefault] {
                    currentView = .home
                }
            }
        }
    }

    @AppStorage("openLastTabByDefault") var openLastTabByDefault: Bool = false {
        didSet {
            if openLastTabByDefault {
                alwaysShowTabs = true
            }
        }
    }
    
    @Default(.hudReplacement) var hudReplacement: Bool
    
    // Legacy storage for migration
    @AppStorage("preferred_screen_name") private var legacyPreferredScreenName: String?
    
    // New UUID-based storage
    @AppStorage("preferred_screen_uuid") var preferredScreenUUID: String? {
        didSet {
            if let uuid = preferredScreenUUID {
                selectedScreenUUID = uuid
            }
            NotificationCenter.default.post(name: Notification.Name.selectedScreenChanged, object: nil)
        }
    }

    @Published var selectedScreenUUID: String = NSScreen.main?.displayUUID ?? ""

    @Published var optionKeyPressed: Bool = true
    private var accessibilityObserver: Any?
    private var hudReplacementCancellable: AnyCancellable?

    private init() {
        // Perform migration from name-based to UUID-based storage
        if preferredScreenUUID == nil, let legacyName = legacyPreferredScreenName {
            // Try to find screen by name and migrate to UUID
            if let screen = NSScreen.screens.first(where: { $0.localizedName == legacyName }),
               let uuid = screen.displayUUID {
                preferredScreenUUID = uuid
                NSLog("✅ Migrated display preference from name '\(legacyName)' to UUID '\(uuid)'")
            } else {
                // Fallback to main screen if legacy screen not found
                preferredScreenUUID = NSScreen.main?.displayUUID
                NSLog("⚠️ Could not find display named '\(legacyName)', falling back to main screen")
            }
            // Clear legacy value after migration
            legacyPreferredScreenName = nil
        } else if preferredScreenUUID == nil {
            // No legacy value, use main screen
            preferredScreenUUID = NSScreen.main?.displayUUID
        }
        
        selectedScreenUUID = preferredScreenUUID ?? NSScreen.main?.displayUUID ?? ""
        // Observe changes to accessibility authorization and react accordingly
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.accessibilityAuthorizationChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if Defaults[.hudReplacement] {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            }
        }

        // Observe changes to hudReplacement
        hudReplacementCancellable = Defaults.publisher(.hudReplacement)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self = self else { return }

                    self.hudEnableTask?.cancel()
                    self.hudEnableTask = nil

                    if change.newValue {
                        self.hudEnableTask = Task { @MainActor in
                            let granted = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
                            if Task.isCancelled { return }

                            if granted {
                                await MediaKeyInterceptor.shared.start()
                            } else {
                                Defaults[.hudReplacement] = false
                            }
                        }
                    } else {
                        MediaKeyInterceptor.shared.stop()
                    }
                }
            }

        Task { @MainActor in
            helloAnimationRunning = firstLaunch

            if Defaults[.hudReplacement] {
                let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
                if !authorized {
                    Defaults[.hudReplacement] = false
                } else {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            }
        }
    }
    
    @objc func sneakPeekEvent(_ notification: Notification) {
        let decoder = JSONDecoder()
        if let decodedData = try? decoder.decode(
            SharedSneakPeek.self, from: notification.userInfo?.first?.value as! Data)
        {
            let contentType =
                decodedData.type == "brightness"
                ? SneakContentType.brightness
                : decodedData.type == "volume"
                    ? SneakContentType.volume
                    : decodedData.type == "backlight"
                        ? SneakContentType.backlight
                        : decodedData.type == "mic"
                            ? SneakContentType.mic : SneakContentType.brightness

            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            let value = CGFloat((formatter.number(from: decodedData.value) ?? 0.0).floatValue)
            let icon = decodedData.icon

            print("Decoded: \(decodedData), Parsed value: \(value)")

            toggleSneakPeek(status: decodedData.show, type: contentType, value: value, icon: icon)

        } else {
            print("Failed to decode JSON data")
        }
    }

    func toggleSneakPeek(
        status: Bool, type: SneakContentType, duration: TimeInterval = 1.5, value: CGFloat = 0,
        icon: String = ""
    ) {
        sneakPeekDuration = duration
        if type != .music {
            // close()
            if !Defaults[.hudReplacement] {
                return
            }
        }
        Task { @MainActor in
            withAnimation(.smooth) {
                self.sneakPeek.show = status
                self.sneakPeek.type = type
                self.sneakPeek.value = value
                self.sneakPeek.icon = icon
            }
        }

        if type == .mic {
            currentMicStatus = value == 1
        }
    }

    private var sneakPeekDuration: TimeInterval = 1.5
    private var sneakPeekTask: Task<Void, Never>?

    // Helper function to manage sneakPeek timer using Swift Concurrency
    private func scheduleSneakPeekHide(after duration: TimeInterval) {
        sneakPeekTask?.cancel()

        sneakPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self = self, !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation {
                    self.toggleSneakPeek(status: false, type: .music)
                    self.sneakPeekDuration = 1.5
                }
            }
        }
    }

    @Published var sneakPeek: sneakPeek = .init() {
        didSet {
            if sneakPeek.show {
                scheduleSneakPeekHide(after: sneakPeekDuration)
            } else {
                sneakPeekTask?.cancel()
            }
        }
    }

    func toggleExpandingView(
        status: Bool,
        type: SneakContentType,
        value: CGFloat = 0,
        browser: BrowserType = .chromium
    ) {
        Task { @MainActor in
            withAnimation(.smooth) {
                self.expandingView.show = status
                self.expandingView.type = type
                self.expandingView.value = value
                self.expandingView.browser = browser
            }
        }
    }

    private var expandingViewTask: Task<Void, Never>?

    @Published var expandingView: ExpandedItem = .init() {
        didSet {
            if expandingView.show {
                expandingViewTask?.cancel()
                let duration: TimeInterval = (expandingView.type == .download ? 2 : 3)
                let currentType = expandingView.type
                expandingViewTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(duration))
                    guard let self = self, !Task.isCancelled else { return }
                    self.toggleExpandingView(status: false, type: currentType)
                }
            } else {
                expandingViewTask?.cancel()
            }
        }
    }
    
    func showEmpty() {
        currentView = .home
    }

    // MARK: - Agent activity (AgenticNotch)

    private var agentActivityTask: Task<Void, Never>?

    @Published var agentActivity = AgentActivityState() {
        didSet {
            if agentActivity.show {
                agentActivityTask?.cancel()
                let seconds = Defaults[.agentAutoCollapseSeconds]
                agentActivityTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    guard let self, !Task.isCancelled else { return }
                    await MainActor.run {
                        withAnimation(.smooth) { self.agentActivity.show = false }
                    }
                }
            } else {
                agentActivityTask?.cancel()
            }
        }
    }

    private var agentDebounceTask: Task<Void, Never>?
    private var pendingAgentInfo: AgentActivityInfo?

    /// Called on every agent-finished event. Debounced: rapid successive events
    /// (turn-by-turn in one task) reset the timer, so only the last one — once
    /// things go quiet — actually notifies. Avoids a notification per turn.
    func showAgentActivity(_ info: AgentActivityInfo) {
        pendingAgentInfo = info
        agentDebounceTask?.cancel()
        let seconds = max(0, Defaults[.agentDebounceSeconds])
        agentDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run { self.fireAgentActivity() }
        }
    }

    private func fireAgentActivity() {
        guard let info = pendingAgentInfo else { return }
        pendingAgentInfo = nil
        recordAgentHistory(info)
        guard Defaults[.agentNotifyEnabled] else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) {
            self.agentActivity.info = info
            self.agentActivity.show = true
        }
        if Defaults[.agentSoundEnabled] {
            NSSound(named: NSSound.Name(Defaults[.agentSoundName]))?.play()
        }
    }

    /// Prepend to the agent history, keeping only the last 10 entries.
    private func recordAgentHistory(_ info: AgentActivityInfo) {
        var history = Defaults[.agentHistory]
        history.insert(AgentActivityRecord(info: info, date: Date()), at: 0)
        if history.count > 10 { history = Array(history.prefix(10)) }
        Defaults[.agentHistory] = history
    }

    // MARK: - Agent session events / "needs you" (AgenticNotch)

    /// Sessions blocked on the user, oldest first; the last one is on screen.
    /// Sticky by design: no auto-collapse. A session leaves when it sends its next
    /// prompt/stop/session_end, or when the user clicks its card.
    @Published var needsYou: [AgentEvent] = []

    func handleAgentEvent(_ event: AgentEvent) {
        switch event.kind {
        case .waiting:
            recordAgentHistory(AgentActivityInfo(tool: event.tool, status: .waiting,
                                                 project: event.project, title: event.detail))
            guard Defaults[.agentNeedsYouEnabled] else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) {
                needsYou.removeAll { $0.session == event.session }
                needsYou.append(event)
                // The URL scheme is unauthenticated, so bound the stack.
                if needsYou.count > 10 { needsYou.removeFirst() }
            }
            if Defaults[.agentSoundEnabled] {
                // Its own chime, never the one picked for "finished".
                let name = Defaults[.agentSoundName] == "Ping" ? "Tink" : "Ping"
                NSSound(named: NSSound.Name(name))?.play()
            }
        case .prompt, .sessionEnd:
            clearNeedsYou(session: event.session)
        case .stop:
            clearNeedsYou(session: event.session)
            showAgentActivity(AgentActivityInfo(tool: event.tool, status: .ok,
                                                project: event.project, title: event.detail))
        case .sessionStart:
            break
        }
    }

    private func clearNeedsYou(session: String) {
        guard needsYou.contains(where: { $0.session == session }) else { return }
        withAnimation(.smooth) { needsYou.removeAll { $0.session == session } }
    }

    /// Click on the card: dismiss the one on screen, revealing any older one.
    func dismissNeedsYou() {
        withAnimation(.smooth) { _ = needsYou.popLast() }
    }

    // MARK: - Focus activity (Engram pomodoro mirror)

    /// Persistent by design: unlike `agentActivity` there is no auto-collapse task.
    /// It lives until Engram says `idle` or the payload goes stale.
    @Published var focusActivity: FocusActivityInfo?

    func showFocusActivity(_ info: FocusActivityInfo) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) {
            focusActivity = info.phase == .idle ? nil : info
        }
    }

    /// Driven by the views' own 1 s timeline — no timer of our own.
    func clearFocusActivityIfStale(at now: Date) {
        guard let focusActivity, focusActivity.isStale(at: now) else { return }
        withAnimation(.smooth) { self.focusActivity = nil }
    }
}

struct AgentActivityState {
    var show: Bool = false
    var info: AgentActivityInfo = AgentActivityInfo(tool: "", status: .ok, project: "", title: "")
}

// MARK: - AI quota / limits (AgenticNotch)

struct QuotaWindow: Identifiable {
    let id = UUID()
    let label: String         // "5h", "7d", ...
    let usedPercent: Double    // 0...100
    let resetAt: Date?
}

struct ProviderQuota: Identifiable {
    let id = UUID()
    let provider: String       // "Claude", "Codex"
    var windows: [QuotaWindow]
    var error: String?
    /// When the numbers were measured. Nil means "just fetched from the API";
    /// a date means they come from a cache written by the CLI itself.
    var measuredAt: Date?
}

/// Reads local Claude/Codex credentials and queries their usage endpoints.
/// Requires the app to be non-sandboxed (see boringNotch.entitlements).
@MainActor
final class AIQuotaManager: ObservableObject {
    static let shared = AIQuotaManager()

    @Published var providers: [ProviderQuota] = []
    @Published var isLoading = false
    @Published var lastUpdated: Date?

    private init() {}

    func refresh() async {
        isLoading = true
        let claude = await fetchClaude()
        let codex = await fetchCodex()
        providers = [claude, codex].compactMap { $0 }
        lastUpdated = Date()
        isLoading = false
    }

    // MARK: Claude

    /// Claude Code caches the numbers it shows in `/usage` inside ~/.claude.json, so
    /// that is the first stop: no token, no network, and it is what the CLI displays.
    /// The OAuth endpoint is only tried when the cache isn't there — reading the token
    /// costs a keychain prompt, and subscription accounts don't always store one.
    private func fetchClaude() async -> ProviderQuota? {
        if let cached = claudeCachedUsage() { return cached }
        guard let token = claudeToken() else {
            return ProviderQuota(provider: "Claude", windows: [],
                                 error: "No usage data — run Claude Code once")
        }
        return await fetchClaudeLive(token: token)
    }

    private func claudeCachedUsage() -> ProviderQuota? {
        let path = ("~/.claude.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cache["utilization"] as? [String: Any]
        else { return nil }

        let measuredAt = (cache["fetchedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        var windows = parseClaudeLimits(utilization)
        if windows.isEmpty { windows = parseClaudeWindows(utilization) }
        guard !windows.isEmpty else { return nil }
        return ProviderQuota(provider: "Claude", windows: windows, error: nil, measuredAt: measuredAt)
    }

    /// The `limits` array is the CLI's own model: one entry per window, including
    /// per-model weekly caps that the flat five_hour/seven_day keys don't carry.
    private func parseClaudeLimits(_ utilization: [String: Any]) -> [QuotaWindow] {
        guard let limits = utilization["limits"] as? [[String: Any]] else { return [] }
        return limits.compactMap { entry in
            guard let percent = numeric(entry["percent"]) else { return nil }
            let kind = entry["kind"] as? String ?? ""
            let model = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            let label: String
            switch kind {
            case "session":       label = "Session (5h)"
            case "weekly_all":    label = "Weekly"
            case "weekly_scoped": label = model.map { "Weekly · \($0)" } ?? "Weekly (scoped)"
            default:              label = kind.replacingOccurrences(of: "_", with: " ").capitalized
            }
            // A scoped window with nothing used and no reset is a limit that never engaged.
            if kind == "weekly_scoped", percent == 0, entry["resets_at"] is NSNull || entry["resets_at"] == nil {
                return nil
            }
            return QuotaWindow(label: label,
                               usedPercent: percent,
                               resetAt: isoDate(entry["resets_at"]))
        }
    }

    private func fetchClaudeLive(token: String) async -> ProviderQuota? {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { return ProviderQuota(provider: "Claude", windows: [], error: "Session expired — log in again") }
            guard code == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ProviderQuota(provider: "Claude", windows: [], error: "API error (\(code))")
            }
            return ProviderQuota(provider: "Claude", windows: parseClaudeWindows(json), error: nil)
        } catch {
            return ProviderQuota(provider: "Claude", windows: [], error: "No network")
        }
    }

    private func parseClaudeWindows(_ json: [String: Any]) -> [QuotaWindow] {
        let labels = ["five_hour": "Session (5h)", "seven_day": "Weekly",
                      "seven_day_opus": "Weekly · Opus", "seven_day_sonnet": "Weekly · Sonnet"]
        var out: [QuotaWindow] = []
        for (key, value) in json {
            guard let dict = value as? [String: Any] else { continue }
            guard let util = numeric(dict["utilization"]) else { continue }
            out.append(QuotaWindow(label: labels[key] ?? key.replacingOccurrences(of: "_", with: " "),
                                   usedPercent: util,
                                   resetAt: isoDate(dict["resets_at"]) ?? isoDate(dict["reset_at"])))
        }
        let order = Array(labels.values)
        return out.sorted { (order.firstIndex(of: $0.label) ?? 99) < (order.firstIndex(of: $1.label) ?? 99) }
    }

    private func numeric(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? NSNumber)?.doubleValue
    }

    /// Reset stamps arrive as epoch seconds from the API and as ISO-8601 with
    /// fractional seconds from the CLI cache.
    private func isoDate(_ value: Any?) -> Date? {
        if let seconds = numeric(value) { return Date(timeIntervalSince1970: seconds) }
        guard let text = value as? String else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: text) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: text)
    }

    private func claudeToken() -> String? {
        // Claude Code keys the keychain per account: "Claude Code-credentials" and
        // "Claude Code-credentials-<hash>". Checking only the bare name misses
        // every machine with more than one login.
        for service in claudeKeychainServices() {
            if let json = keychainJSON(service: service), let t = oauthAccessToken(json) { return t }
        }
        let path = ("~/.claude/.credentials.json" as NSString).expandingTildeInPath
        if let data = FileManager.default.contents(atPath: path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = oauthAccessToken(json) { return t }
        return nil
    }

    private func oauthAccessToken(_ json: [String: Any]) -> String? {
        for key in ["claudeAiOauth", "claude.ai_oauth"] {
            if let o = json[key] as? [String: Any], let t = o["accessToken"] as? String { return t }
        }
        return nil
    }

    // MARK: Codex

    private func fetchCodex() async -> ProviderQuota? {
        let path = ("~/.codex/auth.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else {
            return ProviderQuota(provider: "Codex", windows: [], error: "No OAuth token")
        }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let acc = tokens["account_id"] as? String {
            req.setValue(acc, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { return ProviderQuota(provider: "Codex", windows: [], error: "Session expired — run 'codex' to refresh") }
            guard code == 200,
                  let j = try JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let rate = j["rate_limit"] as? [String: Any] else {
                return ProviderQuota(provider: "Codex", windows: [], error: "API error (\(code))")
            }
            var windows: [QuotaWindow] = []
            for (key, fallback) in [("primary_window", "Session (5h)"), ("secondary_window", "Weekly")] {
                guard let w = rate[key] as? [String: Any],
                      let used = (w["used_percent"] as? Double) ?? (w["used_percent"] as? NSNumber)?.doubleValue
                else { continue }
                let reset = (w["reset_at"] as? Double) ?? (w["reset_at"] as? NSNumber)?.doubleValue
                let secs = (w["limit_window_seconds"] as? Double) ?? (w["limit_window_seconds"] as? NSNumber)?.doubleValue
                windows.append(QuotaWindow(label: codexLabel(secs) ?? fallback,
                                           usedPercent: used,
                                           resetAt: reset.map { Date(timeIntervalSince1970: $0) }))
            }
            return ProviderQuota(provider: "Codex", windows: windows, error: nil)
        } catch {
            return ProviderQuota(provider: "Codex", windows: [], error: "No network")
        }
    }

    private func codexLabel(_ secs: Double?) -> String? {
        guard let s = secs else { return nil }
        switch Int(s) {
        case 18000:  return "Session (5h)"
        case 604800: return "Weekly"
        default:     return "\(Int(s / 3600))h window"
        }
    }

    #if DEBUG
    /// Parses a sample of the real ~/.claude.json cache shape.
    static func runSelfCheck() {
        let sample: [String: Any] = [
            "limits": [
                ["kind": "session", "percent": 18, "resets_at": "2026-07-31T06:20:00.432008+00:00"],
                ["kind": "weekly_all", "percent": 48, "resets_at": "2026-08-01T00:00:00.432029+00:00"],
                ["kind": "weekly_scoped", "percent": 0, "resets_at": NSNull(),
                 "scope": ["model": ["display_name": "Fable"]]],
            ]
        ]
        let windows = shared.parseClaudeLimits(sample)
        assert(windows.count == 2, "the scoped window with nothing used should be dropped")
        assert(windows[0].label == "Session (5h)" && windows[0].usedPercent == 18)
        assert(windows[1].label == "Weekly" && windows[1].resetAt != nil, "6-digit fractional seconds must parse")

        let flat: [String: Any] = ["five_hour": ["utilization": 12, "resets_at": 1785466356.0]]
        assert(shared.parseClaudeWindows(flat).first?.usedPercent == 12)

        // And against whatever this machine's Claude Code wrote, so a shape change is visible.
        if let live = shared.claudeCachedUsage() {
            for w in live.windows {
                FileHandle.standardError.write("[quota] \(w.label): \(Int(w.usedPercent))% resets \(w.resetAt.map(String.init(describing:)) ?? "—")\n".data(using: .utf8)!)
            }
        } else {
            FileHandle.standardError.write("[quota] no cached usage in ~/.claude.json\n".data(using: .utf8)!)
        }
    }
    #endif

    // MARK: Keychain

    /// Names of the keychain entries Claude Code may have written, most specific last.
    /// Only attributes are requested here, which never triggers an unlock prompt —
    /// the prompt (if any) comes when the matching entry's data is read.
    private func claudeKeychainServices() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let attributes = items as? [[String: Any]] else { return ["Claude Code-credentials"] }
        let services = attributes
            .compactMap { $0[kSecAttrService as String] as? String }
            .filter { $0.hasPrefix("Claude Code-credentials") }
        return services.isEmpty ? ["Claude Code-credentials"] : services.sorted()
    }

    private func keychainJSON(service: String) -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}
