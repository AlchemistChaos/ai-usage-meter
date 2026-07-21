import Foundation

struct ProviderAccountGroup: Identifiable {
    var id: ProviderKind { provider }
    let provider: ProviderKind
    let active: Account?
    let inactive: [Account]
}

enum AccountPresentation {
    static func groups(_ accounts: [Account]) -> [ProviderAccountGroup] {
        [ProviderKind.claude, ProviderKind.codex].map { provider in
            let matching = accounts.filter { $0.provider == provider }
            return ProviderAccountGroup(
                provider: provider,
                active: matching.first(where: \.isActive),
                inactive: matching.filter { !$0.isActive })
        }
    }

    static func primaryWindow(for account: Account) -> UsageWindow? {
        account.longWindow
            ?? account.windows.max(by: { $0.windowMinutes < $1.windowMinutes })
    }

    static func shortWindow(
        for account: Account,
        excluding primary: UsageWindow?
    ) -> UsageWindow? {
        guard let short = account.shortWindow,
              short.id != primary?.id else { return nil }
        return short
    }

    static func activeRemaining(
        for provider: ProviderKind,
        in accounts: [Account]
    ) -> Int? {
        guard let active = accounts.first(where: {
            $0.provider == provider && $0.isActive
        }) else { return nil }
        return active.shortWindow.map {
            Int($0.remainingPercent.rounded())
        }
    }

    static func menuLabel(
        for accounts: [Account],
        selection: MenuBarSelection = .standard
    ) -> String? {
        var parts: [String] = []
        if let claude = accounts.first(where: {
            $0.provider == .claude && $0.isActive
        }) {
            let showsBoth = selection.showsClaudeFiveHour
                && selection.showsClaudeWeekly
            if selection.showsClaudeFiveHour {
                let value = remaining(in: claude, windowMinutes: 300)
                    .map(String.init) ?? "—"
                parts.append(showsBoth ? "A 5h \(value)" : "A \(value)")
            }
            if selection.showsClaudeWeekly {
                let value = remaining(in: claude, windowMinutes: 10_080)
                    .map(String.init) ?? "—"
                parts.append(selection.showsClaudeFiveHour
                    ? "W \(value)"
                    : "A W \(value)")
            }
        }
        if selection.showsCodexWeekly,
           let codex = accounts.first(where: {
            $0.provider == .codex && $0.isActive
           }) {
            let weekly = remaining(
                in: codex, windowMinutes: 10_080)
                .map(String.init) ?? "—"
            parts.append("C \(weekly)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func remaining(
        in account: Account,
        windowMinutes: Int
    ) -> Int? {
        account.windows.first(where: {
            $0.windowMinutes == windowMinutes
        }).map {
            Int($0.remainingPercent.rounded())
        }
    }

    static func resetSummary(for window: UsageWindow) -> String {
        guard window.resetsAt != nil else { return "—" }
        return "\(window.resetsInDescription) · \(window.resetsAtDescription)"
    }

    static func resetDetail(for window: UsageWindow) -> String {
        guard window.resetsAt != nil else {
            return "Available after using this account"
        }
        return resetSummary(for: window)
    }

    static func codexProfileName(
        email: String?,
        accountID: String,
        existingAccountIDsByName: [String: String]
    ) -> String {
        if let saved = existingAccountIDsByName.keys.sorted().first(where: {
            existingAccountIDsByName[$0] == accountID
        }) {
            return saved
        }

        let source = (email?.isEmpty == false ? email! : String(accountID.prefix(8)))
            .lowercased()
        let normalized = String(source.map { character in
            character.isLetter || character.isNumber ? character : "-"
        })
        let base = normalized.split(separator: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let preferred = base.isEmpty ? String(accountID.prefix(8)) : base

        guard existingAccountIDsByName[preferred] != nil else { return preferred }
        var suffix = 2
        while existingAccountIDsByName["\(preferred)-\(suffix)"] != nil {
            suffix += 1
        }
        return "\(preferred)-\(suffix)"
    }

}
