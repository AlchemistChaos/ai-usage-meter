import Foundation

/// A usage window reported by a provider (e.g. the 5-hour window or the weekly window).
struct UsageWindow: Identifiable, Hashable {
    let id = UUID()
    /// Human label, e.g. "5h" or "Weekly".
    let label: String
    /// 0...100
    let usedPercent: Double
    /// Length of the rolling window.
    let windowMinutes: Int
    /// When the window resets, if known.
    let resetsAt: Date?

    var remainingPercent: Double { max(0, 100 - usedPercent) }

    var resetsInDescription: String {
        guard let resetsAt else { return "—" }
        let secs = Int(resetsAt.timeIntervalSinceNow)
        if secs <= 0 { return "now" }
        let h = secs / 3600, m = (secs % 3600) / 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// Absolute reset moment — "4:39 PM" if today, else "Jul 25, 6:59 PM".
    var resetsAtDescription: String {
        guard let resetsAt else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = Calendar.current.isDateInToday(resetsAt) ? "h:mm a" : "MMM d, h:mm a"
        return fmt.string(from: resetsAt)
    }
}

enum ProviderKind: String, Codable, CaseIterable {
    case codex, claude

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }
}

/// How fresh / trustworthy an account's usage data is.
enum DataStatus: Equatable {
    /// Real limit data harvested at the given time.
    case live(Date)
    /// We know the account exists but have no usage figures.
    case noData(reason: String)
    /// Something is misconfigured.
    case error(String)

    var isUsable: Bool { if case .live = self { return true }; return false }

    var description: String {
        switch self {
        case .live(let at):
            let mins = Int(-at.timeIntervalSinceNow / 60)
            if mins < 1 { return "just now" }
            if mins < 60 { return "\(mins)m ago" }
            return "\(mins / 60)h ago"
        case .noData(let reason): return reason
        case .error(let msg): return msg
        }
    }
}

struct Account: Identifiable {
    /// Stable identity: provider + profile name on disk.
    var id: String { "\(provider.rawValue):\(profileName)" }

    let provider: ProviderKind
    /// The name of the stored profile directory.
    let profileName: String
    /// Email or other human identifier, if we can read one.
    let email: String?
    /// Plan tier, e.g. "pro", "max".
    let plan: String?
    /// True if this profile is the one currently active for the CLI.
    let isActive: Bool
    let windows: [UsageWindow]
    let status: DataStatus

    var label: String { email ?? profileName }

    /// A copy with a different display email — used only by demo mode.
    func relabelled(_ newEmail: String) -> Account {
        Account(provider: provider, profileName: profileName, email: newEmail,
                plan: plan, isActive: isActive, windows: windows, status: status)
    }

    /// Placeholder identities so marketing screenshots never expose real
    /// account emails. Enabled with CCM_DEMO=1.
    static let demoMode = ProcessInfo.processInfo.environment["CCM_DEMO"] != nil
    static let demoLabels = [
        "you@example.com", "work@example.com",
        "side-project@example.com", "team@example.com",
        "personal@example.com", "agency@example.com",
    ]

    /// The window we treat as the short-term ("5 hour") budget, if the
    /// provider reports one. Codex reports its short window as "secondary"
    /// when a weekly primary window is in force.
    var shortWindow: UsageWindow? {
        windows.filter { $0.windowMinutes > 0 && $0.windowMinutes <= 24 * 60 }
            .min { $0.windowMinutes < $1.windowMinutes }
    }

    var longWindow: UsageWindow? {
        windows.filter { $0.windowMinutes > 24 * 60 }
            .max { $0.windowMinutes < $1.windowMinutes }
    }

    /// Headroom score used to recommend which account to use next.
    /// Higher is better. Nil when we have no real data to judge on.
    var headroom: Double? {
        guard status.isUsable else { return nil }
        let short = shortWindow?.remainingPercent
        let long = longWindow?.remainingPercent
        switch (short, long) {
        case let (s?, l?): return min(s, l) * 0.7 + s * 0.3
        case let (s?, nil): return s
        case let (nil, l?): return l
        default: return nil
        }
    }
}
