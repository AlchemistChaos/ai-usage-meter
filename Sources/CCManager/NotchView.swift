import SwiftUI

/// The notch, designed as a living object with progressive disclosure:
///
///   ambient — visually identical to the hardware notch; one dim status dot
///             per provider. Silent unless a budget runs hot.
///   glance  — on hover the notch swells a touch and remaining-% chips slide
///             out of it into the wings. Zero commitment, instantly gone.
///   full    — dwell (or click) unfurls the dashboard: staggered rows,
///             animated numbers, depth. Content emerges *from* the notch.
enum NotchState: Equatable {
    case ambient, glance, full

    @MainActor var size: CGSize {
        let notch = NotchController.notchWidth()
        switch self {
        case .ambient:
            return CGSize(width: notch + 24, height: NotchController.notchHeight)
        case .glance:
            return CGSize(width: notch + 240, height: NotchController.notchHeight + 6)
        case .full:
            // Width fixed; height hugs the content (reported via preference).
            return CGSize(width: NotchController.expandedSize.width, height: 0)
        }
    }
}

/// Reports the dashboard's natural height so the shell and panel can hug it.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct NotchView: View {
    @ObservedObject var manager: AccountManager
    let notchWidth: CGFloat
    let onStateChange: (NotchState, CGFloat) -> Void

    // CCM_NOTCH_STATE=full|glance forces a state at launch (screenshot/debug).
    @State private var state: NotchState = {
        switch ProcessInfo.processInfo.environment["CCM_NOTCH_STATE"] {
        case "full": return .full
        case "glance": return .glance
        default: return .ambient
        }
    }()
    @State private var hoverTask: Task<Void, Never>?
    @State private var fullHeight: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            shell
            Spacer(minLength: 0)
        }
        .frame(width: NotchController.expandedSize.width,
               height: NotchController.expandedSize.height,
               alignment: .top)
    }

    private var shell: some View {
        ZStack(alignment: .top) {
            // The black object itself. Its silhouette is the entire design.
            notchShape
                .fill(.black)
                .overlay(
                    // Hairline that catches the light only when open.
                    notchShape.strokeBorder(
                        .white.opacity(state == .full ? 0.09 : 0.02),
                        lineWidth: 1))
                .shadow(color: .black.opacity(state == .ambient ? 0 : 0.55),
                        radius: state == .full ? 22 : 8,
                        y: state == .full ? 10 : 3)

            switch state {
            case .ambient:
                AmbientDots(manager: manager)
            case .glance:
                GlanceChips(manager: manager, notchWidth: notchWidth)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .top)))
            case .full:
                FullDashboard(manager: manager)
                    .background(GeometryReader { geo in
                        Color.clear.preference(
                            key: ContentHeightKey.self, value: geo.size.height)
                    })
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)),
                        removal: .opacity))
            }
        }
        .onPreferenceChange(ContentHeightKey.self) { h in
            guard h > 0 else { return }
            fullHeight = min(h, NotchController.expandedSize.height)
            if state == .full { onStateChange(.full, fullHeight) }
        }
        .frame(width: state.size.width, height: height(of: state), alignment: .top)
        .contentShape(notchShape)
        .onTapGesture { advance(to: .full) }
        .onHover { hovering in
            // Debug screenshots pin the state; ignore live hover then.
            guard ProcessInfo.processInfo.environment["CCM_NOTCH_STATE"] == nil else { return }
            hoverTask?.cancel()
            if hovering {
                if state == .ambient { advance(to: .glance) }
                // Dwell: keep hovering and the full view opens on its own.
                if state == .glance {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        guard !Task.isCancelled else { return }
                        advance(to: .full)
                    }
                }
            } else {
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 320_000_000)
                    guard !Task.isCancelled else { return }
                    advance(to: .ambient)
                }
            }
        }
        // Fast, springy in; softer settle out.
        .animation(.spring(response: state == .ambient ? 0.42 : 0.3,
                           dampingFraction: 0.82), value: state)
    }

    private func height(of s: NotchState) -> CGFloat {
        s == .full ? fullHeight : s.size.height
    }

    private func advance(to next: NotchState) {
        guard next != state else { return }
        // Window must grow before content does, and shrink after it's gone.
        if height(of: next) >= height(of: state) {
            onStateChange(next, height(of: next))
            state = next
        } else {
            state = next
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 420_000_000)
                if state == next { onStateChange(next, height(of: next)) }
            }
        }
    }

    private var notchShape: UnevenRoundedRectangle {
        let r: CGFloat = state == .full ? 24 : 11
        return UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: r,
            bottomTrailingRadius: r, topTrailingRadius: 0,
            style: .continuous)
    }
}

// MARK: - Design tokens

/// One color, used only where it means something. Healthy state stays neutral.
private func statusColor(_ used: Double) -> Color {
    switch used {
    case ..<60: return Color(red: 0.35, green: 0.85, blue: 0.55)
    case ..<85: return Color(red: 1.0, green: 0.68, blue: 0.25)
    default: return Color(red: 1.0, green: 0.33, blue: 0.36)
    }
}

private enum Ink {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)
    static let faint = Color.white.opacity(0.14)
}

@MainActor
private func bestWindow(_ manager: AccountManager, _ provider: ProviderKind) -> UsageWindow? {
    let best = manager.accounts
        .filter { $0.provider == provider && $0.headroom != nil }
        .max { ($0.headroom ?? 0) < ($1.headroom ?? 0) }
    return best?.shortWindow ?? best?.longWindow
}

// MARK: - Ambient

private struct AmbientDots: View {
    @ObservedObject var manager: AccountManager

    var body: some View {
        HStack {
            dot(bestWindow(manager, .claude)?.usedPercent)
            Spacer()
            dot(bestWindow(manager, .codex)?.usedPercent)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    @ViewBuilder
    private func dot(_ used: Double?) -> some View {
        if let used, used >= 85 {
            Circle().fill(statusColor(used))
                .frame(width: 4, height: 4)
                .shadow(color: statusColor(used).opacity(0.8), radius: 3)
        } else if let used {
            Circle().fill(statusColor(used).opacity(0.3))
                .frame(width: 3.5, height: 3.5)
        } else {
            Circle().fill(Ink.faint).frame(width: 3.5, height: 3.5)
        }
    }
}

// MARK: - Glance

/// Chips that read as sliding out from behind the notch.
private struct GlanceChips: View {
    @ObservedObject var manager: AccountManager
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            chip(label: "CLAUDE", window: bestWindow(manager, .claude), leading: true)
            Color.clear.frame(width: notchWidth - 30)
            chip(label: "CODEX", window: bestWindow(manager, .codex), leading: false)
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func chip(label: String, window: UsageWindow?, leading: Bool) -> some View {
        let used = window?.usedPercent
        HStack(spacing: 7) {
            if leading { meter(used) }
            VStack(alignment: leading ? .leading : .trailing, spacing: 1) {
                Text(label)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Ink.tertiary)
                    .kerning(1.1)
                Text(window.map { "\(Int($0.remainingPercent))%" } ?? "–")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Ink.primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            if !leading { meter(used) }
        }
        .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
    }

    private func meter(_ used: Double?) -> some View {
        ZStack {
            Circle().stroke(Ink.faint, lineWidth: 2.5)
            if let used {
                Circle()
                    .trim(from: 0, to: max(0.04, (100 - used) / 100))
                    .stroke(statusColor(used),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 17, height: 17)
    }
}

// MARK: - Full

private struct FullDashboard: View {
    @ObservedObject var manager: AccountManager
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer().frame(height: NotchController.notchHeight + 2)

            if let rec = manager.recommended {
                recommendation(rec)
                    .staggered(0, appeared)
            }

            let visible = manager.accounts.filter { !($0.windows.isEmpty && !$0.isActive) }
            ForEach(Array(visible.enumerated()), id: \.element.id) { i, account in
                AccountCard(account: account)
                    .staggered(i + 1, appeared)
            }

            if !manager.todayTokens.isEmpty {
                tokensFooter
                    .staggered(visible.count + 1, appeared)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                appeared = true
            }
        }
        .onDisappear { appeared = false }
    }

    private func recommendation(_ rec: Account) -> some View {
        HStack(spacing: 8) {
            Image(systemName: rec.isActive ? "checkmark.circle.fill" : "arrow.uturn.right.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(rec.isActive
                    ? Color(red: 0.35, green: 0.85, blue: 0.55) : Ink.secondary)
            Text(rec.isActive ? "Best account active" : "Switch to \(rec.label)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.primary)
            Spacer()
            if let w = rec.shortWindow ?? rec.longWindow {
                Text("\(Int(w.remainingPercent))% \(w.label) left")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Ink.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(.white.opacity(0.055)))
    }

    private var tokensFooter: some View {
        HStack(spacing: 5) {
            Text("TODAY")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Ink.tertiary)
                .kerning(1.1)
            Text("\(TokenStats.formatCount(manager.todayTokens.inputTokens)) in · "
                 + "\(TokenStats.formatCount(manager.todayTokens.outputTokens)) out · "
                 + "\(TokenStats.formatCount(manager.todayTokens.cacheReadTokens)) cached")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Ink.secondary)
                .monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, 2)
    }
}

private struct AccountCard: View {
    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(account.provider == .claude ? "◆" : "●")
                    .font(.system(size: 7))
                    .foregroundStyle(account.isActive
                        ? Color(red: 0.35, green: 0.85, blue: 0.55) : Ink.tertiary)
                Text(account.label)
                    .font(.system(size: 12,
                                  weight: account.isActive ? .semibold : .regular))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if let plan = account.plan {
                    Text(plan.uppercased())
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Ink.secondary)
                        .kerning(0.5)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(.white.opacity(0.09)))
                }
                Spacer()
                Text(account.status.description)
                    .font(.system(size: 8.5))
                    .foregroundStyle(Ink.tertiary)
            }

            ForEach(account.windows) { w in
                HStack(spacing: 8) {
                    Text(w.label)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 48, alignment: .leading)
                        .lineLimit(1)
                    bar(w.usedPercent)
                    Text("\(Int(w.usedPercent))%")
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundStyle(Ink.primary)
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                        .contentTransition(.numericText())
                    Text(w.resetsAt == nil ? "—"
                         : "\(w.resetsInDescription) · \(w.resetsAtDescription)")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Ink.tertiary)
                        .monospacedDigit()
                        .frame(width: 104, alignment: .trailing)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(.white.opacity(0.035)))
    }

    private func bar(_ used: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.faint)
                Capsule()
                    .fill(used >= 60
                          ? AnyShapeStyle(statusColor(used))
                          : AnyShapeStyle(Color.white.opacity(0.75)))
                    .frame(width: max(3, geo.size.width * used / 100))
                    .shadow(color: used >= 85 ? statusColor(used).opacity(0.6) : .clear,
                            radius: 4)
            }
        }
        .frame(height: 3.5)
    }
}

// MARK: - Motion helpers

private extension View {
    /// Rows cascade in, each a beat behind the previous.
    func staggered(_ index: Int, _ appeared: Bool) -> some View {
        self
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : -8)
            .animation(.spring(response: 0.45, dampingFraction: 0.85)
                .delay(Double(index) * 0.045), value: appeared)
    }
}
