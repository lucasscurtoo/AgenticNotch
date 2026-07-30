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

// MARK: - Agent activity (AgenticNotch)

enum AgentStatus: String {
    case ok
    case error
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

    private func fetchClaude() async -> ProviderQuota? {
        guard let token = claudeToken() else {
            return ProviderQuota(provider: "Claude", windows: [], error: "No credentials")
        }
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
        let labels = ["five_hour": "5h", "seven_day": "7d",
                      "seven_day_opus": "7d Opus", "seven_day_sonnet": "7d Sonnet"]
        var out: [QuotaWindow] = []
        for (key, value) in json {
            guard let dict = value as? [String: Any] else { continue }
            guard let util = (dict["utilization"] as? Double) ?? (dict["utilization"] as? NSNumber)?.doubleValue
            else { continue }
            let reset = (dict["resets_at"] as? Double) ?? (dict["reset_at"] as? Double)
            out.append(QuotaWindow(label: labels[key] ?? key.replacingOccurrences(of: "_", with: " "),
                                   usedPercent: util,
                                   resetAt: reset.map { Date(timeIntervalSince1970: $0) }))
        }
        let order = ["5h", "7d", "7d Sonnet", "7d Opus"]
        return out.sorted { (order.firstIndex(of: $0.label) ?? 99) < (order.firstIndex(of: $1.label) ?? 99) }
    }

    private func claudeToken() -> String? {
        if let json = keychainJSON(service: "Claude Code-credentials"), let t = oauthAccessToken(json) { return t }
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
            for (key, fallback) in [("primary_window", "5h"), ("secondary_window", "7d")] {
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
        case 18000:  return "5h"
        case 604800: return "7d"
        default:     return "\(Int(s / 3600))h"
        }
    }

    // MARK: Keychain

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
