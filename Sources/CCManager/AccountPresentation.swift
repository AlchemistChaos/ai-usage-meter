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
        return active.windows.map(\.remainingPercent).min()
            .map { Int($0.rounded()) }
    }

    static func menuLabel(for accounts: [Account]) -> String? {
        var parts: [String] = []
        if let value = activeRemaining(for: .claude, in: accounts) {
            parts.append("A \(value)")
        }
        if let value = activeRemaining(for: .codex, in: accounts) {
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

    static func dashboardHeight(for accounts: [Account]) -> CGFloat {
        let contentHeight = groups(accounts).reduce(CGFloat(118)) { total, group in
            var sectionHeight = CGFloat(42)

            if let active = group.active {
                sectionHeight += 45 + CGFloat(max(active.windows.count, 1) * 17)
            }

            if !group.inactive.isEmpty {
                let rows = (group.inactive.count + 2) / 3
                sectionHeight += 20 + CGFloat(rows * 86)
            }

            if group.active == nil && group.inactive.isEmpty {
                sectionHeight += 28
            }

            return total + sectionHeight + 10
        }

        return min(max(contentHeight, 360), 680)
    }
}
