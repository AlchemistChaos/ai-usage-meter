import Foundation

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func window(
    _ label: String,
    minutes: Int,
    used: Double,
    resetsAt: Date? = nil
) -> UsageWindow {
    UsageWindow(
        label: label,
        usedPercent: used,
        windowMinutes: minutes,
        resetsAt: resetsAt)
}

private func account(
    _ provider: ProviderKind,
    _ name: String,
    active: Bool,
    windows: [UsageWindow]
) -> Account {
    Account(
        provider: provider,
        profileName: name,
        email: "\(name)@example.com",
        plan: "pro",
        isActive: active,
        windows: windows,
        status: .live(Date(timeIntervalSince1970: 1)))
}

@main
enum AccountPresentationHarness {
    static func main() {
        let grouped = AccountPresentation.groups([
            account(.codex, "codex-active", active: true, windows: []),
            account(.claude, "claude-other", active: false, windows: []),
            account(.claude, "claude-active", active: true, windows: []),
        ])
        expect(grouped.map(\.provider) == [.claude, .codex],
               "providers should be ordered Claude then Codex")
        expect(grouped[0].active?.profileName == "claude-active",
               "Claude active account should be partitioned")
        expect(grouped[0].inactive.map(\.profileName) == ["claude-other"],
               "Claude inactive accounts should remain visible")

        let fiveHour = window("5h", minutes: 300, used: 25)
        let weekly = window("Weekly", minutes: 10_080, used: 49)
        let claude = account(
            .claude, "claude", active: true,
            windows: [fiveHour, weekly])
        let primary = AccountPresentation.primaryWindow(for: claude)
        let short = AccountPresentation.shortWindow(
            for: claude, excluding: primary)
        expect(primary?.label == "Weekly", "weekly should be primary")
        expect(primary?.remainingPercent == 51,
               "weekly should expose remaining capacity")
        expect(short?.label == "5h", "5h should be secondary")
        expect(short?.remainingPercent == 75,
               "5h should expose remaining capacity")

        let onlyShort = account(
            .codex, "single", active: true, windows: [fiveHour])
        let onlyPrimary = AccountPresentation.primaryWindow(for: onlyShort)
        expect(
            AccountPresentation.shortWindow(
                for: onlyShort, excluding: onlyPrimary) == nil,
            "a single window should not be duplicated")

        let daily = window("Daily", minutes: 1_440, used: 40)
        let dailyAccount = account(
            .codex, "daily", active: true,
            windows: [fiveHour, daily])
        expect(
            AccountPresentation.primaryWindow(for: dailyAccount)?.label == "Daily",
            "the longest available window should be primary")

        let inactive = account(.claude, "inactive", active: false, windows: [
            window("Weekly", minutes: 10_080, used: 99),
        ])
        expect(
            AccountPresentation.activeRemaining(
                for: .claude, in: [claude, inactive]) == 75,
            "menu reading should use the active account's hourly window")

        let codex = account(.codex, "codex", active: true, windows: [
            window("Weekly", minutes: 10_080, used: 55),
        ])
        expect(
            AccountPresentation.menuLabel(for: [claude, codex])
                == "A 75 · C —",
            "menu label should never substitute weekly for missing hourly data")

        let codexHourly = account(.codex, "codex-hourly", active: true, windows: [
            window("5h", minutes: 300, used: 30),
            window("Weekly", minutes: 10_080, used: 55),
        ])
        expect(
            AccountPresentation.menuLabel(for: [claude, codexHourly])
                == "A 75 · C 70",
            "menu label should show each provider's hourly remaining capacity")

        let resetWindow = window(
            "Weekly",
            minutes: 10_080,
            used: 20,
            resetsAt: Date().addingTimeInterval(48 * 60 * 60))
        let resetSummary = AccountPresentation.resetSummary(for: resetWindow)
        expect(resetSummary.contains(" · "),
               "reset summary should include countdown and date/time")
        expect(AccountPresentation.resetSummary(for: weekly) == "—",
               "missing reset time should remain explicit")

        let panelAccounts = [
            claude,
            account(.claude, "claude-2", active: false,
                    windows: [fiveHour, weekly]),
            codex,
            account(.codex, "codex-2", active: false,
                    windows: [fiveHour, weekly]),
            account(.codex, "codex-3", active: false,
                    windows: [fiveHour, weekly]),
        ]
        let panelHeight = AccountPresentation.dashboardHeight(
            for: panelAccounts)
        expect(panelHeight >= 420,
               "a populated menu panel must have a usable finite height")
        expect(panelHeight <= 680,
               "the menu panel must remain bounded on smaller displays")

        let fable = window("Fable wk", minutes: 10_080, used: 49)
        let screenshotLayoutAccounts = [
            account(.claude, "claude-active", active: true,
                    windows: [fiveHour, weekly, fable]),
            account(.claude, "claude-2", active: false,
                    windows: [fiveHour, weekly]),
            account(.claude, "claude-3", active: false,
                    windows: [fiveHour, weekly]),
            account(.codex, "codex-active", active: true,
                    windows: [weekly]),
            account(.codex, "codex-empty", active: false,
                    windows: []),
        ]
        let compactHeight = AccountPresentation.dashboardHeight(
            for: screenshotLayoutAccounts)
        expect(compactHeight >= 440 && compactHeight <= 490,
               "mixed compact rows should not reserve a large empty footer")

        expect(
            AccountPresentation.codexProfileName(
                email: "river@example.com",
                accountID: "new-account",
                existingAccountIDsByName: [:]) == "river-example-com",
            "Codex profile names should include the full email domain")
        expect(
            AccountPresentation.codexProfileName(
                email: "river@example.com",
                accountID: "new-account",
                existingAccountIDsByName: ["river-example-com": "other-account"])
                == "river-example-com-2",
            "Codex profile names should not overwrite a different account")
        expect(
            AccountPresentation.codexProfileName(
                email: "renamed@example.com",
                accountID: "same-account",
                existingAccountIDsByName: ["already-saved": "same-account"])
                == "already-saved",
            "an already saved Codex identity should reuse its profile")
        expect(
            AccountPresentation.resetDetail(for: weekly)
                == "Available after using this account",
            "missing reset timestamps should use actionable copy")
        expect(
            AccountPresentation.resetDetail(for: resetWindow)
                .contains(" · "),
            "available reset details should contain countdown and date/time")

        print("PASS: account presentation")
    }
}
