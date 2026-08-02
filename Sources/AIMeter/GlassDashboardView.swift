import ServiceManagement
import SwiftUI

private struct DashboardContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct GlassDashboardView: View {
    @ObservedObject var manager: AccountManager
    @State private var contentHeight: CGFloat = 360
    @State private var selectedHistoryAccount: Account?
    @State private var blurEmails = false
    @AppStorage(MenuBarPreferenceKey.claudeFiveHour)
    private var showsClaudeFiveHour = MenuBarSelection.standard.showsClaudeFiveHour
    @AppStorage(MenuBarPreferenceKey.claudeWeekly)
    private var showsClaudeWeekly = MenuBarSelection.standard.showsClaudeWeekly
    @AppStorage(MenuBarPreferenceKey.codexWeekly)
    private var showsCodexWeekly = MenuBarSelection.standard.showsCodexWeekly
    private let maxDashboardHeight: CGFloat = 680
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                ForEach(AccountPresentation.groups(manager.accounts)) { group in
                    ProviderGlassSection(
                        group: group,
                        manager: manager,
                        blurEmails: blurEmails,
                        columns: columns,
                        onHistory: { selectedHistoryAccount = $0 })
                }
                if hasTransientStatus {
                    DashboardTransientStatus(manager: manager)
                }
            }
            .padding(13)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: DashboardContentHeightKey.self,
                        value: geometry.size.height)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDisabled(contentHeight <= maxDashboardHeight)
        .frame(width: 500, height: min(contentHeight, maxDashboardHeight))
        .onPreferenceChange(DashboardContentHeightKey.self) { measuredHeight in
            guard measuredHeight > 0 else { return }
            contentHeight = ceil(measuredHeight)
        }
        .background {
            ZStack {
                NativeGlassBackground()
                    .allowsHitTesting(false)
                LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.14, blue: 0.20).opacity(0.20),
                        Color.black.opacity(0.16),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $selectedHistoryAccount) { selected in
            UsageHistoryView(
                account: selected,
                hourlySeries: manager.historySeries(for: selected, preset: .last24Hours),
                dailySeries: manager.historySeries(for: selected, preset: .last30Days),
                monthlySeries: manager.historySeries(for: selected, preset: .thisYear))
        }
    }

    private var hasTransientStatus: Bool {
        manager.pendingCodexLogin != nil
            || manager.pendingClaudeLogin != nil
            || manager.lastError != nil
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Usage")
                .font(.system(size: 10, weight: .semibold))
            Spacer()
            if let date = manager.lastRefresh {
                Text("Updated \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            BlurButton(isBlurred: blurEmails) {
                blurEmails.toggle()
            }
            Button { manager.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")

            Menu {
                Menu("Add Anthropic account") {
                    Button("Default browser") {
                        manager.beginClaudeLogin()
                    }
                    Divider()
                    ForEach(manager.availableBrowsers) { browser in
                        Button(browser.name) {
                            manager.beginClaudeLogin(browser: browser)
                        }
                    }
                }
                .disabled(manager.pendingCodexLogin != nil)

                if manager.pendingCodexLogin == nil {
                    Button("Add OpenAI Codex account") {
                        manager.beginCodexLogin()
                    }
                } else {
                    Button("Restart OpenAI Codex sign-in") {
                        manager.restartCodexLogin()
                    }
                }

                Button("Import OpenAI Codex login") {
                    manager.importCurrentCodex()
                }

                Divider()

                Menu("Menu bar") {
                    Toggle("Claude 5-hour", isOn: $showsClaudeFiveHour)
                    Toggle("Claude weekly", isOn: $showsClaudeWeekly)
                    Toggle("Codex weekly", isOn: $showsCodexWeekly)
                }

                Divider()

                Toggle("Launch at login", isOn: launchAtLogin)
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Settings")
            .help("Settings")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit")
        }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    manager.lastError =
                        "Launch at login: \(error.localizedDescription)"
                }
            })
    }
}

private struct ProviderGlassSection: View {
    let group: ProviderAccountGroup
    @ObservedObject var manager: AccountManager
    let blurEmails: Bool
    let columns: [GridItem]
    let onHistory: (Account) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ProviderHeader(provider: group.provider)
                .padding(.horizontal, 2)

            if let active = group.active {
                ActiveAccountCard(account: active, blurEmails: blurEmails) {
                    onHistory(active)
                }
            }

            if !group.inactive.isEmpty {
                HStack {
                    Text("OTHER ACCOUNTS")
                    Spacer()
                    Text("\(group.inactive.count)")
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)

                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(group.inactive) { account in
                        CompactAccountCard(account: account, blurEmails: blurEmails) {
                            if account.provider == .codex {
                                manager.switchTo(account)
                            }
                        }
                    }
                }
            }

            if group.active == nil && group.inactive.isEmpty {
                Text("No \(group.provider.displayName) accounts yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .padding(9)
        .background(providerBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 7)
    }

    private var providerBackground: AnyShapeStyle {
        let tint = group.provider == .claude
            ? Color(red: 0.84, green: 0.42, blue: 0.25)
            : Color(red: 0.31, green: 0.47, blue: 0.95)
        return AnyShapeStyle(LinearGradient(
            colors: [tint.opacity(0.17), .white.opacity(0.035)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing))
    }
}

private struct BlurButton: View {
    let isBlurred: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isBlurred ? "eye.slash" : "eye")
                    .font(.system(size: 9, weight: .semibold))
                Text(isBlurred ? "Blurred" : "Blur")
                    .font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.white.opacity(isBlurred ? 0.13 : 0.08))
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isBlurred ? "Show emails" : "Blur emails")
        .help(isBlurred ? "Show emails" : "Blur emails")
    }
}

private struct EmailLabel: View {
    let text: String
    let blurEmails: Bool
    let font: Font

    var body: some View {
        let shouldBlur = blurEmails && text.contains("@")

        Text(text)
            .font(font)
            .lineLimit(1)
            .blur(radius: shouldBlur ? 3 : 0)
            .opacity(shouldBlur ? 0.78 : 1)
            .animation(.easeInOut(duration: 0.14), value: shouldBlur)
            .help(shouldBlur ? "Email hidden" : text)
            .accessibilityLabel(shouldBlur ? "Email hidden" : text)
    }
}

private struct ProviderHeader: View {
    let provider: ProviderKind

    var body: some View {
        HStack(spacing: 8) {
            Text(provider == .claude ? "Claude" : "Codex")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            Text(provider == .claude ? "Live usage" : "Local logs")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ActiveAccountCard: View {
    let account: Account
    let blurEmails: Bool
    let onHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(red: 0.36, green: 0.94, blue: 0.64))
                    .frame(width: 7, height: 7)
                    .shadow(color: Color.green.opacity(0.75), radius: 4)
                    .accessibilityLabel("Active CLI account")
                    .help("Active CLI account")
                EmailLabel(
                    text: account.label,
                    blurEmails: blurEmails,
                    font: .system(size: 11, weight: .semibold))
                PlanBadge(plan: account.plan)
                Spacer()
                Button("History") { onHistory() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(account.status.description)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            if account.windows.isEmpty {
                Text(account.status.description)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(account.windows) { window in
                    ActiveWindowRow(window: window)
                }
            }

            if account.hasAttributedTokens {
                VStack(alignment: .leading, spacing: 4) {
                    TokenSummaryRow(title: "Today", stats: account.todayTokens)
                    TokenSummaryRow(title: "24h", stats: account.last24HoursTokens)
                    TokenSummaryRow(title: "7d", stats: account.last7DaysTokens)
                    TokenSummaryRow(title: "Month", stats: account.thisMonthTokens)
                    TokenSummaryRow(title: "Year", stats: account.thisYearTokens)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(.black.opacity(0.28))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.white.opacity(0.065), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct TokenSummaryRow: View {
    let title: String
    let stats: AttributedTokenStats

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Text("in \(TokenStats.formatCount(stats.inputTokens))")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("out \(TokenStats.formatCount(stats.outputTokens))")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if stats.attribution != .observedActiveSpan {
                Text(stats.attribution == .singleProfileFallback ? "fallback" : "unattributed")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
    }
}

private struct ActiveWindowRow: View {
    let window: UsageWindow

    var body: some View {
        HStack(spacing: 7) {
            Text(window.label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
                .lineLimit(1)
            RemainingBar(remaining: window.remainingPercent, height: 4)
            Text("\(Int(window.remainingPercent.rounded()))% left")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 57, alignment: .trailing)
            Text(AccountPresentation.resetSummary(for: window))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 108, alignment: .trailing)
                .lineLimit(1)
        }
    }
}

private struct CompactAccountCard: View {
    let account: Account
    let blurEmails: Bool
    let onSwitch: () -> Void
    @State private var hovering = false
    @State private var showingResetDetails = false

    var body: some View {
        let primary = AccountPresentation.primaryWindow(for: account)
        let short = AccountPresentation.shortWindow(
            for: account,
            excluding: primary)

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                EmailLabel(
                    text: account.label,
                    blurEmails: blurEmails,
                    font: .system(size: 9, weight: .semibold))
                Spacer(minLength: 2)
                PlanBadge(plan: account.plan, compact: true)
                if account.provider == .codex {
                    Button(action: onSwitch) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering ? 1 : 0.35)
                    .help("Switch Codex to this account")
                }
            }

            if let primary {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(primary.remainingPercent.rounded()))%")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Spacer(minLength: 2)
                    Text(primary.windowMinutes >= 7 * 24 * 60
                         ? "weekly left"
                         : "\(primary.label) left")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                RemainingBar(remaining: primary.remainingPercent, height: 5)

                if let short {
                    HStack(spacing: 5) {
                        Text(short.label)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .leading)
                        RemainingBar(remaining: short.remainingPercent, height: 3)
                        Text("\(Int(short.remainingPercent.rounded()))%")
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 25, alignment: .trailing)
                    }
                }
            } else {
                Text(account.status.description)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(hovering ? 0.30 : 0.20))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(hovering ? 0.12 : 0.055), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { showingResetDetails.toggle() }
        .popover(isPresented: $showingResetDetails, arrowEdge: .bottom) {
            ResetDetailsPopover(account: account, blurEmails: blurEmails)
        }
        .contextMenu {
            if account.provider == .codex {
                Button("Make Default") {
                    onSwitch()
                }
            }
        }
        .accessibilityAction(named: "Show reset times") {
            showingResetDetails = true
        }
        .help("Click for reset times · data \(account.status.description)")
    }
}

private struct ResetDetailsPopover: View {
    let account: Account
    let blurEmails: Bool

    var body: some View {
        let windows = AccountPresentation.detailWindows(for: account)

        VStack(alignment: .leading, spacing: 9) {
            EmailLabel(
                text: account.label,
                blurEmails: blurEmails,
                font: .system(size: 12, weight: .semibold))

            if windows.isEmpty {
                Text("Reset times are available after using this account")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(windows) { window in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(window.label)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .frame(width: 48, alignment: .leading)
                        Text("\(Int(window.remainingPercent.rounded()))% left")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                        Text(AccountPresentation.resetDetail(for: window))
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            }

            Text("Data \(account.status.description)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 310, alignment: .leading)
        .preferredColorScheme(.dark)
    }
}

private struct PlanBadge: View {
    let plan: String?
    var compact = false

    var body: some View {
        if let plan, !plan.isEmpty {
            Text(plan.uppercased())
                .font(.system(size: compact ? 7 : 8, weight: .bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, compact ? 4 : 5)
                .padding(.vertical, 1)
                .background(.white.opacity(0.075))
                .clipShape(Capsule())
        }
    }
}

private struct RemainingBar: View {
    let remaining: Double
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.09))
                Capsule()
                    .fill(tint)
                    .frame(width: max(
                        remaining > 0 ? 2 : 0,
                        geometry.size.width * min(max(remaining, 0), 100) / 100))
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(Int(remaining.rounded())) percent left")
    }

    private var tint: AnyShapeStyle {
        switch remaining {
        case ..<15:
            return AnyShapeStyle(LinearGradient(
                colors: [.red, Color(red: 1, green: 0.55, blue: 0.60)],
                startPoint: .leading, endPoint: .trailing))
        case ..<41:
            return AnyShapeStyle(LinearGradient(
                colors: [.orange, Color(red: 1, green: 0.78, blue: 0.42)],
                startPoint: .leading, endPoint: .trailing))
        default:
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.36, green: 0.53, blue: 1),
                         Color(red: 0.88, green: 0.92, blue: 1)],
                startPoint: .leading, endPoint: .trailing))
        }
    }
}

private struct DashboardTransientStatus: View {
    @ObservedObject var manager: AccountManager
    @State private var loginCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if manager.pendingCodexLogin != nil {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for OpenAI Codex sign-in in your browser…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { manager.cancelCodexLogin() }
                        .buttonStyle(.plain)
                }
            }

            if let pending = manager.pendingClaudeLogin {
                if pending.usesCallback {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for Anthropic sign-in in your browser…")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { manager.cancelClaudeLogin() }
                            .buttonStyle(.plain)
                    }
                } else {
                    HStack(spacing: 6) {
                        TextField("code#state", text: $loginCode)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10, design: .monospaced))
                        Button("Add") {
                            let code = loginCode.trimmingCharacters(
                                in: .whitespacesAndNewlines)
                            guard !code.isEmpty else { return }
                            manager.completeClaudeLogin(pasted: code)
                            loginCode = ""
                        }
                        Button("Cancel") {
                            manager.cancelClaudeLogin()
                            loginCode = ""
                        }
                    }
                }
            }

            if let error = manager.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(.horizontal, 2)
    }
}
