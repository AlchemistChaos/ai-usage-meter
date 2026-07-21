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
    used: Double
) -> UsageWindow {
    UsageWindow(
        label: label,
        usedPercent: used,
        windowMinutes: minutes,
        resetsAt: nil)
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
                for: .claude, in: [claude, inactive]) == 51,
            "menu reading should use only the active account")

        let codex = account(.codex, "codex", active: true, windows: [
            window("Weekly", minutes: 10_080, used: 55),
        ])
        expect(
            AccountPresentation.menuLabel(for: [claude, codex])
                == "A 51 · C 45",
            "menu label should identify both providers")

        print("PASS: account presentation")
    }
}
