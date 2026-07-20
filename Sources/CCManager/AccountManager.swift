import Foundation
import SwiftUI

@MainActor
final class AccountManager: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var lastRefresh: Date?
    @Published var lastError: String?

    private var timer: Timer?

    init() {
        try? ProfileStore.ensureDirs()
        refresh()
        // Codex writes new headers only when you actually use it, so a slow
        // poll is plenty — this reads a local file, it never hits the network.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        var result: [Account] = []

        // Harvest the newest reading and attribute it to whoever is active now.
        let liveIdentity = CodexProvider.identity(at: ProfileStore.activeCredentialPath(.codex))
        if let snapshot = CodexProvider.latestSnapshot(), let live = liveIdentity {
            SnapshotCache.put(accountID: live.accountID, snapshot: snapshot)
        }

        let activeName = ProfileStore.activeProfileName(.codex)
        var profiles = ProfileStore.listProfiles(.codex)

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
            profiles = profiles.filter { _ in true }
        }

        for name in profiles {
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

        result.append(contentsOf: ClaudeProvider.accounts())
        accounts = result
        lastRefresh = Date()
    }

    /// The account with the most headroom, among those we have real data for.
    var recommended: Account? {
        accounts
            .filter { $0.provider == .codex && $0.headroom != nil }
            .max { ($0.headroom ?? 0) < ($1.headroom ?? 0) }
    }

    func importCurrent(_ provider: ProviderKind, as name: String) {
        do {
            try ProfileStore.importActive(provider, as: name)
            lastError = nil
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func switchTo(_ account: Account) {
        do {
            try ProfileStore.activate(account.provider, name: account.profileName)
            lastError = nil
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
