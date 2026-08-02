import Foundation
import SwiftUI

@MainActor
final class AccountManager: ObservableObject {
    /// One instance shared by the menu-bar dashboard.
    static let shared = AccountManager()
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var lastRefresh: Date?
    @Published var lastError: String?

    private var timer: Timer?
    /// Codex usage is a live app-server request — poll at most every 5 minutes.
    private var lastCodexPoll: Date?
    private var lastCodexPollAccountID: String?
    private var lastCodexLiveSnapshotAccountID: String?
    private var lastCodexLiveSnapshotCapturedAt: Date?
    private var codexPollInFlightAccountID: String?
    private var codexUsageError: String?
    /// Claude usage is a real network call — poll at most every 5 minutes.
    private var lastClaudePoll: Date?
    private var claudePollInFlight = false
    private var claudeUsageError: String?
    private let timelineStore = try? AccountTimelineStore.open(
        at: ProfileStore.root.appending(path: "account-timeline.sqlite"))
    private let usageLedger = try? UsageLedger.open(
        at: ProfileStore.root.appending(path: "usage.sqlite"))
    private var lastUsageImport: Date?
    private var usageImportInFlight = false

    /// Tokens burned (Claude, machine-wide from local transcripts).
    @Published private(set) var todayTokens = TokenStats()
    @Published private(set) var weekTokens = TokenStats()
    private var lastTokenScan: Date?
    private var tokenScanInFlight = false

    init() {
        try? ProfileStore.ensureDirs()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        rebuildAccounts()
        observeActiveAccounts()
        lastRefresh = Date()
        pollCodexUsageIfStale()
        pollClaudeUsageIfStale()
        importUsageIfStale()
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
            let windows = TokenStats.collectWindows()
            await self?.applyTokenStats(windows.today, week: windows.week)
        }
    }

    /// Swap real emails for distinct placeholders when demo mode is on.
    private static func applyDemoLabels(_ accounts: [Account]) -> [Account] {
        guard Account.demoMode else { return accounts }
        return accounts.enumerated().map { i, a in
            a.relabelled(Account.demoLabels[i % Account.demoLabels.count])
        }
    }

    /// Rough weekly subscription spend across all visible accounts, from list
    /// prices by plan tier. Used to frame API-equivalent value as a multiple.
    var weeklyPlanSpend: Double {
        let monthly = accounts.reduce(0.0) { sum, a in
            guard a.headroom != nil || a.isActive else { return sum }
            let plan = (a.plan ?? "").lowercased()
            switch a.provider {
            case .claude:
                if plan.contains("20x") { return sum + 200 }
                if plan.contains("max") { return sum + 100 }
                if plan.contains("pro") { return sum + 20 }
                return sum
            case .codex:
                if plan.contains("pro") { return sum + 200 }
                if plan.contains("plus") { return sum + 20 }
                return sum
            }
        }
        return monthly * 12 / 52
    }

    private func applyTokenStats(_ stats: TokenStats, week: TokenStats) {
        todayTokens = stats
        weekTokens = week
        lastTokenScan = Date()
        tokenScanInFlight = false
    }

    private func rebuildAccounts() {
        var result = codexAccounts()
        result.append(contentsOf: claudeAccounts())
        accounts = Self.applyDemoLabels(enrichAccounts(result))
    }

    private func enrichAccounts(_ accounts: [Account]) -> [Account] {
        accounts.map { account in
            let snapshot = usageSnapshot(for: account)
            return Account(
                provider: account.provider,
                profileName: account.profileName,
                email: account.email,
                plan: account.plan,
                isActive: account.isActive,
                windows: account.windows,
                status: account.status,
                usageAccountID: account.usageAccountID,
                todayTokens: snapshot.today,
                last24HoursTokens: snapshot.last24Hours,
                last7DaysTokens: snapshot.last7Days,
                thisMonthTokens: snapshot.thisMonth,
                thisYearTokens: snapshot.thisYear)
        }
    }

    private func usageSnapshot(for account: Account) -> UsageHistoryQuery.HistorySnapshot {
        guard let usageLedger else { return emptyUsageSnapshot() }
        let query = UsageHistoryQuery(ledger: usageLedger)
        return (try? query.snapshot(
            provider: account.provider,
            accountID: account.usageAccountID,
            now: Date())) ?? emptyUsageSnapshot()
    }

    private func emptyUsageSnapshot() -> UsageHistoryQuery.HistorySnapshot {
        .init(
            today: AttributedTokenStats(),
            last24Hours: AttributedTokenStats(),
            last7Days: AttributedTokenStats(),
            last30Days: AttributedTokenStats(),
            thisMonth: AttributedTokenStats(),
            thisYear: AttributedTokenStats())
    }

    func historySeries(
        for account: Account,
        preset: UsageHistoryQuery.RangePreset
    ) -> UsageHistoryQuery.Series {
        guard let usageLedger else {
            return .init(preset: preset, points: [])
        }
        let query = UsageHistoryQuery(ledger: usageLedger)
        return (try? query.series(
            provider: account.provider,
            accountID: account.usageAccountID,
            preset: preset,
            now: Date())) ?? .init(preset: preset, points: [])
    }

    private func importUsageIfStale() {
        guard !usageImportInFlight,
              lastUsageImport.map({ -$0.timeIntervalSinceNow > 60 }) ?? true,
              let usageLedger,
              let timelineStore
        else { return }

        usageImportInFlight = true
        let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects")
        let logsDB = CodexProvider.logsDB
        let manager = self

        Task.detached(priority: .utility) {
            let storedProfiles = ClaudeProvider.listProfiles().map {
                ClaudeProvider.storedProfile($0)
            }
            try? ClaudeTranscriptImporter(
                projectsRoot: projectsRoot,
                ledger: usageLedger,
                timeline: timelineStore,
                knownProfileCount: { storedProfiles.count },
                singleKnownAccountID: {
                    ClaudeProvider.soleStoredAccountUUID(from: storedProfiles)
                }
            ).run()

            try? CodexUsageImporter(
                logsDB: logsDB,
                ledger: usageLedger,
                timeline: timelineStore
            ).run()

            await MainActor.run {
                manager.lastUsageImport = Date()
                manager.usageImportInFlight = false
                manager.rebuildAccounts()
            }
        }
    }

    private func observeActiveAccounts() {
        if let claudeAccountID = ClaudeProvider.identity()?.accountUuid {
            try? timelineStore?.observe(
                provider: .claude,
                accountID: claudeAccountID,
                at: Date())
        }

        let liveCredential = ProfileStore.activeCredentialPath(.codex)
        let cliAccountID = CodexProvider.identity(at: liveCredential)?.accountID
        let credentialModifiedAt = CodexProvider.modificationDate(at: liveCredential)
        let desktopState = CodexProvider.desktopAccountState()
        let desktopIsRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: CodexProvider.desktopBundleIdentifier).isEmpty
        if let codexAccountID = CodexProvider.activeAccountIdentity(
            desktopAccountID: desktopState?.accountID,
            desktopModifiedAt: desktopState?.modifiedAt,
            desktopIsRunning: desktopIsRunning,
            cliAccountID: cliAccountID,
            cliCredentialModifiedAt: credentialModifiedAt) {
            try? timelineStore?.observe(
                provider: .codex,
                accountID: codexAccountID,
                at: Date())
        }
    }

    // MARK: - Codex (local: JWT + sqlite log harvest)

    private func codexAccounts() -> [Account] {
        var result: [Account] = []

        let liveCredential = ProfileStore.activeCredentialPath(.codex)
        let liveIdentity = CodexProvider.identity(at: liveCredential)

        // SQLite rows have no account ID. Only use one when it was recorded
        // after this credential file became active, or an account switch could
        // make the menu-bar C value show the previous account's reading.
        let credentialModifiedAt = CodexProvider.modificationDate(at: liveCredential)
        if let snapshot = CodexProvider.latestSnapshot(),
           let live = liveIdentity,
           let credentialModifiedAt,
           CodexProvider.canAttributeSQLiteFallback(
               capturedAt: snapshot.capturedAt,
               credentialModifiedAt: credentialModifiedAt) {
            SnapshotCache.put(accountID: live.accountID, snapshot: snapshot)
        }

        let desktopIsRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: CodexProvider.desktopBundleIdentifier).isEmpty
        let desktopState = CodexProvider.desktopAccountState()
        let activeAccountID = CodexProvider.activeAccountIdentity(
            desktopAccountID: desktopState?.accountID,
            desktopModifiedAt: desktopState?.modifiedAt,
            desktopIsRunning: desktopIsRunning,
            cliAccountID: liveIdentity?.accountID,
            cliCredentialModifiedAt: credentialModifiedAt)
        let profileNames = ProfileStore.listProfiles(.codex)
        let activeProfileName = profileNames.first { name in
            CodexProvider.accountIdentity(
                at: ProfileStore.profileFile(.codex, name)) == activeAccountID
        }
        if let activeProfileName,
           liveIdentity?.accountID == activeAccountID {
            _ = try? ProfileStore.importActive(.codex, as: activeProfileName)
        }

        // Someone may be logged in without having imported that account yet.
        if activeProfileName == nil, let activeAccountID {
            let cached = SnapshotCache.get(accountID: activeAccountID)
            let activeIsCLI = liveIdentity?.accountID == activeAccountID
            let status: DataStatus = cached.map {
                codexDataStatus(
                    cachedAt: $0.capturedAt,
                    accountID: activeAccountID,
                    activeAccountID: activeAccountID)
            } ?? .noData(reason: "use Codex once to record limits")
            result.append(Account(
                provider: .codex,
                profileName: activeIsCLI
                    ? (liveIdentity?.email ?? "current")
                    : "Codex desktop",
                email: activeIsCLI ? liveIdentity?.email : nil,
                plan: cached?.plan ?? (activeIsCLI ? liveIdentity?.plan : nil),
                isActive: true,
                windows: cached?.projectedWindows() ?? [],
                status: status,
                usageAccountID: activeAccountID))
        }

        for name in profileNames {
            let url = ProfileStore.profileFile(.codex, name)
            guard let id = CodexProvider.identity(at: url) else {
                result.append(Account(
                    provider: .codex, profileName: name, email: nil, plan: nil,
                    isActive: false, windows: [],
                    status: .error("unreadable credential"),
                    usageAccountID: nil))
                continue
            }
            let cached = SnapshotCache.get(accountID: id.accountID)
            let status: DataStatus = cached.map {
                codexDataStatus(
                    cachedAt: $0.capturedAt,
                    accountID: id.accountID,
                    activeAccountID: activeAccountID)
            } ?? .noData(reason: "no reading yet — switch to it and use Codex once")
            result.append(Account(
                provider: .codex,
                profileName: name,
                email: id.email,
                plan: cached?.plan ?? id.plan,
                isActive: id.accountID == activeAccountID,
                windows: cached?.projectedWindows() ?? [],
                status: status,
                usageAccountID: id.accountID))
        }
        return result
    }

    private func codexDataStatus(
        cachedAt: Date,
        accountID: String,
        activeAccountID: String?
    ) -> DataStatus {
        if accountID == activeAccountID,
           lastCodexLiveSnapshotAccountID == accountID,
           lastCodexLiveSnapshotCapturedAt == cachedAt {
            return .live(cachedAt)
        }
        return .cached(cachedAt)
    }

    /// Fetch the active Codex account directly through the installed official
    /// client. A changed account bypasses the normal five-minute throttle.
    private func pollCodexUsageIfStale() {
        guard let identity = CodexProvider.identity(
            at: ProfileStore.activeCredentialPath(.codex))
        else { return }
        let requestedAccountID = identity.accountID
        let isFreshForAccount = lastCodexPollAccountID == requestedAccountID
            && (lastCodexPoll.map { -$0.timeIntervalSinceNow <= 300 } ?? false)
        guard codexPollInFlightAccountID == nil, !isFreshForAccount else { return }

        codexPollInFlightAccountID = requestedAccountID
        Task { @MainActor in
            defer {
                if codexPollInFlightAccountID == requestedAccountID {
                    codexPollInFlightAccountID = nil
                }
                // A switch can occur while the old account's helper is still
                // running. Re-evaluate immediately so the new account does not
                // wait for the next 30-second refresh timer.
                pollCodexUsageIfStale()
            }
            do {
                let snapshot = try await CodexRateLimitClient.fetchSnapshot()
                lastCodexPoll = Date()
                lastCodexPollAccountID = requestedAccountID

                // The helper authenticated at launch. Never attribute its
                // response to an account switched in while it was running.
                guard CodexProvider.identity(
                    at: ProfileStore.activeCredentialPath(.codex))?.accountID
                        == requestedAccountID
                else { return }

                SnapshotCache.put(
                    accountID: requestedAccountID,
                    snapshot: snapshot)
                if let cached = SnapshotCache.get(accountID: requestedAccountID) {
                    lastCodexLiveSnapshotAccountID = requestedAccountID
                    lastCodexLiveSnapshotCapturedAt = cached.capturedAt
                }
                codexUsageError = nil
                publishUsageErrors()

                rebuildAccounts()
            } catch {
                lastCodexPoll = Date()
                lastCodexPollAccountID = requestedAccountID
                codexUsageError = "Codex: \(error.localizedDescription)"
                publishUsageErrors()
            }
        }
    }

    // MARK: - Claude (app-stored OAuth tokens + live usage endpoint)

    private func claudeAccounts() -> [Account] {
        guard let identity = ClaudeProvider.identity() else {
            return [Account(
                provider: .claude, profileName: "not-detected",
                email: nil, plan: nil, isActive: false, windows: [],
                status: .noData(reason: "no Claude login found in ~/.claude.json"),
                usageAccountID: nil)]
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
                    : "no reading yet"),
            usageAccountID: uuid)
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
            claudeUsageError = failures.isEmpty
                ? nil
                : "Claude: \(failures.joined(separator: " · "))"
            publishUsageErrors()
            rebuildAccounts()
        }
    }

    private func publishUsageErrors() {
        let errors = [codexUsageError, claudeUsageError].compactMap { $0 }
        lastError = errors.isEmpty ? nil : errors.joined(separator: " · ")
    }

    // MARK: - Claude login flow (add account without touching the CLI)

    @Published var pendingClaudeLogin: ClaudeOAuth.PendingLogin?
    private var callbackServer: ClaudeOAuth.CallbackServer?

    @Published private(set) var pendingCodexLogin: CodexLogin.Session?
    private var codexLoginProcess: Process?
    private var codexLoginErrorPipe: Pipe?
    private var cancelledCodexLoginID: UUID?
    private var restartCodexLoginAfterCancellation = false

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

    /// Authenticate another Codex account in a private CODEX_HOME. The active
    /// ~/.codex/auth.json is never touched, so the current CLI session remains
    /// active throughout the browser login.
    func beginCodexLogin() {
        guard pendingCodexLogin == nil else { return }

        var preparedSession: CodexLogin.Session?
        do {
            let session = try CodexLogin.prepare(in: ProfileStore.root)
            preparedSession = session
            let runner = try CodexLogin.makeProcess(for: session)
            pendingCodexLogin = session
            codexLoginProcess = runner.process
            codexLoginErrorPipe = runner.errorPipe
            cancelledCodexLoginID = nil
            restartCodexLoginAfterCancellation = false

            runner.process.terminationHandler = { [weak self] process in
                let errorData = runner.errorPipe.fileHandleForReading
                    .readDataToEndOfFile()
                let errorText = String(data: errorData, encoding: .utf8) ?? ""
                Task { @MainActor [weak self] in
                    self?.finishCodexLogin(
                        session: session,
                        exitStatus: process.terminationStatus,
                        errorText: errorText)
                }
            }
            try runner.process.run()
        } catch {
            if let preparedSession { CodexLogin.cleanup(preparedSession) }
            pendingCodexLogin = nil
            codexLoginProcess = nil
            codexLoginErrorPipe = nil
            lastError = error.localizedDescription
        }
    }

    func cancelCodexLogin() {
        restartCodexLoginAfterCancellation = false
        stopCodexLogin()
    }

    func restartCodexLogin() {
        guard pendingCodexLogin != nil else {
            beginCodexLogin()
            return
        }
        restartCodexLoginAfterCancellation = true
        stopCodexLogin()
    }

    private func stopCodexLogin() {
        guard let session = pendingCodexLogin else { return }
        cancelledCodexLoginID = session.id
        if let process = codexLoginProcess, process.isRunning {
            process.terminate()
        } else {
            finishCodexLogin(session: session, exitStatus: -1, errorText: "")
        }
    }

    private func finishCodexLogin(
        session: CodexLogin.Session,
        exitStatus: Int32,
        errorText: String
    ) {
        guard pendingCodexLogin?.id == session.id else {
            CodexLogin.cleanup(session)
            return
        }

        defer {
            let shouldRestart = restartCodexLoginAfterCancellation
            CodexLogin.cleanup(session)
            pendingCodexLogin = nil
            codexLoginProcess = nil
            codexLoginErrorPipe = nil
            cancelledCodexLoginID = nil
            restartCodexLoginAfterCancellation = false
            if shouldRestart {
                Task { @MainActor [weak self] in self?.beginCodexLogin() }
            }
        }

        if cancelledCodexLoginID == session.id { return }

        guard exitStatus == 0,
              let identity = CodexProvider.identity(at: session.authFile) else {
            let detail = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            lastError = detail.isEmpty
                ? "Codex sign-in did not complete. Please try again."
                : String(detail.suffix(300))
            return
        }

        do {
            let name = AccountPresentation.codexProfileName(
                email: identity.email,
                accountID: identity.accountID,
                existingAccountIDsByName: existingCodexIdentities())
            try ProfileStore.importCredential(
                .codex,
                from: session.authFile,
                as: name)
            lastError = nil
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func existingCodexIdentities() -> [String: String] {
        var result: [String: String] = [:]
        for name in ProfileStore.listProfiles(.codex) {
            result[name] = CodexProvider.accountIdentity(
                at: ProfileStore.profileFile(.codex, name))
                ?? "unreadable:\(name)"
        }
        return result
    }

    /// The account with the most headroom, among those we have real data for.
    var recommended: Account? {
        accounts
            .filter { $0.headroom != nil }
            .max { ($0.headroom ?? 0) < ($1.headroom ?? 0) }
    }

    /// Import whatever Codex account is currently logged in, naming the profile
    /// after its email automatically — no reason to make anyone type a name we
    /// can already read out of the token.
    func importCurrentCodex() {
        guard let id = CodexProvider.identity(at: ProfileStore.activeCredentialPath(.codex)) else {
            lastError = "No Codex login found — run `codex login` first"
            return
        }
        let name = AccountPresentation.codexProfileName(
            email: id.email,
            accountID: id.accountID,
            existingAccountIDsByName: existingCodexIdentities())
        importCurrent(.codex, as: name)
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
