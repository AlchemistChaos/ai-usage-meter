import Foundation
import SwiftUI

@MainActor
final class AccountManager: ObservableObject {
    /// One instance shared by the menu bar scene and the notch panel.
    static let shared = AccountManager()
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var lastRefresh: Date?
    @Published var lastError: String?

    private var timer: Timer?
    /// Claude usage is a real network call — poll at most every 5 minutes.
    private var lastClaudePoll: Date?
    private var claudePollInFlight = false

    /// Tokens burned today (Claude, machine-wide from local transcripts).
    @Published private(set) var todayTokens = TokenStats()
    private var lastTokenScan: Date?
    private var tokenScanInFlight = false

    init() {
        try? ProfileStore.ensureDirs()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        var result = codexAccounts()
        result.append(contentsOf: claudeAccounts())
        accounts = Self.applyDemoLabels(result)
        lastRefresh = Date()
        pollClaudeUsageIfStale()
        scanTokensIfStale()
    }

    /// Recount today's tokens from transcripts, at most every 2 minutes,
    /// off the main thread (files can be tens of MB).
    private func scanTokensIfStale() {
        guard !tokenScanInFlight,
              lastTokenScan.map({ -$0.timeIntervalSinceNow > 120 }) ?? true
        else { return }
        tokenScanInFlight = true
        Task.detached(priority: .utility) { [weak self] in
            let stats = TokenStats.collectToday()
            await self?.applyTokenStats(stats)
        }
    }

    /// Swap real emails for distinct placeholders when demo mode is on.
    private static func applyDemoLabels(_ accounts: [Account]) -> [Account] {
        guard Account.demoMode else { return accounts }
        return accounts.enumerated().map { i, a in
            a.relabelled(Account.demoLabels[i % Account.demoLabels.count])
        }
    }

    private func applyTokenStats(_ stats: TokenStats) {
        todayTokens = stats
        lastTokenScan = Date()
        tokenScanInFlight = false
    }

    // MARK: - Codex (local: JWT + sqlite log harvest)

    private func codexAccounts() -> [Account] {
        var result: [Account] = []

        // Harvest the newest reading and attribute it to whoever is active now.
        let liveIdentity = CodexProvider.identity(at: ProfileStore.activeCredentialPath(.codex))
        if let snapshot = CodexProvider.latestSnapshot(), let live = liveIdentity {
            SnapshotCache.put(accountID: live.accountID, snapshot: snapshot)
        }

        let activeName = ProfileStore.activeProfileName(.codex)

        // Someone may be logged in without having imported that account yet.
        if activeName == nil, let live = liveIdentity {
            result.append(Account(
                provider: .codex,
                profileName: live.email ?? "current",
                email: live.email,
                plan: live.plan,
                isActive: true,
                windows: SnapshotCache.get(accountID: live.accountID)?.projectedWindows() ?? [],
                status: SnapshotCache.get(accountID: live.accountID)
                    .map { .live($0.capturedAt) }
                    ?? .noData(reason: "run Codex once to record limits")))
        }

        for name in ProfileStore.listProfiles(.codex) {
            let url = ProfileStore.profileFile(.codex, name)
            guard let id = CodexProvider.identity(at: url) else {
                result.append(Account(
                    provider: .codex, profileName: name, email: nil, plan: nil,
                    isActive: false, windows: [],
                    status: .error("unreadable credential")))
                continue
            }
            let cached = SnapshotCache.get(accountID: id.accountID)
            result.append(Account(
                provider: .codex,
                profileName: name,
                email: id.email,
                plan: cached?.plan ?? id.plan,
                isActive: name == activeName,
                windows: cached?.projectedWindows() ?? [],
                status: cached.map { .live($0.capturedAt) }
                    ?? .noData(reason: "no reading yet — switch to it and use Codex once")))
        }
        return result
    }

    // MARK: - Claude (app-stored OAuth tokens + live usage endpoint)

    private func claudeAccounts() -> [Account] {
        guard let identity = ClaudeProvider.identity() else {
            return [Account(
                provider: .claude, profileName: "not-detected",
                email: nil, plan: nil, isActive: false, windows: [],
                status: .noData(reason: "no Claude login found in ~/.claude.json"))]
        }

        var result: [Account] = []
        let profiles = ClaudeProvider.listProfiles()
        let activeProfile = profiles.first {
            ClaudeProvider.storedProfile($0).accountUuid == identity.accountUuid
        }

        // Current login, shown even before it's been imported as a profile.
        if activeProfile == nil {
            result.append(claudeAccount(
                name: identity.email ?? "current",
                uuid: identity.accountUuid,
                email: identity.email, plan: identity.plan, isActive: true))
        }

        for name in profiles {
            let stored = ClaudeProvider.storedProfile(name)
            let isActive = name == activeProfile
            result.append(claudeAccount(
                name: name,
                uuid: stored.accountUuid,
                email: isActive ? identity.email : stored.email,
                plan: isActive ? identity.plan : stored.plan,
                isActive: isActive))
        }
        return result
    }

    private func claudeAccount(
        name: String, uuid: String?, email: String?, plan: String?, isActive: Bool
    ) -> Account {
        let cached = uuid.flatMap { SnapshotCache.get(accountID: "claude:\($0)") }
        return Account(
            provider: .claude,
            profileName: name,
            email: email,
            plan: plan,
            isActive: isActive,
            windows: cached?.projectedWindows() ?? [],
            status: cached.map { .live($0.capturedAt) }
                ?? .noData(reason: isActive
                    ? "sign in via “Add Claude account…” below to see limits"
                    : "no reading yet"))
    }

    /// Fetch live usage for EVERY Claude account we have a token for — each
    /// stored profile carries its own OAuth token (auto-refreshed when expired),
    /// so all accounts' limits stay visible, not just the active one.
    private func pollClaudeUsageIfStale() {
        guard !claudePollInFlight,
              lastClaudePoll.map({ -$0.timeIntervalSinceNow > 300 }) ?? true
        else { return }

        let profiles = ClaudeProvider.listProfiles()
        guard !profiles.isEmpty else { return }

        claudePollInFlight = true
        Task { @MainActor in
            defer { claudePollInFlight = false }
            var polled = Set<String>()
            var failures: [String] = []

            for name in profiles {
                // Skip profiles that are the same account we already polled.
                if let uuid = ClaudeProvider.profileToken(name)?.accountUuid,
                   polled.contains(uuid) { continue }
                do {
                    let tok = try await ClaudeProvider.freshToken(for: name)
                    let windows = try await ClaudeProvider.fetchUsage(token: tok.accessToken)
                    if let uuid = tok.accountUuid {
                        SnapshotCache.put(
                            accountID: "claude:\(uuid)",
                            snapshot: .init(windows: windows, plan: nil, capturedAt: Date()))
                        polled.insert(uuid)
                    }
                } catch { failures.append("\(name): \(error.localizedDescription)") }
            }

            lastClaudePoll = Date()
            lastError = failures.isEmpty ? nil : failures.joined(separator: " · ")
            // Rebuild rows without re-triggering the poll.
            var result = codexAccounts()
            result.append(contentsOf: claudeAccounts())
            accounts = Self.applyDemoLabels(result)
        }
    }

    // MARK: - Claude login flow (add account without touching the CLI)

    @Published var pendingClaudeLogin: ClaudeOAuth.PendingLogin?
    private var callbackServer: ClaudeOAuth.CallbackServer?

    /// Browsers installed on this Mac that can open the login page. Each
    /// browser has its own cookie jar, so signing in from different browsers
    /// lets you add several Claude accounts without logging anything out.
    struct Browser: Identifiable, Hashable {
        let name: String
        let appURL: URL
        var id: URL { appURL }
    }

    var availableBrowsers: [Browser] {
        let handlers = NSWorkspace.shared.urlsForApplications(
            toOpen: URL(string: "https://claude.ai")!)
        return handlers.compactMap { url in
            let name = (url.deletingPathExtension().lastPathComponent)
            return Browser(name: name, appURL: url)
        }
        .sorted { $0.name < $1.name }
    }

    /// Open the chosen browser on Claude's OAuth consent page — the same flow
    /// as `claude login`: a localhost listener catches the redirect
    /// automatically. If the port is taken we fall back to the paste variant.
    func beginClaudeLogin(browser: Browser? = nil) {
        callbackServer?.stop()
        callbackServer = ClaudeOAuth.CallbackServer { [weak self] code, state in
            Task { @MainActor in
                self?.completeClaudeLogin(pasted: "\(code)#\(state)")
            }
        }
        let login = ClaudeOAuth.begin(usesCallback: callbackServer != nil)
        pendingClaudeLogin = login
        if let browser {
            NSWorkspace.shared.open(
                [login.url], withApplicationAt: browser.appURL,
                configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(login.url)
        }
    }

    /// Complete the login with the "code#state" string the user pasted.
    func completeClaudeLogin(pasted: String) {
        guard let login = pendingClaudeLogin else { return }
        Task { @MainActor in
            do {
                let tokens = try await ClaudeOAuth.exchange(pasted: pasted, login: login)
                let profile = try await ClaudeOAuth.fetchProfile(token: tokens.accessToken)
                let name = profile.email?.split(separator: "@").first.map(String.init)
                    ?? String(profile.accountUuid.prefix(8))
                try ClaudeOAuth.saveProfile(name: name, tokens: tokens, profile: profile)
                pendingClaudeLogin = nil
                callbackServer?.stop()
                callbackServer = nil
                lastError = nil
                lastClaudePoll = nil  // pull limits for the new account now
                refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func cancelClaudeLogin() {
        pendingClaudeLogin = nil
        callbackServer?.stop()
        callbackServer = nil
    }

    // MARK: - Actions

    /// The account with the most headroom, among those we have real data for.
    var recommended: Account? {
        accounts
            .filter { $0.headroom != nil }
            .max { ($0.headroom ?? 0) < ($1.headroom ?? 0) }
    }

    func importCurrent(_ provider: ProviderKind, as name: String) {
        do {
            switch provider {
            case .codex: try ProfileStore.importActive(provider, as: name)
            case .claude: break  // Claude accounts are added via the login flow
            }
            lastError = nil
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func switchTo(_ account: Account) {
        do {
            switch account.provider {
            case .codex: try ProfileStore.activate(.codex, name: account.profileName)
            case .claude:
                lastError = "Claude switching is off — the app never writes your keychain. Use `claude` to change accounts."
                return
            }
            lastError = nil
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
