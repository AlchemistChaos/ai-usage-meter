import Foundation
import SwiftUI

@MainActor
final class AccountManager: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var lastRefresh: Date?
    @Published var lastError: String?

    private var timer: Timer?
    /// Claude usage is a real network call — poll at most every 5 minutes.
    private var lastClaudePoll: Date?
    private var claudePollInFlight = false

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
        accounts = result
        lastRefresh = Date()
        pollClaudeUsageIfStale()
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

    // MARK: - Claude (keychain token + live usage endpoint)

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
                ?? .noData(reason: isActive ? "fetching usage…" : "no reading yet"))
    }

    /// True when a Claude login exists but the keychain hasn't been unlocked
    /// for us yet — the UI offers a Connect button that triggers the (one-time)
    /// macOS approval dialog at a moment the user expects it.
    var claudeNeedsKeychainApproval: Bool {
        ClaudeProvider.identity() != nil && ClaudeProvider.credential() == nil
    }

    func connectClaude() {
        // Force a fresh keychain read; macOS shows its password dialog here.
        // "Always Allow" makes it permanent (the app is Developer-ID signed,
        // so the grant survives rebuilds).
        if ClaudeProvider.credential(forceReload: true) != nil {
            lastError = nil
            lastClaudePoll = nil
            refresh()
        } else {
            lastError = "Keychain access was not granted"
        }
    }

    /// Fetch live Claude usage for the active account, at most every 5 minutes.
    private func pollClaudeUsageIfStale() {
        guard !claudePollInFlight,
              lastClaudePoll.map({ -$0.timeIntervalSinceNow > 300 }) ?? true,
              let identity = ClaudeProvider.identity(),
              let cred = ClaudeProvider.credential()
        else { return }

        if let exp = cred.expiresAt, exp <= Date() {
            lastError = "Claude token expired — run `claude` once to refresh it"
            return
        }

        claudePollInFlight = true
        let uuid = identity.accountUuid
        Task { @MainActor in
            defer { claudePollInFlight = false }
            do {
                let windows = try await ClaudeProvider.fetchUsage(token: cred.accessToken)
                lastClaudePoll = Date()
                SnapshotCache.put(
                    accountID: "claude:\(uuid)",
                    snapshot: .init(windows: windows, plan: cred.subscriptionType,
                                    capturedAt: Date()))
                // Rebuild rows without re-triggering the poll.
                var result = codexAccounts()
                result.append(contentsOf: claudeAccounts())
                accounts = result
            } catch {
                lastError = "Claude usage fetch failed: \(error.localizedDescription)"
            }
        }
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
            case .claude: try ClaudeProvider.importActive(as: name)
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
                try ClaudeProvider.activate(name: account.profileName)
                lastClaudePoll = nil  // re-poll usage for the new account
            }
            lastError = nil
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
