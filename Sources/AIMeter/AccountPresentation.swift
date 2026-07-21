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

    static func menuLabel(for accounts: [Account]) -> String? {
        var parts: [String] = []
        if accounts.contains(where: { $0.provider == .claude && $0.isActive }) {
            let value = activeRemaining(for: .claude, in: accounts)
                .map(String.init) ?? "—"
            parts.append("A \(value)")
        }
        if accounts.contains(where: { $0.provider == .codex && $0.isActive }) {
            let value = activeRemaining(for: .codex, in: accounts)
                .map(String.init) ?? "—"
            parts.append("C \(value)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
